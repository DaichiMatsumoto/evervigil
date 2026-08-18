[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$legacyCompatibilityPath = Join-Path $PSScriptRoot 'LegacyCompatibility.generated.ps1'
if (-not (Test-Path -LiteralPath $legacyCompatibilityPath -PathType Leaf)) {
    throw "Required legacy-compatibility constants not found: $legacyCompatibilityPath"
}
. $legacyCompatibilityPath

$script:EverVigilApplicationDataDefinitions = @(
    [pscustomobject]@{
        Name = $script:LegacyCompatibilityDataSettingsFileName
        PresenceProperty = 'settingsWasPresent'
    }
    [pscustomobject]@{
        Name = $script:LegacyCompatibilityDataProtectedTokenFileName
        PresenceProperty = 'tokenWasPresent'
    }
    [pscustomobject]@{
        Name = $script:LegacyCompatibilityDataAppliedSystemConfigurationFileName
        PresenceProperty = 'appliedSystemConfigurationWasPresent'
    }
    [pscustomobject]@{
        Name = $script:LegacyCompatibilityDataSystemConfigurationRequiredFileName
        PresenceProperty = 'systemConfigurationRequiredWasPresent'
    }
    [pscustomobject]@{
        Name = $script:LegacyCompatibilityDataDiagnosticLoggingMarkerFileName
        PresenceProperty = 'diagnosticLoggingWasPresent'
    }
)

$script:EverVigilTransactionDeletionRoles = @(
    'installRoot'
    'previousInstallRoot'
    'backupRoot'
    'previousBackupRoot'
    'stagingRoot'
    'publishRoot'
    'recoveryRoot'
)

$script:EverVigilExternalArtifactRoles = @(
    'current-support-unins-dat'
    'current-support-unins-exe'
    'current-support-uninstall-script'
    'current-support-complete-script'
    'current-support-data-script'
    'current-support-interactive-script'
    'current-support-system-script'
    'current-support-legacy-script'
    'current-support-resolver-script'
    'current-menu-application'
    'current-menu-uninstall'
    'current-startup'
    'legacy-startup'
    'legacy-menu-application'
    'legacy-menu-uninstall'
    'legacy-support-unins-dat'
    'legacy-support-unins-exe'
    'legacy-support-uninstall-script'
    'legacy-support-system-script'
    'legacy-support-resolver-script'
    'legacy-plaintext-token'
)
$script:EverVigilUninstallRegistryRecoveryFileName =
    'external-uninstall-registry.json.rollback'
$script:EverVigilUninstallRegistryMutationMarkerFileName =
    'external-uninstall-registry.intent.json'

function Get-EverVigilApplicationDataDefinitions {
    return @($script:EverVigilApplicationDataDefinitions)
}

function Remove-EverVigilNewApplicationDataFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$State
    )

    if (-not (Test-Path -LiteralPath $DataRoot)) {
        return
    }
    if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) {
        throw "The EverVigil data root is not a directory: $DataRoot"
    }

    foreach ($definition in @(Get-EverVigilApplicationDataDefinitions)) {
        $wasPresent = [bool](Get-EverVigilTransactionValue `
                -State $State `
                -Name $definition.PresenceProperty)
        if ($wasPresent) {
            continue
        }

        $path = Join-Path $DataRoot $definition.Name
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A generated application-data artifact is not a regular file: $path"
        }

        # The rollback journal remains authoritative until every generated
        # artifact is observably absent. A sharing violation or other delete
        # failure must therefore stop recovery instead of retiring evidence.
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $path) {
            throw "A generated application-data artifact remained after rollback: $path"
        }
    }
}

