[CmdletBinding()]
param(
    [ValidateSet('Seal', 'Commit', 'Rollback', 'Recover')]
    [string]$Action,

    [string]$TransactionPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$legacyCompatibilityPath = Join-Path $PSScriptRoot 'LegacyCompatibility.generated.ps1'
if (-not (Test-Path -LiteralPath $legacyCompatibilityPath -PathType Leaf)) {
    throw "Required legacy-compatibility constants not found: $legacyCompatibilityPath"
}
. $legacyCompatibilityPath
$script:InstallTransactionAppId = $script:LegacyCompatibilityApplicationAppId

$installPathResolver = Join-Path $PSScriptRoot 'Resolve-SafeInstallRoot.ps1'
$interactiveTaskHelper = Join-Path $PSScriptRoot 'Invoke-InteractiveUserTask.ps1'
$installTransactionDataHelper = Join-Path $PSScriptRoot 'InstallTransactionData.ps1'
if (-not (Test-Path -LiteralPath $installPathResolver -PathType Leaf)) {
    throw "Required install-path validator not found: $installPathResolver"
}
if (-not (Test-Path -LiteralPath $interactiveTaskHelper -PathType Leaf)) {
    throw "Required interactive-task helper not found: $interactiveTaskHelper"
}
if (-not (Test-Path -LiteralPath $installTransactionDataHelper -PathType Leaf)) {
    throw "Required install-transaction data helper not found: $installTransactionDataHelper"
}
. $installPathResolver
. $interactiveTaskHelper
. $installTransactionDataHelper
$script:InstallTransactionDataRoot = Get-EverVigilActiveDataRoot
$script:InstallTransactionDefaultPath = Join-Path `
    $script:InstallTransactionDataRoot `
    $script:LegacyCompatibilityDataTransactionJournalFileName
$script:PendingSystemJournalPath = Join-Path `
    $script:InstallTransactionDataRoot `
    'pending-system-configuration.json'
$script:InstallTransactionMutex = $null
$script:InstallTransactionMutexTaken = $false
if ([string]::IsNullOrWhiteSpace($TransactionPath)) {
    $TransactionPath = $script:InstallTransactionDefaultPath
}

function Assert-InstallTransactionPath {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    $expected = [IO.Path]::GetFullPath($script:InstallTransactionDefaultPath)
    if (-not [string]::Equals($resolved, $expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The install transaction path is not the reserved path: $resolved"
    }
    return $resolved
}

function Assert-NoForeignPendingSystemJournal {
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [switch]$AllowOwnedAtomicTemporary
    )

    $recognizedRoots = @(
        (Join-Path $env:LOCALAPPDATA 'EverVigil')
        (Join-Path `
            $env:LOCALAPPDATA `
            $script:LegacyCompatibilityApplicationDataRootRelativeToLocalAppData)
    ) | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique
    foreach ($recognizedRoot in $recognizedRoots) {
        if (-not (Test-Path -LiteralPath $recognizedRoot -PathType Container)) {
            continue
        }
        foreach ($temporary in @(Get-ChildItem `
                -LiteralPath $recognizedRoot `
                -File `
                -Force `
                -ErrorAction Stop | Where-Object {
                    $_.Name -cmatch
                        '\A(?:pending-system-configuration|applied-system-configuration)\.json\.[0-9a-f]{32}\.tmp\z'
                })) {
            if (($temporary.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "A system journal temporary is a reparse point: $($temporary.FullName)"
            }
            $expectedSuffix = ".json.$(([guid]$TransactionId).ToString('N')).tmp"
            $ownedTemporary = $AllowOwnedAtomicTemporary -and
                [string]::Equals(
                    $recognizedRoot,
                    [IO.Path]::GetFullPath($script:InstallTransactionDataRoot),
                    [StringComparison]::OrdinalIgnoreCase) -and
                $temporary.Name.EndsWith(
                    $expectedSuffix,
                    [StringComparison]::Ordinal)
            if (-not $ownedTemporary) {
                throw "A possible atomic system journal must be recovered first: $($temporary.FullName)"
            }
            if ($temporary.Length -gt 1048576 -or
                -not (Test-EverVigilAtomicJournalFileAcl -Path $temporary.FullName)) {
                throw "An owned system journal temporary has an invalid identity: $($temporary.FullName)"
            }
        }
        $candidate = Join-Path $recognizedRoot 'pending-system-configuration.json'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        if (-not [string]::Equals(
                [IO.Path]::GetFullPath($candidate),
                [IO.Path]::GetFullPath($script:PendingSystemJournalPath),
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "A pending system journal exists in another recognized data root: $candidate"
        }
        try {
            $pending = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
        } catch {
            throw "The pending system journal is invalid JSON: $($_.Exception.Message)"
        }
        if (-not [string]::Equals(
                ([guid][string]$pending.transactionId).ToString('N'),
                ([guid]$TransactionId).ToString('N'),
                [StringComparison]::OrdinalIgnoreCase) -or
            [string]$pending.initiator -cne 'Installer') {
            throw "The pending system journal does not belong to this install transaction: $candidate"
        }
    }
}

function Get-OwnedInstallerSystemJournalTemporaries {
    param([Parameter(Mandatory)][string]$TransactionId)

    if (-not $script:InstallTransactionMutexTaken) {
        throw 'The install transaction mutex is required before inspecting system journal temporaries.'
    }
    Assert-NoForeignPendingSystemJournal `
        -TransactionId $TransactionId `
        -AllowOwnedAtomicTemporary
    $normalizedTransactionId = ([guid]$TransactionId).ToString('N')
    if (-not (Test-Path `
            -LiteralPath $script:InstallTransactionDataRoot `
            -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem `
            -LiteralPath $script:InstallTransactionDataRoot `
            -File `
            -Force `
            -ErrorAction Stop | Where-Object {
                $_.Name -cmatch
                    ('\A(?:pending-system-configuration|applied-system-configuration)\.json\.' +
                        [regex]::Escape($normalizedTransactionId) + '\.tmp\z')
            })
}

function Remove-OwnedInstallerSystemJournalTemporariesAfterRollback {
    param([Parameter(Mandatory)][string]$TransactionId)

    $temporaries = @(Get-OwnedInstallerSystemJournalTemporaries `
            -TransactionId $TransactionId)
    foreach ($temporary in $temporaries) {
        Remove-Item -LiteralPath $temporary.FullName -Force -ErrorAction Stop
    }
}

function Write-EverVigilInstallTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    $resolvedPath = Assert-InstallTransactionPath -Path $Path
    $parent = Split-Path -Parent $resolvedPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporaryPath = "$resolvedPath.new-$([guid]::NewGuid().ToString('N'))"
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
        # The temporary already has the exact protected ACL and is moved on
        # the same volume. Atomic replacement is deliberately the final
        # fallible operation: once the new stable journal exists, callers must
        # never observe an exception and roll back across its durable phase.
        [IO.File]::Move($temporaryPath, $resolvedPath, $true)
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-RequiredTransactionProperty {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "The install transaction is missing '$Name'."
    }
    return $property.Value
}

function Read-EverVigilInstallTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowAtomicTemporary
    )

    $stablePath = Assert-InstallTransactionPath `
        -Path $script:InstallTransactionDefaultPath
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $isAtomicTemporary = -not [string]::Equals(
        $resolvedPath,
        $stablePath,
        [StringComparison]::OrdinalIgnoreCase)
    if ($isAtomicTemporary) {
        $expectedTemporaryPattern = '\A' +
            [regex]::Escape([IO.Path]::GetFileName($stablePath)) +
            '\.new-[0-9a-f]{32}\z'
        if (-not $AllowAtomicTemporary -or
            -not [string]::Equals(
                [IO.Path]::GetDirectoryName($resolvedPath),
                [IO.Path]::GetDirectoryName($stablePath),
                [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedPath) -cnotmatch
                $expectedTemporaryPattern) {
            throw "The install transaction path is not a reserved atomic path: $resolvedPath"
        }
    }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return $null
    }
    $item = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 1 -or
        $item.Length -gt 1048576 -or
        ($isAtomicTemporary -and
            -not (Test-EverVigilAtomicJournalFileAcl -Path $item.FullName))) {
        throw "The install transaction file identity is invalid at '$resolvedPath'."
    }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString(
            [IO.File]::ReadAllBytes($resolvedPath))
        $jsonDocument = [Text.Json.JsonDocument]::Parse($json)
        try {
            if ($jsonDocument.RootElement.ValueKind -ne
                [Text.Json.JsonValueKind]::Object) {
                throw 'The install transaction root must be a JSON object.'
            }
            $elements = [Collections.Generic.Stack[Text.Json.JsonElement]]::new()
            $elements.Push($jsonDocument.RootElement)
            while ($elements.Count -gt 0) {
                $element = $elements.Pop()
                if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                    $names = [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::Ordinal)
                    foreach ($property in $element.EnumerateObject()) {
                        if (-not $names.Add($property.Name)) {
                            throw "The install transaction contains a duplicate JSON property: $($property.Name)"
                        }
                        $elements.Push($property.Value)
                    }
                } elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                    foreach ($child in $element.EnumerateArray()) {
                        $elements.Push($child)
                    }
                }
            }
        } finally {
            $jsonDocument.Dispose()
        }
        $state = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "The install transaction is invalid at '$resolvedPath': $($_.Exception.Message)"
    }

    $requiredProperties = @(
            'schemaVersion'
            'appId'
            'ownerSid'
            'status'
            'deletionIntent'
            'transactionId'
            'installRoot'
            'previousInstallRoot'
            'publishRoot'
            'stagingRoot'
            'backupRoot'
            'previousBackupRoot'
            'recoveryRoot'
            'rollbackTaskXml'
            'systemResultPath'
            'installRootChanged'
            'destinationBackupPlanned'
            'previousBackupPlanned'
            'destinationOwnedInstallPresent'
            'existingInstallPresent'
            'migrationApplied'
            'runtimeConfigurationReady'
            'dataRootExisted'
            'settingsWasPresent'
            'tokenWasPresent'
            'applicationDataSnapshotReady'
            'applicationDataSnapshots'
            'settingsQuarantineFiles'
            'tokenQuarantineFiles'
            'systemConfigurationRequiredWasPresent'
            'diagnosticLoggingWasPresent'
            'logsRootWasPresent'
            'transactionsRootWasPresent'
            'systemConfigurationWasRequired'
            'appliedSystemConfigurationWasPresent'
            'legacyCredentialFound'
            'legacyTokenPath'
            'startupWasRegistered'
            'existingSupervisorWasRunning'
            'publicPort'
            'backendPort'
            'tailscalePath'
        )
    $optionalProperties = @(
        'legacyCleanupAuthorized'
        'previousOwnedInstallPresent'
        'bridgeHostWasPresent'
        'migrateV121SystemState'
        'protectedBrokerWasPresentBefore'
        'protectedBrokerCleanupAuthorized'
        'protectedBrokerReady'
        'cleanupTransactionId'
        'externalArtifactSnapshotReady'
        'externalArtifactSnapshots'
        'uninstallRegistryWasPresent'
        'uninstallRegistrySnapshotReady'
        'uninstallRegistrySnapshotSha256'
        'uninstallRegistryMutationMarkerSha256'
        'externalCommitPhase'
        'targetVersion'
    )
    $stateProperties = @($state.PSObject.Properties)
    if (@($requiredProperties | Where-Object {
                $null -eq $state.PSObject.Properties[$_]
            }).Count -gt 0 -or
        @($stateProperties.Name | Where-Object {
                $_ -cnotin ($requiredProperties + $optionalProperties)
            }).Count -gt 0) {
        throw 'The install transaction does not have the exact recognized schema.'
    }
    foreach ($requiredProperty in $requiredProperties) {
        [void](Get-RequiredTransactionProperty -State $state -Name $requiredProperty)
    }

    $stringProperties = @(
        'appId', 'ownerSid', 'status', 'deletionIntent', 'transactionId',
        'installRoot', 'previousInstallRoot', 'publishRoot', 'stagingRoot',
        'backupRoot', 'previousBackupRoot', 'recoveryRoot', 'rollbackTaskXml',
        'systemResultPath', 'legacyTokenPath', 'tailscalePath')
    $booleanProperties = @(
        'installRootChanged', 'destinationBackupPlanned',
        'previousBackupPlanned', 'destinationOwnedInstallPresent',
        'existingInstallPresent', 'migrationApplied',
        'runtimeConfigurationReady', 'dataRootExisted', 'settingsWasPresent',
        'tokenWasPresent', 'applicationDataSnapshotReady',
        'systemConfigurationRequiredWasPresent', 'diagnosticLoggingWasPresent',
        'logsRootWasPresent', 'transactionsRootWasPresent',
        'systemConfigurationWasRequired', 'appliedSystemConfigurationWasPresent',
        'legacyCredentialFound', 'startupWasRegistered',
        'existingSupervisorWasRunning')
    $arrayProperties = @(
        'applicationDataSnapshots',
        'settingsQuarantineFiles',
        'tokenQuarantineFiles')
    if (@($stringProperties | Where-Object {
                $state.PSObject.Properties[$_].Value -isnot [string]
            }).Count -gt 0 -or
        @($booleanProperties | Where-Object {
                $state.PSObject.Properties[$_].Value -isnot [bool]
            }).Count -gt 0 -or
        @($arrayProperties | Where-Object {
                $state.PSObject.Properties[$_].Value -isnot [Array]
            }).Count -gt 0 -or
        ($state.PSObject.Properties['schemaVersion'].Value -isnot [int] -and
            $state.PSObject.Properties['schemaVersion'].Value -isnot [long]) -or
        ($state.PSObject.Properties['publicPort'].Value -isnot [int] -and
            $state.PSObject.Properties['publicPort'].Value -isnot [long]) -or
        ($state.PSObject.Properties['backendPort'].Value -isnot [int] -and
            $state.PSObject.Properties['backendPort'].Value -isnot [long])) {
        throw 'The install transaction contains a property with an invalid JSON type.'
    }
    foreach ($optionalBooleanProperty in @(
            'previousOwnedInstallPresent'
            'bridgeHostWasPresent'
            'migrateV121SystemState'
            'protectedBrokerWasPresentBefore'
            'protectedBrokerCleanupAuthorized'
            'protectedBrokerReady')) {
        $optionalProperty = $state.PSObject.Properties[$optionalBooleanProperty]
        if ($null -ne $optionalProperty -and
            $optionalProperty.Value -isnot [bool]) {
            throw "The install transaction property '$optionalBooleanProperty' must be a JSON boolean."
        }
    }
    $externalSnapshotProperties = @(
        'externalArtifactSnapshotReady'
        'externalArtifactSnapshots'
        'uninstallRegistryWasPresent'
        'uninstallRegistrySnapshotReady'
        'uninstallRegistrySnapshotSha256'
        'uninstallRegistryMutationMarkerSha256'
        'externalCommitPhase')
    $externalSnapshotPropertyCount = @($externalSnapshotProperties | Where-Object {
            $null -ne $state.PSObject.Properties[$_]
        }).Count
    if ($externalSnapshotPropertyCount -notin @(0, $externalSnapshotProperties.Count)) {
        throw 'The external artifact snapshot state is incomplete.'
    }
    if ($externalSnapshotPropertyCount -eq $externalSnapshotProperties.Count) {
        foreach ($booleanName in @(
                'externalArtifactSnapshotReady'
                'uninstallRegistryWasPresent'
                'uninstallRegistrySnapshotReady')) {
            if ($state.PSObject.Properties[$booleanName].Value -isnot [bool]) {
                throw "The install transaction property '$booleanName' must be a JSON boolean."
            }
        }
        if ($state.externalArtifactSnapshots -isnot [Array] -or
            $state.uninstallRegistrySnapshotSha256 -isnot [string] -or
            $state.uninstallRegistryMutationMarkerSha256 -isnot [string] -or
            $state.externalCommitPhase -isnot [string] -or
            [string]$state.externalCommitPhase -notin @(
                'None', 'SnapshotReady', 'SystemCommitPrepared',
                'SystemCommitted', 'CleanupComplete')) {
            throw 'The external artifact snapshot state contains an invalid JSON type or phase.'
        }
        foreach ($snapshot in @($state.externalArtifactSnapshots)) {
            $snapshotProperties = @($snapshot.PSObject.Properties)
            if ($snapshotProperties.Count -ne 4 -or
                @($snapshotProperties.Name | Where-Object {
                        $_ -cnotin @('role', 'wasPresent', 'length', 'sha256')
                    }).Count -gt 0 -or
                $snapshot.role -isnot [string] -or
                $snapshot.wasPresent -isnot [bool] -or
                ($snapshot.length -isnot [int] -and
                    $snapshot.length -isnot [long]) -or
                $snapshot.sha256 -isnot [string]) {
                throw 'The install transaction contains an invalid external artifact snapshot schema.'
            }
        }
    } elseif ($null -ne $state.PSObject.Properties['cleanupTransactionId']) {
        throw 'A current install transaction is missing its external artifact recovery state.'
    }
    $targetVersionProperty = $state.PSObject.Properties['targetVersion']
    if ($null -ne $targetVersionProperty -and
        ($targetVersionProperty.Value -isnot [string] -or
            [string]$targetVersionProperty.Value -cnotmatch
                '\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\z')) {
        throw 'The install transaction target version is invalid.'
    }
    if ($null -ne $state.PSObject.Properties['cleanupTransactionId'] -and
        $null -eq $targetVersionProperty) {
        throw 'A current install transaction is missing its target version.'
    }
    foreach ($snapshot in @($state.applicationDataSnapshots)) {
        $snapshotProperties = @($snapshot.PSObject.Properties)
        if ($snapshotProperties.Count -ne 2 -or
            @($snapshotProperties.Name | Where-Object {
                    $_ -cnotin @('name', 'sha256')
                }).Count -gt 0 -or
            $snapshot.PSObject.Properties['name'].Value -isnot [string] -or
            $snapshot.PSObject.Properties['sha256'].Value -isnot [string]) {
            throw 'The install transaction contains an invalid application-data snapshot schema.'
        }
    }
    foreach ($arrayProperty in @('settingsQuarantineFiles', 'tokenQuarantineFiles')) {
        if (@($state.$arrayProperty | Where-Object { $_ -isnot [string] }).Count -gt 0) {
            throw "The install transaction array '$arrayProperty' must contain only strings."
        }
    }

    $ownerSid = Get-EverVigilOwnerSid
    if ([string]$state.schemaVersion -cne
        $script:LegacyCompatibilityDataTransactionSchemaVersion -or
        -not [string]::Equals(
            [string]$state.appId,
            $script:InstallTransactionAppId,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [string]$state.ownerSid,
            $ownerSid,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The install transaction does not belong to this application and user.'
    }
    if ([string]$state.status -notin @(
            'staging',
            'pending',
            'readyToCommit',
            'committed',
            'rollingBack',
            'rolledBack'
        )) {
        throw "The install transaction status is invalid: $($state.status)"
    }
    if ([string]$state.transactionId -cnotmatch '\A[0-9a-f]{32}\z') {
        throw "The install transaction identifier is invalid: $($state.transactionId)"
    }
    $cleanupTransactionIdProperty =
        $state.PSObject.Properties['cleanupTransactionId']
    if ($null -ne $cleanupTransactionIdProperty -and
        ($cleanupTransactionIdProperty.Value -isnot [string] -or
            [string]$cleanupTransactionIdProperty.Value -cnotmatch
                '\A[0-9a-f]{32}\z' -or
            [string]::Equals(
                [string]$cleanupTransactionIdProperty.Value,
                [string]$state.transactionId,
                [StringComparison]::Ordinal))) {
        throw 'The install cleanup transaction identifier is malformed or reuses the primary transaction identifier.'
    }
    $protectedBrokerReadyProperty =
        $state.PSObject.Properties['protectedBrokerReady']
    $protectedBrokerCleanupAuthorizedProperty =
        $state.PSObject.Properties['protectedBrokerCleanupAuthorized']
    if ((($null -ne $protectedBrokerReadyProperty -and
                $protectedBrokerReadyProperty.Value -eq $true) -or
            ($null -ne $protectedBrokerCleanupAuthorizedProperty -and
                $protectedBrokerCleanupAuthorizedProperty.Value -eq $true)) -and
        $null -eq $cleanupTransactionIdProperty) {
        throw 'A protected broker transaction requires a separate cleanup transaction identifier.'
    }
    $legacyCleanupProperty = $state.PSObject.Properties['legacyCleanupAuthorized']
    if ($null -ne $legacyCleanupProperty -and
        $legacyCleanupProperty.Value -isnot [bool]) {
        throw 'The legacy cleanup authorization must be a JSON boolean.'
    }

    $state.installRoot = Resolve-SafeInstallRoot `
        -Path ([string]$state.installRoot) `
        -AllowCurrentTempTree
    $state.previousInstallRoot = Resolve-SafeInstallRoot `
        -Path ([string]$state.previousInstallRoot) `
        -AllowCurrentTempTree
    $expectedPublishRoot = Join-Path `
        $script:InstallTransactionDataRoot `
        "$($script:LegacyCompatibilityDataInstallerPublishDirectoryPrefix)$($state.transactionId)"
    $expectedStagingRoot = "$($state.installRoot).staging-$($state.transactionId)"
    $expectedBackupRoot = "$($state.installRoot).backup-$($state.transactionId)"
    $expectedPreviousBackupRoot = "$($state.previousInstallRoot).relocated-$($state.transactionId)"
    $expectedRecoveryRoot = Join-Path `
        $script:InstallTransactionDataRoot `
        "$($script:LegacyCompatibilityDataTransactionRecoveryDirectoryName)\$($state.transactionId)"
    foreach ($pathCheck in @(
            [pscustomobject]@{ Actual = [string]$state.publishRoot; Expected = $expectedPublishRoot; Name = 'temporary publish root' }
            [pscustomobject]@{ Actual = [string]$state.stagingRoot; Expected = $expectedStagingRoot; Name = 'staging root' }
            [pscustomobject]@{ Actual = [string]$state.backupRoot; Expected = $expectedBackupRoot; Name = 'destination backup' }
            [pscustomobject]@{ Actual = [string]$state.previousBackupRoot; Expected = $expectedPreviousBackupRoot; Name = 'previous backup' }
            [pscustomobject]@{ Actual = [string]$state.recoveryRoot; Expected = $expectedRecoveryRoot; Name = 'recovery root' }
            [pscustomobject]@{ Actual = [string]$state.rollbackTaskXml; Expected = (Join-Path $expectedRecoveryRoot 'legacy-task.xml'); Name = 'rollback task' }
            [pscustomobject]@{ Actual = [string]$state.systemResultPath; Expected = (Join-Path $expectedRecoveryRoot 'system.log'); Name = 'system log' }
        )) {
        $actual = [IO.Path]::GetFullPath($pathCheck.Actual)
        $expected = [IO.Path]::GetFullPath($pathCheck.Expected)
        if (-not [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The $($pathCheck.Name) path is invalid: $actual"
        }
    }
    if ([int]$state.publicPort -lt 1024 -or [int]$state.publicPort -gt 65535 -or
        [int]$state.backendPort -lt 1024 -or [int]$state.backendPort -gt 65535 -or
        [int]$state.publicPort -eq [int]$state.backendPort) {
        throw "The install transaction contains invalid ports: $($state.publicPort)/$($state.backendPort)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$state.tailscalePath) -or
        ([string]$state.tailscalePath).Contains('"') -or
        -not (Test-EverVigilPathFullyQualified -Path ([string]$state.tailscalePath))) {
        throw "The install transaction contains an invalid Tailscale path: $($state.tailscalePath)"
    }
    Assert-EverVigilQuarantineState -State $state
    $requireBackupFiles = [bool]$state.applicationDataSnapshotReady -and
        [string]$state.status -in @('pending', 'readyToCommit', 'rollingBack')
    Assert-EverVigilApplicationDataSnapshotState `
        -State $state `
        -RecoveryRoot $expectedRecoveryRoot `
        -Status ([string]$state.status) `
        -RequireBackupFiles:$requireBackupFiles
    if ($externalSnapshotPropertyCount -eq $externalSnapshotProperties.Count) {
        if ([bool]$state.externalArtifactSnapshotReady -ne
                [bool]$state.uninstallRegistrySnapshotReady -or
            ([bool]$state.externalArtifactSnapshotReady -and
                ([string]$state.uninstallRegistrySnapshotSha256 -cnotmatch
                    '\A[0-9a-f]{64}\z' -or
                    [string]$state.uninstallRegistryMutationMarkerSha256 -cnotmatch
                        '\A[0-9a-f]{64}\z')) -or
            (-not [bool]$state.externalArtifactSnapshotReady -and
                ([string]$state.uninstallRegistrySnapshotSha256 -cne '' -or
                    [string]$state.uninstallRegistryMutationMarkerSha256 -cne '' -or
                    [string]$state.externalCommitPhase -cne 'None'))) {
            throw 'The external artifact and uninstall registry snapshot markers are inconsistent.'
        }
        Assert-EverVigilExternalArtifactSnapshotState `
            -State $state `
            -RecoveryRoot $expectedRecoveryRoot `
            -RequireBackupFiles:([bool]$state.externalArtifactSnapshotReady -and
                [string]$state.externalCommitPhase -cne 'CleanupComplete')
        if ([bool]$state.uninstallRegistrySnapshotReady -and
            [string]$state.externalCommitPhase -cne 'CleanupComplete') {
            [void](Read-EverVigilUninstallRegistrySnapshot `
                    -RecoveryRoot $expectedRecoveryRoot `
                    -ExpectedSha256 ([string]$state.uninstallRegistrySnapshotSha256))
            Assert-EverVigilUninstallRegistryMutationMarker `
                -RecoveryRoot $expectedRecoveryRoot `
                -TransactionId ([string]$state.transactionId) `
                -ExpectedSha256 ([string]$state.uninstallRegistryMutationMarkerSha256)
        }
    }
    Assert-EverVigilTransactionDeletionIntent -State $state

    return $state
}

function Resolve-EverVigilInstallTransactionAtomicState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $script:InstallTransactionMutexTaken) {
        throw 'The install transaction mutex is required for atomic-journal recovery.'
    }
    $resolvedPath = Assert-InstallTransactionPath -Path $Path
    $parent = Split-Path -Parent $resolvedPath
    $prefix = "$(Split-Path -Leaf $resolvedPath).new-"
    $temporaryItems = @(if (Test-Path -LiteralPath $parent -PathType Container) {
            Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop |
                Where-Object {
                    $_.Name.StartsWith($prefix, [StringComparison]::Ordinal)
                }
        })

    $stableState = Read-EverVigilInstallTransaction -Path $resolvedPath
    $validatedTemporaries = [Collections.Generic.List[object]]::new()
    foreach ($temporaryItem in $temporaryItems) {
        $temporaryState = Read-EverVigilInstallTransaction `
            -Path $temporaryItem.FullName `
            -AllowAtomicTemporary
        if ($null -eq $temporaryState) {
            throw "An atomic install transaction disappeared during validation: $($temporaryItem.FullName)"
        }
        $validatedTemporaries.Add([pscustomobject]@{
                Path = [IO.Path]::GetFullPath($temporaryItem.FullName)
                State = $temporaryState
            })
    }

    if ($null -ne $stableState) {
        foreach ($temporary in $validatedTemporaries) {
            if (-not [string]::Equals(
                    [string]$temporary.State.transactionId,
                    [string]$stableState.transactionId,
                    [StringComparison]::Ordinal)) {
                throw 'An atomic install transaction does not match the stable transaction identity.'
            }
        }
        foreach ($temporary in $validatedTemporaries) {
            Remove-Item -LiteralPath $temporary.Path -Force -ErrorAction Stop
        }
        return $stableState
    }

    if ($validatedTemporaries.Count -eq 0) {
        return $null
    }
    if ($validatedTemporaries.Count -ne 1) {
        throw 'Multiple atomic install transactions exist without a stable journal; refusing ambiguous recovery.'
    }

    $authoritativeTemporary = $validatedTemporaries[0]
    # The validated protected temporary already carries the final ACL. Moving
    # it is the commit point and must be the last fallible operation.
    [IO.File]::Move($authoritativeTemporary.Path, $resolvedPath, $false)
    return Read-EverVigilInstallTransaction -Path $resolvedPath
}

