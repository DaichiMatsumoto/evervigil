[CmdletBinding()]
param(
    [switch]$KeepData,
    [string]$InstallRoot
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

$defaultInstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\EverVigil'
$siblingExecutable = Join-Path $PSScriptRoot 'EverVigil.exe'
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = if (Test-Path -LiteralPath $siblingExecutable -PathType Leaf) {
        $PSScriptRoot
    } else {
        $defaultInstallRoot
    }
}
$InstallPathResolver = Join-Path $PSScriptRoot 'scripts\Resolve-SafeInstallRoot.ps1'
$requiredUninstallSupportScripts = @(
    'Complete-InstallTransaction.ps1'
    'InstallTransactionData.ps1'
    'Invoke-InteractiveUserTask.ps1'
    'Invoke-SystemMaintenance.ps1'
    'LegacyCompatibility.generated.ps1'
    'Resolve-SafeInstallRoot.ps1'
)
foreach ($requiredSupportScriptName in $requiredUninstallSupportScripts) {
    $requiredSupportScriptPath = Join-Path `
        (Join-Path $PSScriptRoot 'scripts') `
        $requiredSupportScriptName
    $requiredSupportScriptItem = Get-Item `
        -LiteralPath $requiredSupportScriptPath `
        -Force `
        -ErrorAction SilentlyContinue
    if ($null -eq $requiredSupportScriptItem -or
        $requiredSupportScriptItem.PSIsContainer -or
        ($requiredSupportScriptItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Required uninstall support helper is missing or unsafe: $requiredSupportScriptPath"
    }
}
. $InstallPathResolver
try {
    $installRootResolution = Resolve-EverVigilMaintenanceInstallRoot `
        -Path $InstallRoot `
        -AllowLegacyKnownLayout
} catch {
    $missingInstallRoot = Resolve-SafeInstallRoot `
        -Path $InstallRoot `
        -AllowCurrentTempTree
    if (Test-Path -LiteralPath $missingInstallRoot) {
        throw
    }
    $installRootResolution = [pscustomobject]@{
        Path = $missingInstallRoot
        AllowCurrentTempTree = $true
        Registered = $false
        Owned = $false
    }
}
$InstallRoot = [string]$installRootResolution.Path
$allowInstallRootInCurrentTemp = [bool]$installRootResolution.AllowCurrentTempTree
$DataRoot = Get-EverVigilActiveDataRoot
$PendingSystemJournalPath = Join-Path $DataRoot 'pending-system-configuration.json'
$SystemTransactionId = [guid]::NewGuid().ToString('N')
$RecognizedDataRoots = @(
    (Join-Path $env:LOCALAPPDATA 'EverVigil')
    (Join-Path `
        $env:LOCALAPPDATA `
        $script:LegacyCompatibilityApplicationDataRootRelativeToLocalAppData)
    ) | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique
$CurrentDefaultInstallRoot = [IO.Path]::GetFullPath($defaultInstallRoot).TrimEnd('\')
$LegacyDefaultInstallRoot = [IO.Path]::GetFullPath((Join-Path `
        $env:LOCALAPPDATA `
        $script:LegacyCompatibilityApplicationInstallRootRelativeToLocalAppData)).TrimEnd('\')
$SiblingTransactionResidueSpecifications = [Collections.Generic.List[object]]::new()
$SiblingTransactionResidueSpecifications.Add([pscustomobject]@{
        OriginalInstallRoot = $InstallRoot
        AllowedKind = @('staging', 'backup', 'relocated')
    })
foreach ($knownPreviousRoot in @($CurrentDefaultInstallRoot, $LegacyDefaultInstallRoot)) {
    if (-not [string]::Equals(
            $knownPreviousRoot,
            $InstallRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        $SiblingTransactionResidueSpecifications.Add([pscustomobject]@{
                OriginalInstallRoot = $knownPreviousRoot
                AllowedKind = @('relocated')
            })
    }
}
$InstallTransactionPath = Join-Path `
    $DataRoot `
    $script:LegacyCompatibilityDataTransactionJournalFileName
$InstallTransactionScript = Join-Path `
    $PSScriptRoot `
    'scripts\Complete-InstallTransaction.ps1'
$InstallTransactionDataHelper = Join-Path `
    $PSScriptRoot `
    'scripts\InstallTransactionData.ps1'
if (-not (Test-Path -LiteralPath $InstallTransactionScript -PathType Leaf)) {
    throw "The install transaction recovery helper is missing: $InstallTransactionScript"
}
. $InstallTransactionDataHelper
$installTransactionTemporaryPrefix =
    "$($script:LegacyCompatibilityDataTransactionJournalFileName).new-"
$transactionRecoveryRoots = [Collections.Generic.List[string]]::new()
foreach ($recognizedDataRoot in $RecognizedDataRoots) {
    $candidateTransactionPath = Join-Path `
        $recognizedDataRoot `
        $script:LegacyCompatibilityDataTransactionJournalFileName
    $candidateTemporaries = @(
        Get-EverVigilInstallTransactionTemporaryFiles `
            -DataRoot $recognizedDataRoot)
    if ((Test-Path -LiteralPath $candidateTransactionPath) -or
        $candidateTemporaries.Count -gt 0) {
        $transactionRecoveryRoots.Add(
            [IO.Path]::GetFullPath($recognizedDataRoot))
    }
}
if ($transactionRecoveryRoots.Count -gt 1) {
    throw 'Install transaction artifacts exist in both recognized data roots; refusing ambiguous recovery.'
}
if ($transactionRecoveryRoots.Count -eq 1) {
    $recoveryTransactionPath = Join-Path `
        $transactionRecoveryRoots[0] `
        $script:LegacyCompatibilityDataTransactionJournalFileName
    & $InstallTransactionScript `
        -Action Recover `
        -TransactionPath $recoveryTransactionPath
    $remainingTransactionArtifacts = @(
        if (Test-Path -LiteralPath $recoveryTransactionPath) {
            Get-Item -LiteralPath $recoveryTransactionPath -Force -ErrorAction Stop
        }
        Get-EverVigilInstallTransactionTemporaryFiles `
            -DataRoot $transactionRecoveryRoots[0])
    if ($remainingTransactionArtifacts.Count -gt 0) {
        throw "An install recovery transaction could not be resolved before uninstalling: $($remainingTransactionArtifacts[0].FullName)"
    }
}
$InstalledExecutable = Join-Path $InstallRoot 'EverVigil.exe'
$AppliedSystemConfigurationPath = Join-Path `
    $DataRoot `
    $script:LegacyCompatibilityDataAppliedSystemConfigurationFileName
$SystemConfigurationRequiredPath = Join-Path `
    $DataRoot `
    $script:LegacyCompatibilityDataSystemConfigurationRequiredFileName
$StartupShortcutPath = Join-Path `
    ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) `
    'EverVigil.lnk'
$LegacyStartupShortcutPath = Join-Path `
    ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) `
    $script:LegacyCompatibilityApplicationStartupShortcutFileName
$CurrentStartupTargets = @(
    (Join-Path $InstallRoot 'EverVigil.exe')
) | Select-Object -Unique
$LegacyStartupTargets = @(
    (Join-Path `
        $InstallRoot `
        $script:LegacyCompatibilityApplicationExecutableFileName)
    (Join-Path `
        (Join-Path `
            $env:LOCALAPPDATA `
            $script:LegacyCompatibilityApplicationInstallRootRelativeToLocalAppData) `
        $script:LegacyCompatibilityApplicationExecutableFileName)
) | Select-Object -Unique
if ((Test-Path -LiteralPath $StartupShortcutPath -PathType Leaf) -and
    -not (Test-EverVigilShortcutIdentity `
        -Path $StartupShortcutPath `
        -ExpectedTargetPath $CurrentStartupTargets `
        -ExpectedArguments '--background')) {
    throw "The EverVigil startup shortcut has an unexpected target or arguments: $StartupShortcutPath"
}
if ((Test-Path -LiteralPath $LegacyStartupShortcutPath -PathType Leaf) -and
    -not (Test-EverVigilShortcutIdentity `
        -Path $LegacyStartupShortcutPath `
        -ExpectedTargetPath $LegacyStartupTargets `
        -ExpectedArguments '--background')) {
    throw "The legacy startup shortcut has an unexpected target or arguments: $LegacyStartupShortcutPath"
}
$PublicPort = 3456
$BackendPort = 3457
$TailscalePath = $null
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$OwnerSid = if ($null -eq $currentIdentity.User) {
    $null
} else {
    $currentIdentity.User.Value
}
if ([string]::IsNullOrWhiteSpace($OwnerSid)) {
    throw 'The invoking user SID is unavailable.'
}

function Read-SystemConfiguration {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    try {
        $configuration = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $result = [pscustomobject]@{
            PublicPort = [int]$configuration.publicPort
            BackendPort = [int]$configuration.backendPort
            TailscalePath = [string]$configuration.tailscalePath
        }
    } catch {
        throw "Could not read $Description at '$Path': $($_.Exception.Message)"
    }
    if ($result.PublicPort -lt 1024 -or $result.PublicPort -gt 65535 -or
        $result.BackendPort -lt 1024 -or $result.BackendPort -gt 65535 -or
        $result.PublicPort -eq $result.BackendPort) {
        throw "$Description contains invalid ports: $($result.PublicPort)/$($result.BackendPort)"
    }
    if ([string]::IsNullOrWhiteSpace($result.TailscalePath) -or
        $result.TailscalePath.Contains('"') -or
        -not (Test-EverVigilPathFullyQualified -Path $result.TailscalePath)) {
        throw "$Description contains an invalid Tailscale path: $($result.TailscalePath)"
    }
    $result.TailscalePath = [IO.Path]::GetFullPath($result.TailscalePath)
    return $result
}

function Resolve-AvailableTailscalePath {
    param([Parameter(Mandatory)][string[]]$Candidates)

    $availableCommand = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
    if ($availableCommand -and -not [string]::IsNullOrWhiteSpace($availableCommand.Source)) {
        $Candidates += $availableCommand.Source
    }

    foreach ($candidate in @($Candidates | Select-Object -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw "No available Tailscale CLI was found. Checked: $($Candidates -join ', ')"
}

function New-UninstallPendingSystemJournal {
    param([Parameter(Mandatory)]$Target)

    if (Test-Path -LiteralPath $PendingSystemJournalPath) {
        throw "A pending system journal already exists: $PendingSystemJournalPath"
    }
    $state = [ordered]@{
        schemaVersion = 1
        transactionId = ([guid]$SystemTransactionId).ToString()
        ownerSid = $OwnerSid
        dataRoot = [IO.Path]::GetFullPath($DataRoot)
        initiator = 'Installer'
        target = $Target
        previous = $Target
        previousMappingOwned = $true
        existingTargetMappingOwned = $true
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
    $temporaryPath = "$PendingSystemJournalPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
            (($state | ConvertTo-Json -Depth 8) + "`n"))
        $stream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
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
        $security = [Security.AccessControl.FileSecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        foreach ($identity in @(
                [Security.Principal.SecurityIdentifier]::new($OwnerSid)
                [Security.Principal.SecurityIdentifier]::new(
                    [Security.Principal.WellKnownSidType]::LocalSystemSid,
                    $null)
                [Security.Principal.SecurityIdentifier]::new(
                    [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
                    $null)
            )) {
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    $identity,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    [Security.AccessControl.AccessControlType]::Allow))
        }
        [IO.FileSystemAclExtensions]::SetAccessControl(
            [IO.FileInfo]::new($temporaryPath),
            $security)
        [IO.File]::Move($temporaryPath, $PendingSystemJournalPath, $true)
        [IO.FileSystemAclExtensions]::SetAccessControl(
            [IO.FileInfo]::new($PendingSystemJournalPath),
            $security)
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-EverVigilCurrentOwnerFileAcl {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $security = [IO.FileSystemAclExtensions]::GetAccessControl(
            [IO.FileInfo]::new($item.FullName),
            [Security.AccessControl.AccessControlSections]'Owner, Access')
        if (-not $security.AreAccessRulesProtected) {
            return $false
        }
        $ownerSidObject = [Security.Principal.SecurityIdentifier]::new($OwnerSid)
        $systemSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::LocalSystemSid,
            $null)
        $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
            $null)
        $aclOwner = $security.GetOwner(
            [Security.Principal.SecurityIdentifier])
        if (-not $aclOwner.Equals($ownerSidObject)) {
            return $false
        }
        $required = @{
            $ownerSidObject.Value = $false
            $systemSid.Value = $false
            $administratorsSid.Value = $false
        }
        $fullControl = [long][Security.AccessControl.FileSystemRights]::FullControl
        foreach ($rule in $security.GetAccessRules(
                $true,
                $true,
                [Security.Principal.SecurityIdentifier])) {
            if ($rule.IsInherited -or
                $rule.AccessControlType -ne
                    [Security.AccessControl.AccessControlType]::Allow -or
                -not $required.ContainsKey($rule.IdentityReference.Value) -or
                (([long]$rule.FileSystemRights -band $fullControl) -ne $fullControl)) {
                return $false
            }
            $required[$rule.IdentityReference.Value] = $true
        }
        return @($required.Values | Where-Object { -not $_ }).Count -eq 0
    } catch {
        return $false
    }
}