function Get-EverVigilInstallTransactionTemporaryFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    $resolvedRoot = [IO.Path]::GetFullPath($DataRoot)
    if (-not (Test-Path -LiteralPath $resolvedRoot)) {
        return @()
    }
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "The EverVigil data root is not a directory: $resolvedRoot"
    }

    $temporaryPrefix =
        "$($script:LegacyCompatibilityDataTransactionJournalFileName).new-"
    return @(Get-ChildItem `
            -LiteralPath $resolvedRoot `
            -Force `
            -ErrorAction Stop | Where-Object {
                $_.Name.StartsWith(
                    $temporaryPrefix,
                    [StringComparison]::Ordinal)
            })
}

function Get-EverVigilProgramsFolderPath {
    return [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Programs)
}

function Get-EverVigilStartupFolderPath {
    return [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Startup)
}

function Get-EverVigilExternalArtifactDefinitions {
    param([Parameter(Mandatory)]$State)

    $currentSupportRoot = Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall'
    $legacySupportRoot = Join-Path `
        $env:LOCALAPPDATA `
        $script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData
    $programsRoot = Get-EverVigilProgramsFolderPath
    $startupRoot = Get-EverVigilStartupFolderPath
    $currentGroup = Join-Path $programsRoot 'EverVigil'
    $legacyGroup = Join-Path `
        $programsRoot `
        $script:LegacyCompatibilityApplicationProductName
    $legacyTokenPath = [string](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'legacyTokenPath')
    $legacyCleanupProperty = if ($State -is [Collections.IDictionary]) {
        if ($State.Contains('legacyCleanupAuthorized')) {
            $State['legacyCleanupAuthorized']
        } else {
            $false
        }
    } else {
        $property = $State.PSObject.Properties['legacyCleanupAuthorized']
        $null -ne $property -and $property.Value -eq $true
    }
    $legacyCleanupAuthorized = $legacyCleanupProperty -eq $true
    $legacyCredentialFound = [bool](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'legacyCredentialFound')

    $definitions = @(
        [pscustomobject]@{ Role = 'current-support-unins-dat'; Path = (Join-Path $currentSupportRoot 'unins000.dat'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-support-unins-exe'; Path = (Join-Path $currentSupportRoot 'unins000.exe'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-support-uninstall-script'; Path = (Join-Path $currentSupportRoot 'Support\Uninstall.ps1'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-support-complete-script'; Path = (Join-Path $currentSupportRoot 'Support\scripts\Complete-InstallTransaction.ps1'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-support-data-script'; Path = (Join-Path $currentSupportRoot 'Support\scripts\InstallTransactionData.ps1'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-support-interactive-script'; Path = (Join-Path $currentSupportRoot 'Support\scripts\Invoke-InteractiveUserTask.ps1'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-support-system-script'; Path = (Join-Path $currentSupportRoot 'Support\scripts\Invoke-SystemMaintenance.ps1'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-support-legacy-script'; Path = (Join-Path $currentSupportRoot 'Support\scripts\LegacyCompatibility.generated.ps1'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-support-resolver-script'; Path = (Join-Path $currentSupportRoot 'Support\scripts\Resolve-SafeInstallRoot.ps1'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-menu-application'; Path = (Join-Path $currentGroup 'EverVigil.lnk'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-menu-uninstall'; Path = (Join-Path $currentGroup 'Uninstall EverVigil.lnk'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'current-startup'; Path = (Join-Path $startupRoot 'EverVigil.lnk'); InstallerManaged = $true }
        [pscustomobject]@{ Role = 'legacy-startup'; Path = (Join-Path $startupRoot $script:LegacyCompatibilityApplicationStartupShortcutFileName); InstallerManaged = $false }
        [pscustomobject]@{ Role = 'legacy-menu-application'; Path = (Join-Path $legacyGroup "$($script:LegacyCompatibilityApplicationProductName).lnk"); InstallerManaged = $false }
        [pscustomobject]@{ Role = 'legacy-menu-uninstall'; Path = (Join-Path $legacyGroup "Uninstall $($script:LegacyCompatibilityApplicationProductName).lnk"); InstallerManaged = $false }
        [pscustomobject]@{ Role = 'legacy-support-unins-dat'; Path = (Join-Path $legacySupportRoot 'unins000.dat'); InstallerManaged = $false }
        [pscustomobject]@{ Role = 'legacy-support-unins-exe'; Path = (Join-Path $legacySupportRoot 'unins000.exe'); InstallerManaged = $false }
        [pscustomobject]@{ Role = 'legacy-support-uninstall-script'; Path = (Join-Path $legacySupportRoot 'Support\Uninstall.ps1'); InstallerManaged = $false }
        [pscustomobject]@{ Role = 'legacy-support-system-script'; Path = (Join-Path $legacySupportRoot 'Support\scripts\Invoke-SystemMaintenance.ps1'); InstallerManaged = $false }
        [pscustomobject]@{ Role = 'legacy-support-resolver-script'; Path = (Join-Path $legacySupportRoot 'Support\scripts\Resolve-SafeInstallRoot.ps1'); InstallerManaged = $false }
        [pscustomobject]@{ Role = 'legacy-plaintext-token'; Path = $legacyTokenPath; InstallerManaged = $false }
    )
    return @($definitions | ForEach-Object {
            [pscustomobject]@{
                Role = [string]$_.Role
                Path = if ([string]::IsNullOrWhiteSpace([string]$_.Path)) {
                    ''
                } else {
                    [IO.Path]::GetFullPath([string]$_.Path)
                }
                InstallerManaged = [bool]$_.InstallerManaged
                Authorized = if ([string]$_.Role -ceq 'legacy-plaintext-token') {
                    $legacyCredentialFound
                } elseif ([string]$_.Role -clike 'legacy-*') {
                    $legacyCleanupAuthorized
                } else {
                    $true
                }
                BackupName = "external-$([string]$_.Role).rollback"
            }
        })
}

function Test-EverVigilExternalArtifactRecoveryFileName {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ExpectedTransactionId
    )

    if ([string]::Equals(
            $Name,
            $script:EverVigilUninstallRegistryRecoveryFileName,
            [StringComparison]::Ordinal)) {
        return $true
    }
    if ([string]::Equals(
            $Name,
            $script:EverVigilUninstallRegistryMutationMarkerFileName,
            [StringComparison]::Ordinal)) {
        return $true
    }
    if ($Name -cmatch
        ('\A' +
            [regex]::Escape($script:EverVigilUninstallRegistryRecoveryFileName) +
            '\.[0-9a-f]{32}\.tmp\z')) {
        return [string]::IsNullOrWhiteSpace($ExpectedTransactionId) -or
            $Name -cmatch ('\.' + [regex]::Escape(
                    ([guid]$ExpectedTransactionId).ToString('N')) + '\.tmp\z')
    }
    if ($Name -cmatch
        ('\A' +
            [regex]::Escape(
                $script:EverVigilUninstallRegistryMutationMarkerFileName) +
            '\.[0-9a-f]{32}\.tmp\z')) {
        return [string]::IsNullOrWhiteSpace($ExpectedTransactionId) -or
            $Name -cmatch ('\.' + [regex]::Escape(
                    ([guid]$ExpectedTransactionId).ToString('N')) + '\.tmp\z')
    }
    return @($script:EverVigilExternalArtifactRoles | Where-Object {
            [string]::Equals(
                $Name,
                "external-$_.rollback",
                [StringComparison]::Ordinal)
        }).Count -eq 1
}

function Get-EverVigilTransactionValue {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Name
    )

    if ($State -is [Collections.IDictionary]) {
        if (-not $State.Contains($Name)) {
            throw "The install transaction is missing '$Name'."
        }
        return $State[$Name]
    }
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "The install transaction is missing '$Name'."
    }
    return $property.Value
}

function Set-EverVigilTransactionValue {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value
    )

    if ($State -is [Collections.IDictionary]) {
        if (-not $State.Contains($Name)) {
            throw "The install transaction is missing '$Name'."
        }
        $State[$Name] = $Value
        return
    }
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "The install transaction is missing '$Name'."
    }
    $property.Value = $Value
}

function Assert-EverVigilTransactionDeletionRoleAllowed {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Role
    )

    if ($Role -eq 'none') {
        return
    }
    if ($Role -notin $script:EverVigilTransactionDeletionRoles) {
        throw "The install transaction deletion role is invalid: $Role"
    }

    $status = [string](Get-EverVigilTransactionValue -State $State -Name 'status')
    $allowedByStatus = @{
        staging = @('publishRoot', 'stagingRoot')
        pending = @('publishRoot', 'stagingRoot')
        readyToCommit = @('publishRoot', 'stagingRoot')
        committed = @(
            'backupRoot',
            'previousBackupRoot',
            'stagingRoot',
            'publishRoot',
            'recoveryRoot')
        rollingBack = @(
            'installRoot',
            'previousInstallRoot',
            'stagingRoot',
            'publishRoot')
        rolledBack = @('stagingRoot', 'publishRoot', 'recoveryRoot')
    }
    if (-not $allowedByStatus.ContainsKey($status) -or
        $Role -notin @($allowedByStatus[$status])) {
        throw "Deletion role '$Role' is not valid while the transaction is '$status'."
    }
    if ($Role -eq 'backupRoot' -and
        -not [bool](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'destinationBackupPlanned')) {
        throw 'The transaction cannot delete an unplanned destination backup.'
    }
    if ($Role -in @('previousInstallRoot', 'previousBackupRoot') -and
        -not [bool](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'previousBackupPlanned')) {
        throw 'The transaction cannot delete an unplanned previous-installation tree.'
    }
}

function Assert-EverVigilTransactionDeletionIntent {
    param([Parameter(Mandatory)]$State)

    $intent = [string](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'deletionIntent')
    Assert-EverVigilTransactionDeletionRoleAllowed -State $State -Role $intent
}

function Get-EverVigilTransactionDeletionTarget {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Role
    )

    Assert-EverVigilTransactionDeletionRoleAllowed -State $State -Role $Role
    if ($Role -eq 'none') {
        throw 'The none deletion role has no filesystem target.'
    }
    return [IO.Path]::GetFullPath([string](
            Get-EverVigilTransactionValue -State $State -Name $Role))
}

function Get-EverVigilTransactionTreeItem {
    param([Parameter(Mandatory)][string]$Path)

    return Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Assert-EverVigilAuthorizedPartialTree {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Role
    )

    $expected = (Get-EverVigilTransactionDeletionTarget `
            -State $State `
            -Role $Role).TrimEnd('\')
    $root = Get-EverVigilTransactionTreeItem -Path $expected
    if ($null -eq $root) {
        return
    }
    if (-not $root.PSIsContainer) {
        throw "The authorized transaction tree is not a directory: $expected"
    }
    if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove an authorized reparse point: $expected"
    }

    $ancestor = [IO.DirectoryInfo]::new($expected)
    while ($ancestor) {
        if ($ancestor.Exists -and
            ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to remove a transaction tree below a reparse point: $($ancestor.FullName)"
        }
        $ancestor = $ancestor.Parent
    }

    $resolved = (Resolve-Path -LiteralPath $expected -ErrorAction Stop).Path.TrimEnd('\')
    if (-not [string]::Equals(
            $resolved,
            $expected,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected transaction tree: $resolved"
    }
    $resolvedIdentity = Resolve-EverVigilFinalFileSystemPath -Path $resolved
    $expectedIdentity = Resolve-EverVigilFinalFileSystemPath -Path $expected
    if (-not [string]::Equals(
            $resolvedIdentity,
            $expectedIdentity,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a redirected transaction tree: $resolved"
    }

    $entries = @(
        $root
        Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    )
    if (@($entries | Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            }).Count -gt 0) {
        throw "Refusing to remove an authorized tree containing a reparse point: $resolved"
    }
}

function Resume-EverVigilTransactionTreeRemoval {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][scriptblock]$PersistState
    )

    Assert-EverVigilTransactionDeletionIntent -State $State
    $role = [string](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'deletionIntent')
    if ($role -eq 'none') {
        return
    }

    $target = Get-EverVigilTransactionDeletionTarget -State $State -Role $role
    if ($null -ne (Get-EverVigilTransactionTreeItem -Path $target)) {
        Assert-EverVigilAuthorizedPartialTree -State $State -Role $role
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    }
    Set-EverVigilTransactionValue -State $State -Name 'deletionIntent' -Value 'none'
    & $PersistState $State | Out-Null
}

function Invoke-EverVigilTransactionTreeRemoval {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][scriptblock]$PersistState,
        [scriptblock]$ValidateTree = {}
    )

    Assert-EverVigilTransactionDeletionRoleAllowed -State $State -Role $Role
    $currentIntent = [string](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'deletionIntent')
    if ($currentIntent -ne 'none' -and $currentIntent -ne $Role) {
        throw "Deletion role '$currentIntent' must be resumed before '$Role' can begin."
    }

    $target = Get-EverVigilTransactionDeletionTarget -State $State -Role $Role
    if ($null -eq (Get-EverVigilTransactionTreeItem -Path $target)) {
        if ($currentIntent -eq $Role) {
            Set-EverVigilTransactionValue `
                -State $State `
                -Name 'deletionIntent' `
                -Value 'none'
            & $PersistState $State | Out-Null
        }
        return
    }
    if ($currentIntent -eq 'none') {
        & $ValidateTree
        Set-EverVigilTransactionValue `
            -State $State `
            -Name 'deletionIntent' `
            -Value $Role
        & $PersistState $State | Out-Null
    }
    Resume-EverVigilTransactionTreeRemoval `
        -State $State `
        -PersistState $PersistState
}

function Get-EverVigilApplicationDataRecoveryFileNames {
    return @(Get-EverVigilApplicationDataDefinitions | ForEach-Object {
            "$($_.Name).rollback"
        })
}

function Test-EverVigilApplicationDataRecoveryFileName {
    param([Parameter(Mandatory)][string]$Name)

    if ($Name -in @(Get-EverVigilApplicationDataRecoveryFileNames)) {
        return $true
    }
    return $Name -cmatch `
        '\Asettings\.json\.invalid-\d{8}-\d{6}(?:-[0-9a-f]{32})?\.rollback\z' -or
        $Name -cmatch `
        '\Atoken\.dat\.invalid-\d{8}-\d{6}-[0-9a-f]{32}\.rollback\z'
}

function Get-EverVigilFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The transaction data file must be a regular file: $Path"
    }

    $stream = [IO.FileStream]::new(
        $item.FullName,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $algorithm.ComputeHash($stream)
        return -join @($digest | ForEach-Object { $_.ToString('x2') })
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Copy-EverVigilFileDurably {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if ($sourceItem.PSIsContainer -or
        ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The transaction data source must be a regular file: $Source"
    }
    if (Test-Path -LiteralPath $Destination) {
        throw "The transaction data destination already exists: $Destination"
    }

    $sourceStream = $null
    $destinationStream = $null
    try {
        $sourceStream = [IO.FileStream]::new(
            $sourceItem.FullName,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read)
        $destinationStream = [IO.FileStream]::new(
            $Destination,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            81920,
            [IO.FileOptions]::WriteThrough)
        $sourceStream.CopyTo($destinationStream, 81920)
        $destinationStream.Flush($true)
    } catch {
        if ($destinationStream) {
            $destinationStream.Dispose()
            $destinationStream = $null
        }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($destinationStream) {
            $destinationStream.Dispose()
        }
        if ($sourceStream) {
            $sourceStream.Dispose()
        }
    }

    return Get-EverVigilFileSha256 -Path $Destination
}

function Assert-EverVigilFixedExternalTree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedDirectories,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedFiles,
        [switch]$RequireAllFiles,
        [switch]$AllowInstallerManagedPartialFiles
    )

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $fullRoot)) {
        return
    }
    $rootItem = Get-Item -LiteralPath $fullRoot -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The external artifact root is not a regular directory: $fullRoot"
    }
    $entries = @(Get-ChildItem `
            -LiteralPath $fullRoot `
            -Recurse `
            -Force `
            -ErrorAction Stop)
    foreach ($entry in $entries) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The external artifact tree contains a reparse point: $($entry.FullName)"
        }
        $relative = [IO.Path]::GetRelativePath($fullRoot, $entry.FullName)
        $allowed = if ($entry.PSIsContainer) {
            $relative -cin $AllowedDirectories
        } else {
            $relative -cin $AllowedFiles
        }
        if (-not $allowed) {
            throw "The external artifact tree contains an unexpected entry: $relative"
        }
        if (-not $entry.PSIsContainer) {
            if ((-not $AllowInstallerManagedPartialFiles -and
                    $entry.Length -lt 1) -or
                $entry.Length -gt 536870912) {
                throw "The external artifact file size is outside the allowed range: $relative"
            }
            if (Get-Command Get-EverVigilOwnerSid -ErrorAction SilentlyContinue) {
                $expectedOwner = Get-EverVigilOwnerSid
                $actualOwner = [IO.FileSystemAclExtensions]::GetAccessControl(
                    [IO.FileInfo]::new($entry.FullName)).GetOwner(
                    [Security.Principal.SecurityIdentifier]).Value
                if (-not [string]::Equals(
                        $actualOwner,
                        $expectedOwner,
                        [StringComparison]::OrdinalIgnoreCase)) {
                    throw "The external artifact file has an unexpected owner: $relative"
                }
            }
        }
    }
    if ($RequireAllFiles) {
        foreach ($relative in $AllowedFiles) {
            if (-not (Test-Path `
                    -LiteralPath (Join-Path $fullRoot $relative) `
                    -PathType Leaf)) {
                throw "The external artifact tree is incomplete: $relative"
            }
        }
    }
}

function Assert-EverVigilInstallerManagedArtifactTarget {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt 536870912) {
        throw "The installer-managed external artifact is not a bounded regular file: $Path"
    }
    if (Get-Command Get-EverVigilOwnerSid -ErrorAction SilentlyContinue) {
        $expectedOwner = Get-EverVigilOwnerSid
        $actualOwner = [IO.FileSystemAclExtensions]::GetAccessControl(
            [IO.FileInfo]::new($item.FullName)).GetOwner(
            [Security.Principal.SecurityIdentifier]).Value
        if (-not [string]::Equals(
                $actualOwner,
                $expectedOwner,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "The installer-managed external artifact has an unexpected owner: $Path"
        }
    }
}

function Assert-EverVigilExternalShortcutIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ExpectedTargetPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedArguments,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ExpectedWorkingDirectory,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ExpectedIconLocation
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    if (-not (Test-EverVigilShortcutIdentity `
                -Path $Path `
                -ExpectedTargetPath $ExpectedTargetPath `
                -ExpectedArguments $ExpectedArguments)) {
        throw "The external shortcut target or arguments are not owned: $Path"
    }
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $actualWorkingDirectory = [string]$shortcut.WorkingDirectory
        if (-not [string]::IsNullOrWhiteSpace($actualWorkingDirectory)) {
            $actualWorkingDirectory = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($actualWorkingDirectory))
        }
        $allowedWorkingDirectories = @($ExpectedWorkingDirectory | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace($_)) { '' } else {
                    [IO.Path]::GetFullPath($_)
                }
            })
        if (@($allowedWorkingDirectories | Where-Object {
                    [string]::Equals(
                        $_,
                        $actualWorkingDirectory,
                        [StringComparison]::OrdinalIgnoreCase)
                }).Count -eq 0) {
            throw "The external shortcut working directory is not owned: $Path"
        }
        $actualIcon = [string]$shortcut.IconLocation
        $allowedIcons = @($ExpectedIconLocation | ForEach-Object {
                [Environment]::ExpandEnvironmentVariables([string]$_)
            })
        if (@($allowedIcons | Where-Object {
                    [string]::Equals(
                        $_,
                        $actualIcon,
                        [StringComparison]::OrdinalIgnoreCase)
                }).Count -eq 0) {
            throw "The external shortcut icon identity is not owned: $Path"
        }
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

