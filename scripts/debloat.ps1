# Relaunch as administrator when needed
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $scriptUrl = 'https://helper.dallasrevolt.workers.dev/debloat'

    # Use Windows PowerShell 5.1 only
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $shell)) {
        throw 'Windows PowerShell 5.1 was not found.'
    }

    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
try {
    `$response = Invoke-WebRequest -Uri '$scriptUrl' -UseBasicParsing -ErrorAction Stop
    `$code = `$response.Content

    if ([string]::IsNullOrWhiteSpace(`$code) -or `$code -match '(?is)^\s*(<!doctype html|<html|error code:\s*\d+|not found\b)') {
        throw 'The endpoint did not return a valid PowerShell script.'
    }

    & ([ScriptBlock]::Create(`$code))
}
catch {
    Write-Host "Failed to download or run the script: `$(`$_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check the Cloudflare Worker route and GitHub file path.' -ForegroundColor Yellow
}
"@

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-EncodedCommand', $encodedCommand)
    $terminal = Get-Command wt.exe -ErrorAction SilentlyContinue

    try {
        if ($terminal) {
            Start-Process -FilePath $terminal.Source -Verb RunAs -ArgumentList (@('-w', 'new', $shell) + $arguments) -ErrorAction Stop
        } else {
            Start-Process -FilePath $shell -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
        }
    }
    catch {
        Write-Host "Could not start the elevated console: $($_.Exception.Message)" -ForegroundColor Red
    }

    return
}

Clear-Host
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# --------------------------------------------------
# Input and terminal progress helpers
# --------------------------------------------------

function Confirm-Action {
    param([string]$Message)

    do {
        $answer = (Read-Host $Message).Trim()
    } while ($answer -notmatch '^[YyNn]$')

    return ($answer -match '^[Yy]$')
}

$script:ProgressLineLength = 0

function Write-TerminalProgress {
    param(
        [string]$Activity,
        [int]$Current,
        [int]$Total,
        [int]$Width = 16
    )

    if ($Total -lt 1) {
        $Total = 1
    }

    $percent = [int][Math]::Floor(100 * $Current / $Total)
    $percent = [Math]::Max(0, [Math]::Min(100, $percent))
    $filled = [int][Math]::Floor($Width * $percent / 100)
    $bar = ('█' * $filled) + ('░' * ($Width - $filled))
    $line = '{0}:  {1} {2}%' -f $Activity, $bar, $percent

    $padding = [Math]::Max(0, $script:ProgressLineLength - $line.Length)
    [Console]::Write("`r" + $line + (' ' * $padding) + "`r")

    $script:ProgressLineLength = [Math]::Max($script:ProgressLineLength, $line.Length)
}

function Complete-TerminalProgress {
    param(
        [string]$Activity,
        [string]$Result,
        [ConsoleColor]$Color = [ConsoleColor]::Green
    )

    $line = '{0}: {1}' -f $Activity, $Result
    $padding = [Math]::Max(0, $script:ProgressLineLength - $line.Length)

    Write-Host ("`r" + $line + (' ' * $padding)) -ForegroundColor $Color
    $script:ProgressLineLength = 0
}

# --------------------------------------------------
# Identify the interactive user
# --------------------------------------------------

$session = (Get-Process -Id $PID).SessionId
$explorers = @(
    Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" |
        Where-Object { $_.SessionId -eq $session }
)

$sids = @(
    foreach ($explorer in $explorers) {
        try {
            (Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid -ErrorAction Stop).Sid
        } catch {}
    }
)

$sids = @($sids | Where-Object { $_ } | Select-Object -Unique)

if ($sids.Count -ne 1) {
    Write-Host 'Could not identify the interactive user.' -ForegroundColor Red
    return
}

$sid = $sids[0]

$profileInfo = Get-CimInstance Win32_UserProfile |
    Where-Object { $_.SID -eq $sid } |
    Select-Object -First 1

$profile = $profileInfo.LocalPath

if (-not $profile) {
    Write-Host 'Could not locate the interactive user profile.' -ForegroundColor Red
    return
}

# --------------------------------------------------
# Application definitions
# Special apps are deliberately excluded from $Apps
# --------------------------------------------------

