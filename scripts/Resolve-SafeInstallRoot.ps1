Set-StrictMode -Version Latest

$legacyCompatibilityPath = Join-Path $PSScriptRoot 'LegacyCompatibility.generated.ps1'
if (-not (Test-Path -LiteralPath $legacyCompatibilityPath -PathType Leaf)) {
    throw "Required legacy-compatibility constants not found: $legacyCompatibilityPath"
}
. $legacyCompatibilityPath

$script:EverVigilAppId = $script:LegacyCompatibilityApplicationAppId
$script:EverVigilOwnershipFileName = '.evervigil-install.json'

function New-EverVigilSystemTransactionMutex {
    $security = [Security.AccessControl.MutexSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $authenticatedUsers = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::AuthenticatedUserSid,
        $null)
    $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new(
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
        $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new(
                $identity,
                [Security.AccessControl.MutexRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow))
    }
    $createdNew = $false
    return [Threading.MutexAcl]::Create(
        $false,
        $script:LegacyCompatibilitySynchronizationSystemTransactionMutex,
        [ref]$createdNew,
        $security)
}

if (-not ('EverVigil.NativeFileSystem' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace EverVigil
{
    public static class NativeFileSystem
    {
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            IntPtr file,
            StringBuilder filePath,
            uint filePathLength,
            uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        public static string GetFinalPath(string path)
        {
            IntPtr handle = CreateFileW(
                path,
                0,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics,
                IntPtr.Zero);
            if (handle == new IntPtr(-1))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            try
            {
                uint capacity = 512;
                while (true)
                {
                    var buffer = new StringBuilder((int)capacity);
                    uint length = GetFinalPathNameByHandleW(handle, buffer, capacity, 0);
                    if (length == 0)
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    if (length < capacity)
                    {
                        string finalPath = buffer.ToString();
                        if (finalPath.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                        {
                            return @"\\" + finalPath.Substring(8);
                        }
                        if (finalPath.StartsWith(@"\\?\", StringComparison.Ordinal))
                        {
                            return finalPath.Substring(4);
                        }
                        return finalPath;
                    }
                    capacity = checked(length + 1);
                }
            }
            finally
            {
                CloseHandle(handle);
            }
        }
    }

    public sealed class BootstrapPathLock : IDisposable
    {
        private const uint GenericRead = 0x80000000;
        private const uint FileReadAttributes = 0x00000080;
        private const uint FileShareRead = 0x00000001;
        private const uint OpenExisting = 3;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const int FileAttributeTagInfo = 9;

        private readonly List<ComponentLock> components;
        private bool disposed;

        private BootstrapPathLock(List<ComponentLock> components)
        {
            this.components = components;
        }

        public long ExecutableLength
        {
            get
            {
                ThrowIfDisposed();
                return components[components.Count - 1].Length;
            }
        }

        public int ComponentCount
        {
            get
            {
                ThrowIfDisposed();
                return components.Count;
            }
        }

        public static BootstrapPathLock Acquire(string executablePath)
        {
            if (String.IsNullOrWhiteSpace(executablePath))
            {
                throw new ArgumentException("The bootstrap executable path is required.", "executablePath");
            }

            string fullPath = Path.GetFullPath(executablePath);
            string root = Path.GetPathRoot(fullPath);
            if (String.IsNullOrWhiteSpace(root) || root.StartsWith(@"\\", StringComparison.Ordinal))
            {
                throw new InvalidDataException("The bootstrap executable must be on a local drive.");
            }

            var paths = new List<string>();
            paths.Add(root);
            string current = root;
            string relative = fullPath.Substring(root.Length);
            string[] segments = relative.Split(
                new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
                StringSplitOptions.RemoveEmptyEntries);
            for (int index = 0; index < segments.Length; index++)
            {
                current = Path.Combine(current, segments[index]);
                paths.Add(current);
            }

            if (paths.Count < 2)
            {
                throw new InvalidDataException("The bootstrap executable path has no file component.");
            }

            var acquired = new List<ComponentLock>();
            try
            {
                for (int index = 0; index < paths.Count; index++)
                {
                    bool expectedDirectory = index != paths.Count - 1;
                    acquired.Add(ComponentLock.Open(paths[index], expectedDirectory));
                }
                var result = new BootstrapPathLock(acquired);
                result.Validate();
                return result;
            }
            catch
            {
                DisposeReverse(acquired);
                throw;
            }
        }

        public void Validate()
        {
            ThrowIfDisposed();
            foreach (ComponentLock component in components)
            {
                component.ValidateIdentity();
                using (ComponentLock reopened = ComponentLock.Open(
                    component.RequestedPath,
                    component.ExpectedDirectory))
                {
                    component.AssertSameIdentity(reopened);
                }
            }
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            DisposeReverse(components);
        }

        private void ThrowIfDisposed()
        {
            if (disposed)
            {
                throw new ObjectDisposedException("BootstrapPathLock");
            }
        }

        private static void DisposeReverse(IList<ComponentLock> locks)
        {
            for (int index = locks.Count - 1; index >= 0; index--)
            {
                locks[index].Dispose();
            }
        }

        private sealed class ComponentLock : IDisposable
        {
            private IntPtr handle;
            private readonly uint volumeSerialNumber;
            private readonly ulong fileIndex;
            private readonly uint attributes;
            private readonly uint reparseTag;
            private readonly uint numberOfLinks;
            private readonly string finalPath;

            private ComponentLock(
                IntPtr handle,
                string requestedPath,
                bool expectedDirectory,
                ByHandleFileInformation information,
                FileAttributeTagInformation tagInformation,
                string finalPath,
                long length)
            {
                this.handle = handle;
                RequestedPath = requestedPath;
                ExpectedDirectory = expectedDirectory;
                volumeSerialNumber = information.VolumeSerialNumber;
                fileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
                attributes = tagInformation.FileAttributes;
                reparseTag = tagInformation.ReparseTag;
                numberOfLinks = information.NumberOfLinks;
                this.finalPath = finalPath;
                Length = length;
            }

            public string RequestedPath { get; private set; }
            public bool ExpectedDirectory { get; private set; }
            public long Length { get; private set; }

            public static ComponentLock Open(string path, bool expectedDirectory)
            {
                uint desiredAccess = FileReadAttributes;
                if (!expectedDirectory)
                {
                    desiredAccess |= GenericRead;
                }
                uint flags = FileFlagOpenReparsePoint;
                if (expectedDirectory)
                {
                    flags |= FileFlagBackupSemantics;
                }

                IntPtr opened = CreateFileW(
                    path,
                    desiredAccess,
                    FileShareRead,
                    IntPtr.Zero,
                    OpenExisting,
                    flags,
                    IntPtr.Zero);
                if (opened == new IntPtr(-1))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not lock bootstrap path component: " + path);
                }

                try
                {
                    ByHandleFileInformation information;
                    if (!GetFileInformationByHandle(opened, out information))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }

                    FileAttributeTagInformation tagInformation;
                    if (!GetFileInformationByHandleEx(
                        opened,
                        FileAttributeTagInfo,
                        out tagInformation,
                        (uint)Marshal.SizeOf(typeof(FileAttributeTagInformation))))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }

                    if ((tagInformation.FileAttributes & FileAttributeReparsePoint) != 0 ||
                        tagInformation.ReparseTag != 0)
                    {
                        throw new InvalidDataException(
                            "A reparse point is forbidden in the bootstrap path: " + path);
                    }

                    bool actualDirectory =
                        (tagInformation.FileAttributes & FileAttributeDirectory) != 0;
                    if (actualDirectory != expectedDirectory)
                    {
                        throw new InvalidDataException(
                            "The bootstrap path component has the wrong type: " + path);
                    }
                    if (!expectedDirectory && information.NumberOfLinks != 1)
                    {
                        throw new InvalidDataException(
                            "The bootstrap executable must have exactly one hard link: " + path);
                    }

                    long length = 0;
                    if (!expectedDirectory && !GetFileSizeEx(opened, out length))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    if (!expectedDirectory && length <= 0)
                    {
                        throw new InvalidDataException("The bootstrap executable is empty.");
                    }

                    string finalPath = ReadFinalPath(opened);
                    IntPtr retained = opened;
                    opened = new IntPtr(-1);
                    return new ComponentLock(
                        retained,
                        path,
                        expectedDirectory,
                        information,
                        tagInformation,
                        finalPath,
                        length);
                }
                finally
                {
                    if (opened != new IntPtr(-1))
                    {
                        CloseHandle(opened);
                    }
                }
            }

            public void ValidateIdentity()
            {
                if (handle == IntPtr.Zero || handle == new IntPtr(-1))
                {
                    throw new ObjectDisposedException("ComponentLock");
                }

                ByHandleFileInformation currentInformation;
                if (!GetFileInformationByHandle(handle, out currentInformation))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                FileAttributeTagInformation currentTag;
                if (!GetFileInformationByHandleEx(
                    handle,
                    FileAttributeTagInfo,
                    out currentTag,
                    (uint)Marshal.SizeOf(typeof(FileAttributeTagInformation))))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                ulong currentIndex =
                    ((ulong)currentInformation.FileIndexHigh << 32) |
                    currentInformation.FileIndexLow;
                if (currentInformation.VolumeSerialNumber != volumeSerialNumber ||
                    currentIndex != fileIndex ||
                    currentTag.FileAttributes != attributes ||
                    currentTag.ReparseTag != reparseTag ||
                    currentInformation.NumberOfLinks != numberOfLinks ||
                    !String.Equals(ReadFinalPath(handle), finalPath, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException(
                        "A locked bootstrap path component changed identity: " + RequestedPath);
                }
            }

            public void AssertSameIdentity(ComponentLock other)
            {
                if (other.volumeSerialNumber != volumeSerialNumber ||
                    other.fileIndex != fileIndex ||
                    other.attributes != attributes ||
                    other.reparseTag != reparseTag ||
                    other.numberOfLinks != numberOfLinks ||
                    !String.Equals(other.finalPath, finalPath, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException(
                        "The bootstrap path no longer resolves to the locked identity: " + RequestedPath);
                }
            }

            public void Dispose()
            {
                if (handle != IntPtr.Zero && handle != new IntPtr(-1))
                {
                    CloseHandle(handle);
                    handle = IntPtr.Zero;
                }
            }
        }

        private static string ReadFinalPath(IntPtr handle)
        {
            uint capacity = 512;
            while (true)
            {
                var buffer = new StringBuilder((int)capacity);
                uint length = GetFinalPathNameByHandleW(handle, buffer, capacity, 0);
                if (length == 0)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if (length < capacity)
                {
                    return buffer.ToString();
                }
                capacity = checked(length + 1);
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileAttributeTagInformation
        {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime
        {
            public uint LowDateTime;
            public uint HighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public FileTime CreationTime;
            public FileTime LastAccessTime;
            public FileTime LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(
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
            IntPtr file,
            out ByHandleFileInformation information);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            IntPtr file,
            int informationClass,
            out FileAttributeTagInformation information,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileSizeEx(IntPtr file, out long fileSize);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            IntPtr file,
            StringBuilder filePath,
            uint filePathLength,
            uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

function Normalize-EverVigilFileSystemPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $root, [StringComparison]::OrdinalIgnoreCase)) {
        return $root
    }
    return $fullPath.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Test-EverVigilPathFullyQualified {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathRooted($Path)) {
        return $false
    }
    try {
        $root = [IO.Path]::GetPathRoot($Path)
    } catch {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($root) -or
        [string]::Equals($root, '\', [StringComparison]::Ordinal) -or
        $root -cmatch '\A[A-Za-z]:\z') {
        return $false
    }
    return $true
}

function Get-EverVigilProcessLocations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [object[]]$Process
    )

    if (-not $PSBoundParameters.ContainsKey('Process')) {
        $processNames = @(
            'EverVigil'
            [IO.Path]::GetFileNameWithoutExtension(
                $script:LegacyCompatibilityApplicationExecutableFileName)
        ) | Select-Object -Unique
        $Process = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
    }
    $prefix = "{0}\" -f ([IO.Path]::GetFullPath($Root).TrimEnd('\'))
    return @($Process | ForEach-Object {
            $processPath = try { [string]$_.Path } catch { '' }
            [pscustomobject]@{
                Process = $_
                Id = [int]$_.Id
                Path = $processPath
                AtInstallRoot = -not [string]::IsNullOrWhiteSpace($processPath) -and
                    $processPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
            }
        })
}

function Get-EverVigilActiveDataRoot {
    [CmdletBinding()]
    param()

    $currentDataRoot = Join-Path $env:LOCALAPPDATA 'EverVigil'
    $legacyDataRoot = Join-Path `
        $env:LOCALAPPDATA `
        $script:LegacyCompatibilityApplicationDataRootRelativeToLocalAppData
    $currentHasState = Test-EverVigilPersistentDataState -Path $currentDataRoot
    $legacyHasState = Test-EverVigilPersistentDataState -Path $legacyDataRoot
    if ($currentHasState -and $legacyHasState) {
        throw 'Both current and legacy application data contain persistent state. Resolve the interrupted migration before continuing.'
    }
    if ($legacyHasState) {
        return [IO.Path]::GetFullPath($legacyDataRoot)
    }
    return [IO.Path]::GetFullPath($currentDataRoot)
}

function Get-EverVigilExecutableAtRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    foreach ($fileName in @(
            'EverVigil.exe'
            $script:LegacyCompatibilityApplicationExecutableFileName
        ) | Select-Object -Unique) {
        $candidate = Join-Path $resolvedRoot $fileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return (Join-Path $resolvedRoot 'EverVigil.exe')
}

function Test-EverVigilShortcutIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ExpectedTargetPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedArguments
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $expectedTargets = @($ExpectedTargetPath | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_) -or
                -not (Test-EverVigilPathFullyQualified -Path $_)) {
                throw "A shortcut target identity is not an absolute path: $_"
            }
            [IO.Path]::GetFullPath($_)
        } | Select-Object -Unique)
    if ($expectedTargets.Count -eq 0) {
        throw 'At least one shortcut target identity is required.'
    }

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $actualTarget = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables([string]$shortcut.TargetPath))
        $targetMatches = @($expectedTargets | Where-Object {
                [string]::Equals(
                    $_,
                    $actualTarget,
                    [StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
        return $targetMatches -and [string]::Equals(
            [string]$shortcut.Arguments,
            $ExpectedArguments,
            [StringComparison]::Ordinal)
    } catch {
        return $false
    } finally {
        if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Remove-EverVigilOwnedShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ExpectedTargetPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedArguments
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    if (-not (Test-EverVigilShortcutIdentity `
                -Path $Path `
                -ExpectedTargetPath $ExpectedTargetPath `
                -ExpectedArguments $ExpectedArguments)) {
        return $false
    }
    Remove-Item -LiteralPath $Path -Force
    if (Test-Path -LiteralPath $Path) {
        throw "An owned shortcut could not be removed: $Path"
    }
    return $true
}

function Test-EverVigilPersistentDataState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }
    $installTransactionTemporaryPrefix =
        "$($script:LegacyCompatibilityDataTransactionJournalFileName).new-"
    $hasInstallTransactionTemporary = @(
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop |
            Where-Object {
                $_.Name.StartsWith(
                    $installTransactionTemporaryPrefix,
                    [StringComparison]::Ordinal)
            }).Count -gt 0
    return $hasInstallTransactionTemporary -or
        (Test-Path -LiteralPath (
            Join-Path $Path $script:LegacyCompatibilityDataSettingsFileName) -PathType Leaf) -or
        (Test-Path -LiteralPath (
            Join-Path $Path $script:LegacyCompatibilityDataProtectedTokenFileName) -PathType Leaf) -or
        (Test-Path -LiteralPath (
            Join-Path $Path $script:LegacyCompatibilityDataTransactionJournalFileName) -PathType Leaf) -or
        (Test-Path -LiteralPath (
            Join-Path $Path $script:LegacyCompatibilityDataAppliedSystemConfigurationFileName) -PathType Leaf) -or
        (Test-Path -LiteralPath (
            Join-Path $Path $script:LegacyCompatibilityDataSystemConfigurationRequiredFileName) -PathType Leaf) -or
        (Test-Path -LiteralPath (
            Join-Path $Path $script:LegacyCompatibilityDataDiagnosticLoggingMarkerFileName) -PathType Leaf) -or
        (Test-Path -LiteralPath (
            Join-Path $Path $script:LegacyCompatibilityDataTransactionRecoveryDirectoryName) -PathType Container)
}

function Resolve-EverVigilFinalFileSystemPath {
    param([Parameter(Mandatory)][string]$Path)

    $current = Normalize-EverVigilFileSystemPath -Path $Path
    $missingSegments = [Collections.Generic.Stack[string]]::new()
    while (-not (Test-Path -LiteralPath $current)) {
        $segment = [IO.Path]::GetFileName($current)
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($segment) -or
            [string]::IsNullOrWhiteSpace($parent)) {
            throw "The installation path has no accessible filesystem ancestor: $Path"
        }
        $missingSegments.Push($segment)
        $current = Normalize-EverVigilFileSystemPath -Path $parent
    }

    try {
        $finalPath = [EverVigil.NativeFileSystem]::GetFinalPath($current)
    } catch {
        throw "The installation path could not be resolved to its final filesystem target: $Path. $($_.Exception.Message)"
    }
    while ($missingSegments.Count -gt 0) {
        $finalPath = Join-Path $finalPath $missingSegments.Pop()
    }
    return Normalize-EverVigilFileSystemPath -Path $finalPath
}

function Get-EverVigilOwnerSid {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = if ($null -eq $identity.User) {
        $null
    } else {
        $identity.User.Value
    }
    if ([string]::IsNullOrWhiteSpace($sid)) {
        throw 'The invoking user SID is unavailable.'
    }

    return $sid
}

function New-EverVigilAtomicJournalFileSecurity {
    $ownerSid = [Security.Principal.SecurityIdentifier]::new(
        (Get-EverVigilOwnerSid))
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetOwner($ownerSid)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($identity in @(
            $ownerSid
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
    return $security
}

function Set-EverVigilAtomicJournalFileAcl {
    param([Parameter(Mandatory)][string]$Path)

    [IO.FileSystemAclExtensions]::SetAccessControl(
        [IO.FileInfo]::new([IO.Path]::GetFullPath($Path)),
        (New-EverVigilAtomicJournalFileSecurity))
}

function Test-EverVigilAtomicJournalFileAcl {
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
        $ownerSid = [Security.Principal.SecurityIdentifier]::new(
            (Get-EverVigilOwnerSid))
        $systemSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::LocalSystemSid,
            $null)
        $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
            $null)
        if (-not $security.GetOwner(
                [Security.Principal.SecurityIdentifier]).Equals($ownerSid)) {
            return $false
        }
        $required = @{
            $ownerSid.Value = $false
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

function Get-EverVigilKnownRelativePaths {
    @(
        'EverVigil.exe'
        'LICENSE'
        'NOTICE.md'
        'README.md'
        'SECURITY.md'
        'THIRD-PARTY-NOTICES.md'
        'Uninstall.ps1'
        'docs\README.en.md'
        'docs\README.ja.md'
        'docs\REFERENCE.en.md'
        'docs\REFERENCE.ja.md'
        'docs\SECURITY.en.md'
        'docs\SECURITY.ja.md'
        'docs\TECHNICAL_OVERVIEW.en.md'
        'docs\TECHNICAL_OVERVIEW.ja.md'
        'licenses\DOTNET-LICENSE.txt'
        'licenses\DOTNET-THIRD-PARTY-NOTICES.txt'
        'licenses\INNO-SETUP-LICENSE.txt'
        'licenses\QRCODER-LICENSE.txt'
        'scripts\Complete-InstallTransaction.ps1'
        'scripts\InstallTransactionData.ps1'
        'scripts\Invoke-InteractiveUserTask.ps1'
        'scripts\Invoke-SystemMaintenance.ps1'
        'scripts\LegacyCompatibility.generated.ps1'
        'scripts\Resolve-SafeInstallRoot.ps1'
        $script:EverVigilOwnershipFileName
    )
}

function Get-EverVigilRequiredCurrentPaths {
    @(
        'EverVigil.exe'
        'LICENSE'
        'NOTICE.md'
        'README.md'
        'SECURITY.md'
        'THIRD-PARTY-NOTICES.md'
        'Uninstall.ps1'
        'docs\README.en.md'
        'docs\README.ja.md'
        'docs\REFERENCE.en.md'
        'docs\REFERENCE.ja.md'
        'docs\SECURITY.en.md'
        'docs\SECURITY.ja.md'
        'docs\TECHNICAL_OVERVIEW.en.md'
        'docs\TECHNICAL_OVERVIEW.ja.md'
        'licenses\QRCODER-LICENSE.txt'
        'scripts\Complete-InstallTransaction.ps1'
        'scripts\InstallTransactionData.ps1'
        'scripts\Invoke-InteractiveUserTask.ps1'
        'scripts\Invoke-SystemMaintenance.ps1'
        'scripts\LegacyCompatibility.generated.ps1'
    )
}

function Get-EverVigilLegacyKnownRelativePaths {
    @(
        $script:LegacyCompatibilityApplicationExecutableFileName
        'LICENSE'
        'NOTICE.md'
        'README.md'
        'SECURITY.md'
        'THIRD-PARTY-NOTICES.md'
        'Uninstall.ps1'
        'docs\README.en.md'
        'docs\README.ja.md'
        'docs\REFERENCE.en.md'
        'docs\REFERENCE.ja.md'
        'docs\SECURITY.en.md'
        'docs\SECURITY.ja.md'
        'licenses\DOTNET-LICENSE.txt'
        'licenses\DOTNET-THIRD-PARTY-NOTICES.txt'
        'licenses\INNO-SETUP-LICENSE.txt'
        'licenses\QRCODER-LICENSE.txt'
        'scripts\Invoke-SystemMaintenance.ps1'
        'scripts\Resolve-SafeInstallRoot.ps1'
        $script:LegacyCompatibilityApplicationOwnershipMarkerFileName
    )
}

function Get-EverVigilRequiredLegacyPaths {
    @(
        $script:LegacyCompatibilityApplicationExecutableFileName
        'LICENSE'
        'NOTICE.md'
        'README.md'
        'SECURITY.md'
        'THIRD-PARTY-NOTICES.md'
        'Uninstall.ps1'
        'docs\README.en.md'
        'docs\README.ja.md'
        'docs\REFERENCE.en.md'
        'docs\REFERENCE.ja.md'
        'docs\SECURITY.en.md'
        'docs\SECURITY.ja.md'
        'licenses\QRCODER-LICENSE.txt'
        'scripts\Invoke-SystemMaintenance.ps1'
    )
}

function Test-EverVigilKnownLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$ExecutableIdentityTest,
        [switch]$AllowCurrentTempTree
    )

    $resolvedPath = Resolve-SafeInstallRoot `
        -Path $Path `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        return $false
    }

    $allowedPaths = @(Get-EverVigilKnownRelativePaths)
    $allowedDirectories = @('docs', 'licenses', 'scripts')
    $directories = @(Get-ChildItem -LiteralPath $resolvedPath -Directory -Recurse -Force -ErrorAction Stop)
    foreach ($directory in $directories) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $relativePath = [IO.Path]::GetRelativePath($resolvedPath, $directory.FullName)
        if ($relativePath -notin $allowedDirectories) {
            return $false
        }
    }
    $files = @(Get-ChildItem -LiteralPath $resolvedPath -File -Recurse -Force -ErrorAction Stop)
    if ($files.Count -eq 0) {
        return $false
    }
    foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $relativePath = [IO.Path]::GetRelativePath($resolvedPath, $file.FullName)
        if ($relativePath -notin $allowedPaths) {
            return $false
        }
    }
    $actualPaths = @($files | ForEach-Object {
        [IO.Path]::GetRelativePath($resolvedPath, $_.FullName)
    })
    foreach ($requiredPath in @(Get-EverVigilRequiredCurrentPaths)) {
        if ($requiredPath -notin $actualPaths) {
            return $false
        }
    }

    $executable = Join-Path $resolvedPath 'EverVigil.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        return $false
    }
    try {
        if ($null -ne $ExecutableIdentityTest) {
            return [bool](& $ExecutableIdentityTest $executable)
        }
        return [string]::Equals(
            (Get-Item -LiteralPath $executable -ErrorAction Stop).VersionInfo.ProductName,
            'EverVigil',
            [StringComparison]::Ordinal)
    } catch {
        return $false
    }
}

function Test-EverVigilLegacyKnownLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$ExecutableIdentityTest,
        [switch]$AllowCurrentTempTree
    )

    $resolvedPath = Resolve-SafeInstallRoot `
        -Path $Path `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        return $false
    }

    $allowedPaths = @(Get-EverVigilLegacyKnownRelativePaths)
    $allowedDirectories = @('docs', 'licenses', 'scripts')
    $directories = @(Get-ChildItem -LiteralPath $resolvedPath -Directory -Recurse -Force -ErrorAction Stop)
    foreach ($directory in $directories) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $relativePath = [IO.Path]::GetRelativePath($resolvedPath, $directory.FullName)
        if ($relativePath -notin $allowedDirectories) {
            return $false
        }
    }
    $files = @(Get-ChildItem -LiteralPath $resolvedPath -File -Recurse -Force -ErrorAction Stop)
    if ($files.Count -eq 0) {
        return $false
    }
    foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $relativePath = [IO.Path]::GetRelativePath($resolvedPath, $file.FullName)
        if ($relativePath -notin $allowedPaths) {
            return $false
        }
    }
    $actualPaths = @($files | ForEach-Object {
        [IO.Path]::GetRelativePath($resolvedPath, $_.FullName)
    })
    foreach ($requiredPath in @(Get-EverVigilRequiredLegacyPaths)) {
        if ($requiredPath -notin $actualPaths) {
            return $false
        }
    }

    $executable = Join-Path `
        $resolvedPath `
        $script:LegacyCompatibilityApplicationExecutableFileName
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        return $false
    }
    try {
        if ($null -ne $ExecutableIdentityTest) {
            return [bool](& $ExecutableIdentityTest $executable)
        }
        $versionInfo = (Get-Item -LiteralPath $executable -ErrorAction Stop).VersionInfo
        return [string]::Equals(
                $versionInfo.ProductName,
                $script:LegacyCompatibilityApplicationProductName,
                [StringComparison]::Ordinal) -and
            [string]::Equals(
                $versionInfo.OriginalFilename,
                $script:LegacyCompatibilityApplicationExecutableOriginalFileName,
                [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals(
                $versionInfo.FileVersion,
                $script:LegacyCompatibilityApplicationExecutableFileVersion,
                [StringComparison]::Ordinal)
    } catch {
        return $false
    }
}

function Get-EverVigilLegacyInstallOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowCurrentTempTree
    )

    $resolvedPath = Resolve-SafeInstallRoot `
        -Path $Path `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    $markerPath = Join-Path `
        $resolvedPath `
        $script:LegacyCompatibilityApplicationOwnershipMarkerFileName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $null
    }

    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json
        $markerRoot = Resolve-SafeInstallRoot `
            -Path ([string]$marker.installRoot) `
            -AllowCurrentTempTree:$AllowCurrentTempTree
    } catch {
        throw "The legacy installation ownership marker is invalid at '$markerPath': $($_.Exception.Message)"
    }
    if (-not [string]::Equals(
            [string]$marker.appId,
            $script:LegacyCompatibilityApplicationAppId,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [string]$marker.ownerSid,
            (Get-EverVigilOwnerSid),
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            $markerRoot,
            $resolvedPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The legacy installation ownership marker does not match this user and path: $markerPath"
    }
    if (-not (Test-EverVigilLegacyKnownLayout `
                -Path $resolvedPath `
                -AllowCurrentTempTree:$AllowCurrentTempTree)) {
        throw "The legacy installation contains files outside the owned layout: $resolvedPath"
    }

    return $marker
}

function Get-EverVigilInstallOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowCurrentTempTree
    )

    $resolvedPath = Resolve-SafeInstallRoot `
        -Path $Path `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    $markerPath = Join-Path $resolvedPath $script:EverVigilOwnershipFileName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $null
    }

    try {
        $marker = Get-Content `
            -LiteralPath $markerPath `
            -Raw `
            -Encoding UTF8 `
            -ErrorAction Stop |
            ConvertFrom-Json
        $markerRoot = Resolve-SafeInstallRoot `
            -Path ([string]$marker.installRoot) `
            -AllowCurrentTempTree:$AllowCurrentTempTree
    } catch {
        throw "The installation ownership marker is invalid at '$markerPath': $($_.Exception.Message)"
    }
    if (-not [string]::Equals(
            [string]$marker.appId,
            $script:EverVigilAppId,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [string]$marker.ownerSid,
            (Get-EverVigilOwnerSid),
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            $markerRoot,
            $resolvedPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The installation ownership marker does not match this user and path: $markerPath"
    }
    if (-not (Test-EverVigilKnownLayout `
                -Path $resolvedPath `
                -AllowCurrentTempTree:$AllowCurrentTempTree)) {
        throw "The installation contains files outside the owned layout: $resolvedPath"
    }

    return $marker
}

function Assert-OwnedInstallRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowLegacyKnownLayout,
        [switch]$AllowCurrentTempTree
    )

    $resolvedPath = Resolve-SafeInstallRoot `
        -Path $Path `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    $ownership = Get-EverVigilInstallOwnership `
        -Path $resolvedPath `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    if ($null -ne $ownership) {
        return
    }
    if ($AllowLegacyKnownLayout) {
        $legacyOwnership = Get-EverVigilLegacyInstallOwnership `
            -Path $resolvedPath `
            -AllowCurrentTempTree:$AllowCurrentTempTree
        if ($null -ne $legacyOwnership) {
            return
        }
    }

    throw "The directory is not an owned EverVigil installation: $resolvedPath"
}

function Assert-OwnedInstallBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OriginalInstallRoot,
        [switch]$AllowCurrentTempTree
    )

    $resolvedPath = Resolve-SafeInstallRoot `
        -Path $Path `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    $resolvedOriginalRoot = Resolve-SafeInstallRoot `
        -Path $OriginalInstallRoot `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    $knownCurrentLayout = Test-EverVigilKnownLayout `
        -Path $resolvedPath `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    $knownLegacyLayout = if ($knownCurrentLayout) {
        $false
    } else {
        Test-EverVigilLegacyKnownLayout `
            -Path $resolvedPath `
            -AllowCurrentTempTree:$AllowCurrentTempTree
    }
    if (-not $knownCurrentLayout -and -not $knownLegacyLayout) {
        throw "The backup does not match the known EverVigil layout: $resolvedPath"
    }
    $markerName = if ($knownLegacyLayout) {
        $script:LegacyCompatibilityApplicationOwnershipMarkerFileName
    } else {
        $script:EverVigilOwnershipFileName
    }
    $markerPath = Join-Path $resolvedPath $markerName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "The owned installation backup has no ownership marker: $markerPath"
    }
    try {
        $marker = Get-Content `
            -LiteralPath $markerPath `
            -Raw `
            -Encoding UTF8 `
            -ErrorAction Stop |
            ConvertFrom-Json
        $markerRoot = Resolve-SafeInstallRoot `
            -Path ([string]$marker.installRoot) `
            -AllowCurrentTempTree:$AllowCurrentTempTree
    } catch {
        throw "The backup ownership marker is invalid at '$markerPath': $($_.Exception.Message)"
    }
    if (-not [string]::Equals(
            [string]$marker.appId,
            $script:EverVigilAppId,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [string]$marker.ownerSid,
            (Get-EverVigilOwnerSid),
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            $markerRoot,
            $resolvedOriginalRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The backup ownership marker does not match its original installation: $markerPath"
    }
}

function Write-EverVigilInstallOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$InstallRoot = $Path,
        [switch]$AllowCurrentTempTree
    )

    $resolvedPath = Resolve-SafeInstallRoot `
        -Path $Path `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    $resolvedInstallRoot = Resolve-SafeInstallRoot `
        -Path $InstallRoot `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        throw "The installation directory does not exist: $resolvedPath"
    }
    $marker = [ordered]@{
        schemaVersion = 1
        appId = $script:EverVigilAppId
        ownerSid = Get-EverVigilOwnerSid
        installRoot = $resolvedInstallRoot
    }
    $markerPath = Join-Path $resolvedPath $script:EverVigilOwnershipFileName
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        (($marker | ConvertTo-Json) + "`n"))
    $stream = [IO.FileStream]::new(
        $markerPath,
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
    if ([string]::Equals(
            $resolvedPath,
            $resolvedInstallRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        if ($null -eq (Get-EverVigilInstallOwnership `
                    -Path $resolvedPath `
                    -AllowCurrentTempTree:$AllowCurrentTempTree)) {
            throw "The installation ownership marker could not be verified: $markerPath"
        }
    } else {
        try {
            $writtenMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        } catch {
            throw "The staged installation ownership marker is invalid: $markerPath"
        }
        if (-not [string]::Equals(
                [string]$writtenMarker.appId,
                $script:EverVigilAppId,
                [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals(
                [string]$writtenMarker.ownerSid,
                (Get-EverVigilOwnerSid),
                [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals(
                (Resolve-SafeInstallRoot `
                    -Path ([string]$writtenMarker.installRoot) `
                    -AllowCurrentTempTree:$AllowCurrentTempTree),
                $resolvedInstallRoot,
                [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-EverVigilKnownLayout `
                -Path $resolvedPath `
                -AllowCurrentTempTree:$AllowCurrentTempTree)) {
            throw "The staged installation ownership marker could not be verified: $markerPath"
        }
    }
}

function Resolve-SafeInstallRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,
        [switch]$AllowCurrentTempTree
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'The installation directory is required.'
    }
    if (-not (Test-EverVigilPathFullyQualified -Path $Path)) {
        throw "The installation directory must be an absolute local path: $Path"
    }

    try {
        $requestedPath = Normalize-EverVigilFileSystemPath -Path $Path
    } catch {
        throw "The installation directory is invalid: $Path"
    }
    if ($requestedPath.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw "Network installation directories are not supported: $requestedPath"
    }

    $pathRoot = [IO.Path]::GetPathRoot($requestedPath)
    if ([string]::IsNullOrWhiteSpace($pathRoot) -or
        [string]::Equals(
            $requestedPath,
            $pathRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "A drive root cannot be used as the installation directory: $requestedPath"
    }
    if (Test-Path -LiteralPath $requestedPath -PathType Leaf) {
        throw "The installation directory points to a file: $requestedPath"
    }

    $current = [IO.DirectoryInfo]::new($requestedPath)
    while ($current) {
        if ($current.Exists -and
            ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A reparse point cannot be used in the installation path: $($current.FullName)"
        }
        $current = $current.Parent
    }

    $resolvedPath = Resolve-EverVigilFinalFileSystemPath -Path $requestedPath
    if ($resolvedPath.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw "Network installation directories are not supported: $resolvedPath"
    }
    $resolvedRoot = [IO.Path]::GetPathRoot($resolvedPath)
    if ([string]::IsNullOrWhiteSpace($resolvedRoot) -or
        [string]::Equals(
            $resolvedPath,
            $resolvedRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "A drive root cannot be used as the installation directory: $resolvedPath"
    }
    if (-not [string]::Equals(
            $requestedPath,
            $resolvedPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Filesystem aliases and short-name installation paths are not supported: $requestedPath"
    }

    $dataRoot = Join-Path $env:LOCALAPPDATA 'EverVigil'
    $uninstallSupportRoot = Join-Path $env:LOCALAPPDATA 'EverVigil.Uninstall'
    $blockedTrees = @(
        $env:SystemRoot
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:ProgramData
        $dataRoot
        $uninstallSupportRoot
    )
    if (-not $AllowCurrentTempTree) {
        $blockedTrees += $env:TEMP
    }
    $blockedTrees = $blockedTrees | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | ForEach-Object {
        Resolve-EverVigilFinalFileSystemPath -Path $_
    } | Select-Object -Unique
    foreach ($blockedTree in $blockedTrees) {
        if ([string]::Equals($resolvedPath, $blockedTree, [StringComparison]::OrdinalIgnoreCase) -or
            $resolvedPath.StartsWith("$blockedTree\", [StringComparison]::OrdinalIgnoreCase)) {
            throw "The installation directory is inside a protected location: $resolvedPath"
        }
    }

    $blockedExactPaths = @(
        $env:USERPROFILE
        $env:LOCALAPPDATA
        $env:APPDATA
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        Resolve-EverVigilFinalFileSystemPath -Path $_
    } | Select-Object -Unique
    foreach ($blockedPath in $blockedExactPaths) {
        if ([string]::Equals($resolvedPath, $blockedPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "A profile root cannot be used as the installation directory: $resolvedPath"
        }
    }

    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
        throw "The installation directory points to a file: $resolvedPath"
    }

    return $resolvedPath
}

function Get-EverVigilRegisteredInstallRoot {
    [CmdletBinding()]
    param()

    $registryPath = 'HKCU:\' +
        $script:LegacyCompatibilityApplicationUninstallRegistrySubKey
    try {
        $registeredPath = [string](Get-ItemPropertyValue `
                -LiteralPath $registryPath `
                -Name 'Inno Setup: App Path' `
                -ErrorAction Stop)
    } catch [Management.Automation.ItemNotFoundException] {
        return $null
    } catch [Management.Automation.PSArgumentException] {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($registeredPath)) {
        return $null
    }

    try {
        return Resolve-SafeInstallRoot -Path $registeredPath -AllowCurrentTempTree
    } catch {
        throw "The registered installation directory is unsafe: $registeredPath. $($_.Exception.Message)"
    }
}

function Resolve-EverVigilMaintenanceInstallRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowLegacyKnownLayout
    )

    $candidate = Resolve-SafeInstallRoot -Path $Path -AllowCurrentTempTree
    $registeredRoot = Get-EverVigilRegisteredInstallRoot
    $registered = -not [string]::IsNullOrWhiteSpace($registeredRoot) -and
        [string]::Equals(
            $candidate,
            $registeredRoot,
            [StringComparison]::OrdinalIgnoreCase)
    $owned = $false
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        try {
            Assert-OwnedInstallRoot `
                -Path $candidate `
                -AllowLegacyKnownLayout:$AllowLegacyKnownLayout `
                -AllowCurrentTempTree
            $owned = $true
        } catch {
            $owned = $false
        }
    }

    if (-not $registered -and -not $owned) {
        $candidate = Resolve-SafeInstallRoot -Path $Path
    }
    return [pscustomobject]@{
        Path = $candidate
        AllowCurrentTempTree = $registered -or $owned
        Registered = $registered
        Owned = $owned
    }
}

function Assert-CompatibleInstallRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [switch]$AllowCurrentTempTree
    )

    $resolvedPath = Resolve-SafeInstallRoot `
        -Path $Path `
        -AllowCurrentTempTree:$AllowCurrentTempTree
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        return
    }

    $entries = @(Get-ChildItem -LiteralPath $resolvedPath -Force -ErrorAction Stop)
    if ($entries.Count -eq 0) {
        return
    }

    Assert-OwnedInstallRoot `
        -Path $resolvedPath `
        -AllowLegacyKnownLayout `
        -AllowCurrentTempTree:$AllowCurrentTempTree
}

function Test-EverVigilProtectedBrokerAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Directory
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($Directory -and -not $item.PSIsContainer) -or
            (-not $Directory -and $item.PSIsContainer)) {
            return $false
        }
        $security = if ($Directory) {
            [IO.FileSystemAclExtensions]::GetAccessControl(
                [IO.DirectoryInfo]::new($item.FullName),
                [Security.AccessControl.AccessControlSections]'Owner, Access')
        } else {
            [IO.FileSystemAclExtensions]::GetAccessControl(
                [IO.FileInfo]::new($item.FullName),
                [Security.AccessControl.AccessControlSections]'Owner, Access')
        }
        if (-not $security.AreAccessRulesProtected) {
            return $false
        }
        $systemSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::LocalSystemSid,
            $null)
        $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
            $null)
        $trustedOwners = @($systemSid.Value, $administratorsSid.Value)
        $owner = $security.GetOwner(
            [Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin $trustedOwners) {
            return $false
        }
        $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor
            [Security.AccessControl.FileSystemRights]::Modify -bor
            [Security.AccessControl.FileSystemRights]::FullControl -bor
            [Security.AccessControl.FileSystemRights]::Delete -bor
            [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
            [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
            [Security.AccessControl.FileSystemRights]::TakeOwnership -bor
            [Security.AccessControl.FileSystemRights]::CreateFiles -bor
            [Security.AccessControl.FileSystemRights]::CreateDirectories -bor
            [Security.AccessControl.FileSystemRights]::AppendData -bor
            [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
            [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
        $rules = $security.GetAccessRules(
            $true,
            $true,
            [Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -eq
                    [Security.AccessControl.AccessControlType]::Allow -and
                $rule.IdentityReference.Value -notin $trustedOwners -and
                ($rule.FileSystemRights -band $writeMask) -ne 0) {
                return $false
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Get-EverVigilProtectedBrokerPath {
    [CmdletBinding()]
    param()

    $commonApplicationData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonApplicationData) -or
        -not (Test-EverVigilPathFullyQualified -Path $commonApplicationData)) {
        throw 'The machine-wide application-data directory is unavailable.'
    }
    return [IO.Path]::GetFullPath((Join-Path `
            $commonApplicationData `
            'EverVigil\Broker\2.0.0\EverVigil.Broker.exe'))
}

function Get-EverVigilProtectedBrokerRetirementPaths {
    [CmdletBinding()]
    param()

    $canonicalPath = Get-EverVigilProtectedBrokerPath
    $versionRoot = Split-Path -Parent $canonicalPath
    $brokerRoot = Split-Path -Parent $versionRoot
    $productRoot = Split-Path -Parent $brokerRoot
    return [pscustomobject]@{
        ProductRoot = $productRoot
        BrokerRoot = $brokerRoot
        StateRoot = Join-Path $brokerRoot 'State'
        VersionRoot = $versionRoot
        CanonicalPath = $canonicalPath
        InstallationReceiptPath = Join-Path $versionRoot 'installation.json'
        RetirementReceiptPath = Join-Path $versionRoot 'retirement.json'
    }
}

function Test-EverVigilProtectedBrokerRetirementAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OwnerSid,
        [switch]$Directory
    )

    try {
        $retirementOwnerSid = [Security.Principal.SecurityIdentifier]::new(
            $OwnerSid)
        $systemSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::LocalSystemSid,
            $null)
        $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
            $null)
        $usersSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinUsersSid,
            $null)
        if ($retirementOwnerSid.Equals($systemSid) -or
            $retirementOwnerSid.Equals($administratorsSid) -or
            $retirementOwnerSid.Equals($usersSid)) {
            return $false
        }

        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($Directory -and -not $item.PSIsContainer) -or
            (-not $Directory -and $item.PSIsContainer)) {
            return $false
        }
        $security = if ($Directory) {
            [IO.FileSystemAclExtensions]::GetAccessControl(
                [IO.DirectoryInfo]::new($item.FullName),
                [Security.AccessControl.AccessControlSections]'Owner, Access')
        } else {
            [IO.FileSystemAclExtensions]::GetAccessControl(
                [IO.FileInfo]::new($item.FullName),
                [Security.AccessControl.AccessControlSections]'Owner, Access')
        }
        if (-not $security.AreAccessRulesProtected) {
            return $false
        }
        $aclOwner = $security.GetOwner(
            [Security.Principal.SecurityIdentifier])
        if (-not $aclOwner.Equals($systemSid) -and
            -not $aclOwner.Equals($administratorsSid)) {
            return $false
        }

        $dangerousRights = [long](
            [Security.AccessControl.FileSystemRights]::WriteData -bor
            [Security.AccessControl.FileSystemRights]::CreateFiles -bor
            [Security.AccessControl.FileSystemRights]::AppendData -bor
            [Security.AccessControl.FileSystemRights]::CreateDirectories -bor
            [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
            [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
            [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
            [Security.AccessControl.FileSystemRights]::Delete -bor
            [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
            [Security.AccessControl.FileSystemRights]::TakeOwnership)
        $deleteRight = [long][Security.AccessControl.FileSystemRights]::Delete
        $forbiddenOwnerRights = $dangerousRights -band (-bnot $deleteRight)
        $fullControl = [long][Security.AccessControl.FileSystemRights]::FullControl
        $systemFullControl = $false
        $administratorsFullControl = $false
        $ownerDeleteOnly = $false
        $rules = $security.GetAccessRules(
            $true,
            $true,
            [Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            if ($rule.IsInherited -or
                $rule.AccessControlType -ne
                    [Security.AccessControl.AccessControlType]::Allow) {
                return $false
            }
            $ruleSid = [Security.Principal.SecurityIdentifier]$rule.IdentityReference
            $rights = [long]$rule.FileSystemRights
            if ($ruleSid.Equals($systemSid)) {
                $systemFullControl = $systemFullControl -or
                    (($rights -band $fullControl) -eq $fullControl)
                continue
            }
            if ($ruleSid.Equals($administratorsSid)) {
                $administratorsFullControl = $administratorsFullControl -or
                    (($rights -band $fullControl) -eq $fullControl)
                continue
            }
            if ($ruleSid.Equals($usersSid)) {
                if (($rights -band $dangerousRights) -ne 0) {
                    return $false
                }
                continue
            }
            if ($ruleSid.Equals($retirementOwnerSid)) {
                if (($rights -band $deleteRight) -eq 0 -or
                    ($rights -band $forbiddenOwnerRights) -ne 0) {
                    return $false
                }
                $ownerDeleteOnly = $true
                continue
            }
            return $false
        }
        return $systemFullControl -and
            $administratorsFullControl -and
            $ownerDeleteOnly
    } catch {
        return $false
    }
}

function Read-EverVigilProtectedBrokerRetirementReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OwnerSid,
        [switch]$AllowStandardAcl
    )

    $paths = Get-EverVigilProtectedBrokerRetirementPaths
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals(
            $resolvedPath,
            $paths.RetirementReceiptPath,
            [StringComparison]::OrdinalIgnoreCase) -or
        (-not (Test-EverVigilProtectedBrokerRetirementAcl `
                -Path $resolvedPath `
                -OwnerSid $OwnerSid) -and
            (-not $AllowStandardAcl -or
                -not (Test-EverVigilProtectedBrokerAcl `
                    -Path $resolvedPath)))) {
        throw "The protected broker retirement receipt path or ACL is invalid: $resolvedPath"
    }
    $receiptInfo = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if ($receiptInfo.Length -lt 1 -or $receiptInfo.Length -gt 65536) {
        throw 'The protected broker retirement receipt size is invalid.'
    }
    $receiptBytes = [IO.File]::ReadAllBytes($resolvedPath)
    if ($receiptBytes.Length -ne $receiptInfo.Length) {
        throw 'The protected broker retirement receipt changed while it was read.'
    }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($receiptBytes)
    } catch {
        throw 'The protected broker retirement receipt is not strict UTF-8.'
    }

    $jsonString = '"(?:[^"\\]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"'
    $jsonInteger = '-?(?:0|[1-9][0-9]*)'
    $member = '"(?:schemaVersion|transactionId|ownerSid|version|' +
        'canonicalFileName|length|sha256|state)"' +
        '[ \t\r\n]*:[ \t\r\n]*(?:' + $jsonString + '|' + $jsonInteger + ')'
    $receiptPattern = '\A[ \t\r\n]*\{[ \t\r\n]*' + $member +
        '(?:[ \t\r\n]*,[ \t\r\n]*' + $member + '){7}' +
        '[ \t\r\n]*\}[ \t\r\n]*\z'
    if (-not [Text.RegularExpressions.Regex]::IsMatch(
            $json,
            $receiptPattern,
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw 'The protected broker retirement receipt schema is not exact.'
    }
    try {
        $receipt = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'The protected broker retirement receipt is not valid JSON.'
    }
    $expectedProperties = @(
        'schemaVersion'
        'transactionId'
        'ownerSid'
        'version'
        'canonicalFileName'
        'length'
        'sha256'
        'state'
    )
    $properties = @($receipt.PSObject.Properties)
    if ($properties.Count -ne $expectedProperties.Count -or
        @($properties.Name | Where-Object { $_ -cnotin $expectedProperties }).Count -gt 0) {
        throw 'The protected broker retirement receipt contains unknown members.'
    }
    foreach ($expectedProperty in $expectedProperties) {
        if (@($properties.Name | Where-Object { $_ -ceq $expectedProperty }).Count -ne 1) {
            throw 'The protected broker retirement receipt contains missing or duplicate members.'
        }
    }

    $schemaVersion = $receipt.PSObject.Properties['schemaVersion'].Value
    $transactionId = $receipt.PSObject.Properties['transactionId'].Value
    $receiptOwnerSid = $receipt.PSObject.Properties['ownerSid'].Value
    $version = $receipt.PSObject.Properties['version'].Value
    $canonicalFileName = $receipt.PSObject.Properties['canonicalFileName'].Value
    $length = $receipt.PSObject.Properties['length'].Value
    $sha256 = $receipt.PSObject.Properties['sha256'].Value
    $state = $receipt.PSObject.Properties['state'].Value
    $parsedTransactionId = [guid]::Empty
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or
        [long]$schemaVersion -ne 1 -or
        $transactionId -isnot [string] -or
        -not [guid]::TryParseExact(
            [string]$transactionId,
            'D',
            [ref]$parsedTransactionId) -or
        $parsedTransactionId -eq [guid]::Empty -or
        $receiptOwnerSid -isnot [string] -or
        -not [string]::Equals(
            [string]$receiptOwnerSid,
            $OwnerSid,
            [StringComparison]::Ordinal) -or
        $version -isnot [string] -or
        [string]$version -cne '2.0.0' -or
        $canonicalFileName -isnot [string] -or
        [string]$canonicalFileName -cne 'EverVigil.Broker.exe' -or
        ($length -isnot [int] -and $length -isnot [long]) -or
        [long]$length -le 0 -or
        $sha256 -isnot [string] -or
        [string]$sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
        $state -isnot [string] -or
        [string]$state -cne 'RetirementPrepared') {
        throw 'The protected broker retirement receipt identity is invalid.'
    }
    try {
        $validatedOwnerSid = [Security.Principal.SecurityIdentifier]::new(
            [string]$receiptOwnerSid)
    } catch {
        throw 'The protected broker retirement owner SID is invalid.'
    }
    if (-not [string]::Equals(
            $validatedOwnerSid.Value,
            $OwnerSid,
            [StringComparison]::Ordinal)) {
        throw 'The protected broker retirement owner SID is not canonical.'
    }
    return $receipt
}

function Test-EverVigilProtectedBrokerReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)]
        [long]$ExecutableLength,
        [Parameter(Mandatory)][string]$ExecutableSha256
    )

    # ConvertFrom-Json is permissive about unknown and duplicate members. First
    # constrain this flat record to exactly five JSON members with exact-case
    # names and strict scalar syntax; then validate the parsed types and values.
    $jsonString = '"(?:[^"\\]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"'
    $jsonInteger = '-?(?:0|[1-9][0-9]*)'
    $member = '"(?:schemaVersion|fileName|version|length|sha256)"' +
        '[ \t\r\n]*:[ \t\r\n]*(?:' + $jsonString + '|' + $jsonInteger + ')'
    $receiptPattern = '\A[ \t\r\n]*\{[ \t\r\n]*' + $member +
        '(?:[ \t\r\n]*,[ \t\r\n]*' + $member + '){4}' +
        '[ \t\r\n]*\}[ \t\r\n]*\z'
    if (-not [Text.RegularExpressions.Regex]::IsMatch(
            $Json,
            $receiptPattern,
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        return $false
    }

    try {
        $receipt = $Json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $false
    }
    $expectedProperties = @(
        'schemaVersion'
        'fileName'
        'version'
        'length'
        'sha256'
    )
    $properties = @($receipt.PSObject.Properties)
    if ($properties.Count -ne $expectedProperties.Count) {
        return $false
    }
    foreach ($expectedProperty in $expectedProperties) {
        if (@($properties.Name | Where-Object { $_ -ceq $expectedProperty }).Count -ne 1) {
            return $false
        }
    }

    $schemaVersion = $receipt.PSObject.Properties['schemaVersion'].Value
    $receiptLength = $receipt.PSObject.Properties['length'].Value
    $fileName = $receipt.PSObject.Properties['fileName'].Value
    $version = $receipt.PSObject.Properties['version'].Value
    $receiptSha256 = $receipt.PSObject.Properties['sha256'].Value
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or
        [long]$schemaVersion -ne 1 -or
        ($receiptLength -isnot [int] -and $receiptLength -isnot [long]) -or
        [long]$receiptLength -ne $ExecutableLength -or
        $fileName -isnot [string] -or
        [string]$fileName -cne 'EverVigil.Broker.exe' -or
        $version -isnot [string] -or
        [string]$version -cne '2.0.0' -or
        $receiptSha256 -isnot [string] -or
        [string]$receiptSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
        $ExecutableSha256 -cnotmatch '\A[0-9a-f]{64}\z') {
        return $false
    }
    return [string]::Equals(
        [string]$receiptSha256,
        $ExecutableSha256,
        [StringComparison]::Ordinal)
}

function Complete-EverVigilProtectedBrokerRetirementFromReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExpectedOwnerSid,
        [Parameter(Mandatory)][guid]$ExpectedTransactionId
    )

    $paths = Get-EverVigilProtectedBrokerRetirementPaths
    if (-not (Test-Path -LiteralPath $paths.ProductRoot)) {
        return
    }
    function Assert-RetirementDirectory {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedName
        )

        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        if (-not (Test-EverVigilProtectedBrokerRetirementAcl `
                -Path $Path `
                -OwnerSid $ExpectedOwnerSid `
                -Directory)) {
            throw "A protected broker retirement directory is unsafe: $Path"
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

    Assert-RetirementDirectory -Path $paths.ProductRoot -AllowedName @('Broker')
    Assert-RetirementDirectory `
        -Path $paths.BrokerRoot `
        -AllowedName @('State', '2.0.0')
    Assert-RetirementDirectory `
        -Path $paths.VersionRoot `
        -AllowedName @(
            'EverVigil.Broker.exe'
            'installation.json'
            'retirement.json')
    Assert-RetirementDirectory -Path $paths.StateRoot -AllowedName @()

    $receiptExists = Test-Path `
        -LiteralPath $paths.RetirementReceiptPath `
        -PathType Leaf
    $canonicalExists = Test-Path `
        -LiteralPath $paths.CanonicalPath `
        -PathType Leaf
    $installationReceiptExists = Test-Path `
        -LiteralPath $paths.InstallationReceiptPath `
        -PathType Leaf
    if (-not $receiptExists) {
        if ($canonicalExists -or $installationReceiptExists) {
            throw 'Protected broker retirement lost its durable authority receipt.'
        }
    } else {
        $receipt = Read-EverVigilProtectedBrokerRetirementReceipt `
            -Path $paths.RetirementReceiptPath `
            -OwnerSid $ExpectedOwnerSid
        if (-not [string]::Equals(
                ([guid][string]$receipt.transactionId).ToString('D'),
                $ExpectedTransactionId.ToString('D'),
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The protected broker retirement receipt transaction is not the installer transaction.'
        }
        $expectedLength = [long]$receipt.length
        $expectedSha256 = [string]$receipt.sha256
        if ($canonicalExists) {
            if (-not (Test-EverVigilProtectedBrokerRetirementAcl `
                    -Path $paths.CanonicalPath `
                    -OwnerSid $ExpectedOwnerSid)) {
                throw 'The retiring canonical broker ACL is invalid.'
            }
            $canonical = Get-Item `
                -LiteralPath $paths.CanonicalPath `
                -Force `
                -ErrorAction Stop
            $canonicalSha256 = (Get-FileHash `
                    -LiteralPath $paths.CanonicalPath `
                    -Algorithm SHA256 `
                    -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($canonical.Length -ne $expectedLength -or
                -not [string]::Equals(
                    $canonicalSha256,
                    $expectedSha256,
                    [StringComparison]::Ordinal)) {
                throw 'The retiring canonical broker does not match its protected receipt.'
            }
        }
        if ($installationReceiptExists) {
            if (-not (Test-EverVigilProtectedBrokerRetirementAcl `
                    -Path $paths.InstallationReceiptPath `
                    -OwnerSid $ExpectedOwnerSid)) {
                throw 'The retiring installation receipt ACL is invalid.'
            }
            $installationReceiptInfo = Get-Item `
                -LiteralPath $paths.InstallationReceiptPath `
                -Force `
                -ErrorAction Stop
            if ($installationReceiptInfo.Length -lt 1 -or
                $installationReceiptInfo.Length -gt 4096) {
                throw 'The retiring installation receipt size is invalid.'
            }
            try {
                $installationReceiptJson = [Text.UTF8Encoding]::new(
                    $false,
                    $true).GetString([IO.File]::ReadAllBytes(
                        $paths.InstallationReceiptPath))
            } catch {
                throw 'The retiring installation receipt is not strict UTF-8.'
            }
            if (-not (Test-EverVigilProtectedBrokerReceipt `
                    -Json $installationReceiptJson `
                    -ExecutableLength $expectedLength `
                    -ExecutableSha256 $expectedSha256)) {
                throw 'The retiring installation receipt does not match the retirement receipt.'
            }
        } elseif ($canonicalExists) {
            throw 'The retiring canonical broker exists without its installation receipt.'
        }

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
                throw "Refusing to delete a retirement file with an invalid ACL: $retirementFile"
            }
            [IO.File]::Delete($retirementFile)
            if (Test-Path -LiteralPath $retirementFile) {
                throw "Protected broker retirement requires a restart and retry: $retirementFile"
            }
        }
    }

    Assert-RetirementDirectory -Path $paths.StateRoot -AllowedName @()
    Assert-RetirementDirectory -Path $paths.VersionRoot -AllowedName @()
    Assert-RetirementDirectory -Path $paths.BrokerRoot -AllowedName @('State')
    Assert-RetirementDirectory -Path $paths.ProductRoot -AllowedName @('Broker')
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
                -Directory) -or
            @(Get-ChildItem `
                    -LiteralPath $retirementDirectory `
                    -Force `
                    -ErrorAction Stop).Count -ne 0) {
            throw "Refusing to delete a non-empty or unsafe retirement directory: $retirementDirectory"
        }
        [IO.Directory]::Delete($retirementDirectory, $false)
        if (Test-Path -LiteralPath $retirementDirectory) {
            throw "Protected broker directory retirement requires a restart and retry: $retirementDirectory"
        }
    }
}

function Test-EverVigilProtectedBrokerInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BrokerPath)

    $expectedPath = Get-EverVigilProtectedBrokerPath
    $resolvedPath = [IO.Path]::GetFullPath($BrokerPath)
    if (-not [string]::Equals(
            $resolvedPath,
            $expectedPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $versionRoot = Split-Path -Parent $resolvedPath
    $brokerRoot = Split-Path -Parent $versionRoot
    $applicationRoot = Split-Path -Parent $brokerRoot
    foreach ($directoryPath in @($applicationRoot, $brokerRoot, $versionRoot)) {
        if (-not (Test-EverVigilProtectedBrokerAcl `
                -Path $directoryPath `
                -Directory)) {
            return $false
        }
    }
    if (-not (Test-EverVigilProtectedBrokerAcl -Path $resolvedPath)) {
        return $false
    }

    $receiptPath = Join-Path $versionRoot 'installation.json'
    if (-not (Test-EverVigilProtectedBrokerAcl -Path $receiptPath)) {
        return $false
    }
    try {
        $receiptInfo = Get-Item `
            -LiteralPath $receiptPath `
            -Force `
            -ErrorAction Stop
        if ($receiptInfo.Length -lt 1 -or $receiptInfo.Length -gt 4096) {
            return $false
        }
        $receiptBytes = [IO.File]::ReadAllBytes($receiptPath)
        if ($receiptBytes.Length -ne $receiptInfo.Length) {
            return $false
        }
        $receiptJson = [Text.UTF8Encoding]::new(
            $false,
            $true).GetString($receiptBytes)

        $brokerInfo = Get-Item `
            -LiteralPath $resolvedPath `
            -Force `
            -ErrorAction Stop
        if ($brokerInfo.Length -lt 1) {
            return $false
        }
        $brokerSha256 = (Get-FileHash `
                -LiteralPath $resolvedPath `
                -Algorithm SHA256 `
                -ErrorAction Stop).Hash.ToLowerInvariant()
        return Test-EverVigilProtectedBrokerReceipt `
            -Json $receiptJson `
            -ExecutableLength $brokerInfo.Length `
            -ExecutableSha256 $brokerSha256
    } catch {
        return $false
    }
}

function Read-EverVigilPipeFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [ValidateRange(1, 65536)][int]$MaximumLength = 65536,
        [Threading.CancellationToken]$CancellationToken =
            [Threading.CancellationToken]::None
    )

    $lengthBytes = [byte[]]::new(4)
    $offset = 0
    while ($offset -lt $lengthBytes.Length) {
        $read = $Stream.ReadAsync(
                $lengthBytes,
                $offset,
                $lengthBytes.Length - $offset,
                $CancellationToken).GetAwaiter().GetResult()
        if ($read -le 0) {
            throw 'The system broker closed its pipe before sending a response length.'
        }
        $offset += $read
    }
    if (-not [BitConverter]::IsLittleEndian) {
        [Array]::Reverse($lengthBytes)
    }
    $length = [BitConverter]::ToUInt32($lengthBytes, 0)
    if ($length -lt 1 -or $length -gt $MaximumLength) {
        throw "The system broker response length is invalid: $length"
    }
    $payload = [byte[]]::new([int]$length)
    $offset = 0
    while ($offset -lt $payload.Length) {
        $read = $Stream.ReadAsync(
                $payload,
                $offset,
                $payload.Length - $offset,
                $CancellationToken).GetAwaiter().GetResult()
        if ($read -le 0) {
            throw 'The system broker closed its pipe before sending a complete response.'
        }
        $offset += $read
    }
    return $payload
}

function Assert-EverVigilBrokerResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][guid]$TransactionId
    )

    $expectedProperties = @(
        'schemaVersion'
        'transactionId'
        'success'
        'disposition'
        'errorCode'
        'message'
    )
    $actualProperties = @($Response.PSObject.Properties.Name)
    if ($actualProperties.Count -ne $expectedProperties.Count -or
        @($actualProperties | Where-Object { $_ -cnotin $expectedProperties }).Count -gt 0 -or
        $Response.PSObject.Properties['schemaVersion'].Value -isnot [int64] -and
            $Response.PSObject.Properties['schemaVersion'].Value -isnot [int32] -or
        [int]$Response.schemaVersion -ne 1 -or
        $Response.PSObject.Properties['transactionId'].Value -isnot [string] -or
        -not [string]::Equals(
            ([guid][string]$Response.transactionId).ToString('D'),
            $TransactionId.ToString('D'),
            [StringComparison]::OrdinalIgnoreCase) -or
        $Response.PSObject.Properties['success'].Value -isnot [bool] -or
        $Response.PSObject.Properties['disposition'].Value -isnot [string] -or
        [string]$Response.disposition -cnotin @(
            'CanonicalReady',
            'Completed',
            'RetirementRequired',
            'RolledBack',
            'PendingRecovery',
            'NoChange',
            'Refused') -or
        $Response.PSObject.Properties['errorCode'].Value -isnot [string] -or
        [string]$Response.errorCode -cnotin @(
            'None',
            'InvalidRequest',
            'AuthenticationFailed',
            'ElevationRequired',
            'ProtectedInstallationInvalid',
            'PendingTransactionMismatch',
            'OwnershipMismatch',
            'FunnelDetected',
            'ExternalCommandFailed',
            'RecoveryRequired',
            'UnsupportedOperation',
            'InternalFailure') -or
        $Response.PSObject.Properties['message'].Value -isnot [string] -or
        ([string]$Response.message).Length -gt 1024 -or
        [string]$Response.message -match '[\r\n]') {
        throw 'The system broker returned a malformed response.'
    }
}

