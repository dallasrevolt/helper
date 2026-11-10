#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Activa o normaliza BitLocker en el volumen del sistema de forma idempotente.

.DESCRIPTION
    - Valida TPM sin limpiarlo automaticamente.
    - Valida pertenencia al dominio y disponibilidad de un DC.
    - Conserva configuraciones BitLocker existentes.
    - Garantiza que exista un Recovery Password protector.
    - Intenta respaldar el Recovery Password en Active Directory.
    - Garantiza que exista un protector basado en TPM.
    - Inicia BitLocker solo cuando las precondiciones se cumplen.
    - Si BitLocker esta suspendido, reanuda la proteccion.
    - Registra eventos y un log de texto local.

.NOTES
    Para produccion se recomienda complementar este script con una GPO de BitLocker
    que obligue a almacenar la informacion de recuperacion en AD DS.
#>

[CmdletBinding()]
param(
    [string]$MountPoint = 'C:',

    [ValidateSet('XtsAes128','XtsAes256')]
    [string]$EncryptionMethod = 'XtsAes256',

    # Para equipos recien instalados por MDT se puede cambiar a $true.
    # Para equipos que ya han estado en uso, Full Disk ($false) es mas seguro.
    [bool]$UsedSpaceOnly = $false,

    # Si es $true, no se inicia un cifrado nuevo si el equipo no esta en dominio
    # o no se puede localizar un controlador de dominio.
    [bool]$RequireADBackup = $true
)

$ErrorActionPreference = 'Stop'
$LogSource = 'BitLocker-Deploy'
$LogFile   = Join-Path $env:WINDIR 'Temp\BitLocker-Deploy.log'

$ExitCodes = @{
    Success             = 0
    NotAdministrator    = 10
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
    }
    catch {
        # El log de archivo y consola continuan aunque no se pueda crear el origen.
    }

    try {
        $folder = Split-Path -Parent $LogFile
        if (-not (Test-Path $folder)) {
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
        }
    }
    catch {}
}

function Write-DeployLog {
    param(
        [Parameter(Mandatory=$true)][int]$Id,
        [Parameter(Mandatory=$true)][ValidateSet('Information','Warning','Error')][string]$Type,
        [Parameter(Mandatory=$true)][string]$Message
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] [{2}] {3}' -f (Get-Date), $Type, $Id, $Message
    Write-Host $line

    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}

    try {
        Write-EventLog -LogName Application -Source $LogSource -EventId $Id -EntryType $Type -Message $Message -ErrorAction Stop
    }
    catch {}
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

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
        throw 'No existe ningun protector RecoveryPassword para respaldar en Active Directory.'
    }

    foreach ($protector in $recoveryProtectors) {
        Write-DeployLog -Id 1200 -Type Information -Message "Respaldando Recovery Password en AD DS. KeyProtectorId: $($protector.KeyProtectorId)"
        Backup-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $protector.KeyProtectorId -ErrorAction Stop | Out-Null
    }
}

Initialize-Logging

