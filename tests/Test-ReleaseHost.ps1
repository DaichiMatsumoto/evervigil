[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LockPath = (Join-Path $RepositoryRoot '.github\release-host-lock.json'),
    [string]$EvidencePath = (Join-Path $RepositoryRoot 'artifacts\release-host-evidence.json'),
    [string]$SourceSha = $env:GITHUB_SHA
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseHostCriticalFileLocks = [Collections.Generic.List[IO.FileStream]]::new()

function Lock-ReleaseHostCriticalSourceFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$RunnerSid
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $reviewedWorkspace = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')
    if (-not $fullPath.StartsWith(
            "$reviewedWorkspace\",
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "A release-host critical source file escaped the checkout: $fullPath"
    }
    $stream = [IO.FileStream]::new(
        $fullPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A release-host critical source file is not a regular file: $fullPath"
        }
        $current = Split-Path -Parent $fullPath
        while ($true) {
            $ancestor = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (-not $ancestor.PSIsContainer -or
                ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "A release-host critical source ancestry is not a regular directory: $current"
            }
            if ($current -ceq $reviewedWorkspace) {
                break
            }
            if (-not $current.StartsWith(
                    "$reviewedWorkspace\",
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "A release-host critical source ancestry escaped the checkout: $current"
            }
            $current = Split-Path -Parent $current
        }

        $allowedWriters = @(
            'S-1-5-18',
            'S-1-5-32-544',
            'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
            $RunnerSid)
        $acl = Get-Acl -LiteralPath $fullPath -ErrorAction Stop
        $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
            $acl.GetSecurityDescriptorBinaryForm(),
            0)
        if ($null -eq $rawDescriptor.DiscretionaryAcl) {
            throw "A release-host critical source file has a null discretionary ACL: $fullPath"
        }
        try {
            $ownerSid = if ($acl.Owner -is [Security.Principal.SecurityIdentifier]) {
                $acl.Owner.Value
            } elseif ($acl.Owner -is [Security.Principal.IdentityReference]) {
                $acl.Owner.Translate([Security.Principal.SecurityIdentifier]).Value
            } else {
                ([Security.Principal.NTAccount]::new([string]$acl.Owner)).Translate(
                    [Security.Principal.SecurityIdentifier]).Value
            }
        } catch {
            throw "A release-host critical source owner could not be resolved: $fullPath"
        }
        if ($allowedWriters -notcontains $ownerSid) {
            throw "A release-host critical source file has an untrusted owner '$ownerSid': $fullPath"
        }
        $dangerousMask = 0x500D0156
        foreach ($ace in $rawDescriptor.DiscretionaryAcl) {
            if ($ace -isnot [Security.AccessControl.QualifiedAce]) {
                throw "A release-host critical source file has an unsupported ACE: $fullPath"
            }
            if ($ace.AceQualifier -eq
                    [Security.AccessControl.AceQualifier]::AccessDenied) {
                continue
            }
            if ($ace.AceQualifier -ne
                    [Security.AccessControl.AceQualifier]::AccessAllowed -or
                $ace.IsCallback -or $ace.OpaqueLength -ne 0) {
                throw "A release-host critical source file has an unsupported conditional ACE: $fullPath"
            }
            if (([int]$ace.AccessMask -band $dangerousMask) -eq 0) {
                continue
            }
            if ($allowedWriters -notcontains $ace.SecurityIdentifier.Value) {
                throw "A release-host critical source file is writable by an untrusted identity: $fullPath"
            }
        }
        $releaseHostCriticalFileLocks.Add($stream)
    } catch {
        $stream.Dispose()
        throw
    }
}

