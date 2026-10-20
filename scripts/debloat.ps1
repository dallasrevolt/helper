
# Relaunch as administrator when needed
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $scriptUrl = 'https://helper.dallasrevolt.workers.dev/debloat'
    $shell = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source

    if (-not $shell) {
        throw 'Windows Terminal (wt.exe) was not found.'
    }

    $bootstrap = "`$ErrorActionPreference='Stop';try{`$r=Invoke-WebRequest -Uri '$scriptUrl' -UseBasicParsing -ErrorAction Stop;`$c=`$r.Content;if([string]::IsNullOrWhiteSpace(`$c)-or `$r.StatusCode -ne 200 -or `$c -match '(?is)^\s*(<!doctype html|<html|error code:\s*\d+|not found\b)'){throw 'Invalid script response'};& ([ScriptBlock]::Create(`$c))}catch{Write-Host `"Failed to download or run the script: `$(`$_.Exception.Message)`" -ForegroundColor Red}"

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

    try {
        Start-Process -FilePath $shell -Verb RunAs -ArgumentList @(
            '-w', 'new',
            'powershell.exe',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-NoExit',
            '-EncodedCommand', $encoded
        ) -ErrorAction Stop
    } catch {
        Write-Host "Could not start elevated console: $($_.Exception.Message)" -ForegroundColor Red
    }

    return
}

Clear-Host
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Confirm-Action {
    param([string]$Message)
    do { $answer = (Read-Host $Message).Trim() } while ($answer -notmatch '^[YyNn]$')
    return ($answer -match '^[Yy]$')
}

# Identify the interactive account by its Explorer process, not by SID-based app queries.
$sessionId = (Get-Process -Id $PID).SessionId
$explorers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -eq $sessionId })
$interactiveUsers = @(
    foreach ($explorer in $explorers) {
        try {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction Stop
            if ($owner.User -and $owner.Domain) { "$($owner.Domain)\$($owner.User)" }
        } catch {}
    }
) | Select-Object -Unique

if ($interactiveUsers.Count -ne 1) {
    Write-Host 'Could not identify the interactive user.' -ForegroundColor Red
    return
}
$interactiveUser = $interactiveUsers[0]

# Worker runs detection, uninstallation AND verification in the interactive user's context.
$workerPath = Join-Path $env:ProgramData 'DebloatInteractiveWorker.ps1'
$payloadPath = Join-Path $env:ProgramData 'DebloatInteractivePayload.json'
$resultPath = Join-Path $env:PUBLIC 'DebloatInteractiveResult.json'
$taskName = 'DebloatInteractiveWorker'

$workerCode = @'
param([string]$PayloadPath,[string]$ResultPath)
$ErrorActionPreference = 'Stop'
function Get-OneDriveState {
    $root = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive'
    $exe = Join-Path $root 'OneDrive.exe'
    $paths = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $entries = @(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^(Microsoft )?OneDrive$' })
    [pscustomobject]@{ Root=$root; Exe=$exe; Entries=$entries; Installed=((Test-Path -LiteralPath $exe) -or $entries.Count -gt 0) }
}
function Find-OneDriveSetup($state) {
    foreach ($entry in $state.Entries) {
        $u = [string]$entry.UninstallString
        if ($u -match '^\s*"([^"]+)"') { $candidate=$Matches[1] }
        elseif ($u -match '^\s*(.+?\.exe)(?:\s|$)') { $candidate=$Matches[1].Trim('"') }
        else { $candidate=$null }
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    if (Test-Path -LiteralPath $state.Root) {
        $setup = Get-ChildItem -LiteralPath $state.Root -Filter 'OneDriveSetup.exe' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($setup) { return $setup.FullName }
    }
    return $null
}

$result = $null

try {
    $p = Get-Content -LiteralPath $PayloadPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    switch ($p.Mode) {
        'Detect' {
            $pkgs = @(Get-AppxPackage)
            $od = Get-OneDriveState
            $result = [pscustomobject]@{
                Success = $true
                Packages = @($pkgs | Select-Object Name, PackageFullName)
                OneDriveInstalled = $od.Installed
            }
        }
        'Appx' {
            $wanted = @($p.PackageNames)
            $errors = @()

            foreach ($name in $wanted) {
                $matching = @(Get-AppxPackage | Where-Object { $_.Name -eq $name })

                foreach ($pkg in $matching) {
                    try {
                        Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                    }
                    catch {
                        $errors += "$name`: $($_.Exception.Message)"
                    }
                }
            }

            $deadline = (Get-Date).AddSeconds(30)
            do {
                Start-Sleep -Milliseconds 500
                $remaining = @(Get-AppxPackage | Where-Object { $_.Name -in $wanted })
            } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

            $remainingNames = @($remaining | Select-Object -ExpandProperty Name -Unique)

            $result = [pscustomobject]@{
                Success = ($remainingNames.Count -eq 0 -and $errors.Count -eq 0)
                Remaining = $remainingNames
                Errors = $errors
            }
        }
        'OneDrive' {
            $before = Get-OneDriveState

            if (-not $before.Installed) {
                $result = [pscustomobject]@{ Success = $true; Message = 'Already absent' }
            }
            else {
                $setup = Find-OneDriveSetup $before
                if (-not $setup) { throw 'OneDrive uninstaller was not found.' }

                $proc = Start-Process -FilePath $setup -ArgumentList '/uninstall' -PassThru -Wait -ErrorAction Stop
                $deadline = (Get-Date).AddSeconds(45)

                do {
                    Start-Sleep -Seconds 1
                    $after = Get-OneDriveState
                } while ($after.Installed -and (Get-Date) -lt $deadline)

                $result = [pscustomobject]@{
                    Success = (-not $after.Installed -and $proc.ExitCode -eq 0)
                    ExitCode = $proc.ExitCode
                    StillInstalled = $after.Installed
                }
            }
        }
        default {
            throw "Unknown worker mode: $($p.Mode)"
        }
    }
}
catch {
    $result = [pscustomobject]@{
        Success = $false
        Error = $_.Exception.ToString()
    }
}