function Assert-EverVigilExternalArtifactPrestate {
    param([Parameter(Mandatory)]$State)

    $legacyCleanupAuthorized = $false
    if ($State -is [Collections.IDictionary]) {
        $legacyCleanupAuthorized = $State.Contains('legacyCleanupAuthorized') -and
            $State['legacyCleanupAuthorized'] -eq $true
    } else {
        $legacyCleanupProperty =
            $State.PSObject.Properties['legacyCleanupAuthorized']
        $legacyCleanupAuthorized = $null -ne $legacyCleanupProperty -and
            $legacyCleanupProperty.Value -eq $true
    }
    $currentSupportFiles = @(
        'unins000.dat'
        'unins000.exe'
        'Support\Uninstall.ps1'
        'Support\scripts\Complete-InstallTransaction.ps1'
        'Support\scripts\InstallTransactionData.ps1'
        'Support\scripts\Invoke-InteractiveUserTask.ps1'
        'Support\scripts\Invoke-SystemMaintenance.ps1'
        'Support\scripts\LegacyCompatibility.generated.ps1'
        'Support\scripts\Resolve-SafeInstallRoot.ps1'
    )
    Assert-EverVigilFixedExternalTree `
        -Root (Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall') `
        -AllowedDirectories @('Support', 'Support\scripts') `
        -AllowedFiles $currentSupportFiles `
        -RequireAllFiles

    $programsRoot = Get-EverVigilProgramsFolderPath
    $currentExecutableTargets = @(
        (Join-Path ([string](Get-EverVigilTransactionValue -State $State -Name 'installRoot')) 'EverVigil.exe')
        (Join-Path ([string](Get-EverVigilTransactionValue -State $State -Name 'previousInstallRoot')) 'EverVigil.exe')
    ) | Select-Object -Unique
    $currentWorkingDirectories = @($currentExecutableTargets | ForEach-Object {
            Split-Path -Parent $_
        }) | Select-Object -Unique
    $currentIconLocations = @('') + @($currentExecutableTargets | ForEach-Object {
            "$_,0"
        })
    Assert-EverVigilExternalShortcutIdentity `
        -Path (Join-Path $programsRoot 'EverVigil\EverVigil.lnk') `
        -ExpectedTargetPath $currentExecutableTargets `
        -ExpectedArguments '' `
        -ExpectedWorkingDirectory $currentWorkingDirectories `
        -ExpectedIconLocation $currentIconLocations
    Assert-EverVigilExternalShortcutIdentity `
        -Path (Join-Path $programsRoot 'EverVigil\Uninstall EverVigil.lnk') `
        -ExpectedTargetPath @((Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall\unins000.exe')) `
        -ExpectedArguments '' `
        -ExpectedWorkingDirectory @('', (Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall')) `
        -ExpectedIconLocation @('', "$(Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall\unins000.exe'),0")
    Assert-EverVigilExternalShortcutIdentity `
        -Path (Join-Path (Get-EverVigilStartupFolderPath) 'EverVigil.lnk') `
        -ExpectedTargetPath $currentExecutableTargets `
        -ExpectedArguments '--background' `
        -ExpectedWorkingDirectory $currentWorkingDirectories `
        -ExpectedIconLocation $currentIconLocations

    Assert-EverVigilFixedExternalTree `
        -Root (Join-Path $programsRoot 'EverVigil') `
        -AllowedDirectories @() `
        -AllowedFiles @('EverVigil.lnk', 'Uninstall EverVigil.lnk') `
        -RequireAllFiles

    if ($legacyCleanupAuthorized) {
        Assert-EverVigilFixedExternalTree `
            -Root (Join-Path `
                $env:LOCALAPPDATA `
                $script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData) `
            -AllowedDirectories @('Support', 'Support\scripts') `
            -AllowedFiles @(
                'unins000.dat'
                'unins000.exe'
                'Support\Uninstall.ps1'
                'Support\scripts\Invoke-SystemMaintenance.ps1'
                'Support\scripts\Resolve-SafeInstallRoot.ps1') `
            -RequireAllFiles
        Assert-EverVigilFixedExternalTree `
            -Root (Join-Path `
                $programsRoot `
                $script:LegacyCompatibilityApplicationProductName) `
            -AllowedDirectories @() `
            -AllowedFiles @(
                "$($script:LegacyCompatibilityApplicationProductName).lnk"
                "Uninstall $($script:LegacyCompatibilityApplicationProductName).lnk") `
            -RequireAllFiles
        $legacyExecutableTargets = @(
            (Join-Path ([string](Get-EverVigilTransactionValue -State $State -Name 'installRoot')) $script:LegacyCompatibilityApplicationExecutableFileName)
            (Join-Path ([string](Get-EverVigilTransactionValue -State $State -Name 'previousInstallRoot')) $script:LegacyCompatibilityApplicationExecutableFileName)
            (Join-Path (Join-Path $env:LOCALAPPDATA $script:LegacyCompatibilityApplicationInstallRootRelativeToLocalAppData) $script:LegacyCompatibilityApplicationExecutableFileName)
        ) | Select-Object -Unique
        $legacyWorkingDirectories = @($legacyExecutableTargets | ForEach-Object {
                Split-Path -Parent $_
            }) | Select-Object -Unique
        $legacyIconLocations = @('') + @($legacyExecutableTargets | ForEach-Object {
                "$_,0"
            })
        Assert-EverVigilExternalShortcutIdentity `
            -Path (Join-Path $programsRoot "$($script:LegacyCompatibilityApplicationProductName)\$($script:LegacyCompatibilityApplicationProductName).lnk") `
            -ExpectedTargetPath $legacyExecutableTargets `
            -ExpectedArguments '' `
            -ExpectedWorkingDirectory $legacyWorkingDirectories `
            -ExpectedIconLocation $legacyIconLocations
        Assert-EverVigilExternalShortcutIdentity `
            -Path (Join-Path $programsRoot "$($script:LegacyCompatibilityApplicationProductName)\Uninstall $($script:LegacyCompatibilityApplicationProductName).lnk") `
            -ExpectedTargetPath @((Join-Path `
                    $env:LOCALAPPDATA `
                    "$($script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData)\unins000.exe")) `
            -ExpectedArguments '' `
            -ExpectedWorkingDirectory @('', (Join-Path $env:LOCALAPPDATA $script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData)) `
            -ExpectedIconLocation @('', "$(Join-Path $env:LOCALAPPDATA "$($script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData)\unins000.exe"),0")
        Assert-EverVigilExternalShortcutIdentity `
            -Path (Join-Path (Get-EverVigilStartupFolderPath) $script:LegacyCompatibilityApplicationStartupShortcutFileName) `
            -ExpectedTargetPath $legacyExecutableTargets `
            -ExpectedArguments '--background' `
            -ExpectedWorkingDirectory $legacyWorkingDirectories `
            -ExpectedIconLocation $legacyIconLocations
    }
}