$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$bootstrapWorkspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\')
if ($RepositoryRoot -cne $bootstrapWorkspace) {
    throw 'The release-host repository root must exactly match GITHUB_WORKSPACE.'
}
$bootstrapRunnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$releasePathIsolationPath = Join-Path $RepositoryRoot 'tests\ReleasePathIsolation.ps1'
foreach ($criticalSourcePath in @(
        (Join-Path $RepositoryRoot 'tests\Test-ReleaseHost.ps1'),
        $releasePathIsolationPath,
        ([IO.Path]::GetFullPath($LockPath)))) {
    Lock-ReleaseHostCriticalSourceFile `
        -Path $criticalSourcePath `
        -WorkspaceRoot $bootstrapWorkspace `
        -RunnerSid $bootstrapRunnerSid
}

if ($null -eq ('EverVigil.ReleaseDirectoryLock' -as [type]) -or
    $null -eq (Get-Command Assert-EverVigilReleaseStateDirectorySecurity -ErrorAction SilentlyContinue)) {
    . $releasePathIsolationPath
}

$releaseHostDirectoryLocks = @()
$releaseHostSentinelLocks = @()
$sourceCheckoutLock = $null

function Assert-ExactJsonProperties {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Description
    )

    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
        throw "$Description must be a JSON object."
    }
    $actual = @($Element.EnumerateObject() | ForEach-Object { $_.Name })
    $actualSorted = (@($actual | Sort-Object -CaseSensitive) -join "`n")
    $expectedSorted = (@($Expected | Sort-Object -CaseSensitive) -join "`n")
    if (@($actual | Group-Object | Where-Object Count -ne 1).Count -ne 0 -or
        @($actual).Count -ne @($Expected).Count -or
        $actualSorted -cne $expectedSorted) {
        throw "$Description does not have the exact reviewed property set."
    }
}

function Get-RequiredJsonString {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string]$Name
    )

    $value = $Element.GetProperty($Name)
    if ($value.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
        throw "Release host lock property '$Name' must be a JSON string."
    }
    $text = $value.GetString()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Release host lock property '$Name' is empty."
    }
    return $text
}

function Get-NormalizedSha256 {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string]$Name
    )

    $value = Get-RequiredJsonString -Element $Element -Name $Name
    if ($value -cnotmatch '\A[0-9a-f]{64}\z') {
        throw "Release host lock property '$Name' is not a lowercase SHA-256."
    }
    return $value
}

function Get-SidValue {
    param([Parameter(Mandatory)][object]$Identity)

    try {
        if ($Identity -is [Security.Principal.SecurityIdentifier]) {
            return $Identity.Value
        }
        if ($Identity -is [Security.Principal.IdentityReference]) {
            return $Identity.Translate([Security.Principal.SecurityIdentifier]).Value
        }
        return ([Security.Principal.NTAccount]::new([string]$Identity)).Translate(
            [Security.Principal.SecurityIdentifier]).Value
    } catch {
        throw "An ACL identity could not be resolved to a SID: $Identity"
    }
}