try {
    $result | ConvertTo-Json -Depth 8 -ErrorAction Stop |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8 -ErrorAction Stop
}
catch {
    [Console]::Error.WriteLine("Could not write worker result to '$ResultPath': $($_.Exception.ToString())")
    exit 1
}
'@

Set-Content -LiteralPath $workerPath -Value $workerCode -Encoding UTF8

function Invoke-InteractiveWorker {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Payload,
        [Parameter(Mandatory=$true)][string]$Activity,
        [int]$TimeoutSeconds = 180
    )

    $spinner = @('/', '-', '\')
    $spin = 0
    $lineLength = 0
    $runId = [guid]::NewGuid().ToString('N')
    $runTask = "DebloatWorker_$runId"
    $runPayload = Join-Path $env:ProgramData "DebloatPayload_$runId.json"
    $runResult = Join-Path $env:PUBLIC "DebloatResult_$runId.json"
    $runWorker = Join-Path $env:ProgramData "DebloatWorker_$runId.ps1"

    try {
        Copy-Item -LiteralPath $workerPath -Destination $runWorker -Force -ErrorAction Stop
        $Payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runPayload -Encoding UTF8 -ErrorAction Stop
        Remove-Item -LiteralPath $runResult -Force -ErrorAction SilentlyContinue

        $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $powerShellExe)) { throw "PowerShell executable not found: $powerShellExe" }
        foreach ($path in @($runWorker, $runPayload, (Split-Path -Parent $runResult))) {
            if (-not (Test-Path -LiteralPath $path)) { throw "Required path does not exist: $path" }
        }
        $actionArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PayloadPath "{1}" -ResultPath "{2}"' -f $runWorker, $runPayload, $runResult
        $action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $actionArgs
        $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Limited

        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSeconds + 30))

        Register-ScheduledTask -TaskName $runTask -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $runTask -ErrorAction Stop

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $taskCompleted = $false

        while ((Get-Date) -lt $deadline) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $runTask -ErrorAction SilentlyContinue
            $task = Get-ScheduledTask -TaskName $runTask -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $runResult) {
                try {
                    $data = Get-Content -LiteralPath $runResult -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $data -and $null -ne $data.Success) {
                        $taskCompleted = $true
                        break
                    }
                } catch {}
            }

            if ($task -and $task.State -eq 'Ready' -and $taskInfo -and $taskInfo.LastRunTime -gt [datetime]::MinValue) {
                if (-not (Test-Path -LiteralPath $runResult)) {
                    throw "The scheduled task ended without producing a result file. LastTaskResult=$($taskInfo.LastTaskResult)"
                }
            }

            $frame = "$Activity... $($spinner[$spin])"
            [Console]::Write("`r$frame")
            $lineLength = [Math]::Max($lineLength, $frame.Length)
            $spin = ($spin + 1) % $spinner.Count
            Start-Sleep -Milliseconds 150
        }

        if (-not $taskCompleted) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $runTask -ErrorAction SilentlyContinue
            throw "Timed out or worker failed. LastTaskResult=$($taskInfo.LastTaskResult)"
        }

        [Console]::Write("`r" + (' ' * $lineLength) + "`r")
        return $data
    }
    finally {
        Unregister-ScheduledTask -TaskName $runTask -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $runPayload,$runResult,$runWorker -Force -ErrorAction SilentlyContinue
    }
}