function Test-EmptyDirectory {
    param([Parameter(Mandatory)][string]$Path)

    return (Test-Path -LiteralPath $Path -PathType Container) -and
        @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop).Count -eq 0
}

function Assert-VerifiedTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected,
        [ValidateSet(
            'OwnedInstall',
            'OwnedInstallBackup',
            'StagedInstall',
            'IncompleteStaging',
            'TemporaryPublish',
            'EmptyDirectory',
            'RecoveryDirectory')]
        [string]$Kind,
        [string]$OriginalInstallRoot,
        $State
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
    $resolvedIdentity = Resolve-EverVigilFinalFileSystemPath -Path $resolved
    $expectedIdentity = Resolve-EverVigilFinalFileSystemPath -Path $expectedFull
    if (-not [string]::Equals(
            $resolvedIdentity,
            $expectedIdentity,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected $Kind path: $resolved"
    }
    switch ($Kind) {
        'OwnedInstall' {
            Assert-OwnedInstallRoot -Path $resolved -AllowCurrentTempTree
        }
        'OwnedInstallBackup' {
            if ([string]::IsNullOrWhiteSpace($OriginalInstallRoot)) {
                throw 'Backup verification requires the original installation path.'
            }
            Assert-OwnedInstallBackup `
                -Path $resolved `
                -OriginalInstallRoot $OriginalInstallRoot `
                -AllowCurrentTempTree
        }
        'StagedInstall' {
            if (-not (Test-EverVigilKnownLayout `
                        -Path $resolved `
                        -AllowCurrentTempTree)) {
                throw "Refusing to remove an invalid staged installation: $resolved"
            }
        }
        { $_ -in @('IncompleteStaging', 'TemporaryPublish') } {
            $entries = @(
                Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
                Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
            )
            if (@($entries | Where-Object {
                        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                    }).Count -gt 0) {
                throw "Refusing to remove a generated tree containing a reparse point: $resolved"
            }
        }
        'EmptyDirectory' {
            if (-not (Test-EmptyDirectory -Path $resolved)) {
                throw "Refusing to remove a non-empty destination backup: $resolved"
            }
        }
        'RecoveryDirectory' {
            if ($null -eq $State) {
                throw 'Recovery-directory verification requires the install transaction state.'
            }
            $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if (-not $rootItem.PSIsContainer -or
                ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to remove a non-regular recovery directory: $Path"
            }
            $expectedTransactionId = ([guid][string]$State.transactionId).ToString('N')
            $trustedRecoveryOwners = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase)
            [void]$trustedRecoveryOwners.Add([string](Get-EverVigilOwnerSid))
            foreach ($wellKnownSid in @(
                    [Security.Principal.WellKnownSidType]::LocalSystemSid
                    [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid
                )) {
                [void]$trustedRecoveryOwners.Add(
                    ([Security.Principal.SecurityIdentifier]::new($wellKnownSid, $null)).Value)
            }
            $actualRootOwnerSid = [IO.FileSystemAclExtensions]::GetAccessControl(
                [IO.DirectoryInfo]::new($rootItem.FullName)).GetOwner(
                    [Security.Principal.SecurityIdentifier]).Value
            if (-not $trustedRecoveryOwners.Contains($actualRootOwnerSid)) {
                throw "Refusing to remove a recovery directory with an unexpected owner: $Path"
            }
            $entries = @(Get-ChildItem -LiteralPath $resolved -Force -ErrorAction Stop)
            if (@($entries | Where-Object {
                        $_.PSIsContainer -or
                        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                        $_.Length -gt 536870912 -or
                        ($_.Name -notin @('legacy-task.xml', 'system.log') -and
                            -not (Test-EverVigilApplicationDataRecoveryFileName `
                                -Name $_.Name) -and
                            -not (Test-EverVigilExternalArtifactRecoveryFileName `
                                -Name $_.Name `
                                -ExpectedTransactionId $expectedTransactionId))
                    }).Count -gt 0) {
                throw "Refusing to remove an unexpected recovery directory layout: $resolved"
            }
            foreach ($entry in $entries) {
                $actualOwnerSid = [IO.FileSystemAclExtensions]::GetAccessControl(
                    [IO.FileInfo]::new($entry.FullName)).GetOwner(
                    [Security.Principal.SecurityIdentifier]).Value
                if (-not $trustedRecoveryOwners.Contains($actualOwnerSid)) {
                    throw "Refusing to remove a recovery file with an unexpected owner: $($entry.FullName)"
                }
            }
        }
    }
}

