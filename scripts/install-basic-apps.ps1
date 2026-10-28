$ErrorActionPreference = 'Continue'

# Relaunch as administrator if needed.
$isAdmin = ([Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $url = 'https://helper.diegolascano.dev/apps'

    $shellCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue

    if (-not $shellCommand) {
        $shellCommand = Get-Command powershell.exe -ErrorAction Stop
    }

    $shell = $shellCommand.Source

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue

    if (-not $wt) {
        Write-Host 'Windows Terminal not found.' -ForegroundColor Red
        Write-Host ''
        return
    }

    $command = @"
`$ErrorActionPreference = 'Stop'

try {
    `$response = Invoke-WebRequest -Uri '$url' -UseBasicParsing -ErrorAction Stop
    `$code = `$response.Content

    if ([string]::IsNullOrWhiteSpace(`$code) -or
        `$code -match '(?is)^\s*(<!doctype html|<html|error code:\s*\d+|not found\b)') {
        throw 'The endpoint did not return a valid PowerShell script.'
    }

    Clear-Host
    & ([ScriptBlock]::Create(`$code))
}
catch {
    Write-Host "Failed to download or run the script: `$(`$_.Exception.Message)" -ForegroundColor Red
}

Write-Host ''
"@

    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($command)
    )

    $arguments = "-w new new-tab --title `"Basic apps installation`" `"$shell`" -NoProfile -ExecutionPolicy Bypass -NoExit -EncodedCommand $encoded"

    try {
        Start-Process -FilePath $wt.Source `
            -Verb RunAs `
            -ArgumentList $arguments `
            -ErrorAction Stop
    } catch {
        Write-Host "✗ Elevation cancelled or failed." -ForegroundColor Red
    }

    return
}

Clear-Host

$apps = @(
    'Adobe.Acrobat.Reader.64-bit'
    'AnyDesk.AnyDesk'
    'Google.Chrome'
    'Mozilla.Firefox.es-MX'
    'Mozilla.Thunderbird.es-MX'
    'ONLYOFFICE.DesktopEditors'
    'Oracle.JavaRuntimeEnvironment'
    'RARLab.WinRAR'
    'VideoLAN.VLC'
    'voidtools.Everything'
)

while ($true) {
    $answer = (Read-Host 'Install basic apps? [Y]es / [Q]uit').Trim()

    if ($answer -match '^(?i:y|yes)$') {
        break
    }

    if ($answer -match '^(?i:q|quit)$') {
        Write-Host 'Have a great rest of your day!' -ForegroundColor Yellow
        Write-Host ''
        return
    }
}

if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Write-Host "`n✗ Couldn't install all apps: WinGet not found." `
        -ForegroundColor Red
    return
}

$failed = @()

Write-Host "`nChecking WinGet source..." -NoNewline

$checkPackages = {
    $missing = @()

    foreach ($app in $apps) {
        & winget.exe show --id $app --exact --source winget --disable-interactivity *> $null

        if ($LASTEXITCODE -ne 0) {
            $missing += $app
        }
    }

    return ,$missing
}

$missing = & $checkPackages

if ($missing.Count -gt 0) {
    Write-Host "`rRefreshing WinGet source..." -ForegroundColor Yellow

    try {
        Add-AppxPackage `
            -RegisterByFamilyName `
            -MainPackage Microsoft.Winget.Source_8wekyb3d8bbwe `
            -ErrorAction Stop
    } catch {
        Write-Host "Source registration: $($_.Exception.Message)" `
            -ForegroundColor Yellow
    }

    & winget.exe source update --name winget --disable-interactivity *> $null

    $missing = & $checkPackages
}

if ($missing.Count -gt 0) {
    Write-Host "`rSome packages could not be verified:" -ForegroundColor Yellow

    foreach ($app in $missing) {
        Write-Host "  - $app" -ForegroundColor Yellow
    }
}
else {
    Write-Host "`rChecking WinGet source... ✓ Ready.       " `
        -ForegroundColor Green
}

if ($missing.Count -gt 0) {
    $failed += @(
        $missing | ForEach-Object {
            "$_ (package unavailable in WinGet)"
        }
    )
}

Write-Host ''

$skipped = 0
$frames = @('/', '-', '\', '|')
$frame = 0

# Check common installation locations for apps installed outside WinGet.
$installedPaths = @{
    'Adobe.Acrobat.Reader.64-bit' = @(
        "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe"
        "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe"
    )
    'AnyDesk.AnyDesk' = @(
        "$env:ProgramFiles\AnyDesk\AnyDesk.exe"
        "${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe"
    )
    'Google.Chrome' = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    'Mozilla.Firefox.es-MX' = @(
        "$env:ProgramFiles\Mozilla Firefox\firefox.exe"
        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    )
    'Mozilla.Thunderbird.es-MX' = @(
        "$env:ProgramFiles\Mozilla Thunderbird\thunderbird.exe"
        "${env:ProgramFiles(x86)}\Mozilla Thunderbird\thunderbird.exe"
    )
    'ONLYOFFICE.DesktopEditors' = @(
        "$env:ProgramFiles\ONLYOFFICE\DesktopEditors\DesktopEditors.exe"
        "${env:ProgramFiles(x86)}\ONLYOFFICE\DesktopEditors\DesktopEditors.exe"
    )
    'Oracle.JavaRuntimeEnvironment' = @(
        "$env:ProgramFiles\Java"
        "${env:ProgramFiles(x86)}\Java"
    )
    'RARLab.WinRAR' = @(
        "$env:ProgramFiles\WinRAR\WinRAR.exe"
        "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe"
    )
    'VideoLAN.VLC' = @(
        "$env:ProgramFiles\VideoLAN\VLC\vlc.exe"
        "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe"
    )
    'voidtools.Everything' = @(
        "$env:ProgramFiles\Everything\Everything.exe"
        "${env:ProgramFiles(x86)}\Everything\Everything.exe"
    )
}

foreach ($app in $apps) {
    
    $listOutput = & winget.exe list `
        --id $app `
        --exact `
        --accept-source-agreements `
        --disable-interactivity 2>&1 | Out-String

    $installed = $listOutput -match [regex]::Escape($app)

    if (-not $installed -and $installedPaths.ContainsKey($app)) {
        foreach ($path in $installedPaths[$app]) {
            if (Test-Path $path) {
                $installed = $true
                break
            }
        }
    }

    if ($installed) {
        $skipped++
        continue
    }

    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    $process = $null

    try {
        $arguments = @(
            'install'
            '--id'
            $app
            '--exact'
            '--source'
            'winget'
            '--silent'
            '--scope'
            'machine'
            '--accept-package-agreements'
            '--accept-source-agreements'
            '--disable-interactivity'
        )

        $process = Start-Process `
            -FilePath 'winget.exe' `
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
    } catch {
        $failed += "$app ($($_.Exception.Message))"
    } finally {
        Remove-Item $stdout, $stderr `
            -Force -ErrorAction SilentlyContinue
    }
}

$firmaEcPath = "$env:ProgramFiles\FirmaEC"
$firmaEcJar = Join-Path $firmaEcPath 'firmador-jar-with-dependencies.jar'
$firmaEcInstaller = Join-Path $env:TEMP 'firmaec-win64.exe'

if (Test-Path $firmaEcJar) {
    $skipped++
}
else {
    $downloadJob = $null

    try {
        $downloadJob = Start-Job -ArgumentList $firmaEcInstaller -ScriptBlock {
            param($path)

            try {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest `
                    -Uri 'https://mirror.cedia.org.ec/firmaec/firmaec-win64.exe' `
                    -OutFile $path `
                    -UseBasicParsing `
                    -ErrorAction Stop

                [pscustomobject]@{ Success = $true; Error = '' }
            } catch {
                [pscustomobject]@{
                    Success = $false
                    Error = $_.Exception.Message
                }
            }
        }

        while ($downloadJob.State -eq 'Running' -or
               $downloadJob.State -eq 'NotStarted') {
            Write-Host -NoNewline (
                "`rInstalling... {0} " -f $frames[$frame]
            ) -ForegroundColor Cyan

            $frame = ($frame + 1) % $frames.Count
            Start-Sleep -Milliseconds 120
        }

        $downloadResult = Receive-Job -Job $downloadJob

        if ($downloadJob.State -ne 'Completed' -or
            -not $downloadResult -or
            -not $downloadResult.Success) {

            $errorMessage = if ($downloadResult -and $downloadResult.Error) {
                $downloadResult.Error
            } else {
                'FirmaEC download failed.'
            }

            throw $errorMessage
        }

        if (-not (Test-Path $firmaEcInstaller) -or
            (Get-Item $firmaEcInstaller).Length -eq 0) {
            throw 'FirmaEC installer is missing or empty.'
        }
       
        $process = Start-Process `
            -FilePath $firmaEcInstaller `
            -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' `
            -PassThru `
            -ErrorAction Stop

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
            $failed += "FirmaEC (exit code: $($process.ExitCode))"
        }
        elseif (-not (Test-Path $firmaEcJar)) {
            $failed += 'FirmaEC (installation could not be verified)'
        }
    } catch {
        $failed += "FirmaEC ($($_.Exception.Message))"
    } finally {
        if ($downloadJob) {
            Remove-Job -Job $downloadJob -Force `
                -ErrorAction SilentlyContinue
        }

        Remove-Item $firmaEcInstaller -Force `
            -ErrorAction SilentlyContinue
    }
}

if ($failed.Count -eq 0) {
    Write-Host "`rInstalling... ✓ Done!                 " `
        -ForegroundColor Green
    Write-Host ''

    if ($skipped -gt 0) {
        Write-Host "$skipped app(s) already installed; skipped." `
            -ForegroundColor Gray
    }
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

Write-Host 'Have a great rest of your day!' -ForegroundColor Yellow
Write-Host ''
