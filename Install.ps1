[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\EverVigil'),
    [string]$PreviousInstallRoot,
    [string]$TargetVersion,
    [switch]$DeferCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSStyle -ErrorAction SilentlyContinue) {
    $PSStyle.OutputRendering = 'PlainText'
}

trap {
    [Console]::Error.WriteLine('ERROR: {0}', $_.Exception.Message)
    exit 1
}

$RepositoryRoot = $PSScriptRoot
$InstallPathResolver = Join-Path $RepositoryRoot 'scripts\Resolve-SafeInstallRoot.ps1'
$InteractiveTaskHelper = Join-Path $RepositoryRoot 'scripts\Invoke-InteractiveUserTask.ps1'
$InstallTransactionDataHelper = Join-Path `
    $RepositoryRoot `
    'scripts\InstallTransactionData.ps1'
$LegacyCompatibilityHelper = Join-Path `
    $RepositoryRoot `
    'scripts\LegacyCompatibility.generated.ps1'
if (-not (Test-Path -LiteralPath $InstallPathResolver -PathType Leaf)) {
    throw "Required install-path validator not found: $InstallPathResolver"
}
if (-not (Test-Path -LiteralPath $InteractiveTaskHelper -PathType Leaf)) {
    throw "Required interactive-task helper not found: $InteractiveTaskHelper"
}
if (-not (Test-Path -LiteralPath $InstallTransactionDataHelper -PathType Leaf)) {
    throw "Required install-transaction data helper not found: $InstallTransactionDataHelper"
}
if (-not (Test-Path -LiteralPath $LegacyCompatibilityHelper -PathType Leaf)) {
    throw "Required legacy-compatibility helper not found: $LegacyCompatibilityHelper"
}
. $InstallPathResolver
. $InteractiveTaskHelper
. $InstallTransactionDataHelper
$installRootResolution = Resolve-EverVigilMaintenanceInstallRoot `
    -Path $InstallRoot `
    -AllowLegacyKnownLayout
$InstallRoot = [string]$installRootResolution.Path
$allowInstallRootInCurrentTemp = [bool]$installRootResolution.AllowCurrentTempTree
$allowPreviousInstallRootInCurrentTemp = $false
Assert-CompatibleInstallRoot `
    -Path $InstallRoot `
    -AllowCurrentTempTree:$allowInstallRootInCurrentTemp
if ([string]::IsNullOrWhiteSpace($PreviousInstallRoot)) {
    $legacyDefaultResolution = Resolve-EverVigilMaintenanceInstallRoot `
        -Path (Join-Path `
            $env:LOCALAPPDATA `
            $script:LegacyCompatibilityApplicationInstallRootRelativeToLocalAppData) `
        -AllowLegacyKnownLayout
    $legacyDefaultRoot = [string]$legacyDefaultResolution.Path
    $legacyDefaultOwned = -not [string]::Equals(
        $InstallRoot,
        $legacyDefaultRoot,
        [StringComparison]::OrdinalIgnoreCase) -and
        [bool]$legacyDefaultResolution.Owned
    if ($legacyDefaultOwned) {
        $PreviousInstallRoot = $legacyDefaultRoot
        $allowPreviousInstallRootInCurrentTemp =
            [bool]$legacyDefaultResolution.AllowCurrentTempTree
    } else {
        $PreviousInstallRoot = $InstallRoot
        $allowPreviousInstallRootInCurrentTemp = $allowInstallRootInCurrentTemp
    }
} else {
    $previousInstallRootResolution = Resolve-EverVigilMaintenanceInstallRoot `
        -Path $PreviousInstallRoot `
        -AllowLegacyKnownLayout
    $PreviousInstallRoot = [string]$previousInstallRootResolution.Path
    $allowPreviousInstallRootInCurrentTemp =
        [bool]$previousInstallRootResolution.AllowCurrentTempTree
}
$installRootChanged = -not [string]::Equals(
    $InstallRoot,
    $PreviousInstallRoot,
    [StringComparison]::OrdinalIgnoreCase)
if ($installRootChanged -and
    ($InstallRoot.StartsWith("$PreviousInstallRoot\", [StringComparison]::OrdinalIgnoreCase) -or
        $PreviousInstallRoot.StartsWith("$InstallRoot\", [StringComparison]::OrdinalIgnoreCase))) {
    throw 'The new and previous installation directories cannot contain one another.'
}
if ($installRootChanged -and (Test-Path -LiteralPath $PreviousInstallRoot -PathType Container)) {
    Assert-OwnedInstallRoot `
        -Path $PreviousInstallRoot `
        -AllowLegacyKnownLayout `
        -AllowCurrentTempTree:$allowPreviousInstallRootInCurrentTemp
}
if ($installRootChanged -and (Test-Path -LiteralPath $InstallRoot -PathType Container) -and
    @(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction Stop).Count -gt 0) {
    throw "A new destination selected during an update must be empty: $InstallRoot"
}
$destinationOwnedInstallPresent = -not $installRootChanged -and
    (Test-Path -LiteralPath $InstallRoot -PathType Container) -and
    @(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction Stop).Count -gt 0
$previousOwnedInstallPresent = $installRootChanged -and
    (Test-Path -LiteralPath $PreviousInstallRoot -PathType Container)
$existingInstallPresent = $destinationOwnedInstallPresent -or $previousOwnedInstallPresent
$legacySourceRoot = if ($previousOwnedInstallPresent) {
    $PreviousInstallRoot
} elseif ($destinationOwnedInstallPresent) {
    $InstallRoot
} else {
    $null
}
$legacyCleanupAuthorized = $false
if (-not [string]::IsNullOrWhiteSpace($legacySourceRoot)) {
    $legacyCleanupAuthorized = $null -ne (Get-EverVigilLegacyInstallOwnership `
            -Path $legacySourceRoot `
            -AllowCurrentTempTree)
}

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run Install.ps1 from a non-administrator PowerShell. The installer requests UAC only for system configuration.'
}
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$ownerSid = if ($null -eq $currentIdentity.User) {
    $null
} else {
    $currentIdentity.User.Value
}
if ([string]::IsNullOrWhiteSpace($ownerSid)) {
    throw 'The invoking user SID is unavailable.'
}

function Get-ProfilePathForSid {
    param([Parameter(Mandatory)][string]$Sid)

    $profileRegistryPath =
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    try {
        $profileValue = Get-ItemPropertyValue `
            -LiteralPath $profileRegistryPath `
            -Name 'ProfileImagePath'
        return [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables([string]$profileValue))
    } catch {
        throw "Could not resolve the invoking user's profile from SID '$Sid': $($_.Exception.Message)"
    }
}

function Get-LegacyRootCandidatesForProfile {
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string[]]$FileSystemRoots
    )

    $resolvedProfilePath = [IO.Path]::GetFullPath($ProfilePath)
    $profileName = [IO.DirectoryInfo]::new($resolvedProfilePath).Name
    if ([string]::IsNullOrWhiteSpace($profileName)) {
        throw "The invoking user's profile path has no account-name segment: $resolvedProfilePath"
    }
    $portableTemplate =
        $script:LegacyCompatibilityOlderEvenTerminalCodexDriveLauncherRelativeToProfileDirectory
    $portableLauncher = $portableTemplate.Replace(
        '{profileDirectory}',
        $profileName,
        [StringComparison]::Ordinal)
    $portableSuffix = [IO.Path]::GetDirectoryName($portableLauncher)
    $candidates = @(
        [IO.Path]::Combine(
            $resolvedProfilePath,
            $script:LegacyCompatibilityOlderEvenTerminalCodexLocalAppDataRootRelativeToProfile)
        foreach ($fileSystemRoot in $FileSystemRoots) {
            [IO.Path]::Combine($fileSystemRoot, $portableSuffix)
        }
    )
    return @($candidates | Select-Object -Unique)
}

$ProjectPath = Join-Path $RepositoryRoot 'src\EverVigil\EverVigil.csproj'
$BundledExecutable = Join-Path $RepositoryRoot 'payload\EverVigil.exe'
if ([string]::IsNullOrWhiteSpace($TargetVersion)) {
    if (Test-Path -LiteralPath $BundledExecutable -PathType Leaf) {
        $TargetVersion = [string](Get-Item `
                -LiteralPath $BundledExecutable `
                -Force).VersionInfo.ProductVersion
    } else {
        [xml]$projectDocument = [IO.File]::ReadAllText($ProjectPath)
        $versionCandidates = @($projectDocument.Project.PropertyGroup.Version |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)
        if ($versionCandidates.Count -ne 1) {
            throw 'The source project does not declare one unambiguous target version.'
        }
        $TargetVersion = $versionCandidates[0]
    }
}
$TargetVersion = $TargetVersion.Trim()
if ($TargetVersion -cnotmatch
    '\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\z') {
    throw "The target version is not a strict semantic version: $TargetVersion"
}
$SystemScript = Join-Path $RepositoryRoot 'scripts\Invoke-SystemMaintenance.ps1'
$InstallTransactionScript = Join-Path $RepositoryRoot 'scripts\Complete-InstallTransaction.ps1'
if (-not (Test-Path -LiteralPath $InstallTransactionScript -PathType Leaf)) {
    throw "Required install-transaction script not found: $InstallTransactionScript"
}
$InstallParent = Split-Path -Parent $InstallRoot
$InstalledExecutable = Join-Path $InstallRoot 'EverVigil.exe'
$previousCurrentExecutable = Join-Path $PreviousInstallRoot 'EverVigil.exe'
$previousLegacyExecutable = Join-Path `
    $PreviousInstallRoot `
    $script:LegacyCompatibilityApplicationExecutableFileName
$PreviousInstalledExecutable = if (
    Test-Path -LiteralPath $previousCurrentExecutable -PathType Leaf) {
    $previousCurrentExecutable
} elseif (Test-Path -LiteralPath $previousLegacyExecutable -PathType Leaf) {
    $previousLegacyExecutable
} else {
    $previousCurrentExecutable
}
$DataRoot = Get-EverVigilActiveDataRoot
$legacyDataRoot = [IO.Path]::GetFullPath((Join-Path `
        $env:LOCALAPPDATA `
        $script:LegacyCompatibilityApplicationDataRootRelativeToLocalAppData))
$usingLegacyDataRoot = [string]::Equals(
    [IO.Path]::GetFullPath($DataRoot),
    $legacyDataRoot,
    [StringComparison]::OrdinalIgnoreCase)
$tokenEntropyContext = if ($usingLegacyDataRoot) {
    $script:LegacyCompatibilityCryptographyDpapiEntropyContext
} else {
    'EverVigil/token/v1'
}
$TransactionPath = Join-Path `
    $DataRoot `
    $script:LegacyCompatibilityDataTransactionJournalFileName
$installTransactionRecoveryCandidates = @(
    Get-EverVigilInstallTransactionTemporaryFiles -DataRoot $DataRoot)
if ((Test-Path -LiteralPath $TransactionPath) -or
    $installTransactionRecoveryCandidates.Count -gt 0) {
    & $InstallTransactionScript `
        -Action Recover `
        -TransactionPath $TransactionPath
}
if ((Test-Path -LiteralPath $TransactionPath) -or
    @(Get-EverVigilInstallTransactionTemporaryFiles `
            -DataRoot $DataRoot).Count -gt 0) {
    throw "An installer transaction could not be recovered before installation: $TransactionPath"
}
$SettingsPath = Join-Path $DataRoot $script:LegacyCompatibilityDataSettingsFileName
$AppliedSystemConfigurationPath = Join-Path `
    $DataRoot `
    $script:LegacyCompatibilityDataAppliedSystemConfigurationFileName
$TokenPath = Join-Path $DataRoot $script:LegacyCompatibilityDataProtectedTokenFileName
$SystemConfigurationRequiredPath = Join-Path `
    $DataRoot `
    $script:LegacyCompatibilityDataSystemConfigurationRequiredFileName
$ownerProfilePath = Get-ProfilePathForSid -Sid $ownerSid
$fileSystemRoots = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })
$LegacyRootCandidates = @(Get-LegacyRootCandidatesForProfile `
        -ProfilePath $ownerProfilePath `
        -FileSystemRoots $fileSystemRoots)
