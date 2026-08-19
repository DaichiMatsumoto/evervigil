[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$resolverScript = Join-Path $repositoryRoot 'scripts\Resolve-SafeInstallRoot.ps1'
$uninstallScript = Join-Path $repositoryRoot 'Uninstall.ps1'
$builtExecutable = Join-Path `
    $repositoryRoot `
    'src\EverVigil\bin\Release\net8.0-windows\EverVigil.exe'
if (-not (Test-Path -LiteralPath $builtExecutable -PathType Leaf)) {
    throw "Build the Release configuration before this test: $builtExecutable"
}

$testRoot = Join-Path $repositoryRoot 'artifacts\uninstall-transaction-residue-test'
$originalLocalAppData = $env:LOCALAPPDATA
$transactionId = '0123456789abcdef0123456789abcdef'

function Write-TestFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Protect-TestFileForCurrentOwner {
    param([Parameter(Mandatory)][string]$Path)

    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetOwner($owner)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($identity in @(
            $owner
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
        [IO.FileInfo]::new($Path),
        $security)
}

function Reset-TestDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

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
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force |
            Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }
}

function New-ValidPublishRoot {
    param([Parameter(Mandatory)][string]$Root)

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Copy-Item -LiteralPath $builtExecutable -Destination (Join-Path $Root 'EverVigil.exe')
}

