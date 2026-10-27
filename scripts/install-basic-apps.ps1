$ErrorActionPreference = "Continue"

# Relaunch as administrator if needed.
$isAdmin = ([Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $url = "https://helper.diegolascano.dev/apps"

    $shellCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue

    if (-not $shellCommand) {
        $shellCommand = Get-Command powershell.exe -ErrorAction Stop
    }

    $shell = $shellCommand.Source

    $command = @"
`$ErrorActionPreference = 'Stop'

try {
    `$response = Invoke-WebRequest -Uri '$url' -UseBasicParsing -ErrorAction Stop
    `$code = `$response.Content

    if ([string]::IsNullOrWhiteSpace(`$code) -or
        `$code -match '(?is)^\s*(<!doctype html|<html|error code:\s*\d+|not found\b)') {
        throw 'The endpoint did not return a valid PowerShell script.'
    }

    Clear-Host & ([ScriptBlock]::Create(`$code))
}
catch {
    Write-Host "Failed to download or run the script: `$(`$_.Exception.Message)" -ForegroundColor Red
}
"@

    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($command)
    )

    try {
        Start-Process -FilePath $shell `
            -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -EncodedCommand $encoded" `
            -ErrorAction Stop
    }
    catch {
        Write-Host "✗ Elevation cancelled or failed." -ForegroundColor Red
    }

    return
}

Clear-Host

$apps = @(
    "Adobe.Acrobat.Reader.64-bit"
    "AnyDesk.AnyDesk"
    "Google.Chrome"
    "Mozilla.Firefox.es-MX"
    "Mozilla.Thunderbird.es-MX"
    "ONLYOFFICE.DesktopEditors"
    "Oracle.JavaRuntimeEnvironment"
    "RARLab.WinRAR"
    "VideoLAN.VLC"
    "voidtools.Everything"
)

while ($true) {
    $answer = (Read-Host "Install basic apps? [Y]es / [N]o").Trim()

    if ($answer -match '^(y|yes)$') {
        break
    }

    if ($answer -match '^(n|no)$') {
        return
    }
}

if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Write-Host "`n✗ Couldn't install all apps: WinGet not found." `
        -ForegroundColor Red
    return
}


Write-Host "`nChecking WinGet source..." -NoNewline

& winget.exe search --id Google.Chrome --exact --source winget --disable-interactivity *> $null
$sourceExitCode = $LASTEXITCODE

if ($sourceExitCode -ne 0) {
    Write-Host "`nRefreshing WinGet source..." -ForegroundColor Yellow

    try {
        Add-AppxPackage `
            -RegisterByFamilyName `
            -MainPackage Microsoft.Winget.Source_8wekyb3d8bbwe `
            -ErrorAction Stop
    }
    catch {
        Write-Host "Source registration: $($_.Exception.Message)" `
            -ForegroundColor Yellow
    }

    & winget.exe source update --name winget --disable-interactivity *> $null

    & winget.exe search --id Google.Chrome --exact --source winget --disable-interactivity *> $null
    $sourceExitCode = $LASTEXITCODE
}

if ($sourceExitCode -ne 0) {
    Write-Host "`r✗ WinGet source unavailable. Installation cancelled." `
        -ForegroundColor Red
    return
}

Write-Host "`rChecking WinGet source... ✓ Ready.       " `
    -ForegroundColor Green

$failed = @()
$skipped = 0
$frames = @('/', '-', '\', '|')
$frame = 0

Write-Host ""

foreach ($app in $apps) {
    $listOutput = & winget list `
        --id $app `
        --exact `
        --source winget `
        --accept-source-agreements `
        --disable-interactivity 2>&1 | Out-String

    if ($listOutput -match [regex]::Escape($app)) {
        $skipped++
        continue
    }

    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    $process = $null

    try {
        $arguments = @(
            "install"
            "--id"
            $app
            "--exact"
            "--source"
            "winget"
            "--silent"
            "--force"
            "--scope"
            "machine"
            "--accept-package-agreements"
            "--accept-source-agreements"
            "--disable-interactivity"
        )

        $process = Start-Process `
            -FilePath "winget.exe" `
            -ArgumentList $arguments `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr `
            -NoNewWindow `
            -PassThru

        while ($true) {
            $process.Refresh()

            if ($process.HasExited) {
                break
            }

            Write-Host -NoNewline (
                "`rInstalling... {0} " -f $frames[$frame]
            ) -ForegroundColor Cyan

            $frame = ($frame + 1) % $frames.Count
            Start-Sleep -Milliseconds 120
        }

        $process.WaitForExit()

        if ($process.ExitCode -ne 0) {
            $failed += "$app (exit code: $($process.ExitCode))"
        }
    }
    catch {
        $failed += "$app ($($_.Exception.Message))"
    }
    finally {
        Remove-Item $stdout, $stderr `
            -Force -ErrorAction SilentlyContinue
    }
}

if ($failed.Count -eq 0) {
    Write-Host "`rInstalling... ✓ Done!                 " `
        -ForegroundColor Green
    Write-Host ""

    if ($skipped -gt 0) {
        Write-Host "$skipped app(s) already installed; skipped." `
            -ForegroundColor Gray
    }

    Write-Host "Have a great rest of your day!" `
        -ForegroundColor Yellow
}
else {
    Write-Host "`rInstalling... ✗ Couldn't install all apps:" `
        -ForegroundColor Red

    foreach ($app in $failed) {
        Write-Host "  - $app" -ForegroundColor Red
    }

    if ($skipped -gt 0) {
        Write-Host "$skipped app(s) already installed; skipped." `
            -ForegroundColor Gray
    }
}

Write-Host ''