$LegacyRoot = $null
$LegacyTokenPath = $null
$TransactionId = [guid]::NewGuid().ToString('N')
$CleanupTransactionId = [guid]::NewGuid().ToString('N')
while ([string]::Equals(
        $CleanupTransactionId,
        $TransactionId,
        [StringComparison]::Ordinal)) {
    $CleanupTransactionId = [guid]::NewGuid().ToString('N')
}
$PublishRoot = Join-Path `
    $DataRoot `
    "$($script:LegacyCompatibilityDataInstallerPublishDirectoryPrefix)$TransactionId"
$StagingRoot = "$InstallRoot.staging-$TransactionId"
$BackupRoot = "$InstallRoot.backup-$TransactionId"
$PreviousBackupRoot = "$PreviousInstallRoot.relocated-$TransactionId"
$TransactionRecoveryRoot = Join-Path `
    $DataRoot `
    "$($script:LegacyCompatibilityDataTransactionRecoveryDirectoryName)\$TransactionId"
$RollbackTaskXml = Join-Path $TransactionRecoveryRoot 'legacy-task.xml'
$SystemResultPath = Join-Path $TransactionRecoveryRoot 'system.log'
$PendingSystemJournalPath = Join-Path $DataRoot 'pending-system-configuration.json'
$RecognizedDataRoots = @(
    (Join-Path $env:LOCALAPPDATA 'EverVigil')
    (Join-Path `
        $env:LOCALAPPDATA `
        $script:LegacyCompatibilityApplicationDataRootRelativeToLocalAppData)
) | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique
$PowerShellPath = 'C:\Program Files\PowerShell\7\pwsh.exe'

function Write-InstallTransactionState {
    param([Parameter(Mandatory)]$State)

    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    $temporaryPath = "$TransactionPath.new-$([guid]::NewGuid().ToString('N'))"
    try {
        $content = (($State | ConvertTo-Json -Depth 6) + "`n")
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
        $stream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough)
        try {
            Set-EverVigilAtomicJournalFileAcl -Path $temporaryPath
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        # The protected same-volume temporary carries its ACL into the atomic
        # replacement. Do not perform any fallible operation after Move: a
        # caller must never receive a rollback-triggering exception after the
        # new phase is already durable.
        [IO.File]::Move($temporaryPath, $TransactionPath, $true)
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

$transactionMutex = New-EverVigilSystemTransactionMutex
$transactionLockTaken = $false
try {
    $transactionLockTaken = $transactionMutex.WaitOne([TimeSpan]::FromMinutes(10))
} catch [Threading.AbandonedMutexException] {
    $transactionLockTaken = $true
}
if (-not $transactionLockTaken) {
    $transactionMutex.Dispose()
    throw 'Another EverVigil install or uninstall transaction did not finish within 10 minutes.'
}
if (Test-Path -LiteralPath $TransactionPath) {
    $transactionMutex.ReleaseMutex()
    $transactionMutex.Dispose()
    throw "A pending installer transaction must be recovered before installation: $TransactionPath"
}
$installTransactionTemporaries = @(
    Get-EverVigilInstallTransactionTemporaryFiles -DataRoot $DataRoot)
if ($installTransactionTemporaries.Count -gt 0) {
    $transactionMutex.ReleaseMutex()
    $transactionMutex.Dispose()
    throw "An atomic installer transaction must be recovered before installation: $($installTransactionTemporaries[0].FullName)"
}
foreach ($recognizedDataRoot in $RecognizedDataRoots) {
    if (Test-Path -LiteralPath $recognizedDataRoot -PathType Container) {
        $pendingTemporaries = @(Get-ChildItem `
                -LiteralPath $recognizedDataRoot `
                -File `
                -Force `
                -ErrorAction Stop | Where-Object {
                    $_.Name -cmatch
                        '\Apending-system-configuration\.json\.[0-9a-f]{32}\.tmp\z'
                })
        if ($pendingTemporaries.Count -gt 0) {
            $transactionMutex.ReleaseMutex()
            $transactionMutex.Dispose()
            throw "A possible atomic pending system journal must be recovered before installation: $($pendingTemporaries[0].FullName)"
        }
    }
    $candidatePendingSystemJournal = Join-Path `
        $recognizedDataRoot `
        'pending-system-configuration.json'
    if (Test-Path -LiteralPath $candidatePendingSystemJournal) {
        $transactionMutex.ReleaseMutex()
        $transactionMutex.Dispose()
        throw "A pending system configuration transaction must be recovered before installation: $candidatePendingSystemJournal"
    }
}
$destinationBackupPlanned = Test-Path -LiteralPath $InstallRoot
$previousBackupPlanned = $installRootChanged -and
    (Test-Path -LiteralPath $PreviousInstallRoot)
$newInstallActivated = $false
$migrationApplied = $false
$migrationCommitted = $false
$preserveRecoveryArtifacts = $false
$runtimeConfigurationReady = $false
$systemConfigurationCanBePreserved = $false
$existingSupervisorWasHealthy = $false
$applicationDataRollbackRequired = $false
$dataRootExisted = Test-Path -LiteralPath $DataRoot
$settingsWasPresent = Test-Path -LiteralPath $SettingsPath -PathType Leaf
$tokenWasPresent = Test-Path -LiteralPath $TokenPath -PathType Leaf
$appliedSystemConfigurationWasPresent = Test-Path `
    -LiteralPath $AppliedSystemConfigurationPath `
    -PathType Leaf
$migrateV121SystemState = [bool]$legacyCleanupAuthorized -and
    $appliedSystemConfigurationWasPresent
$systemConfigurationRequiredWasPresent = Test-Path `
    -LiteralPath $SystemConfigurationRequiredPath `
    -PathType Leaf
$diagnosticLoggingWasPresent = Test-Path `
    -LiteralPath (Join-Path `
        $DataRoot `
        $script:LegacyCompatibilityDataDiagnosticLoggingMarkerFileName) `
    -PathType Leaf
$logsRootWasPresent = Test-Path `
    -LiteralPath (Join-Path $DataRoot $script:LegacyCompatibilityDataLogDirectoryName) `
    -PathType Container
$transactionsRootWasPresent = Test-Path `
    -LiteralPath (Join-Path `
        $DataRoot `
        $script:LegacyCompatibilityDataTransactionRecoveryDirectoryName) `
    -PathType Container
$systemConfigurationWasRequired = -not $settingsWasPresent -or
    $systemConfigurationRequiredWasPresent
$legacyCredentialFound = $false
$transactionState = $null
$startupShortcutPath = Join-Path `
    ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) `
    'EverVigil.lnk'
$legacyStartupShortcutPath = Join-Path `
    ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) `
    $script:LegacyCompatibilityApplicationStartupShortcutFileName
$currentStartupTargets = @(
    (Join-Path $InstallRoot 'EverVigil.exe')
    (Join-Path $PreviousInstallRoot 'EverVigil.exe')
) | Select-Object -Unique
$legacyStartupTargets = @(
    (Join-Path `
        $PreviousInstallRoot `
        $script:LegacyCompatibilityApplicationExecutableFileName)
    (Join-Path `
        (Join-Path `
            $env:LOCALAPPDATA `
            $script:LegacyCompatibilityApplicationInstallRootRelativeToLocalAppData) `
        $script:LegacyCompatibilityApplicationExecutableFileName)
) | Select-Object -Unique
$currentStartupOwned = Test-EverVigilShortcutIdentity `
    -Path $startupShortcutPath `
    -ExpectedTargetPath $currentStartupTargets `
    -ExpectedArguments '--background'
$legacyStartupOwned = Test-EverVigilShortcutIdentity `
    -Path $legacyStartupShortcutPath `
    -ExpectedTargetPath $legacyStartupTargets `
    -ExpectedArguments '--background'
if ((Test-Path -LiteralPath $startupShortcutPath -PathType Leaf) -and
    -not $currentStartupOwned) {
    throw "The existing startup shortcut is not owned by EverVigil: $startupShortcutPath"
}
if ((Test-Path -LiteralPath $legacyStartupShortcutPath -PathType Leaf) -and
    -not $legacyStartupOwned) {
    throw "The legacy startup shortcut has an unexpected target or arguments: $legacyStartupShortcutPath"
}
$startupWasRegistered = $currentStartupOwned -or $legacyStartupOwned
$existingSupervisorWasRunning = @(
    Get-EverVigilProcessesAtRoot -Root $InstallRoot
    if ($installRootChanged) {
        Get-EverVigilProcessesAtRoot -Root $PreviousInstallRoot
    }
).Count -gt 0

function Resolve-InitialTailscalePath {
    param(
        [string]$PreferredPath = (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),

        [string[]]$SearchPathValues = @(
            [Environment]::GetEnvironmentVariable(
                'PATH',
                [EnvironmentVariableTarget]::Process)
            [Environment]::GetEnvironmentVariable(
                'PATH',
                [EnvironmentVariableTarget]::User)
            [Environment]::GetEnvironmentVariable(
                'PATH',
                [EnvironmentVariableTarget]::Machine)
        )
    )

    $searchDirectories = $SearchPathValues |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        $_.Split(
            [IO.Path]::PathSeparator,
            [StringSplitOptions]::RemoveEmptyEntries -bor [StringSplitOptions]::TrimEntries)
    } | ForEach-Object { $_.Trim('"') } | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

    foreach ($candidate in @($PreferredPath) + @($searchDirectories | ForEach-Object {
                Join-Path $_ 'tailscale.exe'
            })) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    return [IO.Path]::GetFullPath($PreferredPath)
}

$effectivePublicPort = 3456
$effectiveBackendPort = 3457
$effectiveTailscalePath = Resolve-InitialTailscalePath

function Invoke-AppCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60,
        [string]$ExecutablePath = $InstalledExecutable,
        [string]$WorkingDirectory = $InstallRoot
    )

    return Invoke-EverVigilBoundedProcess `
        -FilePath $ExecutablePath `
        -ArgumentList $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -TimeoutSeconds $TimeoutSeconds
}

function Get-InstalledSupervisorProcesses {
    @(
        Get-EverVigilProcessesAtRoot -Root $InstallRoot
        if ($installRootChanged) {
            Get-EverVigilProcessesAtRoot -Root $PreviousInstallRoot
        }
    )
}

