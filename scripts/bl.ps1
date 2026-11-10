#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$MountPoint = 'C:',

    [ValidateSet('XtsAes128','XtsAes256')]
    [string]$EncryptionMethod = 'XtsAes256',

    # Use $true for newly deployed devices, such as those provisioned through MDT.
    # For devices already in use, Full Disk encryption ($false) is safer.
    [bool]$UsedSpaceOnly = $false,

    # When $true, new encryption will not start unless the device is domain-joined
    # and a domain controller is reachable.
    [bool]$RequireADBackup = $true
)


# Elevate when needed
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    $scriptUrl = 'https://helper.diegolascano.dev/bl'

    $terminal = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (-not $terminal) {
        Write-Host 'Windows Terminal was not found.' -ForegroundColor Red
        return
    }

    $shellCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $shellCommand) {
        $shellCommand = Get-Command pwsh.exe -ErrorAction Stop
    }
    $shell = $shellCommand.Source

    $escapedShell = $shell.Replace("'", "''")

    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$tempFile = Join-Path `$env:TEMP ('BitLocker-Deploy-' + [guid]::NewGuid().ToString() + '.ps1')

try {
    `$response = Invoke-WebRequest -Uri '$scriptUrl' -UseBasicParsing -ErrorAction Stop
    `$code = `$response.Content

    if ([string]::IsNullOrWhiteSpace(`$code) -or `$code -match '(?is)^\s*(<!doctype html|<html|error code:\s*\d+|not found\b)') {
        throw 'The endpoint did not return a valid PowerShell script.'
    }

    Set-Content -LiteralPath `$tempFile -Value `$code -Encoding UTF8 -ErrorAction Stop

    `$process = Start-Process -FilePath '$escapedShell' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', `$tempFile) -Wait -PassThru -ErrorAction Stop

    `$scriptExitCode = `$process.ExitCode

    if (`$scriptExitCode -ne 0) {
        Write-Host "Script finished with exit code: `$scriptExitCode" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Failed to download or run the script: `$(`$_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check the Cloudflare Worker route and GitHub file path.' -ForegroundColor Yellow
} finally {
    if (Test-Path -LiteralPath `$tempFile) {
        Remove-Item -LiteralPath `$tempFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host 'Press any key to close this window.' -ForegroundColor Cyan

    try {
        `$null = `$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        Read-Host 'Press Enter to close this window.' | Out-Null
    }
}
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

    try {
        $wtArgs = @(
            'new-tab'
            '--title'
            'BitLocker deployment'
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

$ErrorActionPreference = 'Stop'
$LogSource = 'BitLocker-Deploy'
$LogFile   = Join-Path $env:WINDIR 'Temp\BitLocker-Deploy.log'

$ExitCodes = @{
    Success             = 0
    NoTPM               = 20
    TPMDisabled         = 21
    TPMNotReady         = 22
    NotDomainJoined     = 30
    NoDomainController  = 31
    ADBckupFailed       = 32
    BitLockerError      = 40
    UnexpectedError     = 99
}

function Initialize-Logging {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($LogSource)) {
            New-EventLog -LogName Application -Source $LogSource -ErrorAction Stop
        }
    } catch {
        # Continue without Event Viewer logging if the event source cannot be created.
    }

    try {
        $folder = Split-Path -Parent $LogFile
        if (-not (Test-Path $folder)) {
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
        }
    } catch {}
}

function Write-DeployLog {
    param(
        [Parameter(Mandatory=$true)][int]$Id,
        [Parameter(Mandatory=$true)][ValidateSet('Information','Warning','Error')][string]$Type,
        [Parameter(Mandatory=$true)][string]$Message
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] [{2}] {3}' -f (Get-Date), $Type, $Id, $Message
    $foregroundColor = switch ($Type) {
        'Information' { 'Cyan' }
        'Warning'     { 'Yellow' }
        'Error'       { 'Red' }
    }

    Write-Host $line -ForegroundColor $foregroundColor

    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}

    try {
        Write-EventLog -LogName Application -Source $LogSource -EventId $Id -EntryType $Type -Message $Message -ErrorAction Stop
    } catch {}
}