function Read-PendingSystemJournalForRecovery {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedDataRoot,
        [switch]$AllowAtomicTemporary
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $expectedPath = Join-Path `
        ([IO.Path]::GetFullPath($ExpectedDataRoot)) `
        'pending-system-configuration.json'
    $isStablePath = [string]::Equals(
        $resolvedPath,
        $expectedPath,
        [StringComparison]::OrdinalIgnoreCase)
    $isAtomicTemporaryPath = $AllowAtomicTemporary -and
        [string]::Equals(
            (Split-Path -Parent $resolvedPath),
            ([IO.Path]::GetFullPath($ExpectedDataRoot)).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedPath) -cmatch
            '\Apending-system-configuration\.json\.[0-9a-f]{32}\.tmp\z'
    if (-not $isStablePath -and -not $isAtomicTemporaryPath) {
        throw "The pending system journal path is not recognized: $resolvedPath"
    }
    $item = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The pending system journal is not a regular file: $resolvedPath"
    }
    if ($item.Length -lt 2 -or $item.Length -gt 65536 -or
        ($isAtomicTemporaryPath -and
            -not (Test-EverVigilCurrentOwnerFileAcl -Path $resolvedPath))) {
        throw "The pending system journal size or owner ACL is invalid: $resolvedPath"
    }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString(
            [IO.File]::ReadAllBytes($resolvedPath))
        $state = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "The pending system journal is invalid JSON: $($_.Exception.Message)"
    }
    $expectedProperties = @(
        'schemaVersion', 'transactionId', 'ownerSid', 'dataRoot', 'initiator',
        'target', 'previous', 'previousMappingOwned',
        'existingTargetMappingOwned', 'phase',
        'observedTargetRouteOwnership', 'observedPreviousRouteOwnership',
        'firewallSnapshotCaptured', 'originalMainFirewallPort',
        'originalTemporaryFirewallPort', 'previousRouteMutationAuthorized',
        'targetRouteMutationAuthorized', 'firewallMutationAuthorized')
    $actualProperties = @($state.PSObject.Properties)
    $targetProperties = @($state.target.PSObject.Properties)
    $validTargetProperties = @('publicPort', 'backendPort', 'tailscalePath')
    $booleanProperties = @(
        'previousMappingOwned', 'existingTargetMappingOwned',
        'firewallSnapshotCaptured', 'previousRouteMutationAuthorized',
        'targetRouteMutationAuthorized', 'firewallMutationAuthorized')
    $validPhase = @(
        'Prepared', 'PreflightVerified', 'PreviousRouteMutationPrepared',
        'PreviousRouteRemoved', 'TargetRouteMutationPrepared',
        'TargetRouteApplied', 'FirewallMutationPrepared', 'FirewallApplied',
        'MutationsCompleted', 'RecoveryPrepared')
    $validObservedOwnership = @($null, 'Unused', 'Owned', 'Unowned')
    $invalidBoolean = @($booleanProperties | Where-Object {
            $state.PSObject.Properties[$_].Value -isnot [bool]
        }).Count -gt 0
    $missingProperty = @($expectedProperties | Where-Object {
            $expectedPropertyName = $_
            @($actualProperties.Name | Where-Object {
                    $_ -ceq $expectedPropertyName
                }).Count -ne 1
        }).Count -gt 0
    $invalidTargetInteger =
        ($state.target.PSObject.Properties['publicPort'].Value -isnot [int] -and
            $state.target.PSObject.Properties['publicPort'].Value -isnot [long]) -or
        ($state.target.PSObject.Properties['backendPort'].Value -isnot [int] -and
            $state.target.PSObject.Properties['backendPort'].Value -isnot [long])
    $invalidOptionalPort = @(
        $state.originalMainFirewallPort
        $state.originalTemporaryFirewallPort
    ) | Where-Object {
        $null -ne $_ -and $_ -isnot [int] -and $_ -isnot [long]
    }
    $previousPropertiesValid = $null -eq $state.previous
    if ($null -ne $state.previous) {
        $previousProperties = @($state.previous.PSObject.Properties)
        $previousPropertiesValid = $previousProperties.Count -eq
            $validTargetProperties.Count -and
            @($previousProperties.Name | Where-Object {
                    $_ -cnotin $validTargetProperties
                }).Count -eq 0 -and
            ($state.previous.PSObject.Properties['publicPort'].Value -is [int] -or
                $state.previous.PSObject.Properties['publicPort'].Value -is [long]) -and
            ($state.previous.PSObject.Properties['backendPort'].Value -is [int] -or
                $state.previous.PSObject.Properties['backendPort'].Value -is [long]) -and
            $state.previous.PSObject.Properties['tailscalePath'].Value -is [string]
    }
    if ($actualProperties.Count -ne $expectedProperties.Count -or
        @($actualProperties.Name | Where-Object { $_ -cnotin $expectedProperties }).Count -gt 0 -or
        $missingProperty -or
        $targetProperties.Count -ne $validTargetProperties.Count -or
        @($targetProperties.Name | Where-Object { $_ -cnotin $validTargetProperties }).Count -gt 0 -or
        $invalidTargetInteger -or
        $state.target.PSObject.Properties['tailscalePath'].Value -isnot [string] -or
        -not $previousPropertiesValid -or
        @($invalidOptionalPort).Count -gt 0 -or
        $invalidBoolean -or
        ($state.PSObject.Properties['schemaVersion'].Value -isnot [int] -and
            $state.PSObject.Properties['schemaVersion'].Value -isnot [long]) -or
        [int]$state.schemaVersion -ne 1 -or
        $state.PSObject.Properties['initiator'].Value -isnot [string] -or
        [string]$state.initiator -cnotin @('Interactive', 'Installer') -or
        $state.PSObject.Properties['phase'].Value -isnot [string] -or
        [string]$state.phase -cnotin $validPhase -or
        ($null -ne $state.observedTargetRouteOwnership -and
            $state.PSObject.Properties['observedTargetRouteOwnership'].Value -isnot [string]) -or
        ($null -ne $state.observedPreviousRouteOwnership -and
            $state.PSObject.Properties['observedPreviousRouteOwnership'].Value -isnot [string]) -or
        $state.observedTargetRouteOwnership -cnotin $validObservedOwnership -or
        $state.observedPreviousRouteOwnership -cnotin $validObservedOwnership -or
        $state.PSObject.Properties['transactionId'].Value -isnot [string] -or
        $state.PSObject.Properties['ownerSid'].Value -isnot [string] -or
        $state.PSObject.Properties['dataRoot'].Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$state.transactionId) -or
        ([guid][string]$state.transactionId) -eq [guid]::Empty -or
        -not [string]::Equals([string]$state.ownerSid, $OwnerSid, [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$state.dataRoot).TrimEnd('\'),
            [IO.Path]::GetFullPath($ExpectedDataRoot).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase) -or
        [int]$state.target.publicPort -lt 1024 -or
        [int]$state.target.publicPort -gt 65535 -or
        [int]$state.target.backendPort -lt 1024 -or
        [int]$state.target.backendPort -gt 65535 -or
        [int]$state.target.publicPort -eq [int]$state.target.backendPort -or
        [string]::IsNullOrWhiteSpace([string]$state.target.tailscalePath) -or
        [string]$state.target.tailscalePath -match '["\r\n]' -or
        -not (Test-EverVigilPathFullyQualified -Path ([string]$state.target.tailscalePath))) {
        throw "The pending system journal identity is invalid: $resolvedPath"
    }
    return $state
}

function Assert-NoInstallTransactionAfterElevation {
    foreach ($recognizedDataRoot in $RecognizedDataRoots) {
        $candidate = Join-Path `
            $recognizedDataRoot `
            $script:LegacyCompatibilityDataTransactionJournalFileName
        if (Test-Path -LiteralPath $candidate) {
            throw "An install transaction appeared while the elevated helper owned the system mutex: $candidate"
        }
    }
}