$Apps = [ordered]@{
    'Alarms' = @('Microsoft.WindowsAlarms')
    'Bing' = @('Microsoft.BingNews', 'Microsoft.BingSearch', 'Microsoft.BingWeather')
    'Camera' = @('Microsoft.WindowsCamera')
    'Clipchamp' = @('Clipchamp.Clipchamp', 'Clipchamp')
    'Copilot' = @('Microsoft.Copilot', 'Microsoft.Windows.Copilot')
    'Cross Device Experience Host' = @('MicrosoftWindows.CrossDevice')
    'Dev Home' = @('Microsoft.Windows.DevHome', 'Microsoft.DevHome')
    'Feedback Hub' = @('Microsoft.WindowsFeedbackHub')
    'Game Assist (Edge)' = @('Microsoft.Edge.GameAssist')
    'Game Bar' = @('Microsoft.XboxGamingOverlay')
    'Gaming' = @('Microsoft.GamingApp', 'Microsoft.GamingServices')
    'Get Help' = @('Microsoft.GetHelp')
    'HP Easy Clean' = @('AD2F1837.HPEasyClean')
    'HP Support Desktop Utilities' = @('AD2F1837.HPDesktopSupportUtilities')
    'HP System Information' = @('AD2F1837.HPSystemInformation', '9MTKLT3PWWN1')
    'Microsoft 365' = @('Microsoft.MicrosoftOfficeHub')
    'Music' = @('Microsoft.ZuneMusic')
    'Phone Link' = @('Microsoft.YourPhone')
    'Power Automate' = @('Microsoft.PowerAutomate', 'Microsoft.PowerAutomateDesktop')
    'Solitaire' = @('Microsoft.MicrosoftSolitaireCollection')
    'Sound Recorder' = @('Microsoft.WindowsSoundRecorder')
    'To Do' = @('Microsoft.Todos')
    'Video' = @('Microsoft.ZuneVideo')
    'Xbox' = @(
        'Microsoft.XboxApp',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxGameOverlay'
    )
}

$OutlookNames = @('Microsoft.OutlookForWindows')
$TeamsNames = @('MicrosoftTeams', 'MSTeams', 'MicrosoftTeamsClassic')

# --------------------------------------------------
# Detect applications for the target user
# --------------------------------------------------

try {
    $packages = @(Get-AppxPackage -User $sid -ErrorAction Stop)
}
catch {
    Write-Host "Could not query applications for the target user: $($_.Exception.Message)" -ForegroundColor Red
    return
}

$Targets = [ordered]@{}

foreach ($appName in $Apps.Keys) {
    $found = @($packages | Where-Object { $_.Name -in $Apps[$appName] })

    if ($found.Count -gt 0) {
        $Targets[$appName] = $found
    }
}

$outlook = @($packages | Where-Object { $_.Name -in $OutlookNames })
$teams = @($packages | Where-Object { $_.Name -in $TeamsNames })

# OneDrive detection for the target user's profile
$oneDriveRoot = Join-Path $profile 'AppData\Local\Microsoft\OneDrive'
$oneDriveExe = Join-Path $oneDriveRoot 'OneDrive.exe'

$targetUninstallPath = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
$targetUninstallWowPath = "Registry::HKEY_USERS\$sid\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"

$oneDriveEntries = @(
    Get-ItemProperty -Path $targetUninstallPath, $targetUninstallWowPath -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^(Microsoft )?OneDrive$' }
)

$oneDriveDetected = (Test-Path -LiteralPath $oneDriveExe) -or ($oneDriveEntries.Count -gt 0)

# --------------------------------------------------
# Normal applications: alphabetical list and count
# --------------------------------------------------

$DetectedApps = @($Targets.Keys | Sort-Object)

Write-Host ''
Write-Host 'Checking for apps:' -NoNewline