try {
    Reset-TestDirectory -Path $testRoot
    $env:LOCALAPPDATA = Join-Path $testRoot 'LocalAppData'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
    . $resolverScript
    $OwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    $tokens = $null
    $parseErrors = $null
    $uninstallAst = [Management.Automation.Language.Parser]::ParseFile(
        $uninstallScript,
        [ref]$tokens,
        [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Uninstall.ps1 does not parse: $($parseErrors.Message -join '; ')"
    }
    $requiredFunctions = @(
        'Test-EverVigilCurrentOwnerFileAcl'
        'Read-PendingSystemJournalForRecovery'
        'Get-ValidatedEverVigilProtectedBrokerRetirementState'
        'Complete-EverVigilProtectedBrokerRetirement'
        'Get-EverVigilFileSha256'
        'Assert-EverVigilRegularFile'
        'Assert-EverVigilGeneratedTree'
        'Assert-EverVigilTemporaryPublishTree'
        'Test-EverVigilRecoveryFileName'
        'Test-EverVigilRestoreTemporaryFileName'
        'Assert-EverVigilRecoveryTree'
        'Get-EverVigilRuntimeAtomicTemporaryInfo'
        'Get-EverVigilTransactionResiduePaths'
        'Remove-EverVigilTransactionResidue'
        'Get-EverVigilSiblingTransactionResiduePaths'
        'Remove-EverVigilSiblingTransactionResidue'
        'Assert-EverVigilDataRootRemovable'
    )
    foreach ($functionName in $requiredFunctions) {
        $definition = @($uninstallAst.FindAll(
                {
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -eq $functionName
                },
                $true))
        if ($definition.Count -ne 1) {
            throw "Expected exactly one uninstall function named '$functionName'."
        }
        . ([scriptblock]::Create($definition[0].Extent.Text))
    }

    $dataRoot = Join-Path $env:LOCALAPPDATA 'EverVigil'
    Reset-TestDirectory -Path $dataRoot
    Write-TestFile -Path (Join-Path $dataRoot 'settings.json') -Content 'preserved state'
    Write-TestFile `
        -Path (Join-Path $dataRoot 'Logs\evervigil.log') `
        -Content 'owned log'
    $recoveryRoot = Join-Path $dataRoot "install-transactions\$transactionId"
    Write-TestFile -Path (Join-Path $recoveryRoot 'settings.json.rollback') -Content 'old state'
    Write-TestFile -Path (Join-Path $recoveryRoot 'legacy-task.xml') -Content '<Task />'
    Write-TestFile -Path (Join-Path $recoveryRoot 'system.log') -Content 'maintenance'
    $publishRoot = Join-Path $dataRoot "install-publish-$transactionId"
    New-ValidPublishRoot -Root $publishRoot
    $restoreTemporary = Join-Path `
        $dataRoot `
        "settings.json.restore-$transactionId.tmp"
    Write-TestFile -Path $restoreTemporary -Content 'partial restore'

    Assert-EverVigilDataRootRemovable -Path $dataRoot
    Remove-EverVigilTransactionResidue -Path $dataRoot
    foreach ($removedPath in @(
            (Join-Path $dataRoot 'install-transactions')
            $publishRoot
            $restoreTemporary
        )) {
        if (Test-Path -LiteralPath $removedPath) {
            throw "Complete-removal residue cleanup left '$removedPath'."
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'settings.json') -PathType Leaf)) {
        throw 'Residue cleanup removed preserved application data before root removal.'
    }
    Assert-EverVigilDataRootRemovable -Path $dataRoot

    Reset-TestDirectory -Path $dataRoot
    Write-TestFile -Path (Join-Path $dataRoot 'settings.json') -Content 'same bytes'
    $matchingRecoveryRoot = Join-Path $dataRoot "install-transactions\$transactionId"
    Write-TestFile `
        -Path (Join-Path $matchingRecoveryRoot 'settings.json.rollback') `
        -Content 'same bytes'
    Write-TestFile -Path (Join-Path $matchingRecoveryRoot 'system.log') -Content 'maintenance'
    $matchingPublishRoot = Join-Path $dataRoot "install-publish-$transactionId"
    New-ValidPublishRoot -Root $matchingPublishRoot
    $matchingRestoreTemporary = Join-Path `
        $dataRoot `
        "settings.json.restore-$transactionId.tmp"
    Write-TestFile -Path $matchingRestoreTemporary -Content 'same bytes'
    Remove-EverVigilTransactionResidue -Path $dataRoot -PreserveData
    if (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'settings.json') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $dataRoot 'install-transactions')) -or
        (Test-Path -LiteralPath $matchingPublishRoot) -or
        (Test-Path -LiteralPath $matchingRestoreTemporary)) {
        throw 'Keep-data cleanup did not preserve state and retire verified redundant residue.'
    }

    Reset-TestDirectory -Path $dataRoot
    Write-TestFile -Path (Join-Path $dataRoot 'settings.json') -Content 'current bytes'
    $mismatchRecoveryRoot = Join-Path $dataRoot "install-transactions\$transactionId"
    $mismatchRollback = Join-Path $mismatchRecoveryRoot 'settings.json.rollback'
    Write-TestFile -Path $mismatchRollback -Content 'different rollback bytes'
    $mismatchPublishRoot = Join-Path $dataRoot "install-publish-$transactionId"
    New-ValidPublishRoot -Root $mismatchPublishRoot
    $mismatchedRollbackRejected = $false
    try {
        Remove-EverVigilTransactionResidue -Path $dataRoot -PreserveData
    } catch {
        $mismatchedRollbackRejected = $_.Exception.Message -match 'differs from preserved data'
    }
    if (-not $mismatchedRollbackRejected -or
        -not (Test-Path -LiteralPath $mismatchRollback -PathType Leaf) -or
        -not (Test-Path -LiteralPath $mismatchPublishRoot -PathType Container)) {
        throw 'Keep-data cleanup did not fail atomically for an unconfirmed rollback copy.'
    }

    Reset-TestDirectory -Path $dataRoot
    Write-TestFile -Path (Join-Path $dataRoot 'settings.json') -Content 'current bytes'
    $mismatchRestoreTemporary = Join-Path `
        $dataRoot `
        "settings.json.restore-$transactionId.tmp"
    Write-TestFile -Path $mismatchRestoreTemporary -Content 'different restore bytes'
    $mismatchedRestoreRejected = $false
    try {
        Remove-EverVigilTransactionResidue -Path $dataRoot -PreserveData
    } catch {
        $mismatchedRestoreRejected = $_.Exception.Message -match 'differs from preserved data'
    }
    if (-not $mismatchedRestoreRejected -or
        -not (Test-Path -LiteralPath $mismatchRestoreTemporary -PathType Leaf)) {
        throw 'Keep-data cleanup discarded an unconfirmed restore temporary file.'
    }

    Reset-TestDirectory -Path $dataRoot
    $unknownRecoveryRoot = Join-Path $dataRoot "install-transactions\$transactionId"
    $unknownRecoveryFile = Join-Path $unknownRecoveryRoot 'user-file.txt'
    Write-TestFile -Path $unknownRecoveryFile -Content 'must remain'
    $unknownRecoveryRejected = $false
    try {
        [void]@(Get-EverVigilTransactionResiduePaths -Path $dataRoot)
    } catch {
        $unknownRecoveryRejected = $true
    }
    if (-not $unknownRecoveryRejected -or
        -not (Test-Path -LiteralPath $unknownRecoveryFile -PathType Leaf)) {
        throw 'An unknown recovery-tree file was not preserved fail-closed.'
    }

    Reset-TestDirectory -Path $dataRoot
    $maliciousPublishRoot = Join-Path $dataRoot "install-publish-$transactionId"
    New-ValidPublishRoot -Root $maliciousPublishRoot
    $maliciousPublishFile = Join-Path $maliciousPublishRoot 'unrelated-user-file.txt'
    Write-TestFile -Path $maliciousPublishFile -Content 'must remain'
    $maliciousPublishRejected = $false
    try {
        Remove-EverVigilTransactionResidue -Path $dataRoot
    } catch {
        $maliciousPublishRejected = $true
    }
    if (-not $maliciousPublishRejected -or
        -not (Test-Path -LiteralPath $maliciousPublishFile -PathType Leaf)) {
        throw 'A publish-like directory with unrelated content was not preserved fail-closed.'
    }

    Reset-TestDirectory -Path $dataRoot
    $journalTemporary = Join-Path `
        $dataRoot `
        "install-transaction.json.new-$transactionId"
    Write-TestFile -Path $journalTemporary -Content '{"status":"staging"}'
    $journalGuardPublishRoot = Join-Path $dataRoot "install-publish-$transactionId"
    New-ValidPublishRoot -Root $journalGuardPublishRoot
    $journalTemporaryRejected = $false
    try {
        Remove-EverVigilTransactionResidue -Path $dataRoot -PreserveData
    } catch {
        $journalTemporaryRejected = $_.Exception.Message -match 'recovery journal is pending'
    }
    if (-not $journalTemporaryRejected -or
        -not (Test-Path -LiteralPath $journalTemporary -PathType Leaf) -or
        -not (Test-Path -LiteralPath $journalGuardPublishRoot -PathType Container)) {
        throw 'A possible atomic recovery journal was not preserved before any residue mutation.'
    }

    Reset-TestDirectory -Path $dataRoot
    $pendingSystemTemporary = Join-Path `
        $dataRoot `
        "pending-system-configuration.json.$transactionId.tmp"
    Write-TestFile `
        -Path $pendingSystemTemporary `
        -Content '{"phase":"Prepared"}'
    $pendingSystemTemporaryRejected = $false
    try {
        Remove-EverVigilTransactionResidue -Path $dataRoot
    } catch {
        $pendingSystemTemporaryRejected = $true
    }
    if (-not $pendingSystemTemporaryRejected -or
        -not (Test-Path -LiteralPath $pendingSystemTemporary -PathType Leaf)) {
        throw 'A possible atomic pending-system journal was not preserved fail-closed.'
    }

    Reset-TestDirectory -Path $dataRoot
    $atomicSuffix = [guid]::NewGuid().ToString('N')
    $fixedExecutable = Join-Path $env:SystemRoot 'System32\where.exe'
    $settingsTemporary = Join-Path $dataRoot "settings.json.$atomicSuffix.tmp"
    $settingsJson = [ordered]@{
        uiLanguage = 'system'
        displayName = 'test-machine'
        publicPort = 3456
        backendPort = 3457
        codexAppServerPort = 8765
        projectDirectory = $testRoot
        nodePath = $fixedExecutable
        evenTerminalCliPath = $fixedExecutable
        codexPath = $fixedExecutable
        tailscalePath = $fixedExecutable
        healthIntervalSeconds = 30
        providerCheckIntervalSeconds = 300
        publicCheckIntervalSeconds = 300
        startupTimeoutSeconds = 120
        stableRunSeconds = 600
        failureThreshold = 3
        logFileSizeMb = 5
        logFileCopies = 3
        clipboardClearSeconds = 60
        diagnosticLogging = $false
        autoStartService = $true
    } | ConvertTo-Json
    Write-TestFile -Path $settingsTemporary -Content $settingsJson
    Protect-TestFileForCurrentOwner -Path $settingsTemporary

    $legacySettingsDocument = $settingsJson | ConvertFrom-Json
    $legacySettingsDocument | Add-Member `
        -MemberType NoteProperty `
        -Name publicHost `
        -Value 'test-device'
    $legacySettingsJson = $legacySettingsDocument | ConvertTo-Json
    $legacySettingsTemporary = Join-Path `
        $dataRoot `
        "settings.json.$([guid]::NewGuid().ToString('N')).tmp"
    Write-TestFile -Path $legacySettingsTemporary -Content $legacySettingsJson
    Protect-TestFileForCurrentOwner -Path $legacySettingsTemporary

    $appliedTemporary = Join-Path `
        $dataRoot `
        "applied-system-configuration.json.$atomicSuffix.tmp"
    Write-TestFile `
        -Path $appliedTemporary `
        -Content ([ordered]@{
            publicPort = 3456
            backendPort = 3457
            tailscalePath = $fixedExecutable
        } | ConvertTo-Json)
    Protect-TestFileForCurrentOwner -Path $appliedTemporary

    $tokenTemporary = Join-Path $dataRoot "token.dat.$atomicSuffix.tmp"
    $entropy = [Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false).GetBytes('EverVigil/token/v1'))
    $protectedToken = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::ASCII.GetBytes('0123456789abcdef0123456789abcdef'),
        $entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($tokenTemporary, $protectedToken)
    Protect-TestFileForCurrentOwner -Path $tokenTemporary

    foreach ($runtimeTemporary in @(
            $settingsTemporary,
            $legacySettingsTemporary,
            $appliedTemporary,
            $tokenTemporary)) {
        [void](Get-EverVigilRuntimeAtomicTemporaryInfo `
                -Path $runtimeTemporary `
                -DataRoot $dataRoot)
    }
    Remove-EverVigilTransactionResidue -Path $dataRoot -PreserveData
    if ((Test-Path -LiteralPath $settingsTemporary) -or
        (Test-Path -LiteralPath $legacySettingsTemporary) -or
        (Test-Path -LiteralPath $appliedTemporary) -or
        (Test-Path -LiteralPath $tokenTemporary)) {
        throw 'Validated runtime atomic temporaries were not removed with KeepData.'
    }

    Reset-TestDirectory -Path $dataRoot
    $legacyCompleteRemovalTemporary = Join-Path `
        $dataRoot `
        "settings.json.$([guid]::NewGuid().ToString('N')).tmp"
    Write-TestFile `
        -Path $legacyCompleteRemovalTemporary `
        -Content $legacySettingsJson
    Protect-TestFileForCurrentOwner -Path $legacyCompleteRemovalTemporary
    Remove-EverVigilTransactionResidue -Path $dataRoot
    if (Test-Path -LiteralPath $legacyCompleteRemovalTemporary) {
        throw 'A validated v1.2.1 settings atomic temporary survived complete removal.'
    }

    Reset-TestDirectory -Path $dataRoot
    $unknownSettingsDocument = $legacySettingsJson | ConvertFrom-Json
    $unknownSettingsDocument | Add-Member `
        -MemberType NoteProperty `
        -Name unexpectedProperty `
        -Value 'must-fail-closed'
    $invalidRuntimeTemporaries = @(
        [pscustomobject]@{
            Label = 'unknown property'
            Content = $unknownSettingsDocument | ConvertTo-Json
            Protect = $true
        }
        [pscustomobject]@{
            Label = 'duplicate property'
            Content = [regex]::Replace(
                $legacySettingsJson,
                '\A\s*\{',
                '{"publicHost":"duplicate.invalid",',
                1)
            Protect = $true
        }
        [pscustomobject]@{
            Label = 'malformed JSON'
            Content = '{'
            Protect = $true
        }
        [pscustomobject]@{
            Label = 'wrong ACL'
            Content = $legacySettingsJson
            Protect = $false
        }
    )
    foreach ($invalidRuntimeTemporary in $invalidRuntimeTemporaries) {
        $invalidPath = Join-Path `
            $dataRoot `
            "settings.json.$([guid]::NewGuid().ToString('N')).tmp"
        Write-TestFile -Path $invalidPath -Content $invalidRuntimeTemporary.Content
        if ($invalidRuntimeTemporary.Protect) {
            Protect-TestFileForCurrentOwner -Path $invalidPath
        }
        $invalidRejected = $false
        try {
            [void](Get-EverVigilRuntimeAtomicTemporaryInfo `
                    -Path $invalidPath `
                    -DataRoot $dataRoot)
        } catch {
            $invalidRejected = $true
        }
        if (-not $invalidRejected -or
            -not (Test-Path -LiteralPath $invalidPath -PathType Leaf)) {
            throw "A settings atomic temporary with $($invalidRuntimeTemporary.Label) was not preserved fail-closed."
        }
        Remove-Item -LiteralPath $invalidPath -Force
    }

    $invalidHostDocument = $settingsJson | ConvertFrom-Json
    $invalidHostDocument | Add-Member `
        -MemberType NoteProperty `
        -Name publicHost `
        -Value ('a' * 256)
    $invalidHostPath = Join-Path `
        $dataRoot `
        "settings.json.$([guid]::NewGuid().ToString('N')).tmp"
    Write-TestFile `
        -Path $invalidHostPath `
        -Content ($invalidHostDocument | ConvertTo-Json)
    Protect-TestFileForCurrentOwner -Path $invalidHostPath
    $invalidHostRejected = $false
    try {
        [void](Get-EverVigilRuntimeAtomicTemporaryInfo `
                -Path $invalidHostPath `
                -DataRoot $dataRoot)
    } catch {
        $invalidHostRejected = $true
    }
    if (-not $invalidHostRejected) {
        throw 'An overlong v1.2.1 publicHost was accepted as owned residue.'
    }
    Remove-Item -LiteralPath $invalidHostPath -Force

    $reparseTarget = Join-Path $testRoot 'settings-reparse-target'
    Reset-TestDirectory -Path $reparseTarget
    $reparseSettingsPath = Join-Path `
        $dataRoot `
        "settings.json.$([guid]::NewGuid().ToString('N')).tmp"
    New-Item `
        -ItemType Junction `
        -Path $reparseSettingsPath `
        -Target $reparseTarget | Out-Null
    $reparseSettingsRejected = $false
    try {
        [void](Get-EverVigilRuntimeAtomicTemporaryInfo `
                -Path $reparseSettingsPath `
                -DataRoot $dataRoot)
    } catch {
        $reparseSettingsRejected = $true
    }
    if (-not $reparseSettingsRejected -or
        -not (Test-Path -LiteralPath $reparseSettingsPath)) {
        throw 'A reparse-point settings atomic temporary was not preserved fail-closed.'
    }
    Remove-Item -LiteralPath $reparseSettingsPath -Force

    $pendingAtomicTransaction = [guid]::NewGuid()
    $pendingAtomicTemporary = Join-Path `
        $dataRoot `
        "pending-system-configuration.json.$atomicSuffix.tmp"
    Write-TestFile `
        -Path $pendingAtomicTemporary `
        -Content ([ordered]@{
            schemaVersion = 1
            transactionId = $pendingAtomicTransaction.ToString('D')
            ownerSid = $OwnerSid
            dataRoot = [IO.Path]::GetFullPath($dataRoot)
            initiator = 'Interactive'
            target = [ordered]@{
                publicPort = 3456
                backendPort = 3457
                tailscalePath = $fixedExecutable
            }
            previous = $null
            previousMappingOwned = $false
            existingTargetMappingOwned = $false
            phase = 'Prepared'
            observedTargetRouteOwnership = $null
            observedPreviousRouteOwnership = $null
            firewallSnapshotCaptured = $false
            originalMainFirewallPort = $null
            originalTemporaryFirewallPort = $null
            previousRouteMutationAuthorized = $false
            targetRouteMutationAuthorized = $false
            firewallMutationAuthorized = $false
        } | ConvertTo-Json -Depth 6)
    Protect-TestFileForCurrentOwner -Path $pendingAtomicTemporary
    $pendingAtomicInfo = Get-EverVigilRuntimeAtomicTemporaryInfo `
        -Path $pendingAtomicTemporary `
        -DataRoot $dataRoot
    if ($pendingAtomicInfo.TransactionId -ne $pendingAtomicTransaction) {
        throw 'The atomic pending-system transaction identity changed during validation.'
    }
    $unauthenticatedPendingRejected = $false
    try {
        Remove-EverVigilTransactionResidue -Path $dataRoot -PreserveData
    } catch {
        $unauthenticatedPendingRejected = $_.Exception.Message -match
            'not authenticated with the protected broker'
    }
    if (-not $unauthenticatedPendingRejected -or
        -not (Test-Path -LiteralPath $pendingAtomicTemporary -PathType Leaf)) {
        throw 'An atomic pending-system journal was deleted without protected-broker recovery evidence.'
    }
    $script:recoveredPendingAtomicSystemPaths =
        [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
    [void]$script:recoveredPendingAtomicSystemPaths.Add(
        [IO.Path]::GetFullPath($pendingAtomicTemporary))
    Remove-EverVigilTransactionResidue -Path $dataRoot -PreserveData
    if (Test-Path -LiteralPath $pendingAtomicTemporary) {
        throw 'An authenticated atomic pending-system journal was not removed.'
    }

    Reset-TestDirectory -Path $dataRoot
    $unknownRootFile = Join-Path $dataRoot 'user-document.txt'
    Write-TestFile -Path $unknownRootFile -Content 'must remain'
    $unknownRootRejected = $false
    try {
        Assert-EverVigilDataRootRemovable -Path $dataRoot
    } catch {
        $unknownRootRejected = $true
    }
    if (-not $unknownRootRejected -or
        -not (Test-Path -LiteralPath $unknownRootFile -PathType Leaf)) {
        throw 'Complete removal accepted an unrelated application-data file.'
    }

    Reset-TestDirectory -Path $dataRoot
    $junctionTarget = Join-Path $testRoot 'junction-target'
    Reset-TestDirectory -Path $junctionTarget
    $reparsePublishRoot = Join-Path $dataRoot "install-publish-$transactionId"
    New-Item -ItemType Directory -Path $reparsePublishRoot -Force | Out-Null
    $junctionPath = Join-Path $reparsePublishRoot 'redirected'
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    $reparseRejected = $false
    try {
        [void]@(Get-EverVigilTransactionResiduePaths -Path $dataRoot)
    } catch {
        $reparseRejected = $true
    }
    if (-not $reparseRejected -or
        -not (Test-Path -LiteralPath $junctionPath -PathType Container)) {
        throw 'A generated residue tree containing a reparse point was not preserved fail-closed.'
    }
    Remove-Item -LiteralPath $junctionPath -Force

    $activeInstallRoot = Join-Path $testRoot 'Programs\EverVigil'
    New-KnownInstallLayout -Root $activeInstallRoot
    Write-EverVigilInstallOwnership -Path $activeInstallRoot
    $stagingRoot = "$activeInstallRoot.staging-$transactionId"
    Copy-Item -LiteralPath $activeInstallRoot -Destination $stagingRoot -Recurse
    $backupRoot = "$activeInstallRoot.backup-$transactionId"
    Copy-Item -LiteralPath $activeInstallRoot -Destination $backupRoot -Recurse
    $relocatedRoot = "$activeInstallRoot.relocated-$transactionId"
    Copy-Item -LiteralPath $activeInstallRoot -Destination $relocatedRoot -Recurse
    $siblingSpecification = @([pscustomobject]@{
            OriginalInstallRoot = $activeInstallRoot
            AllowedKind = @('staging', 'backup', 'relocated')
        })
    Remove-EverVigilSiblingTransactionResidue `
        -Specification $siblingSpecification `
        -ActiveInstallRoot $activeInstallRoot
    if (-not (Test-Path -LiteralPath $activeInstallRoot -PathType Container) -or
        (Test-Path -LiteralPath $stagingRoot) -or
        (Test-Path -LiteralPath $backupRoot) -or
        (Test-Path -LiteralPath $relocatedRoot)) {
        throw 'Verified sibling work-tree cleanup removed the active install or left owned residue.'
    }

    $incompleteStagingRoot = "$activeInstallRoot.staging-$transactionId"
    Write-TestFile -Path (Join-Path $incompleteStagingRoot 'unrelated-user-file.txt') -Content 'must remain'
    $guardedOwnedBackupRoot = "$activeInstallRoot.backup-$transactionId"
    Copy-Item -LiteralPath $activeInstallRoot -Destination $guardedOwnedBackupRoot -Recurse
    $incompleteStagingRejected = $false
    try {
        Remove-EverVigilSiblingTransactionResidue `
            -Specification $siblingSpecification `
            -ActiveInstallRoot $activeInstallRoot
    } catch {
        $incompleteStagingRejected = $true
    }
    if (-not $incompleteStagingRejected -or
        -not (Test-Path -LiteralPath $incompleteStagingRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $guardedOwnedBackupRoot -PathType Container)) {
        throw 'An incomplete staging tree did not stop all sibling residue mutation.'
    }
    Remove-Item -LiteralPath $incompleteStagingRoot -Recurse -Force
    Remove-EverVigilSiblingTransactionResidue `
        -Specification $siblingSpecification `
        -ActiveInstallRoot $activeInstallRoot

    $unownedBackupRoot = "$activeInstallRoot.backup-$transactionId"
    Write-TestFile -Path (Join-Path $unownedBackupRoot 'user-file.txt') -Content 'must remain'
    $unownedBackupRejected = $false
    try {
        Remove-EverVigilSiblingTransactionResidue `
            -Specification $siblingSpecification `
            -ActiveInstallRoot $activeInstallRoot
    } catch {
        $unownedBackupRejected = $true
    }
    if (-not $unownedBackupRejected -or
        -not (Test-Path -LiteralPath $unownedBackupRoot -PathType Container)) {
        throw 'An unowned sibling backup was not preserved fail-closed.'
    }

    $originalRetirementPaths = (Get-Command `
            Get-EverVigilProtectedBrokerRetirementPaths `
            -CommandType Function).ScriptBlock
    $originalRetirementAcl = (Get-Command `
            Test-EverVigilProtectedBrokerRetirementAcl `
            -CommandType Function).ScriptBlock
    $originalProtectedAcl = (Get-Command `
            Test-EverVigilProtectedBrokerAcl `
            -CommandType Function).ScriptBlock
    $retirementFixtureRoot = Join-Path $testRoot 'ProgramData\EverVigil'
    $script:mockRetirementPaths = [pscustomobject]@{
        ProductRoot = $retirementFixtureRoot
        BrokerRoot = Join-Path $retirementFixtureRoot 'Broker'
        StateRoot = Join-Path $retirementFixtureRoot 'Broker\State'
        VersionRoot = Join-Path $retirementFixtureRoot 'Broker\2.0.0'
        CanonicalPath = Join-Path `
            $retirementFixtureRoot `
            'Broker\2.0.0\EverVigil.Broker.exe'
        InstallationReceiptPath = Join-Path `
            $retirementFixtureRoot `
            'Broker\2.0.0\installation.json'
        RetirementReceiptPath = Join-Path `
            $retirementFixtureRoot `
            'Broker\2.0.0\retirement.json'
    }
    $script:mockDeleteOnlyPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    function Get-EverVigilProtectedBrokerRetirementPaths {
        return $script:mockRetirementPaths
    }
    function Test-EverVigilProtectedBrokerRetirementAcl {
        param(
            [string]$Path,
            [string]$OwnerSid,
            [switch]$Directory
        )
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return $null -ne $item -and
            [bool]$item.PSIsContainer -eq [bool]$Directory -and
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
            $script:mockDeleteOnlyPaths.Contains([IO.Path]::GetFullPath($Path))
    }
    function Test-EverVigilProtectedBrokerAcl {
        param([string]$Path, [switch]$Directory)
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return $null -ne $item -and
            [bool]$item.PSIsContainer -eq [bool]$Directory -and
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    }
    function New-MockRetirementTree {
        param([switch]$IncludeOwnerState)

        if (Test-Path -LiteralPath $script:mockRetirementPaths.ProductRoot) {
            Remove-Item `
                -LiteralPath $script:mockRetirementPaths.ProductRoot `
                -Recurse `
                -Force
        }
        New-Item `
            -ItemType Directory `
            -Path $script:mockRetirementPaths.VersionRoot `
            -Force | Out-Null
        Copy-Item `
            -LiteralPath $fixedExecutable `
            -Destination $script:mockRetirementPaths.CanonicalPath
        $canonicalInfo = Get-Item `
            -LiteralPath $script:mockRetirementPaths.CanonicalPath
        $canonicalSha256 = (Get-FileHash `
                -LiteralPath $script:mockRetirementPaths.CanonicalPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-TestFile `
            -Path $script:mockRetirementPaths.InstallationReceiptPath `
            -Content ([ordered]@{
                schemaVersion = 1
                fileName = 'EverVigil.Broker.exe'
                version = '2.0.0'
                length = $canonicalInfo.Length
                sha256 = $canonicalSha256
            } | ConvertTo-Json)
        $script:mockRetirementTransactionId = [guid]::NewGuid()
        Write-TestFile `
            -Path $script:mockRetirementPaths.RetirementReceiptPath `
            -Content ([ordered]@{
                schemaVersion = 1
                transactionId = $script:mockRetirementTransactionId.ToString('D')
                ownerSid = $OwnerSid
                version = '2.0.0'
                canonicalFileName = 'EverVigil.Broker.exe'
                length = $canonicalInfo.Length
                sha256 = $canonicalSha256
                state = 'RetirementPrepared'
            } | ConvertTo-Json)
        if ($IncludeOwnerState) {
            Write-TestFile `
                -Path (Join-Path `
                    $script:mockRetirementPaths.StateRoot `
                    "$OwnerSid\last-system-transaction.json") `
                -Content '{}'
        }
        $script:mockDeleteOnlyPaths.Clear()
    }
    try {
        New-MockRetirementTree -IncludeOwnerState
        $needsResume = Get-ValidatedEverVigilProtectedBrokerRetirementState `
            -ExpectedOwnerSid $OwnerSid `
            -ExpectedTransactionId $script:mockRetirementTransactionId
        if ($needsResume.Status -cne 'NeedsBrokerResume') {
            throw 'A receipt-written pre-ACL retirement crash was not classified for broker resume.'
        }
        $wrongTransactionRejected = $false
        try {
            [void](Get-ValidatedEverVigilProtectedBrokerRetirementState `
                    -ExpectedOwnerSid $OwnerSid `
                    -ExpectedTransactionId ([guid]::NewGuid()))
        } catch {
            $wrongTransactionRejected = $true
        }
        if (-not $wrongTransactionRejected) {
            throw 'A retirement receipt was accepted for the wrong local transaction.'
        }

        $otherOwnerRoot = Join-Path `
            $script:mockRetirementPaths.StateRoot `
            'S-1-5-21-1-2-3-1001'
        New-Item -ItemType Directory -Path $otherOwnerRoot -Force | Out-Null
        $otherOwnerRejected = $false
        try {
            [void](Get-ValidatedEverVigilProtectedBrokerRetirementState `
                    -ExpectedOwnerSid $OwnerSid)
        } catch {
            $otherOwnerRejected = $true
        }
        if (-not $otherOwnerRejected) {
            throw 'Interrupted retirement accepted another owner SID state directory.'
        }
        Remove-Item -LiteralPath $otherOwnerRoot -Recurse -Force

        $unknownStatePath = Join-Path `
            $script:mockRetirementPaths.StateRoot `
            "$OwnerSid\unknown.bin"
        Write-TestFile -Path $unknownStatePath -Content 'unknown'
        $unknownStateRejected = $false
        try {
            [void](Get-ValidatedEverVigilProtectedBrokerRetirementState `
                    -ExpectedOwnerSid $OwnerSid)
        } catch {
            $unknownStateRejected = $true
        }
        if (-not $unknownStateRejected) {
            throw 'Interrupted retirement accepted an unknown protected owner-state file.'
        }
        Remove-Item -LiteralPath $unknownStatePath -Force

        $authorizationOrder = @(
            $script:mockRetirementPaths.CanonicalPath
            $script:mockRetirementPaths.InstallationReceiptPath
            $script:mockRetirementPaths.RetirementReceiptPath
            $script:mockRetirementPaths.VersionRoot
            $script:mockRetirementPaths.BrokerRoot
            $script:mockRetirementPaths.ProductRoot
        )
        foreach ($authorizedPath in $authorizationOrder) {
            [void]$script:mockDeleteOnlyPaths.Add(
                [IO.Path]::GetFullPath($authorizedPath))
            $partial = Get-ValidatedEverVigilProtectedBrokerRetirementState `
                -ExpectedOwnerSid $OwnerSid
            if ($partial.Status -cne 'NeedsBrokerResume') {
                throw "A partial retirement ACL stage was not classified for broker resume: $authorizedPath"
            }
        }
        Remove-Item -LiteralPath $script:mockRetirementPaths.StateRoot -Recurse -Force
        $prepared = Get-ValidatedEverVigilProtectedBrokerRetirementState `
            -ExpectedOwnerSid $OwnerSid
        if ($prepared.Status -cne 'Prepared') {
            throw 'A fully delete-authorized retirement was not classified Prepared.'
        }

        for ($deletedFileCount = 0; $deletedFileCount -le 3; $deletedFileCount++) {
            New-MockRetirementTree
            foreach ($deleteOnlyPath in $authorizationOrder) {
                [void]$script:mockDeleteOnlyPaths.Add(
                    [IO.Path]::GetFullPath($deleteOnlyPath))
            }
            $retirementFiles = @(
                $script:mockRetirementPaths.CanonicalPath
                $script:mockRetirementPaths.InstallationReceiptPath
                $script:mockRetirementPaths.RetirementReceiptPath)
            for ($index = 0; $index -lt $deletedFileCount; $index++) {
                [IO.File]::Delete($retirementFiles[$index])
            }
            $crashState = Get-ValidatedEverVigilProtectedBrokerRetirementState `
                -ExpectedOwnerSid $OwnerSid
            $expectedCrashState = if ($deletedFileCount -lt 3) {
                'Prepared'
            } else {
                'DirectoriesOnly'
            }
            if ($crashState.Status -cne $expectedCrashState) {
                throw "Retirement file-delete crash stage $deletedFileCount was classified incorrectly."
            }
            Complete-EverVigilProtectedBrokerRetirement `
                -ExpectedOwnerSid $OwnerSid
            if (Test-Path -LiteralPath $script:mockRetirementPaths.ProductRoot) {
                throw "Retirement did not resume after file-delete crash stage $deletedFileCount."
            }
        }

        for ($deletedDirectoryCount = 0; $deletedDirectoryCount -le 3; $deletedDirectoryCount++) {
            New-MockRetirementTree
            foreach ($deleteOnlyPath in $authorizationOrder) {
                [void]$script:mockDeleteOnlyPaths.Add(
                    [IO.Path]::GetFullPath($deleteOnlyPath))
            }
            foreach ($retirementFile in @(
                    $script:mockRetirementPaths.CanonicalPath
                    $script:mockRetirementPaths.InstallationReceiptPath
                    $script:mockRetirementPaths.RetirementReceiptPath)) {
                [IO.File]::Delete($retirementFile)
            }
            $retirementDirectories = @(
                $script:mockRetirementPaths.VersionRoot
                $script:mockRetirementPaths.BrokerRoot
                $script:mockRetirementPaths.ProductRoot)
            for ($index = 0; $index -lt $deletedDirectoryCount; $index++) {
                [IO.Directory]::Delete($retirementDirectories[$index], $false)
            }
            Complete-EverVigilProtectedBrokerRetirement `
                -ExpectedOwnerSid $OwnerSid
            if (Test-Path -LiteralPath $script:mockRetirementPaths.ProductRoot) {
                throw "Retirement did not resume after directory-delete crash stage $deletedDirectoryCount."
            }
        }
    } finally {
        Set-Item `
            -LiteralPath Function:\Get-EverVigilProtectedBrokerRetirementPaths `
            -Value $originalRetirementPaths
        Set-Item `
            -LiteralPath Function:\Test-EverVigilProtectedBrokerRetirementAcl `
            -Value $originalRetirementAcl
        Set-Item `
            -LiteralPath Function:\Test-EverVigilProtectedBrokerAcl `
            -Value $originalProtectedAcl
        Remove-Variable -Name mockRetirementPaths -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name mockDeleteOnlyPaths -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name mockRetirementTransactionId -Scope Script -ErrorAction SilentlyContinue
    }

    'Uninstall transaction-residue tests passed: recovery copies verified, runtime atomic temporaries ownership-checked, pending-system deletion broker-gated, retirement crash stages resumed, publish/staging identity enforced, and unrelated files/reparse points preserved fail-closed.'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $expectedParent = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'artifacts'))
        if ($resolvedTestRoot.StartsWith(
                "$expectedParent\",
                [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