function Invoke-UninstallSystemBrokerOperation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Recover', 'UninstallCleanup')]
        [string]$Operation,
        [Parameter(Mandatory)][guid]$TransactionId,
        [Parameter(Mandatory)][ValidateSet('Interactive', 'Installer')]
        [string]$Initiator
    )

    $brokerResponse = $null
    $invocationError = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (-not $script:transactionLockTaken) {
            throw 'The uninstall transaction mutex is not held before broker invocation.'
        }
        $transactionMutex.ReleaseMutex()
        $script:transactionLockTaken = $false
        try {
            $brokerResponse = Invoke-EverVigilSystemBroker `
                -Operation $Operation `
                -TransactionId $TransactionId `
                -Initiator $Initiator
            $invocationError = $null
        } catch {
            $invocationError = $_
        } finally {
            try {
                $script:transactionLockTaken = $transactionMutex.WaitOne(
                    [TimeSpan]::FromMinutes(10))
            } catch [Threading.AbandonedMutexException] {
                $script:transactionLockTaken = $true
            }
            if (-not $script:transactionLockTaken) {
                throw 'Uninstall could not reacquire the system transaction mutex after broker execution.'
            }
        }
        Assert-NoInstallTransactionAfterElevation
        if ($null -ne $brokerResponse) {
            break
        }
        if ($Operation -ne 'UninstallCleanup' -or $attempt -ge 2) {
            throw $invocationError
        }
        # A response can be lost after the protected retirement receipt is
        # durable. Retry the same transaction with a fresh one-shot nonce; the
        # canonical retired gate will only resume UninstallCleanup.
    }
    $expectedDispositions = if ($Operation -eq 'Recover') {
        @('RolledBack', 'NoChange')
    } else {
        @('Completed', 'NoChange', 'RetirementRequired')
    }
    if ([string]$brokerResponse.disposition -cnotin $expectedDispositions) {
        throw "The protected broker returned an unexpected $Operation disposition: $($brokerResponse.disposition)"
    }
    return $brokerResponse
}

function Get-ValidatedEverVigilProtectedBrokerRetirementState {
    param(
        [Parameter(Mandatory)][string]$ExpectedOwnerSid,
        [guid]$ExpectedTransactionId = [guid]::Empty
    )

    $paths = Get-EverVigilProtectedBrokerRetirementPaths
    if (-not (Test-Path -LiteralPath $paths.ProductRoot)) {
        return [pscustomobject]@{
            Status = 'Absent'
            Paths = $paths
            Receipt = $null
        }
    }
    if (-not (Test-Path -LiteralPath $paths.ProductRoot -PathType Container)) {
        throw "The protected broker product root is not a directory: $($paths.ProductRoot)"
    }

    $retirementReceiptExists = Test-Path `
        -LiteralPath $paths.RetirementReceiptPath `
        -PathType Leaf
    $canonicalExists = Test-Path `
        -LiteralPath $paths.CanonicalPath `
        -PathType Leaf
    if (-not $retirementReceiptExists -and $canonicalExists) {
        if (-not (Test-EverVigilProtectedBrokerInstallation `
                -BrokerPath $paths.CanonicalPath)) {
            throw 'The active protected broker installation is invalid.'
        }
        return [pscustomobject]@{
            Status = 'Active'
            Paths = $paths
            Receipt = $null
        }
    }

    $allowStandardAcl = $retirementReceiptExists -and $canonicalExists
    $allDeleteOnly = $true
    function Test-AcceptableRetirementAcl {
        param(
            [Parameter(Mandatory)][string]$Path,
            [switch]$Directory
        )

        if (Test-EverVigilProtectedBrokerRetirementAcl `
                -Path $Path `
                -OwnerSid $ExpectedOwnerSid `
                -Directory:$Directory) {
            return $true
        }
        if ($allowStandardAcl -and
            (Test-EverVigilProtectedBrokerAcl `
                -Path $Path `
                -Directory:$Directory)) {
            $script:retirementStandardAclObserved = $true
            return $true
        }
        return $false
    }
    function Assert-ExactRetirementDirectoryEntries {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [string[]]$AllowedName
        )

        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        if (-not (Test-AcceptableRetirementAcl -Path $Path -Directory)) {
            throw "A protected broker retirement directory has an invalid ACL or is redirected: $Path"
        }
        if (-not (Test-EverVigilProtectedBrokerRetirementAcl `
                -Path $Path `
                -OwnerSid $ExpectedOwnerSid `
                -Directory)) {
            $script:retirementStandardAclObserved = $true
        }
        foreach ($entry in @(Get-ChildItem `
                -LiteralPath $Path `
                -Force `
                -ErrorAction Stop)) {
            if ($entry.Name -cnotin $AllowedName) {
                throw "Protected broker retirement contains an unknown entry: $($entry.FullName)"
            }
        }
    }

    $script:retirementStandardAclObserved = $false
    try {
        Assert-ExactRetirementDirectoryEntries `
            -Path $paths.ProductRoot `
            -AllowedName @('Broker')
        Assert-ExactRetirementDirectoryEntries `
            -Path $paths.BrokerRoot `
            -AllowedName @('State', '2.1.1')
        Assert-ExactRetirementDirectoryEntries `
            -Path $paths.VersionRoot `
            -AllowedName @(
                'EverVigil.Broker.exe'
                'installation.json'
                'retirement.json'
            )

        if (Test-Path -LiteralPath $paths.StateRoot) {
            if (-not $allowStandardAcl) {
                Assert-ExactRetirementDirectoryEntries `
                    -Path $paths.StateRoot `
                    -AllowedName @()
            } else {
                Assert-ExactRetirementDirectoryEntries `
                    -Path $paths.StateRoot `
                    -AllowedName @($ExpectedOwnerSid)
                $ownerStateRoot = Join-Path $paths.StateRoot $ExpectedOwnerSid
                if (Test-Path -LiteralPath $ownerStateRoot) {
                    if (-not (Test-EverVigilProtectedBrokerAcl `
                            -Path $ownerStateRoot `
                            -Directory)) {
                        throw 'The interrupted protected owner-state directory is invalid.'
                    }
                    foreach ($ownerStateEntry in @(Get-ChildItem `
                            -LiteralPath $ownerStateRoot `
                            -Force `
                            -ErrorAction Stop)) {
                        $knownStableState = $ownerStateEntry.Name -ceq
                            'last-system-transaction.json'
                        $knownTemporaryState = $ownerStateEntry.Name -cmatch
                            '\A(?:pending-system-configuration|applied-system-configuration|last-system-transaction)\.json\.[0-9a-f]{32}\.tmp\z'
                        if ($ownerStateEntry.PSIsContainer -or
                            ($ownerStateEntry.Attributes -band
                                [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                            (-not $knownStableState -and -not $knownTemporaryState) -or
                            -not (Test-EverVigilProtectedBrokerAcl `
                                -Path $ownerStateEntry.FullName)) {
                            throw "Interrupted protected owner state contains an unknown entry: $($ownerStateEntry.FullName)"
                        }
                    }
                }
                $script:retirementStandardAclObserved = $true
            }
        }

        if (-not $retirementReceiptExists) {
            foreach ($unexpectedRetirementFile in @(
                    $paths.CanonicalPath,
                    $paths.InstallationReceiptPath)) {
                if (Test-Path -LiteralPath $unexpectedRetirementFile) {
                    throw "Protected broker retirement is missing its durable receipt: $unexpectedRetirementFile"
                }
            }
            return [pscustomobject]@{
                Status = 'DirectoriesOnly'
                Paths = $paths
                Receipt = $null
            }
        }

        $receipt = Read-EverVigilProtectedBrokerRetirementReceipt `
            -Path $paths.RetirementReceiptPath `
            -OwnerSid $ExpectedOwnerSid `
            -AllowStandardAcl:$allowStandardAcl
        if ($ExpectedTransactionId -ne [guid]::Empty -and
            -not [string]::Equals(
                ([guid][string]$receipt.transactionId).ToString('D'),
                $ExpectedTransactionId.ToString('D'),
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The protected broker retirement receipt transaction does not match the authenticated response.'
        }
        if (-not (Test-EverVigilProtectedBrokerRetirementAcl `
                -Path $paths.RetirementReceiptPath `
                -OwnerSid $ExpectedOwnerSid)) {
            $script:retirementStandardAclObserved = $true
        }
        $expectedLength = [long]$receipt.length
        $expectedSha256 = [string]$receipt.sha256
        if ($canonicalExists) {
            if (-not (Test-AcceptableRetirementAcl -Path $paths.CanonicalPath)) {
                throw 'The retiring canonical broker ACL is invalid.'
            }
            if (-not (Test-EverVigilProtectedBrokerRetirementAcl `
                    -Path $paths.CanonicalPath `
                    -OwnerSid $ExpectedOwnerSid)) {
                $script:retirementStandardAclObserved = $true
            }
            $canonicalInfo = Get-Item `
                -LiteralPath $paths.CanonicalPath `
                -Force `
                -ErrorAction Stop
            $canonicalSha256 = (Get-FileHash `
                    -LiteralPath $paths.CanonicalPath `
                    -Algorithm SHA256 `
                    -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($canonicalInfo.Length -ne $expectedLength -or
                -not [string]::Equals(
                    $canonicalSha256,
                    $expectedSha256,
                    [StringComparison]::Ordinal)) {
                throw 'The retiring canonical broker does not match its protected retirement receipt.'
            }
        }

        if (Test-Path -LiteralPath $paths.InstallationReceiptPath -PathType Leaf) {
            if (-not (Test-AcceptableRetirementAcl `
                    -Path $paths.InstallationReceiptPath)) {
                throw 'The retiring broker installation receipt ACL is invalid.'
            }
            if (-not (Test-EverVigilProtectedBrokerRetirementAcl `
                    -Path $paths.InstallationReceiptPath `
                    -OwnerSid $ExpectedOwnerSid)) {
                $script:retirementStandardAclObserved = $true
            }
            $installationReceiptInfo = Get-Item `
                -LiteralPath $paths.InstallationReceiptPath `
                -Force `
                -ErrorAction Stop
            if ($installationReceiptInfo.Length -lt 1 -or
                $installationReceiptInfo.Length -gt 4096) {
                throw 'The retiring broker installation receipt size is invalid.'
            }
            try {
                $installationReceiptJson = [Text.UTF8Encoding]::new(
                    $false,
                    $true).GetString([IO.File]::ReadAllBytes(
                        $paths.InstallationReceiptPath))
            } catch {
                throw 'The retiring broker installation receipt is not strict UTF-8.'
            }
            if (-not (Test-EverVigilProtectedBrokerReceipt `
                    -Json $installationReceiptJson `
                    -ExecutableLength $expectedLength `
                    -ExecutableSha256 $expectedSha256)) {
                throw 'The retiring broker installation receipt does not match the retirement receipt.'
            }
        } elseif ($canonicalExists) {
            throw 'The retiring canonical broker exists without its installation receipt.'
        }

        $allDeleteOnly = -not $script:retirementStandardAclObserved -and
            -not (Test-Path -LiteralPath $paths.StateRoot)
        return [pscustomobject]@{
            Status = if ($allDeleteOnly) { 'Prepared' } else { 'NeedsBrokerResume' }
            Paths = $paths
            Receipt = $receipt
        }
    } finally {
        Remove-Variable `
            -Name retirementStandardAclObserved `
            -Scope Script `
            -ErrorAction SilentlyContinue
    }
}

function Complete-EverVigilProtectedBrokerRetirement {
    param([Parameter(Mandatory)][string]$ExpectedOwnerSid)

    $retirement = Get-ValidatedEverVigilProtectedBrokerRetirementState `
        -ExpectedOwnerSid $ExpectedOwnerSid
    if ($retirement.Status -eq 'Active') {
        throw 'The protected broker did not enter its authenticated retirement gate.'
    }
    if ($retirement.Status -eq 'Absent') {
        return
    }

    $paths = $retirement.Paths
    if ($retirement.Status -eq 'Prepared') {
        foreach ($retirementFile in @(
                $paths.CanonicalPath,
                $paths.InstallationReceiptPath,
                $paths.RetirementReceiptPath)) {
            if (-not (Test-Path -LiteralPath $retirementFile)) {
                continue
            }
            if (-not (Test-EverVigilProtectedBrokerRetirementAcl `
                    -Path $retirementFile `
                    -OwnerSid $ExpectedOwnerSid)) {
                throw "Refusing to delete a protected retirement file with an invalid ACL: $retirementFile"
            }
            try {
                [IO.File]::Delete($retirementFile)
            } catch {
                throw "Protected broker retirement is pending a Windows restart; reboot and run uninstall again. Residue: $retirementFile"
            }
            if (Test-Path -LiteralPath $retirementFile) {
                throw "Protected broker retirement is pending a Windows restart; reboot and run uninstall again. Residue: $retirementFile"
            }
        }
    }

    $directoryState = Get-ValidatedEverVigilProtectedBrokerRetirementState `
        -ExpectedOwnerSid $ExpectedOwnerSid
    if ($directoryState.Status -eq 'Active' -or
        $directoryState.Status -eq 'Prepared') {
        throw 'Protected broker retirement files remained after fixed-path deletion.'
    }
    if ($directoryState.Status -eq 'Absent') {
        return
    }
    foreach ($retirementDirectory in @(
            $paths.StateRoot,
            $paths.VersionRoot,
            $paths.BrokerRoot,
            $paths.ProductRoot)) {
        if (-not (Test-Path -LiteralPath $retirementDirectory)) {
            continue
        }
        if (-not (Test-EverVigilProtectedBrokerRetirementAcl `
                -Path $retirementDirectory `
                -OwnerSid $ExpectedOwnerSid `
                -Directory)) {
            throw "Refusing to delete a protected retirement directory with an invalid ACL: $retirementDirectory"
        }
        if (@(Get-ChildItem `
                -LiteralPath $retirementDirectory `
                -Force `
                -ErrorAction Stop).Count -ne 0) {
            throw "Refusing to delete a non-empty protected retirement directory: $retirementDirectory"
        }
        try {
            [IO.Directory]::Delete($retirementDirectory, $false)
        } catch {
            throw "Protected broker directory retirement is pending a Windows restart; reboot and run uninstall again. Residue: $retirementDirectory"
        }
        if (Test-Path -LiteralPath $retirementDirectory) {
            throw "Protected broker directory retirement is pending a Windows restart; reboot and run uninstall again. Residue: $retirementDirectory"
        }
    }
    if (Test-Path -LiteralPath $paths.ProductRoot) {
        throw 'The last-user protected broker product root remained after retirement.'
    }
}

function Get-EverVigilFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The transaction residue must be a regular file: $Path"
    }

    $stream = [IO.FileStream]::new(
        $item.FullName,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return -join @($algorithm.ComputeHash($stream) | ForEach-Object {
                $_.ToString('x2')
            })
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Assert-EverVigilRegularFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The $Description is not a regular file: $Path"
    }
}

function Assert-EverVigilGeneratedTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    $expected = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = Get-Item -LiteralPath $expected -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or
        ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The $Description is not a regular directory: $expected"
    }
    $resolved = [IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $expected -ErrorAction Stop).Path).TrimEnd('\')
    if (-not [string]::Equals(
            $resolved,
            $expected,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The $Description resolves unexpectedly: $resolved"
    }
    $entries = @(
        $root
        Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    )
    if (@($entries | Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            }).Count -gt 0) {
        throw "The $Description contains a reparse point: $resolved"
    }
}

function Assert-EverVigilTemporaryPublishTree {
    param([Parameter(Mandatory)][string]$Path)

    Assert-EverVigilGeneratedTree `
        -Path $Path `
        -Description 'installer temporary publish root'
    $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    if ($entries.Count -ne 1 -or
        $entries[0].PSIsContainer -or
        ($entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $entries[0].Name -cne 'EverVigil.exe') {
        throw "The installer temporary publish root does not contain exactly one regular EverVigil.exe: $Path"
    }
    $productName = [string]$entries[0].VersionInfo.ProductName
    if (-not [string]::Equals(
            $productName,
            'EverVigil',
            [StringComparison]::Ordinal)) {
        throw "The installer temporary publish executable has an unexpected product identity: $($entries[0].FullName)"
    }
}

function Test-EverVigilRecoveryFileName {
    param([Parameter(Mandatory)][string]$Name)

    $applicationDataNames = @(
        $script:LegacyCompatibilityDataSettingsFileName
        $script:LegacyCompatibilityDataProtectedTokenFileName
        $script:LegacyCompatibilityDataAppliedSystemConfigurationFileName
        $script:LegacyCompatibilityDataSystemConfigurationRequiredFileName
        $script:LegacyCompatibilityDataDiagnosticLoggingMarkerFileName
    ) | Select-Object -Unique
    if (@($applicationDataNames | Where-Object {
                $Name -ceq "$_.rollback"
            }).Count -gt 0) {
        return $true
    }
    return $Name -cmatch `
        '\Asettings\.json\.invalid-\d{8}-\d{6}(?:-[0-9a-f]{32})?\.rollback\z' -or
        $Name -cmatch `
        '\Atoken\.dat\.invalid-\d{8}-\d{6}-[0-9a-f]{32}\.rollback\z'
}

function Test-EverVigilRestoreTemporaryFileName {
    param([Parameter(Mandatory)][string]$Name)

    if ($Name -cnotmatch '\A(?<source>.+)\.restore-[0-9a-f]{32}\.tmp\z') {
        return $false
    }
    $sourceName = [string]$Matches.source
    $applicationDataNames = @(
        $script:LegacyCompatibilityDataSettingsFileName
        $script:LegacyCompatibilityDataProtectedTokenFileName
        $script:LegacyCompatibilityDataAppliedSystemConfigurationFileName
        $script:LegacyCompatibilityDataSystemConfigurationRequiredFileName
        $script:LegacyCompatibilityDataDiagnosticLoggingMarkerFileName
    ) | Select-Object -Unique
    return $sourceName -cin $applicationDataNames -or
        $sourceName -cmatch `
        '\Asettings\.json\.invalid-\d{8}-\d{6}(?:-[0-9a-f]{32})?\z' -or
        $sourceName -cmatch `
        '\Atoken\.dat\.invalid-\d{8}-\d{6}-[0-9a-f]{32}\z'
}

function Assert-EverVigilRecoveryTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DataRoot,
        [switch]$PreserveData
    )

    Assert-EverVigilGeneratedTree `
        -Path $Path `
        -Description 'installer transaction-recovery root'
    foreach ($transactionRoot in @(
            Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
        if (-not $transactionRoot.PSIsContainer -or
            ($transactionRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $transactionRoot.Name -cnotmatch '\A[0-9a-f]{32}\z') {
            throw "The transaction-recovery root contains an unexpected entry: $($transactionRoot.FullName)"
        }
        foreach ($entry in @(
                Get-ChildItem -LiteralPath $transactionRoot.FullName -Force -ErrorAction Stop)) {
            if ($entry.PSIsContainer -or
                ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($entry.Name -notin @('legacy-task.xml', 'system.log') -and
                    -not (Test-EverVigilRecoveryFileName -Name $entry.Name))) {
                throw "The transaction-recovery directory contains an unexpected entry: $($entry.FullName)"
            }
            if ($PreserveData -and (Test-EverVigilRecoveryFileName -Name $entry.Name)) {
                $sourceName = $entry.Name.Substring(0, $entry.Name.Length - '.rollback'.Length)
                $sourcePath = Join-Path $DataRoot $sourceName
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    throw "Refusing to discard an unconfirmed rollback copy whose source is missing: $($entry.FullName)"
                }
                Assert-EverVigilRegularFile `
                    -Path $sourcePath `
                    -Description 'preserved application-data source'
                $sourceHash = Get-EverVigilFileSha256 -Path $sourcePath
                $rollbackHash = Get-EverVigilFileSha256 -Path $entry.FullName
                if (-not [string]::Equals(
                        $sourceHash,
                        $rollbackHash,
                        [StringComparison]::Ordinal)) {
                    throw "Refusing to discard an unconfirmed rollback copy that differs from preserved data: $($entry.FullName)"
                }
            }
        }
    }
}

function Get-EverVigilRuntimeAtomicTemporaryInfo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DataRoot
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not (Test-EverVigilCurrentOwnerFileAcl -Path $item.FullName)) {
        throw "A runtime atomic temporary is not a current-owner regular file: $($item.FullName)"
    }
    $name = $item.Name
    $match = [regex]::Match(
        $name,
        '\A(?<stable>settings\.json|token\.dat|applied-system-configuration\.json|pending-system-configuration\.json)\.(?<id>[0-9a-f]{32})\.tmp\z',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        throw "The runtime atomic temporary name is not recognized: $name"
    }
    $stableName = $match.Groups['stable'].Value
    $maximumLength = if ($stableName -ceq 'settings.json') {
        1048576
    } elseif ($stableName -ceq 'token.dat') {
        16384
    } else {
        65536
    }
    if ($item.Length -lt 1 -or $item.Length -gt $maximumLength) {
        throw "The runtime atomic temporary size is invalid: $($item.FullName)"
    }

    if ($stableName -ceq 'token.dat') {
        $protectedBytes = [IO.File]::ReadAllBytes($item.FullName)
        $tokenEvidenceValid = $false
        foreach ($entropyContext in @(
                'EverVigil/token/v1',
                $script:LegacyCompatibilityCryptographyDpapiEntropyContext)) {
            try {
                $entropy = [Security.Cryptography.SHA256]::HashData(
                    [Text.UTF8Encoding]::new($false).GetBytes($entropyContext))
                $tokenBytes = [Security.Cryptography.ProtectedData]::Unprotect(
                    $protectedBytes,
                    $entropy,
                    [Security.Cryptography.DataProtectionScope]::CurrentUser)
                $token = [Text.Encoding]::ASCII.GetString($tokenBytes)
                if ($token -cmatch '\A[0-9a-f]{32}\z' -and
                    $tokenBytes.Length -eq 32) {
                    $tokenEvidenceValid = $true
                    break
                }
            } catch [Security.Cryptography.CryptographicException] {
                # Try the other fixed application-specific entropy context.
            }
        }
        if (-not $tokenEvidenceValid) {
            throw "The token atomic temporary is not valid CurrentUser DPAPI data: $($item.FullName)"
        }
        return [pscustomobject]@{
            Kind = 'Token'
            Path = $item.FullName
            TransactionId = $null
        }
    }

    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString(
            [IO.File]::ReadAllBytes($item.FullName))
        $jsonDocument = [Text.Json.JsonDocument]::Parse($json)
        try {
            if ($jsonDocument.RootElement.ValueKind -ne
                [Text.Json.JsonValueKind]::Object) {
                throw 'The JSON root must be an object.'
            }
            $jsonPropertyNames = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal)
            foreach ($jsonProperty in $jsonDocument.RootElement.EnumerateObject()) {
                if (-not $jsonPropertyNames.Add($jsonProperty.Name)) {
                    throw "The JSON object contains a duplicate property: $($jsonProperty.Name)"
                }
            }
        } finally {
            $jsonDocument.Dispose()
        }
        $document = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "A runtime atomic temporary is not strict UTF-8 JSON: $($item.FullName)"
    }
    if ($stableName -ceq 'pending-system-configuration.json') {
        $pending = Read-PendingSystemJournalForRecovery `
            -Path $item.FullName `
            -ExpectedDataRoot $DataRoot `
            -AllowAtomicTemporary
        return [pscustomobject]@{
            Kind = 'PendingSystem'
            Path = $item.FullName
            TransactionId = [guid][string]$pending.transactionId
            Initiator = [string]$pending.initiator
        }
    }
    if ($stableName -ceq 'applied-system-configuration.json') {
        $properties = @($document.PSObject.Properties)
        $expected = @('publicPort', 'backendPort', 'tailscalePath')
        if ($properties.Count -ne $expected.Count -or
            @($properties.Name | Where-Object { $_ -cnotin $expected }).Count -gt 0 -or
            ($document.PSObject.Properties['publicPort'].Value -isnot [int] -and
                $document.PSObject.Properties['publicPort'].Value -isnot [long]) -or
            ($document.PSObject.Properties['backendPort'].Value -isnot [int] -and
                $document.PSObject.Properties['backendPort'].Value -isnot [long]) -or
            $document.PSObject.Properties['tailscalePath'].Value -isnot [string] -or
            [int]$document.publicPort -lt 1024 -or
            [int]$document.publicPort -gt 65535 -or
            [int]$document.backendPort -lt 1024 -or
            [int]$document.backendPort -gt 65535 -or
            [int]$document.publicPort -eq [int]$document.backendPort -or
            -not (Test-EverVigilPathFullyQualified `
                -Path ([string]$document.tailscalePath))) {
            throw "The applied-system atomic temporary schema is invalid: $($item.FullName)"
        }
        return [pscustomobject]@{
            Kind = 'AppliedSystem'
            Path = $item.FullName
            TransactionId = $null
        }
    }

    $expectedSettingsProperties = @(
        'uiLanguage', 'displayName', 'publicPort', 'backendPort',
        'codexAppServerPort', 'projectDirectory', 'nodePath',
        'evenTerminalCliPath', 'codexPath', 'tailscalePath',
        'healthIntervalSeconds', 'providerCheckIntervalSeconds',
        'publicCheckIntervalSeconds', 'startupTimeoutSeconds',
        'stableRunSeconds', 'failureThreshold', 'logFileSizeMb',
        'logFileCopies', 'clipboardClearSeconds', 'diagnosticLogging',
        'autoStartService')
    $settingsProperties = @($document.PSObject.Properties)
    $isLegacySettingsSchema =
        $settingsProperties.Count -eq ($expectedSettingsProperties.Count + 1) -and
        @($settingsProperties.Name | Where-Object {
                $_ -cnotin ($expectedSettingsProperties + 'publicHost')
            }).Count -eq 0 -and
        @($settingsProperties.Name | Where-Object { $_ -ceq 'publicHost' }).Count -eq 1
    $isCurrentSettingsSchema =
        $settingsProperties.Count -eq $expectedSettingsProperties.Count -and
        @($settingsProperties.Name | Where-Object {
                $_ -cnotin $expectedSettingsProperties
            }).Count -eq 0
    $stringSettings = @(
        'uiLanguage', 'displayName', 'projectDirectory', 'nodePath',
        'evenTerminalCliPath', 'codexPath', 'tailscalePath')
    $integerSettings = @(
        'publicPort', 'backendPort', 'codexAppServerPort',
        'healthIntervalSeconds', 'providerCheckIntervalSeconds',
        'publicCheckIntervalSeconds', 'startupTimeoutSeconds',
        'stableRunSeconds', 'failureThreshold', 'logFileSizeMb',
        'logFileCopies', 'clipboardClearSeconds')
    $legacyPublicHostValid = $true
    if ($isLegacySettingsSchema) {
        $legacyPublicHostProperty = $document.PSObject.Properties['publicHost']
        $legacyPublicHostValid = $legacyPublicHostProperty.Value -is [string]
        if ($legacyPublicHostValid) {
            $legacyPublicHostValue = [string]$legacyPublicHostProperty.Value
            $legacyPublicHost = $legacyPublicHostValue
            if ($legacyPublicHost.Length -ge 2 -and
                $legacyPublicHost[0] -eq '[' -and
                $legacyPublicHost[$legacyPublicHost.Length - 1] -eq ']') {
                $legacyPublicHost = $legacyPublicHost.Substring(
                    1,
                    $legacyPublicHost.Length - 2)
            }
            $legacyPublicHostValid =
                $legacyPublicHostValue.Length -le 255 -and
                $legacyPublicHost.Length -le 253 -and
                -not [string]::IsNullOrWhiteSpace($legacyPublicHost) -and
                -not $legacyPublicHostValue.Contains(
                    '://',
                    [StringComparison]::Ordinal) -and
                -not $legacyPublicHostValue.Contains('/') -and
                -not ($legacyPublicHostValue -match '\s') -and
                [Uri]::CheckHostName($legacyPublicHost) -ne
                    [UriHostNameType]::Unknown
        }
    }
    if ((-not $isCurrentSettingsSchema -and -not $isLegacySettingsSchema) -or
        -not $legacyPublicHostValid -or
        @($stringSettings | Where-Object {
                $document.PSObject.Properties[$_].Value -isnot [string]
            }).Count -gt 0 -or
        @($integerSettings | Where-Object {
                $document.PSObject.Properties[$_].Value -isnot [int] -and
                $document.PSObject.Properties[$_].Value -isnot [long]
            }).Count -gt 0 -or
        $document.PSObject.Properties['diagnosticLogging'].Value -isnot [bool] -or
        $document.PSObject.Properties['autoStartService'].Value -isnot [bool] -or
        [string]$document.uiLanguage -cnotin @('system', 'en', 'ja') -or
        [string]::IsNullOrWhiteSpace([string]$document.displayName) -or
        ([string]$document.displayName).Length -gt 64 -or
        @($stringSettings | Where-Object {
                $_ -notin @('uiLanguage', 'displayName') -and
                -not (Test-EverVigilPathFullyQualified `
                    -Path ([string]$document.$_))
            }).Count -gt 0) {
        throw "The settings atomic temporary schema is invalid: $($item.FullName)"
    }
    return [pscustomobject]@{
        Kind = 'Settings'
        Path = $item.FullName
        TransactionId = $null
    }
}

function Get-EverVigilTransactionResiduePaths {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$PreserveData
    )

    $result = [Collections.Generic.List[string]]::new()
    $expectedRoot = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $expectedRoot -PathType Container)) {
        return @()
    }
    $rootItem = Get-Item -LiteralPath $expectedRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing transaction cleanup through a data-root reparse point: $expectedRoot"
    }

    $journalTemporaryPattern = '\A' +
        [regex]::Escape($script:LegacyCompatibilityDataTransactionJournalFileName) +
        '\.new-[0-9a-f]{32}\z'
    $publishDirectoryPattern = '\A' +
        [regex]::Escape($script:LegacyCompatibilityDataInstallerPublishDirectoryPrefix) +
        '[0-9a-f]{32}\z'
    $runtimeAtomicTemporaryPattern =
        '\A(?:settings\.json|token\.dat|applied-system-configuration\.json|pending-system-configuration\.json)\.[0-9a-f]{32}\.tmp\z'
    foreach ($entry in @(
            Get-ChildItem -LiteralPath $expectedRoot -Force -ErrorAction Stop)) {
        $isRecoveryRoot = $entry.Name -ceq
            $script:LegacyCompatibilityDataTransactionRecoveryDirectoryName
        $isPublishRoot = $entry.Name -cmatch $publishDirectoryPattern
        $isJournalTemporary = $entry.Name -cmatch $journalTemporaryPattern
        $isRestoreTemporary = Test-EverVigilRestoreTemporaryFileName -Name $entry.Name
        $isRuntimeAtomicTemporary = $entry.Name -cmatch
            $runtimeAtomicTemporaryPattern
        $isAtomicTemporary = $isJournalTemporary -or
            $isRestoreTemporary -or
            $isRuntimeAtomicTemporary
        if ($isJournalTemporary) {
            throw "A possible atomic install-recovery journal is pending at '$($entry.FullName)'. Rerun the latest setup before uninstalling."
        }
        if ($entry.PSIsContainer) {
            if ($isRecoveryRoot) {
                Assert-EverVigilRecoveryTree `
                    -Path $entry.FullName `
                    -DataRoot $expectedRoot `
                    -PreserveData:$PreserveData
                $result.Add($entry.FullName)
            } elseif ($isPublishRoot) {
                Assert-EverVigilTemporaryPublishTree -Path $entry.FullName
                $result.Add($entry.FullName)
            } elseif ($isAtomicTemporary) {
                throw "An installer atomic temporary path is unexpectedly a directory: $($entry.FullName)"
            }
            continue
        }
        if ($isRecoveryRoot -or $isPublishRoot) {
            throw "An installer transaction directory is unexpectedly a file: $($entry.FullName)"
        }
        if ($isRuntimeAtomicTemporary) {
            [void](Get-EverVigilRuntimeAtomicTemporaryInfo `
                    -Path $entry.FullName `
                    -DataRoot $expectedRoot)
            $result.Add($entry.FullName)
            continue
        }
        if ($isRestoreTemporary) {
            Assert-EverVigilRegularFile `
                -Path $entry.FullName `
                -Description 'installer atomic temporary file'
            if ($PreserveData -and $isRestoreTemporary) {
                [void]($entry.Name -cmatch '\A(?<source>.+)\.restore-[0-9a-f]{32}\.tmp\z')
                $sourcePath = Join-Path $expectedRoot ([string]$Matches.source)
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    throw "Refusing to discard an unconfirmed restore temporary file whose source is missing: $($entry.FullName)"
                }
                Assert-EverVigilRegularFile `
                    -Path $sourcePath `
                    -Description 'preserved application-data source'
                $sourceHash = Get-EverVigilFileSha256 -Path $sourcePath
                $temporaryHash = Get-EverVigilFileSha256 -Path $entry.FullName
                if (-not [string]::Equals(
                        $sourceHash,
                        $temporaryHash,
                        [StringComparison]::Ordinal)) {
                    throw "Refusing to discard an unconfirmed restore temporary file that differs from preserved data: $($entry.FullName)"
                }
            }
            $result.Add($entry.FullName)
            continue
        }
        if ($entry.Name -cmatch '\.tmp\z') {
            throw "An unknown temporary file is present in the application data root: $($entry.FullName)"
        }
    }
    return @($result)
}

