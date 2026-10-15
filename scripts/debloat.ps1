
# Relaunch as administrator when needed
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host 'Administrator privileges are required. Requesting elevation...' -ForegroundColor Yellow

    $scriptUrl = 'https://wr.dallasrevolt.workers.dev/debloat'
    $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $bootstrap = "`$ErrorActionPreference = 'Stop'; `$code = Invoke-RestMethod -Uri '$scriptUrl'; & ([ScriptBlock]::Create(`$code))"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

    try {
        Start-Process -FilePath $shell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-EncodedCommand', $encodedCommand) -ErrorAction Stop
    }
    catch {
        Write-Host 'Elevation was cancelled or could not be started.' -ForegroundColor Red
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

<#
# Check administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Run PowerShell as Administrator.' -ForegroundColor Red
    return
}
#>

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

# Display detection results
Write-Host ''
Write-Host 'Checking for apps:' -NoNewline

if ($Targets.Count -eq 0) {
    Write-Host ' ✗ No apps found.' -ForegroundColor Red
} else {
    Write-Host " ✓ $($Targets.Count) app(s) found:" -ForegroundColor Green
    foreach ($appName in $Targets.Keys) {
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

        foreach ($package in $allPackages) {
            $i++
            $percent = [int](100 * $i / $total)

            Write-Progress -Activity 'Uninstalling apps' -Status "$i of $total" -PercentComplete $percent

            try {
                Remove-AppxPackage -Package $package.PackageFullName -User $sid -ErrorAction Stop
            } catch {
                # Final verification determines whether removal succeeded.
            }
        }

        Write-Progress -Activity 'Uninstalling apps' -Completed
        Write-Host 'Uninstalling: ✓ Done!'

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
if (Test-Path $oneDriveExe) {
    if (Confirm-Action 'Uninstall OneDrive? [Y]es / [N]o') {
        Write-Host "OneDrive removal was not attempted: it must run in the target user's context." -ForegroundColor Yellow
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