function Invoke-SystemBrokerMaintenance {
    param(
        [ValidateSet('Prepare', 'Install', 'Commit', 'Rollback')][string]$Mode,
        [int]$PublicPort = 0,
        [int]$BackendPort = 0,
        [switch]$MigrateV121SystemState
    )

    if (-not $script:transactionLockTaken) {
        throw 'The installer system transaction mutex is not held before broker invocation.'
    }
    $operation = switch ($Mode) {
        'Prepare' { 'Status' }
        'Install' { 'Apply' }
        'Commit' { 'Commit' }
        'Rollback' { 'Rollback' }
    }
    $transactionMutex.ReleaseMutex()
    $script:transactionLockTaken = $false
    try {
        $brokerResponse = Invoke-EverVigilSystemBroker `
            -Operation $operation `
            -TransactionId ([guid]$TransactionId) `
            -Initiator Installer `
            -PublicPort $(if ($Mode -eq 'Install') { $PublicPort } else { 0 }) `
            -BackendPort $(if ($Mode -eq 'Install') { $BackendPort } else { 0 }) `
            -MigrateV121SystemState:($Mode -eq 'Install' -and $MigrateV121SystemState) `
            -AllowBootstrap:($Mode -eq 'Prepare')
    } finally {
        try {
            $script:transactionLockTaken = $transactionMutex.WaitOne(
                [TimeSpan]::FromMinutes(10))
        } catch [Threading.AbandonedMutexException] {
            $script:transactionLockTaken = $true
        }
        if (-not $script:transactionLockTaken) {
            throw 'The installer could not reacquire the system transaction mutex after elevation.'
        }
    }
    if (-not (Test-Path -LiteralPath $TransactionPath -PathType Leaf)) {
        throw 'The install transaction disappeared while the elevated helper owned the system mutex.'
    }
    try {
        $reloadedTransaction = Get-Content -LiteralPath $TransactionPath -Raw |
            ConvertFrom-Json
    } catch {
        throw "The install transaction became unreadable after elevation: $($_.Exception.Message)"
    }
    if (-not [string]::Equals(
            [string]$reloadedTransaction.transactionId,
            $TransactionId,
            [StringComparison]::Ordinal)) {
        throw 'The install transaction identity changed while the elevated helper owned the system mutex.'
    }
    foreach ($recognizedDataRoot in $RecognizedDataRoots) {
        if (Test-Path -LiteralPath $recognizedDataRoot -PathType Container) {
            $pendingTemporaries = @(Get-ChildItem `
                    -LiteralPath $recognizedDataRoot `
                    -File `
                    -Force `
                    -ErrorAction Stop | Where-Object {
                        $_.Name -cmatch
                            '\Apending-system-configuration\.json\.[0-9a-f]{32}\.tmp\z'
                    })
            foreach ($pendingTemporary in $pendingTemporaries) {
                $expectedRollbackTemporary =
                    "pending-system-configuration.json.$TransactionId.tmp"
                $isAuthorizedRollbackTemporary = $Mode -eq 'Rollback' -and
                    [string]::Equals(
                        $recognizedDataRoot,
                        $DataRoot,
                        [StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals(
                        $pendingTemporary.Name,
                        $expectedRollbackTemporary,
                        [StringComparison]::Ordinal)
                if (-not $isAuthorizedRollbackTemporary) {
                    throw "An unrecognized atomic pending-system journal appeared during broker execution: $($pendingTemporary.FullName)"
                }
                if (($pendingTemporary.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $pendingTemporary.Length -gt 1048576 -or
                    -not (Test-EverVigilAtomicJournalFileAcl `
                        -Path $pendingTemporary.FullName)) {
                    throw "The rollback pending-system temporary has an invalid identity: $($pendingTemporary.FullName)"
                }
            }
        }
        $candidate = Join-Path $recognizedDataRoot 'pending-system-configuration.json'
        if ((Test-Path -LiteralPath $candidate) -and
            -not [string]::Equals(
                [IO.Path]::GetFullPath($candidate),
                [IO.Path]::GetFullPath($PendingSystemJournalPath),
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "A foreign pending system journal appeared during elevation: $candidate"
        }
    }
    $pending = Read-InstallerPendingSystemJournal
    if ($Mode -eq 'Prepare') {
        if ([string]$brokerResponse.disposition -cne 'NoChange' -or $pending) {
            throw 'The protected broker bootstrap/status preflight did not finish cleanly.'
        }
    } elseif ($Mode -eq 'Install') {
        if ([string]$brokerResponse.disposition -cne 'Completed' -or -not $pending) {
            throw 'The protected broker returned without durable Apply completion.'
        }
        $pending.phase = 'MutationsCompleted'
        Write-InstallPendingSystemJournalState -State $pending
    } elseif ($Mode -eq 'Commit') {
        if ([string]$brokerResponse.disposition -cnotin @('Completed', 'NoChange')) {
            throw "The protected broker returned an unexpected Commit disposition: $($brokerResponse.disposition)"
        }
        if ($pending) {
            Remove-Item -LiteralPath $PendingSystemJournalPath -Force -ErrorAction Stop
        }
    } else {
        if ([string]$brokerResponse.disposition -cnotin @('RolledBack', 'NoChange')) {
            throw "The protected broker returned an unexpected Rollback disposition: $($brokerResponse.disposition)"
        }
        if ($pending) {
            Remove-Item -LiteralPath $PendingSystemJournalPath -Force -ErrorAction Stop
        }
        Remove-InstallerSystemJournalTemporariesAfterRollback `
            -ExpectedTransactionId $TransactionId
    }
}

function Invoke-InitialInstallProtectedBrokerCleanup {
    param([Parameter(Mandatory)]$State)

    if ($State -is [Collections.IDictionary]) {
        $State = [pscustomobject]$State
    }
    $protectedBrokerReadyProperty =
        $State.PSObject.Properties['protectedBrokerReady']
    $protectedBrokerCleanupAuthorizedProperty =
        $State.PSObject.Properties['protectedBrokerCleanupAuthorized']
    $protectedBrokerWasPresentBeforeProperty =
        $State.PSObject.Properties['protectedBrokerWasPresentBefore']
    $protectedCleanupAuthorized =
        ($null -ne $protectedBrokerReadyProperty -and
            $protectedBrokerReadyProperty.Value -eq $true) -or
        ($null -ne $protectedBrokerCleanupAuthorizedProperty -and
            $protectedBrokerCleanupAuthorizedProperty.Value -eq $true)
    $protectedBrokerWasPresentBefore = if (
        $null -ne $protectedBrokerWasPresentBeforeProperty) {
        $protectedBrokerWasPresentBeforeProperty.Value -eq $true
    } else {
        # Journals created before the pre-state field existed are conservative:
        # a prior owned install may already have owned the shared broker.
        [bool]$State.existingInstallPresent
    }
    if (-not $protectedCleanupAuthorized -or
        $protectedBrokerWasPresentBefore) {
        return
    }
    if (-not $script:transactionLockTaken) {
        throw 'The installer transaction mutex is required for initial broker cleanup.'
    }
    $paths = Get-EverVigilProtectedBrokerRetirementPaths
    if (-not (Test-Path -LiteralPath $paths.ProductRoot)) {
        return
    }
    $cleanupTransactionIdProperty =
        $State.PSObject.Properties['cleanupTransactionId']
    if ($null -eq $cleanupTransactionIdProperty -or
        $cleanupTransactionIdProperty.Value -isnot [string] -or
        [string]$cleanupTransactionIdProperty.Value -cnotmatch
            '\A[0-9a-f]{32}\z' -or
        [string]::Equals(
            [string]$cleanupTransactionIdProperty.Value,
            [string]$State.transactionId,
            [StringComparison]::Ordinal)) {
        throw 'The initial broker cleanup transaction identity is missing, malformed, or reused.'
    }
    $cleanupTransactionId = [guid][string]$cleanupTransactionIdProperty.Value
    $ownerSid = [string]$State.ownerSid
    if (-not (Test-Path -LiteralPath $paths.CanonicalPath -PathType Leaf)) {
        Complete-EverVigilProtectedBrokerRetirementFromReceipt `
            -ExpectedOwnerSid $ownerSid `
            -ExpectedTransactionId $cleanupTransactionId
        return
    }

    $brokerResponse = $null
    $lastInvocationError = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $transactionMutex.ReleaseMutex()
        $script:transactionLockTaken = $false
        try {
            $brokerResponse = Invoke-EverVigilSystemBroker `
                -Operation UninstallCleanup `
                -TransactionId $cleanupTransactionId `
                -Initiator Installer
            $lastInvocationError = $null
        } catch {
            $lastInvocationError = $_
        } finally {
            try {
                $script:transactionLockTaken = $transactionMutex.WaitOne(
                    [TimeSpan]::FromMinutes(10))
            } catch [Threading.AbandonedMutexException] {
                $script:transactionLockTaken = $true
            }
            if (-not $script:transactionLockTaken) {
                throw 'Installer rollback could not reacquire the system mutex after broker cleanup.'
            }
        }
        if (-not (Test-Path -LiteralPath $TransactionPath -PathType Leaf)) {
            throw 'The install transaction disappeared during initial broker cleanup.'
        }
        try {
            $reloadedTransaction = Get-Content `
                -LiteralPath $TransactionPath `
                -Raw `
                -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "The install transaction became unreadable during initial broker cleanup: $($_.Exception.Message)"
        }
        if (-not [string]::Equals(
                [string]$reloadedTransaction.transactionId,
                [string]$State.transactionId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$reloadedTransaction.cleanupTransactionId,
                [string]$State.cleanupTransactionId,
                [StringComparison]::Ordinal)) {
            throw 'The install transaction changed during initial broker cleanup.'
        }
        if ($null -ne $brokerResponse) {
            break
        }
        if (-not (Test-Path `
                -LiteralPath $paths.CanonicalPath `
                -PathType Leaf)) {
            break
        }
    }

    if ($null -eq $brokerResponse) {
        if (-not (Test-Path `
                -LiteralPath $paths.RetirementReceiptPath `
                -PathType Leaf)) {
            throw $lastInvocationError
        }
        Complete-EverVigilProtectedBrokerRetirementFromReceipt `
            -ExpectedOwnerSid $ownerSid `
            -ExpectedTransactionId $cleanupTransactionId
        return
    }
    if ([string]$brokerResponse.disposition -ceq 'RetirementRequired') {
        Complete-EverVigilProtectedBrokerRetirementFromReceipt `
            -ExpectedOwnerSid $ownerSid `
            -ExpectedTransactionId $cleanupTransactionId
        return
    }
    if ([string]$brokerResponse.disposition -cnotin @('Completed', 'NoChange')) {
        throw "Initial protected broker cleanup returned an unexpected disposition: $($brokerResponse.disposition)"
    }
    if (Test-Path -LiteralPath $paths.RetirementReceiptPath) {
        throw 'Initial protected broker cleanup returned without completing durable retirement.'
    }
}

function Read-PersistedSystemConfiguration {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [switch]$RequireTailscaleExecutable
    )

    try {
        $persisted = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $configuration = [pscustomobject]@{
            PublicPort = [int]$persisted.publicPort
            BackendPort = [int]$persisted.backendPort
            TailscalePath = [string]$persisted.tailscalePath
        }
    } catch {
        throw "Could not read $Description at '$Path': $($_.Exception.Message)"
    }
    if ($configuration.PublicPort -lt 1024 -or $configuration.PublicPort -gt 65535 -or
        $configuration.BackendPort -lt 1024 -or $configuration.BackendPort -gt 65535 -or
        $configuration.PublicPort -eq $configuration.BackendPort) {
        throw "$Description contains invalid ports: $($configuration.PublicPort)/$($configuration.BackendPort)"
    }
    if ([string]::IsNullOrWhiteSpace($configuration.TailscalePath) -or
        $configuration.TailscalePath.Contains('"') -or
                -not (Test-EverVigilPathFullyQualified -Path $configuration.TailscalePath) -or
        ($RequireTailscaleExecutable -and
            -not (Test-Path -LiteralPath $configuration.TailscalePath -PathType Leaf))) {
        throw "$Description contains an invalid Tailscale path: $($configuration.TailscalePath)"
    }

    $configuration.TailscalePath = [IO.Path]::GetFullPath($configuration.TailscalePath)
    return $configuration
}

function Test-SameSystemConfiguration {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )

    return $Left.PublicPort -eq $Right.PublicPort -and
        $Left.BackendPort -eq $Right.BackendPort -and
        [string]::Equals(
            $Left.TailscalePath,
            $Right.TailscalePath,
            [StringComparison]::OrdinalIgnoreCase)
}

function Read-ExactAppliedSystemConfiguration {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        -not (Test-EverVigilAtomicJournalFileAcl -Path $Path)) {
        throw "The applied system configuration file is missing or has an invalid identity: $Path"
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 1 -or $bytes.Length -gt 16384) {
            throw 'The applied system configuration size is invalid.'
        }
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $document = [Text.Json.JsonDocument]::Parse($json)
        try {
            if ($document.RootElement.ValueKind -ne
                [Text.Json.JsonValueKind]::Object) {
                throw 'The applied system configuration root must be an object.'
            }
            $properties = @($document.RootElement.EnumerateObject())
            $expectedNames = @('publicPort', 'backendPort', 'tailscalePath')
            if ($properties.Count -ne $expectedNames.Count -or
                @($properties.Name | Sort-Object -Unique).Count -ne
                    $expectedNames.Count -or
                @($properties.Name | Where-Object {
                        $_ -cnotin $expectedNames
                    }).Count -gt 0) {
                throw 'The applied system configuration schema is not exact.'
            }
            $publicPortElement = $document.RootElement.GetProperty('publicPort')
            $backendPortElement = $document.RootElement.GetProperty('backendPort')
            $tailscalePathElement = $document.RootElement.GetProperty('tailscalePath')
            if ($publicPortElement.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
                $backendPortElement.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
                $tailscalePathElement.ValueKind -ne [Text.Json.JsonValueKind]::String) {
                throw 'The applied system configuration contains an invalid JSON type.'
            }
            $configuration = [pscustomobject]@{
                PublicPort = $publicPortElement.GetInt32()
                BackendPort = $backendPortElement.GetInt32()
                TailscalePath = $tailscalePathElement.GetString()
            }
        } finally {
            $document.Dispose()
        }
    } catch {
        throw "The applied system configuration is invalid at '$Path': $($_.Exception.Message)"
    }
    if ($configuration.PublicPort -lt 1024 -or
        $configuration.PublicPort -gt 65535 -or
        $configuration.BackendPort -lt 1024 -or
        $configuration.BackendPort -gt 65535 -or
        $configuration.PublicPort -eq $configuration.BackendPort -or
        [string]::IsNullOrWhiteSpace($configuration.TailscalePath) -or
        $configuration.TailscalePath.Contains('"') -or
        -not (Test-EverVigilPathFullyQualified -Path $configuration.TailscalePath)) {
        throw 'The applied system configuration values are invalid.'
    }
    $configuration.TailscalePath =
        [IO.Path]::GetFullPath($configuration.TailscalePath)
    return $configuration
}

function Commit-InstallerSystemConfigurationLocally {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$ExpectedTarget
    )

    if (-not $script:transactionLockTaken) {
        throw 'The installer transaction mutex is required before local system commit.'
    }
    $pending = Read-InstallerPendingSystemJournal
    if ($null -eq $pending -or
        [string]$pending.transactionId -cne [string]$State.transactionId -or
        [string]$pending.ownerSid -cne [string]$State.ownerSid -or
        [string]$pending.initiator -cne 'Installer' -or
        [string]$pending.phase -cne 'MutationsCompleted') {
        throw 'The installer-owned pending system journal is not ready for local commit.'
    }

    $commandExitCode = $null
    $commandError = $null
    $transactionMutex.ReleaseMutex()
    $script:transactionLockTaken = $false
    try {
        $commandExitCode = Invoke-AppCommand -Arguments @(
            '--commit-installer-system-config'
            '--system-transaction-id'
            ([string]$State.transactionId))
    } catch {
        $commandError = $_
    } finally {
        try {
            $script:transactionLockTaken = $transactionMutex.WaitOne(
                [TimeSpan]::FromMinutes(10))
        } catch [Threading.AbandonedMutexException] {
            $script:transactionLockTaken = $true
        }
        if (-not $script:transactionLockTaken) {
            throw 'The installer could not reacquire the system mutex after local configuration commit.'
        }
    }

    if (-not (Test-Path -LiteralPath $TransactionPath -PathType Leaf)) {
        throw 'The install transaction disappeared during local system commit.'
    }
    try {
        $reloadedTransaction = Get-Content `
            -LiteralPath $TransactionPath `
            -Raw `
            -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "The install transaction became unreadable during local system commit: $($_.Exception.Message)"
    }
    if (-not [string]::Equals(
            [string]$reloadedTransaction.transactionId,
            [string]$State.transactionId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$reloadedTransaction.cleanupTransactionId,
            [string]$State.cleanupTransactionId,
            [StringComparison]::Ordinal)) {
        throw 'The install transaction identity changed during local system commit.'
    }

    $pendingTemporaries = @(Get-ChildItem `
            -LiteralPath $DataRoot `
            -File `
            -Force `
            -ErrorAction Stop | Where-Object {
                $_.Name -cmatch
                    '\A(?:pending-system-configuration|applied-system-configuration)\.json\.[0-9a-f]{32}\.tmp\z'
            })
    $postconditionSatisfied =
        -not (Test-Path -LiteralPath $PendingSystemJournalPath) -and
        $pendingTemporaries.Count -eq 0 -and
        -not (Test-Path -LiteralPath $SystemConfigurationRequiredPath) -and
        (Test-Path -LiteralPath $AppliedSystemConfigurationPath -PathType Leaf)
    $appliedConfiguration = $null
    if ($postconditionSatisfied) {
        try {
            $appliedConfiguration = Read-ExactAppliedSystemConfiguration `
                -Path $AppliedSystemConfigurationPath
            $postconditionSatisfied = Test-SameSystemConfiguration `
                -Left $appliedConfiguration `
                -Right $ExpectedTarget
        } catch {
            $postconditionSatisfied = $false
            if ($null -eq $commandError) {
                $commandError = $_
            }
        }
    }
    if (-not $postconditionSatisfied) {
        if ($null -ne $commandError) {
            throw $commandError
        }
        throw "Local installer system commit did not reach its exact postcondition (exit code $commandExitCode)."
    }
}

function Get-ConfiguredPorts {
    $configuration = [pscustomobject]@{
        PublicPort = 3456
        BackendPort = 3457
        TailscalePath = Resolve-InitialTailscalePath
    }
    if ($settingsWasPresent) {
        if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
            throw "Persisted settings disappeared during installation: $SettingsPath"
        }
        $configuration = Read-PersistedSystemConfiguration `
            -Path $SettingsPath `
            -Description 'persisted settings'
    } elseif (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
        throw "Persisted settings appeared during installation: $SettingsPath"
    } elseif (Test-Path -LiteralPath $AppliedSystemConfigurationPath -PathType Leaf) {
        throw "Persisted settings are missing while applied system configuration exists. Restore settings or uninstall before reinstalling: $AppliedSystemConfigurationPath"
    }

    if ($configuration.PublicPort -lt 1024 -or $configuration.PublicPort -gt 65535 -or
        $configuration.BackendPort -lt 1024 -or $configuration.BackendPort -gt 65535 -or
        $configuration.PublicPort -eq $configuration.BackendPort) {
        throw "Persisted public/backend ports are invalid: $($configuration.PublicPort)/$($configuration.BackendPort)"
    }
    if ([string]::IsNullOrWhiteSpace($configuration.TailscalePath) -or
        $configuration.TailscalePath.Contains('"') -or
        -not (Test-EverVigilPathFullyQualified -Path $configuration.TailscalePath)) {
        throw "Persisted Tailscale path is invalid: $($configuration.TailscalePath)"
    }
    $configuration.TailscalePath = [IO.Path]::GetFullPath($configuration.TailscalePath)

    if (Test-Path -LiteralPath $AppliedSystemConfigurationPath -PathType Leaf) {
        $appliedConfiguration = Read-PersistedSystemConfiguration `
            -Path $AppliedSystemConfigurationPath `
            -Description 'the last applied system configuration'
        if (-not (Test-SameSystemConfiguration -Left $configuration -Right $appliedConfiguration)) {
            throw 'Persisted settings do not match the last applied system configuration. Reapply or uninstall the pending configuration before installing.'
        }
    }

    return $configuration
}

function Read-InstallerPendingSystemJournal {
    if (-not (Test-Path -LiteralPath $PendingSystemJournalPath -PathType Leaf)) {
        return $null
    }
    $item = Get-Item -LiteralPath $PendingSystemJournalPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The pending system journal is a reparse point: $PendingSystemJournalPath"
    }
    try {
        $state = Get-Content -LiteralPath $PendingSystemJournalPath -Raw | ConvertFrom-Json
    } catch {
        throw "The pending system journal is invalid JSON: $($_.Exception.Message)"
    }
    if ([int]$state.schemaVersion -ne 1 -or
        [string]$state.initiator -cne 'Installer' -or
        -not [string]::Equals(
            ([guid][string]$state.transactionId).ToString('N'),
            ([guid]$TransactionId).ToString('N'),
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$state.ownerSid, $ownerSid, [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$state.dataRoot).TrimEnd('\'),
            [IO.Path]::GetFullPath($DataRoot).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The pending system journal identity does not match the install transaction.'
    }
    return $state
}

function Write-InstallPendingSystemJournalState {
    param([Parameter(Mandatory)]$State)

    $stateTransactionId = ([guid][string]$State.transactionId).ToString('N')
    if (-not [string]::Equals(
            $stateTransactionId,
            ([guid]$TransactionId).ToString('N'),
            [StringComparison]::Ordinal)) {
        throw 'The pending system journal cannot be written for another install transaction.'
    }
    # The transaction identifier is part of the atomic name so a crash residue
    # can be correlated with the durable install journal. A random name would
    # leave no safe recovery authority after a power loss.
    $temporaryPath = "$PendingSystemJournalPath.$stateTransactionId.tmp"
    if (Test-Path -LiteralPath $temporaryPath) {
        $temporaryItem = Get-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        if ($temporaryItem.PSIsContainer -or
            ($temporaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not (Test-EverVigilAtomicJournalFileAcl -Path $temporaryItem.FullName)) {
            throw "The pending system journal temporary has an invalid identity: $temporaryPath"
        }
        throw "A pending system journal write for this transaction must be recovered first: $temporaryPath"
    }
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
            (($State | ConvertTo-Json -Depth 8) + "`n"))
        $stream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough)
        try {
            # Apply the final owner/SYSTEM/Administrators DACL before the first
            # byte. A zero/partial hard-crash residue must remain recoverable
            # under the exact transaction ID instead of inheriting a broad ACL.
            Set-EverVigilAtomicJournalFileAcl -Path $temporaryPath
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        # Atomic replacement is the final fallible operation; the temporary
        # already has the exact final ACL.
        [IO.File]::Move($temporaryPath, $PendingSystemJournalPath, $true)
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-InstallerSystemJournalTemporariesForTransaction {
    param([Parameter(Mandatory)][string]$ExpectedTransactionId)

    if (-not $script:transactionLockTaken) {
        throw 'The system transaction mutex is required before inspecting system journal temporaries.'
    }
    $normalizedTransactionId = ([guid]$ExpectedTransactionId).ToString('N')
    $recognizedPattern =
        '\A(?<stable>pending-system-configuration|applied-system-configuration)\.json\.(?<id>[0-9a-f]{32})\.tmp\z'
    $temporaries = @(if (Test-Path -LiteralPath $DataRoot -PathType Container) {
            Get-ChildItem -LiteralPath $DataRoot -File -Force -ErrorAction Stop |
                Where-Object { $_.Name -cmatch $recognizedPattern }
        })
    foreach ($temporary in $temporaries) {
        [void]($temporary.Name -cmatch $recognizedPattern)
        if (-not [string]::Equals(
                [string]$Matches.id,
                $normalizedTransactionId,
                [StringComparison]::Ordinal)) {
            throw "A system journal temporary belongs to another transaction: $($temporary.FullName)"
        }
        if ($temporary.PSIsContainer -or
            ($temporary.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $temporary.Length -gt 1048576 -or
            -not (Test-EverVigilAtomicJournalFileAcl -Path $temporary.FullName)) {
            throw "A system journal temporary has an invalid identity: $($temporary.FullName)"
        }
    }
    return @($temporaries)
}

function Remove-InstallerSystemJournalTemporariesAfterRollback {
    param([Parameter(Mandatory)][string]$ExpectedTransactionId)

    $temporaries = @(Get-InstallerSystemJournalTemporariesForTransaction `
            -ExpectedTransactionId $ExpectedTransactionId)
    foreach ($temporary in $temporaries) {
        Remove-Item -LiteralPath $temporary.FullName -Force -ErrorAction Stop
    }
}

function New-InstallPendingSystemJournal {
    param(
        [Parameter(Mandatory)]$Target,
        $Previous,
        [switch]$PreviousMappingOwned,
        [switch]$ExistingTargetMappingOwned
    )

    if (Test-Path -LiteralPath $PendingSystemJournalPath) {
        throw "A pending system journal already exists: $PendingSystemJournalPath"
    }
    $state = [ordered]@{
        schemaVersion = 1
        transactionId = ([guid]$TransactionId).ToString()
        ownerSid = $ownerSid
        dataRoot = [IO.Path]::GetFullPath($DataRoot)
        initiator = 'Installer'
        target = $Target
        previous = $Previous
        previousMappingOwned = [bool]$PreviousMappingOwned
        existingTargetMappingOwned = [bool]$ExistingTargetMappingOwned
        phase = 'Prepared'
        observedTargetRouteOwnership = $null
        observedPreviousRouteOwnership = $null
        firewallSnapshotCaptured = $false
        originalMainFirewallPort = $null
        originalTemporaryFirewallPort = $null
        previousRouteMutationAuthorized = $false
        targetRouteMutationAuthorized = $false
        firewallMutationAuthorized = $false
    }
    Write-InstallPendingSystemJournalState -State $state
}

function Remove-UnmutatedInstallPendingSystemJournal {
    if (-not $script:transactionLockTaken) {
        throw 'The system transaction mutex must be held before removing a pending journal.'
    }
    $pending = Read-InstallerPendingSystemJournal
    if (-not $pending) {
        return $false
    }
    $phaseProperty = $pending.PSObject.Properties['phase']
    $authorizationProperties = @(
        $pending.PSObject.Properties['previousRouteMutationAuthorized']
        $pending.PSObject.Properties['targetRouteMutationAuthorized']
        $pending.PSObject.Properties['firewallMutationAuthorized']
    )
    if (-not $phaseProperty -or
        $phaseProperty.Value -isnot [string] -or
        [string]$phaseProperty.Value -notin @('Prepared', 'PreflightVerified') -or
        $authorizationProperties.Count -ne 3 -or
        @($authorizationProperties | Where-Object {
                -not $_ -or $_.Value -isnot [bool]
            }).Count -gt 0) {
        throw 'The pending system journal does not contain strict mutation authorization booleans.'
    }
    if (@($authorizationProperties | Where-Object { $_.Value -eq $true }).Count -gt 0) {
        return $false
    }
    Remove-Item -LiteralPath $PendingSystemJournalPath -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $PendingSystemJournalPath) {
        throw 'The unmutated pending system journal could not be removed.'
    }
    return $true
}

function Get-LegacyTokenCredential {
    param([Parameter(Mandatory)][string[]]$CandidateRoots)

    $credentials = @(
        foreach ($candidateRoot in $CandidateRoots) {
            $candidateTokenPath = Join-Path $candidateRoot 'token.txt'
            if (-not (Test-Path -LiteralPath $candidateTokenPath -PathType Leaf)) {
                continue
            }

            try {
                $legacyToken = [IO.File]::ReadAllText(
                    $candidateTokenPath,
                    [Text.Encoding]::ASCII).Trim()
                if ($legacyToken -cmatch '\A[0-9A-Fa-f]{32}\z') {
                    [pscustomobject]@{
                        Root = [IO.Path]::GetFullPath($candidateRoot)
                        TokenPath = [IO.Path]::GetFullPath($candidateTokenPath)
                    }
                }
            } catch {
                # An unreadable candidate is not accepted as migration ownership evidence.
            }
        }
    )
    if ($credentials.Count -gt 1) {
        throw 'Multiple valid legacy credentials were found. Remove the ambiguity before installing.'
    }

    return $credentials | Select-Object -First 1
}

$legacyCredential = Get-LegacyTokenCredential -CandidateRoots $LegacyRootCandidates
if ($legacyCredential) {
    $LegacyRoot = $legacyCredential.Root
    $LegacyTokenPath = $legacyCredential.TokenPath
    $legacyCredentialFound = $true
}

function Restore-SystemConfigurationRequirement {
    if (-not $systemConfigurationWasRequired -or
        (Test-Path -LiteralPath $SystemConfigurationRequiredPath -PathType Leaf)) {
        return
    }

    Set-SystemConfigurationRequirement -Reason 'Installer rollback restored a prior startup block'
}

function Set-SystemConfigurationRequirement {
    param([Parameter(Mandatory)][string]$Reason)

    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    Set-Content `
        -LiteralPath $SystemConfigurationRequiredPath `
        -Value "$Reason at $(Get-Date -Format o)" `
        -Encoding UTF8
}

function Wait-NewSupervisorHealthy {
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 4
        try {
            if ((Invoke-AppCommand -Arguments @('--health-check') -TimeoutSeconds 60) -eq 0) {
                return $true
            }
        } catch {
            # Startup health can fail transiently while Codex app-server initializes.
        }
    }
    return $false
}

function Wait-NewSupervisorStarted {
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        if (@(Get-InstalledSupervisorProcesses).Count -eq 0) {
            continue
        }

        Start-Sleep -Seconds 2
        return @(Get-InstalledSupervisorProcesses).Count -gt 0
    }
    return $false
}

function Remove-ExactTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
    if (-not [string]::Equals($resolved, $expectedFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected path: $resolved"
    }
    $root = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if (-not $root.PSIsContainer) {
        throw "Refusing to remove a transaction path that is not a directory: $resolved"
    }
    $entries = @(
        $root
        Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    )
    if (@($entries | Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            }).Count -gt 0) {
        throw "Refusing to remove a transaction tree containing a reparse point: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Remove-InstallTransactionTree {
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$ValidateTree = {}
    )

    if ($null -eq $transactionState) {
        if (Test-Path -LiteralPath $Path) {
            & $ValidateTree
            Remove-ExactTree -Path $Path -Expected $Path
        }
        return
    }
    $target = Get-EverVigilTransactionDeletionTarget `
        -State $transactionState `
        -Role $Role
    if (-not [string]::Equals(
            [IO.Path]::GetFullPath($Path),
            $target,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The requested transaction deletion does not match role '$Role': $Path"
    }

    $transactionFilePath = $TransactionPath
    $persistence = if (Test-Path -LiteralPath $transactionFilePath -PathType Leaf) {
        {
            param($CurrentState)
            Write-InstallTransactionState -State $CurrentState
        }
    } else {
        { param($CurrentState) }
    }
    Invoke-EverVigilTransactionTreeRemoval `
        -State $transactionState `
        -Role $Role `
        -PersistState $persistence `
        -ValidateTree $ValidateTree
}

function Test-ExistingSupervisorHealth {
    param(
        [Parameter(Mandatory)][string]$TokenPath,
        [Parameter(Mandatory)][string]$EntropyContext,
        [Parameter(Mandatory)][int]$BackendPort
    )

    $handler = $null
    $client = $null
    try {
        if (-not (Test-Path -LiteralPath $TokenPath -PathType Leaf)) {
            return $false
        }

        Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop
        $entropy = [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($EntropyContext))
        $tokenBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            [IO.File]::ReadAllBytes($TokenPath),
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $token = [Text.Encoding]::ASCII.GetString($tokenBytes)
        if ($token -cnotmatch '\A[0-9A-Fa-f]{32}\z') {
            return $false
        }

        $handler = [Net.Http.SocketsHttpHandler]::new()
        $handler.AllowAutoRedirect = $false
        $handler.UseProxy = $false
        $handler.ConnectTimeout = [TimeSpan]::FromSeconds(5)
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $endpoint =
            "http://127.0.0.1:$BackendPort/api/sessions?provider=codex&limit=1"
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $endpoint)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new(
            'Bearer',
            $token)
        $response = $null
        $document = $null
        try {
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                return $false
            }
            $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $document = [Text.Json.JsonDocument]::Parse($content)
            $sessions = [Text.Json.JsonElement]::new()
            $error = [Text.Json.JsonElement]::new()
            if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                -not $document.RootElement.TryGetProperty('sessions', [ref]$sessions) -or
                $sessions.ValueKind -ne [Text.Json.JsonValueKind]::Array -or
                $document.RootElement.TryGetProperty('error', [ref]$error)) {
                return $false
            }
        } finally {
            if ($document) {
                $document.Dispose()
            }
            if ($response) {
                $response.Dispose()
            }
            $request.Dispose()
        }
        return $true
    } catch {
        return $false
    } finally {
        if ($client) {
            $client.Dispose()
        }
        if ($handler) {
            $handler.Dispose()
        }
    }
}