function Assert-ReleaseHostNullDaclGuard {
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
        'S-1-5-32-544')
    $nullDaclDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
        [Security.AccessControl.ControlFlags]::None,
        $administratorsSid,
        $administratorsSid,
        $null,
        $null)
    try {
        Assert-EverVigilAccessControlDescriptor `
            -Descriptor $nullDaclDescriptor `
            -AllowedWriterSids @('S-1-5-32-544') `
            -DangerousAccessMask 0 `
            -Description 'A release-host dependency' `
            -Path '<null-DACL self-test>'
    } catch {
        if ($_.Exception.Message -cne
                'A release-host dependency has a null discretionary ACL: <null-DACL self-test>') {
            throw
        }
        return
    }
    throw 'The release-host null-DACL guard accepted an unrestricted descriptor.'
}

function Assert-ProtectedPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$RequireSingleLink
    )

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "A release-host dependency path is not absolute: $Path"
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "A release-host dependency is missing: $fullPath"
    }
    $file = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "A release-host dependency is a reparse point: $fullPath"
    }

    $allowedWriters = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $dangerousRights =
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership

    $protectedRoots = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } |
        Sort-Object Length -Descending -Unique
    $protectedRoot = $protectedRoots | Where-Object {
        $fullPath.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($protectedRoot)) {
        throw "A release-host dependency is outside a fixed Program Files root: $fullPath"
    }
    $current = $fullPath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A release-host dependency ancestry contains a reparse point: $current"
        }
        $acl = Get-Acl -LiteralPath $current -ErrorAction Stop
        $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
            $acl.GetSecurityDescriptorBinaryForm(),
            0)
        Assert-EverVigilAccessControlDescriptor `
            -Descriptor $rawDescriptor `
            -AllowedWriterSids $allowedWriters `
            -DangerousAccessMask ([int]$dangerousRights) `
            -Description 'A release-host dependency' `
            -Path $current
        $ownerSid = Get-SidValue -Identity $acl.Owner
        if ($allowedWriters -notcontains $ownerSid) {
            throw "A release-host dependency has an untrusted owner '$ownerSid': $current"
        }
        if ([string]::Equals($current, $protectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = Split-Path -Parent $current
    }

    if ($RequireSingleLink -and [EverVigil.ReleaseFileIdentity]::GetLinkCount($fullPath) -ne 1) {
        throw "A release-host executable has more than one hard link: $fullPath"
    }
    return $fullPath
}

function Assert-SignedFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PublisherOrganization
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate) {
        throw "A release-host dependency does not have a valid Authenticode signature: $Path"
    }
    $organizationPattern =
        '(?:\A|,\s*)O=' + [regex]::Escape($PublisherOrganization) + '(?:,|\z)'
    if ($signature.SignerCertificate.Subject -notmatch $organizationPattern) {
        throw "A release-host dependency has an unexpected Authenticode publisher: $Path"
    }
    return $signature.SignerCertificate.Subject
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace EverVigil
{
    public static class ReleaseFileIdentity
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            internal uint FileAttributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            internal System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            internal System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            internal uint VolumeSerialNumber;
            internal uint FileSizeHigh;
            internal uint FileSizeLow;
            internal uint NumberOfLinks;
            internal uint FileIndexHigh;
            internal uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out BY_HANDLE_FILE_INFORMATION information);

        public static uint GetLinkCount(string path)
        {
            using (SafeFileHandle handle = CreateFileW(path, 0x80, 0x7, IntPtr.Zero, 3, 0x80, IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                BY_HANDLE_FILE_INFORMATION information;
                if (!GetFileInformationByHandle(handle, out information))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return information.NumberOfLinks;
            }
        }
    }
}
'@

Assert-ReleaseHostNullDaclGuard