# Application definitions retained from the original script.
$Apps = [ordered]@{
    'Alarms' = @('Microsoft.WindowsAlarms')
    'Bing' = @('Microsoft.BingNews','Microsoft.BingSearch','Microsoft.BingWeather')
    'Camera' = @('Microsoft.WindowsCamera')
    'Clipchamp' = @('Clipchamp.Clipchamp','Clipchamp')
    'Copilot' = @('Microsoft.Copilot','Microsoft.Windows.Copilot')
    'Cross Device Experience Host' = @('MicrosoftWindows.CrossDevice')
    'Dev Home' = @('Microsoft.Windows.DevHome','Microsoft.DevHome')
    'Feedback Hub' = @('Microsoft.WindowsFeedbackHub')
    'Game Assist (Edge)' = @('Microsoft.Edge.GameAssist')
    'Game Bar' = @('Microsoft.XboxGamingOverlay')
    'Gaming' = @('Microsoft.GamingApp','Microsoft.GamingServices')
    'Get Help' = @('Microsoft.GetHelp')
    'HP Easy Clean' = @('AD2F1837.HPEasyClean')
    'HP Support Desktop Utilities' = @('AD2F1837.HPDesktopSupportUtilities')
    'HP System Information' = @('AD2F1837.HPSystemInformation','9MTKLT3PWWN1')
    'Microsoft 365' = @('Microsoft.MicrosoftOfficeHub')
    'Music' = @('Microsoft.ZuneMusic')
    'Phone Link' = @('Microsoft.YourPhone')
    'Power Automate' = @('Microsoft.PowerAutomate','Microsoft.PowerAutomateDesktop')
    'Solitaire' = @('Microsoft.MicrosoftSolitaireCollection')
    'Sound Recorder' = @('Microsoft.WindowsSoundRecorder')
    'To Do' = @('Microsoft.Todos')
    'Video' = @('Microsoft.ZuneVideo')
    'Xbox' = @('Microsoft.XboxApp','Microsoft.XboxGamingOverlay','Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay','Microsoft.Xbox.TCUI','Microsoft.XboxGameOverlay')
}
$OutlookNames = @('Microsoft.OutlookForWindows')
$TeamsNames = @('MicrosoftTeams','MSTeams','MicrosoftTeamsClassic')

