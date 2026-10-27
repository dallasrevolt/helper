$ErrorActionPreference = "Continue"

$apps = @(
    "Adobe.Acrobat.Reader.64-bit"
    "AnyDesk.AnyDesk"
    "Google.Chrome"
    "Mozilla.Firefox.es-MX"
    "Mozilla.Thunderbird.es-MX"
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

    Read-Host "Press Enter to return to prompt" | Out-Null
    return
}

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

Write-Host ""
Read-Host "Press Enter to return to prompt" | Out-Null