function Remove-VerifiedTransactionTree {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Role,
        [ValidateSet(
            'OwnedInstall',
            'OwnedInstallBackup',
            'StagedInstall',
            'IncompleteStaging',
            'TemporaryPublish',
            'EmptyDirectory',
            'RecoveryDirectory')]
        [Parameter(Mandatory)][string]$Kind,
        [string]$OriginalInstallRoot
    )

    $target = Get-EverVigilTransactionDeletionTarget -State $State -Role $Role
    $transactionFilePath = $TransactionPath
    $validation = {
        Assert-VerifiedTree `
            -Path $target `
            -Expected $target `
            -Kind $Kind `
            -OriginalInstallRoot $OriginalInstallRoot `
            -State $State
    }
    $persistence = {
        param($CurrentState)
        Write-EverVigilInstallTransaction `
            -Path $transactionFilePath `
            -State $CurrentState
    }
    Invoke-EverVigilTransactionTreeRemoval `
        -State $State `
        -Role $Role `
        -PersistState $persistence `
        -ValidateTree $validation
}

function Resume-VerifiedTransactionTreeRemoval {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)]$State
    )

    $transactionFilePath = $TransactionPath
    $persistence = {
        param($CurrentState)
        Write-EverVigilInstallTransaction `
            -Path $transactionFilePath `
            -State $CurrentState
    }
    Resume-EverVigilTransactionTreeRemoval `
        -State $State `
        -PersistState $persistence
}

function Get-SupervisorProcessesAtRoot {
    param([Parameter(Mandatory)][string]$Root)

    return @(Get-EverVigilProcessesAtRoot -Root $Root)
}

function Invoke-SupervisorCommand {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw "Supervisor executable not found: $Executable"
    }
    $exitCode = Invoke-EverVigilBoundedProcess `
        -FilePath $Executable `
        -ArgumentList $Arguments `
        -WorkingDirectory (Split-Path -Parent $Executable) `
        -TimeoutSeconds $TimeoutSeconds
    if ($exitCode -ne 0) {
        throw "Supervisor command failed with exit code ${exitCode}: $($Arguments -join ' ')"
    }
}

function Stop-TransactionSupervisors {
    param([Parameter(Mandatory)]$State)

    $roots = @(
        [string]$State.installRoot
        [string]$State.previousInstallRoot
    ) | Select-Object -Unique
    foreach ($root in $roots) {
        $executable = Get-EverVigilExecutableAtRoot -Root $root
        if (Test-Path -LiteralPath $executable -PathType Leaf) {
            try { Invoke-SupervisorCommand -Executable $executable -Arguments @('--shutdown') -TimeoutSeconds 15 } catch {}
            try { Invoke-SupervisorCommand -Executable $executable -Arguments @('--unregister-startup') -TimeoutSeconds 15 } catch {}
        }
    }
    if (-not [bool]$State.startupWasRegistered) {
        $startupFolder = Get-EverVigilStartupFolderPath
        if (-not [string]::IsNullOrWhiteSpace($startupFolder)) {
            $startupShortcut = Join-Path $startupFolder 'EverVigil.lnk'
            [void](Remove-EverVigilOwnedShortcut `
                    -Path $startupShortcut `
                    -ExpectedTargetPath @(
                        (Join-Path ([string]$State.installRoot) 'EverVigil.exe')
                        (Join-Path ([string]$State.previousInstallRoot) 'EverVigil.exe')) `
                    -ExpectedArguments '--background')
        }
    }
    $remaining = @(@(foreach ($root in $roots) {
                Get-SupervisorProcessesAtRoot -Root $root
            }) | Sort-Object Id -Unique)
    if ($remaining.Count -gt 0) {
        $remaining | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue
    }
    $remaining = @(@(foreach ($root in $roots) {
                Get-SupervisorProcessesAtRoot -Root $root
            }) | Sort-Object Id -Unique)
    if ($remaining.Count -gt 0) {
        throw "A transaction supervisor is still running. PID(s): $($remaining.Id -join ', ')."
    }
}