if ($DetectedApps.Count -eq 0) {
    Write-Host ' ✗ No apps found!' -ForegroundColor Red
}
else {
    Write-Host " ✓ $($DetectedApps.Count) app(s) found:" -ForegroundColor Green

    foreach ($appName in $DetectedApps) {
        Write-Host "- $appName"
    }

    if (Confirm-Action 'Uninstall apps? [Y]es / [N]o') {
        $allPackages = @(
            $Targets.Values |
                ForEach-Object { $_ } |
                Sort-Object -Property PackageFullName -Unique
        )

        $total = $allPackages.Count
        $i = 0
        $uninstallFailed = $false

        foreach ($package in $allPackages) {
            Write-TerminalProgress -Activity 'Uninstalling apps' -Current $i -Total $total
        
            try {
                Remove-AppxPackage -Package $package.PackageFullName -User $sid -ErrorAction Stop
            }
            catch {
                $uninstallFailed = $true
                Write-Host "`nFailed to uninstall $($package.Name): $($_.Exception.Message)" -ForegroundColor Red
            }
        
            $i++
            Write-TerminalProgress -Activity 'Uninstalling apps' -Current $i -Total $total
        }

        if ($uninstallFailed) {
            Complete-TerminalProgress -Activity 'Uninstalling apps' -Result '✗ Apps NOT uninstalled!' -Color Red
        }
        else {
            Complete-TerminalProgress -Activity 'Uninstalling apps' -Result '✓ Done!'

            # Verify only when the uninstall commands reported no errors
            try {
                $remaining = @(Get-AppxPackage -User $sid -ErrorAction Stop)
                $notRemoved = @()
                $verifyNames = @($Targets.Keys | Sort-Object)
                $verifyTotal = $verifyNames.Count
                $verifyIndex = 0

                foreach ($appName in $verifyNames) {
                    Write-TerminalProgress -Activity 'Verifying removal' -Current $verifyIndex -Total $verifyTotal
                
                    $left = @($remaining | Where-Object { $_.Name -in $Apps[$appName] })
                
                    if ($left.Count -gt 0) {
                        $notRemoved += $appName
                    }
                
                    $verifyIndex++
                    Write-TerminalProgress -Activity 'Verifying removal' -Current $verifyIndex -Total $verifyTotal
                }

                if ($notRemoved.Count -gt 0) {
                    Complete-TerminalProgress -Activity 'Verifying removal' -Result '✗ Verification error!' -Color Red

                    foreach ($name in ($notRemoved | Select-Object -Unique)) {
                        Write-Host "- Still installed: $name" -ForegroundColor Yellow
                    }
                }
                else {
                    Complete-TerminalProgress -Activity 'Verifying removal' -Result '✓ Done!'
                }
            }
            catch {
                Complete-TerminalProgress -Activity 'Verifying removal' -Result '✗ Verification error!' -Color Red
                Write-Host $_.Exception.Message -ForegroundColor Yellow
            }
        }
    }
}

# --------------------------------------------------
# OneDrive: separate detection, removal and verification
# --------------------------------------------------

if ($oneDriveDetected) {
    if (Confirm-Action 'OneDrive detected. Uninstall it? [Y]es / [N]o') {
        $setupPath = $null

        # Prefer the uninstaller registered for this user
        foreach ($entry in $oneDriveEntries) {
            $candidate = $null

            if ($entry.UninstallString -match '^\s*"([^"]+)"') {
                $candidate = $Matches[1]
            }
            elseif ($entry.UninstallString -match '^\s*(.+?\.exe)\b') {
                $candidate = $Matches[1].Trim('"')
            }

            if ($candidate -and (Test-Path -LiteralPath $candidate)) {
                $setupPath = $candidate
                break
            }
        }

        # Fallback: search the target user's OneDrive directory
        if (-not $setupPath -and (Test-Path -LiteralPath $oneDriveRoot)) {
            $setup = Get-ChildItem -LiteralPath $oneDriveRoot -Filter 'OneDriveSetup.exe' -File -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if ($setup) {
                $setupPath = $setup.FullName
            }
        }

        if (-not $setupPath) {
            Write-Host 'Uninstalling OneDrive: ✗ App NOT uninstalled! Uninstaller not found.' -ForegroundColor Red
        }
        else {
            try {
                Write-TerminalProgress -Activity 'Uninstalling OneDrive' -Current 0 -Total 1

                $process = Start-Process -FilePath $setupPath -ArgumentList '/uninstall' -Wait -PassThru -ErrorAction Stop

                Write-TerminalProgress -Activity 'Uninstalling OneDrive' -Current 1 -Total 1

                if ($process.ExitCode -ne 0) {
                    Complete-TerminalProgress -Activity 'Uninstalling OneDrive' -Result "✗ App NOT uninstalled! Exit code: $($process.ExitCode)" -Color Red
                }
                else {
                    Complete-TerminalProgress -Activity 'Uninstalling OneDrive' -Result '✓ Done!'

                    # Verify the target user's executable and uninstall registration
                    try {
                        Write-TerminalProgress -Activity 'Verifying OneDrive removal' -Current 0 -Total 1
                        Start-Sleep -Seconds 2

                        $remainingOneDriveEntries = @(
                            Get-ItemProperty -Path $targetUninstallPath, $targetUninstallWowPath -ErrorAction SilentlyContinue |
                                Where-Object { $_.DisplayName -match '^(Microsoft )?OneDrive$' }
                        )

                        $oneDriveStillExists = (Test-Path -LiteralPath $oneDriveExe) -or ($remainingOneDriveEntries.Count -gt 0)

                        Write-TerminalProgress -Activity 'Verifying OneDrive removal' -Current 1 -Total 1

                        if ($oneDriveStillExists) {
                            Complete-TerminalProgress -Activity 'Verifying OneDrive removal' -Result '✗ Verification error!' -Color Red
                        }
                        else {
                            Complete-TerminalProgress -Activity 'Verifying OneDrive removal' -Result '✓ Done!'
                        }
                    }
                    catch {
                        Complete-TerminalProgress -Activity 'Verifying OneDrive removal' -Result '✗ Verification error!' -Color Red
                        Write-Host $_.Exception.Message -ForegroundColor Yellow
                    }
                }
            }
            catch {
                Complete-TerminalProgress -Activity 'Uninstalling OneDrive' -Result '✗ App NOT uninstalled!' -Color Red
                Write-Host $_.Exception.Message -ForegroundColor Yellow
            }
        }
    }
}

