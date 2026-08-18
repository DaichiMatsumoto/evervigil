if ($null -eq ('EverVigil.ReleaseDirectoryLock' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace EverVigil
{
    public sealed class ReleaseDirectoryLock : IDisposable
    {
        private const uint FileReadAttributes = 0x0080;
        private const uint FileShareRead = 0x00000001;
        private const uint OpenExisting = 3;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const uint VolumeNameGuid = 0x00000001;

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryW(
            string path,
            IntPtr securityAttributes);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file,
            StringBuilder path,
            uint pathLength,
            uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint QueryDosDeviceW(
            string deviceName,
            [Out] char[] targetPath,
            int maximumLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumePathNamesForVolumeNameW(
            string volumeName,
            [Out] char[] volumePathNames,
            uint bufferLength,
            out uint returnLength);

        private SafeFileHandle handle;

        public string FinalPath { get; }
        public uint VolumeSerialNumber { get; }
        public ulong FileIndex { get; }
        public bool IsAlive => handle != null && !handle.IsClosed && !handle.IsInvalid;

        public ReleaseDirectoryLock(string path)
        {
            handle = CreateFileW(
                path,
                FileReadAttributes,
                FileShareRead,
                IntPtr.Zero,
                OpenExisting,
                FileFlagOpenReparsePoint | FileFlagBackupSemantics,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "The reviewed directory could not be locked.");
            }

            try
            {
                if (!GetFileInformationByHandle(handle, out ByHandleFileInformation information))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "The reviewed directory identity could not be read.");
                }
                if ((information.FileAttributes & FileAttributeDirectory) == 0 ||
                    (information.FileAttributes & FileAttributeReparsePoint) != 0)
                {
                    throw new InvalidOperationException(
                        "The reviewed path is not a non-reparse directory.");
                }

                VolumeSerialNumber = information.VolumeSerialNumber;
                FileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
                FinalPath = ReadFinalPath(handle);
                if (!FinalPath.StartsWith(
                        @"\\?\Volume{",
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        "The reviewed directory did not resolve to a volume GUID path.");
                }
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public static void CreateFreshDirectory(string path)
        {
            if (!CreateDirectoryW(path, IntPtr.Zero))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The isolated release directory could not be created atomically.");
            }
        }

        public static bool IsNativeDriveRoot(string rootPath)
        {
            string driveName = rootPath.Substring(0, 2);
            int capacity = 512;
            while (capacity <= 32768)
            {
                char[] targets = new char[capacity];
                uint length = QueryDosDeviceW(driveName, targets, targets.Length);
                if (length != 0)
                {
                    string[] mappings = new string(targets, 0, checked((int)length)).Split(
                        new[] { '\0' },
                        StringSplitOptions.RemoveEmptyEntries);
                    return mappings.Length == 1 && mappings[0].StartsWith(
                        @"\Device\",
                        StringComparison.OrdinalIgnoreCase);
                }
                int error = Marshal.GetLastWin32Error();
                if (error != 122)
                {
                    throw new Win32Exception(
                        error,
                        "The reviewed drive mapping could not be read.");
                }
                capacity *= 2;
            }
            throw new InvalidOperationException("The reviewed drive mapping is too long.");
        }

        public static bool IsRegisteredVolumeMount(string rootPath, string volumeGuidPath)
        {
            string volumeName = volumeGuidPath.TrimEnd('\\') + "\\";
            uint capacity = 512;
            while (capacity <= 32768)
            {
                char[] paths = new char[capacity];
                if (GetVolumePathNamesForVolumeNameW(
                        volumeName,
                        paths,
                        (uint)paths.Length,
                        out uint requiredLength))
                {
                    string[] mountPoints = new string(
                        paths,
                        0,
                        checked((int)requiredLength)).Split(
                            new[] { '\0' },
                            StringSplitOptions.RemoveEmptyEntries);
                    foreach (string mountPoint in mountPoints)
                    {
                        if (string.Equals(
                                mountPoint,
                                rootPath,
                                StringComparison.OrdinalIgnoreCase))
                        {
                            return true;
                        }
                    }
                    return false;
                }
                int error = Marshal.GetLastWin32Error();
                if (error != 234)
                {
                    throw new Win32Exception(
                        error,
                        "The reviewed volume mount points could not be read.");
                }
                capacity = Math.Max(capacity * 2, requiredLength);
            }
            throw new InvalidOperationException("The reviewed volume mount-point list is too long.");
        }

        public static string GetFinalPath(SafeFileHandle file)
        {
            if (file == null || file.IsClosed || file.IsInvalid)
            {
                throw new InvalidOperationException("The reviewed file handle is not live.");
            }
            return ReadFinalPath(file);
        }

        private static string ReadFinalPath(SafeFileHandle file)
        {
            int capacity = 512;
            while (capacity <= 32768)
            {
                StringBuilder path = new StringBuilder(capacity);
                uint length = GetFinalPathNameByHandleW(
                    file,
                    path,
                    (uint)path.Capacity,
                    VolumeNameGuid);
                if (length == 0)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "The reviewed directory final path could not be read.");
                }
                if (length < path.Capacity)
                {
                    return path.ToString().TrimEnd('\\');
                }
                capacity = checked((int)length + 1);
            }
            throw new InvalidOperationException("The reviewed directory final path is too long.");
        }

        public void Dispose()
        {
            if (handle != null)
            {
                handle.Dispose();
                handle = null;
            }
        }
    }
}
'@
}

function Get-EverVigilNormalizedDirectoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Description must be a fully-qualified local path."
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($pathRoot -cnotmatch '\A[A-Za-z]:\\\z') {
        throw "$Description must be on a local drive."
    }
    if ($fullPath.Length -gt $pathRoot.Length) {
        $fullPath = $fullPath.TrimEnd('\')
    }

    return $fullPath
}

function Get-EverVigilDirectoryChain {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $fullPath = Get-EverVigilNormalizedDirectoryPath `
        -Path $Path `
        -Description $Description
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if (-not [EverVigil.ReleaseDirectoryLock]::IsNativeDriveRoot($pathRoot)) {
        throw "$Description uses a drive alias instead of a native volume root."
    }
    $rootLock = [EverVigil.ReleaseDirectoryLock]::new($pathRoot)
    try {
        if ($rootLock.FinalPath -cnotmatch
                '\A\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\z') {
            throw "$Description uses a drive alias instead of a native volume root."
        }
        if (-not [EverVigil.ReleaseDirectoryLock]::IsRegisteredVolumeMount(
                $pathRoot,
                $rootLock.FinalPath)) {
            throw "$Description uses a drive alias that is not registered by the volume mount manager."
        }
    } finally {
        $rootLock.Dispose()
    }
    $chain = [Collections.Generic.List[string]]::new()
    $chain.Add($pathRoot)
    $currentPath = $pathRoot
    $relativePath = $fullPath.Substring($pathRoot.Length)
    foreach ($segment in $relativePath.Split(
            [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
            [StringSplitOptions]::RemoveEmptyEntries)) {
        $currentPath = Join-Path $currentPath $segment
        $chain.Add($currentPath)
    }

    return $chain.ToArray()
}

function Assert-EverVigilNonReparseDirectoryAncestry {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $fullPath = Get-EverVigilNormalizedDirectoryPath `
        -Path $Path `
        -Description $Description
    foreach ($componentPath in @(Get-EverVigilDirectoryChain `
            -Path $fullPath `
            -Description $Description)) {
        $item = Get-Item -LiteralPath $componentPath -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description contains a non-directory or reparse component."
        }
    }

    return $fullPath
}

function Lock-EverVigilDirectoryAncestries {
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $reviewedPaths = [Collections.Generic.List[string]]::new()
    $seenPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        foreach ($componentPath in @(Get-EverVigilDirectoryChain `
                -Path $path `
                -Description $Description)) {
            if ($seenPaths.Add($componentPath)) {
                $reviewedPaths.Add($componentPath)
            }
        }
    }

    $locks = [Collections.Generic.List[EverVigil.ReleaseDirectoryLock]]::new()
    try {
        foreach ($reviewedPath in $reviewedPaths) {
            $locks.Add([EverVigil.ReleaseDirectoryLock]::new($reviewedPath))
        }
        return $locks.ToArray()
    } catch {
        foreach ($directoryLock in $locks) {
            $directoryLock.Dispose()
        }
        throw
    }
}

function Close-EverVigilDirectoryLocks {
    param(
        [AllowEmptyCollection()]
        [EverVigil.ReleaseDirectoryLock[]]$Locks
    )

    $failures = [Collections.Generic.List[string]]::new()
    for ($index = @($Locks).Count - 1; $index -ge 0; $index--) {
        try {
            $Locks[$index].Dispose()
        } catch {
            $failures.Add($_.Exception.Message)
        }
    }
    if ($failures.Count -ne 0) {
        throw "One or more release directory locks could not be closed: $($failures -join ' | ')"
    }
}

function New-EverVigilDirectorySentinelLocks {
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $streams = [Collections.Generic.List[IO.FileStream]]::new()
    $seenPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($path in $Paths) {
            $fullPath = Assert-EverVigilNonReparseDirectoryAncestry `
                -Path $path `
                -Description $Description
            if (-not $seenPaths.Add($fullPath)) {
                continue
            }
            $sentinelPath = Join-Path `
                $fullPath `
                ('.evervigil-release-lock-' + [Guid]::NewGuid().ToString('N'))
            $stream = [IO.FileStream]::new(
                $sentinelPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::Read,
                4096,
                [IO.FileOptions]::WriteThrough)
            try {
                $sentinelBytes = [byte[]]::new(32)
                [Security.Cryptography.RandomNumberGenerator]::Fill($sentinelBytes)
                $stream.Write($sentinelBytes, 0, $sentinelBytes.Length)
                $stream.Flush($true)
                $streams.Add($stream)
            } catch {
                $stream.Dispose()
                [IO.File]::Delete($sentinelPath)
                throw
            }
        }
        return $streams.ToArray()
    } catch {
        foreach ($stream in $streams) {
            $sentinelPath = $stream.Name
            $stream.Dispose()
            [IO.File]::Delete($sentinelPath)
        }
        throw
    }
}