# Detection is performed by Get-AppxPackage in the interactive user's own context.
try {
    $inventory = Invoke-InteractiveWorker -Payload @{ Mode='Detect' } -Activity 'Checking for apps'
} catch {
    Write-Host " ✗ Could not check apps: $($_.Exception.Message)" -ForegroundColor Red
    return
}
if (-not $inventory.Success) {
    Write-Host " ✗ Could not check apps: $($inventory.Error)" -ForegroundColor Red
    return
}
$packages = @($inventory.Packages)
$Targets = [ordered]@{}
foreach ($appName in $Apps.Keys) {
    $found = @($packages | Where-Object { $_.Name -in $Apps[$appName] })
    if ($found.Count -gt 0) { $Targets[$appName] = $found }
}
$outlook = @($packages | Where-Object { $_.Name -in $OutlookNames })
$teams = @($packages | Where-Object { $_.Name -in $TeamsNames })
$DetectedApps = @($Targets.Keys | Sort-Object)

Write-Host " $($DetectedApps.Count) app(s) found." -ForegroundColor Green

# OneDrive: uninstall and verify within the same interactive worker process.
if ($inventory.OneDriveInstalled -and (Confirm-Action 'Uninstall OneDrive? [Y]es / [N]o:')) {
    try {
        $r = Invoke-InteractiveWorker -Payload @{ Mode='OneDrive' } -Activity 'Uninstalling OneDrive'
        if ($r.Success) { Write-Host 'Uninstalling OneDrive... ✓ Done.' -ForegroundColor Green }
        else { Write-Host "Uninstalling OneDrive... ✗ Couldn't uninstall. $($r.Error)" -ForegroundColor Red }
    } catch {
        Write-Host "Uninstalling OneDrive... ✗ Couldn't uninstall. $($_.Exception.Message)" -ForegroundColor Red
    }
}

# New Outlook: AppX removal plus verification in one worker process.
if ($outlook.Count -gt 0 -and (Confirm-Action 'Uninstall Outlook? [Y]es / [N]o:')) {
    try {
        $r = Invoke-InteractiveWorker -Payload @{ Mode='Appx'; PackageNames=$OutlookNames } -Activity 'Uninstalling Outlook'
        if ($r.Success) { Write-Host 'Uninstalling Outlook... ✓ Done.' -ForegroundColor Green }
        else { Write-Host "Uninstalling Outlook... ✗ Couldn't uninstall." -ForegroundColor Red }
    } catch {
        Write-Host "Uninstalling Outlook... ✗ Couldn't uninstall. $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Remaining applications: preserve the original application list and confirm-before-removal flow.
if ($DetectedApps.Count -gt 0 -and (Confirm-Action 'Uninstall other apps? [Y]es / [N]o:')) {
    $namesToRemove = @($Targets.Keys | ForEach-Object { $Apps[$_] } | Select-Object -Unique)
    try {
        $r = Invoke-InteractiveWorker -Payload @{ Mode='Appx'; PackageNames=$namesToRemove } -Activity 'Uninstalling apps'
        if ($r.Success) { Write-Host 'Uninstalling apps... ✓ Done.' -ForegroundColor Green }
        else {
            Write-Host 'Uninstalling apps... ✗ Couldn''t uninstall.' -ForegroundColor Red
            if ($r.Remaining) { Write-Host ("Still installed: " + ($r.Remaining -join ', ')) -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "Uninstalling apps... ✗ Couldn't uninstall. $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Teams: retain its separate prompt and verification.
if ($teams.Count -gt 0 -and (Confirm-Action 'Uninstall Teams? [Y]es / [N]o:')) {
    try {
        $r = Invoke-InteractiveWorker -Payload @{ Mode='Appx'; PackageNames=$TeamsNames } -Activity 'Uninstalling Teams'
        if ($r.Success) { Write-Host 'Uninstalling Teams... ✓ Done.' -ForegroundColor Green }
        else { Write-Host 'Uninstalling Teams... ✗ Couldn''t uninstall.' -ForegroundColor Red }
    } catch {
        Write-Host "Uninstalling Teams... ✗ Couldn't uninstall. $($_.Exception.Message)" -ForegroundColor Red
    }
}

Remove-Item -LiteralPath $workerPath -Force -ErrorAction SilentlyContinue
Write-Host 'Have a great rest of your day!'
Write-Host ''
