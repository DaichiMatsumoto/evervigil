[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$transactionScript = Join-Path $repositoryRoot 'scripts\Complete-InstallTransaction.ps1'
$transactionDataScript = Join-Path $repositoryRoot 'scripts\InstallTransactionData.ps1'
$resolverScript = Join-Path $repositoryRoot 'scripts\Resolve-SafeInstallRoot.ps1'
$uninstallScript = Join-Path $repositoryRoot 'Uninstall.ps1'
$uninstallResidueTest = Join-Path $PSScriptRoot 'Test-UninstallTransactionResidue.ps1'
$externalTransactionTest = Join-Path `
    $PSScriptRoot `
    'Test-ExternalInstallTransaction.ps1'
$builtExecutable = Join-Path `
    $repositoryRoot `
    'src\EverVigil\bin\Release\net8.0-windows\EverVigil.exe'
if (-not (Test-Path -LiteralPath $builtExecutable -PathType Leaf)) {
    throw "Build the Release configuration before this test: $builtExecutable"
}
& $uninstallResidueTest
& $externalTransactionTest

$testRoot = Join-Path $repositoryRoot 'artifacts\install-transaction-test'
$originalLocalAppData = $env:LOCALAPPDATA
$originalTemp = $env:TEMP
$testLocalAppData = Join-Path $testRoot 'LocalAppData'
$transactionId = '0123456789abcdef0123456789abcdef'
$cleanupTransactionId = 'fedcba9876543210fedcba9876543210'
$startupFolder = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::Startup)
if ([string]::IsNullOrWhiteSpace($startupFolder)) {
    # Service-hosted CI runners may not expose the interactive Startup folder.
    # Keep the restore check hermetic instead of passing an empty path to Join-Path.
    $startupFolder = Join-Path $testRoot 'startup-fixture'
}
$startupShortcutPath = Join-Path $startupFolder 'EverVigil.lnk'
$startupWasPresentBeforeTest = Test-Path -LiteralPath $startupShortcutPath -PathType Leaf
$startupDigestBeforeTest = if ($startupWasPresentBeforeTest) {
    (Get-FileHash -LiteralPath $startupShortcutPath -Algorithm SHA256).Hash
} else {
    $null
}
$startupBackupPath = Join-Path $testRoot 'pre-test-startup.lnk'

function New-KnownInstallLayout {
    param([Parameter(Mandatory)][string]$Root)

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Copy-Item -LiteralPath $builtExecutable -Destination (Join-Path $Root 'EverVigil.exe')
    foreach ($relativePath in @(Get-EverVigilRequiredCurrentPaths)) {
        if ($relativePath -eq 'EverVigil.exe') {
            continue
        }
        $source = Join-Path $repositoryRoot $relativePath
        $destination = Join-Path $Root $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }
}

function New-TransactionState {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$PreviousInstallRoot,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$PreviousBackupRoot,
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [bool]$DestinationBackupPlanned,
        [bool]$PreviousBackupPlanned,
        [bool]$DestinationOwnedInstallPresent,
        [bool]$InstallRootChanged,
        [bool]$ExistingInstallPresent = $false,
        [bool]$StartupWasRegistered = $false,
        [bool]$DataRootExisted = $true,
        [bool]$SettingsWasPresent = $false,
        [bool]$TokenWasPresent = $false,
        [bool]$ApplicationDataSnapshotReady = $true,
        [bool]$AppliedSystemConfigurationWasPresent = $false,
        [bool]$SystemConfigurationRequiredWasPresent = $false,
        [bool]$DiagnosticLoggingWasPresent = $false,
        [bool]$LogsRootWasPresent = $false,
        [bool]$TransactionsRootWasPresent = $false,
        [ValidateSet('staging', 'pending', 'readyToCommit', 'committed', 'rollingBack', 'rolledBack')]
        [string]$Status = 'pending',
        [switch]$CurrentTransaction
    )

    $state = [ordered]@{
        schemaVersion = 3
        appId = 'D1ACB787-2308-4AC4-91BD-A6A3856E7AF0'
        ownerSid = Get-EverVigilOwnerSid
        status = $Status
        deletionIntent = 'none'
        transactionId = $transactionId
        installRoot = $InstallRoot
        previousInstallRoot = $PreviousInstallRoot
        installRootChanged = $InstallRootChanged
        publishRoot = Join-Path `
            (Join-Path $env:LOCALAPPDATA 'EverVigil') `
            "install-publish-$transactionId"
        stagingRoot = "$InstallRoot.staging-$transactionId"
        backupRoot = $BackupRoot
        previousBackupRoot = $PreviousBackupRoot
        recoveryRoot = $RecoveryRoot
        rollbackTaskXml = Join-Path $RecoveryRoot 'legacy-task.xml'
        systemResultPath = Join-Path $RecoveryRoot 'system.log'
        destinationBackupPlanned = $DestinationBackupPlanned
        previousBackupPlanned = $PreviousBackupPlanned
        destinationOwnedInstallPresent = $DestinationOwnedInstallPresent
        previousOwnedInstallPresent = $PreviousBackupPlanned
        existingInstallPresent = $ExistingInstallPresent
        migrationApplied = $false
        runtimeConfigurationReady = $false
        dataRootExisted = $DataRootExisted
        settingsWasPresent = $SettingsWasPresent
        tokenWasPresent = $TokenWasPresent
        applicationDataSnapshotReady = $ApplicationDataSnapshotReady
        applicationDataSnapshots = @()
        settingsQuarantineFiles = @()
        tokenQuarantineFiles = @()
        appliedSystemConfigurationWasPresent = $AppliedSystemConfigurationWasPresent
        systemConfigurationRequiredWasPresent = $SystemConfigurationRequiredWasPresent
        diagnosticLoggingWasPresent = $DiagnosticLoggingWasPresent
        logsRootWasPresent = $LogsRootWasPresent
        transactionsRootWasPresent = $TransactionsRootWasPresent
        systemConfigurationWasRequired = $false
        legacyCredentialFound = $false
        legacyTokenPath = ''
        startupWasRegistered = $StartupWasRegistered
        existingSupervisorWasRunning = $false
        protectedBrokerWasPresentBefore = $false
        protectedBrokerCleanupAuthorized = $false
        protectedBrokerReady = $false
        publicPort = 3456
        backendPort = 3457
        tailscalePath = 'C:\Program Files\Tailscale\tailscale.exe'
    }
    if ($CurrentTransaction) {
        $state.cleanupTransactionId = $cleanupTransactionId
        $state.externalArtifactSnapshotReady = $false
        $state.externalArtifactSnapshots = @()
        $state.uninstallRegistryWasPresent = $false
        $state.uninstallRegistrySnapshotReady = $false
        $state.uninstallRegistrySnapshotSha256 = ''
        $state.uninstallRegistryMutationMarkerSha256 = ''
        $state.externalCommitPhase = 'None'
        $state.targetVersion = '2.0.0'
    }
    return $state
}