function New-EverVigilExternalArtifactSnapshots {
    param(
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [Parameter(Mandatory)]$State
    )

    Assert-EverVigilExternalArtifactPrestate -State $State
    New-Item -ItemType Directory -Path $RecoveryRoot -Force | Out-Null
    $snapshots = [Collections.Generic.List[object]]::new()
    foreach ($definition in @(Get-EverVigilExternalArtifactDefinitions -State $State)) {
        $wasPresent = $definition.Authorized -and
            -not [string]::IsNullOrWhiteSpace($definition.Path) -and
            (Test-Path -LiteralPath $definition.Path -PathType Leaf)
        $sha256 = ''
        $length = [long]0
        if ($wasPresent) {
            $sourceItem = Get-Item `
                -LiteralPath $definition.Path `
                -Force `
                -ErrorAction Stop
            if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "An external artifact is a reparse point: $($definition.Path)"
            }
            $length = [long]$sourceItem.Length
            $sha256 = Copy-EverVigilFileDurably `
                -Source $definition.Path `
                -Destination (Join-Path $RecoveryRoot $definition.BackupName)
        }
        $snapshots.Add([ordered]@{
                role = $definition.Role
                wasPresent = [bool]$wasPresent
                length = $length
                sha256 = $sha256
            })
    }
    return @($snapshots)
}

function Assert-EverVigilExternalArtifactSnapshotState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [switch]$RequireBackupFiles
    )

    $ready = [bool](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'externalArtifactSnapshotReady')
    $snapshots = @(Get-EverVigilTransactionValue `
            -State $State `
            -Name 'externalArtifactSnapshots')
    if (-not $ready) {
        if ($snapshots.Count -ne 0) {
            throw 'External artifact snapshots exist without a durable ready marker.'
        }
        return
    }
    $expectedRoles = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($expectedRole in $script:EverVigilExternalArtifactRoles) {
        [void]$expectedRoles.Add([string]$expectedRole)
    }
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($snapshot in $snapshots) {
        $role = [string](Get-EverVigilTransactionValue `
                -State $snapshot `
                -Name 'role')
        $wasPresent = Get-EverVigilTransactionValue `
            -State $snapshot `
            -Name 'wasPresent'
        $length = Get-EverVigilTransactionValue `
            -State $snapshot `
            -Name 'length'
        $sha256 = [string](Get-EverVigilTransactionValue `
                -State $snapshot `
                -Name 'sha256')
        if (-not $expectedRoles.Contains($role) -or -not $seen.Add($role) -or
            $wasPresent -isnot [bool] -or
            ($length -isnot [int] -and $length -isnot [long]) -or
            [long]$length -lt 0 -or
            ($wasPresent -and (
                [long]$length -lt 1 -or
                $sha256 -cnotmatch '\A[0-9a-f]{64}\z')) -or
            (-not $wasPresent -and (
                [long]$length -ne 0 -or
                $sha256 -cne ''))) {
            throw "The external artifact snapshot is invalid: $role"
        }
    }
    if (-not $seen.SetEquals($expectedRoles)) {
        throw 'The install transaction does not contain the exact external artifact snapshot roles.'
    }
    if ($RequireBackupFiles) {
        $definitions = @{}
        foreach ($definition in @(Get-EverVigilExternalArtifactDefinitions -State $State)) {
            $definitions[$definition.Role] = $definition
        }
        foreach ($snapshot in $snapshots | Where-Object { $_.wasPresent -eq $true }) {
            $backup = Join-Path `
                $RecoveryRoot `
                $definitions[[string]$snapshot.role].BackupName
            if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or
                (Get-Item -LiteralPath $backup -Force).Length -ne [long]$snapshot.length -or
                -not [string]::Equals(
                    (Get-EverVigilFileSha256 -Path $backup),
                    [string]$snapshot.sha256,
                    [StringComparison]::Ordinal)) {
                throw "The external artifact rollback snapshot is missing or corrupt: $($snapshot.role)"
            }
        }
    }
}

function Assert-EverVigilLegacyArtifactsMatchSnapshot {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RecoveryRoot
    )

    Assert-EverVigilExternalArtifactSnapshotState `
        -State $State `
        -RecoveryRoot $RecoveryRoot `
        -RequireBackupFiles
    $snapshotByRole = @{}
    foreach ($snapshot in @(
            Get-EverVigilTransactionValue `
                -State $State `
                -Name 'externalArtifactSnapshots')) {
        $snapshotByRole[[string]$snapshot.role] = $snapshot
    }
    foreach ($definition in @(Get-EverVigilExternalArtifactDefinitions -State $State)) {
        if (-not $definition.Authorized -or $definition.InstallerManaged) {
            continue
        }
        $snapshot = $snapshotByRole[$definition.Role]
        $exists = Test-Path -LiteralPath $definition.Path -PathType Leaf
        if ([bool]$snapshot.wasPresent) {
            if (-not $exists -or
                (Get-Item -LiteralPath $definition.Path -Force).Length -ne
                    [long]$snapshot.length -or
                -not [string]::Equals(
                    (Get-EverVigilFileSha256 -Path $definition.Path),
                    [string]$snapshot.sha256,
                    [StringComparison]::Ordinal)) {
                throw "A legacy external artifact changed before finalization: $($definition.Role)"
            }
        } elseif ($exists) {
            throw "A legacy external artifact appeared after its absent pre-state: $($definition.Role)"
        }
    }
}

function Get-EverVigilNormalizedRegistrySecurityDescriptor {
    param([Parameter(Mandatory)][string]$SecurityDescriptor)

    # Windows may recompute the DACL AutoInherited control bit when an
    # otherwise identical ACL is reapplied. It does not change owner, group,
    # protection, inheritance, or any ACE. Remove only that derived bit so the
    # durable comparison remains semantic and all authorization data stays
    # exact.
    $daclStart = $SecurityDescriptor.IndexOf(
        'D:',
        [StringComparison]::Ordinal)
    if ($daclStart -lt 0) {
        return $SecurityDescriptor
    }
    $flagsStart = $daclStart + 2
    $aceStart = $SecurityDescriptor.IndexOf('(', $flagsStart)
    $saclStart = $SecurityDescriptor.IndexOf(
        'S:',
        $flagsStart,
        [StringComparison]::Ordinal)
    $flagsEnd = if ($aceStart -ge 0 -and
        ($saclStart -lt 0 -or $aceStart -lt $saclStart)) {
        $aceStart
    } elseif ($saclStart -ge 0) {
        $saclStart
    } else {
        $SecurityDescriptor.Length
    }
    $flags = $SecurityDescriptor.Substring(
        $flagsStart,
        $flagsEnd - $flagsStart).Replace('AI', '')
    return $SecurityDescriptor.Substring(0, $flagsStart) +
        $flags +
        $SecurityDescriptor.Substring($flagsEnd)
}

function Get-EverVigilUninstallRegistryState {
    $subKey = $script:LegacyCompatibilityApplicationUninstallRegistrySubKey
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subKey, $false)
    if ($null -eq $key) {
        return [ordered]@{
            schemaVersion = 1
            wasPresent = $false
            securityDescriptor = ''
            values = @()
        }
    }
    try {
        if (@($key.GetSubKeyNames()).Count -ne 0) {
            throw 'The application uninstall registry key contains an unexpected subkey.'
        }
        $values = [Collections.Generic.List[object]]::new()
        foreach ($name in @($key.GetValueNames() | Sort-Object)) {
            $kind = $key.GetValueKind($name)
            $rawValue = $key.GetValue(
                $name,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $serialized = switch ($kind) {
                ([Microsoft.Win32.RegistryValueKind]::String) {
                    [string]$rawValue
                }
                ([Microsoft.Win32.RegistryValueKind]::ExpandString) {
                    [string]$rawValue
                }
                ([Microsoft.Win32.RegistryValueKind]::DWord) {
                    ([uint32]$rawValue).ToString(
                        [Globalization.CultureInfo]::InvariantCulture)
                }
                ([Microsoft.Win32.RegistryValueKind]::QWord) {
                    ([uint64]$rawValue).ToString(
                        [Globalization.CultureInfo]::InvariantCulture)
                }
                ([Microsoft.Win32.RegistryValueKind]::MultiString) {
                    @([string[]]$rawValue)
                }
                { $_ -in @(
                        [Microsoft.Win32.RegistryValueKind]::Binary,
                        [Microsoft.Win32.RegistryValueKind]::None) } {
                    [Convert]::ToBase64String([byte[]]$rawValue)
                }
                default {
                    throw "The uninstall registry contains an unsupported value kind: $kind"
                }
            }
            $values.Add([ordered]@{
                    name = [string]$name
                    kind = $kind.ToString()
                    value = $serialized
                })
        }
        return [ordered]@{
            schemaVersion = 1
            wasPresent = $true
            securityDescriptor = Get-EverVigilNormalizedRegistrySecurityDescriptor `
                -SecurityDescriptor ($key.GetAccessControl().GetSecurityDescriptorSddlForm(
                    [Security.AccessControl.AccessControlSections]::Access -bor
                    [Security.AccessControl.AccessControlSections]::Owner -bor
                    [Security.AccessControl.AccessControlSections]::Group))
            values = @($values)
        }
    } finally {
        $key.Dispose()
    }
}

function Write-EverVigilRecoveryJsonDurably {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$TransactionId
    )

    $temporary = "$Path.$(([guid]$TransactionId).ToString('N')).tmp"
    if (Test-Path -LiteralPath $temporary) {
        $item = Get-Item -LiteralPath $temporary -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The recovery JSON temporary has an invalid identity: $temporary"
        }
        Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop
    }
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
            (($Value | ConvertTo-Json -Depth 8 -Compress) + "`n"))
        $stream = [IO.FileStream]::new(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough)
        try {
            if (Get-Command Set-EverVigilAtomicJournalFileAcl -ErrorAction SilentlyContinue) {
                Set-EverVigilAtomicJournalFileAcl -Path $temporary
            }
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        [IO.File]::Move($temporary, $Path, $false)
        if (Get-Command Set-EverVigilAtomicJournalFileAcl -ErrorAction SilentlyContinue) {
            Set-EverVigilAtomicJournalFileAcl -Path $Path
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function New-EverVigilUninstallRegistrySnapshot {
    param(
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [Parameter(Mandatory)][string]$TransactionId
    )

    New-Item -ItemType Directory -Path $RecoveryRoot -Force | Out-Null
    $state = Get-EverVigilUninstallRegistryState
    $path = Join-Path `
        $RecoveryRoot `
        $script:EverVigilUninstallRegistryRecoveryFileName
    Write-EverVigilRecoveryJsonDurably `
        -Path $path `
        -Value $state `
        -TransactionId $TransactionId
    return [pscustomobject]@{
        WasPresent = [bool]$state.wasPresent
        Sha256 = Get-EverVigilFileSha256 -Path $path
    }
}

function New-EverVigilUninstallRegistryMutationMarker {
    param(
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [Parameter(Mandatory)][string]$TransactionId
    )

    $normalizedTransactionId = ([guid]$TransactionId).ToString('N')
    $marker = [ordered]@{
        schemaVersion = 1
        transactionId = $normalizedTransactionId
        appId = $script:LegacyCompatibilityApplicationAppId
        registrySubKey =
            $script:LegacyCompatibilityApplicationUninstallRegistrySubKey
    }
    $path = Join-Path `
        $RecoveryRoot `
        $script:EverVigilUninstallRegistryMutationMarkerFileName
    Write-EverVigilRecoveryJsonDurably `
        -Path $path `
        -Value $marker `
        -TransactionId $normalizedTransactionId
    return Get-EverVigilFileSha256 -Path $path
}

function Assert-EverVigilUninstallRegistryMutationMarker {
    param(
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )

    $path = Join-Path `
        $RecoveryRoot `
        $script:EverVigilUninstallRegistryMutationMarkerFileName
    if ($ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
        -not (Test-Path -LiteralPath $path -PathType Leaf) -or
        -not [string]::Equals(
            (Get-EverVigilFileSha256 -Path $path),
            $ExpectedSha256,
            [StringComparison]::Ordinal)) {
        throw 'The uninstall registry mutation marker is missing or corrupt.'
    }
    try {
        $marker = [Text.UTF8Encoding]::new($false, $true).GetString(
            [IO.File]::ReadAllBytes($path)) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "The uninstall registry mutation marker is invalid: $($_.Exception.Message)"
    }
    $properties = @($marker.PSObject.Properties)
    if ($properties.Count -ne 4 -or
        @($properties.Name | Sort-Object -Unique).Count -ne 4 -or
        @($properties.Name | Where-Object {
                $_ -cnotin @(
                    'schemaVersion', 'transactionId', 'appId', 'registrySubKey')
            }).Count -ne 0 -or
        ($marker.schemaVersion -isnot [int] -and
            $marker.schemaVersion -isnot [long]) -or
        [int]$marker.schemaVersion -ne 1 -or
        $marker.transactionId -isnot [string] -or
        [string]$marker.transactionId -cne ([guid]$TransactionId).ToString('N') -or
        $marker.appId -isnot [string] -or
        -not [string]::Equals(
            [string]$marker.appId,
            $script:LegacyCompatibilityApplicationAppId,
            [StringComparison]::OrdinalIgnoreCase) -or
        $marker.registrySubKey -isnot [string] -or
        [string]$marker.registrySubKey -cne
            $script:LegacyCompatibilityApplicationUninstallRegistrySubKey) {
        throw 'The uninstall registry mutation marker does not match this transaction.'
    }
}

function Read-EverVigilUninstallRegistrySnapshot {
    param(
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )

    $path = Join-Path `
        $RecoveryRoot `
        $script:EverVigilUninstallRegistryRecoveryFileName
    if ($ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
        -not (Test-Path -LiteralPath $path -PathType Leaf) -or
        -not [string]::Equals(
            (Get-EverVigilFileSha256 -Path $path),
            $ExpectedSha256,
            [StringComparison]::Ordinal)) {
        throw 'The uninstall registry rollback snapshot is missing or corrupt.'
    }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString(
            [IO.File]::ReadAllBytes($path))
        $document = [Text.Json.JsonDocument]::Parse($json)
        try {
            if ($document.RootElement.ValueKind -ne
                [Text.Json.JsonValueKind]::Object) {
                throw 'The uninstall registry snapshot root is not an object.'
            }
            $rootProperties = @($document.RootElement.EnumerateObject())
            if ($rootProperties.Count -ne 4 -or
                @($rootProperties.Name | Sort-Object -Unique).Count -ne 4 -or
                @($rootProperties.Name | Where-Object {
                        $_ -cnotin @(
                            'schemaVersion', 'wasPresent',
                            'securityDescriptor', 'values')
                    }).Count -ne 0) {
                throw 'The uninstall registry snapshot schema is not exact.'
            }
        } finally {
            $document.Dispose()
        }
        $snapshot = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "The uninstall registry snapshot is invalid: $($_.Exception.Message)"
    }
    if (($snapshot.schemaVersion -isnot [int] -and
            $snapshot.schemaVersion -isnot [long]) -or
        [int]$snapshot.schemaVersion -ne 1 -or
        $snapshot.wasPresent -isnot [bool] -or
        $snapshot.securityDescriptor -isnot [string] -or
        $snapshot.values -isnot [Array]) {
        throw 'The uninstall registry snapshot contains invalid JSON types.'
    }
    $seenNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($value in @($snapshot.values)) {
        $properties = @($value.PSObject.Properties)
        if ($properties.Count -ne 3 -or
            @($properties.Name | Sort-Object -Unique).Count -ne 3 -or
            @($properties.Name | Where-Object {
                    $_ -cnotin @('name', 'kind', 'value')
                }).Count -ne 0 -or
            $value.name -isnot [string] -or
            $value.kind -isnot [string] -or
            -not $seenNames.Add([string]$value.name) -or
            [string]$value.kind -notin @(
                'String', 'ExpandString', 'DWord', 'QWord',
                'MultiString', 'Binary', 'None')) {
            throw 'The uninstall registry snapshot contains an invalid value record.'
        }
        if ([string]$value.kind -eq 'MultiString') {
            if ($value.value -isnot [Array] -or
                @($value.value | Where-Object { $_ -isnot [string] }).Count -gt 0) {
                throw 'The uninstall registry snapshot contains an invalid multi-string.'
            }
        } elseif ($value.value -isnot [string]) {
            throw 'The uninstall registry snapshot contains an invalid scalar value.'
        }
    }
    if ((-not [bool]$snapshot.wasPresent -and
            (@($snapshot.values).Count -ne 0 -or
                [string]$snapshot.securityDescriptor -cne '')) -or
        ([bool]$snapshot.wasPresent -and
            [string]::IsNullOrWhiteSpace(
                [string]$snapshot.securityDescriptor))) {
        throw 'An absent uninstall registry snapshot unexpectedly contains values.'
    }
    return $snapshot
}

function Test-EverVigilKnownInnoRegistryValue {
    param(
        [Parameter(Mandatory)]$ValueRecord,
        [Parameter(Mandatory)]$State
    )

    $name = [string]$ValueRecord.name
    $kind = [string]$ValueRecord.kind
    $value = $ValueRecord.value
    $installRoot = [IO.Path]::GetFullPath([string](
            Get-EverVigilTransactionValue -State $State -Name 'installRoot'))
    $supportRoot = [IO.Path]::GetFullPath((Join-Path `
                $env:LOCALAPPDATA `
                'EverVigil.Uninstall'))
    $targetVersion = [string](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'targetVersion')
    if ($targetVersion -cnotmatch
        '\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\z') {
        throw 'The install transaction target version is invalid.'
    }
    $targetVersionCore = $targetVersion.Split('-', 2)[0]
    $targetVersionParts = $targetVersionCore.Split('.')
    $targetMajor = [uint32]::Parse(
        $targetVersionParts[0],
        [Globalization.CultureInfo]::InvariantCulture)
    $targetMinor = [uint32]::Parse(
        $targetVersionParts[1],
        [Globalization.CultureInfo]::InvariantCulture)
    $exactStrings = @{
        'Comments' = 'An independent Windows tray utility that keeps Even Terminal running and available.'
        'DisplayIcon' = (Join-Path $installRoot 'EverVigil.exe')
        'DisplayName' = 'EverVigil'
        'DisplayVersion' = $targetVersion
        'HelpLink' = 'https://github.com/DaichiMatsumoto/evervigil/issues'
        'Inno Setup: App Path' = $installRoot.TrimEnd('\')
        'Inno Setup: Icon Group' = 'EverVigil'
        'Inno Setup: User' = [Environment]::UserName
        'InstallLocation' = ($installRoot.TrimEnd('\') + '\')
        'Publisher' = 'Daichi Matsumoto'
        'QuietUninstallString' = ('"{0}" /SILENT /LOG' -f
            (Join-Path $supportRoot 'unins000.exe'))
        'UninstallString' = ('"{0}" /LOG' -f
            (Join-Path $supportRoot 'unins000.exe'))
        'URLInfoAbout' = 'https://github.com/DaichiMatsumoto'
        'URLUpdateInfo' = 'https://github.com/DaichiMatsumoto/evervigil/releases'
    }
    if ($exactStrings.ContainsKey($name)) {
        return $kind -ceq 'String' -and
            [string]::Equals(
                [string]$value,
                [string]$exactStrings[$name],
                [StringComparison]::OrdinalIgnoreCase)
    }
    if ($name -ceq 'Inno Setup: Language') {
        return $kind -ceq 'String' -and
            [string]$value -cin @('english', 'japanese')
    }
    if ($name -ceq 'Inno Setup: Setup Version') {
        return $kind -ceq 'String' -and
            [string]$value -cmatch '\A6\.[0-9]+(?:\.[0-9]+)?\z'
    }
    if ($name -ceq 'InstallDate') {
        return $kind -ceq 'String' -and
            [string]$value -cmatch '\A20[0-9]{6}\z'
    }
    if ($name -ceq 'EstimatedSize') {
        $parsed = [uint32]0
        return $kind -ceq 'DWord' -and
            [uint32]::TryParse(
                [string]$value,
                [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed) -and
            $parsed -gt 0
    }
    $exactDwords = @{
        'MajorVersion' = $targetMajor.ToString(
            [Globalization.CultureInfo]::InvariantCulture)
        'MinorVersion' = $targetMinor.ToString(
            [Globalization.CultureInfo]::InvariantCulture)
        'NoModify' = '1'
        'NoRepair' = '1'
        'VersionMajor' = $targetMajor.ToString(
            [Globalization.CultureInfo]::InvariantCulture)
        'VersionMinor' = $targetMinor.ToString(
            [Globalization.CultureInfo]::InvariantCulture)
    }
    return $exactDwords.ContainsKey($name) -and
        $kind -ceq 'DWord' -and
        [string]$value -ceq [string]$exactDwords[$name]
}

function Assert-EverVigilPartialInnoRegistryOwned {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$PrestateSnapshot,
        [switch]$RequireCompleteCurrent
    )

    $current = Get-EverVigilUninstallRegistryState
    if (-not [bool]$current.wasPresent) {
        if ($RequireCompleteCurrent) {
            throw 'The current Inno uninstall registry key is missing.'
        }
        return
    }
    if ($RequireCompleteCurrent) {
        if (@($current.values).Count -ne 24) {
            throw 'The current Inno uninstall registry does not contain its exact 24-value manifest.'
        }
        foreach ($record in @($current.values)) {
            if (-not (Test-EverVigilKnownInnoRegistryValue `
                        -ValueRecord $record `
                        -State $State)) {
                throw "The current Inno uninstall registry contains an unexpected value: $($record.name)"
            }
        }
        return
    }
    $prestateByName = @{}
    foreach ($record in @($PrestateSnapshot.values)) {
        $prestateByName[[string]$record.name] = $record
    }
    foreach ($record in @($current.values)) {
        $prestateRecord = $prestateByName[[string]$record.name]
        $matchesPrestate = $null -ne $prestateRecord -and
            [string]::Equals(
                ($record | ConvertTo-Json -Depth 5 -Compress),
                ($prestateRecord | ConvertTo-Json -Depth 5 -Compress),
                [StringComparison]::Ordinal)
        if ($matchesPrestate) {
            continue
        }
        if (-not (Test-EverVigilKnownInnoRegistryValue `
                    -ValueRecord $record `
                    -State $State)) {
            throw "The uninstall registry contains an unowned partial value: $($record.name)"
        }
    }
}

function Restore-EverVigilUninstallRegistrySnapshot {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RecoveryRoot
    )

    Assert-EverVigilUninstallRegistryMutationMarker `
        -RecoveryRoot $RecoveryRoot `
        -TransactionId ([string](Get-EverVigilTransactionValue `
                -State $State `
                -Name 'transactionId')) `
        -ExpectedSha256 ([string](Get-EverVigilTransactionValue `
                -State $State `
                -Name 'uninstallRegistryMutationMarkerSha256'))
    $expectedHash = [string](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'uninstallRegistrySnapshotSha256')
    $snapshot = Read-EverVigilUninstallRegistrySnapshot `
        -RecoveryRoot $RecoveryRoot `
        -ExpectedSha256 $expectedHash
    $expectedWasPresent = [bool](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'uninstallRegistryWasPresent')
    if ([bool]$snapshot.wasPresent -ne $expectedWasPresent) {
        throw 'The uninstall registry snapshot presence marker does not match the transaction.'
    }
    $currentState = Get-EverVigilUninstallRegistryState
    $currentCanonical = $currentState | ConvertTo-Json -Depth 8 -Compress
    $snapshotCanonical = $snapshot | ConvertTo-Json -Depth 8 -Compress
    if ([string]::Equals(
            $currentCanonical,
            $snapshotCanonical,
            [StringComparison]::Ordinal)) {
        return
    }
    $subKey = $script:LegacyCompatibilityApplicationUninstallRegistrySubKey
    $currentProbe = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        $subKey,
        $false)
    $currentExists = $null -ne $currentProbe
    if ($null -ne $currentProbe) {
        $currentProbe.Dispose()
    }
    if ($currentExists) {
        Assert-EverVigilPartialInnoRegistryOwned `
            -State $State `
            -PrestateSnapshot $snapshot
    }
    if ($currentExists) {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subKey, $false)
    }
    if ([bool]$snapshot.wasPresent) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey, $true)
        try {
            foreach ($value in @($snapshot.values)) {
                $kind = [Microsoft.Win32.RegistryValueKind]::$([string]$value.kind)
                $restoredValue = switch ([string]$value.kind) {
                'DWord' {
                    $unsigned = [uint32]::Parse(
                        [string]$value.value,
                        [Globalization.CultureInfo]::InvariantCulture)
                    [BitConverter]::ToInt32(
                        [BitConverter]::GetBytes($unsigned),
                        0)
                }
                'QWord' {
                    $unsigned = [uint64]::Parse(
                        [string]$value.value,
                        [Globalization.CultureInfo]::InvariantCulture)
                    [BitConverter]::ToInt64(
                        [BitConverter]::GetBytes($unsigned),
                        0)
                }
                    'MultiString' { ,([string[]]@($value.value)) }
                    { $_ -in @('Binary', 'None') } {
                        ,([Convert]::FromBase64String([string]$value.value))
                    }
                    default { [string]$value.value }
                }
                $key.SetValue([string]$value.name, $restoredValue, $kind)
            }
            $registrySecurity = [Security.AccessControl.RegistrySecurity]::new()
            $registrySecurity.SetSecurityDescriptorSddlForm(
                [string]$snapshot.securityDescriptor,
                [Security.AccessControl.AccessControlSections]::Access -bor
                [Security.AccessControl.AccessControlSections]::Owner -bor
                [Security.AccessControl.AccessControlSections]::Group)
            $key.SetAccessControl($registrySecurity)
            $key.Flush()
        } finally {
            $key.Dispose()
        }
    }
    $restoredCanonical = Get-EverVigilUninstallRegistryState |
        ConvertTo-Json -Depth 8 -Compress
    if (-not [string]::Equals(
            $restoredCanonical,
            $snapshotCanonical,
            [StringComparison]::Ordinal)) {
        throw 'The uninstall registry did not reach its exact rollback state.'
    }
}

function Restore-EverVigilExternalArtifactSnapshots {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [Parameter(Mandatory)][string]$TransactionId
    )

    Assert-EverVigilExternalArtifactSnapshotState `
        -State $State `
        -RecoveryRoot $RecoveryRoot `
        -RequireBackupFiles
    $currentSupportFiles = @(
        'unins000.dat'
        'unins000.exe'
        'Support\Uninstall.ps1'
        'Support\scripts\Complete-InstallTransaction.ps1'
        'Support\scripts\InstallTransactionData.ps1'
        'Support\scripts\Invoke-InteractiveUserTask.ps1'
        'Support\scripts\Invoke-SystemMaintenance.ps1'
        'Support\scripts\LegacyCompatibility.generated.ps1'
        'Support\scripts\Resolve-SafeInstallRoot.ps1'
    )
    Assert-EverVigilFixedExternalTree `
        -Root (Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall') `
        -AllowedDirectories @('Support', 'Support\scripts') `
        -AllowedFiles $currentSupportFiles `
        -AllowInstallerManagedPartialFiles
    $programsRoot = Get-EverVigilProgramsFolderPath
    Assert-EverVigilFixedExternalTree `
        -Root (Join-Path $programsRoot 'EverVigil') `
        -AllowedDirectories @() `
        -AllowedFiles @('EverVigil.lnk', 'Uninstall EverVigil.lnk') `
        -AllowInstallerManagedPartialFiles
    Assert-EverVigilFixedExternalTree `
        -Root (Join-Path `
            $env:LOCALAPPDATA `
            $script:LegacyCompatibilityApplicationUninstallSupportRootRelativeToLocalAppData) `
        -AllowedDirectories @('Support', 'Support\scripts') `
        -AllowedFiles @(
            'unins000.dat'
            'unins000.exe'
            'Support\Uninstall.ps1'
            'Support\scripts\Invoke-SystemMaintenance.ps1'
            'Support\scripts\Resolve-SafeInstallRoot.ps1')
    Assert-EverVigilFixedExternalTree `
        -Root (Join-Path `
            $programsRoot `
            $script:LegacyCompatibilityApplicationProductName) `
        -AllowedDirectories @() `
        -AllowedFiles @(
            "$($script:LegacyCompatibilityApplicationProductName).lnk"
            "Uninstall $($script:LegacyCompatibilityApplicationProductName).lnk")

    $snapshotByRole = @{}
    foreach ($snapshot in @(
            Get-EverVigilTransactionValue `
                -State $State `
                -Name 'externalArtifactSnapshots')) {
        $snapshotByRole[[string]$snapshot.role] = $snapshot
    }
    foreach ($definition in @(Get-EverVigilExternalArtifactDefinitions -State $State)) {
        if (-not $definition.Authorized) {
            continue
        }
        $snapshot = $snapshotByRole[$definition.Role]
        $target = $definition.Path
        $targetExists = Test-Path -LiteralPath $target -PathType Leaf
        if ($targetExists -and $definition.InstallerManaged) {
            Assert-EverVigilInstallerManagedArtifactTarget -Path $target
        }
        if ([bool]$snapshot.wasPresent) {
            if ($targetExists -and -not $definition.InstallerManaged) {
                $actualHash = Get-EverVigilFileSha256 -Path $target
                if (-not [string]::Equals(
                        $actualHash,
                        [string]$snapshot.sha256,
                        [StringComparison]::Ordinal)) {
                    throw "A legacy external artifact changed during the install transaction: $target"
                }
                continue
            }
            New-Item `
                -ItemType Directory `
                -Path (Split-Path -Parent $target) `
                -Force | Out-Null
            $backup = Join-Path $RecoveryRoot $definition.BackupName
            $temporary = "$target.restore-$(([guid]$TransactionId).ToString('N')).tmp"
            try {
                if (Test-Path -LiteralPath $temporary) {
                    $temporaryItem = Get-Item `
                        -LiteralPath $temporary `
                        -Force `
                        -ErrorAction Stop
                    if ($temporaryItem.PSIsContainer -or
                        ($temporaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "The external artifact restore temporary is invalid: $temporary"
                    }
                    Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop
                }
                $copiedHash = Copy-EverVigilFileDurably `
                    -Source $backup `
                    -Destination $temporary
                if (-not [string]::Equals(
                        $copiedHash,
                        [string]$snapshot.sha256,
                        [StringComparison]::Ordinal)) {
                    throw "The restored external artifact failed SHA-256 verification: $($definition.Role)"
                }
                [IO.File]::Move($temporary, $target, $true)
            } finally {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
        } elseif ($targetExists) {
            if (-not $definition.InstallerManaged) {
                throw "An external legacy artifact appeared after an absent pre-state: $target"
            }
            $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction Stop
            if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "The generated external artifact is a reparse point: $target"
            }
            Remove-Item -LiteralPath $target -Force -ErrorAction Stop
        }
    }

    foreach ($directory in @(
            (Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall\Support\scripts')
            (Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall\Support')
            (Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall')
            (Join-Path $programsRoot 'EverVigil')
        )) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -eq 0) {
            Remove-Item -LiteralPath $directory -Force -ErrorAction Stop
        }
    }
    Restore-EverVigilUninstallRegistrySnapshot `
        -State $State `
        -RecoveryRoot $RecoveryRoot

    foreach ($definition in @(Get-EverVigilExternalArtifactDefinitions -State $State)) {
        if (-not $definition.Authorized) {
            continue
        }
        $snapshot = $snapshotByRole[$definition.Role]
        if ([bool]$snapshot.wasPresent) {
            if (-not (Test-Path -LiteralPath $definition.Path -PathType Leaf) -or
                (Get-Item -LiteralPath $definition.Path -Force).Length -ne
                    [long]$snapshot.length -or
                -not [string]::Equals(
                    (Get-EverVigilFileSha256 -Path $definition.Path),
                    [string]$snapshot.sha256,
                    [StringComparison]::Ordinal)) {
                throw "An external artifact did not reach its exact rollback state: $($definition.Role)"
            }
        } elseif ($definition.InstallerManaged -and
            (Test-Path -LiteralPath $definition.Path)) {
            throw "A generated external artifact remained after rollback: $($definition.Role)"
        }
    }
}

function Get-EverVigilQuarantineFileNames {
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][ValidateSet('settings', 'token')][string]$Kind
    )

    if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) {
        return @()
    }
    $pattern = if ($Kind -eq 'settings') {
        '\Asettings\.json\.invalid-\d{8}-\d{6}(?:-[0-9a-f]{32})?\z'
    } else {
        '\Atoken\.dat\.invalid-\d{8}-\d{6}-[0-9a-f]{32}\z'
    }
    return @(Get-ChildItem -LiteralPath $DataRoot -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -cmatch $pattern } |
        ForEach-Object { $_.Name } |
        Sort-Object -Unique)
}

function New-EverVigilApplicationDataSnapshots {
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [Parameter(Mandatory)]$State
    )

    $snapshots = [Collections.Generic.List[object]]::new()
    $snapshotNames = [Collections.Generic.List[string]]::new()
    foreach ($definition in @(Get-EverVigilApplicationDataDefinitions)) {
        $wasPresent = Get-EverVigilTransactionValue `
            -State $State `
            -Name $definition.PresenceProperty
        if (-not [bool]$wasPresent) {
            continue
        }

        $snapshotNames.Add([string]$definition.Name)
    }
    Assert-EverVigilQuarantineState -State $State
    foreach ($property in @('settingsQuarantineFiles', 'tokenQuarantineFiles')) {
        foreach ($name in @(Get-EverVigilTransactionValue -State $State -Name $property)) {
            $snapshotNames.Add([string]$name)
        }
    }

    foreach ($name in $snapshotNames) {
        New-Item -ItemType Directory -Path $RecoveryRoot -Force | Out-Null
        $source = Join-Path $DataRoot $name
        $backup = Join-Path $RecoveryRoot "$name.rollback"
        $sha256 = Copy-EverVigilFileDurably -Source $source -Destination $backup
        $snapshots.Add([ordered]@{
                name = $name
                sha256 = $sha256
            })
    }
    return @($snapshots)
}

function Assert-EverVigilApplicationDataSnapshotState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [Parameter(Mandatory)][string]$Status,
        [switch]$RequireBackupFiles
    )

    $snapshotValues = Get-EverVigilTransactionValue `
        -State $State `
        -Name 'applicationDataSnapshots'
    $snapshotReady = [bool](Get-EverVigilTransactionValue `
            -State $State `
            -Name 'applicationDataSnapshotReady')
    $definitions = @(Get-EverVigilApplicationDataDefinitions)
    $allowed = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in $definitions) {
        [void]$allowed.Add([string]$definition.Name)
    }
    Assert-EverVigilQuarantineState -State $State
    foreach ($property in @('settingsQuarantineFiles', 'tokenQuarantineFiles')) {
        foreach ($name in @(Get-EverVigilTransactionValue -State $State -Name $property)) {
            [void]$allowed.Add([string]$name)
        }
    }

    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $snapshots = @($snapshotValues)
    foreach ($snapshot in $snapshots) {
        if ($null -eq $snapshot) {
            throw 'The install transaction contains an empty application-data snapshot.'
        }
        $name = [string](Get-EverVigilTransactionValue -State $snapshot -Name 'name')
        $sha256 = [string](Get-EverVigilTransactionValue -State $snapshot -Name 'sha256')
        if (-not $allowed.Contains($name) -or -not $seen.Add($name)) {
            throw "The install transaction contains an invalid application-data snapshot: $name"
        }
        if ($sha256 -cnotmatch '\A[0-9a-f]{64}\z') {
            throw "The application-data snapshot SHA-256 is invalid for '$name'."
        }
    }

    if (-not $snapshotReady) {
        if ($Status -notin @('staging', 'pending', 'rollingBack', 'rolledBack') -or
            $seen.Count -ne 0) {
            throw 'The install transaction has no complete application-data snapshot.'
        }
    } elseif ($Status -ne 'staging') {
        $expected = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($definition in $definitions) {
            $wasPresent = Get-EverVigilTransactionValue `
                -State $State `
                -Name $definition.PresenceProperty
            if ([bool]$wasPresent) {
                [void]$expected.Add([string]$definition.Name)
            }
        }
        foreach ($property in @('settingsQuarantineFiles', 'tokenQuarantineFiles')) {
            foreach ($name in @(Get-EverVigilTransactionValue -State $State -Name $property)) {
                [void]$expected.Add([string]$name)
            }
        }
        if (-not $seen.SetEquals($expected)) {
            throw 'The install transaction does not contain the exact required application-data snapshots.'
        }
    }

    if ($RequireBackupFiles) {
        foreach ($snapshot in $snapshots) {
            $name = [string](Get-EverVigilTransactionValue -State $snapshot -Name 'name')
            $expectedHash = [string](
                Get-EverVigilTransactionValue -State $snapshot -Name 'sha256')
            $backup = Join-Path $RecoveryRoot "$name.rollback"
            if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
                throw "The application-data rollback snapshot is missing: $backup"
            }
            $actualHash = Get-EverVigilFileSha256 -Path $backup
            if (-not [string]::Equals(
                    $actualHash,
                    $expectedHash,
                    [StringComparison]::Ordinal)) {
                throw "The application-data rollback snapshot failed SHA-256 verification: $name"
            }
        }
    }
}

