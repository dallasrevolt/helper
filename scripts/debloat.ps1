$ErrorActionPreference = 'Continue'

function Confirm-Action {
    param([string]$Prompt)
    while ($true) {
        $answer = (Read-Host "$Prompt [Y]es / [N]o").Trim()
        if ($answer -match '^(?i:y|yes)$') { return $true }
        if ($answer -match '^(?i:n|no)$') { return $false }
        Write-Host 'Please enter Y or N.' -ForegroundColor Yellow
    }
}

function Get-OneDriveState {
    $root = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive'
    $exe = Join-Path $root 'OneDrive.exe'
    $paths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = @(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^(Microsoft )?OneDrive$' })
    [pscustomobject]@{
        Root = $root
        Exe = $exe
        Entries = $entries
        Installed = ((Test-Path -LiteralPath $exe) -or $entries.Count -gt 0)
    }
}

function Find-OneDriveSetup {
    param($State)
    foreach ($entry in $State.Entries) {
        $u = [string]$entry.UninstallString
        if ($u -match '^\s*"([^"]+)"') { $candidate = $Matches[1] }
        elseif ($u -match '^\s*(.+?\.exe)(?:\s|$)') { $candidate = $Matches[1].Trim('"') }
        else { $candidate = $null }
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    if (Test-Path -LiteralPath $State.Root) {
        $setup = Get-ChildItem -LiteralPath $State.Root -Filter 'OneDriveSetup.exe' -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($setup) { return $setup.FullName }
    }
    return $null
}

function Remove-OneDrive {
    $before = Get-OneDriveState
    if (-not $before.Installed) {
        Write-Host 'OneDrive: ✓ Already uninstalled.'
        return
    }

    $setup = Find-OneDriveSetup $before
    if (-not $setup) {
        Write-Host 'OneDrive: ✗ Uninstaller not found.' -ForegroundColor Red
        return
    }

    Write-Host 'Uninstalling OneDrive...'
    try {
        $proc = Start-Process -FilePath $setup -ArgumentList '/uninstall' -PassThru -Wait -ErrorAction Stop
        $deadline = (Get-Date).AddSeconds(45)
        do {
            Start-Sleep -Seconds 1
            $after = Get-OneDriveState
        } while ($after.Installed -and (Get-Date) -lt $deadline)

        if (-not $after.Installed) {
            Write-Host 'OneDrive: ✓ Done.' -ForegroundColor Green
        } else {
            Write-Host "OneDrive: ✗ Couldn't uninstall (exit code $($proc.ExitCode))." -ForegroundColor Red
        }
    } catch {
        Write-Host "OneDrive: ✗ $($_.Exception.Message)" -ForegroundColor Red
    }
}

$Apps = @(
    @{ Name = 'Alarms'; Packages = @('Microsoft.WindowsAlarms') }
    @{ Name = 'Bing'; Packages = @('Microsoft.BingNews','Microsoft.BingSearch','Microsoft.BingWeather') }
    @{ Name = 'Camera'; Packages = @('Microsoft.WindowsCamera') }
    @{ Name = 'Clipchamp'; Packages = @('Clipchamp.Clipchamp','Clipchamp') }
    @{ Name = 'Copilot'; Packages = @('Microsoft.Copilot','Microsoft.Windows.Copilot') }
    @{ Name = 'Cross Device Experience Host'; Packages = @('MicrosoftWindows.CrossDevice') }
    @{ Name = 'Dev Home'; Packages = @('Microsoft.Windows.DevHome','Microsoft.DevHome') }
    @{ Name = 'Feedback Hub'; Packages = @('Microsoft.WindowsFeedbackHub') }
    @{ Name = 'Game Assist (Edge)'; Packages = @('Microsoft.Edge.GameAssist') }
    @{ Name = 'Game Bar'; Packages = @('Microsoft.XboxGamingOverlay') }
    @{ Name = 'Gaming'; Packages = @('Microsoft.GamingApp','Microsoft.GamingServices') }
    @{ Name = 'Get Help'; Packages = @('Microsoft.GetHelp') }
    @{ Name = 'HP Easy Clean'; Packages = @('AD2F1837.HPEasyClean') }
    @{ Name = 'HP Support Desktop Utilities'; Packages = @('AD2F1837.HPDesktopSupportUtilities') }
    @{ Name = 'HP System Information'; Packages = @('AD2F1837.HPSystemInformation','9MTKLT3PWWN1') }
    @{ Name = 'Microsoft 365'; Packages = @('Microsoft.MicrosoftOfficeHub') }
    @{ Name = 'Music'; Packages = @('Microsoft.ZuneMusic') }
    @{ Name = 'Phone Link'; Packages = @('Microsoft.YourPhone') }
    @{ Name = 'Power Automate'; Packages = @('Microsoft.PowerAutomate','Microsoft.PowerAutomateDesktop') }
    @{ Name = 'Solitaire'; Packages = @('Microsoft.MicrosoftSolitaireCollection') }
    @{ Name = 'Sound Recorder'; Packages = @('Microsoft.WindowsSoundRecorder') }
    @{ Name = 'To Do'; Packages = @('Microsoft.Todos') }
    @{ Name = 'Video'; Packages = @('Microsoft.ZuneVideo') }
    @{ Name = 'Xbox'; Packages = @('Microsoft.XboxApp','Microsoft.XboxGamingOverlay','Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay','Microsoft.XboxGameOverlay') }
)

$OutlookNames = @('Microsoft.OutlookForWindows')
$TeamsNames = @('MicrosoftTeams','MSTeams','MicrosoftTeamsClassic')

Write-Host 'Checking for apps...' -NoNewline
try {
    $installed = @(Get-AppxPackage -ErrorAction Stop)
} catch {
    Write-Host "`n✗ Could not check apps: $($_.Exception.Message)" -ForegroundColor Red
    return
}

$foundApps = @()
foreach ($app in $Apps) {
    if (@($installed | Where-Object { $_.Name -in $app.Packages }).Count -gt 0) {
        $foundApps += $app
    }
}
$outlookFound = @($installed | Where-Object { $_.Name -in $OutlookNames })
$teamsFound = @($installed | Where-Object { $_.Name -in $TeamsNames })
$oneDriveFound = (Get-OneDriveState).Installed
$total = $foundApps.Count + [int]($outlookFound.Count -gt 0) + [int]($teamsFound.Count -gt 0) + [int]$oneDriveFound

if ($total -eq 0) {
    Write-Host ' ✓ No apps found.'
    Write-Host 'Have a great rest of your day!'
    return
}
Write-Host " ✓ $total app(s) found."

if ($oneDriveFound -and (Confirm-Action 'Uninstall OneDrive?')) {
    Remove-OneDrive
}

if ($outlookFound.Count -gt 0 -and (Confirm-Action 'Uninstall Outlook?')) {
    foreach ($pkg in $outlookFound) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
        } catch {
            Write-Host "Outlook: ✗ $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    if (@(Get-AppxPackage | Where-Object { $_.Name -in $OutlookNames }).Count -eq 0) {
        Write-Host 'Outlook: ✓ Done.' -ForegroundColor Green
    } else {
        Write-Host "Outlook: ✗ Couldn't uninstall." -ForegroundColor Red
    }
}

if ($foundApps.Count -gt 0 -and (Confirm-Action 'Uninstall other apps?')) {
    $wanted = @($foundApps | ForEach-Object { $_.Packages } | Select-Object -Unique)
    $targets = @($installed | Where-Object { $_.Name -in $wanted })
    $errors = @()

    Write-Host 'Uninstalling apps...'
    foreach ($pkg in $targets) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
        } catch {
            $errors += "$($pkg.Name): $($_.Exception.Message)"
            Write-Host "  ✗ $($pkg.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $remaining = @(Get-AppxPackage | Where-Object { $_.Name -in $wanted })
    } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ($remaining.Count -eq 0 -and $errors.Count -eq 0) {
        Write-Host '✓ Done.' -ForegroundColor Green
    } else {
        foreach ($pkg in $remaining) {
            Write-Host "  ✗ Still installed: $($pkg.Name)" -ForegroundColor Red
        }
        Write-Host "✗ Some apps couldn't be removed." -ForegroundColor Red
    }
}

if ($teamsFound.Count -gt 0 -and (Confirm-Action 'Uninstall Teams?')) {
    foreach ($pkg in $teamsFound) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
        } catch {
            Write-Host "Teams: ✗ $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    if (@(Get-AppxPackage | Where-Object { $_.Name -in $TeamsNames }).Count -eq 0) {
        Write-Host 'Teams: ✓ Done.' -ForegroundColor Green
    } else {
        Write-Host "Teams: ✗ Couldn't uninstall." -ForegroundColor Red
    }
}

Write-Host 'Have a great rest of your day!'
