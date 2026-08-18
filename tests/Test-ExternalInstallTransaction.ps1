[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$resolverScript = Join-Path $repositoryRoot 'scripts\Resolve-SafeInstallRoot.ps1'
$transactionDataScript = Join-Path $repositoryRoot 'scripts\InstallTransactionData.ps1'
$transactionScript = Join-Path $repositoryRoot 'scripts\Complete-InstallTransaction.ps1'
$testRoot = Join-Path $repositoryRoot 'artifacts\external-install-transaction-test'
$testLocalAppData = Join-Path $testRoot 'LocalAppData'
$testPrograms = Join-Path $testRoot 'Programs'
$testStartup = Join-Path $testRoot 'Startup'
$installRoot = Join-Path $testLocalAppData 'Programs\EverVigil'
$transactionId = '1023456789abcdef0123456789abcdef'
$cleanupTransactionId = 'efdcba9876543210fedcba9876543210'
$originalLocalAppData = $env:LOCALAPPDATA
$testRegistrySubKey =
    "Software\EverVigil.Tests\ExternalInstallTransaction\$transactionId"
$originalRegistrySubKey = $null

function New-TestShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Arguments,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkingDirectory,
        [Parameter(Mandatory)][AllowEmptyString()][string]$IconLocation
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force |
        Out-Null
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $TargetPath
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = $WorkingDirectory
        if (-not [string]::IsNullOrEmpty($IconLocation)) {
            $shortcut.IconLocation = $IconLocation
        }
        $shortcut.Save()
    } finally {
        if ($null -ne $shortcut -and
            [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($null -ne $shell -and
            [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Get-TestCurrentInnoRegistryRecords {
    param([Parameter(Mandatory)][string]$Version)

    $parts = $Version.Split('-', 2)[0].Split('.')
    $major = [uint32]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture)
    $minor = [uint32]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
    $supportRoot = Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall'
    return @(
        [pscustomobject]@{ name = 'Comments'; kind = 'String'; value = 'An independent Windows tray utility that keeps Even Terminal running and available.' }
        [pscustomobject]@{ name = 'DisplayIcon'; kind = 'String'; value = (Join-Path $installRoot 'EverVigil.exe') }
        [pscustomobject]@{ name = 'DisplayName'; kind = 'String'; value = 'EverVigil' }
        [pscustomobject]@{ name = 'DisplayVersion'; kind = 'String'; value = $Version }
        [pscustomobject]@{ name = 'EstimatedSize'; kind = 'DWord'; value = '4096' }
        [pscustomobject]@{ name = 'HelpLink'; kind = 'String'; value = 'https://github.com/DaichiMatsumoto/evervigil/issues' }
        [pscustomobject]@{ name = 'Inno Setup: App Path'; kind = 'String'; value = $installRoot.TrimEnd('\') }
        [pscustomobject]@{ name = 'Inno Setup: Icon Group'; kind = 'String'; value = 'EverVigil' }
        [pscustomobject]@{ name = 'Inno Setup: Language'; kind = 'String'; value = 'english' }
        [pscustomobject]@{ name = 'Inno Setup: Setup Version'; kind = 'String'; value = '6.4.3' }
        [pscustomobject]@{ name = 'Inno Setup: User'; kind = 'String'; value = [Environment]::UserName }
        [pscustomobject]@{ name = 'InstallDate'; kind = 'String'; value = '20260818' }
        [pscustomobject]@{ name = 'InstallLocation'; kind = 'String'; value = ($installRoot.TrimEnd('\') + '\') }
        [pscustomobject]@{ name = 'MajorVersion'; kind = 'DWord'; value = $major.ToString([Globalization.CultureInfo]::InvariantCulture) }
        [pscustomobject]@{ name = 'MinorVersion'; kind = 'DWord'; value = $minor.ToString([Globalization.CultureInfo]::InvariantCulture) }
        [pscustomobject]@{ name = 'NoModify'; kind = 'DWord'; value = '1' }
        [pscustomobject]@{ name = 'NoRepair'; kind = 'DWord'; value = '1' }
        [pscustomobject]@{ name = 'Publisher'; kind = 'String'; value = 'Daichi Matsumoto' }
        [pscustomobject]@{ name = 'QuietUninstallString'; kind = 'String'; value = ('"{0}" /SILENT /LOG' -f (Join-Path $supportRoot 'unins000.exe')) }
        [pscustomobject]@{ name = 'UninstallString'; kind = 'String'; value = ('"{0}" /LOG' -f (Join-Path $supportRoot 'unins000.exe')) }
        [pscustomobject]@{ name = 'URLInfoAbout'; kind = 'String'; value = 'https://github.com/DaichiMatsumoto' }
        [pscustomobject]@{ name = 'URLUpdateInfo'; kind = 'String'; value = 'https://github.com/DaichiMatsumoto/evervigil/releases' }
        [pscustomobject]@{ name = 'VersionMajor'; kind = 'DWord'; value = $major.ToString([Globalization.CultureInfo]::InvariantCulture) }
        [pscustomobject]@{ name = 'VersionMinor'; kind = 'DWord'; value = $minor.ToString([Globalization.CultureInfo]::InvariantCulture) }
    )
}

function Set-TestRegistryRecords {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record)

    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
        $script:LegacyCompatibilityApplicationUninstallRegistrySubKey,
        $false)
    if ($Record.Count -eq 0) {
        return
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(
        $script:LegacyCompatibilityApplicationUninstallRegistrySubKey,
        $true)
    try {
        foreach ($entry in $Record) {
            $kind = [Microsoft.Win32.RegistryValueKind]::$([string]$entry.kind)
            $value = switch ([string]$entry.kind) {
                'DWord' {
                    $unsigned = [uint32]::Parse(
                        [string]$entry.value,
                        [Globalization.CultureInfo]::InvariantCulture)
                    [BitConverter]::ToInt32(
                        [BitConverter]::GetBytes($unsigned),
                        0)
                }
                'QWord' {
                    $unsigned = [uint64]::Parse(
                        [string]$entry.value,
                        [Globalization.CultureInfo]::InvariantCulture)
                    [BitConverter]::ToInt64(
                        [BitConverter]::GetBytes($unsigned),
                        0)
                }
                'MultiString' { ,([string[]]@($entry.value)) }
                { $_ -in @('Binary', 'None') } {
                    ,([Convert]::FromBase64String([string]$entry.value))
                }
                default { [string]$entry.value }
            }
            try {
                $key.SetValue([string]$entry.name, $value, $kind)
            } catch {
                throw "The registry fixture value '$($entry.name)' ($($entry.kind)) could not be written: $($_.Exception.Message)"
            }
        }
        $key.Flush()
    } finally {
        $key.Dispose()
    }
}

function Assert-TestRegistryCanonical {
    param([Parameter(Mandatory)][string]$Expected)

    $actual = Get-EverVigilUninstallRegistryState |
        ConvertTo-Json -Depth 8 -Compress
    if (-not [string]::Equals($actual, $Expected, [StringComparison]::Ordinal)) {
        throw 'The isolated uninstall registry did not reach its exact expected state.'
    }
}

try {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $testLocalAppData -Force | Out-Null
    New-Item -ItemType Directory -Path $testPrograms -Force | Out-Null
    New-Item -ItemType Directory -Path $testStartup -Force | Out-Null
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    $env:LOCALAPPDATA = $testLocalAppData
    . $resolverScript
    . $transactionDataScript
    . $transactionScript
    $originalRegistrySubKey =
        $script:LegacyCompatibilityApplicationUninstallRegistrySubKey
    $script:LegacyCompatibilityApplicationUninstallRegistrySubKey =
        $testRegistrySubKey
    function Get-EverVigilProgramsFolderPath { return $testPrograms }
    function Get-EverVigilStartupFolderPath { return $testStartup }

    $supportRoot = Join-Path $testLocalAppData 'EverVigil.Uninstall'
    $supportFiles = @(
        'unins000.dat'
        'unins000.exe'
        'Support\Uninstall.ps1'
        'Support\scripts\Complete-InstallTransaction.ps1'
        'Support\scripts\InstallTransactionData.ps1'
        'Support\scripts\Invoke-InteractiveUserTask.ps1'
        'Support\scripts\Invoke-SystemMaintenance.ps1'
        'Support\scripts\LegacyCompatibility.generated.ps1'
        'Support\scripts\Resolve-SafeInstallRoot.ps1')
    foreach ($relative in $supportFiles) {
        $path = Join-Path $supportRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force |
            Out-Null
        [IO.File]::WriteAllText(
            $path,
            "pre-install support bytes: $relative",
            [Text.UTF8Encoding]::new($false))
    }
    $applicationShortcut = Join-Path $testPrograms 'EverVigil\EverVigil.lnk'
    $uninstallShortcut = Join-Path `
        $testPrograms `
        'EverVigil\Uninstall EverVigil.lnk'
    $startupShortcut = Join-Path $testStartup 'EverVigil.lnk'
    $targetExecutable = Join-Path $installRoot 'EverVigil.exe'
    $uninstaller = Join-Path $supportRoot 'unins000.exe'
    New-TestShortcut `
        -Path $applicationShortcut `
        -TargetPath $targetExecutable `
        -Arguments '' `
        -WorkingDirectory $installRoot `
        -IconLocation ''
    New-TestShortcut `
        -Path $uninstallShortcut `
        -TargetPath $uninstaller `
        -Arguments '' `
        -WorkingDirectory $supportRoot `
        -IconLocation ''
    New-TestShortcut `
        -Path $startupShortcut `
        -TargetPath $targetExecutable `
        -Arguments '--background' `
        -WorkingDirectory ($installRoot + [IO.Path]::DirectorySeparatorChar) `
        -IconLocation "$targetExecutable,0"

    $legacyRegistryRecords = @(
        [pscustomobject]@{ name = 'LegacyString'; kind = 'String'; value = 'legacy text' }
        [pscustomobject]@{ name = 'LegacyExpand'; kind = 'ExpandString'; value = '%LOCALAPPDATA%\Legacy' }
        [pscustomobject]@{ name = 'LegacyDword'; kind = 'DWord'; value = '41' }
        [pscustomobject]@{ name = 'LegacyQword'; kind = 'QWord'; value = '4294967297' }
        [pscustomobject]@{ name = 'LegacyMulti'; kind = 'MultiString'; value = @('one', 'two') }
        [pscustomobject]@{ name = 'LegacyBinary'; kind = 'Binary'; value = [Convert]::ToBase64String([byte[]](0, 1, 254, 255)) }
        [pscustomobject]@{ name = 'LegacyNone'; kind = 'None'; value = [Convert]::ToBase64String([byte[]](4, 5, 6)) }
    )
    Set-TestRegistryRecords -Record $legacyRegistryRecords
    $legacyRegistryCanonical = Get-EverVigilUninstallRegistryState |
        ConvertTo-Json -Depth 8 -Compress

    $recoveryRoot = Join-Path `
        $testLocalAppData `
        "EverVigil\install-transactions\$transactionId"
    $state = [ordered]@{
        transactionId = $transactionId
        cleanupTransactionId = $cleanupTransactionId
        installRoot = $installRoot
        previousInstallRoot = $installRoot
        legacyCleanupAuthorized = $false
        legacyCredentialFound = $false
        legacyTokenPath = ''
        targetVersion = '2.1.0'
        existingInstallPresent = $true
        startupWasRegistered = $true
        migrationApplied = $false
        externalArtifactSnapshotReady = $false
        externalArtifactSnapshots = @()
        uninstallRegistryWasPresent = $false
        uninstallRegistrySnapshotReady = $false
        uninstallRegistrySnapshotSha256 = ''
        uninstallRegistryMutationMarkerSha256 = ''
        externalCommitPhase = 'None'
        recoveryRoot = $recoveryRoot
    }
    $registrySnapshot = New-EverVigilUninstallRegistrySnapshot `
        -RecoveryRoot $recoveryRoot `
        -TransactionId $transactionId
    $state.uninstallRegistryMutationMarkerSha256 =
        New-EverVigilUninstallRegistryMutationMarker `
            -RecoveryRoot $recoveryRoot `
            -TransactionId $transactionId
    $state.externalArtifactSnapshots = @(
        New-EverVigilExternalArtifactSnapshots `
            -RecoveryRoot $recoveryRoot `
            -State $state)
    $state.uninstallRegistryWasPresent = [bool]$registrySnapshot.WasPresent
    $state.uninstallRegistrySnapshotSha256 = [string]$registrySnapshot.Sha256
    $state.uninstallRegistrySnapshotReady = $true
    $state.externalArtifactSnapshotReady = $true
    $state.externalCommitPhase = 'SnapshotReady'
    Assert-EverVigilExternalArtifactSnapshotState `
        -State $state `
        -RecoveryRoot $recoveryRoot `
        -RequireBackupFiles

    $snapshotByRole = @{}
    foreach ($snapshot in @($state.externalArtifactSnapshots)) {
        $snapshotByRole[[string]$snapshot.role] = $snapshot
    }
    $definitions = @(Get-EverVigilExternalArtifactDefinitions -State $state)
    foreach ($definition in @($definitions | Where-Object InstallerManaged)) {
        if (Test-Path -LiteralPath $definition.Path -PathType Leaf) {
            [IO.File]::WriteAllBytes($definition.Path, [byte[]]@())
        }
    }
    Set-TestRegistryRecords -Record @(
        (Get-TestCurrentInnoRegistryRecords -Version '2.1.0' |
            Select-Object -First 4))

    $unexpectedSupport = Join-Path $supportRoot 'unexpected-inno.tmp'
    [IO.File]::WriteAllText(
        $unexpectedSupport,
        'unknown residue',
        [Text.UTF8Encoding]::new($false))
    $unknownFileRejected = $false
    try {
        Restore-EverVigilExternalArtifactSnapshots `
            -State $state `
            -RecoveryRoot $recoveryRoot `
            -TransactionId $transactionId
    } catch {
        $unknownFileRejected = $_.Exception.Message -match 'unexpected entry'
    }
    if (-not $unknownFileRejected -or
        -not (Test-Path -LiteralPath $unexpectedSupport -PathType Leaf)) {
        throw 'An unknown Inno support residue was not preserved fail-closed.'
    }
    Remove-Item -LiteralPath $unexpectedSupport -Force

    $registryKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        $testRegistrySubKey,
        $true)
    try {
        $registryKey.SetValue(
            'UnownedValue',
            'must remain',
            [Microsoft.Win32.RegistryValueKind]::String)
        $registryKey.Flush()
    } finally {
        $registryKey.Dispose()
    }
    $unknownRegistryRejected = $false
    try {
        Restore-EverVigilUninstallRegistrySnapshot `
            -State $state `
            -RecoveryRoot $recoveryRoot
    } catch {
        $unknownRegistryRejected = $_.Exception.Message -match 'unowned partial value'
    }
    if (-not $unknownRegistryRejected) {
        throw 'An unknown Inno registry value was not rejected fail-closed.'
    }
    $registryKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        $testRegistrySubKey,
        $true)
    try {
        $registryKey.DeleteValue('UnownedValue', $false)
        $registryKey.Flush()
    } finally {
        $registryKey.Dispose()
    }

    $registryKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        $testRegistrySubKey,
        $true)
    try {
        $unexpectedSubKey = $registryKey.CreateSubKey('Unexpected', $true)
        $unexpectedSubKey.Dispose()
        $registryKey.Flush()
    } finally {
        $registryKey.Dispose()
    }
    $unknownSubKeyRejected = $false
    try {
        Restore-EverVigilUninstallRegistrySnapshot `
            -State $state `
            -RecoveryRoot $recoveryRoot
    } catch {
        $unknownSubKeyRejected = $_.Exception.Message -match 'unexpected subkey'
    }
    if (-not $unknownSubKeyRejected) {
        throw 'An unknown Inno registry subkey was not rejected fail-closed.'
    }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
        "$testRegistrySubKey\Unexpected",
        $false)

    $markerPath = Join-Path `
        $recoveryRoot `
        $script:EverVigilUninstallRegistryMutationMarkerFileName
    $correctMarkerBytes = [IO.File]::ReadAllBytes($markerPath)
    Remove-Item -LiteralPath $markerPath -Force
    $wrongTransactionId = '2023456789abcdef0123456789abcdef'
    $state.uninstallRegistryMutationMarkerSha256 =
        New-EverVigilUninstallRegistryMutationMarker `
            -RecoveryRoot $recoveryRoot `
            -TransactionId $wrongTransactionId
    $wrongMarkerRejected = $false
    try {
        Restore-EverVigilUninstallRegistrySnapshot `
            -State $state `
            -RecoveryRoot $recoveryRoot
    } catch {
        $wrongMarkerRejected = $_.Exception.Message -match 'does not match this transaction'
    }
    if (-not $wrongMarkerRejected) {
        throw 'A registry mutation marker for a different transaction was accepted.'
    }
    [IO.File]::WriteAllBytes($markerPath, $correctMarkerBytes)
    $state.uninstallRegistryMutationMarkerSha256 =
        Get-EverVigilFileSha256 -Path $markerPath

    Restore-EverVigilExternalArtifactSnapshots `
        -State $state `
        -RecoveryRoot $recoveryRoot `
        -TransactionId $transactionId
    Assert-TestRegistryCanonical -Expected $legacyRegistryCanonical
    foreach ($definition in @($definitions | Where-Object Authorized)) {
        $snapshot = $snapshotByRole[[string]$definition.Role]
        if ([bool]$snapshot.wasPresent) {
            if (-not (Test-Path -LiteralPath $definition.Path -PathType Leaf) -or
                (Get-EverVigilFileSha256 -Path $definition.Path) -cne
                    [string]$snapshot.sha256) {
                throw "An external rollback byte snapshot was not restored: $($definition.Role)"
            }
        } elseif (Test-Path -LiteralPath $definition.Path) {
            throw "A newly generated external artifact remained after rollback: $($definition.Role)"
        }
    }
    Restore-EverVigilExternalArtifactSnapshots `
        -State $state `
        -RecoveryRoot $recoveryRoot `
        -TransactionId $transactionId

    $currentRecords = @(Get-TestCurrentInnoRegistryRecords -Version '2.1.0')
    for ($recordCount = 0; $recordCount -le $currentRecords.Count; $recordCount++) {
        Set-TestRegistryRecords -Record @($currentRecords | Select-Object -First $recordCount)
        Restore-EverVigilUninstallRegistrySnapshot `
            -State $state `
            -RecoveryRoot $recoveryRoot
        Assert-TestRegistryCanonical -Expected $legacyRegistryCanonical
    }

    foreach ($versionCase in @(
            [pscustomobject]@{ Version = '2.0.1'; Major = '2'; Minor = '0' }
            [pscustomobject]@{ Version = '2.1.0'; Major = '2'; Minor = '1' }
            [pscustomobject]@{ Version = '3.0.0-rc.1'; Major = '3'; Minor = '0' }
        )) {
        $state.targetVersion = $versionCase.Version
        $records = @(Get-TestCurrentInnoRegistryRecords -Version $versionCase.Version)
        foreach ($record in $records) {
            if (-not (Test-EverVigilKnownInnoRegistryValue `
                        -ValueRecord $record `
                        -State $state)) {
                throw "A valid target-version registry value was rejected: $($versionCase.Version)/$($record.name)"
            }
        }
        $wrongDisplayVersion = [pscustomobject]@{
            name = 'DisplayVersion'
            kind = 'String'
            value = '9.9.9'
        }
        if (Test-EverVigilKnownInnoRegistryValue `
                -ValueRecord $wrongDisplayVersion `
                -State $state) {
            throw "A mismatched DisplayVersion was accepted for $($versionCase.Version)."
        }
    }
    $state.targetVersion = '2.1.0'
    Set-TestRegistryRecords -Record $currentRecords
    $alreadyCurrentSnapshot = Get-EverVigilUninstallRegistryState
    Assert-EverVigilPartialInnoRegistryOwned `
        -State $state `
        -PrestateSnapshot $alreadyCurrentSnapshot `
        -RequireCompleteCurrent

    $state.ownerSid = Get-EverVigilOwnerSid
    $state.status = 'readyToCommit'
    $state.destinationBackupPlanned = $false
    $state.previousBackupPlanned = $false
    $state.runtimeConfigurationReady = $false
    $state.systemConfigurationWasRequired = $false
    $state.publicPort = 3456
    $state.backendPort = 3457
    $state.tailscalePath = 'C:\Program Files\Tailscale\tailscale.exe'
    $preflightMutex = New-EverVigilSystemTransactionMutex
    $preflightMutexTaken = $false
    try {
        try {
            $preflightMutexTaken = $preflightMutex.WaitOne(
                [TimeSpan]::FromSeconds(10))
        } catch [Threading.AbandonedMutexException] {
            $preflightMutexTaken = $true
        }
        if (-not $preflightMutexTaken) {
            throw 'The external finalization preflight fixture could not acquire the system mutex.'
        }
        $script:InstallTransactionMutex = $preflightMutex
        $script:InstallTransactionMutexTaken = $true
        Assert-EverVigilInstallerFinalizationPreflight -State $state
    } finally {
        if ($script:InstallTransactionMutexTaken) {
            $preflightMutex.ReleaseMutex()
        }
        $script:InstallTransactionMutexTaken = $false
        $script:InstallTransactionMutex = $null
        $preflightMutex.Dispose()
    }

    $originalKnownLayout = (Get-Command `
            Test-EverVigilKnownLayout `
            -CommandType Function).ScriptBlock
    $originalOwnedInstallAssertion = (Get-Command `
            Assert-OwnedInstallRoot `
            -CommandType Function).ScriptBlock
    $originalInteractiveCleanup = (Get-Command `
            Remove-EverVigilInteractiveTasksForTransaction `
            -CommandType Function).ScriptBlock
    $originalFinalizationPreflight = (Get-Command `
            Assert-EverVigilInstallerFinalizationPreflight `
            -CommandType Function).ScriptBlock
    $originalRollback = (Get-Command `
            Rollback-EverVigilInstallTransaction `
            -CommandType Function).ScriptBlock
    $originalBrokerTransaction = (Get-Command `
            Invoke-SystemBrokerTransaction `
            -CommandType Function).ScriptBlock
    $originalTransactionWriter = (Get-Command `
            Write-EverVigilInstallTransaction `
            -CommandType Function).ScriptBlock
    $originalTreeResume = (Get-Command `
            Resume-VerifiedTransactionTreeRemoval `
            -CommandType Function).ScriptBlock
    $originalPublishRemoval = (Get-Command `
            Remove-TemporaryPublishTree `
            -CommandType Function).ScriptBlock
    $originalTreeRemoval = (Get-Command `
            Remove-VerifiedTransactionTree `
            -CommandType Function).ScriptBlock
    $originalRecoveryRemoval = (Get-Command `
            Remove-TransactionRecoveryFiles `
            -CommandType Function).ScriptBlock

    function Test-EverVigilKnownLayout { return $true }
    function Assert-OwnedInstallRoot {}
    function Remove-EverVigilInteractiveTasksForTransaction {}
    function Rollback-EverVigilInstallTransaction {
        $script:phaseRollbackCount++
    }
    try {
        Set-TestRegistryRecords -Record @()
        $script:phaseRollbackCount = 0
        $preflightFailureState = [pscustomobject](
            $state | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable)
        $preflightFailureState.externalCommitPhase = 'SnapshotReady'
        $preflightFailurePath = Join-Path $testRoot 'preflight-failure.json'
        [IO.File]::WriteAllText(
            $preflightFailurePath,
            'durable fixture',
            [Text.UTF8Encoding]::new($false))
        $script:InstallTransactionMutexTaken = $true
        $preflightFailureRejected = $false
        try {
            Commit-EverVigilInstallTransaction `
                -Path $preflightFailurePath `
                -State $preflightFailureState
        } catch {
            $preflightFailureRejected = $_.Exception.Message -match
                'prior environment was restored'
        } finally {
            $script:InstallTransactionMutexTaken = $false
        }
        if (-not $preflightFailureRejected -or
            $script:phaseRollbackCount -ne 1 -or
            [string]$preflightFailureState.externalCommitPhase -cne
                'SnapshotReady') {
            throw 'SnapshotReady finalization failure did not select rollback before the point of no return.'
        }
        Remove-Item `
            -LiteralPath $preflightFailurePath `
            -Force `
            -ErrorAction SilentlyContinue

        function Assert-EverVigilInstallerFinalizationPreflight {}
        function Invoke-SystemBrokerTransaction {
            $script:phaseBrokerCount++
            if ($script:phaseBrokerFailuresRemaining -gt 0) {
                $script:phaseBrokerFailuresRemaining--
                throw 'simulated authenticated broker response loss'
            }
        }
        function Write-EverVigilInstallTransaction {
            param([string]$Path, $State)
            $script:phaseWrites.Add([string]$State.externalCommitPhase)
            if (-not [string]::IsNullOrWhiteSpace(
                    [string]$script:phaseWriteFailure) -and
                [string]$State.externalCommitPhase -ceq
                    [string]$script:phaseWriteFailure) {
                $script:phaseWriteFailure = ''
                throw 'simulated durable phase write failure'
            }
        }
        function Resume-VerifiedTransactionTreeRemoval {}
        function Remove-TemporaryPublishTree {
            if ($script:phaseCleanupFailuresRemaining -gt 0) {
                $script:phaseCleanupFailuresRemaining--
                throw 'simulated external cleanup interruption'
            }
        }
        function Remove-VerifiedTransactionTree {
            param(
                [string]$TransactionPath,
                $State,
                [string]$Role,
                [string]$Kind,
                [string]$OriginalInstallRoot
            )
            $script:phaseCleanupOrder.Add("tree:$Role")
        }
        function Remove-TransactionRecoveryFiles {
            if ($script:phaseRecoveryFailuresRemaining -gt 0) {
                $script:phaseRecoveryFailuresRemaining--
                throw 'simulated recovery evidence deletion interruption'
            }
            $script:phaseCleanupOrder.Add('recovery')
        }

        function New-PhaseFixtureState {
            param([Parameter(Mandatory)][string]$Phase)

            return [pscustomobject]@{
                transactionId = $transactionId
                ownerSid = Get-EverVigilOwnerSid
                installRoot = $installRoot
                previousInstallRoot = $installRoot
                status = if ($Phase -in @('SystemCommitted', 'CleanupComplete')) {
                    'committed'
                } else {
                    'readyToCommit'
                }
                externalCommitPhase = $Phase
                externalArtifactSnapshots = @($state.externalArtifactSnapshots)
                destinationBackupPlanned = $true
                previousBackupPlanned = $true
                destinationOwnedInstallPresent = $true
                runtimeConfigurationReady = $false
                legacyCredentialFound = $false
                legacyTokenPath = ''
                legacyCleanupAuthorized = $false
            }
        }

        $forwardCases = @(
            [pscustomobject]@{
                Name = 'SnapshotReady success'
                Phase = 'SnapshotReady'
                BrokerFailures = 0
                WriteFailure = ''
                CleanupFailures = 0
                RecoveryFailures = 0
                ExpectedBrokerCalls = 1
                ExpectedWrites = @(
                    'SystemCommitPrepared',
                    'SystemCommitted',
                    'CleanupComplete')
                ExpectedCleanupOrder =
                    'tree:stagingRoot,tree:backupRoot,tree:previousBackupRoot,recovery'
            }
            [pscustomobject]@{
                Name = 'SystemCommitPrepared resume'
                Phase = 'SystemCommitPrepared'
                BrokerFailures = 0
                WriteFailure = ''
                CleanupFailures = 0
                RecoveryFailures = 0
                ExpectedBrokerCalls = 1
                ExpectedWrites = @('SystemCommitted', 'CleanupComplete')
                ExpectedCleanupOrder =
                    'tree:backupRoot,tree:previousBackupRoot,recovery'
            }
            [pscustomobject]@{
                Name = 'SystemCommitted resume'
                Phase = 'SystemCommitted'
                BrokerFailures = 0
                WriteFailure = ''
                CleanupFailures = 0
                RecoveryFailures = 0
                ExpectedBrokerCalls = 0
                ExpectedWrites = @('CleanupComplete')
                ExpectedCleanupOrder =
                    'tree:backupRoot,tree:previousBackupRoot,recovery'
            }
            [pscustomobject]@{
                Name = 'CleanupComplete resume'
                Phase = 'CleanupComplete'
                BrokerFailures = 0
                WriteFailure = ''
                CleanupFailures = 0
                RecoveryFailures = 0
                ExpectedBrokerCalls = 0
                ExpectedWrites = @()
                ExpectedCleanupOrder =
                    'tree:backupRoot,tree:previousBackupRoot,recovery'
            }
        )
        foreach ($forwardCase in $forwardCases) {
            $phasePath = Join-Path `
                $testRoot `
                ("phase-{0}.json" -f
                    ($forwardCase.Name -replace '[^A-Za-z]', '-'))
            [IO.File]::WriteAllText(
                $phasePath,
                'durable fixture',
                [Text.UTF8Encoding]::new($false))
            $phaseState = New-PhaseFixtureState -Phase $forwardCase.Phase
            $script:phaseBrokerCount = 0
            $script:phaseBrokerFailuresRemaining = $forwardCase.BrokerFailures
            $script:phaseWriteFailure = $forwardCase.WriteFailure
            $script:phaseCleanupFailuresRemaining = $forwardCase.CleanupFailures
            $script:phaseRecoveryFailuresRemaining = $forwardCase.RecoveryFailures
            $script:phaseWrites = [Collections.Generic.List[string]]::new()
            $script:phaseCleanupOrder = [Collections.Generic.List[string]]::new()
            Commit-EverVigilInstallTransaction `
                -Path $phasePath `
                -State $phaseState | Out-Null
            if ($script:phaseBrokerCount -ne $forwardCase.ExpectedBrokerCalls -or
                [string]$phaseState.externalCommitPhase -cne 'CleanupComplete' -or
                (Test-Path -LiteralPath $phasePath) -or
                [string]::Join(',', $script:phaseWrites) -cne
                    [string]::Join(',', $forwardCase.ExpectedWrites) -or
                [string]::Join(',', $script:phaseCleanupOrder) -cne
                    [string]$forwardCase.ExpectedCleanupOrder) {
                throw "The forward commit phase did not converge: $($forwardCase.Name)"
            }
        }

        foreach ($retryCase in @(
                [pscustomobject]@{
                    Name = 'broker response loss'
                    FirstPhase = 'SystemCommitPrepared'
                    BrokerFailures = 1
                    WriteFailure = ''
                    CleanupFailures = 0
                    RecoveryFailures = 0
                    ExpectedDurablePhase = 'SystemCommitPrepared'
                }
                [pscustomobject]@{
                    Name = 'SystemCommitted durable write loss'
                    FirstPhase = 'SystemCommitPrepared'
                    BrokerFailures = 0
                    WriteFailure = 'SystemCommitted'
                    CleanupFailures = 0
                    RecoveryFailures = 0
                    ExpectedDurablePhase = 'SystemCommitPrepared'
                }
                [pscustomobject]@{
                    Name = 'commit boundary durable write loss'
                    FirstPhase = 'SnapshotReady'
                    BrokerFailures = 0
                    WriteFailure = 'SystemCommitPrepared'
                    CleanupFailures = 0
                    RecoveryFailures = 0
                    ExpectedDurablePhase = 'SnapshotReady'
                }
                [pscustomobject]@{
                    Name = 'external cleanup interruption'
                    FirstPhase = 'SnapshotReady'
                    BrokerFailures = 0
                    WriteFailure = ''
                    CleanupFailures = 1
                    RecoveryFailures = 0
                    ExpectedDurablePhase = 'SnapshotReady'
                }
                [pscustomobject]@{
                    Name = 'final evidence deletion interruption'
                    FirstPhase = 'CleanupComplete'
                    BrokerFailures = 0
                    WriteFailure = ''
                    CleanupFailures = 0
                    RecoveryFailures = 1
                    ExpectedDurablePhase = 'CleanupComplete'
                }
            )) {
            $retryPath = Join-Path `
                $testRoot `
                ("retry-{0}.json" -f
                    ($retryCase.Name -replace '[^A-Za-z]', '-'))
            [IO.File]::WriteAllText(
                $retryPath,
                'durable fixture',
                [Text.UTF8Encoding]::new($false))
            $retryState = New-PhaseFixtureState -Phase $retryCase.FirstPhase
            $script:phaseBrokerCount = 0
            $script:phaseBrokerFailuresRemaining = $retryCase.BrokerFailures
            $script:phaseWriteFailure = $retryCase.WriteFailure
            $script:phaseCleanupFailuresRemaining = $retryCase.CleanupFailures
            $script:phaseRecoveryFailuresRemaining = $retryCase.RecoveryFailures
            $script:phaseWrites = [Collections.Generic.List[string]]::new()
            $script:phaseCleanupOrder = [Collections.Generic.List[string]]::new()
            $firstAttemptFailed = $false
            try {
                Commit-EverVigilInstallTransaction `
                    -Path $retryPath `
                    -State $retryState | Out-Null
            } catch {
                $firstAttemptFailed = $true
            }
            if (-not $firstAttemptFailed -or
                -not (Test-Path -LiteralPath $retryPath -PathType Leaf)) {
                throw "The injected commit interruption did not preserve recovery evidence: $($retryCase.Name)"
            }
            $retryState = New-PhaseFixtureState `
                -Phase $retryCase.ExpectedDurablePhase
            $script:phaseBrokerFailuresRemaining = 0
            $script:phaseWriteFailure = ''
            $script:phaseCleanupFailuresRemaining = 0
            $script:phaseRecoveryFailuresRemaining = 0
            Commit-EverVigilInstallTransaction `
                -Path $retryPath `
                -State $retryState | Out-Null
            if ((Test-Path -LiteralPath $retryPath) -or
                [string]$retryState.externalCommitPhase -cne 'CleanupComplete') {
                throw "The injected commit interruption did not converge on retry: $($retryCase.Name)"
            }
        }
    } finally {
        Set-Item -LiteralPath Function:\Test-EverVigilKnownLayout -Value $originalKnownLayout
        Set-Item -LiteralPath Function:\Assert-OwnedInstallRoot -Value $originalOwnedInstallAssertion
        Set-Item -LiteralPath Function:\Remove-EverVigilInteractiveTasksForTransaction -Value $originalInteractiveCleanup
        Set-Item -LiteralPath Function:\Assert-EverVigilInstallerFinalizationPreflight -Value $originalFinalizationPreflight
        Set-Item -LiteralPath Function:\Rollback-EverVigilInstallTransaction -Value $originalRollback
        Set-Item -LiteralPath Function:\Invoke-SystemBrokerTransaction -Value $originalBrokerTransaction
        Set-Item -LiteralPath Function:\Write-EverVigilInstallTransaction -Value $originalTransactionWriter
        Set-Item -LiteralPath Function:\Resume-VerifiedTransactionTreeRemoval -Value $originalTreeResume
        Set-Item -LiteralPath Function:\Remove-TemporaryPublishTree -Value $originalPublishRemoval
        Set-Item -LiteralPath Function:\Remove-VerifiedTransactionTree -Value $originalTreeRemoval
        Set-Item -LiteralPath Function:\Remove-TransactionRecoveryFiles -Value $originalRecoveryRemoval
        $script:InstallTransactionMutexTaken = $false
        $script:InstallTransactionMutex = $null
    }

    'External install transaction tests passed: byte-exact support and shortcut rollback, typed HKCU rollback with semantic-exact ACL, all 24 partial Inno value boundaries, transaction-bound registry intent, target-version manifests, SnapshotReady rollback, forward-only protected commit phases with crash retry, zero-byte known artifacts, idempotent recovery, and unknown file/value/subkey fail-closed behavior.'
} finally {
    if ($null -ne $originalRegistrySubKey) {
        $script:LegacyCompatibilityApplicationUninstallRegistrySubKey =
            $testRegistrySubKey
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
            $testRegistrySubKey,
            $false)
        $script:LegacyCompatibilityApplicationUninstallRegistrySubKey =
            $originalRegistrySubKey
    }
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