try {
    Write-DeployLog -Id 1000 -Type Information -Message "Inicio de validacion BitLocker en $env:COMPUTERNAME. Volumen: $MountPoint"

    if (-not (Test-IsAdministrator)) {
        Stop-Deployment -Code $ExitCodes.NotAdministrator -EventId 1010 -Message 'El script debe ejecutarse con privilegios de administrador.'
    }

    # -------------------------------------------------------------------------
    # 1. TPM
    # -------------------------------------------------------------------------
    $tpm = Get-Tpm -ErrorAction Stop

    if (-not $tpm.TpmPresent) {
        Stop-Deployment -Code $ExitCodes.NoTPM -EventId 1020 -Message 'No se detecto TPM. Revisar BIOS/UEFI (Intel PTT / AMD fTPM / TPM discreto).'
    }

    if (-not $tpm.TpmEnabled -or -not $tpm.TpmActivated) {
        Stop-Deployment -Code $ExitCodes.TPMDisabled -EventId 1021 -Message 'TPM presente pero no habilitado/activado. Debe habilitarse en BIOS/UEFI.'
    }

    if (-not $tpm.TpmReady) {
        Write-DeployLog -Id 1022 -Type Warning -Message 'TPM presente pero no preparado. Se intentara Initialize-Tpm sin permitir limpieza automatica del TPM.'

        try {
            Initialize-Tpm -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 2
            $tpm = Get-Tpm -ErrorAction Stop
        }
        catch {
            Stop-Deployment -Code $ExitCodes.TPMNotReady -EventId 1023 -Message "No fue posible preparar el TPM sin limpiarlo. Error: $($_.Exception.Message)"
        }

        if (-not $tpm.TpmReady) {
            Stop-Deployment -Code $ExitCodes.TPMNotReady -EventId 1024 -Message 'TPM continua sin estar preparado. No se realizara ninguna accion destructiva ni se limpiara automaticamente.'
        }
    }

    Write-DeployLog -Id 1025 -Type Information -Message 'TPM presente, habilitado y preparado.'

    # -------------------------------------------------------------------------
    # 2. Dominio / controlador de dominio
    # -------------------------------------------------------------------------
    $domainState = Test-DomainAvailability

    if ($RequireADBackup) {
        if (-not $domainState.PartOfDomain) {
            Stop-Deployment -Code $ExitCodes.NotDomainJoined -EventId 1030 -Message 'El equipo no pertenece a un dominio. RequireADBackup=True: no se iniciara un cifrado nuevo.'
        }

        if (-not $domainState.DCReachable) {
            Stop-Deployment -Code $ExitCodes.NoDomainController -EventId 1031 -Message "El equipo pertenece a $($domainState.Domain), pero no se pudo localizar un controlador de dominio. No se iniciara un cifrado nuevo."
        }

        Write-DeployLog -Id 1032 -Type Information -Message "Dominio disponible: $($domainState.Domain)."
    }

    # -------------------------------------------------------------------------
    # 3. Estado actual de BitLocker
    # -------------------------------------------------------------------------
    $volume = Get-BitLockerState
    Write-DeployLog -Id 1040 -Type Information -Message "Estado inicial: VolumeStatus=$($volume.VolumeStatus); ProtectionStatus=$($volume.ProtectionStatus); EncryptionPercentage=$($volume.EncryptionPercentage)%"

    $wasFullyDecrypted = ($volume.VolumeStatus -eq 'FullyDecrypted')

    # -------------------------------------------------------------------------
    # 4. Si esta totalmente descifrado, iniciar BitLocker con Recovery Password.
    #    Primero se valida dominio/DC; despues se inicia cifrado y se respalda
    #    inmediatamente el protector en AD DS.
    # -------------------------------------------------------------------------
    if ($wasFullyDecrypted) {
        Write-DeployLog -Id 1050 -Type Information -Message "BitLocker no esta habilitado. Iniciando cifrado $EncryptionMethod. UsedSpaceOnly=$UsedSpaceOnly"

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
    # 5. Garantizar Recovery Password protector
    # -------------------------------------------------------------------------
    $recoveryProtectors = Get-RecoveryProtectors -Volume $volume

    if ($recoveryProtectors.Count -eq 0) {
        Write-DeployLog -Id 1060 -Type Warning -Message 'No existe Recovery Password protector. Se agregara uno.'
        Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1
        $volume = Get-BitLockerState
        $recoveryProtectors = Get-RecoveryProtectors -Volume $volume
    }

    if ($recoveryProtectors.Count -eq 0) {
        throw 'No fue posible crear un Recovery Password protector.'
    }

    # -------------------------------------------------------------------------
    # 6. Respaldar Recovery Password en AD DS
    # -------------------------------------------------------------------------
    if ($RequireADBackup) {
        try {
            Backup-RecoveryProtectorsToAD -Volume $volume
            Write-DeployLog -Id 1070 -Type Information -Message 'Comando de respaldo de Recovery Password en AD DS completado correctamente.'
        }
        catch {
            # Si el cifrado se acaba de iniciar y no se pudo respaldar, se suspende
            # la proteccion para reducir el riesgo de bloqueo hasta corregir AD.
            try {
                Suspend-BitLocker -MountPoint $MountPoint -RebootCount 0 -ErrorAction SilentlyContinue | Out-Null
            }
            catch {}

            Stop-Deployment -Code $ExitCodes.ADBckupFailed -EventId 1071 -Message "Fallo el respaldo de Recovery Password en AD DS. La proteccion se dejo suspendida cuando fue posible. Error: $($_.Exception.Message)"
        }
    }
    else {
        Write-DeployLog -Id 1072 -Type Warning -Message 'RequireADBackup=False. El script no exigira respaldo de Recovery Password en AD DS.'
    }

    # -------------------------------------------------------------------------
    # 7. Garantizar protector TPM sin alterar configuraciones TPM+PIN existentes
    # -------------------------------------------------------------------------
    $volume = Get-BitLockerState
    $tpmProtectors = Get-TpmProtectors -Volume $volume

    if ($tpmProtectors.Count -eq 0) {
        Write-DeployLog -Id 1080 -Type Information -Message 'No existe protector basado en TPM. Se agregara protector TPM.'
        Add-BitLockerKeyProtector -MountPoint $MountPoint -TpmProtector -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1
        $volume = Get-BitLockerState
        $tpmProtectors = Get-TpmProtectors -Volume $volume
    }

    if ($tpmProtectors.Count -eq 0) {
        throw 'No fue posible crear un protector TPM.'
    }

    # -------------------------------------------------------------------------
    # 8. Reanudar proteccion si estaba suspendida
    # -------------------------------------------------------------------------
    $volume = Get-BitLockerState

    if ($volume.ProtectionStatus -eq 'Off' -and $volume.VolumeStatus -ne 'FullyDecrypted') {
        Write-DeployLog -Id 1090 -Type Warning -Message 'El volumen esta cifrado o cifrandose pero la proteccion esta suspendida. Se intentara reanudar.'
        Resume-BitLocker -MountPoint $MountPoint -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1
        $volume = Get-BitLockerState
    }

    # -------------------------------------------------------------------------
    # 9. Estado final
    # -------------------------------------------------------------------------
    $volume = Get-BitLockerState
    $recoveryProtectors = Get-RecoveryProtectors -Volume $volume
    $tpmProtectors      = Get-TpmProtectors -Volume $volume

    $recoveryIds = ($recoveryProtectors | ForEach-Object { $_.KeyProtectorId }) -join ', '
    $tpmTypes    = ($tpmProtectors | ForEach-Object { $_.KeyProtectorType }) -join ', '

    Write-DeployLog -Id 1100 -Type Information -Message "BitLocker OK. VolumeStatus=$($volume.VolumeStatus); ProtectionStatus=$($volume.ProtectionStatus); EncryptionPercentage=$($volume.EncryptionPercentage)%; RecoveryProtectorId=$recoveryIds; TPMProtector=$tpmTypes"

    Write-Host ''
    Write-Host '=============================================='
    Write-Host ' BITLOCKER - RESULTADO'
    Write-Host '=============================================='
    Write-Host "Equipo             : $env:COMPUTERNAME"
    Write-Host "Volumen            : $MountPoint"
    Write-Host "Estado volumen      : $($volume.VolumeStatus)"
    Write-Host "Proteccion          : $($volume.ProtectionStatus)"
    Write-Host "Cifrado             : $($volume.EncryptionPercentage)%"
    Write-Host "Recovery protectors : $($recoveryProtectors.Count)"
    Write-Host "TPM protectors      : $($tpmProtectors.Count)"
    if ($RequireADBackup) {
        Write-Host "Backup AD           : comando completado correctamente"
    }
    Write-Host "Log                 : $LogFile"
    Write-Host '=============================================='

    exit $ExitCodes.Success
}
catch {
    $message = "Error no controlado en BitLocker: $($_.Exception.Message)"
    Write-DeployLog -Id 1999 -Type Error -Message $message
    exit $ExitCodes.UnexpectedError
}