function Remove-TransactionInteractiveTasks {
    param([Parameter(Mandatory)]$State)

    $attemptErrors = [Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-EverVigilInteractiveTasksForTransaction `
                -TransactionId ([string]$State.transactionId) `
                -OwnerSid ([string]$State.ownerSid) `
                -AllowedExecutablePath @(
                    (Get-EverVigilExecutableAtRoot -Root ([string]$State.installRoot))
                    (Get-EverVigilExecutableAtRoot -Root ([string]$State.previousInstallRoot))) `
                -StopInstances
            return
        } catch {
            $attemptErrors.Add("attempt ${attempt}: $($_.Exception.Message)")
            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds (250 * $attempt)
            }
        }
    }
    throw "Temporary interactive-task cleanup failed after 3 attempts: $($attemptErrors -join ' | ')"
}

function Write-SystemConfigurationRequirement {
    param([Parameter(Mandatory)][string]$Reason)

    New-Item -ItemType Directory -Path $script:InstallTransactionDataRoot -Force | Out-Null
    $requiredPath = Join-Path `
        $script:InstallTransactionDataRoot `
        $script:LegacyCompatibilityDataSystemConfigurationRequiredFileName
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        "$Reason at $(Get-Date -Format o)`n")
    $stream = [IO.FileStream]::new(
        $requiredPath,
        [IO.FileMode]::Create,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Test-AppliedSystemConfigurationMatchesTransaction {
    param([Parameter(Mandatory)]$State)

    $path = Join-Path `
        $script:InstallTransactionDataRoot `
        $script:LegacyCompatibilityDataAppliedSystemConfigurationFileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $false
    }
    try {
        $applied = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return [int]$applied.publicPort -eq [int]$State.publicPort -and
            [int]$applied.backendPort -eq [int]$State.backendPort -and
            [string]::Equals(
                [IO.Path]::GetFullPath([string]$applied.tailscalePath),
                [IO.Path]::GetFullPath([string]$State.tailscalePath),
                [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Invoke-SystemBrokerTransaction {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][ValidateSet('Commit', 'Rollback')][string]$Mode
    )

    $pendingExists = Test-Path `
        -LiteralPath $script:PendingSystemJournalPath `
        -PathType Leaf
    $ownedSystemTemporaries = @(
        Get-OwnedInstallerSystemJournalTemporaries `
            -TransactionId ([string]$State.transactionId))
    if (-not [bool]$State.migrationApplied -and
        -not $pendingExists -and
        $ownedSystemTemporaries.Count -eq 0) {
        return
    }
    if (-not $script:InstallTransactionMutexTaken -or
        -not $script:InstallTransactionMutex) {
        throw 'The install transaction mutex is not held before broker invocation.'
    }
    $script:InstallTransactionMutex.ReleaseMutex()
    $script:InstallTransactionMutexTaken = $false
    try {
        $brokerResponse = Invoke-EverVigilSystemBroker `
            -Operation $Mode `
            -TransactionId ([guid][string]$State.transactionId) `
            -Initiator Installer
    } finally {
        try {
            $script:InstallTransactionMutexTaken =
                $script:InstallTransactionMutex.WaitOne([TimeSpan]::FromMinutes(10))
        } catch [Threading.AbandonedMutexException] {
            $script:InstallTransactionMutexTaken = $true
        }
        if (-not $script:InstallTransactionMutexTaken) {
            throw 'Install recovery could not reacquire the system transaction mutex after broker execution.'
        }
    }
    $reloadedState = Resolve-EverVigilInstallTransactionAtomicState `
        -Path $script:InstallTransactionDefaultPath
    if ($null -eq $reloadedState -or
        -not [string]::Equals(
            [string]$reloadedState.transactionId,
            [string]$State.transactionId,
            [StringComparison]::Ordinal)) {
        throw 'The install transaction changed while the broker owned the system mutex.'
    }
    Assert-NoForeignPendingSystemJournal `
        -TransactionId ([string]$State.transactionId) `
        -AllowOwnedAtomicTemporary
    $expectedDispositions = if ($Mode -eq 'Commit') {
        @('Completed', 'NoChange')
    } else {
        @('RolledBack', 'NoChange')
    }
    if ([string]$brokerResponse.disposition -cnotin $expectedDispositions) {
        throw "The protected broker returned an unexpected $Mode disposition: $($brokerResponse.disposition)"
    }
    if (Test-Path -LiteralPath $script:PendingSystemJournalPath -PathType Leaf) {
        Remove-Item `
            -LiteralPath $script:PendingSystemJournalPath `
            -Force `
            -ErrorAction Stop
    }
    if ($Mode -eq 'Rollback') {
        Remove-OwnedInstallerSystemJournalTemporariesAfterRollback `
            -TransactionId ([string]$State.transactionId)
    } elseif ($ownedSystemTemporaries.Count -gt 0) {
        if (-not (Test-AppliedSystemConfigurationMatchesTransaction `
                    -State $State)) {
            throw 'Commit cannot retire same-transaction temporaries without exact applied state.'
        }
        Remove-OwnedInstallerSystemJournalTemporariesAfterRollback `
            -TransactionId ([string]$State.transactionId)
    }
}

function Invoke-InitialInstallProtectedBrokerCleanup {
    param([Parameter(Mandatory)]$State)

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
        [bool]$State.existingInstallPresent
    }
    if (-not $protectedCleanupAuthorized -or
        $protectedBrokerWasPresentBefore) {
        return
    }
    if (-not $script:InstallTransactionMutexTaken -or
        -not $script:InstallTransactionMutex) {
        throw 'The install transaction mutex is required for initial broker cleanup.'
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
    $cleanupTransactionId =
        [guid][string]$cleanupTransactionIdProperty.Value
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
        $script:InstallTransactionMutex.ReleaseMutex()
        $script:InstallTransactionMutexTaken = $false
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
                $script:InstallTransactionMutexTaken =
                    $script:InstallTransactionMutex.WaitOne(
                        [TimeSpan]::FromMinutes(10))
            } catch [Threading.AbandonedMutexException] {
                $script:InstallTransactionMutexTaken = $true
            }
            if (-not $script:InstallTransactionMutexTaken) {
                throw 'Install rollback could not reacquire the system mutex after broker cleanup.'
            }
        }
        $reloadedState = Resolve-EverVigilInstallTransactionAtomicState `
            -Path $script:InstallTransactionDefaultPath
        if ($null -eq $reloadedState -or
            -not [string]::Equals(
                [string]$reloadedState.transactionId,
                [string]$State.transactionId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$reloadedState.cleanupTransactionId,
                [string]$State.cleanupTransactionId,
                [StringComparison]::Ordinal)) {
            throw 'The install transaction changed while the broker cleaned initial state.'
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

function Restore-ProgramFiles {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)]$State
    )

    $installRoot = [string]$State.installRoot
    $backupRoot = [string]$State.backupRoot
    if ([bool]$State.destinationBackupPlanned -and (Test-Path -LiteralPath $backupRoot)) {
        if ([bool]$State.destinationOwnedInstallPresent) {
            Assert-OwnedInstallBackup `
                -Path $backupRoot `
                -OriginalInstallRoot $installRoot `
                -AllowCurrentTempTree
        } elseif (-not (Test-EmptyDirectory -Path $backupRoot)) {
            throw "The destination backup is not the expected empty directory: $backupRoot"
        }
        if (Test-Path -LiteralPath $installRoot) {
            Remove-VerifiedTransactionTree `
                -TransactionPath $TransactionPath `
                -State $State `
                -Role installRoot `
                -Kind OwnedInstall
        }
        Move-Item -LiteralPath $backupRoot -Destination $installRoot
    } elseif (-not [bool]$State.destinationBackupPlanned -and (Test-Path -LiteralPath $installRoot)) {
        Remove-VerifiedTransactionTree `
            -TransactionPath $TransactionPath `
            -State $State `
            -Role installRoot `
            -Kind OwnedInstall
    }

    if ([bool]$State.previousBackupPlanned) {
        $previousRoot = [string]$State.previousInstallRoot
        $previousBackupRoot = [string]$State.previousBackupRoot
        if (Test-Path -LiteralPath $previousBackupRoot) {
            Assert-OwnedInstallBackup `
                -Path $previousBackupRoot `
                -OriginalInstallRoot $previousRoot `
                -AllowCurrentTempTree
            if (Test-Path -LiteralPath $previousRoot) {
                Remove-VerifiedTransactionTree `
                    -TransactionPath $TransactionPath `
                    -State $State `
                    -Role previousInstallRoot `
                    -Kind OwnedInstall
            }
            Move-Item -LiteralPath $previousBackupRoot -Destination $previousRoot
        } elseif (-not (Test-Path -LiteralPath $previousRoot -PathType Container)) {
            throw "The previous installation backup is missing: $previousBackupRoot"
        } else {
            Assert-OwnedInstallRoot `
                -Path $previousRoot `
                -AllowLegacyKnownLayout `
                -AllowCurrentTempTree
        }
    }
}

function Restore-PreviousRuntime {
    param([Parameter(Mandatory)]$State)

    if (-not [bool]$State.existingInstallPresent) {
        return
    }
    $root = if ([bool]$State.installRootChanged) {
        [string]$State.previousInstallRoot
    } else {
        [string]$State.installRoot
    }
    $executable = Get-EverVigilExecutableAtRoot -Root $root
    Assert-OwnedInstallRoot `
        -Path $root `
        -AllowLegacyKnownLayout `
        -AllowCurrentTempTree
    if ([bool]$State.startupWasRegistered) {
        Invoke-SupervisorCommand -Executable $executable -Arguments @('--register-startup') -TimeoutSeconds 15
    }
    if ([bool]$State.existingSupervisorWasRunning) {
        Start-EverVigilRestoredSupervisor `
            -TransactionId ([string]$State.transactionId) `
            -OwnerSid ([string]$State.ownerSid) `
            -ExecutablePath $executable `
            -WorkingDirectory $root
    }
}

function Remove-TransactionRecoveryFiles {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)]$State
    )

    Remove-VerifiedTransactionTree `
        -TransactionPath $TransactionPath `
        -State $State `
        -Role recoveryRoot `
        -Kind RecoveryDirectory
    Remove-EverVigilEmptyApplicationDataContainers `
        -DataRoot $script:InstallTransactionDataRoot `
        -DataRootExisted ([bool]$State.dataRootExisted) `
        -TransactionsRootWasPresent ([bool]$State.transactionsRootWasPresent)
}

function Remove-TemporaryPublishTree {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)]$State
    )

    Remove-VerifiedTransactionTree `
        -TransactionPath $TransactionPath `
        -State $State `
        -Role publishRoot `
        -Kind TemporaryPublish
}

function Remove-RollbackWorkTrees {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)]$State
    )

    Remove-TemporaryPublishTree -TransactionPath $TransactionPath -State $State
    $stagingRoot = [string]$State.stagingRoot
    $kind = if (Test-EverVigilKnownLayout `
            -Path $stagingRoot `
            -AllowCurrentTempTree) {
        'StagedInstall'
    } else {
        'IncompleteStaging'
    }
    Remove-VerifiedTransactionTree `
        -TransactionPath $TransactionPath `
        -State $State `
        -Role stagingRoot `
        -Kind $kind
}

function Get-BridgeHostWasPresentBeforeTransaction {
    param([Parameter(Mandatory)]$State)

    $property = $State.PSObject.Properties['bridgeHostWasPresent']
    if ($null -eq $property) {
        # Transactions from builds that predate BridgeHost could not have
        # created it. Preserve any such directory during recovery.
        return $true
    }
    return [bool]$property.Value
}

function Remove-NewApplicationData {
    param([Parameter(Mandatory)]$State)

    Remove-EverVigilNewApplicationDataFiles `
        -DataRoot $script:InstallTransactionDataRoot `
        -State $State
    Remove-EverVigilNewBridgeHostDirectory `
        -DataRoot $script:InstallTransactionDataRoot `
        -BridgeHostWasPresent (Get-BridgeHostWasPresentBeforeTransaction -State $State)
    $logRoot = Join-Path `
        $script:InstallTransactionDataRoot `
        $script:LegacyCompatibilityDataLogDirectoryName
    if (-not [bool]$State.logsRootWasPresent -and
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
}

function Remove-EmptyApplicationDataContainers {
    param([Parameter(Mandatory)]$State)

    Remove-EverVigilEmptyApplicationDataContainers `
        -DataRoot $script:InstallTransactionDataRoot `
        -DataRootExisted ([bool]$State.dataRootExisted) `
        -TransactionsRootWasPresent ([bool]$State.transactionsRootWasPresent)
}