function Assert-EverVigilQuarantineState {
    param([Parameter(Mandatory)]$State)

    foreach ($definition in @(
            [pscustomobject]@{
                Property = 'settingsQuarantineFiles'
                Pattern = '\Asettings\.json\.invalid-\d{8}-\d{6}(?:-[0-9a-f]{32})?\z'
            }
            [pscustomobject]@{
                Property = 'tokenQuarantineFiles'
                Pattern = '\Atoken\.dat\.invalid-\d{8}-\d{6}-[0-9a-f]{32}\z'
            }
        )) {
        $values = Get-EverVigilTransactionValue `
            -State $State `
            -Name $definition.Property
        $seen = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($value in @($values)) {
            $name = [string]$value
            if ([string]::IsNullOrWhiteSpace($name) -or
                $name -cnotmatch $definition.Pattern -or
                -not [string]::Equals(
                    [IO.Path]::GetFileName($name),
                    $name,
                    [StringComparison]::Ordinal) -or
                $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
                -not $seen.Add($name)) {
                throw "The install transaction contains an invalid quarantine file name: $name"
            }
        }
    }
}

function Restore-EverVigilApplicationDataSnapshots {
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$RecoveryRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)]$State
    )

    Assert-EverVigilApplicationDataSnapshotState `
        -State $State `
        -RecoveryRoot $RecoveryRoot `
        -Status ([string](Get-EverVigilTransactionValue -State $State -Name 'status')) `
        -RequireBackupFiles
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    $snapshots = Get-EverVigilTransactionValue `
        -State $State `
        -Name 'applicationDataSnapshots'
    foreach ($snapshot in @($snapshots)) {
        $name = [string](Get-EverVigilTransactionValue -State $snapshot -Name 'name')
        $expectedHash = [string](
            Get-EverVigilTransactionValue -State $snapshot -Name 'sha256')
        $backup = Join-Path $RecoveryRoot "$name.rollback"
        $target = Join-Path $DataRoot $name
        $temporary = Join-Path $DataRoot "$name.restore-$TransactionId.tmp"
        if (Test-Path -LiteralPath $temporary) {
            $temporaryItem = Get-Item -LiteralPath $temporary -Force -ErrorAction Stop
            if ($temporaryItem.PSIsContainer -or
                ($temporaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "The application-data restore path is not a regular temporary file: $temporary"
            }
            Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop
        }
        try {
            $copiedHash = Copy-EverVigilFileDurably `
                -Source $backup `
                -Destination $temporary
            if (-not [string]::Equals(
                    $copiedHash,
                    $expectedHash,
                    [StringComparison]::Ordinal)) {
                throw "The restored application-data snapshot failed SHA-256 verification: $name"
            }
            [IO.File]::Move($temporary, $target, $true)
            $restoredHash = Get-EverVigilFileSha256 -Path $target
            if (-not [string]::Equals(
                    $restoredHash,
                    $expectedHash,
                    [StringComparison]::Ordinal)) {
                throw "The application-data target failed SHA-256 verification after restore: $name"
            }
        } finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-EverVigilNewQuarantineFiles {
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)]$State
    )

    Assert-EverVigilQuarantineState -State $State
    if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) {
        return
    }
    foreach ($definition in @(
            [pscustomobject]@{
                Property = 'settingsQuarantineFiles'
                Pattern = '\Asettings\.json\.invalid-\d{8}-\d{6}-[0-9a-f]{32}\z'
            }
            [pscustomobject]@{
                Property = 'tokenQuarantineFiles'
                Pattern = '\Atoken\.dat\.invalid-\d{8}-\d{6}-[0-9a-f]{32}\z'
            }
        )) {
        $existing = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        $priorNames = Get-EverVigilTransactionValue `
            -State $State `
            -Name $definition.Property
        foreach ($name in @($priorNames)) {
            [void]$existing.Add([string]$name)
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $DataRoot -File -Force -ErrorAction Stop |
                Where-Object { $_.Name -cmatch $definition.Pattern })) {
            if (-not $existing.Contains($file.Name)) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            }
        }
    }
}