# --------------------------------------------------
# Outlook and Teams: separate Appx removal workflow
# --------------------------------------------------

function Invoke-SpecialAppxRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$PackageNames,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$FoundPackages,
        [Parameter(Mandatory = $true)][string]$UserSid
    )

    if ($FoundPackages.Count -eq 0) {
        return
    }

    if (-not (Confirm-Action "$Name detected. Uninstall it? [Y]es / [N]o")) {
        return
    }

    $failed = $false
    $total = $FoundPackages.Count
    $i = 0

    foreach ($package in $FoundPackages) {
        try {
            Remove-AppxPackage -Package $package.PackageFullName -User $UserSid -ErrorAction Stop
        }
        catch {
            $failed = $true
            Write-Host "`nFailed to uninstall $Name ($($package.Name)): $($_.Exception.Message)" -ForegroundColor Red
        }

        $i++
        Write-TerminalProgress -Activity "Uninstalling $Name" -Current $i -Total $total
    }

    if ($failed) {
        Complete-TerminalProgress -Activity "Uninstalling $Name" -Result '✗ App NOT uninstalled!' -Color Red
        return
    }

    Complete-TerminalProgress -Activity "Uninstalling $Name" -Result '✓ Done!'

    # Do not verify if an uninstall command reported an error
    try {
        Write-TerminalProgress -Activity "Verifying $Name removal" -Current 0 -Total 1

        $remaining = @(
            Get-AppxPackage -User $UserSid -ErrorAction Stop |
                Where-Object { $_.Name -in $PackageNames }
        )

        Write-TerminalProgress -Activity "Verifying $Name removal" -Current 1 -Total 1

        if ($remaining.Count -gt 0) {
            Complete-TerminalProgress -Activity "Verifying $Name removal" -Result '✗ Verification error!' -Color Red
        }
        else {
            Complete-TerminalProgress -Activity "Verifying $Name removal" -Result '✓ Done!'
        }
    }
    catch {
        Complete-TerminalProgress -Activity "Verifying $Name removal" -Result '✗ Verification error!' -Color Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }
}

# Process special apps in the requested order
if ($outlook.Count -gt 0) {
    Invoke-SpecialAppxRemoval -Name 'New Outlook' -PackageNames $OutlookNames -FoundPackages $outlook -UserSid $sid
}

if ($teams.Count -gt 0) {
    Invoke-SpecialAppxRemoval -Name 'Teams' -PackageNames $TeamsNames -FoundPackages $teams -UserSid $sid
}

Write-Host 'Have a great rest of your day!'
Write-Host ''

<#
# Relaunch as administrator when needed
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $scriptUrl = 'https://helper.dallasrevolt.workers.dev/debloat'

    # Use PowerShell 5 only
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $shell)) {
        throw 'Windows PowerShell 5.1 was not found.'
    }

    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