function Complete-RolledBackInstallTransaction {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    Resume-VerifiedTransactionTreeRemoval -TransactionPath $Path -State $State
    Remove-RollbackWorkTrees -TransactionPath $Path -State $State
    Remove-TransactionRecoveryFiles -TransactionPath $Path -State $State
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    Remove-EmptyApplicationDataContainers -State $State
}

function Restore-TransactionExternalArtifacts {
    param([Parameter(Mandatory)]$State)

    $snapshotReady = $State.PSObject.Properties['externalArtifactSnapshotReady']
    $registryReady = $State.PSObject.Properties['uninstallRegistrySnapshotReady']
    if ($null -eq $snapshotReady -and $null -eq $registryReady) {
        return
    }
    if ($null -ne $snapshotReady -and
        $snapshotReady.Value -eq $false -and
        $null -ne $registryReady -and
        $registryReady.Value -eq $false -and
        [string]$State.status -ceq 'staging' -and
        [string]$State.externalCommitPhase -ceq 'None' -and
        @($State.externalArtifactSnapshots).Count -eq 0 -and
        [string]$State.uninstallRegistrySnapshotSha256 -ceq '' -and
        [string]$State.uninstallRegistryMutationMarkerSha256 -ceq '') {
        # Snapshot construction precedes bootstrap, Inno file installation,
        # and program mutation. Known partial recovery copies are therefore
        # disposable; they are not authority to restore or delete live state.
        return
    }
    if ($null -eq $snapshotReady -or
        $snapshotReady.Value -ne $true -or
        $null -eq $registryReady -or
        $registryReady.Value -ne $true) {
        throw 'The external artifact rollback snapshots are incomplete.'
    }
    Restore-EverVigilExternalArtifactSnapshots `
        -State $State `
        -RecoveryRoot ([string]$State.recoveryRoot) `
        -TransactionId ([string]$State.transactionId)
}

function Assert-LegacyTokenPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OwnerSid
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals(
            [IO.Path]::GetFileName($resolvedPath),
            'token.txt',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The legacy token path has an unexpected file name: $resolvedPath"
    }
    $profileRegistryPath =
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$OwnerSid"
    $profilePath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string](
                Get-ItemPropertyValue -LiteralPath $profileRegistryPath -Name 'ProfileImagePath')))
    $profileName = [IO.DirectoryInfo]::new($profilePath).Name
    $allowedRoots = @(
        (Join-Path `
            $profilePath `
            $script:LegacyCompatibilityOlderEvenTerminalCodexLocalAppDataRootRelativeToProfile)
        foreach ($drive in @(Get-PSDrive -PSProvider FileSystem)) {
            [IO.Path]::Combine($drive.Root, 'Users', $profileName, 'Apps', 'even-terminal')
        }
    ) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Select-Object -Unique
    $tokenRoot = [IO.Path]::GetDirectoryName($resolvedPath).TrimEnd('\')
    if (-not @($allowedRoots | Where-Object {
                [string]::Equals($_, $tokenRoot, [StringComparison]::OrdinalIgnoreCase)
            }).Count) {
        throw "The legacy token path is outside the recognized migration roots: $resolvedPath"
    }
}

function Remove-EverVigilLegacyStartMenuShortcuts {
    param([Parameter(Mandatory)]$State)

    $programsRoot = Get-EverVigilProgramsFolderPath
    $legacyGroup = Join-Path `
        $programsRoot `
        $script:LegacyCompatibilityApplicationProductName
    if (-not (Test-Path -LiteralPath $legacyGroup -PathType Container)) {
        return
    }
    $groupItem = Get-Item -LiteralPath $legacyGroup -Force -ErrorAction Stop
    if (($groupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The legacy Start Menu group is a reparse point: $legacyGroup"
    }

    $applicationShortcut = Join-Path `
        $legacyGroup `
        "$($script:LegacyCompatibilityApplicationProductName).lnk"
    $applicationTargets = @(
        (Join-Path `
            ([string]$State.previousInstallRoot) `
            $script:LegacyCompatibilityApplicationExecutableFileName)
        (Join-Path `
            ([string]$State.installRoot) `
            $script:LegacyCompatibilityApplicationExecutableFileName)
        (Join-Path `
            (Join-Path `
                $env:LOCALAPPDATA `
                $script:LegacyCompatibilityApplicationInstallRootRelativeToLocalAppData) `
            $script:LegacyCompatibilityApplicationExecutableFileName)
    ) | Select-Object -Unique
    if ((Test-Path -LiteralPath $applicationShortcut -PathType Leaf) -and
        -not (Remove-EverVigilOwnedShortcut `
            -Path $applicationShortcut `
            -ExpectedTargetPath $applicationTargets `
            -ExpectedArguments '')) {
        throw "The legacy application Start Menu shortcut has an unexpected identity: $applicationShortcut"
    }

    $legacySupportRoot = Join-Path `
        $env:LOCALAPPDATA `
        $script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData
    $uninstallShortcut = Join-Path `
        $legacyGroup `
        "Uninstall $($script:LegacyCompatibilityApplicationProductName).lnk"
    if ((Test-Path -LiteralPath $uninstallShortcut -PathType Leaf) -and
        -not (Remove-EverVigilOwnedShortcut `
            -Path $uninstallShortcut `
            -ExpectedTargetPath @((Join-Path $legacySupportRoot 'unins000.exe')) `
            -ExpectedArguments '')) {
        throw "The legacy uninstaller Start Menu shortcut has an unexpected identity: $uninstallShortcut"
    }

    if (@(Get-ChildItem -LiteralPath $legacyGroup -Force -ErrorAction Stop).Count -eq 0) {
        Remove-Item -LiteralPath $legacyGroup -Force
    }
}

function Remove-EverVigilLegacyStartupShortcut {
    param([Parameter(Mandatory)]$State)

    $startupFolder = Get-EverVigilStartupFolderPath
    if ([string]::IsNullOrWhiteSpace($startupFolder)) {
        return
    }
    $shortcutPath = Join-Path `
        $startupFolder `
        $script:LegacyCompatibilityApplicationStartupShortcutFileName
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        return
    }
    $expectedTargets = @(
        (Join-Path `
            ([string]$State.previousInstallRoot) `
            $script:LegacyCompatibilityApplicationExecutableFileName)
        (Join-Path `
            ([string]$State.installRoot) `
            $script:LegacyCompatibilityApplicationExecutableFileName)
        (Join-Path `
            (Join-Path `
                $env:LOCALAPPDATA `
                $script:LegacyCompatibilityApplicationInstallRootRelativeToLocalAppData) `
            $script:LegacyCompatibilityApplicationExecutableFileName)
    ) | Select-Object -Unique
    if (-not (Remove-EverVigilOwnedShortcut `
            -Path $shortcutPath `
            -ExpectedTargetPath $expectedTargets `
            -ExpectedArguments '--background')) {
        throw "The legacy startup shortcut has an unexpected identity: $shortcutPath"
    }
}