function Remove-EverVigilTransactionResidue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$PreserveData
    )

    $residuePaths = @(Get-EverVigilTransactionResiduePaths `
            -Path $Path `
            -PreserveData:$PreserveData)
    $recoveredPendingSet = Get-Variable `
        -Name recoveredPendingAtomicSystemPaths `
        -Scope Script `
        -ValueOnly `
        -ErrorAction SilentlyContinue
    foreach ($residuePath in $residuePaths) {
        if ((Split-Path -Leaf $residuePath) -cmatch
                '\Apending-system-configuration\.json\.[0-9a-f]{32}\.tmp\z' -and
            ($null -eq $recoveredPendingSet -or
                -not $recoveredPendingSet.Contains(
                    [IO.Path]::GetFullPath($residuePath)))) {
            throw "An atomic pending system journal was not authenticated with the protected broker: $residuePath"
        }
        Remove-Item -LiteralPath $residuePath -Recurse -Force -ErrorAction Stop
    }
    foreach ($residuePath in $residuePaths) {
        if (Test-Path -LiteralPath $residuePath) {
            throw "Installer transaction residue remained after cleanup: $residuePath"
        }
    }
}

function Get-EverVigilSiblingTransactionResiduePaths {
    param(
        [Parameter(Mandatory)][string]$OriginalInstallRoot,
        [Parameter(Mandatory)][string]$ActiveInstallRoot,
        [Parameter(Mandatory)]
        [ValidateSet('staging', 'backup', 'relocated')]
        [string[]]$AllowedKind,
        [switch]$AllowActiveInstallRootInCurrentTemp
    )

    $originalRoot = [IO.Path]::GetFullPath($OriginalInstallRoot).TrimEnd('\')
    $activeRoot = [IO.Path]::GetFullPath($ActiveInstallRoot).TrimEnd('\')
    $parent = Split-Path -Parent $originalRoot
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        return @()
    }
    $baseName = [IO.Path]::GetFileName($originalRoot)
    $pattern = '\A' + [regex]::Escape($baseName) +
        '\.(?<kind>staging|backup|relocated)-[0-9a-f]{32}\z'
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($entry in @(
            Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop)) {
        if ($entry.Name -cnotmatch $pattern) {
            continue
        }
        $kind = [string]$Matches.kind
        if ($kind -notin $AllowedKind) {
            continue
        }
        $candidates.Add([pscustomobject]@{
                Entry = $entry
                Kind = $kind
            })
    }
    if ($candidates.Count -eq 0) {
        return @()
    }
    if (-not (Test-Path -LiteralPath $activeRoot -PathType Container)) {
        throw "Refusing to discard installer work trees without a verified active installation: $activeRoot"
    }
    Assert-OwnedInstallRoot `
        -Path $activeRoot `
        -AllowLegacyKnownLayout `
        -AllowCurrentTempTree:$AllowActiveInstallRootInCurrentTemp

    $result = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        $entry = $candidate.Entry
        $kind = [string]$candidate.Kind
        Assert-EverVigilGeneratedTree `
            -Path $entry.FullName `
            -Description "installer $kind work tree"
        if ($kind -eq 'staging') {
            if (-not (Test-EverVigilKnownLayout `
                        -Path $entry.FullName `
                        -AllowCurrentTempTree)) {
                throw "Refusing to remove an incomplete or invalid staging tree without its durable transaction journal: $($entry.FullName)"
            }
            Assert-OwnedInstallBackup `
                -Path $entry.FullName `
                -OriginalInstallRoot $originalRoot `
                -AllowCurrentTempTree
            $result.Add($entry.FullName)
            continue
        }
        if ($kind -eq 'backup' -and
            @(Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction Stop).Count -eq 0) {
            $result.Add($entry.FullName)
            continue
        }
        if ($kind -in @('backup', 'relocated')) {
            Assert-OwnedInstallBackup `
                -Path $entry.FullName `
                -OriginalInstallRoot $originalRoot `
                -AllowCurrentTempTree
        }
        $result.Add($entry.FullName)
    }
    return @($result)
}

function Remove-EverVigilSiblingTransactionResidue {
    param(
        [Parameter(Mandatory)][object[]]$Specification,
        [Parameter(Mandatory)][string]$ActiveInstallRoot,
        [switch]$AllowActiveInstallRootInCurrentTemp
    )

    $residuePaths = [Collections.Generic.List[string]]::new()
    foreach ($specificationItem in $Specification) {
        foreach ($residuePath in @(Get-EverVigilSiblingTransactionResiduePaths `
                -OriginalInstallRoot ([string]$specificationItem.OriginalInstallRoot) `
                -ActiveInstallRoot $ActiveInstallRoot `
                -AllowedKind @($specificationItem.AllowedKind) `
                -AllowActiveInstallRootInCurrentTemp:$AllowActiveInstallRootInCurrentTemp)) {
            if ($residuePath -notin $residuePaths) {
                $residuePaths.Add($residuePath)
            }
        }
    }
    foreach ($residuePath in $residuePaths) {
        Remove-Item -LiteralPath $residuePath -Recurse -Force -ErrorAction Stop
    }
    foreach ($residuePath in $residuePaths) {
        if (Test-Path -LiteralPath $residuePath) {
            throw "Installer sibling transaction residue remained after cleanup: $residuePath"
        }
    }
}

function Assert-EverVigilDataRootRemovable {
    param([Parameter(Mandatory)][string]$Path)

    $expectedRoot = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $expectedRoot -PathType Container)) {
        return
    }
    $resolvedRoot = [IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $expectedRoot -ErrorAction Stop).Path).TrimEnd('\')
    if (-not [string]::Equals(
            $resolvedRoot,
            $expectedRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a data root that resolves unexpectedly: $resolvedRoot"
    }

    $allowedRootFiles = @(
        $script:LegacyCompatibilityDataSettingsFileName
        $script:LegacyCompatibilityDataProtectedTokenFileName
        $script:LegacyCompatibilityDataAppliedSystemConfigurationFileName
        $script:LegacyCompatibilityDataSystemConfigurationRequiredFileName
        $script:LegacyCompatibilityDataDiagnosticLoggingMarkerFileName
    ) | Select-Object -Unique
    $allowedLogNames = @(
        'evervigil.log'
        $script:LegacyCompatibilityDataLogFileName
    ) | Select-Object -Unique
    $transactionResiduePaths = @(Get-EverVigilTransactionResiduePaths -Path $resolvedRoot)
    $transactionResidue = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($transactionResiduePath in $transactionResiduePaths) {
        [void]$transactionResidue.Add(
            [IO.Path]::GetFullPath($transactionResiduePath).TrimEnd('\'))
    }
    foreach ($entry in @(
            Get-ChildItem -LiteralPath $resolvedRoot -Force -ErrorAction Stop)) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to remove a data tree containing a reparse point: $($entry.FullName)"
        }
        if ($transactionResidue.Contains(
                [IO.Path]::GetFullPath($entry.FullName).TrimEnd('\'))) {
            continue
        }
        if ($entry.PSIsContainer) {
            if ($entry.Name -cne $script:LegacyCompatibilityDataLogDirectoryName) {
                throw "Refusing to remove an application data directory with an unexpected entry: $($entry.Name)"
            }
            foreach ($logEntry in @(
                    Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction Stop)) {
                if ($logEntry.PSIsContainer -or
                    ($logEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing to remove an application log directory with an unexpected entry: $($logEntry.FullName)"
                }
                $logName = $logEntry.Name
                $ownedLog = @($allowedLogNames | Where-Object {
                        $logName -ceq $_ -or
                        $logName -cmatch ('\A' + [regex]::Escape($_) + '\.[1-9][0-9]*\z')
                    }).Count -gt 0
                if (-not $ownedLog) {
                    throw "Refusing to remove an application log directory with an unexpected file: $($logEntry.FullName)"
                }
            }
            continue
        }
        $ownedRootFile = $entry.Name -cin $allowedRootFiles -or
            $entry.Name -cmatch '\Asettings\.json\.invalid-\d{8}-\d{6}(?:-[0-9a-f]{32})?\z' -or
            $entry.Name -cmatch '\Atoken\.dat\.invalid-\d{8}-\d{6}-[0-9a-f]{32}\z'
        if (-not $ownedRootFile) {
            throw "Refusing to remove an application data root with an unexpected file: $($entry.Name)"
        }
    }
}

function Remove-EverVigilOwnedDataRoot {
    param([Parameter(Mandatory)][string]$Path)

    Assert-EverVigilDataRootRemovable -Path $Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

$pendingAtomicSystemCandidates = [Collections.Generic.List[object]]::new()
$script:recoveredPendingAtomicSystemPaths =
    [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
foreach ($recognizedDataRoot in $RecognizedDataRoots) {
    $transactionResiduePreflight = @(Get-EverVigilTransactionResiduePaths `
            -Path $recognizedDataRoot `
            -PreserveData:$KeepData)
    foreach ($residuePath in $transactionResiduePreflight) {
        if ((Split-Path -Leaf $residuePath) -cmatch
            '\Apending-system-configuration\.json\.[0-9a-f]{32}\.tmp\z') {
            $pendingAtomicSystemCandidates.Add(
                (Get-EverVigilRuntimeAtomicTemporaryInfo `
                    -Path $residuePath `
                    -DataRoot $recognizedDataRoot))
        }
    }
}
if (-not $KeepData) {
    foreach ($recognizedDataRoot in $RecognizedDataRoots) {
        Assert-EverVigilDataRootRemovable -Path $recognizedDataRoot
    }
}

$transactionMutex = $null
$transactionLockTaken = $false
$instanceMutex = $null
$instanceLockTaken = $false
$pendingSystemRecoveryCandidate = $null
$protectedBrokerRetirementRequired = $false
$sharedProtectedBrokerRetained = $false
try {
    $transactionMutex = New-EverVigilSystemTransactionMutex
    try {
        $transactionLockTaken = $transactionMutex.WaitOne([TimeSpan]::FromMinutes(10))
    } catch [Threading.AbandonedMutexException] {
        $transactionLockTaken = $true
    }
    if (-not $transactionLockTaken) {
        throw 'Another EverVigil install or uninstall transaction did not finish within 10 minutes.'
    }
    foreach ($recognizedDataRoot in $RecognizedDataRoots) {
        $candidateTransactionPath = Join-Path `
            $recognizedDataRoot `
            $script:LegacyCompatibilityDataTransactionJournalFileName
        $candidateInstallTransactionArtifacts = @(if (
                Test-Path -LiteralPath $recognizedDataRoot -PathType Container) {
                Get-ChildItem `
                    -LiteralPath $recognizedDataRoot `
                    -Force `
                    -ErrorAction Stop | Where-Object {
                        $_.Name.StartsWith(
                            $installTransactionTemporaryPrefix,
                            [StringComparison]::Ordinal)
                    }
            })
        if ((Test-Path -LiteralPath $candidateTransactionPath) -or
            $candidateInstallTransactionArtifacts.Count -gt 0) {
            throw "An install recovery transaction appeared after preflight at '$recognizedDataRoot'."
        }
    }
    $pendingSystemCandidates = @(
        foreach ($recognizedDataRoot in $RecognizedDataRoots) {
            $candidate = Join-Path `
                $recognizedDataRoot `
                'pending-system-configuration.json'
            if (Test-Path -LiteralPath $candidate) {
                [pscustomobject]@{
                    Path = $candidate
                    DataRoot = $recognizedDataRoot
                }
            }
        }
    )
    if ($pendingSystemCandidates.Count -gt 1) {
        throw 'Multiple pending system journals exist; uninstall cannot choose ownership safely.'
    }
    if ($pendingSystemCandidates.Count -eq 1) {
        $pendingCandidate = $pendingSystemCandidates[0]
        $pendingState = Read-PendingSystemJournalForRecovery `
            -Path $pendingCandidate.Path `
            -ExpectedDataRoot $pendingCandidate.DataRoot
        $pendingSystemRecoveryCandidate = [pscustomobject]@{
            Path = $pendingCandidate.Path
            State = $pendingState
        }
    }
    $installRootEntryExists = Test-Path -LiteralPath $InstallRoot
    if ($installRootEntryExists) {
        if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
            throw "The registered install path is not a directory: $InstallRoot"
        }
        Assert-OwnedInstallRoot `
            -Path $InstallRoot `
            -AllowLegacyKnownLayout `
            -AllowCurrentTempTree:$allowInstallRootInCurrentTemp
    }
    foreach ($recognizedDataRoot in $RecognizedDataRoots) {
        $transactionResiduePreflight = @(Get-EverVigilTransactionResiduePaths `
                -Path $recognizedDataRoot `
                -PreserveData:$KeepData)
        if (-not $KeepData) {
            Assert-EverVigilDataRootRemovable -Path $recognizedDataRoot
        }
    }
    foreach ($residueSpecification in $SiblingTransactionResidueSpecifications) {
        $siblingResiduePreflight = @(Get-EverVigilSiblingTransactionResiduePaths `
                -OriginalInstallRoot ([string]$residueSpecification.OriginalInstallRoot) `
                -ActiveInstallRoot $InstallRoot `
                -AllowedKind @($residueSpecification.AllowedKind) `
                -AllowActiveInstallRootInCurrentTemp:$allowInstallRootInCurrentTemp)
    }

function Get-ValidatedAppliedSystemConfiguration {
    if (-not (Test-Path `
            -LiteralPath $AppliedSystemConfigurationPath `
            -PathType Leaf)) {
        return $null
    }
    $configuration = Read-SystemConfiguration `
        -Path $AppliedSystemConfigurationPath `
        -Description 'the last applied system configuration'
    $resolvedTailscalePath = Resolve-AvailableTailscalePath `
        -Candidates @($configuration.TailscalePath)
    if ($configuration.PublicPort -lt 1024 -or
        $configuration.PublicPort -gt 65535 -or
        $configuration.BackendPort -lt 1024 -or
        $configuration.BackendPort -gt 65535 -or
        $configuration.PublicPort -eq $configuration.BackendPort) {
        throw "System cleanup ports are invalid: $($configuration.PublicPort)/$($configuration.BackendPort)"
    }
    if ([string]::IsNullOrWhiteSpace($resolvedTailscalePath) -or
        $resolvedTailscalePath.Contains('"') -or
        -not (Test-EverVigilPathFullyQualified -Path $resolvedTailscalePath) -or
        -not (Test-Path -LiteralPath $resolvedTailscalePath -PathType Leaf)) {
        throw "System cleanup Tailscale path is invalid: $resolvedTailscalePath"
    }
    return [pscustomobject]@{
        PublicPort = [int]$configuration.PublicPort
        BackendPort = [int]$configuration.BackendPort
        TailscalePath = [IO.Path]::GetFullPath($resolvedTailscalePath)
    }
}