try {
    `$response = Invoke-WebRequest -Uri '$scriptUrl' -UseBasicParsing -ErrorAction Stop
    `$code = `$response.Content

    if ([string]::IsNullOrWhiteSpace(`$code) -or `$code -match '(?is)^\s*(<!doctype html|<html|error code:\s*\d+|not found\b)') {
        throw 'The endpoint did not return a valid PowerShell script.'
    }

    & ([ScriptBlock]::Create(`$code))
}
catch {
    Write-Host "Failed to download or run the script: `$(`$_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check the Cloudflare Worker route and GitHub file path.' -ForegroundColor Yellow
}
"@

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-EncodedCommand', $encodedCommand)

    $terminal = Get-Command wt.exe -ErrorAction SilentlyContinue

    try {
        if ($terminal) {
            Start-Process -FilePath $terminal.Source -Verb RunAs -ArgumentList (@('-w', 'new', $shell) + $arguments) -ErrorAction Stop
        } else {
            Start-Process -FilePath $shell -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
        }
    }
    catch {
        Write-Host "Could not start the elevated console: $($_.Exception.Message)" -ForegroundColor Red
    }

    return
}

Clear-Host

$ErrorActionPreference = 'Stop'

function Confirm-Action {
    param([string]$Message)
    do {
        $answer = (Read-Host $Message).Trim()
    } while ($answer -notmatch '^[YyNn]$')
    return ($answer -match '^[Yy]$')
}

# Identify the interactive user in the current Windows session
$session = (Get-Process -Id $PID).SessionId
$explorers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -eq $session })
$sids = @(
    foreach ($explorer in $explorers) {
        try {
            (Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid -ErrorAction Stop).Sid
        } catch {}
    }
)

$sids = @($sids | Where-Object { $_ } | Select-Object -Unique)

if ($sids.Count -ne 1) {
    Write-Host 'Could not identify the interactive user.' -ForegroundColor Red
    return
}

$sid = $sids[0]
$profile = (Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $sid } | Select-Object -First 1).LocalPath

if (-not $profile) {
    Write-Host 'Could not locate the interactive user profile.' -ForegroundColor Red
    return
}

# App names and their corresponding Appx package names
$Apps = [ordered]@{
    'Alarms' = @('Microsoft.WindowsAlarms')
    'Bing' = @('Microsoft.BingNews', 'Microsoft.BingSearch', 'Microsoft.BingWeather')
    'Camera' = @('Microsoft.WindowsCamera')
    'Clipchamp' = @('Clipchamp.Clipchamp', 'Clipchamp')
    'Copilot' = @('Microsoft.Copilot', 'Microsoft.Windows.Copilot')
    'Cross Device Experience Host' = @('MicrosoftWindows.CrossDevice')
    'Dev Home' = @('Microsoft.Windows.DevHome', 'Microsoft.DevHome')
    'Feedback Hub' = @('Microsoft.WindowsFeedbackHub')
    'Game Assist (Edge)' = @('Microsoft.Edge.GameAssist')
    'Game Bar' = @('Microsoft.XboxGamingOverlay')
    'Gaming' = @('Microsoft.GamingApp', 'Microsoft.GamingServices')
    'Get Help' = @('Microsoft.GetHelp')
    'HP Easy Clean' = @('AD2F1837.HPEasyClean')
    'HP Support Desktop Utilities' = @('AD2F1837.HPDesktopSupportUtilities')
    'HP System Information' = @('AD2F1837.HPSystemInformation', '9MTKLT3PWWN1')
    'Microsoft 365' = @('Microsoft.MicrosoftOfficeHub')
    'Music' = @('Microsoft.ZuneMusic')
    'Phone Link' = @('Microsoft.YourPhone')
    'Power Automate' = @('Microsoft.PowerAutomate', 'Microsoft.PowerAutomateDesktop')
    'Solitaire' = @('Microsoft.MicrosoftSolitaireCollection')
    'Sound Recorder' = @('Microsoft.WindowsSoundRecorder')
    'Teams' = @('MicrosoftTeams', 'MSTeams', 'MicrosoftTeamsClassic')
    'To Do' = @('Microsoft.Todos')
    'Video' = @('Microsoft.ZuneVideo')
    'Xbox' = @('Microsoft.XboxApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxGameOverlay')
}

$OutlookNames = @('Microsoft.OutlookForWindows')
$packages = @(Get-AppxPackage -User $sid)
$Targets = [ordered]@{}

foreach ($appName in $Apps.Keys) {
    $found = @($packages | Where-Object { $_.Name -in $Apps[$appName] })
    if ($found.Count -gt 0) {
        $Targets[$appName] = $found
    }
}

$outlook = @($packages | Where-Object { $_.Name -in $OutlookNames })
$oneDriveExe = Join-Path $profile 'AppData\Local\Microsoft\OneDrive\OneDrive.exe'