function Remove-NewApplicationData {
    foreach ($fileState in @(
            [pscustomobject]@{
                Name = $script:LegacyCompatibilityDataSettingsFileName
                WasPresent = $settingsWasPresent
            }
            [pscustomobject]@{
                Name = $script:LegacyCompatibilityDataProtectedTokenFileName
                WasPresent = $tokenWasPresent
            }
            [pscustomobject]@{
                Name = $script:LegacyCompatibilityDataAppliedSystemConfigurationFileName
                WasPresent = $appliedSystemConfigurationWasPresent
            }
            [pscustomobject]@{
                Name = $script:LegacyCompatibilityDataSystemConfigurationRequiredFileName
                WasPresent = $systemConfigurationRequiredWasPresent
            }
            [pscustomobject]@{
                Name = $script:LegacyCompatibilityDataDiagnosticLoggingMarkerFileName
                WasPresent = $diagnosticLoggingWasPresent
            }
        )) {
        if (-not $fileState.WasPresent) {
            Remove-Item `
                -LiteralPath (Join-Path $DataRoot $fileState.Name) `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    $logRoot = Join-Path $DataRoot $script:LegacyCompatibilityDataLogDirectoryName
    if (-not $logsRootWasPresent -and
        (Test-Path -LiteralPath $logRoot -PathType Container)) {
        $ownedLogNames = @(
            'evervigil.log'
            $script:LegacyCompatibilityDataLogFileName
        ) | Select-Object -Unique
        Get-ChildItem -LiteralPath $logRoot -File -Force |
            Where-Object {
                $fileName = $_.Name
                @($ownedLogNames | Where-Object {
                        $fileName -ceq $_ -or
                        $fileName -cmatch ('\A' + [regex]::Escape($_) + '\.[1-9][0-9]*\z')
                    }).Count -gt 0
            } |
            Remove-Item -Force
        if (@(Get-ChildItem -LiteralPath $logRoot -Force).Count -eq 0) {
            Remove-Item -LiteralPath $logRoot -Force
        }
    }
    $transactionsRoot = Join-Path `
        $DataRoot `
        $script:LegacyCompatibilityDataTransactionRecoveryDirectoryName
    if (-not $transactionsRootWasPresent -and
        (Test-Path -LiteralPath $transactionsRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $transactionsRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $transactionsRoot -Force
    }
    if (-not $dataRootExisted -and
        (Test-Path -LiteralPath $DataRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $DataRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $DataRoot -Force
    }
}

function Remove-TransactionRecoveryArtifacts {
    Remove-InstallTransactionTree `
        -Role recoveryRoot `
        -Path $TransactionRecoveryRoot
    $transactionsRoot = Join-Path `
        $DataRoot `
        $script:LegacyCompatibilityDataTransactionRecoveryDirectoryName
    if (-not $transactionsRootWasPresent -and
        (Test-Path -LiteralPath $transactionsRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $transactionsRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $transactionsRoot -Force
    }
}

function Assert-TargetExecutableVersion {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The target executable is missing: $Path"
    }
    $versionInfo = (Get-Item -LiteralPath $Path -Force).VersionInfo
    if (-not [string]::Equals(
            [string]$versionInfo.ProductVersion,
            $TargetVersion,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$versionInfo.ProductName,
            'EverVigil',
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$versionInfo.OriginalFilename,
            'EverVigil.exe',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The target executable metadata does not match EverVigil ${TargetVersion}: $Path"
    }
}

try {
    $configuredPorts = Get-ConfiguredPorts
    $effectivePublicPort = $configuredPorts.PublicPort
    $effectiveBackendPort = $configuredPorts.BackendPort
    $effectiveTailscalePath = $configuredPorts.TailscalePath

    if ($existingInstallPresent -and
        $existingSupervisorWasRunning -and
        $appliedSystemConfigurationWasPresent -and
        $tokenWasPresent -and
        -not $systemConfigurationRequiredWasPresent -and
        -not $legacyCredentialFound) {
        try {
            $existingSupervisorWasHealthy = Test-ExistingSupervisorHealth `
                -TokenPath $TokenPath `
                -EntropyContext $tokenEntropyContext `
                -BackendPort $effectiveBackendPort
            # The token-bearing health check proves only the loopback backend. System
            # route/firewall state is reconciled separately by the protected broker,
            # whose protected ledger is the sole ownership authority.
            $systemConfigurationCanBePreserved = $false
        } catch {
            $systemConfigurationCanBePreserved = $false
        }
    }

    foreach ($requiredPath in @(
            $SystemScript
            $InstallTransactionScript
            $LegacyCompatibilityHelper
            $PowerShellPath
        )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required path not found: $requiredPath"
        }
    }

    foreach ($transactionArtifact in @(
            $PublishRoot
            $StagingRoot
            $BackupRoot
            $PreviousBackupRoot
            $TransactionRecoveryRoot
        )) {
        if (Test-Path -LiteralPath $transactionArtifact) {
            throw "A transaction artifact already exists at the generated path: $transactionArtifact"
        }
    }
    $protectedBrokerPathBeforeBootstrap =
        Get-EverVigilProtectedBrokerPath
    $protectedBrokerWasPresentBefore = $false
    if (Test-Path -LiteralPath $protectedBrokerPathBeforeBootstrap) {
        if (-not (Test-Path `
                -LiteralPath $protectedBrokerPathBeforeBootstrap `
                -PathType Leaf) -or
            -not (Test-EverVigilProtectedBrokerInstallation `
                -BrokerPath $protectedBrokerPathBeforeBootstrap)) {
            throw "The pre-existing protected broker installation is invalid: $protectedBrokerPathBeforeBootstrap"
        }
        $protectedBrokerWasPresentBefore = $true
    }
    $transactionState = [ordered]@{
        schemaVersion = [int]$script:LegacyCompatibilityDataTransactionSchemaVersion
        appId = $script:EverVigilAppId
        ownerSid = $ownerSid
        status = 'staging'
        deletionIntent = 'none'
        transactionId = $TransactionId
        cleanupTransactionId = $CleanupTransactionId
        installRoot = $InstallRoot
        previousInstallRoot = $PreviousInstallRoot
        installRootChanged = $installRootChanged
        publishRoot = $PublishRoot
        stagingRoot = $StagingRoot
        backupRoot = $BackupRoot
        previousBackupRoot = $PreviousBackupRoot
        recoveryRoot = $TransactionRecoveryRoot
        rollbackTaskXml = $RollbackTaskXml
        systemResultPath = $SystemResultPath
        destinationBackupPlanned = $destinationBackupPlanned
        previousBackupPlanned = $previousBackupPlanned
        destinationOwnedInstallPresent = $destinationOwnedInstallPresent
        previousOwnedInstallPresent = $previousOwnedInstallPresent
        existingInstallPresent = $existingInstallPresent
        legacyCleanupAuthorized = $legacyCleanupAuthorized
        migrationApplied = $false
        runtimeConfigurationReady = $false
        dataRootExisted = $dataRootExisted
        settingsWasPresent = $settingsWasPresent
        tokenWasPresent = $tokenWasPresent
        applicationDataSnapshotReady = $false
        applicationDataSnapshots = @()
        externalArtifactSnapshotReady = $false
        externalArtifactSnapshots = @()
        uninstallRegistryWasPresent = $false
        uninstallRegistrySnapshotReady = $false
        uninstallRegistrySnapshotSha256 = ''
        uninstallRegistryMutationMarkerSha256 = ''
        externalCommitPhase = 'None'
        settingsQuarantineFiles = @()
        tokenQuarantineFiles = @()
        appliedSystemConfigurationWasPresent = $appliedSystemConfigurationWasPresent
        systemConfigurationRequiredWasPresent = $systemConfigurationRequiredWasPresent
        diagnosticLoggingWasPresent = $diagnosticLoggingWasPresent
        logsRootWasPresent = $logsRootWasPresent
        transactionsRootWasPresent = $transactionsRootWasPresent
        systemConfigurationWasRequired = $systemConfigurationWasRequired
        legacyCredentialFound = $legacyCredentialFound
        migrateV121SystemState = $migrateV121SystemState
        # This durable intent is written before bootstrap. If bootstrap creates
        # protected state and the process then stops, rollback may invoke only
        # the fixed broker cleanup operation with its separate transaction ID.
        protectedBrokerWasPresentBefore = $protectedBrokerWasPresentBefore
        protectedBrokerCleanupAuthorized = -not $protectedBrokerWasPresentBefore
        protectedBrokerReady = $false
        legacyTokenPath = if ($LegacyTokenPath) { $LegacyTokenPath } else { '' }
        startupWasRegistered = $startupWasRegistered
        existingSupervisorWasRunning = $existingSupervisorWasRunning
        publicPort = $effectivePublicPort
        backendPort = $effectiveBackendPort
        tailscalePath = $effectiveTailscalePath
        targetVersion = $TargetVersion
    }
    Write-InstallTransactionState -State $transactionState
    $preserveRecoveryArtifacts = $true

    # Capture every Inno-managed external surface before bootstrap or program
    # mutation. The ready marker is written only after all byte-for-byte files
    # and the typed HKCU uninstall registration have durable recovery copies.
    $registrySnapshot = New-EverVigilUninstallRegistrySnapshot `
        -RecoveryRoot $TransactionRecoveryRoot `
        -TransactionId $TransactionId
    $registryMutationMarkerSha256 =
        New-EverVigilUninstallRegistryMutationMarker `
            -RecoveryRoot $TransactionRecoveryRoot `
            -TransactionId $TransactionId
    $transactionState.externalArtifactSnapshots = @(
        New-EverVigilExternalArtifactSnapshots `
            -RecoveryRoot $TransactionRecoveryRoot `
            -State $transactionState)
    $transactionState.uninstallRegistryWasPresent =
        [bool]$registrySnapshot.WasPresent
    $transactionState.uninstallRegistrySnapshotSha256 =
        [string]$registrySnapshot.Sha256
    $transactionState.uninstallRegistryMutationMarkerSha256 =
        [string]$registryMutationMarkerSha256
    $transactionState.uninstallRegistrySnapshotReady = $true
    $transactionState.externalArtifactSnapshotReady = $true
    $transactionState.externalCommitPhase = 'SnapshotReady'
    Write-InstallTransactionState -State $transactionState

    # Bootstrap installs only the ACL-protected canonical broker and then runs a
    # canonical Status request. This is unconditional so an installation that
    # remains CONFIGURATION REQUIRED can still perform safe broker-owned cleanup.
    Invoke-SystemBrokerMaintenance -Mode Prepare
    $transactionState.protectedBrokerReady = $true
    Write-InstallTransactionState -State $transactionState

    if (Test-Path -LiteralPath $BundledExecutable -PathType Leaf) {
        New-Item -ItemType Directory -Path $PublishRoot -Force | Out-Null
        Copy-Item -LiteralPath $BundledExecutable -Destination $PublishRoot
    } else {
        if (-not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
            throw "Neither a bundled executable nor the source project was found: $ProjectPath"
        }
        $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
        if (-not $dotnetCommand) {
            throw 'The source installer requires the .NET 8 SDK, but dotnet was not found.'
        }
        $sdkVersions = @(& $dotnetCommand.Source --list-sdks)
        if ($LASTEXITCODE -ne 0 -or -not ($sdkVersions | Where-Object { $_ -match '^8\.' })) {
            throw 'The source installer requires a .NET 8.x SDK.'
        }

        & $dotnetCommand.Source publish `
            $ProjectPath `
            -c Release `
            -r win-x64 `
            --self-contained true `
            -p:PublishSingleFile=true `
            -p:DebugType=None `
            -p:DebugSymbols=false `
            -o $PublishRoot
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet publish failed with exit code $LASTEXITCODE"
        }
    }

    $publishedExecutable = Join-Path $PublishRoot 'EverVigil.exe'
    Assert-TargetExecutableVersion -Path $publishedExecutable

    New-Item -ItemType Directory -Path $InstallParent -Force | Out-Null
    Copy-Item -LiteralPath $PublishRoot -Destination $StagingRoot -Recurse
    New-Item -ItemType Directory -Path (Join-Path $StagingRoot 'scripts') -Force | Out-Null
    foreach ($supportScript in @(
            $SystemScript
            $InstallPathResolver
            $InstallTransactionScript
            $InstallTransactionDataHelper
            $InteractiveTaskHelper
            $LegacyCompatibilityHelper
        )) {
        Copy-Item -LiteralPath $supportScript -Destination (Join-Path $StagingRoot 'scripts')
    }
    foreach ($supportFile in @(
            'Uninstall.ps1'
            'README.md'
            'SECURITY.md'
            'LICENSE'
            'NOTICE.md'
            'THIRD-PARTY-NOTICES.md'
        )) {
        $supportPath = Join-Path $RepositoryRoot $supportFile
        if (Test-Path -LiteralPath $supportPath -PathType Leaf) {
            Copy-Item -LiteralPath $supportPath -Destination $StagingRoot
        }
    }
    $documentationRoot = Join-Path $RepositoryRoot 'docs'
    if (Test-Path -LiteralPath $documentationRoot -PathType Container) {
        Copy-Item -LiteralPath $documentationRoot -Destination $StagingRoot -Recurse
    }
    $licenseRoot = Join-Path $RepositoryRoot 'licenses'
    if (Test-Path -LiteralPath $licenseRoot -PathType Container) {
        Copy-Item -LiteralPath $licenseRoot -Destination $StagingRoot -Recurse
    }
    Write-EverVigilInstallOwnership `
        -Path $StagingRoot `
        -InstallRoot $InstallRoot `
        -AllowCurrentTempTree:$allowInstallRootInCurrentTemp
    $transactionState.status = 'pending'
    Write-InstallTransactionState -State $transactionState

    $shutdownExecutable = if (Test-Path -LiteralPath $PreviousInstalledExecutable -PathType Leaf) {
        $PreviousInstalledExecutable
    } elseif (Test-Path -LiteralPath $InstalledExecutable -PathType Leaf) {
        $InstalledExecutable
    } else {
        $null
    }
    if ($shutdownExecutable) {
        try {
            [void](Invoke-AppCommand `
                    -Arguments @('--shutdown') `
                    -TimeoutSeconds 15 `
                    -ExecutablePath $shutdownExecutable `
                    -WorkingDirectory (Split-Path -Parent $shutdownExecutable))
        } catch {}
        $remaining = @(Get-InstalledSupervisorProcesses)
        if ($remaining.Count -gt 0) {
            $remaining | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue
        }
        $remaining = @(Get-InstalledSupervisorProcesses)
        if ($remaining.Count -gt 0) {
            throw 'The installed supervisor did not exit within 20 seconds.'
        }
    }

    $transactionState.settingsQuarantineFiles = @(
        Get-EverVigilQuarantineFileNames -DataRoot $DataRoot -Kind settings)
    $transactionState.tokenQuarantineFiles = @(
        Get-EverVigilQuarantineFileNames -DataRoot $DataRoot -Kind token)
    $transactionState.applicationDataSnapshots = @(
        New-EverVigilApplicationDataSnapshots `
            -DataRoot $DataRoot `
            -RecoveryRoot $TransactionRecoveryRoot `
            -State $transactionState)
    $transactionState.applicationDataSnapshotReady = $true
    Write-InstallTransactionState -State $transactionState
    $applicationDataRollbackRequired = $true

    if (Test-Path -LiteralPath $InstallRoot) {
        Move-Item -LiteralPath $InstallRoot -Destination $BackupRoot
    }
    if ($installRootChanged -and (Test-Path -LiteralPath $PreviousInstallRoot)) {
        Move-Item -LiteralPath $PreviousInstallRoot -Destination $PreviousBackupRoot
    }
    Move-Item -LiteralPath $StagingRoot -Destination $InstallRoot
    $newInstallActivated = $true
    Assert-OwnedInstallRoot `
        -Path $InstallRoot `
        -AllowCurrentTempTree:$allowInstallRootInCurrentTemp
    Assert-TargetExecutableVersion -Path $InstalledExecutable

    if ($LegacyRoot -and
        $LegacyTokenPath -and
        (Test-Path -LiteralPath $LegacyTokenPath -PathType Leaf) -and
        -not $settingsWasPresent) {
        $legacySettingsArguments = @(
            '--initialize-legacy-settings'
            '--legacy-token-file', $LegacyTokenPath
            '--legacy-root', $LegacyRoot
        )
        if ((Invoke-AppCommand -Arguments $legacySettingsArguments) -ne 0) {
            throw 'Legacy settings initialization failed.'
        }
    }
    if ($LegacyTokenPath -and
        (Test-Path -LiteralPath $LegacyTokenPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $TokenPath -PathType Leaf)) {
        if ((Invoke-AppCommand -Arguments @('--import-token-file', $LegacyTokenPath)) -ne 0) {
            throw 'Legacy token import failed.'
        }
    }
    $runtimeConfigurationReady = (Invoke-EverVigilInteractiveCommand `
            -TransactionId $TransactionId `
            -OwnerSid $ownerSid `
            -ExecutablePath $InstalledExecutable `
            -Arguments @('--validate-settings') `
            -WorkingDirectory $InstallRoot `
            -TimeoutSeconds 60) -eq 0
    $transactionState.runtimeConfigurationReady = $runtimeConfigurationReady
    Write-InstallTransactionState -State $transactionState
    if ($existingSupervisorWasHealthy -and -not $runtimeConfigurationReady) {
        throw 'The replacement supervisor configuration is invalid even though the previous version was healthy.'
    }

    if ($runtimeConfigurationReady) {
        if (-not $systemConfigurationCanBePreserved -or
            $migrateV121SystemState) {
            $previousConfiguration = if ($appliedSystemConfigurationWasPresent) {
                Read-PersistedSystemConfiguration `
                    -Path $AppliedSystemConfigurationPath `
                    -Description 'the last applied system configuration' `
                    -RequireTailscaleExecutable
            } else {
                $null
            }
            $existingTargetMappingOwned = $null -ne $previousConfiguration -and
                $previousConfiguration.PublicPort -eq $effectivePublicPort
            $pendingTarget = [ordered]@{
                publicPort = $effectivePublicPort
                backendPort = $effectiveBackendPort
                tailscalePath = [IO.Path]::GetFullPath($effectiveTailscalePath)
            }
            $pendingPrevious = if ($previousConfiguration) {
                [ordered]@{
                    publicPort = [int]$previousConfiguration.PublicPort
                    backendPort = [int]$previousConfiguration.BackendPort
                    tailscalePath = [IO.Path]::GetFullPath(
                        [string]$previousConfiguration.TailscalePath)
                }
            } elseif ($legacyCredentialFound) {
                [ordered]@{
                    publicPort = 3456
                    backendPort = 3457
                    tailscalePath = [IO.Path]::GetFullPath($effectiveTailscalePath)
                }
            } else {
                $null
            }
            $pendingPreviousOwned = $null -ne $pendingPrevious
            $pendingExistingTargetOwned = $pendingPreviousOwned -and
                $pendingPrevious.publicPort -eq $pendingTarget.publicPort
            New-InstallPendingSystemJournal `
                -Target $pendingTarget `
                -Previous $pendingPrevious `
                -PreviousMappingOwned:$pendingPreviousOwned `
                -ExistingTargetMappingOwned:$pendingExistingTargetOwned
            Invoke-SystemBrokerMaintenance `
                -Mode Install `
                -PublicPort $effectivePublicPort `
                -BackendPort $effectiveBackendPort `
                -MigrateV121SystemState:$migrateV121SystemState
            $pendingSystemState = Read-InstallerPendingSystemJournal
            if (-not $pendingSystemState -or
                [string]$pendingSystemState.phase -cne 'MutationsCompleted') {
                throw 'System maintenance returned without durable completion evidence.'
            }
            $migrationApplied = $true
            $transactionState.migrationApplied = $true
            Write-InstallTransactionState -State $transactionState
            Commit-InstallerSystemConfigurationLocally `
                -State ([pscustomobject]$transactionState) `
                -ExpectedTarget $pendingTarget
        }
    }

    $shouldRegisterStartup = -not $existingInstallPresent -or
        $startupWasRegistered
    if ($shouldRegisterStartup) {
        if ((Invoke-AppCommand -Arguments @('--register-startup')) -ne 0) {
            throw 'Startup registration failed.'
        }
        # The verified legacy startup entry remains intact until the protected
        # system commit is durable. Complete-InstallTransaction retires it as a
        # resumable post-commit cleanup, so every pre-finalization failure can
        # still restore the exact previous environment.
    }
    $launchArguments = @('--background')
    if ($runtimeConfigurationReady -or $existingSupervisorWasRunning) {
        $launchArguments += '--force-start-service'
    }
    Start-EverVigilInteractiveProcess `
        -TransactionId $TransactionId `
        -OwnerSid $ownerSid `
        -ExecutablePath $InstalledExecutable `
        -Arguments $launchArguments `
        -WorkingDirectory $InstallRoot

    if ($runtimeConfigurationReady -and -not (Wait-NewSupervisorHealthy)) {
        throw 'The new tray supervisor did not become healthy within three minutes.'
    }
    if (-not $runtimeConfigurationReady -and -not (Wait-NewSupervisorStarted)) {
        throw 'The new tray supervisor did not remain available for dependency configuration.'
    }

    $transactionState.migrationApplied = $migrationApplied
    $transactionState.runtimeConfigurationReady = $runtimeConfigurationReady
    if ($DeferCommit) {
        Write-InstallTransactionState -State $transactionState
        $preserveRecoveryArtifacts = $true
    } else {
        $transactionState.status = 'committed'
        Write-InstallTransactionState -State $transactionState
        $preserveRecoveryArtifacts = $true
        $migrationCommitted = $true
        if ($migrationApplied -and
            (Test-Path -LiteralPath $PendingSystemJournalPath -PathType Leaf)) {
            Invoke-SystemBrokerMaintenance -Mode Commit
            if (Test-Path -LiteralPath $PendingSystemJournalPath) {
                throw 'The installer-owned pending system journal remained after commit.'
            }
        }
        if ($runtimeConfigurationReady -and
            $legacyCredentialFound -and
            $LegacyTokenPath -and
            (Test-Path -LiteralPath $LegacyTokenPath -PathType Leaf)) {
            Remove-Item -LiteralPath $LegacyTokenPath -Force
        }
        if ($destinationBackupPlanned) {
            $validateDestinationBackup = {
                if ($destinationOwnedInstallPresent) {
                    Assert-OwnedInstallBackup `
                        -Path $BackupRoot `
                        -OriginalInstallRoot $InstallRoot `
                        -AllowCurrentTempTree:$allowInstallRootInCurrentTemp
                } elseif (@(Get-ChildItem -LiteralPath $BackupRoot -Force).Count -gt 0) {
                    throw "The destination backup is not empty: $BackupRoot"
                }
            }
            Remove-InstallTransactionTree `
                -Role backupRoot `
                -Path $BackupRoot `
                -ValidateTree $validateDestinationBackup
        }
        if ($previousBackupPlanned) {
            $validatePreviousBackup = {
                Assert-OwnedInstallBackup `
                    -Path $PreviousBackupRoot `
                    -OriginalInstallRoot $PreviousInstallRoot `
                    -AllowCurrentTempTree:$allowPreviousInstallRootInCurrentTemp
            }
            Remove-InstallTransactionTree `
                -Role previousBackupRoot `
                -Path $PreviousBackupRoot `
                -ValidateTree $validatePreviousBackup
        }
        Remove-TransactionRecoveryArtifacts
        Remove-Item -LiteralPath $TransactionPath -Force
        $preserveRecoveryArtifacts = $false
    }

    "Installed: $InstalledExecutable"
    "Startup: $(if ($shouldRegisterStartup) { 'registered' } else { 'preserved disabled' })"
    $legacyCredentialStatus = if (-not $legacyCredentialFound) {
        'not found'
    } elseif ($runtimeConfigurationReady) {
        'plaintext token retired'
    } else {
        'preserved until system migration completes'
    }
    "Legacy credential: $legacyCredentialStatus"
    "System configuration: $(if ($runtimeConfigurationReady) { 'reconciled by protected broker' } else { 'deferred until configuration completes' })"
    "Health: $(if ($runtimeConfigurationReady) { 'ONLINE' } else { 'CONFIGURATION REQUIRED' })"
    "Transaction: $(if ($DeferCommit) { 'pending setup completion' } else { 'committed' })"
    if (-not $runtimeConfigurationReady) {
        'Open Settings from the tray icon, select and save the missing dependency paths, then rerun this installer.'
    }
} catch {
    $installError = $_.Exception
    if ($migrationCommitted) {
        throw "The new tray supervisor remains active, but legacy cleanup failed: $($installError.Message)"
    }
    if ($null -ne $transactionState -and
        [string]$transactionState.status -ne 'staging') {
        $applicationDataRollbackRequired = [bool]$transactionState.applicationDataSnapshotReady
    }
    if ($null -ne $transactionState -and
        [string]$transactionState.status -ne 'staging' -and
        (Test-Path -LiteralPath $TransactionPath)) {
        try {
            $transactionState.status = 'rollingBack'
            $transactionState.migrationApplied = $migrationApplied
            $transactionState.runtimeConfigurationReady = $runtimeConfigurationReady
            Write-InstallTransactionState -State $transactionState
        } catch {
            $preserveRecoveryArtifacts = $true
        }
    }

    try {
        if ($newInstallActivated -and (Test-Path -LiteralPath $InstalledExecutable)) {
            [void](Invoke-AppCommand -Arguments @('--shutdown') -TimeoutSeconds 15)
            [void](Invoke-AppCommand -Arguments @('--unregister-startup') -TimeoutSeconds 15)
        }
    } catch {}
    if ($newInstallActivated -and -not $startupWasRegistered) {
        [void](Remove-EverVigilOwnedShortcut `
                -Path $startupShortcutPath `
                -ExpectedTargetPath @($InstalledExecutable) `
                -ExpectedArguments '--background')
    }

    $remaining = @(Get-InstalledSupervisorProcesses)
    if ($remaining.Count -gt 0) {
        $remaining | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue
    }
    $remaining = @(Get-InstalledSupervisorProcesses)
    if ($newInstallActivated -and $remaining.Count -gt 0) {
        $preserveRecoveryArtifacts = $migrationApplied -or
            (Test-Path -LiteralPath $PendingSystemJournalPath -PathType Leaf)
        throw "Installation failed: $($installError.Message) The new supervisor is still running, so system rollback was not attempted. PID(s): $($remaining.Id -join ', ')."
    }
    if ($migrationApplied -or
        (Test-Path -LiteralPath $PendingSystemJournalPath -PathType Leaf)) {
        $preserveRecoveryArtifacts = $true
    }
    $startupBlockError = $null
    try {
        Restore-SystemConfigurationRequirement
    } catch {
        $startupBlockError = $_.Exception
    }

    $rollbackError = $null
    $pendingSystemJournalExists = Test-Path `
        -LiteralPath $PendingSystemJournalPath `
        -PathType Leaf
    $systemJournalTemporaries = @()
    try {
        $systemJournalTemporaries = @(
            Get-InstallerSystemJournalTemporariesForTransaction `
                -ExpectedTransactionId $TransactionId)
    } catch {
        $rollbackError = $_.Exception
    }
    if (-not $migrationApplied -and $pendingSystemJournalExists) {
        try {
            [void](Remove-UnmutatedInstallPendingSystemJournal)
            $pendingSystemJournalExists = Test-Path `
                -LiteralPath $PendingSystemJournalPath `
                -PathType Leaf
        } catch {
            $rollbackError = $_.Exception
        }
    }
    if (-not $rollbackError -and
        $migrationApplied -and
        -not $pendingSystemJournalExists -and
        $systemJournalTemporaries.Count -eq 0) {
        $rollbackError = [InvalidOperationException]::new(
            'System rollback requires the durable pending system journal; migrationApplied is not ownership evidence.')
    }
    if (-not $rollbackError -and
        ($pendingSystemJournalExists -or $systemJournalTemporaries.Count -gt 0)) {
        try {
            Invoke-SystemBrokerMaintenance `
                -Mode Rollback `
                -MigrateV121SystemState:$migrateV121SystemState
        } catch {
            $rollbackError = $_.Exception
        }
    }
    if (-not $rollbackError -and $null -ne $transactionState) {
        try {
            Invoke-InitialInstallProtectedBrokerCleanup -State $transactionState
        } catch {
            $rollbackError = $_.Exception
        }
    }
    if (-not $rollbackError) {
        try {
            if ($applicationDataRollbackRequired) {
                Restore-EverVigilApplicationDataSnapshots `
                    -DataRoot $DataRoot `
                    -RecoveryRoot $TransactionRecoveryRoot `
                    -TransactionId $TransactionId `
                    -State $transactionState
                Remove-EverVigilNewQuarantineFiles `
                    -DataRoot $DataRoot `
                    -State $transactionState
            }
            if ($null -ne $transactionState -and
                [bool]$transactionState.externalArtifactSnapshotReady -and
                [bool]$transactionState.uninstallRegistrySnapshotReady) {
                Restore-EverVigilExternalArtifactSnapshots `
                    -State $transactionState `
                    -RecoveryRoot $TransactionRecoveryRoot `
                    -TransactionId $TransactionId
            }
            Remove-InstallTransactionTree `
                -Role publishRoot `
                -Path $PublishRoot
            Remove-NewApplicationData
        } catch {
            $rollbackError = $_.Exception
        }
    }
    if ($rollbackError) {
        try {
            Set-SystemConfigurationRequirement -Reason 'System rollback failed; backend must remain stopped'
            $startupBlockError = $null
        } catch {
            $startupBlockError = $_.Exception
        }
    } elseif ($startupBlockError) {
        try {
            Restore-SystemConfigurationRequirement
            $startupBlockError = $null
        } catch {
            $startupBlockError = $_.Exception
        }
    }
    if ($startupBlockError) {
        $rollbackError = if ($rollbackError) {
            [InvalidOperationException]::new(
                "System rollback failed: $($rollbackError.Message) Startup blocking also failed: $($startupBlockError.Message)")
        } else {
            $startupBlockError
        }
    }
    if ($rollbackError) {
        $preserveRecoveryArtifacts = $true
        [void](Remove-EverVigilOwnedShortcut `
                -Path $startupShortcutPath `
                -ExpectedTargetPath @($InstalledExecutable) `
                -ExpectedArguments '--background')
        if (Test-Path -LiteralPath $startupShortcutPath) {
            $rollbackError = [InvalidOperationException]::new(
                "$($rollbackError.Message) The startup shortcut could not be removed: $startupShortcutPath")
        }
    }

    if ($destinationBackupPlanned -and (Test-Path -LiteralPath $BackupRoot)) {
        if ($destinationOwnedInstallPresent) {
            Assert-OwnedInstallBackup `
                -Path $BackupRoot `
                -OriginalInstallRoot $InstallRoot `
                -AllowCurrentTempTree:$allowInstallRootInCurrentTemp
        } elseif (@(Get-ChildItem -LiteralPath $BackupRoot -Force).Count -gt 0) {
            throw "The destination backup is not empty: $BackupRoot"
        }
        if (Test-Path -LiteralPath $InstallRoot) {
            $validateInstallRoot = {
                Assert-OwnedInstallRoot `
                    -Path $InstallRoot `
                    -AllowCurrentTempTree:$allowInstallRootInCurrentTemp
            }
            Remove-InstallTransactionTree `
                -Role installRoot `
                -Path $InstallRoot `
                -ValidateTree $validateInstallRoot
        }
        Move-Item -LiteralPath $BackupRoot -Destination $InstallRoot
        if (-not $installRootChanged -and $existingInstallPresent -and
            $startupWasRegistered -and -not $rollbackError) {
            [void](Invoke-AppCommand -Arguments @('--register-startup') -TimeoutSeconds 15)
        }
        if (-not $installRootChanged -and $existingSupervisorWasRunning -and -not $rollbackError) {
            Start-EverVigilRestoredSupervisor `
                -TransactionId $TransactionId `
                -OwnerSid $ownerSid `
                -ExecutablePath $InstalledExecutable `
                -WorkingDirectory $InstallRoot
        }
    } elseif ($newInstallActivated -and (Test-Path -LiteralPath $InstallRoot)) {
        $validateActivatedInstallRoot = {
            Assert-OwnedInstallRoot `
                -Path $InstallRoot `
                -AllowCurrentTempTree:$allowInstallRootInCurrentTemp
        }
        Remove-InstallTransactionTree `
            -Role installRoot `
            -Path $InstallRoot `
            -ValidateTree $validateActivatedInstallRoot
    } elseif (-not $installRootChanged -and $existingSupervisorWasRunning -and -not $rollbackError -and
        (Test-Path -LiteralPath $InstalledExecutable)) {
        Start-EverVigilRestoredSupervisor `
            -TransactionId $TransactionId `
            -OwnerSid $ownerSid `
            -ExecutablePath $InstalledExecutable `
            -WorkingDirectory $InstallRoot
    }
    if ($previousBackupPlanned -and (Test-Path -LiteralPath $PreviousBackupRoot)) {
        Assert-OwnedInstallBackup `
            -Path $PreviousBackupRoot `
            -OriginalInstallRoot $PreviousInstallRoot `
            -AllowCurrentTempTree:$allowPreviousInstallRootInCurrentTemp
        if (Test-Path -LiteralPath $PreviousInstallRoot) {
            $validatePreviousInstallRoot = {
                Assert-OwnedInstallRoot `
                    -Path $PreviousInstallRoot `
                    -AllowCurrentTempTree:$allowPreviousInstallRootInCurrentTemp
            }
            Remove-InstallTransactionTree `
                -Role previousInstallRoot `
                -Path $PreviousInstallRoot `
                -ValidateTree $validatePreviousInstallRoot
        }
        Move-Item -LiteralPath $PreviousBackupRoot -Destination $PreviousInstallRoot
        if ($startupWasRegistered -and -not $rollbackError) {
            [void](Invoke-AppCommand `
                    -Arguments @('--register-startup') `
                    -TimeoutSeconds 15 `
                    -ExecutablePath $PreviousInstalledExecutable `
                    -WorkingDirectory $PreviousInstallRoot)
        }
        if ($existingSupervisorWasRunning -and -not $rollbackError) {
            Start-EverVigilRestoredSupervisor `
                -TransactionId $TransactionId `
                -OwnerSid $ownerSid `
                -ExecutablePath $PreviousInstalledExecutable `
                -WorkingDirectory $PreviousInstallRoot
        }
    } elseif ($installRootChanged -and $existingInstallPresent -and
        $existingSupervisorWasRunning -and -not $rollbackError -and
        (Test-Path -LiteralPath $PreviousInstalledExecutable -PathType Leaf)) {
        if ($startupWasRegistered) {
            [void](Invoke-AppCommand `
                    -Arguments @('--register-startup') `
                    -TimeoutSeconds 15 `
                    -ExecutablePath $PreviousInstalledExecutable `
                    -WorkingDirectory $PreviousInstallRoot)
        }
        Start-EverVigilRestoredSupervisor `
            -TransactionId $TransactionId `
            -OwnerSid $ownerSid `
            -ExecutablePath $PreviousInstalledExecutable `
            -WorkingDirectory $PreviousInstallRoot
    }
    if (-not $rollbackError) {
        try {
            if ($null -ne $transactionState -and
                (Test-Path -LiteralPath $TransactionPath -PathType Leaf)) {
                $transactionState.status = 'rolledBack'
                Write-InstallTransactionState -State $transactionState
            }
            Remove-TransactionRecoveryArtifacts
            if (Test-Path -LiteralPath $TransactionPath -PathType Leaf) {
                Remove-Item -LiteralPath $TransactionPath -Force -ErrorAction Stop
            }
            $preserveRecoveryArtifacts = $false
        } catch {
            $rollbackError = $_.Exception
            $preserveRecoveryArtifacts = $true
        }
    }
    if ($rollbackError) {
        throw "Installation failed: $($installError.Message) Rollback also failed: $($rollbackError.Message) Recovery files were retained at '$RollbackTaskXml' and '$SystemResultPath'."
    }
    throw $installError
} finally {
    Remove-InstallTransactionTree `
        -Role publishRoot `
        -Path $PublishRoot
    Remove-InstallTransactionTree `
        -Role stagingRoot `
        -Path $StagingRoot
    if (-not $preserveRecoveryArtifacts) {
        Remove-Item -LiteralPath $RollbackTaskXml, $SystemResultPath -Force -ErrorAction SilentlyContinue
        Remove-TransactionRecoveryArtifacts
    }
    if ($transactionLockTaken) {
        $transactionMutex.ReleaseMutex()
    }
    $transactionMutex.Dispose()
}