$appliedConfiguration = Get-ValidatedAppliedSystemConfiguration
$primaryConfigurationOwned = $null -ne $appliedConfiguration
if ($primaryConfigurationOwned -and -not $protectedBrokerRetirementRequired) {
    $PublicPort = $appliedConfiguration.PublicPort
    $BackendPort = $appliedConfiguration.BackendPort
    $TailscalePath = $appliedConfiguration.TailscalePath
}

function Get-SupervisorProcessLocations {
    @(Get-EverVigilProcessLocations -Root $InstallRoot)
}

function Assert-NoSupervisorOutsideInstallRoot {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Location
    )

    $outside = @($Location | Where-Object { -not $_.AtInstallRoot })
    if ($outside.Count -gt 0) {
        throw "An EverVigil process is running outside the registered installation directory; system cleanup was not started. PID(s): $($outside.Id -join ', ')"
    }
}

$processLocations = @(Get-SupervisorProcessLocations)
Assert-NoSupervisorOutsideInstallRoot -Location $processLocations
if (Test-Path -LiteralPath $InstalledExecutable) {
    $shutdownProcess = Start-Process `
        -FilePath $InstalledExecutable `
        -ArgumentList '--shutdown' `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    if ($shutdownProcess.ExitCode -ne 0) {
        throw "Supervisor shutdown command failed with exit code $($shutdownProcess.ExitCode)."
    }
}

$runningSupervisors = @($processLocations | Where-Object AtInstallRoot | ForEach-Object Process)
if ($runningSupervisors.Count -gt 0) {
    $runningSupervisors | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue
}
$instanceMutex = [Threading.Mutex]::new(
    $false,
    $script:LegacyCompatibilitySynchronizationInstanceMutexTemplate.Replace(
        '{ownerSid}',
        $OwnerSid,
        [StringComparison]::Ordinal))
try {
    $instanceLockTaken = $instanceMutex.WaitOne([TimeSpan]::FromSeconds(20))
} catch [Threading.AbandonedMutexException] {
    $instanceLockTaken = $true
}
if (-not $instanceLockTaken) {
    throw 'The supervisor single-instance lock remained active; system cleanup was not started.'
}
$processLocations = @(Get-SupervisorProcessLocations)
Assert-NoSupervisorOutsideInstallRoot -Location $processLocations
$runningSupervisors = @($processLocations | Where-Object AtInstallRoot | ForEach-Object Process)
if ($runningSupervisors.Count -gt 0) {
    throw "Supervisor is still running after the shutdown request; system cleanup was not started. PID(s): $($runningSupervisors.Id -join ', ')"
}

if ($pendingSystemRecoveryCandidate) {
    $pendingRecoveryTransactionId = [guid][string]$pendingSystemRecoveryCandidate.State.transactionId
    $pendingRecoveryBrokerState = Get-ValidatedEverVigilProtectedBrokerRetirementState `
        -ExpectedOwnerSid $OwnerSid
    if ($pendingRecoveryBrokerState.Status -eq 'NeedsBrokerResume' -or
        $pendingRecoveryBrokerState.Status -eq 'Prepared') {
        # Retirement may become durable before the medium coordination mirror
        # is deleted. Recover is intentionally refused by the retired gate, so
        # bind the protected receipt to this exact local transaction first and
        # resume UninstallCleanup instead.
        $pendingRecoveryBrokerState = Get-ValidatedEverVigilProtectedBrokerRetirementState `
            -ExpectedOwnerSid $OwnerSid `
            -ExpectedTransactionId $pendingRecoveryTransactionId
        if (Test-Path `
                -LiteralPath $pendingRecoveryBrokerState.Paths.CanonicalPath `
                -PathType Leaf) {
            $retirementRecoveryResponse = Invoke-UninstallSystemBrokerOperation `
                -Operation UninstallCleanup `
                -TransactionId $pendingRecoveryTransactionId `
                -Initiator ([string]$pendingSystemRecoveryCandidate.State.initiator)
            if ([string]$retirementRecoveryResponse.disposition -cne
                'RetirementRequired') {
                throw 'The retired broker did not resume the exact pending uninstall transaction.'
            }
            $pendingRecoveryBrokerState = Get-ValidatedEverVigilProtectedBrokerRetirementState `
                -ExpectedOwnerSid $OwnerSid `
                -ExpectedTransactionId $pendingRecoveryTransactionId
            if ($pendingRecoveryBrokerState.Status -cne 'Prepared') {
                throw 'The resumed broker retirement did not reach its delete-only prepared state.'
            }
        }
        $protectedBrokerRetirementRequired = $true
    } elseif ($pendingRecoveryBrokerState.Status -eq 'Active') {
        [void](Invoke-UninstallSystemBrokerOperation `
                -Operation Recover `
                -TransactionId $pendingRecoveryTransactionId `
                -Initiator ([string]$pendingSystemRecoveryCandidate.State.initiator))
    } else {
        throw 'A local pending system journal exists without matching active or protected retirement evidence.'
    }
    Remove-Item `
        -LiteralPath ([string]$pendingSystemRecoveryCandidate.Path) `
        -Force `
        -ErrorAction Stop
    if (Test-Path -LiteralPath ([string]$pendingSystemRecoveryCandidate.Path)) {
        throw "The pending system journal remained after authenticated recovery: $($pendingSystemRecoveryCandidate.Path)"
    }
    # Recovery can restore a different previously applied identity. Never use
    # the pre-recovery route/path snapshot as uninstall ownership evidence.
    $appliedConfiguration = Get-ValidatedAppliedSystemConfiguration
    $primaryConfigurationOwned = $null -ne $appliedConfiguration
    if ($primaryConfigurationOwned) {
        $PublicPort = $appliedConfiguration.PublicPort
        $BackendPort = $appliedConfiguration.BackendPort
        $TailscalePath = $appliedConfiguration.TailscalePath
    }
}
foreach ($pendingAtomicCandidate in $pendingAtomicSystemCandidates) {
    if (-not (Test-Path -LiteralPath $pendingAtomicCandidate.Path -PathType Leaf)) {
        continue
    }
    $pendingAtomicCandidate = Get-EverVigilRuntimeAtomicTemporaryInfo `
        -Path $pendingAtomicCandidate.Path `
        -DataRoot (Split-Path -Parent $pendingAtomicCandidate.Path)
    $atomicBrokerState = Get-ValidatedEverVigilProtectedBrokerRetirementState `
        -ExpectedOwnerSid $OwnerSid
    if ($atomicBrokerState.Status -eq 'Active') {
        [void](Invoke-UninstallSystemBrokerOperation `
                -Operation Recover `
                -TransactionId ([guid]$pendingAtomicCandidate.TransactionId) `
                -Initiator ([string]$pendingAtomicCandidate.Initiator))
    } elseif ($atomicBrokerState.Status -eq 'NeedsBrokerResume' -or
        $atomicBrokerState.Status -eq 'Prepared') {
        $atomicBrokerState = Get-ValidatedEverVigilProtectedBrokerRetirementState `
            -ExpectedOwnerSid $OwnerSid `
            -ExpectedTransactionId ([guid]$pendingAtomicCandidate.TransactionId)
        if (Test-Path `
                -LiteralPath $atomicBrokerState.Paths.CanonicalPath `
                -PathType Leaf) {
            $atomicRetirementResponse = Invoke-UninstallSystemBrokerOperation `
                -Operation UninstallCleanup `
                -TransactionId ([guid]$pendingAtomicCandidate.TransactionId) `
                -Initiator ([string]$pendingAtomicCandidate.Initiator)
            if ([string]$atomicRetirementResponse.disposition -cne
                'RetirementRequired') {
                throw 'The retired broker did not authenticate an atomic pending journal.'
            }
        }
        $protectedBrokerRetirementRequired = $true
    } else {
        throw "An atomic pending system journal has no matching protected transaction evidence: $($pendingAtomicCandidate.Path)"
    }
    [IO.File]::Delete([string]$pendingAtomicCandidate.Path)
    if (Test-Path -LiteralPath $pendingAtomicCandidate.Path) {
        throw "An authenticated atomic pending system journal remained: $($pendingAtomicCandidate.Path)"
    }
    [void]$script:recoveredPendingAtomicSystemPaths.Add(
        [IO.Path]::GetFullPath([string]$pendingAtomicCandidate.Path))
}
foreach ($recognizedDataRoot in $RecognizedDataRoots) {
    $remainingPendingPath = Join-Path `
        $recognizedDataRoot `
        'pending-system-configuration.json'
    if (Test-Path -LiteralPath $remainingPendingPath) {
        throw "A pending system journal remained after recovery: $remainingPendingPath"
    }
}