function Remove-EverVigilLegacyUninstallSupport {
    param($State)

    $legacySupportRoot = [IO.Path]::GetFullPath((Join-Path `
                $env:LOCALAPPDATA `
                $script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData))
    if (-not (Test-Path -LiteralPath $legacySupportRoot -PathType Container)) {
        return
    }
    $resolvedRoot = [IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $legacySupportRoot -ErrorAction Stop).Path)
    if (-not [string]::Equals(
            $resolvedRoot,
            $legacySupportRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The legacy uninstall support path resolves unexpectedly: $resolvedRoot"
    }
    $allowedDirectories = @(
        'Support'
        'Support\scripts'
    )
    # The frozen v1.2.1 installer placed exactly three support scripts here.
    # EverVigil's seven-file uninstall-support manifest lives under the new
    # EverVigil.Uninstall root and must never be required at this legacy root.
    $legacyV121AllowedFiles = @(
        'unins000.dat'
        'unins000.exe'
        'Support\Uninstall.ps1'
        'Support\scripts\Invoke-SystemMaintenance.ps1'
        'Support\scripts\Resolve-SafeInstallRoot.ps1'
    )
    if ($null -eq $State) {
        Assert-EverVigilFixedExternalTree `
            -Root $resolvedRoot `
            -AllowedDirectories $allowedDirectories `
            -AllowedFiles $legacyV121AllowedFiles `
            -RequireAllFiles
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        if (Test-Path -LiteralPath $resolvedRoot) {
            throw "The legacy uninstall support directory could not be removed: $resolvedRoot"
        }
        return
    }
    Assert-EverVigilFixedExternalTree `
        -Root $resolvedRoot `
        -AllowedDirectories $allowedDirectories `
        -AllowedFiles $legacyV121AllowedFiles
    $snapshotByRole = @{}
    foreach ($snapshot in @($State.externalArtifactSnapshots)) {
        $snapshotByRole[[string]$snapshot.role] = $snapshot
    }
    $definitions = @(Get-EverVigilExternalArtifactDefinitions -State $State |
        Where-Object { $_.Role -clike 'legacy-support-*' })
    foreach ($definition in $definitions) {
        $snapshot = $snapshotByRole[$definition.Role]
        if ($null -eq $snapshot -or -not [bool]$snapshot.wasPresent) {
            if (Test-Path -LiteralPath $definition.Path) {
                throw "An unsnapshotted legacy support artifact appeared: $($definition.Path)"
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $definition.Path -PathType Leaf)) {
            continue
        }
        if (-not [string]::Equals(
                (Get-EverVigilFileSha256 -Path $definition.Path),
                [string]$snapshot.sha256,
                [StringComparison]::Ordinal)) {
            throw "A legacy support artifact changed before retirement: $($definition.Path)"
        }
        Remove-Item -LiteralPath $definition.Path -Force -ErrorAction Stop
    }
    foreach ($directory in @(
            (Join-Path $resolvedRoot 'Support\scripts')
            (Join-Path $resolvedRoot 'Support')
            $resolvedRoot
        )) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -eq 0) {
            Remove-Item -LiteralPath $directory -Force -ErrorAction Stop
        }
    }
    if (Test-Path -LiteralPath $resolvedRoot) {
        throw "The legacy uninstall support directory contains unretired entries: $resolvedRoot"
    }
}

function Assert-EverVigilInstallerFinalizationPreflight {
    param([Parameter(Mandatory)]$State)

    if (-not [bool]$State.externalArtifactSnapshotReady -or
        -not [bool]$State.uninstallRegistrySnapshotReady) {
        throw 'External rollback snapshots are not durable before installer finalization.'
    }
    Assert-EverVigilExternalArtifactSnapshotState `
        -State $State `
        -RecoveryRoot ([string]$State.recoveryRoot) `
        -RequireBackupFiles
    $registryPrestate = Read-EverVigilUninstallRegistrySnapshot `
        -RecoveryRoot ([string]$State.recoveryRoot) `
        -ExpectedSha256 ([string]$State.uninstallRegistrySnapshotSha256)
    Assert-EverVigilUninstallRegistryMutationMarker `
        -RecoveryRoot ([string]$State.recoveryRoot) `
        -TransactionId ([string]$State.transactionId) `
        -ExpectedSha256 ([string]$State.uninstallRegistryMutationMarkerSha256)
    Assert-EverVigilLegacyArtifactsMatchSnapshot `
        -State $State `
        -RecoveryRoot ([string]$State.recoveryRoot)

    Assert-EverVigilFixedExternalTree `
        -Root (Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall') `
        -AllowedDirectories @('Support', 'Support\scripts') `
        -AllowedFiles @(
            'unins000.dat'
            'unins000.exe'
            'Support\Uninstall.ps1'
            'Support\scripts\Complete-InstallTransaction.ps1'
            'Support\scripts\InstallTransactionData.ps1'
            'Support\scripts\Invoke-InteractiveUserTask.ps1'
            'Support\scripts\Invoke-SystemMaintenance.ps1'
            'Support\scripts\LegacyCompatibility.generated.ps1'
            'Support\scripts\Resolve-SafeInstallRoot.ps1') `
        -RequireAllFiles
    $programsRoot = Get-EverVigilProgramsFolderPath
    Assert-EverVigilFixedExternalTree `
        -Root (Join-Path $programsRoot 'EverVigil') `
        -AllowedDirectories @() `
        -AllowedFiles @('EverVigil.lnk', 'Uninstall EverVigil.lnk') `
        -RequireAllFiles
    $installedExecutable = Join-Path ([string]$State.installRoot) 'EverVigil.exe'
    Assert-EverVigilExternalShortcutIdentity `
        -Path (Join-Path $programsRoot 'EverVigil\EverVigil.lnk') `
        -ExpectedTargetPath @($installedExecutable) `
        -ExpectedArguments '' `
        -ExpectedWorkingDirectory @([string]$State.installRoot) `
        -ExpectedIconLocation @('', ',0', "$installedExecutable,0")
    $uninstaller = Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall\unins000.exe'
    Assert-EverVigilExternalShortcutIdentity `
        -Path (Join-Path $programsRoot 'EverVigil\Uninstall EverVigil.lnk') `
        -ExpectedTargetPath @($uninstaller) `
        -ExpectedArguments '' `
        -ExpectedWorkingDirectory @('', (Split-Path -Parent $uninstaller)) `
        -ExpectedIconLocation @('', ',0', "$uninstaller,0")
    $startupPath = Join-Path `
        (Get-EverVigilStartupFolderPath) `
        'EverVigil.lnk'
    $startupExpected = -not [bool]$State.existingInstallPresent -or
        [bool]$State.startupWasRegistered
    if ($startupExpected) {
        if (-not (Test-Path -LiteralPath $startupPath -PathType Leaf)) {
            throw 'The expected EverVigil startup shortcut is missing before finalization.'
        }
        Assert-EverVigilExternalShortcutIdentity `
            -Path $startupPath `
            -ExpectedTargetPath @($installedExecutable) `
            -ExpectedArguments '--background' `
            -ExpectedWorkingDirectory @([string]$State.installRoot) `
            -ExpectedIconLocation @('', "$installedExecutable,0")
    } elseif (Test-Path -LiteralPath $startupPath) {
        throw 'EverVigil startup was enabled despite a preserved disabled preference.'
    }
    Assert-EverVigilPartialInnoRegistryOwned `
        -State $State `
        -PrestateSnapshot $registryPrestate `
        -RequireCompleteCurrent
    if (Test-Path -LiteralPath $script:PendingSystemJournalPath) {
        throw 'The local installer pending system journal must be committed before finalization.'
    }
    if (@(Get-OwnedInstallerSystemJournalTemporaries `
                -TransactionId ([string]$State.transactionId)).Count -ne 0) {
        throw 'A system journal atomic temporary remains before finalization.'
    }
    if ([bool]$State.migrationApplied -and
        -not (Test-AppliedSystemConfigurationMatchesTransaction -State $State)) {
        throw 'The locally applied system configuration does not match the install transaction.'
    }
}

function Commit-EverVigilInstallTransaction {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    Remove-EverVigilInteractiveTasksForTransaction `
        -TransactionId ([string]$State.transactionId) `
        -OwnerSid ([string]$State.ownerSid) `
        -AllowedExecutablePath @(
            (Get-EverVigilExecutableAtRoot -Root ([string]$State.installRoot))
            (Get-EverVigilExecutableAtRoot -Root ([string]$State.previousInstallRoot)))
    $installRoot = [string]$State.installRoot
    $currentInstallLayout = Test-EverVigilKnownLayout `
        -Path $installRoot `
        -AllowCurrentTempTree
    $legacyInstallLayout = if ($currentInstallLayout) {
        $false
    } else {
        $null -ne (Get-EverVigilLegacyInstallOwnership `
                -Path $installRoot `
                -AllowCurrentTempTree)
    }
    if ($currentInstallLayout) {
        Assert-OwnedInstallRoot `
            -Path $installRoot `
            -AllowCurrentTempTree
    } elseif ($legacyInstallLayout) {
        Assert-OwnedInstallRoot `
            -Path $installRoot `
            -AllowLegacyKnownLayout `
            -AllowCurrentTempTree
    } else {
        throw "The committed installation does not match a verified current or legacy layout: $installRoot"
    }
    $externalCommitPhaseProperty =
        $State.PSObject.Properties['externalCommitPhase']
    if ($null -eq $externalCommitPhaseProperty) {
        # Frozen v1.2.1 transactions predate Inno-external snapshots. Preserve
        # their established recovery behavior without manufacturing new
        # rollback authority for files that were never snapshotted.
        $State.status = 'committed'
        Write-EverVigilInstallTransaction -Path $Path -State $State
        Invoke-SystemBrokerTransaction -State $State -Mode Commit
        Resume-VerifiedTransactionTreeRemoval -TransactionPath $Path -State $State
        Remove-TemporaryPublishTree -TransactionPath $Path -State $State
        Remove-VerifiedTransactionTree `
            -TransactionPath $Path `
            -State $State `
            -Role stagingRoot `
            -Kind StagedInstall
        if ([bool]$State.destinationBackupPlanned) {
            $kind = if ([bool]$State.destinationOwnedInstallPresent) {
                'OwnedInstallBackup'
            } else {
                'EmptyDirectory'
            }
            Remove-VerifiedTransactionTree `
                -TransactionPath $Path `
                -State $State `
                -Role backupRoot `
                -Kind $kind `
                -OriginalInstallRoot ([string]$State.installRoot)
        }
        if ([bool]$State.previousBackupPlanned) {
            Remove-VerifiedTransactionTree `
                -TransactionPath $Path `
                -State $State `
                -Role previousBackupRoot `
                -Kind OwnedInstallBackup `
                -OriginalInstallRoot ([string]$State.previousInstallRoot)
        }
        Remove-TransactionRecoveryFiles -TransactionPath $Path -State $State
        Remove-Item -LiteralPath $Path -Force
        'Legacy install transaction committed.'
        return
    }

    $phase = [string]$State.externalCommitPhase
    if ($phase -in @('None', 'SnapshotReady')) {
        try {
            Assert-EverVigilInstallerFinalizationPreflight -State $State

            # Everything below this point is still compensatable from the
            # durable Program Files, application-data, shortcut, uninstall
            # support, and typed-registry snapshots. Complete all fallible
            # external retirement before crossing the protected broker commit
            # boundary. A failure or hard crash while the durable phase is
            # SnapshotReady is therefore recovered by rollback, never by
            # leaving a partially retired prior installation active.
            Resume-VerifiedTransactionTreeRemoval -TransactionPath $Path -State $State
            Remove-TemporaryPublishTree -TransactionPath $Path -State $State
            Remove-VerifiedTransactionTree `
                -TransactionPath $Path `
                -State $State `
                -Role stagingRoot `
                -Kind StagedInstall

            if ([bool]$State.runtimeConfigurationReady -and
                [bool]$State.legacyCredentialFound -and
                -not [string]::IsNullOrWhiteSpace([string]$State.legacyTokenPath) -and
                (Test-Path -LiteralPath ([string]$State.legacyTokenPath) -PathType Leaf)) {
                Assert-LegacyTokenPath `
                    -Path ([string]$State.legacyTokenPath) `
                    -OwnerSid ([string]$State.ownerSid)
                $legacyTokenSnapshot = @($State.externalArtifactSnapshots |
                        Where-Object {
                            [string]$_.role -ceq 'legacy-plaintext-token'
                        })
                if ($legacyTokenSnapshot.Count -ne 1 -or
                    $legacyTokenSnapshot[0].wasPresent -ne $true -or
                    -not [string]::Equals(
                        (Get-EverVigilFileSha256 -Path ([string]$State.legacyTokenPath)),
                        [string]$legacyTokenSnapshot[0].sha256,
                        [StringComparison]::Ordinal)) {
                    throw 'The legacy plaintext token changed before retirement.'
                }
                Remove-Item -LiteralPath ([string]$State.legacyTokenPath) -Force
            }
            $legacyCleanupProperty =
                $State.PSObject.Properties['legacyCleanupAuthorized']
            if ($null -ne $legacyCleanupProperty -and
                $legacyCleanupProperty.Value -isnot [bool]) {
                throw 'The legacy cleanup authorization must be a JSON boolean.'
            }
            $legacyCleanupAuthorized = $null -ne $legacyCleanupProperty -and
                $legacyCleanupProperty.Value -eq $true
            if ($legacyCleanupAuthorized) {
                if (-not $currentInstallLayout) {
                    throw 'Legacy artifact retirement is authorized only after the current EverVigil layout is active.'
                }
                Remove-EverVigilLegacyStartupShortcut -State $State
                Remove-EverVigilLegacyStartMenuShortcuts -State $State
                Remove-EverVigilLegacyUninstallSupport -State $State
            }

            $State.externalCommitPhase = 'SystemCommitPrepared'
            Write-EverVigilInstallTransaction -Path $Path -State $State
        } catch {
            $preflightError = $_.Exception
            $State.externalCommitPhase = 'SnapshotReady'
            try {
                Rollback-EverVigilInstallTransaction -Path $Path -State $State | Out-Null
            } catch {
                throw "Installer finalization preflight failed: $($preflightError.Message) Rollback also failed: $($_.Exception.Message)"
            }
            throw "Installer finalization preflight failed and the prior environment was restored: $($preflightError.Message)"
        }
        $phase = 'SystemCommitPrepared'
    }

    if ($phase -ceq 'SystemCommitPrepared') {
        # This durable phase is the point of no return. A process loss during
        # the broker call is resolved by idempotently resuming Commit, never by
        # guessing whether protected state was already finalized.
        Invoke-SystemBrokerTransaction -State $State -Mode Commit
        $State.status = 'committed'
        $State.externalCommitPhase = 'SystemCommitted'
        Write-EverVigilInstallTransaction -Path $Path -State $State
        $phase = 'SystemCommitted'
    }

    if ($phase -ceq 'SystemCommitted') {
        # The active installation and all externally visible migration cleanup
        # were already verified before SystemCommitPrepared. After the broker
        # commit only transaction evidence remains, so retries move forward and
        # never guess whether protected state was committed.
        $State.externalCommitPhase = 'CleanupComplete'
        Write-EverVigilInstallTransaction -Path $Path -State $State
        $phase = 'CleanupComplete'
    }

    if ($phase -cne 'CleanupComplete') {
        throw "The external commit phase is not resumable: $phase"
    }
    Resume-VerifiedTransactionTreeRemoval -TransactionPath $Path -State $State
    if ([bool]$State.destinationBackupPlanned) {
        $kind = if ([bool]$State.destinationOwnedInstallPresent) {
            'OwnedInstallBackup'
        } else {
            'EmptyDirectory'
        }
        Remove-VerifiedTransactionTree `
            -TransactionPath $Path `
            -State $State `
            -Role backupRoot `
            -Kind $kind `
            -OriginalInstallRoot ([string]$State.installRoot)
    }
    if ([bool]$State.previousBackupPlanned) {
        Remove-VerifiedTransactionTree `
            -TransactionPath $Path `
            -State $State `
            -Role previousBackupRoot `
            -Kind OwnedInstallBackup `
            -OriginalInstallRoot ([string]$State.previousInstallRoot)
    }
    Remove-TransactionRecoveryFiles -TransactionPath $Path -State $State
    Remove-Item -LiteralPath $Path -Force
    'Install transaction committed.'
}

function Seal-EverVigilInstallTransaction {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    if ([string]$State.status -ne 'pending') {
        throw "Only a pending install transaction can be sealed: $($State.status)"
    }
    if (-not [bool]$State.applicationDataSnapshotReady) {
        throw 'The install transaction cannot be sealed before application-data snapshots complete.'
    }
    $externalReadyProperty =
        $State.PSObject.Properties['externalArtifactSnapshotReady']
    $registryReadyProperty =
        $State.PSObject.Properties['uninstallRegistrySnapshotReady']
    if ($null -ne $State.PSObject.Properties['cleanupTransactionId'] -and
        ($null -eq $externalReadyProperty -or
            $externalReadyProperty.Value -ne $true -or
            $null -eq $registryReadyProperty -or
            $registryReadyProperty.Value -ne $true -or
            [string]$State.externalCommitPhase -cne 'SnapshotReady')) {
        throw 'The install transaction cannot be sealed before external recovery snapshots complete.'
    }
    Assert-OwnedInstallRoot `
        -Path ([string]$State.installRoot) `
        -AllowCurrentTempTree
    $State.status = 'readyToCommit'
    Write-EverVigilInstallTransaction -Path $Path -State $State
    'Install transaction sealed for commit.'
}

function Rollback-EverVigilInstallTransaction {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    $externalCommitPhaseProperty =
        $State.PSObject.Properties['externalCommitPhase']
    if ($null -ne $externalCommitPhaseProperty -and
        [string]$externalCommitPhaseProperty.Value -in @(
            'SystemCommitPrepared', 'SystemCommitted', 'CleanupComplete')) {
        throw 'The install transaction crossed the protected system commit boundary and must resume commit.'
    }
    if ([string]$State.status -eq 'rolledBack') {
        # A durable rolledBack state is written only after protected, external,
        # application-data, and runtime restoration all succeeded. Retrying
        # those mutations could remove data created after rollback.
        # Only remaining transaction evidence is resumable from this state.
        Complete-RolledBackInstallTransaction -Path $Path -State $State
        'Install transaction rollback cleanup completed.'
        return
    }
    if ([string]$State.status -eq 'staging') {
        Invoke-InitialInstallProtectedBrokerCleanup -State $State
        Restore-TransactionExternalArtifacts -State $State
        # Staging can already have created the configuration-required marker
        # and other application-data artifacts before protected bootstrap
        # fails. Restore the recorded pre-install data state before making the
        # rollback status durable, so both this attempt and a response-loss
        # retry converge to the same clean prestate.
        Remove-NewApplicationData -State $State
        $State.status = 'rolledBack'
        Write-EverVigilInstallTransaction -Path $Path -State $State
        Complete-RolledBackInstallTransaction -Path $Path -State $State
        'Incomplete staging transaction removed.'
        return
    }

    $State.status = 'rollingBack'
    Write-EverVigilInstallTransaction -Path $Path -State $State
    $errors = [Collections.Generic.List[string]]::new()
    $programFilesSafe = $true
    try {
        Remove-TransactionInteractiveTasks -State $State
    } catch {
        $programFilesSafe = $false
        $errors.Add("temporary task cleanup: $($_.Exception.Message)")
    }
    try {
        Stop-TransactionSupervisors -State $State
    } catch {
        $programFilesSafe = $false
        $errors.Add("supervisor shutdown: $($_.Exception.Message)")
    }
    if ($programFilesSafe) {
        try {
            Resume-VerifiedTransactionTreeRemoval -TransactionPath $Path -State $State
        } catch {
            $programFilesSafe = $false
            $errors.Add("interrupted tree deletion: $($_.Exception.Message)")
        }
    }

    $systemRollbackSucceeded = $true
    try {
        if ([bool]$State.systemConfigurationWasRequired) {
            Write-SystemConfigurationRequirement `
                -Reason 'Installer rollback restored a prior startup block'
        }
        Invoke-SystemBrokerTransaction `
            -State $State `
            -Mode Rollback
        Invoke-InitialInstallProtectedBrokerCleanup -State $State
    } catch {
        $systemRollbackSucceeded = $false
        $errors.Add("system configuration: $($_.Exception.Message)")
        try {
            Write-SystemConfigurationRequirement `
                -Reason 'System rollback failed; backend must remain stopped'
        } catch {
            $errors.Add("Startup blocking also failed: $($_.Exception.Message)")
        }
    }

    if ($programFilesSafe) {
        try {
            Restore-ProgramFiles -TransactionPath $Path -State $State
        } catch {
            $errors.Add("program files: $($_.Exception.Message)")
        }
    }
    try {
        Remove-RollbackWorkTrees -TransactionPath $Path -State $State
    } catch {
        $errors.Add("generated trees: $($_.Exception.Message)")
    }
    if ($systemRollbackSucceeded -and $errors.Count -eq 0) {
        try {
            if ([bool]$State.applicationDataSnapshotReady) {
                Restore-EverVigilApplicationDataSnapshots `
                    -DataRoot $script:InstallTransactionDataRoot `
                    -RecoveryRoot ([string]$State.recoveryRoot) `
                    -TransactionId ([string]$State.transactionId) `
                    -State $State
                Remove-EverVigilNewQuarantineFiles `
                    -DataRoot $script:InstallTransactionDataRoot `
                    -State $State
            }
            Remove-NewApplicationData -State $State
            Restore-TransactionExternalArtifacts -State $State
        } catch {
            $errors.Add("application data: $($_.Exception.Message)")
        }
    }
    if ($systemRollbackSucceeded -and $errors.Count -eq 0) {
        try {
            Restore-PreviousRuntime -State $State
        } catch {
            $errors.Add("previous runtime: $($_.Exception.Message)")
        }
    } else {
        $startupFolder = Get-EverVigilStartupFolderPath
        if (-not [string]::IsNullOrWhiteSpace($startupFolder)) {
            $startupShortcut = Join-Path $startupFolder 'EverVigil.lnk'
            [void](Remove-EverVigilOwnedShortcut `
                    -Path $startupShortcut `
                    -ExpectedTargetPath @(
                        (Join-Path ([string]$State.installRoot) 'EverVigil.exe')
                        (Join-Path ([string]$State.previousInstallRoot) 'EverVigil.exe')) `
                    -ExpectedArguments '--background')
        }
    }

    if ($errors.Count -gt 0) {
        throw "Install transaction rollback is incomplete: $($errors -join ' | ')"
    }
    $State.status = 'rolledBack'
    Write-EverVigilInstallTransaction -Path $Path -State $State
    Complete-RolledBackInstallTransaction -Path $Path -State $State
    'Install transaction rolled back.'
}

function Invoke-EverVigilInstallTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Seal', 'Commit', 'Rollback', 'Recover')][string]$RequestedAction,
        [Parameter(Mandatory)][string]$Path
    )

    $resolvedPath = Assert-InstallTransactionPath -Path $Path
    $mutex = New-EverVigilSystemTransactionMutex
    $script:InstallTransactionMutex = $mutex
    $lockTaken = $false
    try {
        try {
            $lockTaken = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
        } catch [Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
        if (-not $lockTaken) {
            throw 'Another EverVigil install or uninstall transaction did not finish within 10 minutes.'
        }
        $script:InstallTransactionMutexTaken = $true
        $state = Resolve-EverVigilInstallTransactionAtomicState `
            -Path $resolvedPath
        if ($null -eq $state) {
            'No pending install transaction was found.'
            return
        }
        $ownedSystemTemporaries = @(
            Get-OwnedInstallerSystemJournalTemporaries `
                -TransactionId ([string]$state.transactionId))
        $effectiveAction = if ($RequestedAction -eq 'Recover') {
            if ($null -ne $state.PSObject.Properties['externalCommitPhase'] -and
                [string]$state.externalCommitPhase -in @(
                    'SystemCommitPrepared',
                    'SystemCommitted',
                    'CleanupComplete')) {
                'Commit'
            } elseif ($ownedSystemTemporaries.Count -gt 0) {
                'Rollback'
            } elseif ($null -ne $state.PSObject.Properties['externalCommitPhase']) {
                if ([string]$state.externalCommitPhase -in @(
                        'SystemCommitPrepared',
                        'SystemCommitted',
                        'CleanupComplete')) {
                    'Commit'
                } else {
                    'Rollback'
                }
            } elseif ([string]$state.status -in @('readyToCommit', 'committed')) {
                'Commit'
            } else {
                'Rollback'
            }
        } else {
            $RequestedAction
        }
        if ($effectiveAction -eq 'Seal') {
            Seal-EverVigilInstallTransaction -Path $resolvedPath -State $state
        } elseif ($effectiveAction -eq 'Commit') {
            Commit-EverVigilInstallTransaction `
                -Path $resolvedPath `
                -State $state
        } else {
            Rollback-EverVigilInstallTransaction `
                -Path $resolvedPath `
                -State $state
        }
    } finally {
        if ($script:InstallTransactionMutexTaken) {
            $mutex.ReleaseMutex()
        }
        $script:InstallTransactionMutexTaken = $false
        $script:InstallTransactionMutex = $null
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($Action)) {
        throw 'Specify -Action Seal, Commit, Rollback, or Recover.'
    }
    Invoke-EverVigilInstallTransaction `
        -RequestedAction $Action `
        -Path $TransactionPath
}
