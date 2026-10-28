# Relaunch in Windows Terminal as administrator when needed
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    $scriptUrl = 'https://helper.diegolascano.dev/admin'

    $terminal = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (-not $terminal) {
        Write-Host 'Windows Terminal was not found.' -ForegroundColor Red
        return
    }

    $shellCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $shellCommand) {
        $shellCommand = Get-Command powershell.exe -ErrorAction Stop
    }
    $shell = $shellCommand.Source

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

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

    try {
        $wtArgs = @(
            'new-tab'
            '--title'
            'Give administrator privileges'
            $shell
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-NoExit'
            '-EncodedCommand'
            $encoded
        )

        $argumentLine = $wtArgs | ForEach-Object {
            if ($_ -match '\s') {
                '"' + $_.Replace('"', '\"') + '"'
            } else {
                $_
            }
        }
    
        Start-Process -FilePath $terminal.Source `
            -Verb RunAs `
            -ArgumentList ($argumentLine -join ' ') `
            -ErrorAction Stop
    } catch {
        Write-Host "Could not start the elevated terminal: $($_.Exception.Message)" -ForegroundColor Red
    }

    return
}

Clear-Host

$G = 'Administradores'
$Protected = @('Administrador', 'desplieguem')
$Profiles = @{}

# Get local user profile names
Get-ChildItem 'C:\Users' -Directory -Force -EA SilentlyContinue |
    ForEach-Object {
        $Profiles[$_.Name.ToLowerInvariant()] = $_.Name
    }

# Get current local administrator members
$Members = @{}

net localgroup $G 2>$null |
    ForEach-Object {
        $v = $_.Trim()

        if (
            $v -match '^(?:[^\\]+\\)?([A-Za-z0-9._-]+)$' -and
            $v -notmatch '^(Alias name|Comment|Members|The command completed successfully)$'
        ) {
            $Members[$matches[1].ToLowerInvariant()] = $matches[1]
        }
    }

while ($true) {
    $u = (Read-Host 'Type username / [Q]uit').Trim()

    if (!$u) {
        continue
    }

    if ($u -match '^[Qq]$') {
        Write-Host 'Have a great rest of your day!' -ForegroundColor Yellow
        Write-Host ''
        break
    }

    if ($u.Length -gt 30) {
        $u = $u.Substring(0, 30)
    }

    # Validate username and check for a local profile
    if (
        $u -notmatch '^[A-Za-z0-9._-]+$' -or
        !$Profiles.ContainsKey($u.ToLowerInvariant())
    ) {
        Write-Host 'Username not found.' -ForegroundColor Red
        Write-Host ''
        continue
    }

    $k = $u.ToLowerInvariant()
    $A = $Members.ContainsKey($k)

    if ($Protected -contains $u) {
        $A = $true
    }

    # Handle users who are already administrators
    if ($A) {
        if ($Protected -contains $u) {
            Write-Host -NoNewline $u -ForegroundColor Green

            if ($u -ieq 'desplieguem') {
                Write-Host ' already has local administrator privileges.'
            } else {
                Write-Host ' is already a local admin.'
            }

            Write-Host ''
            continue
        }

        while ($true) {
            Write-Host -NoNewline $u -ForegroundColor Green
            Write-Host -NoNewline ' is already a local admin. Remove it? [Y]es / [N]o: '

            $c = Read-Host

            if ($c -match '^[Yy]$') {
                net localgroup $G $u /delete | Out-Null

                if ($LASTEXITCODE -eq 0) {
                    $Members.Remove($k)

                    Write-Host -NoNewline $u -ForegroundColor Green
                    Write-Host ' was removed from local administrators.'
                } else {
                    Write-Host 'Unable to remove user.' -ForegroundColor Red
                }

                Write-Host ''
                break
            }

            if ($c -match '^[Nn]$') {
                Write-Host ''
                break
            }
        }

        continue
    }

    # Ask before granting local administrator privileges
    while ($true) {
        Write-Host -NoNewline 'Make '
        Write-Host -NoNewline $u -ForegroundColor Green
        Write-Host -NoNewline ' local admin? [Y]es / [N]o: '

        $c = Read-Host

        if ($c -match '^[Yy]$') {
            net localgroup $G $u /add | Out-Null

            if ($LASTEXITCODE -eq 0) {
                $Members[$k] = $u

                Write-Host -NoNewline $u -ForegroundColor Green
                Write-Host ' is now a local admin.'
            } else {
                Write-Host "Failed. Windows error code: $LASTEXITCODE" -ForegroundColor Red
            }

            Write-Host ''
            break
        }

        if ($c -match '^[Nn]$') {
            Write-Host ''
            break
        }
    }
}

Write-Host 'Have a great rest of your day!' -ForegroundColor Yellow
Write-Host ''