if ($primaryConfigurationOwned) {
    $uninstallTarget = [ordered]@{
        publicPort = $PublicPort
        backendPort = $BackendPort
        tailscalePath = $TailscalePath
    }
    New-UninstallPendingSystemJournal -Target $uninstallTarget
}
$preCleanupBrokerState = Get-ValidatedEverVigilProtectedBrokerRetirementState `
    -ExpectedOwnerSid $OwnerSid
if ($protectedBrokerRetirementRequired) {
    if ($preCleanupBrokerState.Status -cne 'Prepared') {
        throw 'The authenticated protected broker retirement state changed before local cleanup.'
    }
} elseif ($preCleanupBrokerState.Status -eq 'Active' -or
    $preCleanupBrokerState.Status -eq 'NeedsBrokerResume' -or
    ($preCleanupBrokerState.Status -eq 'Prepared' -and
        (Test-Path `
            -LiteralPath $preCleanupBrokerState.Paths.CanonicalPath `
            -PathType Leaf))) {
    $uninstallBrokerResponse = Invoke-UninstallSystemBrokerOperation `
        -Operation UninstallCleanup `
        -TransactionId ([guid]$SystemTransactionId) `
        -Initiator Installer
    if ([string]$uninstallBrokerResponse.disposition -ceq 'RetirementRequired') {
        $protectedBrokerRetirementRequired = $true
        $validatedRetirement = Get-ValidatedEverVigilProtectedBrokerRetirementState `
            -ExpectedOwnerSid $OwnerSid
        if ($validatedRetirement.Status -cne 'Prepared') {
            throw 'The broker returned RetirementRequired without a valid protected retirement receipt.'
        }
    } else {
        # Completed/NoChange with a valid canonical broker means at least one
        # other owner SID still has protected state. Only this owner's state was
        # removed; the shared canonical installation must remain.
        $sharedProtectedBrokerRetained = $true
    }
} elseif ($preCleanupBrokerState.Status -eq 'Prepared' -or
    $preCleanupBrokerState.Status -eq 'DirectoriesOnly') {
    # A previous uninstall reached the protected retirement gate and then lost
    # its response or stopped between fixed delete steps. The receipt/ACL/tree
    # validation above is the authority for medium-integrity continuation.
    $protectedBrokerRetirementRequired = $true
} elseif ($preCleanupBrokerState.Status -eq 'Absent') {
    if ($primaryConfigurationOwned) {
        throw 'The protected broker is absent while local system ownership state still requires cleanup.'
    }
    # A configuration-required install can intentionally have only its local
    # marker and no protected broker. With no applied ownership journal there
    # is no privileged state to clean; the marker is removed below.
} else {
    throw "Unknown protected broker retirement state: $($preCleanupBrokerState.Status)"
}
if (Test-Path -LiteralPath $PendingSystemJournalPath -PathType Leaf) {
    Remove-Item `
        -LiteralPath $PendingSystemJournalPath `
        -Force `
        -ErrorAction Stop
}
if (Test-Path -LiteralPath $PendingSystemJournalPath) {
    throw 'The pending system journal remained after authenticated uninstall cleanup.'
}
foreach ($recognizedDataRoot in $RecognizedDataRoots) {
    $candidatePendingSystemPath = Join-Path `
        $recognizedDataRoot `
        'pending-system-configuration.json'
    if (Test-Path -LiteralPath $candidatePendingSystemPath) {
        throw "A pending system journal remained after system cleanup: $candidatePendingSystemPath"
    }
}