try {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $expectedParent = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'artifacts'))
        if (-not $resolvedTestRoot.StartsWith("$expectedParent\", [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected test root: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $testLocalAppData -Force | Out-Null
    if ($startupWasPresentBeforeTest) {
        Copy-Item -LiteralPath $startupShortcutPath -Destination $startupBackupPath
    }
    $env:LOCALAPPDATA = $testLocalAppData
    . $resolverScript
    . $transactionDataScript

    $knownInstallPaths = @(Get-EverVigilKnownRelativePaths)
    $unknownDocumentationPaths = @(Get-ChildItem `
            -LiteralPath (Join-Path $repositoryRoot 'docs') `
            -File `
            -Recurse `
            -Force |
        ForEach-Object {
            [IO.Path]::GetRelativePath($repositoryRoot, $_.FullName)
        } |
        Where-Object { $_ -notin $knownInstallPaths })
    if ($unknownDocumentationPaths.Count -ne 0) {
        throw "Packaged documentation is outside the owned install layout: $($unknownDocumentationPaths -join ', ')"
    }

    $freshDataRoot = Join-Path $testLocalAppData 'fresh-install-data-root'
    $freshInstallTemporaries = @(
        Get-EverVigilInstallTransactionTemporaryFiles -DataRoot $freshDataRoot)
    if ($freshInstallTemporaries.Count -ne 0 -or
        (Test-Path -LiteralPath $freshDataRoot)) {
        throw 'A clean install treated its not-yet-created data root as an error or created it during read-only preflight.'
    }
    New-Item -ItemType Directory -Path $freshDataRoot | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $freshDataRoot 'unrelated.txt'),
        'unrelated',
        [Text.UTF8Encoding]::new($false))
    $recognizedInstallTemporary = Join-Path `
        $freshDataRoot `
        'install-transaction.json.new-0123456789abcdef0123456789abcdef'
    [IO.File]::WriteAllText(
        $recognizedInstallTemporary,
        '{}',
        [Text.UTF8Encoding]::new($false))
    $freshInstallTemporaries = @(
        Get-EverVigilInstallTransactionTemporaryFiles -DataRoot $freshDataRoot)
    if ($freshInstallTemporaries.Count -ne 1 -or
        -not [string]::Equals(
            $freshInstallTemporaries[0].FullName,
            $recognizedInstallTemporary,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Install transaction preflight did not distinguish its atomic temporary from unrelated data.'
    }

    $immediateRollbackDataRoot = Join-Path `
        $testLocalAppData `
        'immediate-clean-rollback-data-root'
    $immediateRollbackTransactionsRoot = Join-Path `
        $immediateRollbackDataRoot `
        $script:LegacyCompatibilityDataTransactionRecoveryDirectoryName
    New-Item `
        -ItemType Directory `
        -Path $immediateRollbackTransactionsRoot `
        -Force | Out-Null
    $immediateRollbackJournal = Join-Path `
        $immediateRollbackDataRoot `
        $script:LegacyCompatibilityDataTransactionJournalFileName
    [IO.File]::WriteAllText(
        $immediateRollbackJournal,
        '{}',
        [Text.UTF8Encoding]::new($false))
    Remove-EverVigilEmptyApplicationDataContainers `
        -DataRoot $immediateRollbackDataRoot `
        -DataRootExisted $false `
        -TransactionsRootWasPresent $false
    if ((Test-Path -LiteralPath $immediateRollbackTransactionsRoot) -or
        -not (Test-Path -LiteralPath $immediateRollbackDataRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $immediateRollbackJournal -PathType Leaf)) {
        throw 'Immediate rollback removed its data root before retiring the transaction journal.'
    }
    Remove-Item `
        -LiteralPath $immediateRollbackJournal `
        -Force `
        -ErrorAction Stop
    Remove-EverVigilEmptyApplicationDataContainers `
        -DataRoot $immediateRollbackDataRoot `
        -DataRootExisted $false `
        -TransactionsRootWasPresent $false
    if (Test-Path -LiteralPath $immediateRollbackDataRoot) {
        throw 'Immediate rollback left an empty clean-install data root after retiring its journal.'
    }
    $preexistingRollbackDataRoot = Join-Path `
        $testLocalAppData `
        'preexisting-immediate-rollback-data-root'
    New-Item -ItemType Directory -Path $preexistingRollbackDataRoot | Out-Null
    Remove-EverVigilEmptyApplicationDataContainers `
        -DataRoot $preexistingRollbackDataRoot `
        -DataRootExisted $true `
        -TransactionsRootWasPresent $false
    if (-not (Test-Path -LiteralPath $preexistingRollbackDataRoot -PathType Container)) {
        throw 'Immediate rollback removed a data root that existed before installation.'
    }
    $unrelatedRollbackDataPath = Join-Path `
        $preexistingRollbackDataRoot `
        'unrelated.txt'
    [IO.File]::WriteAllText(
        $unrelatedRollbackDataPath,
        'preserve',
        [Text.UTF8Encoding]::new($false))
    Remove-EverVigilEmptyApplicationDataContainers `
        -DataRoot $preexistingRollbackDataRoot `
        -DataRootExisted $false `
        -TransactionsRootWasPresent $false
    if (-not (Test-Path -LiteralPath $unrelatedRollbackDataPath -PathType Leaf)) {
        throw 'Immediate rollback removed unrelated application data from a newly created root.'
    }
    Remove-Item `
        -LiteralPath $preexistingRollbackDataRoot `
        -Recurse `
        -Force `
        -ErrorAction Stop

    $transactionPath = Join-Path $testLocalAppData 'EverVigil\install-transaction.json'
    $phaseDispatchTransactionPath = [IO.Path]::GetFullPath($transactionPath)
    $typeGuardRoot = Join-Path $testRoot 'legacy-cleanup-type-guard'
    $typeGuardState = New-TransactionState `
        -InstallRoot $typeGuardRoot `
        -PreviousInstallRoot $typeGuardRoot `
        -BackupRoot "$typeGuardRoot.backup-$transactionId" `
        -PreviousBackupRoot "$typeGuardRoot.relocated-$transactionId" `
        -RecoveryRoot (Join-Path `
            $testLocalAppData `
            "EverVigil\install-transactions\$transactionId") `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false `
        -CurrentTransaction
    $typeGuardState.legacyCleanupAuthorized = 'false'
    New-Item -ItemType Directory -Path (Split-Path -Parent $transactionPath) -Force | Out-Null
    [IO.File]::WriteAllText(
        $transactionPath,
        (($typeGuardState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    $stringBooleanRejected = $false
    try {
        & $transactionScript `
            -Action Seal `
            -TransactionPath $transactionPath
    } catch {
        $stringBooleanRejected = $_.Exception.Message -match
            'legacy cleanup authorization must be a JSON boolean'
    }
    if (-not $stringBooleanRejected) {
        throw 'A string-valued legacyCleanupAuthorized property was not rejected fail-closed.'
    }
    Remove-Item -LiteralPath $transactionPath -Force
    foreach ($invalidCleanupIdentity in @($null, $transactionId)) {
        $cleanupIdentityGuardState = [ordered]@{}
        foreach ($entry in $typeGuardState.GetEnumerator()) {
            $cleanupIdentityGuardState[$entry.Key] = $entry.Value
        }
        $cleanupIdentityGuardState.legacyCleanupAuthorized = $false
        $cleanupIdentityGuardState.protectedBrokerCleanupAuthorized = $true
        $cleanupIdentityGuardState.protectedBrokerReady = $false
        if ($null -eq $invalidCleanupIdentity) {
            $cleanupIdentityGuardState.Remove('cleanupTransactionId')
        } else {
            $cleanupIdentityGuardState.cleanupTransactionId =
                $invalidCleanupIdentity
        }
        [IO.File]::WriteAllText(
            $transactionPath,
            (($cleanupIdentityGuardState | ConvertTo-Json -Depth 6) + "`n"),
            [Text.UTF8Encoding]::new($false))
        $cleanupIdentityRejected = $false
        try {
            & $transactionScript `
                -Action Seal `
                -TransactionPath $transactionPath
        } catch {
            $cleanupIdentityRejected = $_.Exception.Message -match
                'cleanup transaction identifier|separate cleanup transaction identifier'
        }
        if (-not $cleanupIdentityRejected) {
            throw "Install transaction validation accepted unsafe cleanup identity '$invalidCleanupIdentity'."
        }
        Remove-Item -LiteralPath $transactionPath -Force
    }
    $legacyCleanupSentinel = Join-Path `
        (Join-Path `
            $testLocalAppData `
            $script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData) `
        'must-remain-without-legacy-cleanup-authorization.txt'
    New-Item `
        -ItemType Directory `
        -Path (Split-Path -Parent $legacyCleanupSentinel) `
        -Force | Out-Null
    [IO.File]::WriteAllText(
        $legacyCleanupSentinel,
        'schema-3 fixture without the optional authorization property',
        [Text.UTF8Encoding]::new($false))

    $commitInstallRoot = Join-Path $testRoot 'commit-install'
    $commitBackupRoot = "$commitInstallRoot.backup-$transactionId"
    $commitPreviousBackupRoot = "$commitInstallRoot.relocated-$transactionId"
    $commitRecoveryRoot = Join-Path `
        $testLocalAppData `
        "EverVigil\install-transactions\$transactionId"
    New-KnownInstallLayout -Root $commitInstallRoot
    Write-EverVigilInstallOwnership -Path $commitInstallRoot
    New-Item -ItemType Directory -Path $commitBackupRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $commitRecoveryRoot -Force | Out-Null
    $commitState = New-TransactionState `
        -InstallRoot $commitInstallRoot `
        -PreviousInstallRoot $commitInstallRoot `
        -BackupRoot $commitBackupRoot `
        -PreviousBackupRoot $commitPreviousBackupRoot `
        -RecoveryRoot $commitRecoveryRoot `
        -DestinationBackupPlanned $true `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false
    New-Item -ItemType Directory -Path (Split-Path -Parent $transactionPath) -Force | Out-Null
    [IO.File]::WriteAllText(
        $transactionPath,
        (($commitState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    & $transactionScript `
        -Action Seal `
        -TransactionPath $transactionPath
    $sealedState = Get-Content -LiteralPath $transactionPath -Raw | ConvertFrom-Json
    if ([string]$sealedState.status -ne 'readyToCommit') {
        throw 'Seal did not persist the ready-to-commit state.'
    }
    try {
        $env:TEMP = $testRoot
        $newDestinationPolicyRejectedExistingRoot = $false
        try {
            [void](Resolve-SafeInstallRoot -Path $commitInstallRoot)
        } catch {
            $newDestinationPolicyRejectedExistingRoot = $true
        }
        $maintenanceRoot = Resolve-EverVigilMaintenanceInstallRoot `
            -Path $commitInstallRoot `
            -AllowLegacyKnownLayout
        if (-not $newDestinationPolicyRejectedExistingRoot -or
            -not [bool]$maintenanceRoot.Owned -or
            -not [bool]$maintenanceRoot.AllowCurrentTempTree -or
            -not [string]::Equals(
                [string]$maintenanceRoot.Path,
                $commitInstallRoot,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A current TEMP ancestor was not limited to the verified maintenance path.'
        }
        & $transactionScript `
            -Action Recover `
            -TransactionPath $transactionPath
    } finally {
        $env:TEMP = $originalTemp
    }
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath $commitBackupRoot) -or
        -not (Test-Path -LiteralPath $commitInstallRoot -PathType Container)) {
        throw 'Commit did not retain the new installation and retire its transaction artifacts.'
    }
    if (-not (Test-Path -LiteralPath $legacyCleanupSentinel -PathType Leaf)) {
        throw 'A schema-3 transaction without legacyCleanupAuthorized retired legacy artifacts.'
    }

    Remove-Item -LiteralPath $commitInstallRoot -Recurse -Force

    $interruptedCommitRoot = Join-Path $testRoot 'interrupted-commit-install'
    $interruptedCommitBackupRoot = "$interruptedCommitRoot.backup-$transactionId"
    $interruptedCommitPreviousBackupRoot = "$interruptedCommitRoot.relocated-$transactionId"
    $interruptedCommitRecoveryRoot = Join-Path `
        $testLocalAppData `
        "EverVigil\install-transactions\$transactionId"
    New-KnownInstallLayout -Root $interruptedCommitRoot
    Write-EverVigilInstallOwnership -Path $interruptedCommitRoot
    New-Item -ItemType Directory -Path $interruptedCommitBackupRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $interruptedCommitBackupRoot 'remaining-after-interruption.bin'),
        'partial backup tree',
        [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path $interruptedCommitRecoveryRoot -Force | Out-Null
    $interruptedCommitState = New-TransactionState `
        -InstallRoot $interruptedCommitRoot `
        -PreviousInstallRoot $interruptedCommitRoot `
        -BackupRoot $interruptedCommitBackupRoot `
        -PreviousBackupRoot $interruptedCommitPreviousBackupRoot `
        -RecoveryRoot $interruptedCommitRecoveryRoot `
        -DestinationBackupPlanned $true `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $true `
        -InstallRootChanged $false `
        -ExistingInstallPresent $true `
        -Status committed
    $interruptedCommitState.deletionIntent = 'backupRoot'
    [IO.File]::WriteAllText(
        $transactionPath,
        (($interruptedCommitState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath $interruptedCommitBackupRoot) -or
        -not (Test-Path -LiteralPath $interruptedCommitRoot -PathType Container)) {
        throw 'Commit recovery could not resume a previously authorized partial backup deletion.'
    }
    Remove-Item -LiteralPath $interruptedCommitRoot -Recurse -Force

    $interruptedRollbackRoot = Join-Path $testRoot 'interrupted-rollback-install'
    $interruptedRollbackBackupRoot = "$interruptedRollbackRoot.backup-$transactionId"
    $interruptedRollbackPreviousBackupRoot = "$interruptedRollbackRoot.relocated-$transactionId"
    $interruptedRollbackRecoveryRoot = Join-Path `
        $testLocalAppData `
        "EverVigil\install-transactions\$transactionId"
    New-KnownInstallLayout -Root $interruptedRollbackRoot
    Write-EverVigilInstallOwnership -Path $interruptedRollbackRoot
    Move-Item -LiteralPath $interruptedRollbackRoot -Destination $interruptedRollbackBackupRoot
    New-Item -ItemType Directory -Path $interruptedRollbackRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $interruptedRollbackRoot 'remaining-after-interruption.bin'),
        'partial activated tree',
        [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path $interruptedRollbackRecoveryRoot -Force | Out-Null
    $interruptedRollbackState = New-TransactionState `
        -InstallRoot $interruptedRollbackRoot `
        -PreviousInstallRoot $interruptedRollbackRoot `
        -BackupRoot $interruptedRollbackBackupRoot `
        -PreviousBackupRoot $interruptedRollbackPreviousBackupRoot `
        -RecoveryRoot $interruptedRollbackRecoveryRoot `
        -DestinationBackupPlanned $true `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $true `
        -InstallRootChanged $false `
        -ExistingInstallPresent $true `
        -Status rollingBack
    $interruptedRollbackState.deletionIntent = 'installRoot'
    New-Item `
        -ItemType Directory `
        -Path ([string]$interruptedRollbackState.publishRoot) `
        -Force |
        Out-Null
    $mismatchedDeletionRejected = $false
    try {
        Invoke-EverVigilTransactionTreeRemoval `
            -State $interruptedRollbackState `
            -Role publishRoot `
            -PersistState { param($CurrentState) }
    } catch {
        $mismatchedDeletionRejected = $_.Exception.Message -match 'must be resumed'
    }
    if (-not $mismatchedDeletionRejected -or
        -not (Test-Path -LiteralPath $interruptedRollbackRoot -PathType Container) -or
        -not (Test-Path `
            -LiteralPath ([string]$interruptedRollbackState.publishRoot) `
            -PathType Container)) {
        throw 'A different deletion role bypassed the pending durable deletion intent.'
    }
    [IO.File]::WriteAllText(
        $transactionPath,
        (($interruptedRollbackState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath $interruptedRollbackBackupRoot) -or
        -not (Test-Path -LiteralPath $interruptedRollbackRoot -PathType Container)) {
        throw 'Rollback recovery could not resume a previously authorized partial install deletion.'
    }
    Assert-OwnedInstallRoot -Path $interruptedRollbackRoot
    Remove-Item -LiteralPath $interruptedRollbackRoot -Recurse -Force

    $rollbackInstallRoot = Join-Path $testRoot 'rollback-new-install'
    $rollbackPreviousRoot = Join-Path $testRoot 'rollback-previous-install'
    $rollbackBackupRoot = "$rollbackInstallRoot.backup-$transactionId"
    $rollbackPreviousBackupRoot = "$rollbackPreviousRoot.relocated-$transactionId"
    $rollbackRecoveryRoot = Join-Path `
        $testLocalAppData `
        "EverVigil\install-transactions\$transactionId"
    New-KnownInstallLayout -Root $rollbackPreviousRoot
    Write-EverVigilInstallOwnership -Path $rollbackPreviousRoot
    Move-Item -LiteralPath $rollbackPreviousRoot -Destination $rollbackPreviousBackupRoot
    New-Item -ItemType Directory -Path $rollbackRecoveryRoot -Force | Out-Null
    $rollbackState = New-TransactionState `
        -InstallRoot $rollbackInstallRoot `
        -PreviousInstallRoot $rollbackPreviousRoot `
        -BackupRoot $rollbackBackupRoot `
        -PreviousBackupRoot $rollbackPreviousBackupRoot `
        -RecoveryRoot $rollbackRecoveryRoot `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $true `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $true
    [IO.File]::WriteAllText(
        $transactionPath,
        (($rollbackState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath $rollbackPreviousBackupRoot) -or
        -not (Test-Path -LiteralPath $rollbackPreviousRoot -PathType Container)) {
        throw 'Rollback did not restore the previous installation and retire its transaction artifacts.'
    }
    Assert-OwnedInstallRoot -Path $rollbackPreviousRoot

    Remove-Item -LiteralPath $rollbackPreviousRoot -Recurse -Force
    $writeAheadRoot = Join-Path $testRoot 'write-ahead-install'
    $writeAheadBackupRoot = "$writeAheadRoot.backup-$transactionId"
    $writeAheadPreviousBackupRoot = "$writeAheadRoot.relocated-$transactionId"
    $writeAheadRecoveryRoot = Join-Path `
        $testLocalAppData `
        "EverVigil\install-transactions\$transactionId"
    New-KnownInstallLayout -Root $writeAheadRoot
    Write-EverVigilInstallOwnership -Path $writeAheadRoot
    $writeAheadState = New-TransactionState `
        -InstallRoot $writeAheadRoot `
        -PreviousInstallRoot $writeAheadRoot `
        -BackupRoot $writeAheadBackupRoot `
        -PreviousBackupRoot $writeAheadPreviousBackupRoot `
        -RecoveryRoot $writeAheadRecoveryRoot `
        -DestinationBackupPlanned $true `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $true `
        -InstallRootChanged $false `
        -ExistingInstallPresent $true `
        -SettingsWasPresent $true `
        -TokenWasPresent $true `
        -ApplicationDataSnapshotReady $false
    New-KnownInstallLayout -Root ([string]$writeAheadState.stagingRoot)
    New-Item -ItemType Directory -Path $writeAheadRecoveryRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $writeAheadRecoveryRoot 'settings.json.rollback'),
        'partial snapshot',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $transactionPath,
        (($writeAheadState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    $incompleteSealRejected = $false
    try {
        & $transactionScript `
            -Action Seal `
            -TransactionPath $transactionPath
    } catch {
        $incompleteSealRejected = $true
    }
    if (-not $incompleteSealRejected) {
        throw 'Seal accepted a transaction whose application-data snapshot was incomplete.'
    }
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath ([string]$writeAheadState.stagingRoot)) -or
        (Test-Path -LiteralPath $writeAheadRecoveryRoot) -or
        -not (Test-Path -LiteralPath $writeAheadRoot -PathType Container)) {
        throw 'Write-ahead recovery did not preserve the untouched installation and remove staging.'
    }
    Assert-OwnedInstallRoot -Path $writeAheadRoot
    Remove-Item -LiteralPath $writeAheadRoot -Recurse -Force

    $stagingRecoveryRoot = Join-Path $testRoot 'staging-recovery-install'
    $stagingRecoveryBackupRoot = "$stagingRecoveryRoot.backup-$transactionId"
    $stagingRecoveryPreviousBackupRoot = "$stagingRecoveryRoot.relocated-$transactionId"
    $stagingRecoveryEvidenceRoot = Join-Path `
        $testLocalAppData `
        "EverVigil\install-transactions\$transactionId"
    $stagingRecoveryState = New-TransactionState `
        -InstallRoot $stagingRecoveryRoot `
        -PreviousInstallRoot $stagingRecoveryRoot `
        -BackupRoot $stagingRecoveryBackupRoot `
        -PreviousBackupRoot $stagingRecoveryPreviousBackupRoot `
        -RecoveryRoot $stagingRecoveryEvidenceRoot `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false `
        -ApplicationDataSnapshotReady $false `
        -Status staging
    New-Item -ItemType Directory -Path ([string]$stagingRecoveryState.publishRoot) -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path ([string]$stagingRecoveryState.publishRoot) 'partial.dll'),
        'partial publish',
        [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path ([string]$stagingRecoveryState.stagingRoot) -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path ([string]$stagingRecoveryState.stagingRoot) 'partial.exe'),
        'partial staging',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $transactionPath,
        (($stagingRecoveryState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath ([string]$stagingRecoveryState.publishRoot)) -or
        (Test-Path -LiteralPath ([string]$stagingRecoveryState.stagingRoot))) {
        throw 'Staging recovery did not remove the partial publish and staging trees.'
    }

    $partialExternalRoot = Join-Path $testRoot 'partial-external-snapshot-install'
    $partialExternalRecoveryRoot = Join-Path `
        $testLocalAppData `
        "EverVigil\install-transactions\$transactionId"
    $partialExternalState = New-TransactionState `
        -InstallRoot $partialExternalRoot `
        -PreviousInstallRoot $partialExternalRoot `
        -BackupRoot "$partialExternalRoot.backup-$transactionId" `
        -PreviousBackupRoot "$partialExternalRoot.relocated-$transactionId" `
        -RecoveryRoot $partialExternalRecoveryRoot `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false `
        -ApplicationDataSnapshotReady $false `
        -Status staging `
        -CurrentTransaction
    New-Item -ItemType Directory -Path $partialExternalRecoveryRoot -Force |
        Out-Null
    $partialExternalRecoveryFiles = @(
        'external-uninstall-registry.json.rollback'
        'external-uninstall-registry.intent.json'
        "external-uninstall-registry.json.rollback.$transactionId.tmp"
        "external-uninstall-registry.intent.json.$transactionId.tmp"
        foreach ($role in $script:EverVigilExternalArtifactRoles) {
            "external-$role.rollback"
        }
    )
    foreach ($partialName in $partialExternalRecoveryFiles) {
        [byte[]]$partialBytes = [byte[]]::new(0)
        if ($partialName -cnotlike '*.tmp') {
            $partialBytes = [Text.UTF8Encoding]::new($false).GetBytes(
                'partial durable snapshot')
        }
        [IO.File]::WriteAllBytes(
            (Join-Path $partialExternalRecoveryRoot $partialName),
            $partialBytes)
    }
    [IO.File]::WriteAllText(
        $transactionPath,
        (($partialExternalState | ConvertTo-Json -Depth 8) + "`n"),
        [Text.UTF8Encoding]::new($false))
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath $partialExternalRecoveryRoot)) {
        throw 'Pre-mutation partial external snapshot construction did not converge safely.'
    }

    foreach ($invalidPartialCase in @(
            [pscustomobject]@{
                Name = 'foreign transaction temporary'
                Configure = {
                    param($State, $Root)
                    [IO.File]::WriteAllBytes(
                        (Join-Path `
                            $Root `
                            "external-uninstall-registry.json.rollback.$cleanupTransactionId.tmp"),
                        [byte[]]@())
                }
            }
            [pscustomobject]@{
                Name = 'unknown recovery entry'
                Configure = {
                    param($State, $Root)
                    [IO.File]::WriteAllText(
                        (Join-Path $Root 'unknown.rollback'),
                        'unowned',
                        [Text.UTF8Encoding]::new($false))
                }
            }
            [pscustomobject]@{
                Name = 'reparse recovery entry'
                Configure = {
                    param($State, $Root)
                    $target = Join-Path $testRoot 'partial-external-reparse-target'
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                    New-Item `
                        -ItemType Junction `
                        -Path (Join-Path $Root 'external-current-support-unins-exe.rollback') `
                        -Target $target | Out-Null
                }
            }
            [pscustomobject]@{
                Name = 'one-sided ready marker'
                Configure = {
                    param($State, $Root)
                    $State.externalArtifactSnapshotReady = $true
                }
            }
            [pscustomobject]@{
                Name = 'phase without ready evidence'
                Configure = {
                    param($State, $Root)
                    $State.externalCommitPhase = 'SnapshotReady'
                }
            }
        )) {
        if (Test-Path -LiteralPath $partialExternalRecoveryRoot) {
            Remove-Item `
                -LiteralPath $partialExternalRecoveryRoot `
                -Recurse `
                -Force
        }
        New-Item -ItemType Directory -Path $partialExternalRecoveryRoot -Force |
            Out-Null
        $invalidPartialState = New-TransactionState `
            -InstallRoot $partialExternalRoot `
            -PreviousInstallRoot $partialExternalRoot `
            -BackupRoot "$partialExternalRoot.backup-$transactionId" `
            -PreviousBackupRoot "$partialExternalRoot.relocated-$transactionId" `
            -RecoveryRoot $partialExternalRecoveryRoot `
            -DestinationBackupPlanned $false `
            -PreviousBackupPlanned $false `
            -DestinationOwnedInstallPresent $false `
            -InstallRootChanged $false `
            -ApplicationDataSnapshotReady $false `
            -Status staging `
            -CurrentTransaction
        & $invalidPartialCase.Configure $invalidPartialState $partialExternalRecoveryRoot
        [IO.File]::WriteAllText(
            $transactionPath,
            (($invalidPartialState | ConvertTo-Json -Depth 8) + "`n"),
            [Text.UTF8Encoding]::new($false))
        $invalidPartialRejected = $false
        try {
            & $transactionScript `
                -Action Recover `
                -TransactionPath $transactionPath
        } catch {
            $invalidPartialRejected = $true
        }
        if (-not $invalidPartialRejected -or
            -not (Test-Path -LiteralPath $transactionPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $partialExternalRecoveryRoot -PathType Container)) {
            throw "Unsafe partial external snapshot state was not preserved fail-closed: $($invalidPartialCase.Name)"
        }
        foreach ($reparseEntry in @(Get-ChildItem `
                    -LiteralPath $partialExternalRecoveryRoot `
                    -Force `
                    -ErrorAction Stop | Where-Object {
                        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                    })) {
            Remove-Item -LiteralPath $reparseEntry.FullName -Force -ErrorAction Stop
        }
        Remove-Item -LiteralPath $transactionPath -Force
    }
    Remove-Item `
        -LiteralPath $partialExternalRecoveryRoot `
        -Recurse `
        -Force

    $rolledBackCleanupRoot = Join-Path $testRoot 'rolled-back-cleanup-install'
    $rolledBackCleanupBackupRoot = "$rolledBackCleanupRoot.backup-$transactionId"
    $rolledBackCleanupPreviousBackupRoot = "$rolledBackCleanupRoot.relocated-$transactionId"
    $rolledBackCleanupEvidenceRoot = Join-Path `
        $testLocalAppData `
        "EverVigil\install-transactions\$transactionId"
    $rolledBackCleanupState = New-TransactionState `
        -InstallRoot $rolledBackCleanupRoot `
        -PreviousInstallRoot $rolledBackCleanupRoot `
        -BackupRoot $rolledBackCleanupBackupRoot `
        -PreviousBackupRoot $rolledBackCleanupPreviousBackupRoot `
        -RecoveryRoot $rolledBackCleanupEvidenceRoot `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false `
        -SettingsWasPresent $true `
        -TokenWasPresent $true `
        -ApplicationDataSnapshotReady $false `
        -Status rolledBack
    New-Item -ItemType Directory -Path $rolledBackCleanupEvidenceRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $rolledBackCleanupEvidenceRoot 'legacy-task.xml'),
        'rollback evidence',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $transactionPath,
        (($rolledBackCleanupState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    $postRollbackMarkerPath = Join-Path `
        $testLocalAppData `
        'EverVigil\system-configuration-required'
    [IO.File]::WriteAllText(
        $postRollbackMarkerPath,
        'created after rollback became durable',
        [Text.UTF8Encoding]::new($false))
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath $rolledBackCleanupEvidenceRoot) -or
        -not (Test-Path -LiteralPath $postRollbackMarkerPath -PathType Leaf)) {
        throw 'Rolled-back cleanup repeated rollback mutations instead of retiring only its evidence.'
    }
    Remove-Item -LiteralPath $postRollbackMarkerPath -Force -ErrorAction Stop

    $reparseRecoveryDataRoot = Join-Path $testLocalAppData 'EverVigil'
    $reparseRecoveryTransactionsRoot = Join-Path `
        $reparseRecoveryDataRoot `
        $script:LegacyCompatibilityDataTransactionRecoveryDirectoryName
    $reparseRecoveryTarget = Join-Path `
        $testRoot `
        'reparse-recovery-target'
    New-Item -ItemType Directory -Path $reparseRecoveryDataRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $reparseRecoveryTarget -Force | Out-Null
    New-Item `
        -ItemType Junction `
        -Path $reparseRecoveryTransactionsRoot `
        -Target $reparseRecoveryTarget | Out-Null
    $reparseRecoveryRoot = Join-Path `
        $reparseRecoveryTransactionsRoot `
        $transactionId
    $reparseRecoveryInstallRoot = Join-Path `
        $testRoot `
        'reparse-recovery-install'
    $reparseRecoveryState = New-TransactionState `
        -InstallRoot $reparseRecoveryInstallRoot `
        -PreviousInstallRoot $reparseRecoveryInstallRoot `
        -BackupRoot "$reparseRecoveryInstallRoot.backup-$transactionId" `
        -PreviousBackupRoot "$reparseRecoveryInstallRoot.relocated-$transactionId" `
        -RecoveryRoot $reparseRecoveryRoot `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false `
        -DataRootExisted $false `
        -TransactionsRootWasPresent $false `
        -Status rolledBack
    $reparseRecoveryTransactionPath = Join-Path `
        $reparseRecoveryDataRoot `
        $script:LegacyCompatibilityDataTransactionJournalFileName
    [IO.File]::WriteAllText(
        $reparseRecoveryTransactionPath,
        (($reparseRecoveryState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    $reparseRecoveryRejected = $false
    $reparseRecoveryError = ''
    try {
        & $transactionScript `
            -Action Recover `
            -TransactionPath $reparseRecoveryTransactionPath
    } catch {
        $reparseRecoveryRejected = $true
        $reparseRecoveryError = $_.Exception.Message
    }
    if (-not $reparseRecoveryRejected -or
        -not $reparseRecoveryError.Contains(
            'transaction recovery root is a reparse point',
            [StringComparison]::Ordinal) -or
        -not (Test-Path -LiteralPath $reparseRecoveryTransactionPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $reparseRecoveryTransactionsRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $reparseRecoveryTarget -PathType Container)) {
        throw "Rolled-back recovery removed a transaction junction or lost its retry authority. Error: $reparseRecoveryError"
    }
    Remove-Item -LiteralPath $reparseRecoveryTransactionsRoot -Force -ErrorAction Stop
    Remove-Item -LiteralPath $reparseRecoveryDataRoot -Recurse -Force -ErrorAction Stop
    Remove-Item -LiteralPath $reparseRecoveryTarget -Recurse -Force -ErrorAction Stop

    $dataRoot = Join-Path $testLocalAppData 'EverVigil'
    $lockedStagingCleanupRoot = Join-Path `
        $testRoot `
        'locked-staging-data-cleanup-install'
    $lockedStagingCleanupRecoveryRoot = Join-Path `
        $dataRoot `
        "install-transactions\$transactionId"
    New-Item `
        -ItemType Directory `
        -Path $lockedStagingCleanupRecoveryRoot `
        -Force | Out-Null
    $lockedMarkerPath = Join-Path $dataRoot 'system-configuration-required'
    [IO.File]::WriteAllText(
        $lockedMarkerPath,
        'deletion must fail while this file is locked',
        [Text.UTF8Encoding]::new($false))
    $lockedStagingCleanupState = New-TransactionState `
        -InstallRoot $lockedStagingCleanupRoot `
        -PreviousInstallRoot $lockedStagingCleanupRoot `
        -BackupRoot "$lockedStagingCleanupRoot.backup-$transactionId" `
        -PreviousBackupRoot "$lockedStagingCleanupRoot.relocated-$transactionId" `
        -RecoveryRoot $lockedStagingCleanupRecoveryRoot `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false `
        -DataRootExisted $false `
        -SystemConfigurationRequiredWasPresent $false `
        -TransactionsRootWasPresent $false `
        -Status staging
    [IO.File]::WriteAllText(
        $transactionPath,
        (($lockedStagingCleanupState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    $lockedMarkerStream = [IO.FileStream]::new(
        $lockedMarkerPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        $lockedCleanupFailure = $null
        try {
            & $transactionScript `
                -Action Recover `
                -TransactionPath $transactionPath
        } catch {
            $lockedCleanupFailure = $_.Exception
        }
        if ($null -eq $lockedCleanupFailure -or
            -not (Test-Path -LiteralPath $transactionPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $lockedStagingCleanupRecoveryRoot -PathType Container) -or
            -not (Test-Path -LiteralPath $lockedMarkerPath -PathType Leaf) -or
            [string](Get-Content -LiteralPath $transactionPath -Raw | ConvertFrom-Json).status -cne
                'staging') {
            throw 'A locked application-data artifact did not preserve staging rollback authority.'
        }
    } finally {
        $lockedMarkerStream.Dispose()
    }
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath $lockedStagingCleanupRecoveryRoot) -or
        (Test-Path -LiteralPath $lockedMarkerPath) -or
        (Test-Path -LiteralPath $dataRoot)) {
        throw 'Staging rollback did not converge after the application-data lock was released.'
    }

    $stagingCleanupRoot = Join-Path $testRoot 'staging-data-cleanup-install'
    $stagingCleanupRecoveryRoot = Join-Path `
        $dataRoot `
        "install-transactions\$transactionId"
    New-Item -ItemType Directory -Path $stagingCleanupRecoveryRoot -Force |
        Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $dataRoot 'system-configuration-required'),
        'created before protected bootstrap failed',
        [Text.UTF8Encoding]::new($false))
    $stagingCleanupState = New-TransactionState `
        -InstallRoot $stagingCleanupRoot `
        -PreviousInstallRoot $stagingCleanupRoot `
        -BackupRoot "$stagingCleanupRoot.backup-$transactionId" `
        -PreviousBackupRoot "$stagingCleanupRoot.relocated-$transactionId" `
        -RecoveryRoot $stagingCleanupRecoveryRoot `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false `
        -DataRootExisted $false `
        -SystemConfigurationRequiredWasPresent $false `
        -TransactionsRootWasPresent $false `
        -Status staging
    [IO.File]::WriteAllText(
        $transactionPath,
        (($stagingCleanupState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath $stagingCleanupRecoveryRoot) -or
        (Test-Path -LiteralPath $dataRoot)) {
        throw 'Staging rollback did not remove application data created after a clean prestate.'
    }

    $logsRoot = Join-Path $dataRoot 'Logs'
    New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $logsRoot 'preexisting.log'),
        'preserve',
        [Text.UTF8Encoding]::new($false))
    $dataRollbackRoot = Join-Path $testRoot 'data-rollback-install'
    $dataRollbackBackupRoot = "$dataRollbackRoot.backup-$transactionId"
    $dataRollbackPreviousBackupRoot = "$dataRollbackRoot.relocated-$transactionId"
    $dataRollbackRecoveryRoot = Join-Path `
        $dataRoot `
        "install-transactions\$transactionId"
    New-KnownInstallLayout -Root $dataRollbackRoot
    Write-EverVigilInstallOwnership -Path $dataRollbackRoot
    $dataRollbackState = New-TransactionState `
        -InstallRoot $dataRollbackRoot `
        -PreviousInstallRoot $dataRollbackRoot `
        -BackupRoot $dataRollbackBackupRoot `
        -PreviousBackupRoot $dataRollbackPreviousBackupRoot `
        -RecoveryRoot $dataRollbackRecoveryRoot `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false `
        -DataRootExisted $true `
        -SettingsWasPresent $false `
        -TokenWasPresent $false `
        -AppliedSystemConfigurationWasPresent $false `
        -SystemConfigurationRequiredWasPresent $false `
        -DiagnosticLoggingWasPresent $false `
        -LogsRootWasPresent $true `
        -TransactionsRootWasPresent $false
    foreach ($generatedFile in @(
            'settings.json'
            'token.dat'
            'applied-system-configuration.json'
            'system-configuration-required'
            'diagnostic-logging.enabled'
        )) {
        [IO.File]::WriteAllText(
            (Join-Path $dataRoot $generatedFile),
            'generated',
            [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText(
        $transactionPath,
        (($dataRollbackState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    $generatedFilesRemaining = @(@(
            'settings.json'
            'token.dat'
            'applied-system-configuration.json'
            'system-configuration-required'
            'diagnostic-logging.enabled'
        ) | Where-Object { Test-Path -LiteralPath (Join-Path $dataRoot $_) })
    if ((Test-Path -LiteralPath $transactionPath) -or
        (Test-Path -LiteralPath $dataRollbackRoot) -or
        $generatedFilesRemaining.Count -gt 0 -or
        -not (Test-Path -LiteralPath (Join-Path $logsRoot 'preexisting.log') -PathType Leaf)) {
        throw 'Data rollback did not remove only newly created state while preserving the prior log tree.'
    }

    $snapshotRollbackRoot = Join-Path $testRoot 'snapshot-rollback-install'
    $snapshotRollbackBackupRoot = "$snapshotRollbackRoot.backup-$transactionId"
    $snapshotRollbackPreviousBackupRoot = "$snapshotRollbackRoot.relocated-$transactionId"
    $snapshotRollbackRecoveryRoot = Join-Path `
        $dataRoot `
        "install-transactions\$transactionId"
    New-KnownInstallLayout -Root $snapshotRollbackRoot
    Write-EverVigilInstallOwnership -Path $snapshotRollbackRoot
    $snapshotFiles = [ordered]@{
        'settings.json' = [Text.UTF8Encoding]::new($false).GetBytes('original settings bytes')
        'token.dat' = [byte[]](0, 1, 2, 3, 254, 255)
        'applied-system-configuration.json' = [Text.UTF8Encoding]::new($false).GetBytes('original applied state')
        'system-configuration-required' = [Text.UTF8Encoding]::new($false).GetBytes('original startup block')
        'diagnostic-logging.enabled' = [byte[]]@()
    }
    $snapshotHashes = @{}
    foreach ($entry in $snapshotFiles.GetEnumerator()) {
        $path = Join-Path $dataRoot $entry.Key
        [IO.File]::WriteAllBytes($path, [byte[]]$entry.Value)
        $snapshotHashes[$entry.Key] = Get-EverVigilFileSha256 -Path $path
    }
    $existingSettingsQuarantine = 'settings.json.invalid-20260101-000000'
    $existingTokenQuarantine =
        'token.dat.invalid-20260101-000000-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    [IO.File]::WriteAllText(
        (Join-Path $dataRoot $existingSettingsQuarantine),
        'preserve settings quarantine',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $dataRoot $existingTokenQuarantine),
        'preserve token quarantine',
        [Text.UTF8Encoding]::new($false))
    $snapshotRollbackState = New-TransactionState `
        -InstallRoot $snapshotRollbackRoot `
        -PreviousInstallRoot $snapshotRollbackRoot `
        -BackupRoot $snapshotRollbackBackupRoot `
        -PreviousBackupRoot $snapshotRollbackPreviousBackupRoot `
        -RecoveryRoot $snapshotRollbackRecoveryRoot `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false `
        -SettingsWasPresent $true `
        -TokenWasPresent $true `
        -AppliedSystemConfigurationWasPresent $true `
        -SystemConfigurationRequiredWasPresent $true `
        -DiagnosticLoggingWasPresent $true `
        -LogsRootWasPresent $true `
        -TransactionsRootWasPresent $false
    $snapshotRollbackState.settingsQuarantineFiles = @($existingSettingsQuarantine)
    $snapshotRollbackState.tokenQuarantineFiles = @($existingTokenQuarantine)
    $snapshotRollbackState.applicationDataSnapshots = @(
        New-EverVigilApplicationDataSnapshots `
            -DataRoot $dataRoot `
            -RecoveryRoot $snapshotRollbackRecoveryRoot `
            -State $snapshotRollbackState)
    $tokenSnapshotPath = Join-Path $snapshotRollbackRecoveryRoot 'token.dat.rollback'
    [IO.File]::WriteAllBytes($tokenSnapshotPath, [byte[]](9, 9, 9))
    $corruptSnapshotRejected = $false
    try {
        Assert-EverVigilApplicationDataSnapshotState `
            -State $snapshotRollbackState `
            -RecoveryRoot $snapshotRollbackRecoveryRoot `
            -Status pending `
            -RequireBackupFiles
    } catch {
        $corruptSnapshotRejected = $true
    }
    if (-not $corruptSnapshotRejected) {
        throw 'A corrupted application-data rollback snapshot passed SHA-256 validation.'
    }
    Remove-Item -LiteralPath $tokenSnapshotPath -Force
    $restoredSnapshotHash = Copy-EverVigilFileDurably `
        -Source (Join-Path $dataRoot 'token.dat') `
        -Destination $tokenSnapshotPath
    if ($restoredSnapshotHash -ne $snapshotHashes['token.dat']) {
        throw 'The token rollback snapshot could not be restored after corruption testing.'
    }
    foreach ($entry in $snapshotFiles.GetEnumerator()) {
        [IO.File]::WriteAllBytes(
            (Join-Path $dataRoot $entry.Key),
            [Text.UTF8Encoding]::new($false).GetBytes("replacement $($entry.Key)"))
    }
    $newSettingsQuarantine =
        'settings.json.invalid-20260812-120000-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $newTokenQuarantine =
        'token.dat.invalid-20260812-120000-cccccccccccccccccccccccccccccccc'
    [IO.File]::WriteAllText(
        (Join-Path $dataRoot $newSettingsQuarantine),
        'remove settings quarantine',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $dataRoot $newTokenQuarantine),
        'remove token quarantine',
        [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath (Join-Path $dataRoot $existingSettingsQuarantine) -Force
    Remove-Item -LiteralPath (Join-Path $dataRoot $existingTokenQuarantine) -Force
    [IO.File]::WriteAllText(
        $transactionPath,
        (($snapshotRollbackState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    & $transactionScript `
        -Action Recover `
        -TransactionPath $transactionPath
    foreach ($entry in $snapshotFiles.GetEnumerator()) {
        $restoredPath = Join-Path $dataRoot $entry.Key
        if ((Get-EverVigilFileSha256 -Path $restoredPath) -ne $snapshotHashes[$entry.Key]) {
            throw "Rollback did not restore the exact prior application-data bytes: $($entry.Key)"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dataRoot $existingSettingsQuarantine) -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $dataRoot $existingTokenQuarantine) -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $dataRoot $newSettingsQuarantine)) -or
        (Test-Path -LiteralPath (Join-Path $dataRoot $newTokenQuarantine)) -or
        (Test-Path -LiteralPath $snapshotRollbackRecoveryRoot) -or
        (Test-Path -LiteralPath $snapshotRollbackRoot) -or
        (Test-Path -LiteralPath $transactionPath)) {
        throw 'Snapshot rollback did not preserve prior quarantine files and remove only new artifacts.'
    }

    $atomicInstallRoot = Join-Path $testRoot 'atomic-journal-recovery'
    $atomicState = New-TransactionState `
        -InstallRoot $atomicInstallRoot `
        -PreviousInstallRoot $atomicInstallRoot `
        -BackupRoot "$atomicInstallRoot.backup-$transactionId" `
        -PreviousBackupRoot "$atomicInstallRoot.relocated-$transactionId" `
        -RecoveryRoot (Join-Path `
            $testLocalAppData `
            "EverVigil\install-transactions\$transactionId") `
        -DestinationBackupPlanned $false `
        -PreviousBackupPlanned $false `
        -DestinationOwnedInstallPresent $false `
        -InstallRootChanged $false `
        -Status rolledBack
    $uniqueAtomicPath = "$transactionPath.new-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText(
        $uniqueAtomicPath,
        (($atomicState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    Set-EverVigilAtomicJournalFileAcl -Path $uniqueAtomicPath
    & $transactionScript -Action Recover -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $uniqueAtomicPath) -or
        (Test-Path -LiteralPath $transactionPath)) {
        throw 'A unique complete atomic install journal was not promoted and recovered.'
    }

    [IO.File]::WriteAllText(
        $transactionPath,
        (($atomicState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    $nonAuthoritativeAtomicPath =
        "$transactionPath.new-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText(
        $nonAuthoritativeAtomicPath,
        (($atomicState | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false))
    Set-EverVigilAtomicJournalFileAcl -Path $nonAuthoritativeAtomicPath
    & $transactionScript -Action Recover -TransactionPath $transactionPath
    if ((Test-Path -LiteralPath $nonAuthoritativeAtomicPath) -or
        (Test-Path -LiteralPath $transactionPath)) {
        throw 'A same-transaction non-authoritative atomic journal was not retired before recovery.'
    }

    $ambiguousAtomicPaths = @(
        "$transactionPath.new-$([guid]::NewGuid().ToString('N'))"
        "$transactionPath.new-$([guid]::NewGuid().ToString('N'))")
    foreach ($ambiguousAtomicPath in $ambiguousAtomicPaths) {
        [IO.File]::WriteAllText(
            $ambiguousAtomicPath,
            (($atomicState | ConvertTo-Json -Depth 6) + "`n"),
            [Text.UTF8Encoding]::new($false))
        Set-EverVigilAtomicJournalFileAcl -Path $ambiguousAtomicPath
    }
    $ambiguousAtomicRejected = $false
    try {
        & $transactionScript -Action Recover -TransactionPath $transactionPath
    } catch {
        $ambiguousAtomicRejected = $_.Exception.Message -match
            'Multiple atomic install transactions'
    }
    if (-not $ambiguousAtomicRejected -or
        (Test-Path -LiteralPath $transactionPath) -or
        @($ambiguousAtomicPaths | Where-Object {
                -not (Test-Path -LiteralPath $_ -PathType Leaf)
            }).Count -gt 0) {
        throw 'Ambiguous atomic install journals were not preserved fail-closed.'
    }
    Remove-Item -LiteralPath $ambiguousAtomicPaths -Force

    $unknownAtomicState = [ordered]@{}
    foreach ($atomicStateEntry in $atomicState.GetEnumerator()) {
        $unknownAtomicState[$atomicStateEntry.Key] = $atomicStateEntry.Value
    }
    $unknownAtomicState.unexpectedProperty = $true
    foreach ($invalidAtomicFixture in @(
            [pscustomobject]@{
                Label = 'invalid JSON'
                Content = '{}'
                Protect = $true
            }
            [pscustomobject]@{
                Label = 'wrong ACL'
                Content = (($atomicState | ConvertTo-Json -Depth 6) + "`n")
                Protect = $false
            }
            [pscustomobject]@{
                Label = 'unknown property'
                Content = ($unknownAtomicState | ConvertTo-Json -Depth 6)
                Protect = $true
            }
        )) {
        $invalidAtomicPath =
            "$transactionPath.new-$([guid]::NewGuid().ToString('N'))"
        [IO.File]::WriteAllText(
            $invalidAtomicPath,
            [string]$invalidAtomicFixture.Content,
            [Text.UTF8Encoding]::new($false))
        if ($invalidAtomicFixture.Protect) {
            Set-EverVigilAtomicJournalFileAcl -Path $invalidAtomicPath
        }
        $invalidAtomicRejected = $false
        try {
            & $transactionScript -Action Recover -TransactionPath $transactionPath
        } catch {
            $invalidAtomicRejected = $true
        }
        if (-not $invalidAtomicRejected -or
            -not (Test-Path -LiteralPath $invalidAtomicPath -PathType Leaf) -or
            (Test-Path -LiteralPath $transactionPath)) {
            throw "An atomic install journal with $($invalidAtomicFixture.Label) was not preserved fail-closed."
        }
        Remove-Item -LiteralPath $invalidAtomicPath -Force
    }

    $supportFixtureRoot = Join-Path $testRoot 'uninstall-support-fixture\Support'
    $supportFixtureScripts = Join-Path $supportFixtureRoot 'scripts'
    New-Item -ItemType Directory -Path $supportFixtureScripts -Force | Out-Null
    Copy-Item -LiteralPath $uninstallScript -Destination $supportFixtureRoot
    $requiredSupportScriptNames = @(
        'Complete-InstallTransaction.ps1'
        'InstallTransactionData.ps1'
        'Invoke-InteractiveUserTask.ps1'
        'Invoke-SystemMaintenance.ps1'
        'LegacyCompatibility.generated.ps1'
        'Resolve-SafeInstallRoot.ps1')
    foreach ($supportScriptName in $requiredSupportScriptNames) {
        Copy-Item `
            -LiteralPath (Join-Path $repositoryRoot "scripts\$supportScriptName") `
            -Destination $supportFixtureScripts
    }
    $missingSupportHelper = Join-Path `
        $supportFixtureScripts `
        'InstallTransactionData.ps1'
    Remove-Item -LiteralPath $missingSupportHelper -Force
    $supportGuardRoot = Join-Path $testRoot 'uninstall-support-guard'
    New-Item -ItemType Directory -Path $supportGuardRoot -Force | Out-Null
    $supportGuardSentinel = Join-Path $supportGuardRoot 'DO-NOT-DELETE.txt'
    [IO.File]::WriteAllText(
        $supportGuardSentinel,
        'preserve',
        [Text.UTF8Encoding]::new($false))
    $supportStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $supportStartInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $supportStartInfo.UseShellExecute = $false
    $supportStartInfo.CreateNoWindow = $true
    $supportStartInfo.RedirectStandardOutput = $true
    $supportStartInfo.RedirectStandardError = $true
    $supportStartInfo.Environment['LOCALAPPDATA'] = Join-Path `
        $testRoot `
        'MissingSupportLocalAppData'
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-File',
            (Join-Path $supportFixtureRoot 'Uninstall.ps1'),
            '-InstallRoot', $supportGuardRoot, '-KeepData')) {
        [void]$supportStartInfo.ArgumentList.Add($argument)
    }
    $supportProcess = [Diagnostics.Process]::Start($supportStartInfo)
    $supportOutputTask = $supportProcess.StandardOutput.ReadToEndAsync()
    $supportErrorTask = $supportProcess.StandardError.ReadToEndAsync()
    if (-not $supportProcess.WaitForExit(30000)) {
        try { $supportProcess.Kill($true) } catch {}
        throw 'Missing uninstall-support helper negative test timed out.'
    }
    $supportOutput = $supportOutputTask.GetAwaiter().GetResult()
    $supportError = $supportErrorTask.GetAwaiter().GetResult()
    if ($supportProcess.ExitCode -eq 0 -or
        -not (Test-Path -LiteralPath $supportGuardSentinel -PathType Leaf) -or
        $supportError -notmatch 'Required uninstall support helper is missing or unsafe') {
        throw "Uninstall did not fail before mutation when a transitive support helper was missing: stdout=$supportOutput stderr=$supportError"
    }

    $uninstallGuardRoot = Join-Path $testRoot 'uninstall-guard'
    New-Item -ItemType Directory -Path $uninstallGuardRoot -Force | Out-Null
    $uninstallSentinel = Join-Path $uninstallGuardRoot 'DO-NOT-DELETE.txt'
    [IO.File]::WriteAllText(
        $uninstallSentinel,
        'preserve',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $transactionPath,
        '{}',
        [Text.UTF8Encoding]::new($false))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['LOCALAPPDATA'] = $testLocalAppData
    foreach ($argument in @(
            '-NoLogo'
            '-NoProfile'
            '-File'
            $uninstallScript
            '-InstallRoot'
            $uninstallGuardRoot
            '-KeepData'
        )) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $uninstallProcess = [Diagnostics.Process]::Start($startInfo)
    $uninstallOutput = $uninstallProcess.StandardOutput.ReadToEndAsync()
    $uninstallError = $uninstallProcess.StandardError.ReadToEndAsync()
    if (-not $uninstallProcess.WaitForExit(30000)) {
        try { $uninstallProcess.Kill($true) } catch {}
        throw 'Pending-transaction uninstall guard timed out.'
    }
    $uninstallStandardOutput = $uninstallOutput.GetAwaiter().GetResult()
    $uninstallStandardError = $uninstallError.GetAwaiter().GetResult()
    if ($uninstallProcess.ExitCode -eq 0 -or
        -not (Test-Path -LiteralPath $uninstallSentinel -PathType Leaf) -or
        -not ($uninstallStandardError -match
            'install transaction (?:is invalid|does not have the exact recognized schema)')) {
        throw "Uninstall did not fail closed for a pending install transaction: stdout=$uninstallStandardOutput stderr=$uninstallStandardError"
    }
    Remove-Item -LiteralPath $transactionPath -Force

    . $transactionScript
    & {
        $fixtureRoot = Join-Path $testRoot 'recovery-broker-bootstrap'
        $script:recoveryBootstrapBrokerPath = Join-Path `
            $fixtureRoot `
            'EverVigil.Broker.exe'
        $originalPendingSystemJournalPath =
            $script:PendingSystemJournalPath
        $script:PendingSystemJournalPath = Join-Path `
            $fixtureRoot `
            'pending-system-configuration.json'
        function Get-EverVigilProtectedBrokerPath {
            return $script:recoveryBootstrapBrokerPath
        }
        function Get-OwnedInstallerSystemJournalTemporaries {
            param([string]$TransactionId)
            return @()
        }
        function Resolve-EverVigilInstallTransactionAtomicState {
            param([string]$Path)
            return $script:recoveryBootstrapState
        }
        function Assert-NoForeignPendingSystemJournal {}
        function Remove-OwnedInstallerSystemJournalTemporariesAfterRollback {}
        function Invoke-EverVigilSystemBroker {
            param(
                [string]$Operation,
                [guid]$TransactionId,
                [string]$Initiator,
                [switch]$AllowBootstrap
            )

            $script:recoveryBootstrapCalls.Add([pscustomobject]@{
                    Operation = $Operation
                    TransactionId = $TransactionId.ToString('N')
                    Initiator = $Initiator
                    AllowBootstrap = [bool]$AllowBootstrap
                })
            if ($Operation -eq 'Status' -and $AllowBootstrap) {
                [IO.File]::WriteAllText(
                    $script:recoveryBootstrapBrokerPath,
                    'bootstrapped canonical broker fixture',
                    [Text.UTF8Encoding]::new($false))
            } elseif ($Operation -eq 'Rollback' -and
                -not (Test-Path `
                    -LiteralPath $script:recoveryBootstrapBrokerPath `
                    -PathType Leaf)) {
                throw 'The protected broker is not installed.'
            }
            return [pscustomobject]@{
                success = $true
                disposition = if ($Operation -eq 'Status') {
                    'CanonicalReady'
                } else {
                    'RolledBack'
                }
                errorCode = 'None'
                transactionId = $TransactionId.ToString('D')
            }
        }
        try {
            foreach ($recoveryBootstrapCase in @(
                    [pscustomobject]@{
                        Name = 'authorized initial rollback without protected broker'
                        BrokerExists = $false
                        BrokerWasPresentBefore = $false
                        CleanupAuthorized = $true
                        BrokerReady = $false
                        ExpectedOperations = 'Status:True,Rollback:False'
                        ExpectFailure = $false
                    }
                    [pscustomobject]@{
                        Name = 'canonical broker already exists'
                        BrokerExists = $true
                        BrokerWasPresentBefore = $false
                        CleanupAuthorized = $true
                        BrokerReady = $false
                        ExpectedOperations = 'Rollback:False'
                        ExpectFailure = $false
                    }
                    [pscustomobject]@{
                        Name = 'missing previously protected broker fails closed'
                        BrokerExists = $false
                        BrokerWasPresentBefore = $true
                        CleanupAuthorized = $true
                        BrokerReady = $false
                        ExpectedOperations = 'Rollback:False'
                        ExpectFailure = $true
                    }
                )) {
                if (Test-Path -LiteralPath $fixtureRoot) {
                    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
                }
                New-Item -ItemType Directory -Path $fixtureRoot -Force |
                    Out-Null
                if ($recoveryBootstrapCase.BrokerExists) {
                    [IO.File]::WriteAllText(
                        $script:recoveryBootstrapBrokerPath,
                        'canonical broker fixture',
                        [Text.UTF8Encoding]::new($false))
                }
                [IO.File]::WriteAllText(
                    $script:PendingSystemJournalPath,
                    '{}',
                    [Text.UTF8Encoding]::new($false))
                $script:recoveryBootstrapState = [pscustomobject]@{
                    transactionId = $transactionId
                    migrationApplied = $false
                    protectedBrokerWasPresentBefore =
                        [bool]$recoveryBootstrapCase.BrokerWasPresentBefore
                    protectedBrokerCleanupAuthorized =
                        [bool]$recoveryBootstrapCase.CleanupAuthorized
                    protectedBrokerReady =
                        [bool]$recoveryBootstrapCase.BrokerReady
                }
                $script:recoveryBootstrapCalls =
                    [Collections.Generic.List[object]]::new()
                $observedError = $null
                $fixtureMutex = [Threading.Mutex]::new($false)
                $fixtureMutexTaken = $false
                try {
                    $fixtureMutexTaken = $fixtureMutex.WaitOne(
                        [TimeSpan]::FromSeconds(10))
                    if (-not $fixtureMutexTaken) {
                        throw 'The recovery-bootstrap fixture could not acquire its mutex.'
                    }
                    $script:InstallTransactionMutex = $fixtureMutex
                    $script:InstallTransactionMutexTaken = $true
                    try {
                        Invoke-SystemBrokerTransaction `
                            -State $script:recoveryBootstrapState `
                            -Mode Rollback
                    } catch {
                        $observedError = $_.Exception
                    }
                    $fixtureMutexTaken = $script:InstallTransactionMutexTaken
                } finally {
                    if ($fixtureMutexTaken) {
                        $fixtureMutex.ReleaseMutex()
                    }
                    $script:InstallTransactionMutexTaken = $false
                    $script:InstallTransactionMutex = $null
                    $fixtureMutex.Dispose()
                }
                $observedOperations = @(
                    $script:recoveryBootstrapCalls |
                        ForEach-Object {
                            "$($_.Operation):$($_.AllowBootstrap)"
                        }) -join ','
                if ($observedOperations -cne
                        $recoveryBootstrapCase.ExpectedOperations -or
                    [bool]($null -ne $observedError) -ne
                        [bool]$recoveryBootstrapCase.ExpectFailure -or
                    @($script:recoveryBootstrapCalls | Where-Object {
                            $_.TransactionId -cne $transactionId -or
                            $_.Initiator -cne 'Installer'
                        }).Count -gt 0 -or
                    [bool](Test-Path `
                            -LiteralPath $script:PendingSystemJournalPath `
                            -PathType Leaf) -ne
                        [bool]$recoveryBootstrapCase.ExpectFailure) {
                    throw "Recovery broker bootstrap did not preserve its security contract for $($recoveryBootstrapCase.Name)."
                }
            }
        } finally {
            $script:PendingSystemJournalPath =
                $originalPendingSystemJournalPath
            $script:InstallTransactionMutexTaken = $false
            $script:InstallTransactionMutex = $null
            if (Test-Path -LiteralPath $fixtureRoot) {
                Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
            }
        }
    }
    # The dot-sourced script declares a case-insensitive TransactionPath
    # parameter. Restore this test fixture path before dispatching phases.
    $transactionPath = Join-Path $testLocalAppData 'EverVigil\install-transaction.json'
    $originalAtomicResolver = (Get-Command `
            Resolve-EverVigilInstallTransactionAtomicState `
            -CommandType Function).ScriptBlock
    $originalSystemTemporaryReader = (Get-Command `
            Get-OwnedInstallerSystemJournalTemporaries `
            -CommandType Function).ScriptBlock
    $originalCommitTransaction = (Get-Command `
            Commit-EverVigilInstallTransaction `
            -CommandType Function).ScriptBlock
    $originalRollbackTransaction = (Get-Command `
            Rollback-EverVigilInstallTransaction `
            -CommandType Function).ScriptBlock
    function Resolve-EverVigilInstallTransactionAtomicState {
        param([string]$Path)
        return $script:phaseDispatchState
    }
    function Get-OwnedInstallerSystemJournalTemporaries {
        param([string]$TransactionId)
        return @($script:phaseDispatchTemporaries)
    }
    function Commit-EverVigilInstallTransaction {
        param([string]$Path, $State)
        $script:phaseDispatchResult = 'Commit'
    }
    function Rollback-EverVigilInstallTransaction {
        param([string]$Path, $State)
        $script:phaseDispatchResult = 'Rollback'
    }
    try {
        foreach ($phaseDispatchCase in @(
                [pscustomobject]@{ Phase = 'SnapshotReady'; TemporaryCount = 0; Expected = 'Rollback' }
                [pscustomobject]@{ Phase = 'SnapshotReady'; TemporaryCount = 1; Expected = 'Rollback' }
                [pscustomobject]@{ Phase = 'SystemCommitPrepared'; TemporaryCount = 0; Expected = 'Commit' }
                [pscustomobject]@{ Phase = 'SystemCommitPrepared'; TemporaryCount = 1; Expected = 'Commit' }
                [pscustomobject]@{ Phase = 'SystemCommitted'; TemporaryCount = 1; Expected = 'Commit' }
                [pscustomobject]@{ Phase = 'CleanupComplete'; TemporaryCount = 1; Expected = 'Commit' }
            )) {
            $script:phaseDispatchState = [pscustomobject]@{
                transactionId = $transactionId
                externalCommitPhase = $phaseDispatchCase.Phase
                status = if ($phaseDispatchCase.Phase -in @(
                        'SystemCommitted', 'CleanupComplete')) {
                    'committed'
                } else {
                    'readyToCommit'
                }
            }
            $script:phaseDispatchTemporaries = @(
                for ($index = 0; $index -lt $phaseDispatchCase.TemporaryCount; $index++) {
                    [pscustomobject]@{ Name = "same-transaction-$index.tmp" }
                })
            $script:phaseDispatchResult = ''
            Invoke-EverVigilInstallTransaction `
                -RequestedAction Recover `
                -Path $phaseDispatchTransactionPath
            if ([string]$script:phaseDispatchResult -cne
                [string]$phaseDispatchCase.Expected) {
                throw "Recovery selected '$($script:phaseDispatchResult)' for phase '$($phaseDispatchCase.Phase)' with $($phaseDispatchCase.TemporaryCount) temporary file(s)."
            }
        }
    } finally {
        Set-Item `
            -LiteralPath Function:\Resolve-EverVigilInstallTransactionAtomicState `
            -Value $originalAtomicResolver
        Set-Item `
            -LiteralPath Function:\Get-OwnedInstallerSystemJournalTemporaries `
            -Value $originalSystemTemporaryReader
        Set-Item `
            -LiteralPath Function:\Commit-EverVigilInstallTransaction `
            -Value $originalCommitTransaction
        Set-Item `
            -LiteralPath Function:\Rollback-EverVigilInstallTransaction `
            -Value $originalRollbackTransaction
    }

    $systemTemporaryRoot = Join-Path $testLocalAppData 'EverVigil'
    New-Item -ItemType Directory -Path $systemTemporaryRoot -Force | Out-Null
    $foreignSystemTemporary = Join-Path `
        $systemTemporaryRoot `
        "applied-system-configuration.json.$cleanupTransactionId.tmp"
    [IO.File]::WriteAllBytes($foreignSystemTemporary, [byte[]]@())
    $systemTemporaryMutex = New-EverVigilSystemTransactionMutex
    $systemTemporaryMutexTaken = $false
    try {
        try {
            $systemTemporaryMutexTaken = $systemTemporaryMutex.WaitOne(
                [TimeSpan]::FromSeconds(10))
        } catch [Threading.AbandonedMutexException] {
            $systemTemporaryMutexTaken = $true
        }
        if (-not $systemTemporaryMutexTaken) {
            throw 'The foreign system-temporary fixture could not acquire the transaction mutex.'
        }
        $script:InstallTransactionMutex = $systemTemporaryMutex
        $script:InstallTransactionMutexTaken = $true
        $foreignSystemTemporaryRejected = $false
        try {
            [void](Get-OwnedInstallerSystemJournalTemporaries `
                    -TransactionId $transactionId)
        } catch {
            $foreignSystemTemporaryRejected = $_.Exception.Message -match
                'must be recovered first'
        }
        if (-not $foreignSystemTemporaryRejected -or
            -not (Test-Path -LiteralPath $foreignSystemTemporary -PathType Leaf)) {
            throw 'A foreign system-journal temporary was not preserved fail-closed.'
        }
    } finally {
        if ($script:InstallTransactionMutexTaken) {
            $systemTemporaryMutex.ReleaseMutex()
        }
        $script:InstallTransactionMutexTaken = $false
        $script:InstallTransactionMutex = $null
        $systemTemporaryMutex.Dispose()
        Remove-Item `
            -LiteralPath $foreignSystemTemporary `
            -Force `
            -ErrorAction SilentlyContinue
    }

    $legacyV121SupportRoot = Join-Path `
        $env:LOCALAPPDATA `
        $script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData
    if (Test-Path -LiteralPath $legacyV121SupportRoot) {
        Remove-Item -LiteralPath $legacyV121SupportRoot -Recurse -Force
    }
    $legacyV121SupportFiles = @(
        'unins000.dat'
        'unins000.exe'
        'Support\Uninstall.ps1'
        'Support\scripts\Invoke-SystemMaintenance.ps1'
        'Support\scripts\Resolve-SafeInstallRoot.ps1')
    foreach ($legacyV121SupportFile in $legacyV121SupportFiles) {
        $legacyV121SupportPath = Join-Path `
            $legacyV121SupportRoot `
            $legacyV121SupportFile
        New-Item `
            -ItemType Directory `
            -Path (Split-Path -Parent $legacyV121SupportPath) `
            -Force | Out-Null
        [IO.File]::WriteAllText(
            $legacyV121SupportPath,
            "frozen v1.2.1 support fixture: $legacyV121SupportFile",
            [Text.UTF8Encoding]::new($false))
    }
    $currentOnlyLegacySupportPath = Join-Path `
        $legacyV121SupportRoot `
        'Support\scripts\Complete-InstallTransaction.ps1'
    [IO.File]::WriteAllText(
        $currentOnlyLegacySupportPath,
        'must not be accepted as part of the frozen v1.2.1 manifest',
        [Text.UTF8Encoding]::new($false))
    $mixedLegacyManifestRejected = $false
    try {
        Remove-EverVigilLegacyUninstallSupport
    } catch {
        $mixedLegacyManifestRejected = $_.Exception.Message -match
            'unexpected entry'
    }
    if (-not $mixedLegacyManifestRejected -or
        -not (Test-Path -LiteralPath $legacyV121SupportRoot -PathType Container)) {
        throw 'Legacy support cleanup did not keep the frozen three-script manifest separate from the current seven-script manifest.'
    }
    Remove-Item -LiteralPath $currentOnlyLegacySupportPath -Force
    Remove-EverVigilLegacyUninstallSupport
    if (Test-Path -LiteralPath $legacyV121SupportRoot) {
        throw 'The exact frozen v1.2.1 uninstall-support tree did not retire.'
    }
    $originalBrokerInvoker = (Get-Command `
            Invoke-EverVigilSystemBroker `
            -CommandType Function).ScriptBlock
    $originalRetirementPaths = (Get-Command `
            Get-EverVigilProtectedBrokerRetirementPaths `
            -CommandType Function).ScriptBlock
    $originalRetirementCompletion = (Get-Command `
            Complete-EverVigilProtectedBrokerRetirementFromReceipt `
            -CommandType Function).ScriptBlock
    $bootstrapCleanupRoot = Join-Path $testRoot 'mock-protected-bootstrap'
    $script:mockBootstrapCleanupPaths = [pscustomobject]@{
        ProductRoot = $bootstrapCleanupRoot
        CanonicalPath = Join-Path $bootstrapCleanupRoot 'EverVigil.Broker.exe'
        RetirementReceiptPath = Join-Path $bootstrapCleanupRoot 'retirement.json'
    }
    function Get-EverVigilProtectedBrokerRetirementPaths {
        return $script:mockBootstrapCleanupPaths
    }
    function Invoke-EverVigilSystemBroker {
        param(
            [string]$Operation,
            [guid]$TransactionId,
            [string]$Initiator
        )

        $script:mockBootstrapInvocationCount++
        [void]$script:mockBootstrapTransactionIds.Add(
            $TransactionId.ToString('N'))
        if ($script:mockBootstrapFailuresRemaining -gt 0) {
            $script:mockBootstrapFailuresRemaining--
            throw 'simulated authenticated response loss'
        }
        return [pscustomobject]@{
            success = $true
            disposition = $script:mockBootstrapDisposition
            errorCode = 'None'
            transactionId = $TransactionId.ToString('D')
        }
    }
    function Complete-EverVigilProtectedBrokerRetirementFromReceipt {
        param(
            [string]$ExpectedOwnerSid,
            [guid]$ExpectedTransactionId
        )

        if (-not [string]::Equals(
                $ExpectedOwnerSid,
                (Get-EverVigilOwnerSid),
                [StringComparison]::Ordinal) -or
            $ExpectedTransactionId.ToString('N') -cne
                $script:cleanupTransactionId) {
            throw 'The bootstrap-cleanup fixture received the wrong protected identity.'
        }
        $script:mockBootstrapRetirementCompleted = $true
        if (Test-Path -LiteralPath $script:mockBootstrapCleanupPaths.ProductRoot) {
            Remove-Item `
                -LiteralPath $script:mockBootstrapCleanupPaths.ProductRoot `
                -Recurse `
                -Force
        }
    }
    try {
        foreach ($bootstrapCleanupScenario in @(
                [pscustomobject]@{
                    Name = 'durable cleanup intent before bootstrap'
                    Failures = 0
                    Disposition = 'NoChange'
                    ReceiptFallback = $false
                    CreateProduct = $false
                    ExistingInstallPresent = $false
                    BrokerWasPresentBefore = $false
                    ExpectedInvocations = 0
                    ExpectRetirement = $false
                    ExpectedProductPresent = $false
                }
                [pscustomobject]@{
                    Name = 'immediate response'
                    Failures = 0
                    Disposition = 'RetirementRequired'
                    ReceiptFallback = $false
                    CreateProduct = $true
                    ExistingInstallPresent = $false
                    BrokerWasPresentBefore = $false
                    ExpectedInvocations = 1
                    ExpectRetirement = $true
                    ExpectedProductPresent = $false
                }
                [pscustomobject]@{
                    Name = 'one lost response'
                    Failures = 1
                    Disposition = 'RetirementRequired'
                    ReceiptFallback = $false
                    CreateProduct = $true
                    ExistingInstallPresent = $false
                    BrokerWasPresentBefore = $false
                    ExpectedInvocations = 2
                    ExpectRetirement = $true
                    ExpectedProductPresent = $false
                }
                [pscustomobject]@{
                    Name = 'two lost responses after receipt'
                    Failures = 2
                    Disposition = 'RetirementRequired'
                    ReceiptFallback = $true
                    CreateProduct = $true
                    ExistingInstallPresent = $false
                    BrokerWasPresentBefore = $false
                    ExpectedInvocations = 2
                    ExpectRetirement = $true
                    ExpectedProductPresent = $false
                }
                [pscustomobject]@{
                    Name = 'another protected owner remains'
                    Failures = 0
                    Disposition = 'Completed'
                    ReceiptFallback = $false
                    CreateProduct = $true
                    ExistingInstallPresent = $false
                    BrokerWasPresentBefore = $false
                    ExpectedInvocations = 1
                    ExpectRetirement = $false
                    ExpectedProductPresent = $true
                }
                [pscustomobject]@{
                    Name = 'v1.2.1 install without a prior protected broker'
                    Failures = 0
                    Disposition = 'RetirementRequired'
                    ReceiptFallback = $false
                    CreateProduct = $true
                    ExistingInstallPresent = $true
                    BrokerWasPresentBefore = $false
                    ExpectedInvocations = 1
                    ExpectRetirement = $true
                    ExpectedProductPresent = $false
                }
                [pscustomobject]@{
                    Name = 'existing EverVigil protected broker'
                    Failures = 0
                    Disposition = 'NoChange'
                    ReceiptFallback = $false
                    CreateProduct = $true
                    ExistingInstallPresent = $true
                    BrokerWasPresentBefore = $true
                    ExpectedInvocations = 0
                    ExpectRetirement = $false
                    ExpectedProductPresent = $true
                }
            )) {
            if (Test-Path -LiteralPath $bootstrapCleanupRoot) {
                Remove-Item -LiteralPath $bootstrapCleanupRoot -Recurse -Force
            }
            if ($bootstrapCleanupScenario.CreateProduct) {
                New-Item -ItemType Directory -Path $bootstrapCleanupRoot -Force |
                    Out-Null
                [IO.File]::WriteAllText(
                    $script:mockBootstrapCleanupPaths.CanonicalPath,
                    'canonical fixture',
                    [Text.UTF8Encoding]::new($false))
                if ($bootstrapCleanupScenario.ReceiptFallback) {
                    [IO.File]::WriteAllText(
                        $script:mockBootstrapCleanupPaths.RetirementReceiptPath,
                        'durable receipt fixture',
                        [Text.UTF8Encoding]::new($false))
                }
            }
            $bootstrapCleanupState = New-TransactionState `
                -InstallRoot $atomicInstallRoot `
                -PreviousInstallRoot $atomicInstallRoot `
                -BackupRoot "$atomicInstallRoot.backup-$transactionId" `
                -PreviousBackupRoot "$atomicInstallRoot.relocated-$transactionId" `
                -RecoveryRoot (Join-Path `
                    $testLocalAppData `
                    "EverVigil\install-transactions\$transactionId") `
                -DestinationBackupPlanned $false `
                -PreviousBackupPlanned $false `
                -DestinationOwnedInstallPresent $false `
                -InstallRootChanged $false `
                -ExistingInstallPresent:$bootstrapCleanupScenario.ExistingInstallPresent `
                -Status rolledBack `
                -CurrentTransaction
            $bootstrapCleanupState['protectedBrokerWasPresentBefore'] =
                [bool]$bootstrapCleanupScenario.BrokerWasPresentBefore
            $bootstrapCleanupState['protectedBrokerCleanupAuthorized'] = $true
            $bootstrapCleanupState['protectedBrokerReady'] = $false
            [IO.File]::WriteAllText(
                $transactionPath,
                (($bootstrapCleanupState | ConvertTo-Json -Depth 6) + "`n"),
                [Text.UTF8Encoding]::new($false))
            $script:mockBootstrapInvocationCount = 0
            $script:mockBootstrapTransactionIds =
                [Collections.Generic.List[string]]::new()
            $script:mockBootstrapFailuresRemaining =
                [int]$bootstrapCleanupScenario.Failures
            $script:mockBootstrapDisposition =
                [string]$bootstrapCleanupScenario.Disposition
            $script:mockBootstrapRetirementCompleted = $false
            $cleanupMutex = New-EverVigilSystemTransactionMutex
            $cleanupMutexTaken = $false
            try {
                try {
                    $cleanupMutexTaken = $cleanupMutex.WaitOne(
                        [TimeSpan]::FromSeconds(10))
                } catch [Threading.AbandonedMutexException] {
                    $cleanupMutexTaken = $true
                }
                if (-not $cleanupMutexTaken) {
                    throw 'The bootstrap-cleanup fixture could not acquire the system mutex.'
                }
                $script:InstallTransactionMutex = $cleanupMutex
                $script:InstallTransactionMutexTaken = $true
                Invoke-InitialInstallProtectedBrokerCleanup `
                    -State ([pscustomobject]$bootstrapCleanupState)
            } finally {
                if ($script:InstallTransactionMutexTaken) {
                    $cleanupMutex.ReleaseMutex()
                }
                $script:InstallTransactionMutexTaken = $false
                $script:InstallTransactionMutex = $null
                $cleanupMutex.Dispose()
            }
            if ($script:mockBootstrapInvocationCount -ne
                    $bootstrapCleanupScenario.ExpectedInvocations -or
                @($script:mockBootstrapTransactionIds | Where-Object {
                        $_ -cne $cleanupTransactionId -or
                        $_ -ceq $transactionId
                    }).Count -gt 0 -or
                $script:mockBootstrapRetirementCompleted -ne
                    $bootstrapCleanupScenario.ExpectRetirement -or
                [bool](Test-Path -LiteralPath $bootstrapCleanupRoot) -ne
                    [bool]$bootstrapCleanupScenario.ExpectedProductPresent) {
                throw "Initial protected broker cleanup did not converge for $($bootstrapCleanupScenario.Name)."
            }
            Remove-Item -LiteralPath $transactionPath -Force
        }

        foreach ($invalidCleanupIdentity in @(
                $null
                $transactionId
                'NOT-A-GUID')) {
            if (Test-Path -LiteralPath $bootstrapCleanupRoot) {
                Remove-Item -LiteralPath $bootstrapCleanupRoot -Recurse -Force
            }
            New-Item -ItemType Directory -Path $bootstrapCleanupRoot -Force |
                Out-Null
            [IO.File]::WriteAllText(
                $script:mockBootstrapCleanupPaths.CanonicalPath,
                'canonical fixture',
                [Text.UTF8Encoding]::new($false))
            $invalidCleanupState = New-TransactionState `
                -InstallRoot $atomicInstallRoot `
                -PreviousInstallRoot $atomicInstallRoot `
                -BackupRoot "$atomicInstallRoot.backup-$transactionId" `
                -PreviousBackupRoot "$atomicInstallRoot.relocated-$transactionId" `
                -RecoveryRoot (Join-Path `
                    $testLocalAppData `
                    "EverVigil\install-transactions\$transactionId") `
                -DestinationBackupPlanned $false `
                -PreviousBackupPlanned $false `
                -DestinationOwnedInstallPresent $false `
                -InstallRootChanged $false `
                -ExistingInstallPresent $false `
                -Status rolledBack `
                -CurrentTransaction
            $invalidCleanupState['protectedBrokerCleanupAuthorized'] = $true
            $invalidCleanupState['protectedBrokerReady'] = $false
            if ($null -eq $invalidCleanupIdentity) {
                $invalidCleanupState.Remove('cleanupTransactionId')
            } else {
                $invalidCleanupState['cleanupTransactionId'] =
                    $invalidCleanupIdentity
            }
            [IO.File]::WriteAllText(
                $transactionPath,
                (($invalidCleanupState | ConvertTo-Json -Depth 6) + "`n"),
                [Text.UTF8Encoding]::new($false))
            $script:mockBootstrapInvocationCount = 0
            $script:mockBootstrapTransactionIds =
                [Collections.Generic.List[string]]::new()
            $cleanupMutex = New-EverVigilSystemTransactionMutex
            $cleanupMutexTaken = $false
            $invalidCleanupRejected = $false
            try {
                try {
                    $cleanupMutexTaken = $cleanupMutex.WaitOne(
                        [TimeSpan]::FromSeconds(10))
                } catch [Threading.AbandonedMutexException] {
                    $cleanupMutexTaken = $true
                }
                if (-not $cleanupMutexTaken) {
                    throw 'The invalid cleanup-identity fixture could not acquire the system mutex.'
                }
                $script:InstallTransactionMutex = $cleanupMutex
                $script:InstallTransactionMutexTaken = $true
                try {
                    Invoke-InitialInstallProtectedBrokerCleanup `
                        -State ([pscustomobject]$invalidCleanupState)
                } catch {
                    $invalidCleanupRejected =
                        $_.Exception.Message -match
                            'cleanup transaction identity|cleanup transaction identifier'
                }
            } finally {
                if ($script:InstallTransactionMutexTaken) {
                    $cleanupMutex.ReleaseMutex()
                }
                $script:InstallTransactionMutexTaken = $false
                $script:InstallTransactionMutex = $null
                $cleanupMutex.Dispose()
            }
            if (-not $invalidCleanupRejected -or
                $script:mockBootstrapInvocationCount -ne 0 -or
                -not (Test-Path `
                    -LiteralPath $script:mockBootstrapCleanupPaths.CanonicalPath `
                    -PathType Leaf)) {
                throw "Initial protected broker cleanup did not fail closed for invalid identity '$invalidCleanupIdentity'."
            }
            Remove-Item -LiteralPath $transactionPath -Force
        }
    } finally {
        Set-Item `
            -LiteralPath Function:\Invoke-EverVigilSystemBroker `
            -Value $originalBrokerInvoker
        Set-Item `
            -LiteralPath Function:\Get-EverVigilProtectedBrokerRetirementPaths `
            -Value $originalRetirementPaths
        Set-Item `
            -LiteralPath Function:\Complete-EverVigilProtectedBrokerRetirementFromReceipt `
            -Value $originalRetirementCompletion
        if (Test-Path -LiteralPath $bootstrapCleanupRoot) {
            Remove-Item -LiteralPath $bootstrapCleanupRoot -Recurse -Force
        }
        Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue
    }
    & {
        $script:processPathReadCount = 0
        $script:processProbePath = Join-Path `
            $uninstallGuardRoot `
            'EverVigil.exe'
        $processProbe = [pscustomobject]@{ Id = 4241 }
        $pathGetter = {
            $script:processPathReadCount++
            if ($script:processPathReadCount -eq 1) {
                return $script:processProbePath
            }
            return $null
        }
        $processProbe | Add-Member -MemberType ScriptProperty -Name Path -Value $pathGetter
        function Get-Process {
            [CmdletBinding()]
            param([string[]]$Name)

            return @($processProbe)
        }
        $matchedProcesses = @(
            Get-EverVigilProcessesAtRoot -Root $uninstallGuardRoot)
        if ($matchedProcesses.Count -ne 1 -or $script:processPathReadCount -ne 1) {
            throw 'Supervisor process matching reread a process path during an exit race.'
        }

        $script:insideClassificationPathReadCount = 0
        $insideProbe = [pscustomobject]@{ Id = 4242 }
        $insideProbe | Add-Member -MemberType ScriptProperty -Name Path -Value {
            $script:insideClassificationPathReadCount++
            return $script:processProbePath
        }
        $outsideProbe = [pscustomobject]@{
            Id = 4243
            Path = Join-Path $testRoot 'relocated\EverVigil.exe'
        }
        $locations = @(Get-EverVigilProcessLocations `
                -Root $uninstallGuardRoot `
                -Process @($insideProbe, $outsideProbe))
        $insideLocation = @($locations | Where-Object Id -eq 4242)
        $outsideLocation = @($locations | Where-Object Id -eq 4243)
        if ($locations.Count -ne 2 -or
            $insideLocation.Count -ne 1 -or
            -not $insideLocation[0].AtInstallRoot -or
            $outsideLocation.Count -ne 1 -or
            $outsideLocation[0].AtInstallRoot -or
            $script:insideClassificationPathReadCount -ne 1) {
            throw 'Uninstall process classification did not reject a relocated supervisor safely.'
        }
    }

    for ($attempt = 1; $attempt -le 64; $attempt++) {
        $fastExitCode = Invoke-EverVigilBoundedProcess `
            -FilePath $env:ComSpec `
            -ArgumentList @('/d', '/c', 'exit', '0') `
            -WorkingDirectory $env:SystemRoot `
            -TimeoutSeconds 5
        if ($fastExitCode -ne 0) {
            throw "Immediate process command returned exit code $fastExitCode."
        }
    }

    $boundedFailureCaptured = $false
    try {
        [void](Invoke-EverVigilBoundedProcess `
                -FilePath $env:ComSpec `
                -ArgumentList @(
                    '/d',
                    '/c',
                    'echo evervigil-bounded-error 1>&2 & exit /b 9') `
                -WorkingDirectory $env:SystemRoot `
                -TimeoutSeconds 5)
    } catch {
        $boundedFailureCaptured =
            $_.Exception.Message.Contains(
                'failed with exit code 9: evervigil-bounded-error',
                [StringComparison]::Ordinal)
    }
    if (-not $boundedFailureCaptured) {
        throw 'Bounded process stderr was not surfaced to the installer.'
    }

    $mutexName = "Local\EverVigil.Transaction.Tests-$([guid]::NewGuid().ToString('N'))"
    $mutexSecurity = [Security.AccessControl.MutexSecurity]::new()
    $mutexSecurity.SetAccessRuleProtection($true, $false)
    $authenticatedUsers = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::AuthenticatedUserSid,
        $null)
    $mutexSecurity.AddAccessRule([Security.AccessControl.MutexAccessRule]::new(
            $authenticatedUsers,
            [Security.AccessControl.MutexRights]'Synchronize, Modify',
            [Security.AccessControl.AccessControlType]::Allow))
    foreach ($identity in @(
            [Security.Principal.SecurityIdentifier]::new(
                [Security.Principal.WellKnownSidType]::LocalSystemSid,
                $null)
            [Security.Principal.SecurityIdentifier]::new(
                [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
                $null)
        )) {
        $mutexSecurity.AddAccessRule([Security.AccessControl.MutexAccessRule]::new(
                $identity,
                [Security.AccessControl.MutexRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow))
    }
    $createdNew = $false
    $existingMutex = [Threading.MutexAcl]::Create(
        $false,
        $mutexName,
        [ref]$createdNew,
        $mutexSecurity)
    try {
        $reopenedMutex = New-EverVigilSystemTransactionMutex -Name $mutexName
        try {
            if (-not $reopenedMutex.WaitOne([TimeSpan]::Zero)) {
                throw 'The PowerShell transaction mutex could not be acquired.'
            }
            $reopenedMutex.ReleaseMutex()
        } finally {
            $reopenedMutex.Dispose()
        }
    } finally {
        $existingMutex.Dispose()
    }

    $script:taskCleanupAttempts = 0
    function Remove-EverVigilInteractiveTasksForTransaction {
        param(
            [string]$TransactionId,
            [string]$OwnerSid,
            [string[]]$AllowedExecutablePath,
            [switch]$StopInstances
        )

        $script:taskCleanupAttempts++
        if ($script:taskCleanupAttempts -lt 3) {
            throw 'simulated transient Task Scheduler cleanup failure'
        }
    }
    $retryState = [pscustomobject]@{
        transactionId = $transactionId
        ownerSid = Get-EverVigilOwnerSid
        installRoot = $uninstallGuardRoot
        previousInstallRoot = $uninstallGuardRoot
    }
    Remove-TransactionInteractiveTasks -State $retryState
    if ($script:taskCleanupAttempts -ne 3) {
        throw 'Temporary interactive-task cleanup did not retry transient failures.'
    }

    $runtimeRetryRoot = Join-Path $testRoot 'runtime-retry-install'
    New-KnownInstallLayout -Root $runtimeRetryRoot
    Write-EverVigilInstallOwnership -Path $runtimeRetryRoot
    $script:runtimeLaunchAttempts = 0
    $script:runtimeSurvivalChecks = 0
    function Start-EverVigilInteractiveProcess {
        param(
            [string]$TransactionId,
            [string]$OwnerSid,
            [string]$ExecutablePath,
            [string[]]$Arguments,
            [string]$WorkingDirectory,
            [string]$Purpose
        )

        $script:runtimeLaunchAttempts++
        if ($script:runtimeLaunchAttempts -lt 3) {
            throw 'simulated transient Task Scheduler launch failure'
        }
    }
    function Get-EverVigilProcessesAtRoot {
        param([string]$Root)

        $script:runtimeSurvivalChecks++
        return @([pscustomobject]@{ Id = 4242; Path = $Root })
    }
    $runtimeRetryState = [pscustomobject]@{
        existingInstallPresent = $true
        installRootChanged = $false
        installRoot = $runtimeRetryRoot
        previousInstallRoot = $runtimeRetryRoot
        startupWasRegistered = $false
        existingSupervisorWasRunning = $true
        transactionId = $transactionId
        ownerSid = Get-EverVigilOwnerSid
    }
    Restore-PreviousRuntime -State $runtimeRetryState
    if ($script:runtimeLaunchAttempts -ne 3 -or $script:runtimeSurvivalChecks -lt 2) {
        throw 'Restored-runtime launch did not retry failures and verify stable process survival.'
    }
    Remove-Item -LiteralPath $runtimeRetryRoot -Recurse -Force

    'Install transaction tests passed: TEMP-independent commit, strict JSON types, distinct durable broker-cleanup identity and pre-bootstrap cleanup intent, schema-3 fail-closed recovery, durable deletion recovery, two-phase write-ahead recovery, resumable cleanup, relocation rollback, exact SHA-256 data restoration, exit-race-safe process matching and command waiting, stable task retries, exact uninstall-support manifest, and uninstall refusal.'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:TEMP = $originalTemp
    if ($startupWasPresentBeforeTest) {
        if (-not (Test-Path -LiteralPath $startupBackupPath -PathType Leaf)) {
            throw 'The pre-test startup shortcut backup is missing.'
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $startupShortcutPath) -Force |
            Out-Null
        Copy-Item -LiteralPath $startupBackupPath -Destination $startupShortcutPath -Force
        $restoredStartupDigest = (Get-FileHash `
                -LiteralPath $startupShortcutPath `
                -Algorithm SHA256).Hash
        if ($restoredStartupDigest -ne $startupDigestBeforeTest) {
            throw 'The pre-test startup shortcut was not restored exactly.'
        }
    } else {
        Remove-Item -LiteralPath $startupShortcutPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $expectedParent = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'artifacts'))
        if ($resolvedTestRoot.StartsWith("$expectedParent\", [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