function Invoke-EverVigilSystemBroker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'Apply',
            'Recover',
            'Rollback',
            'Commit',
            'UninstallCleanup',
            'LegacyTaskCleanup',
            'Status')]
        [string]$Operation,
        [Parameter(Mandatory)][guid]$TransactionId,
        [Parameter(Mandatory)][ValidateSet('Interactive', 'Installer')]
        [string]$Initiator,
        [ValidateRange(0, 65535)][int]$PublicPort = 0,
        [ValidateRange(0, 65535)][int]$BackendPort = 0,
        [switch]$MigrateV121SystemState,
        [switch]$AllowBootstrap
    )

    if ($Operation -eq 'Apply') {
        if ($PublicPort -lt 1024 -or $BackendPort -lt 1024 -or
            $PublicPort -eq $BackendPort) {
            throw 'System broker Apply requires distinct public/backend ports in the user range.'
        }
    } elseif ($PublicPort -ne 0 -or $BackendPort -ne 0) {
        throw "System broker $Operation must not receive port fields."
    }
    if ($MigrateV121SystemState -and $Operation -ne 'Apply') {
        throw 'v1.2.1 system-state migration can be requested only with Apply.'
    }

    function Invoke-ProtectedBrokerOnce {
        param(
            [Parameter(Mandatory)][string]$ExecutablePath,
            [switch]$Bootstrap
        )

        $pipeName = "EverVigil.Broker.$([guid]::NewGuid().ToString('N'))"
        $nonceBytes = [byte[]]::new(32)
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $random.GetBytes($nonceBytes)
        } finally {
            $random.Dispose()
        }
        $nonce = [BitConverter]::ToString($nonceBytes).Replace(
            '-',
            '').ToLowerInvariant()
        $request = [ordered]@{
            schemaVersion = 1
            transactionId = $TransactionId.ToString('D')
            nonce = $nonce
            operation = $Operation
            initiator = $Initiator
            publicPort = if ($Operation -eq 'Apply') { $PublicPort } else { $null }
            backendPort = if ($Operation -eq 'Apply') { $BackendPort } else { $null }
            # The wire name is retained for protocol v1 compatibility. This
            # authorization is derived only from a strictly owned v1.2.1
            # install plus its validated local applied-system record; it is
            # never inferred from an older plaintext credential.
            migrateLegacySystemState = [bool]$MigrateV121SystemState
        }
        $requestBytes = [Text.UTF8Encoding]::new(
            $false,
            $true).GetBytes(($request | ConvertTo-Json -Compress -Depth 4))
        if ($requestBytes.Length -lt 1 -or $requestBytes.Length -gt 65536) {
            throw 'The system broker request exceeds the bounded protocol size.'
        }
        $arguments = @(
            if ($Bootstrap) { '--bootstrap' }
            '--client-pid', [string]$PID
            '--pipe', $pipeName
            '--nonce', $nonce
            '--transaction-id', $TransactionId.ToString('D')
        )
        $process = $null
        $pipe = $null
        try {
            # This is the only elevation point. Bootstrap can only install the
            # canonical image; all mutations require a second canonical launch.
            $process = Start-Process `
                -FilePath $ExecutablePath `
                -ArgumentList $arguments `
                -Verb RunAs `
                -WindowStyle Hidden `
                -PassThru
            $pipe = [IO.Pipes.NamedPipeClientStream]::new(
                '.',
                $pipeName,
                [IO.Pipes.PipeDirection]::InOut,
                [IO.Pipes.PipeOptions]::Asynchronous,
                [Security.Principal.TokenImpersonationLevel]::Identification)
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not $pipe.IsConnected -and [DateTime]::UtcNow -lt $deadline) {
                if ($process.HasExited) {
                    throw "The system broker exited before opening its authenticated pipe (exit $($process.ExitCode))."
                }
                try {
                    $pipe.Connect(250)
                } catch [TimeoutException] {
                    # The elevated broker may still be validating its installation.
                }
            }
            if (-not $pipe.IsConnected) {
                throw 'Timed out waiting for the authenticated system broker pipe.'
            }
            $pipe.ReadMode = [IO.Pipes.PipeTransmissionMode]::Byte
            $lengthBytes = [BitConverter]::GetBytes([uint32]$requestBytes.Length)
            if (-not [BitConverter]::IsLittleEndian) {
                [Array]::Reverse($lengthBytes)
            }
            $ioCancellation = [Threading.CancellationTokenSource]::new(
                [TimeSpan]::FromSeconds(90))
            try {
                $pipe.WriteAsync(
                        $lengthBytes,
                        0,
                        $lengthBytes.Length,
                        $ioCancellation.Token).GetAwaiter().GetResult()
                $pipe.WriteAsync(
                        $requestBytes,
                        0,
                        $requestBytes.Length,
                        $ioCancellation.Token).GetAwaiter().GetResult()
                $pipe.FlushAsync(
                        $ioCancellation.Token).GetAwaiter().GetResult()
                $responseBytes = Read-EverVigilPipeFrame `
                    -Stream $pipe `
                    -CancellationToken $ioCancellation.Token
            } finally {
                $ioCancellation.Dispose()
            }
            try {
                $response = [Text.UTF8Encoding]::new(
                    $false,
                    $true).GetString($responseBytes) | ConvertFrom-Json
            } catch {
                throw "The system broker response is not strict UTF-8 JSON: $($_.Exception.Message)"
            }
            Assert-EverVigilBrokerResponse `
                -Response $response `
                -TransactionId $TransactionId
            if (-not $process.WaitForExit(30000)) {
                throw 'The system broker did not exit after sending its bounded response.'
            }
            if ($process.ExitCode -ne 0) {
                throw "The system broker exited unexpectedly after responding (exit $($process.ExitCode))."
            }
            if (-not $response.success) {
                throw "System broker refused $Operation ($($response.errorCode)): $($response.message)"
            }
            return $response
        } finally {
            if ($pipe) {
                $pipe.Dispose()
            }
            if ($process) {
                $process.Dispose()
            }
        }
    }

    $protectedBrokerPath = Get-EverVigilProtectedBrokerPath
    if (Test-Path -LiteralPath $protectedBrokerPath) {
        if (-not (Test-EverVigilProtectedBrokerInstallation `
                -BrokerPath $protectedBrokerPath)) {
            throw "The protected EverVigil system broker installation is invalid: $protectedBrokerPath"
        }
    } else {
        if (-not $AllowBootstrap) {
            throw 'The protected EverVigil system broker is not installed. Rerun the same Setup package.'
        }
        $packageRoot = Split-Path -Parent $PSScriptRoot
        $bootstrapBrokerPath = [IO.Path]::GetFullPath((Join-Path `
                $packageRoot `
                'broker\EverVigil.Broker.exe'))
        if (-not (Test-Path -LiteralPath $bootstrapBrokerPath -PathType Leaf)) {
            throw "The fixed Setup package broker is unavailable: $bootstrapBrokerPath"
        }
        $bootstrapItem = Get-Item `
            -LiteralPath $bootstrapBrokerPath `
            -Force `
            -ErrorAction Stop
        if (($bootstrapItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The fixed Setup package broker is a reparse point: $bootstrapBrokerPath"
        }
        # Open every component from the local volume root through the package
        # broker without following reparse points. Keep all handles without
        # write/delete sharing until CanonicalReady and protected-copy
        # validation complete. Identity is checked again through the original
        # handles and by reopening the same path before and after UAC. This
        # closes both file replacement and ancestor junction-retarget races. It
        # does not turn an unsigned package into a cryptographic trust anchor.
        $bootstrapPathLock = [EverVigil.BootstrapPathLock]::Acquire(
            $bootstrapBrokerPath)
        try {
            if ($bootstrapPathLock.ExecutableLength -le 0 -or
                $bootstrapPathLock.ComponentCount -lt 2) {
                throw 'The fixed Setup package broker is empty.'
            }
            $bootstrapPathLock.Validate()
            $bootstrapResponse = Invoke-ProtectedBrokerOnce `
                -ExecutablePath $bootstrapBrokerPath `
                -Bootstrap
            if ([string]$bootstrapResponse.disposition -cne 'CanonicalReady' -or
                [string]$bootstrapResponse.errorCode -cne 'None') {
                throw 'The bootstrap broker did not return CanonicalReady.'
            }
            if (-not (Test-EverVigilProtectedBrokerInstallation `
                    -BrokerPath $protectedBrokerPath)) {
                throw 'The bootstrap broker did not create a valid canonical installation.'
            }
            $bootstrapPathLock.Validate()
        } finally {
            $bootstrapPathLock.Dispose()
        }
    }

    $response = Invoke-ProtectedBrokerOnce -ExecutablePath $protectedBrokerPath
    if ([string]$response.disposition -ceq 'CanonicalReady') {
        throw 'The canonical broker returned the bootstrap-only disposition.'
    }
    return $response
}