foreach ($recognizedDataRoot in $RecognizedDataRoots) {
    Remove-EverVigilTransactionResidue `
        -Path $recognizedDataRoot `
        -PreserveData:$KeepData
}

$ownershipStatePaths = @(
    $AppliedSystemConfigurationPath
    $SystemConfigurationRequiredPath
)
foreach ($ownershipStatePath in $ownershipStatePaths) {
    Remove-Item -LiteralPath $ownershipStatePath -Force -ErrorAction SilentlyContinue
}
foreach ($ownershipStatePath in $ownershipStatePaths) {
    if (Test-Path -LiteralPath $ownershipStatePath) {
        throw "System configuration ownership state could not be removed: $ownershipStatePath"
    }
}

$currentStartupRemoved = Remove-EverVigilOwnedShortcut `
        -Path $StartupShortcutPath `
        -ExpectedTargetPath $CurrentStartupTargets `
        -ExpectedArguments '--background'
$legacyStartupRemoved = Remove-EverVigilOwnedShortcut `
        -Path $LegacyStartupShortcutPath `
        -ExpectedTargetPath $LegacyStartupTargets `
        -ExpectedArguments '--background'
if ((Test-Path -LiteralPath $StartupShortcutPath -PathType Leaf) -or
    (Test-Path -LiteralPath $LegacyStartupShortcutPath -PathType Leaf)) {
    throw 'A verified startup shortcut remained after uninstall cleanup.'
}