function Stop-Deployment {
    param(
        [Parameter(Mandatory=$true)][int]$Code,
        [Parameter(Mandatory=$true)][int]$EventId,
        [Parameter(Mandatory=$true)][string]$Message
    )

    Write-DeployLog -Id $EventId -Type Error -Message $Message
    exit $Code
}

function Get-BitLockerState {
    return Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
}

function Get-RecoveryProtectors {
    param([Parameter(Mandatory=$true)]$Volume)
    @($Volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
}

function Get-TpmProtectors {
    param([Parameter(Mandatory=$true)]$Volume)
    @($Volume.KeyProtector | Where-Object { $_.KeyProtectorType.ToString() -like 'Tpm*' })
}

function Test-DomainAvailability {
    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop

    if (-not $computerSystem.PartOfDomain) {
        return [pscustomobject]@{
            PartOfDomain = $false
            Domain       = $null
            DCReachable  = $false
        }
    }

    $domain = $computerSystem.Domain
    $null = & nltest.exe "/dsgetdc:$domain" 2>&1
    $dcOK = ($LASTEXITCODE -eq 0)

    return [pscustomobject]@{
        PartOfDomain = $true
        Domain       = $domain
        DCReachable  = $dcOK
    }
}

function Backup-RecoveryProtectorsToAD {
    param([Parameter(Mandatory=$true)]$Volume)

    $recoveryProtectors = Get-RecoveryProtectors -Volume $Volume
    if ($recoveryProtectors.Count -eq 0) {
        throw 'No Recovery Password protector exists to back up to Active Directory.'
    }

    foreach ($protector in $recoveryProtectors) {
        Write-DeployLog -Id 1200 -Type Information -Message "Backing up Recovery Password to AD DS. KeyProtectorId: $($protector.KeyProtectorId)"
        Backup-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $protector.KeyProtectorId -ErrorAction Stop | Out-Null
    }
}

# Confirm execution
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ' BITLOCKER - DEPLOYMENT' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host "Computer : $env:COMPUTERNAME"
Write-Host "Volume   : $MountPoint"
Write-Host "Method   : $EncryptionMethod"
Write-Host ''

while ($true) {
    $answer = (Read-Host 'Proceed with BitLocker configuration?').Trim()

    if ($answer -match '^(?i:y|yes)$') { break }
    if ($answer -match '^(?i:q|quit)$') { 
        Write-Host 'Have a great rest of your day!' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    Write-Host 'Please enter Y or Q.' -ForegroundColor Yellow
}

Write-Host ''

Initialize-Logging

<#
try {
    Write-DeployLog -Id 1000 -Type Information -Message "Starting BitLocker validation on $env:COMPUTERNAME. Volume: $MountPoint"

    # -------------------------------------------------------------------------
    # 1. TPM validation
    # -------------------------------------------------------------------------
    $tpm = Get-Tpm -ErrorAction Stop

    if (-not $tpm.TpmPresent) {
        Stop-Deployment -Code $ExitCodes.NoTPM -EventId 1020 -Message 'No TPM detected. Check BIOS/UEFI settings (Intel PTT / AMD fTPM / discrete TPM).'
    }

    if (-not $tpm.TpmEnabled -or -not $tpm.TpmActivated) {
        Stop-Deployment -Code $ExitCodes.TPMDisabled -EventId 1021 -Message 'TPM detected but not enabled or activated. Enable it in BIOS/UEFI.'
    }

    if (-not $tpm.TpmReady) {
        Write-DeployLog -Id 1022 -Type Warning -Message 'TPM detected but not ready. Attempting Initialize-Tpm without allowing automatic TPM clearing.'

        try {
            Initialize-Tpm -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 2
            $tpm = Get-Tpm -ErrorAction Stop
        } catch {
            Stop-Deployment -Code $ExitCodes.TPMNotReady -EventId 1023 -Message "Unable to prepare the TPM without clearing it. Error: $($_.Exception.Message)"
        }

        if (-not $tpm.TpmReady) {
            Stop-Deployment -Code $ExitCodes.TPMNotReady -EventId 1024 -Message 'TPM is still not ready. No destructive actions or automatic TPM clearing will be performed.'
        }
    }

    Write-DeployLog -Id 1025 -Type Information -Message 'TPM detected, enabled and ready.'

    # -------------------------------------------------------------------------
    # 2. Domain and domain controller availability
    # -------------------------------------------------------------------------
    $domainState = Test-DomainAvailability

    if ($RequireADBackup) {
        if (-not $domainState.PartOfDomain) {
            Stop-Deployment -Code $ExitCodes.NotDomainJoined -EventId 1030 -Message 'The computer is not domain-joined. RequireADBackup=True: new encryption will not start.'
        }

        if (-not $domainState.DCReachable) {
            Stop-Deployment -Code $ExitCodes.NoDomainController -EventId 1031 -Message "The computer belongs to $($domainState.Domain), but no domain controller could be located. New encryption will not start."
        }

        Write-DeployLog -Id 1032 -Type Information -Message "Domain available: $($domainState.Domain)."
    }

    # -------------------------------------------------------------------------
    # 3. Current BitLocker status
    # -------------------------------------------------------------------------
    $volume = Get-BitLockerState
    Write-DeployLog -Id 1040 -Type Information -Message "Initial status: VolumeStatus=$($volume.VolumeStatus); ProtectionStatus=$($volume.ProtectionStatus); EncryptionPercentage=$($volume.EncryptionPercentage)%"

    $wasFullyDecrypted = ($volume.VolumeStatus -eq 'FullyDecrypted')

    # -------------------------------------------------------------------------
    # 4. Enable BitLocker if the volume is fully decrypted.
    #    Validate domain/DC availability first, then start encryption and
    #    immediately back up the recovery protector to AD DS.
    # -------------------------------------------------------------------------
    if ($wasFullyDecrypted) {
        Write-DeployLog -Id 1050 -Type Information -Message "BitLocker is not enabled. Starting $EncryptionMethod encryption. UsedSpaceOnly=$UsedSpaceOnly"

        $enableParams = @{
            MountPoint                = $MountPoint
            EncryptionMethod          = $EncryptionMethod
            RecoveryPasswordProtector = $true
            SkipHardwareTest          = $true
            ErrorAction               = 'Stop'
        }

        if ($UsedSpaceOnly) {
            $enableParams['UsedSpaceOnly'] = $true
        }

        Enable-BitLocker @enableParams | Out-Null
        Start-Sleep -Seconds 2
        $volume = Get-BitLockerState
    }

    # -------------------------------------------------------------------------
    # 5. Ensure a Recovery Password protector exists.
    # -------------------------------------------------------------------------
    $recoveryProtectors = Get-RecoveryProtectors -Volume $volume

    if ($recoveryProtectors.Count -eq 0) {
        Write-DeployLog -Id 1060 -Type Warning -Message 'No Recovery Password protector exists. One will be added.'
        Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1
        $volume = Get-BitLockerState
        $recoveryProtectors = Get-RecoveryProtectors -Volume $volume
    }

    if ($recoveryProtectors.Count -eq 0) {
        throw 'Unable to create a Recovery Password protector.'
    }

    # -------------------------------------------------------------------------
    # 6. Back up a Recovery Password protectors to AD DS
    # -------------------------------------------------------------------------
    if ($RequireADBackup) {
        try {
            Backup-RecoveryProtectorsToAD -Volume $volume
            Write-DeployLog -Id 1070 -Type Information -Message 'Recovery Password backup command completed successfully.'
        } catch {
            # If encryption was just started and the backup failed, suspend
            # protection when possible to reduce the risk of lockout until AD is fixed.
            try {
                Suspend-BitLocker -MountPoint $MountPoint -RebootCount 0 -ErrorAction SilentlyContinue | Out-Null
            } catch {}

            Stop-Deployment -Code $ExitCodes.ADBckupFailed -EventId 1071 -Message "Recovery Password backup to AD DS failed. Protection was suspended when possible. Error: $($_.Exception.Message)"
        }
    }
    else {
        Write-DeployLog -Id 1072 -Type Warning -Message 'RequireADBackup=False. The script will not require a Recovery Password backup in AD DS.'
    }

    # -------------------------------------------------------------------------
    # 7. Ensure a TPM protector exists without modifying existing TPM+PIN configurations
    # -------------------------------------------------------------------------
    $volume = Get-BitLockerState
    $tpmProtectors = Get-TpmProtectors -Volume $volume

    if ($tpmProtectors.Count -eq 0) {
        Write-DeployLog -Id 1080 -Type Information -Message 'No TPM-based protector exists. A TPM protector will be added.'
        Add-BitLockerKeyProtector -MountPoint $MountPoint -TpmProtector -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1
        $volume = Get-BitLockerState
        $tpmProtectors = Get-TpmProtectors -Volume $volume
    }

    if ($tpmProtectors.Count -eq 0) {
        throw 'Unable to create a TPM protector.'
    }

    # -------------------------------------------------------------------------
    # 8. Resume protection if suspended
    # -------------------------------------------------------------------------
    $volume = Get-BitLockerState

    if ($volume.ProtectionStatus -eq 'Off' -and $volume.VolumeStatus -ne 'FullyDecrypted') {
        Write-DeployLog -Id 1090 -Type Warning -Message 'The volume is encrypted or encrypting, but protection is suspended. Attempting to resume protection.'
        Resume-BitLocker -MountPoint $MountPoint -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1
        $volume = Get-BitLockerState
    }

    # -------------------------------------------------------------------------
    # 9. Final status
    # -------------------------------------------------------------------------
    $volume = Get-BitLockerState
    $recoveryProtectors = Get-RecoveryProtectors -Volume $volume
    $tpmProtectors      = Get-TpmProtectors -Volume $volume

    $recoveryIds = ($recoveryProtectors | ForEach-Object { $_.KeyProtectorId }) -join ', '
    $tpmTypes    = ($tpmProtectors | ForEach-Object { $_.KeyProtectorType }) -join ', '

    Write-DeployLog -Id 1100 -Type Information -Message "BitLocker configured successfully. VolumeStatus=$($volume.VolumeStatus); ProtectionStatus=$($volume.ProtectionStatus); EncryptionPercentage=$($volume.EncryptionPercentage)%; RecoveryProtectorId=$recoveryIds; TPMProtector=$tpmTypes"

    Write-Host ''
    Write-Host '==============================================' -ForegroundColor Green
    Write-Host ' DEPLOYMENT RESULTS' -ForegroundColor Green
    Write-Host '==============================================' -ForegroundColor Green
    Write-Host "Computer            : $env:COMPUTERNAME" -ForegroundColor Green
    Write-Host "Volume              : $MountPoint" -ForegroundColor Green
    Write-Host "Volume status       : $($volume.VolumeStatus)" -ForegroundColor Green
    Write-Host "Protection status   : $($volume.ProtectionStatus)" -ForegroundColor Green
    Write-Host "Encryption          : $($volume.EncryptionPercentage)%" -ForegroundColor Green
    Write-Host "Recovery protectors : $($recoveryProtectors.Count)" -ForegroundColor Green
    Write-Host "TPM protectors      : $($tpmProtectors.Count)" -ForegroundColor Green
    if ($RequireADBackup) {
        Write-Host "AD backup           : Command completed successfully" -ForegroundColor Green
    }
    Write-Host "Log file            : $LogFile" -ForegroundColor Green
    Write-Host '==============================================' -ForegroundColor Green

    exit $ExitCodes.Success
} catch {
    $message = "Unhandled BitLocker error: $($_.Exception.Message)"
    Write-DeployLog -Id 1999 -Type Error -Message $message
    exit $ExitCodes.UnexpectedError
}
#>

# Test
Write-Host ''
Write-Host 'Hello World!' -ForegroundColor Green
Write-Host ''
exit 0