# Build a unified list of detected apps
$DetectedApps = @()

foreach ($appName in $Targets.Keys) {
    $DetectedApps += $appName
}

if ($outlook.Count -gt 0 -and $DetectedApps -notcontains 'New Outlook') {
    $DetectedApps += 'New Outlook'
}

if (Test-Path -LiteralPath $oneDriveExe) {
    $DetectedApps += 'OneDrive'
}

# Display detection results
Write-Host ''
Write-Host 'Checking for apps:' -NoNewline

if ($DetectedApps.Count -eq 0) {
    Write-Host ' ✗ No apps found.' -ForegroundColor Red
} else {
    Write-Host " ✓ $($DetectedApps.Count) app(s) found:" -ForegroundColor Green

    foreach ($appName in $DetectedApps) {
        Write-Host "- $appName"
    }

    if ($Targets.Count -gt 0 -and (Confirm-Action 'Uninstall apps? [Y]es / [N]o')) {
        $allPackages = @(
            $Targets.Values |
                ForEach-Object { $_ } |
                Sort-Object -Property PackageFullName -Unique
        )

        $total = $allPackages.Count
        $i = 0

        foreach ($package in $allPackages) {
            $i++
            $percent = [int](100 * $i / $total)

            Write-Progress -Activity 'Uninstalling apps' -Status "$i of $total" -PercentComplete $percent

            try {
                Remove-AppxPackage -Package $package.PackageFullName -User $sid -ErrorAction Stop
            } catch {
                Write-Host "Failed to uninstall $($package.Name): $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        Write-Progress -Activity 'Uninstalling apps' -Completed

        # Verify removal against the target user's package list
        Write-Host 'Verifying:' -NoNewline
        $remaining = @(Get-AppxPackage -User $sid)
        $notRemoved = @()

        foreach ($appName in $Targets.Keys) {
            $left = @($remaining | Where-Object { $_.Name -in $Apps[$appName] })
            if ($left.Count -gt 0) {
                $notRemoved += $appName
            }
        }

        if ($notRemoved.Count -gt 0) {
            Write-Host ' ✗ App(s) not removed:' -ForegroundColor Red
            $notRemoved | Select-Object -Unique | ForEach-Object {
                Write-Host "- $_" -ForegroundColor Red
            }
        } else {
            Write-Host ' ✓ OK!' -ForegroundColor Green
        }
    }
}

# OneDrive: separate confirmation
if (Test-Path -LiteralPath $oneDriveExe) {
    if (Confirm-Action 'Uninstall OneDrive? [Y]es / [N]o') {
        $oneDriveSetup = Get-ChildItem -LiteralPath (Join-Path $profile 'AppData\Local\Microsoft\OneDrive') -Filter 'OneDriveSetup.exe' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1

        if ($oneDriveSetup) {
            try {
                Write-Host 'Uninstalling OneDrive...' -ForegroundColor Cyan
                $process = Start-Process -FilePath $oneDriveSetup.FullName -ArgumentList '/uninstall' -Wait -PassThru -ErrorAction Stop
                Start-Sleep -Seconds 2

                if (-not (Test-Path -LiteralPath $oneDriveExe)) {
                    Write-Host '✓ OneDrive removed and verified.' -ForegroundColor Green
                } else {
                    Write-Host "OneDrive removal could not be verified (exit code: $($process.ExitCode))." -ForegroundColor Yellow
                }
            } catch {
                Write-Host "OneDrive removal failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host 'OneDrive uninstaller was not found in the target user profile.' -ForegroundColor Yellow
        }
    }
}

# New Outlook: separate confirmation and verification
if ($outlook.Count -gt 0) {
    if (Confirm-Action 'Uninstall New Outlook? [Y]es / [N]o') {
        foreach ($package in $outlook) {
            try {
                Remove-AppxPackage -Package $package.PackageFullName -User $sid -ErrorAction Stop
            } catch {
                # Verify the actual result below.
            }
        }

        $remainingOutlook = @(
            Get-AppxPackage -User $sid |
                Where-Object { $_.Name -in $OutlookNames }
        )

        if ($remainingOutlook.Count -gt 0) {
            Write-Host '✗ New Outlook was not completely removed.' -ForegroundColor Red
        } else {
            Write-Host '✓ New Outlook removed and verified.' -ForegroundColor Green
        }
    }
}

Write-Host 'Have a great rest of your day!'
Write-Host ''

#>