Remove-EverVigilSiblingTransactionResidue `
    -Specification @($SiblingTransactionResidueSpecifications) `
    -ActiveInstallRoot $InstallRoot `
    -AllowActiveInstallRootInCurrentTemp:$allowInstallRootInCurrentTemp

if (Test-Path -LiteralPath $InstallRoot) {
    $resolved = (Resolve-Path -LiteralPath $InstallRoot).Path.TrimEnd('\')
    $expected = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    if (-not [string]::Equals($resolved, $expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected install path: $resolved"
    }
    Assert-OwnedInstallRoot `
        -Path $resolved `
        -AllowLegacyKnownLayout `
        -AllowCurrentTempTree:$allowInstallRootInCurrentTemp
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

if (-not $KeepData) {
    foreach ($recognizedDataRoot in $RecognizedDataRoots) {
        Remove-EverVigilOwnedDataRoot -Path $recognizedDataRoot
    }
}

if ($protectedBrokerRetirementRequired) {
    # This is deliberately the final mutation. If an earlier local cleanup step
    # fails, canonical+receipt remain and a rerun can resume the retired gate.
    Complete-EverVigilProtectedBrokerRetirement `
        -ExpectedOwnerSid $OwnerSid
}

if ($sharedProtectedBrokerRetained) {
    'EverVigil was uninstalled. The shared protected broker was retained because another Windows user still has protected EverVigil state.'
} elseif ($KeepData) {
    'EverVigil was uninstalled, including its last-user protected broker. Settings and the encrypted token were retained as requested.'
} else {
    'EverVigil was completely removed, including its last-user protected broker.'
}
} finally {
    if ($instanceLockTaken) {
        $instanceMutex.ReleaseMutex()
    }
    if ($instanceMutex) {
        $instanceMutex.Dispose()
    }
    if ($transactionLockTaken) {
        $transactionMutex.ReleaseMutex()
    }
    if ($transactionMutex) {
        $transactionMutex.Dispose()
    }
}