function Close-EverVigilDirectorySentinelLocks {
    param(
        [AllowEmptyCollection()]
        [IO.FileStream[]]$Locks
    )

    $failures = [Collections.Generic.List[string]]::new()
    for ($index = @($Locks).Count - 1; $index -ge 0; $index--) {
        $sentinelPath = $Locks[$index].Name
        try {
            $Locks[$index].Dispose()
            [IO.File]::Delete($sentinelPath)
            if (Test-Path -LiteralPath $sentinelPath) {
                throw "A release directory sentinel remained after cleanup: $sentinelPath"
            }
        } catch {
            $failures.Add($_.Exception.Message)
        }
    }
    if ($failures.Count -ne 0) {
        throw "One or more release directory sentinels could not be closed: $($failures -join ' | ')"
    }
}

function New-EverVigilSourceTreeLocks {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$RunnerSid,

        [string[]]$ExcludedRootNames = @('.git')
    )

    $reviewedWorkspace = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $WorkspaceRoot `
        -Description 'Reviewed source checkout'
    $allowedWriterSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
        $RunnerSid)
    $dangerousMask = 0x000D0156
    $workspaceIdentity = Get-EverVigilDirectoryIdentity `
        -Path $reviewedWorkspace `
        -Description 'Reviewed source checkout'
    $fileLocks = [Collections.Generic.List[IO.FileStream]]::new()
    $directoryLocks =
        [Collections.Generic.List[EverVigil.ReleaseDirectoryLock]]::new()
    try {
        $workspaceLock = [EverVigil.ReleaseDirectoryLock]::new($reviewedWorkspace)
        try {
            if (-not $workspaceLock.FinalPath.Equals(
                    $workspaceIdentity.CanonicalPath,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The reviewed source checkout changed identity while it was locked.'
            }
            $workspaceAcl = Get-Acl -LiteralPath $reviewedWorkspace -ErrorAction Stop
            $workspaceOwnerSid = ConvertTo-EverVigilSidValue -Identity $workspaceAcl.Owner
            if ($allowedWriterSids -notcontains $workspaceOwnerSid) {
                throw "The reviewed source checkout has an untrusted owner '$workspaceOwnerSid'."
            }
            $workspaceDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
                $workspaceAcl.GetSecurityDescriptorBinaryForm(),
                0)
            Assert-EverVigilAccessControlDescriptor `
                -Descriptor $workspaceDescriptor `
                -AllowedWriterSids $allowedWriterSids `
                -DangerousAccessMask $dangerousMask `
                -Description 'The reviewed source checkout' `
                -Path $reviewedWorkspace
            $directoryLocks.Add($workspaceLock)
        } catch {
            $workspaceLock.Dispose()
            throw
        }
        $sourceEntries = [Collections.Generic.List[IO.FileSystemInfo]]::new()
        $sourceEntryKeys = [Collections.Generic.List[string]]::new()
        foreach ($rootEntry in @(Get-ChildItem -LiteralPath $reviewedWorkspace -Force)) {
            if ($ExcludedRootNames -contains $rootEntry.Name) {
                continue
            }
            if (($rootEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "The reviewed source checkout contains a reparse entry: $($rootEntry.FullName)"
            }
            foreach ($entry in $(if ($rootEntry.PSIsContainer) {
                @($rootEntry) + @(
                    Get-ChildItem -LiteralPath $rootEntry.FullName -Recurse -Force -ErrorAction Stop)
            } else {
                @($rootEntry)
            })) {
                $sourceEntries.Add($entry)
                $entryKind = if ($entry.PSIsContainer) { 'D' } else { 'F' }
                $relativeEntryPath = [IO.Path]::GetRelativePath(
                    $reviewedWorkspace,
                    $entry.FullName).Replace('\', '/')
                if (@($relativeEntryPath.Split('/') | Where-Object {
                            $_ -ieq 'bin' -or $_ -ieq 'obj'
                        }).Count -ne 0) {
                    throw "The fresh reviewed source checkout contains generated output: $($entry.FullName)"
                }
                $sourceEntryKeys.Add($entryKind + ':' + $relativeEntryPath)
            }
        }

        foreach ($entry in @($sourceEntries | Where-Object PSIsContainer |
                Sort-Object { $_.FullName.Length }, FullName)) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "The reviewed source checkout contains a reparse entry: $($entry.FullName)"
            }
            $directoryLock = [EverVigil.ReleaseDirectoryLock]::new($entry.FullName)
            try {
                $expectedFinalPath = $workspaceIdentity.CanonicalPath + '\' +
                    [IO.Path]::GetRelativePath($reviewedWorkspace, $entry.FullName)
                if (-not $directoryLock.FinalPath.Equals(
                        $expectedFinalPath,
                        [StringComparison]::OrdinalIgnoreCase)) {
                    throw "A reviewed source directory changed identity while it was locked: $($entry.FullName)"
                }
                $acl = Get-Acl -LiteralPath $entry.FullName -ErrorAction Stop
                $ownerSid = ConvertTo-EverVigilSidValue -Identity $acl.Owner
                if ($allowedWriterSids -notcontains $ownerSid) {
                    throw "A reviewed source directory has an untrusted owner '$ownerSid': $($entry.FullName)"
                }
                $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
                    $acl.GetSecurityDescriptorBinaryForm(),
                    0)
                Assert-EverVigilAccessControlDescriptor `
                    -Descriptor $rawDescriptor `
                    -AllowedWriterSids $allowedWriterSids `
                    -DangerousAccessMask $dangerousMask `
                    -Description 'A reviewed source directory' `
                    -Path $entry.FullName
                $directoryLocks.Add($directoryLock)
            } catch {
                $directoryLock.Dispose()
                throw
            }
        }

        foreach ($entry in @($sourceEntries | Where-Object { -not $_.PSIsContainer } |
                Sort-Object FullName)) {
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "The reviewed source checkout contains a reparse entry: $($entry.FullName)"
                }
                $stream = [IO.FileStream]::new(
                    $entry.FullName,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Read,
                    [IO.FileShare]::Read)
                try {
                    $expectedFinalPath = $workspaceIdentity.CanonicalPath + '\' +
                        [IO.Path]::GetRelativePath($reviewedWorkspace, $entry.FullName)
                    $lockedFinalPath = [EverVigil.ReleaseDirectoryLock]::GetFinalPath(
                        $stream.SafeFileHandle)
                    if (-not $lockedFinalPath.Equals(
                            $expectedFinalPath,
                            [StringComparison]::OrdinalIgnoreCase)) {
                        throw "A reviewed source file changed identity while it was locked: $($entry.FullName)"
                    }
                    $acl = Get-Acl -LiteralPath $entry.FullName -ErrorAction Stop
                    $ownerSid = ConvertTo-EverVigilSidValue -Identity $acl.Owner
                    if ($allowedWriterSids -notcontains $ownerSid) {
                        throw "A reviewed source file has an untrusted owner '$ownerSid': $($entry.FullName)"
                    }
                    $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
                        $acl.GetSecurityDescriptorBinaryForm(),
                        0)
                    Assert-EverVigilAccessControlDescriptor `
                        -Descriptor $rawDescriptor `
                        -AllowedWriterSids $allowedWriterSids `
                        -DangerousAccessMask $dangerousMask `
                        -Description 'A reviewed source file' `
                        -Path $entry.FullName
                    $fileLocks.Add($stream)
                } catch {
                    $stream.Dispose()
                    throw
                }
        }
        if ($fileLocks.Count -eq 0 -or $directoryLocks.Count -eq 0) {
            throw 'The reviewed source checkout did not contain any lockable source files.'
        }
        $currentEntryKeys = [Collections.Generic.List[string]]::new()
        foreach ($rootEntry in @(Get-ChildItem -LiteralPath $reviewedWorkspace -Force)) {
            if ($ExcludedRootNames -contains $rootEntry.Name) {
                continue
            }
            foreach ($entry in $(if ($rootEntry.PSIsContainer) {
                @($rootEntry) + @(
                    Get-ChildItem -LiteralPath $rootEntry.FullName -Recurse -Force -ErrorAction Stop)
            } else {
                @($rootEntry)
            })) {
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "The reviewed source checkout contains a reparse entry: $($entry.FullName)"
                }
                $entryKind = if ($entry.PSIsContainer) { 'D' } else { 'F' }
                $currentEntryKeys.Add(
                    $entryKind + ':' + [IO.Path]::GetRelativePath(
                        $reviewedWorkspace,
                        $entry.FullName).Replace('\', '/'))
            }
        }
        $expectedKeys = @($sourceEntryKeys | Sort-Object)
        $actualKeys = @($currentEntryKeys | Sort-Object)
        if ($expectedKeys.Count -ne $actualKeys.Count -or
            [string]::Join("`n", $expectedKeys) -cne
                [string]::Join("`n", $actualKeys)) {
            throw 'The reviewed source checkout changed while its source tree was being locked.'
        }
        return [pscustomobject]@{
            FileLocks = $fileLocks.ToArray()
            DirectoryLocks = $directoryLocks.ToArray()
            WorkspaceRoot = $reviewedWorkspace
            EntryKeys = $expectedKeys
            ExcludedRootNames = @($ExcludedRootNames)
            AllowedWriterSids = @($allowedWriterSids)
            DangerousAccessMask = $dangerousMask
        }
    } catch {
        for ($index = $fileLocks.Count - 1; $index -ge 0; $index--) {
            $fileLocks[$index].Dispose()
        }
        for ($index = $directoryLocks.Count - 1; $index -ge 0; $index--) {
            $directoryLocks[$index].Dispose()
        }
        throw
    }
}