if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
    throw "The reviewed release-host lock file is missing: $LockPath"
}
$lockBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $LockPath))
$jsonOptions = [System.Text.Json.JsonDocumentOptions]::new()
$jsonOptions.AllowTrailingCommas = $false
$jsonOptions.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
$jsonOptions.MaxDepth = 16
$lockMemory = [ReadOnlyMemory[byte]]::new($lockBytes)
$document = [System.Text.Json.JsonDocument]::Parse($lockMemory, $jsonOptions)
try {
    $root = $document.RootElement
    Assert-ExactJsonProperties $root @(
        'schemaVersion', 'snapshotId', 'releaseShell', 'operatingSystem', 'tailscale', 'dotnet',
        'powerShell', 'windowsResourceCompiler', 'innoSetup') 'Release host lock'
    if ($root.GetProperty('schemaVersion').GetInt32() -ne 3) {
        throw 'The release-host lock schema version is unsupported.'
    }
    $snapshotId = Get-RequiredJsonString $root 'snapshotId'
    $releaseShellLock = $root.GetProperty('releaseShell')
    $osLock = $root.GetProperty('operatingSystem')
    $tailscaleLock = $root.GetProperty('tailscale')
    $dotnetLock = $root.GetProperty('dotnet')
    $powerShellLock = $root.GetProperty('powerShell')
    $resourceCompilerLock = $root.GetProperty('windowsResourceCompiler')
    $innoLock = $root.GetProperty('innoSetup')
    Assert-ExactJsonProperties $osLock @(
        'editionId', 'displayVersion', 'buildNumber', 'updateBuildRevision', 'architecture') 'Operating-system lock'
    Assert-ExactJsonProperties $releaseShellLock @(
        'hostPath', 'sha256') 'Release shell lock'
    Assert-ExactJsonProperties $tailscaleLock @(
        'executablePath', 'version', 'commandVersion', 'sha256', 'publisherOrganization',
        'officialMsiUrl', 'officialMsiSha256') 'Tailscale lock'
    Assert-ExactJsonProperties $dotnetLock @(
        'hostPath', 'hostVersion', 'hostSha256', 'sdkVersion', 'msbuildPath', 'msbuildSha256',
        'nugetProtocolPath', 'nugetProtocolVersion', 'nugetProtocolSha256',
        'publisherOrganization') '.NET lock'
    Assert-ExactJsonProperties $powerShellLock @(
        'hostPath', 'version', 'sha256', 'publisherOrganization') 'PowerShell lock'
    Assert-ExactJsonProperties $resourceCompilerLock @(
        'compilerPath', 'version', 'sha256', 'publisherOrganization') 'Windows resource compiler lock'
    Assert-ExactJsonProperties $innoLock @(
        'compilerPath', 'version', 'sha256', 'publisherOrganization') 'Inno Setup lock'

    if ($env:RUNNER_ENVIRONMENT -cne 'self-hosted') {
        throw 'A private release candidate must run on a dedicated self-hosted runner.'
    }
    if ($env:EVERVIGIL_RELEASE_EPHEMERAL -cne 'true') {
        throw 'The release runner must be externally registered as a one-job ephemeral runner.'
    }
    if ($env:EVERVIGIL_RELEASE_SNAPSHOT_ID -cne $snapshotId) {
        throw 'The runner snapshot identity does not match the reviewed release-host lock.'
    }
    if ($env:GITHUB_REF -cne 'refs/heads/main') {
        throw 'A private release candidate may be built only from refs/heads/main.'
    }
    if ($SourceSha -cnotmatch '\A[0-9a-f]{40}\z') {
        throw 'The release source SHA is not an exact lowercase Git commit ID.'
    }

    $expectedModulePath =
        'C:\Program Files\PowerShell\7\Modules;' +
        'C:\Windows\System32\WindowsPowerShell\v1.0\Modules'
    if ($env:PSModulePath -cne $expectedModulePath) {
        throw 'The release shell did not replace PSModulePath with the protected system-only allowlist.'
    }
    $prohibitedEnvironmentPrefixes = @(
        'DOTNET_'
        'CORECLR_'
        'COMPLUS_'
        'COR_'
        'MSBUILD'
        'NUGET_'
        'RESTORE')
    $prohibitedEnvironmentNames = @(
        'DirectoryBuildPropsPath'
        'DirectoryBuildTargetsPath'
        'ImportDirectoryBuildProps'
        'ImportDirectoryBuildTargets'
        'CustomBeforeDirectoryBuildProps'
        'CustomAfterDirectoryBuildProps'
        'CustomBeforeDirectoryBuildTargets'
        'CustomAfterDirectoryBuildTargets'
        'CustomBeforeMicrosoftCommonProps'
        'CustomAfterMicrosoftCommonProps'
        'CustomBeforeMicrosoftCommonTargets'
        'CustomAfterMicrosoftCommonTargets'
        'CustomBeforeMicrosoftCSharpTargets'
        'CustomAfterMicrosoftCSharpTargets'
        'BaseIntermediateOutputPath'
        'ImportProjectExtensionProps'
        'ProjectAssetsFile'
        'NuGetLockFilePath')
    $injectedEnvironment = @(Get-ChildItem Env: | Where-Object {
        $name = [string]$_.Name
        @($prohibitedEnvironmentPrefixes | Where-Object {
            $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
        }).Count -ne 0 -or
        @($prohibitedEnvironmentNames | Where-Object {
            [string]::Equals($name, $_, [StringComparison]::OrdinalIgnoreCase)
        }).Count -ne 0
    })
    if ($injectedEnvironment.Count -ne 0) {
        throw 'The release shell retained a prohibited .NET, MSBuild, or NuGet environment override.'
    }

    $workspaceRoot = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $env:GITHUB_WORKSPACE `
        -Description 'Reviewed source checkout'
    $workingDirectory = Get-EverVigilNormalizedDirectoryPath `
        -Path (Get-Location).ProviderPath `
        -Description 'Release-host working directory'
    if ($workingDirectory -cne $workspaceRoot) {
        throw 'The release-host working directory must exactly match GITHUB_WORKSPACE.'
    }
    $runnerTemp = Assert-EverVigilDirectoryOutside `
        -Path $env:RUNNER_TEMP `
        -ForbiddenRoot $workspaceRoot `
        -Description 'RUNNER_TEMP'

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    Assert-EverVigilReleaseStateDirectorySecurity `
        -Path $workspaceRoot `
        -RunnerSid $identity.User.Value `
        -Description 'Reviewed source checkout' | Out-Null
    Assert-EverVigilReleaseStateDirectorySecurity `
        -Path $runnerTemp `
        -RunnerSid $identity.User.Value `
        -Description 'RUNNER_TEMP' | Out-Null
    $releaseHostDirectoryLocks = @(Lock-EverVigilDirectoryAncestries `
        -Paths @($workspaceRoot, $runnerTemp) `
        -Description 'Release-host directory ancestry')
    $releaseHostSentinelLocks = @(New-EverVigilDirectorySentinelLocks `
        -Paths @($runnerTemp) `
        -Description 'RUNNER_TEMP')
    $sourceCheckoutLock = [IO.FileStream]::new(
        [IO.Path]::GetFullPath($LockPath),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    $evidenceDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($EvidencePath))
    $expectedEvidenceDirectory = Join-Path $RepositoryRoot 'artifacts'
    if ($evidenceDirectory -cne $expectedEvidenceDirectory) {
        throw 'Release-host evidence must be written only to the reviewed artifacts root.'
    }
    $evidenceDirectory = New-EverVigilFreshIsolatedRoot `
        -Root $workspaceRoot `
        -Path $evidenceDirectory `
        -Description 'Release artifacts root'
    Assert-EverVigilReleaseStateDirectorySecurity `
        -Path $evidenceDirectory `
        -RunnerSid $identity.User.Value `
        -Description 'Release artifacts root' | Out-Null
    $releaseHostDirectoryLocks += @(Lock-EverVigilDirectoryAncestries `
        -Paths @($evidenceDirectory) `
        -Description 'Release artifacts root')
    $releaseHostSentinelLocks += @(New-EverVigilDirectorySentinelLocks `
        -Paths @($evidenceDirectory) `
        -Description 'Release artifacts root')
    Assert-EverVigilDirectoryOutside `
        -Path $runnerTemp `
        -ForbiddenRoot $workspaceRoot `
        -Description 'RUNNER_TEMP' | Out-Null
    Assert-EverVigilReleaseStateDirectorySecurity `
        -Path $runnerTemp `
        -RunnerSid $identity.User.Value `
        -Description 'RUNNER_TEMP' | Out-Null

    foreach ($secretName in @(
            'GH_TOKEN', 'GITHUB_TOKEN', 'TS_AUTHKEY', 'TAILSCALE_AUTHKEY', 'OPENAI_API_KEY',
            'AZURE_OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'CODEX_API_KEY', 'HTTP_PROXY',
            'HTTPS_PROXY', 'ALL_PROXY')) {
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($secretName))) {
            throw "The release validation process inherited prohibited credential or proxy environment: $secretName"
        }
    }

    if (@($identity.Groups.Value) -contains 'S-1-5-32-544') {
        throw 'The release runner account must be a dedicated standard user, not an Administrators member.'
    }
    $whoamiPath = Join-Path $env:SystemRoot 'System32\whoami.exe'
    $groupRows = @(& $whoamiPath /groups /fo csv /nh |
        ConvertFrom-Csv -Header Name,Type,Sid,Attributes)
    if (@($groupRows | Where-Object Sid -eq 'S-1-16-8192').Count -ne 1 -or
        @($groupRows | Where-Object Sid -eq 'S-1-16-12288').Count -ne 0) {
        throw 'The release validation process must run at Medium integrity only.'
    }

    $windows = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $editionId = Get-RequiredJsonString $osLock 'editionId'
    $displayVersion = Get-RequiredJsonString $osLock 'displayVersion'
    $buildNumber = Get-RequiredJsonString $osLock 'buildNumber'
    $ubr = $osLock.GetProperty('updateBuildRevision').GetInt32()
    $architecture = Get-RequiredJsonString $osLock 'architecture'
    if ([string]$windows.EditionID -cne $editionId -or
        [string]$windows.DisplayVersion -cne $displayVersion -or
        [string]$windows.CurrentBuildNumber -cne $buildNumber -or
        [int]$windows.UBR -ne $ubr -or
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -cne $architecture -or
        [int]$windows.CurrentBuildNumber -lt 22000) {
        throw 'The release runner is not the exact reviewed Windows 11 Pro x64 image.'
    }

    $tailscalePath = Assert-ProtectedPath `
        -Path (Get-RequiredJsonString $tailscaleLock 'executablePath') `
        -RequireSingleLink
    $releaseShellPath = Assert-ProtectedPath `
        -Path (Get-RequiredJsonString $releaseShellLock 'hostPath') `
        -RequireSingleLink
    if ((Get-FileSha256 $releaseShellPath) -cne
        (Get-NormalizedSha256 $releaseShellLock 'sha256')) {
        throw 'The reviewed release shell hash does not match.'
    }
    $tailscaleSha = Get-FileSha256 $tailscalePath
    if ($tailscaleSha -cne (Get-NormalizedSha256 $tailscaleLock 'sha256')) {
        throw 'The installed Tailscale executable hash does not match the reviewed lock.'
    }
    $tailscaleVersion = (Get-Item -LiteralPath $tailscalePath).VersionInfo.ProductVersion
    if ($tailscaleVersion -cne (Get-RequiredJsonString $tailscaleLock 'version')) {
        throw 'The installed Tailscale executable version does not match the reviewed lock.'
    }
    $tailscalePublisher = Assert-SignedFile `
        $tailscalePath `
        (Get-RequiredJsonString $tailscaleLock 'publisherOrganization')
    $tailscaleCommandOutput = @(& $tailscalePath version)
    if ($LASTEXITCODE -ne 0 -or
        $tailscaleCommandOutput.Count -eq 0 -or
        $tailscaleCommandOutput[0] -cne (Get-RequiredJsonString $tailscaleLock 'commandVersion')) {
        throw 'The fixed Tailscale CLI did not report the reviewed version.'
    }

    $dotnetPath = Assert-ProtectedPath `
        -Path (Get-RequiredJsonString $dotnetLock 'hostPath') `
        -RequireSingleLink
    if ((Get-FileSha256 $dotnetPath) -cne (Get-NormalizedSha256 $dotnetLock 'hostSha256')) {
        throw 'The .NET host hash does not match the reviewed lock.'
    }
    $dotnetPublisher = Assert-SignedFile `
        $dotnetPath `
        (Get-RequiredJsonString $dotnetLock 'publisherOrganization')
    $sdkVersion = (& $dotnetPath --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $sdkVersion -cne (Get-RequiredJsonString $dotnetLock 'sdkVersion')) {
        throw 'The active .NET SDK does not match the reviewed lock and global.json.'
    }
    $msbuildPath = Assert-ProtectedPath `
        -Path (Get-RequiredJsonString $dotnetLock 'msbuildPath')
    if ((Get-FileSha256 $msbuildPath) -cne (Get-NormalizedSha256 $dotnetLock 'msbuildSha256')) {
        throw 'The reviewed .NET SDK MSBuild assembly hash does not match.'
    }
    $nuGetProtocolPath = Assert-ProtectedPath `
        -Path (Get-RequiredJsonString $dotnetLock 'nugetProtocolPath') `
        -RequireSingleLink
    if ((Get-FileSha256 $nuGetProtocolPath) -cne
        (Get-NormalizedSha256 $dotnetLock 'nugetProtocolSha256')) {
        throw 'The reviewed NuGet protocol assembly hash does not match.'
    }
    $nuGetProtocolItem = Get-Item -LiteralPath $nuGetProtocolPath -Force
    if ($nuGetProtocolItem.VersionInfo.FileVersion -cne
        (Get-RequiredJsonString $dotnetLock 'nugetProtocolVersion')) {
        throw 'The reviewed NuGet protocol assembly version does not match.'
    }
    $nuGetProtocolPublisher = Assert-SignedFile `
        $nuGetProtocolPath `
        (Get-RequiredJsonString $dotnetLock 'publisherOrganization')

    $powerShellPath = Assert-ProtectedPath `
        -Path (Get-RequiredJsonString $powerShellLock 'hostPath') `
        -RequireSingleLink
    if (-not [string]::Equals(
            [IO.Path]::GetFullPath([Environment]::ProcessPath),
            $powerShellPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release-host validation was not launched by the reviewed PowerShell executable.'
    }
    if ((Get-FileSha256 $powerShellPath) -cne
        (Get-NormalizedSha256 $powerShellLock 'sha256')) {
        throw 'The PowerShell executable hash does not match the reviewed lock.'
    }
    $powerShellPublisher = Assert-SignedFile `
        $powerShellPath `
        (Get-RequiredJsonString $powerShellLock 'publisherOrganization')
    $powerShellVersion = $PSVersionTable.PSVersion.ToString()
    if ($powerShellVersion -cne (Get-RequiredJsonString $powerShellLock 'version')) {
        throw 'The active PowerShell version does not match the reviewed lock.'
    }

    $resourceCompilerPath = Assert-ProtectedPath `
        -Path (Get-RequiredJsonString $resourceCompilerLock 'compilerPath') `
        -RequireSingleLink
    if ((Get-FileSha256 $resourceCompilerPath) -cne
        (Get-NormalizedSha256 $resourceCompilerLock 'sha256')) {
        throw 'The Windows resource compiler hash does not match the reviewed lock.'
    }
    $resourceCompilerPublisher = Assert-SignedFile `
        $resourceCompilerPath `
        (Get-RequiredJsonString $resourceCompilerLock 'publisherOrganization')
    $resourceCompilerVersion =
        (Get-Item -LiteralPath $resourceCompilerPath -Force -ErrorAction Stop).VersionInfo.ProductVersion
    if ($resourceCompilerVersion -cne
        (Get-RequiredJsonString $resourceCompilerLock 'version')) {
        throw 'The Windows resource compiler version does not match the reviewed lock.'
    }

    $innoPath = Assert-ProtectedPath `
        -Path (Get-RequiredJsonString $innoLock 'compilerPath') `
        -RequireSingleLink
    if ((Get-FileSha256 $innoPath) -cne (Get-NormalizedSha256 $innoLock 'sha256')) {
        throw 'The Inno Setup compiler hash does not match the reviewed lock.'
    }
    $innoPublisher = Assert-SignedFile `
        $innoPath `
        (Get-RequiredJsonString $innoLock 'publisherOrganization')
    $innoVersionSources = @(
        (Get-Item -LiteralPath $innoPath).VersionInfo.ProductVersion
        Get-ChildItem -LiteralPath (Split-Path -Parent $innoPath) -Filter 'unins*.exe' -File |
            ForEach-Object { $_.VersionInfo.ProductVersion })
    $innoVersions = @($innoVersionSources | ForEach-Object {
        [regex]::Matches([string]$_, '\d+\.\d+\.\d+') | ForEach-Object Value
    } | Where-Object { $_ -ne '0.0.0' } | Select-Object -Unique)
    if ($innoVersions.Count -ne 1 -or
        $innoVersions[0] -cne (Get-RequiredJsonString $innoLock 'version')) {
        throw 'The Inno Setup compiler version does not match the reviewed lock.'
    }

    $bundledVendorFiles = @(Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -Force |
        Where-Object {
            $_.FullName -notlike "$RepositoryRoot\.git\*" -and
            ($_.Name -ieq 'tailscale.exe' -or $_.Extension -ieq '.msi')
        })
    if ($bundledVendorFiles.Count -ne 0) {
        throw 'Tailscale or an MSI package must never be bundled in the EverVigil repository or release tree.'
    }

    $evidence = [ordered]@{
        schemaVersion = 3
        sourceSha = $SourceSha
        snapshotId = $snapshotId
        releaseShell = [ordered]@{
            path = $releaseShellPath
            sha256 = Get-FileSha256 $releaseShellPath
        }
        runnerName = [string]$env:RUNNER_NAME
        runnerEnvironment = [string]$env:RUNNER_ENVIRONMENT
        ephemeral = $true
        runnerTemp = $runnerTemp
        bootedAtUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('O')
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        userSid = $identity.User.Value
        integrity = 'Medium'
        operatingSystem = [ordered]@{
            product = 'Windows 11 Pro'
            editionId = $editionId
            displayVersion = $displayVersion
            buildNumber = $buildNumber
            updateBuildRevision = $ubr
            architecture = $architecture
            processorIdentifier = [string]$env:PROCESSOR_IDENTIFIER
        }
        tailscale = [ordered]@{
            path = $tailscalePath
            version = $tailscaleVersion
            sha256 = $tailscaleSha
            signerSubject = $tailscalePublisher
            officialMsiUrl = Get-RequiredJsonString $tailscaleLock 'officialMsiUrl'
            officialMsiSha256 = Get-NormalizedSha256 $tailscaleLock 'officialMsiSha256'
        }
        dotnet = [ordered]@{
            path = $dotnetPath
            hostVersion = Get-RequiredJsonString $dotnetLock 'hostVersion'
            sdkVersion = $sdkVersion
            hostSha256 = Get-FileSha256 $dotnetPath
            msbuildSha256 = Get-FileSha256 $msbuildPath
            nugetProtocolVersion = $nuGetProtocolItem.VersionInfo.FileVersion
            nugetProtocolSha256 = Get-FileSha256 $nuGetProtocolPath
            nugetProtocolSignerSubject = $nuGetProtocolPublisher
            signerSubject = $dotnetPublisher
        }
        powerShell = [ordered]@{
            path = $powerShellPath
            version = $powerShellVersion
            sha256 = Get-FileSha256 $powerShellPath
            signerSubject = $powerShellPublisher
        }
        windowsResourceCompiler = [ordered]@{
            path = $resourceCompilerPath
            version = $resourceCompilerVersion
            sha256 = Get-FileSha256 $resourceCompilerPath
            signerSubject = $resourceCompilerPublisher
        }
        innoSetup = [ordered]@{
            path = $innoPath
            version = $innoVersions[0]
            sha256 = Get-FileSha256 $innoPath
            signerSubject = $innoPublisher
        }
    }
    $evidenceBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(
        (($evidence | ConvertTo-Json -Depth 8) + "`n"))
    $evidenceStream = [IO.FileStream]::new(
        [IO.Path]::GetFullPath($EvidencePath),
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read,
        4096,
        [IO.FileOptions]::WriteThrough)
    try {
        $evidenceStream.Write($evidenceBytes, 0, $evidenceBytes.Length)
        $evidenceStream.Flush($true)
    } finally {
        $evidenceStream.Dispose()
    }
    Write-Host "Release host evidence written to $EvidencePath"
} finally {
    if ($null -ne $sourceCheckoutLock) {
        $sourceCheckoutLock.Dispose()
    }
    Close-EverVigilDirectorySentinelLocks -Locks $releaseHostSentinelLocks
    Close-EverVigilDirectoryLocks -Locks $releaseHostDirectoryLocks
    for ($index = $releaseHostCriticalFileLocks.Count - 1; $index -ge 0; $index--) {
        $releaseHostCriticalFileLocks[$index].Dispose()
    }
    $document.Dispose()
}