function Close-EverVigilSourceTreeLocks {
    param(
        [AllowNull()]
        [pscustomobject]$LockSet
    )

    if ($null -eq $LockSet) {
        return
    }
    $failures = [Collections.Generic.List[string]]::new()
    for ($index = @($LockSet.FileLocks).Count - 1; $index -ge 0; $index--) {
        try {
            $LockSet.FileLocks[$index].Dispose()
        } catch {
            $failures.Add($_.Exception.Message)
        }
    }
    for ($index = @($LockSet.DirectoryLocks).Count - 1; $index -ge 0; $index--) {
        try {
            $LockSet.DirectoryLocks[$index].Dispose()
        } catch {
            $failures.Add($_.Exception.Message)
        }
    }
    if ($failures.Count -ne 0) {
        throw "One or more reviewed source-tree locks could not be closed: $($failures -join ' | ')"
    }
}

function Assert-EverVigilSourceTreeLockState {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$LockSet
    )

    if ([string]::IsNullOrWhiteSpace([string]$LockSet.WorkspaceRoot) -or
        @($LockSet.EntryKeys).Count -eq 0 -or
        @($LockSet.FileLocks).Count -eq 0 -or
        @($LockSet.DirectoryLocks).Count -eq 0 -or
        @($LockSet.FileLocks | Where-Object {
                -not $_.CanRead -or $_.SafeFileHandle.IsClosed -or
                    $_.SafeFileHandle.IsInvalid
            }).Count -ne 0 -or
        @($LockSet.DirectoryLocks | Where-Object { -not $_.IsAlive }).Count -ne 0) {
        throw 'The reviewed source-tree lock set is not live and complete.'
    }

    $workspaceRoot = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path ([string]$LockSet.WorkspaceRoot) `
        -Description 'Reviewed source checkout'
    $currentEntryKeys = [Collections.Generic.List[string]]::new()
    foreach ($rootEntry in @(Get-ChildItem -LiteralPath $workspaceRoot -Force)) {
        if (@($LockSet.ExcludedRootNames) -contains $rootEntry.Name) {
            continue
        }
        foreach ($entry in $(if ($rootEntry.PSIsContainer) {
            @($rootEntry) + @(
                Get-ChildItem -LiteralPath $rootEntry.FullName -Recurse -Force -ErrorAction Stop)
        } else {
            @($rootEntry)
        })) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "The reviewed source checkout contains a reparse entry: $($entry.FullName)"
            }
            $relativeEntryPath = [IO.Path]::GetRelativePath(
                $workspaceRoot,
                $entry.FullName).Replace('\', '/')
            $isGeneratedEntry = @($relativeEntryPath.Split('/') | Where-Object {
                    $_ -ieq 'bin' -or $_ -ieq 'obj'
                }).Count -ne 0
            if ($isGeneratedEntry) {
                $acl = Get-Acl -LiteralPath $entry.FullName -ErrorAction Stop
                $ownerSid = ConvertTo-EverVigilSidValue -Identity $acl.Owner
                if (@($LockSet.AllowedWriterSids) -notcontains $ownerSid) {
                    throw "A generated release entry has an untrusted owner '$ownerSid': $($entry.FullName)"
                }
                $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
                    $acl.GetSecurityDescriptorBinaryForm(),
                    0)
                Assert-EverVigilAccessControlDescriptor `
                    -Descriptor $rawDescriptor `
                    -AllowedWriterSids @($LockSet.AllowedWriterSids) `
                    -DangerousAccessMask ([int]$LockSet.DangerousAccessMask) `
                    -Description 'A generated release entry' `
                    -Path $entry.FullName
                continue
            }
            $entryKind = if ($entry.PSIsContainer) { 'D' } else { 'F' }
            $currentEntryKeys.Add($entryKind + ':' + $relativeEntryPath)
        }
    }

    $expectedKeys = @($LockSet.EntryKeys | Sort-Object)
    $actualKeys = @($currentEntryKeys | Sort-Object)
    if ($expectedKeys.Count -ne $actualKeys.Count -or
        [string]::Join("`n", $expectedKeys) -cne
            [string]::Join("`n", $actualKeys)) {
        throw 'The reviewed non-generated source tree changed after it was locked.'
    }
}

function New-EverVigilFreshIsolatedRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $rootPath = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $Root `
        -Description "$Description root"
    $fullPath = Get-EverVigilNormalizedDirectoryPath `
        -Path $Path `
        -Description $Description
    if ([IO.Path]::GetDirectoryName($fullPath) -cne $rootPath) {
        throw "$Description must be a direct child of its reviewed root."
    }

    $created = $false
    try {
        [EverVigil.ReleaseDirectoryLock]::CreateFreshDirectory($fullPath)
        $created = $true
        return Assert-EverVigilDirectoryWithin `
            -Path $fullPath `
            -RequiredRoot $rootPath `
            -Description $Description
    } catch {
        $creationFailure = $_
        if ($created) {
            try {
                $createdItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
                if (-not $createdItem.PSIsContainer -or
                    ($createdItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    @(Get-ChildItem -LiteralPath $fullPath -Force -ErrorAction Stop).Count -ne 0) {
                    throw 'The failed fresh release directory is no longer an empty regular directory.'
                }
                [IO.Directory]::Delete($fullPath, $false)
                if (Test-Path -LiteralPath $fullPath) {
                    throw 'The failed fresh release directory remained after cleanup.'
                }
            } catch {
                throw "$($creationFailure.Exception.Message) Fresh-directory cleanup also failed: $($_.Exception.Message)"
            }
        }
        throw $creationFailure
    }
}

function New-EverVigilIsolatedDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $rootPath = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $Root `
        -Description "$Description root"
    $fullPath = Get-EverVigilNormalizedDirectoryPath `
        -Path $Path `
        -Description $Description
    if ($fullPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not $fullPath.StartsWith("$rootPath\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description escaped its reviewed root."
    }

    $currentPath = $rootPath
    $relativePath = [IO.Path]::GetRelativePath($rootPath, $fullPath)
    foreach ($segment in $relativePath.Split(
            [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
            [StringSplitOptions]::RemoveEmptyEntries)) {
        $currentPath = Join-Path $currentPath $segment
        if (-not (Test-Path -LiteralPath $currentPath)) {
            [IO.Directory]::CreateDirectory($currentPath) | Out-Null
        }
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description contains a non-directory or reparse component."
        }
    }

    return Assert-EverVigilDirectoryWithin `
        -Path $fullPath `
        -RequiredRoot $rootPath `
        -Description $Description
}

function Get-EverVigilDirectoryIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $fullPath = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $Path `
        -Description $Description
    $directoryLock = [EverVigil.ReleaseDirectoryLock]::new($fullPath)
    try {
        $finalPathMatch = [regex]::Match(
            $directoryLock.FinalPath,
            '(?i)\A\\\\\?\\Volume\{(?<volume>[0-9a-f-]{36})\}(?:\\(?<relative>.*))?\z')
        if (-not $finalPathMatch.Success) {
            throw "$Description canonical directory identity is malformed."
        }
        $volumeId = $finalPathMatch.Groups['volume'].Value.ToLowerInvariant()
        $relativePath = $finalPathMatch.Groups['relative'].Value.TrimEnd('\')
        return [pscustomobject]@{
            Volume = $volumeId
            VolumeSerialNumber = $directoryLock.VolumeSerialNumber
            FileId = ('{0:x16}' -f [uint64]$directoryLock.FileIndex)
            RelativePath = $relativePath
            CanonicalPath = $directoryLock.FinalPath
        }
    } finally {
        $directoryLock.Dispose()
    }
}

function Test-EverVigilDirectoryIdentityWithin {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$PathIdentity,

        [Parameter(Mandatory)]
        [pscustomobject]$RootIdentity
    )

    if ($PathIdentity.Volume -cne $RootIdentity.Volume) {
        return $false
    }
    if ([string]::IsNullOrEmpty([string]$RootIdentity.RelativePath)) {
        return $true
    }

    return $PathIdentity.RelativePath.Equals(
        $RootIdentity.RelativePath,
        [StringComparison]::OrdinalIgnoreCase) -or
        $PathIdentity.RelativePath.StartsWith(
            "$($RootIdentity.RelativePath)\",
            [StringComparison]::OrdinalIgnoreCase)
}

function Assert-EverVigilDirectoryWithin {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$RequiredRoot,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $fullPath = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $Path `
        -Description $Description
    $rootPath = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $RequiredRoot `
        -Description "$Description root"
    if (-not $fullPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.StartsWith("$rootPath\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description escaped its reviewed root."
    }

    $pathIdentity = Get-EverVigilDirectoryIdentity `
        -Path $fullPath `
        -Description $Description
    $rootIdentity = Get-EverVigilDirectoryIdentity `
        -Path $rootPath `
        -Description "$Description root"
    if (-not (Test-EverVigilDirectoryIdentityWithin `
            -PathIdentity $pathIdentity `
            -RootIdentity $rootIdentity)) {
        throw "$Description escaped the physical identity of its reviewed root."
    }

    return $fullPath
}

function Assert-EverVigilDirectoryOutside {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ForbiddenRoot,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $fullPath = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $Path `
        -Description $Description
    $forbiddenPath = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $ForbiddenRoot `
        -Description 'Reviewed source checkout'
    if ($fullPath.Equals($forbiddenPath, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith("$forbiddenPath\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must be outside the reviewed source checkout."
    }

    $pathIdentity = Get-EverVigilDirectoryIdentity `
        -Path $fullPath `
        -Description $Description
    $forbiddenIdentity = Get-EverVigilDirectoryIdentity `
        -Path $forbiddenPath `
        -Description 'Reviewed source checkout'
    if (Test-EverVigilDirectoryIdentityWithin `
            -PathIdentity $pathIdentity `
            -RootIdentity $forbiddenIdentity) {
        throw "$Description resolves inside the reviewed source checkout."
    }
    foreach ($componentPath in @(Get-EverVigilDirectoryChain `
            -Path $fullPath `
            -Description $Description)) {
        $componentIdentity = Get-EverVigilDirectoryIdentity `
            -Path $componentPath `
            -Description "$Description ancestry"
        if ($componentIdentity.Volume -ceq $forbiddenIdentity.Volume -and
            $componentIdentity.FileId -ceq $forbiddenIdentity.FileId) {
            throw "$Description resolves inside the reviewed source checkout."
        }
    }

    return $fullPath
}

function ConvertTo-EverVigilSidValue {
    param(
        [Parameter(Mandatory)]
        [object]$Identity
    )

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
        throw "A release-state ACL identity could not be resolved to a SID: $Identity"
    }
}

function Assert-EverVigilAccessControlDescriptor {
    param(
        [Parameter(Mandatory)]
        [Security.AccessControl.RawSecurityDescriptor]$Descriptor,

        [Parameter(Mandatory)]
        [string[]]$AllowedWriterSids,

        [Parameter(Mandatory)]
        [int]$DangerousAccessMask,

        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($null -eq $Descriptor.DiscretionaryAcl) {
        throw "$Description has a null discretionary ACL: $Path"
    }

    # Generic write/all bits are expanded by the Windows access check even
    # though FileSystemRights exposes the raw, unmapped mask.  Treat them as
    # dangerous before comparing the object-specific file rights.
    $reviewedDangerousMask = $DangerousAccessMask -bor 0x50000000
    foreach ($ace in $Descriptor.DiscretionaryAcl) {
        if ($ace -isnot [Security.AccessControl.QualifiedAce]) {
            throw "$Description has an unsupported discretionary ACE: $Path"
        }
        if ($ace.AceQualifier -eq
                [Security.AccessControl.AceQualifier]::AccessDenied) {
            continue
        }
        if ($ace.AceQualifier -ne
                [Security.AccessControl.AceQualifier]::AccessAllowed -or
            $ace.IsCallback -or $ace.OpaqueLength -ne 0) {
            throw "$Description has an unsupported conditional or qualified ACE: $Path"
        }
        if (([int]$ace.AccessMask -band $reviewedDangerousMask) -eq 0) {
            continue
        }
        $ruleSid = $ace.SecurityIdentifier.Value
        if ($AllowedWriterSids -notcontains $ruleSid) {
            throw "$Description can be replaced or modified by '$ruleSid': $Path"
        }
    }
}

function Assert-EverVigilReleaseStateDirectorySecurity {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$RunnerSid,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if ($RunnerSid -cnotmatch '\AS-1-(?:\d+-){2,14}\d+\z') {
        throw 'The release runner SID is malformed.'
    }
    $fullPath = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $Path `
        -Description $Description
    $allowedWriterSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
        $RunnerSid)
    $structuralRights =
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    $stateRights =
        $structuralRights -bor
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes
    $chain = @(Get-EverVigilDirectoryChain -Path $fullPath -Description $Description)
    for ($index = 0; $index -lt $chain.Count; $index++) {
        $componentPath = $chain[$index]
        $acl = Get-Acl -LiteralPath $componentPath -ErrorAction Stop
        $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
            $acl.GetSecurityDescriptorBinaryForm(),
            0)
        if ($null -eq $rawDescriptor.DiscretionaryAcl) {
            throw "$Description has a null discretionary ACL: $componentPath"
        }
        $ownerSid = ConvertTo-EverVigilSidValue -Identity $acl.Owner
        if ($allowedWriterSids -notcontains $ownerSid) {
            throw "$Description has an untrusted owner '$ownerSid': $componentPath"
        }
        $dangerousRights = if ($index -eq $chain.Count - 1) {
            $stateRights
        } else {
            $structuralRights
        }
        Assert-EverVigilAccessControlDescriptor `
            -Descriptor $rawDescriptor `
            -AllowedWriterSids $allowedWriterSids `
            -DangerousAccessMask ([int]$dangerousRights) `
            -Description $Description `
            -Path $componentPath
    }

    return $fullPath
}

function Assert-EverVigilGeneratedOutputTreeState {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [pscustomobject]$ExpectedRootIdentity,

        [Parameter(Mandatory)]
        [string]$RunnerSid,

        [Parameter(Mandatory)]
        [string]$Description,

        [AllowEmptyCollection()]
        [IO.FileStream[]]$HeldFileLocks = @()
    )

    # The caller separately protects and locks the release-state ancestry.
    # This validator owns the generated root itself and every descendant; do
    # not make a hermetic generated-tree check depend on unrelated volume-root
    # ACLs while still rejecting any reparse component in the path.
    $reviewedRoot = Assert-EverVigilNonReparseDirectoryAncestry `
        -Path $RootPath `
        -Description $Description
    $currentRootIdentity = Get-EverVigilDirectoryIdentity `
        -Path $reviewedRoot `
        -Description $Description
    if ($null -eq $ExpectedRootIdentity -or
        $currentRootIdentity.Volume -cne $ExpectedRootIdentity.Volume -or
        $currentRootIdentity.FileId -cne $ExpectedRootIdentity.FileId -or
        $currentRootIdentity.RelativePath -cne $ExpectedRootIdentity.RelativePath -or
        $currentRootIdentity.CanonicalPath -cne $ExpectedRootIdentity.CanonicalPath) {
        throw "$Description identity changed after it was established."
    }

    $allowedWriterSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
        $RunnerSid)
    $dangerousRights =
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    $canonicalRoot = $currentRootIdentity.CanonicalPath.TrimEnd('\')

    $rootAcl = Get-Acl -LiteralPath $reviewedRoot -ErrorAction Stop
    $rootOwnerSid = ConvertTo-EverVigilSidValue -Identity $rootAcl.Owner
    if ($allowedWriterSids -notcontains $rootOwnerSid) {
        throw "$Description root has an untrusted owner '$rootOwnerSid': $reviewedRoot"
    }
    $rootDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
        $rootAcl.GetSecurityDescriptorBinaryForm(),
        0)
    Assert-EverVigilAccessControlDescriptor `
        -Descriptor $rootDescriptor `
        -AllowedWriterSids $allowedWriterSids `
        -DangerousAccessMask ([int]$dangerousRights) `
        -Description $Description `
        -Path $reviewedRoot

    foreach ($entry in @(Get-ChildItem -LiteralPath $reviewedRoot -Recurse -Force -ErrorAction Stop)) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description contains a reparse entry: $($entry.FullName)"
        }
        $relativePath = [IO.Path]::GetRelativePath(
            $reviewedRoot,
            $entry.FullName)
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            $relativePath -eq '..' -or $relativePath.StartsWith('..\')) {
            throw "$Description contains an entry outside its reviewed root: $($entry.FullName)"
        }
        $expectedFinalPath = "$canonicalRoot\$relativePath"
        if ($entry.PSIsContainer) {
            $entryLock = [EverVigil.ReleaseDirectoryLock]::new($entry.FullName)
            try {
                if (-not $entryLock.FinalPath.Equals(
                        $expectedFinalPath,
                        [StringComparison]::OrdinalIgnoreCase)) {
                    throw "$Description directory changed physical identity: $($entry.FullName)"
                }
            } finally {
                $entryLock.Dispose()
            }
        } else {
            $matchingHeldLocks = @($HeldFileLocks | Where-Object {
                    $null -ne $_ -and
                    [string]::Equals(
                        [IO.Path]::GetFullPath($_.Name),
                        [IO.Path]::GetFullPath($entry.FullName),
                        [StringComparison]::OrdinalIgnoreCase)
                })
            if ($matchingHeldLocks.Count -gt 1) {
                throw "$Description has duplicate held locks for: $($entry.FullName)"
            }
            if ($matchingHeldLocks.Count -eq 1) {
                $entryLock = $matchingHeldLocks[0]
                if (-not $entryLock.CanRead -or $entryLock.SafeFileHandle.IsClosed -or
                    $entryLock.SafeFileHandle.IsInvalid) {
                    throw "$Description held file lock is not live: $($entry.FullName)"
                }
                $entryFinalPath = [EverVigil.ReleaseDirectoryLock]::GetFinalPath(
                    $entryLock.SafeFileHandle)
            } else {
                $entryLock = [IO.FileStream]::new(
                    $entry.FullName,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Read,
                    [IO.FileShare]::Read)
                try {
                    $entryFinalPath = [EverVigil.ReleaseDirectoryLock]::GetFinalPath(
                        $entryLock.SafeFileHandle)
                } finally {
                    $entryLock.Dispose()
                }
            }
            if (-not $entryFinalPath.Equals(
                    $expectedFinalPath,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "$Description file changed physical identity: $($entry.FullName)"
            }
        }

        $acl = Get-Acl -LiteralPath $entry.FullName -ErrorAction Stop
        $ownerSid = ConvertTo-EverVigilSidValue -Identity $acl.Owner
        if ($allowedWriterSids -notcontains $ownerSid) {
            throw "$Description entry has an untrusted owner '$ownerSid': $($entry.FullName)"
        }
        $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
            $acl.GetSecurityDescriptorBinaryForm(),
            0)
        Assert-EverVigilAccessControlDescriptor `
            -Descriptor $rawDescriptor `
            -AllowedWriterSids $allowedWriterSids `
            -DangerousAccessMask ([int]$dangerousRights) `
            -Description $Description `
            -Path $entry.FullName
    }

    return $reviewedRoot
}
