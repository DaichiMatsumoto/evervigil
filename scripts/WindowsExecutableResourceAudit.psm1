Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('EverVigil.ReleaseAudit.NativeResources' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace EverVigil.ReleaseAudit
{
    public sealed class IconFrame
    {
        public string ResourceName { get; set; } = "";
        public ushort LanguageId { get; set; }
        public ushort ResourceId { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public ushort BitCount { get; set; }
        public int ByteCount { get; set; }
        public string Sha256 { get; set; } = "";
    }

    public sealed class IconGroup
    {
        public string ResourceName { get; set; } = "";
        public ushort LanguageId { get; set; }
        public string ReconstructedIcoSha256 { get; set; } = "";
        public List<IconFrame> Frames { get; } = new List<IconFrame>();
    }

    public sealed class IconResourceInventory
    {
        public List<IconGroup> Groups { get; } = new List<IconGroup>();
        public List<IconFrame> Icons { get; } = new List<IconFrame>();
    }

    public static class NativeResources
    {
        private const uint LoadLibraryAsDataFile = 0x00000002;
        private const uint LoadLibraryAsImageResource = 0x00000020;
        private static readonly IntPtr RtIcon = new IntPtr(3);
        private static readonly IntPtr RtGroupIcon = new IntPtr(14);
        private static readonly IntPtr RtManifest = new IntPtr(24);

        private delegate bool EnumResourceNameCallback(
            IntPtr module, IntPtr type, IntPtr name, IntPtr parameter);
        private delegate bool EnumResourceLanguageCallback(
            IntPtr module, IntPtr type, IntPtr name, ushort language, IntPtr parameter);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string fileName, IntPtr file, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr module);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool EnumResourceNamesW(
            IntPtr module, IntPtr type, EnumResourceNameCallback callback, IntPtr parameter);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool EnumResourceLanguagesW(
            IntPtr module, IntPtr type, IntPtr name,
            EnumResourceLanguageCallback callback, IntPtr parameter);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindResourceExW(
            IntPtr module, IntPtr type, IntPtr name, ushort language);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindResourceW(IntPtr module, IntPtr name, IntPtr type);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LockResource(IntPtr resourceData);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint SizeofResource(IntPtr module, IntPtr resource);

        public static IconResourceInventory ReadExecutable(string path)
        {
            string fullPath = Path.GetFullPath(path);
            IntPtr module = LoadLibraryExW(
                fullPath,
                IntPtr.Zero,
                LoadLibraryAsDataFile | LoadLibraryAsImageResource);
            if (module == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not load executable resources: " + fullPath);

            try
            {
                var inventory = new IconResourceInventory();
                EnumerateGroups(module, inventory);
                EnumerateIcons(module, inventory);
                return inventory;
            }
            finally
            {
                FreeLibrary(module);
            }
        }

        public static byte[] ReadManifest(string path)
        {
            string fullPath = Path.GetFullPath(path);
            IntPtr module = LoadLibraryExW(
                fullPath,
                IntPtr.Zero,
                LoadLibraryAsDataFile | LoadLibraryAsImageResource);
            if (module == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not load executable resources: " + fullPath);

            try
            {
                return ReadResource(module, RtManifest, new IntPtr(1), 0);
            }
            finally
            {
                FreeLibrary(module);
            }
        }

        public static List<IconFrame> ReadIco(string path)
        {
            byte[] bytes = File.ReadAllBytes(Path.GetFullPath(path));
            if (bytes.Length < 6 || ReadUInt16(bytes, 0) != 0 || ReadUInt16(bytes, 2) != 1)
                throw new InvalidDataException("The expected icon is not a valid ICO file.");

            int count = ReadUInt16(bytes, 4);
            if (count < 1 || bytes.Length < 6 + (count * 16))
                throw new InvalidDataException("The expected ICO directory is truncated.");

            var result = new List<IconFrame>();
            for (int index = 0; index < count; index++)
            {
                int offset = 6 + (index * 16);
                int width = bytes[offset] == 0 ? 256 : bytes[offset];
                int height = bytes[offset + 1] == 0 ? 256 : bytes[offset + 1];
                ushort bitCount = ReadUInt16(bytes, offset + 6);
                uint byteCount = ReadUInt32(bytes, offset + 8);
                uint imageOffset = ReadUInt32(bytes, offset + 12);
                if (byteCount == 0 || imageOffset > bytes.Length ||
                    byteCount > bytes.Length - imageOffset)
                    throw new InvalidDataException("The expected ICO frame is truncated.");

                byte[] image = new byte[byteCount];
                Buffer.BlockCopy(bytes, checked((int)imageOffset), image, 0, checked((int)byteCount));
                result.Add(new IconFrame
                {
                    ResourceName = "ICO:" + index,
                    ResourceId = checked((ushort)index),
                    Width = width,
                    Height = height,
                    BitCount = bitCount,
                    ByteCount = image.Length,
                    Sha256 = Hash(image)
                });
            }
            return result;
        }

        private static void EnumerateGroups(IntPtr module, IconResourceInventory inventory)
        {
            EnumResourceNameCallback nameCallback = (m, t, name, parameter) =>
            {
                string groupName = ResourceName(name);
                EnumResourceLanguageCallback languageCallback = (lm, lt, ln, language, lp) =>
                {
                    byte[] groupBytes = ReadResource(lm, RtGroupIcon, ln, language);
                    var group = ParseGroup(lm, groupName, language, groupBytes);
                    inventory.Groups.Add(group);
                    return true;
                };
                if (!EnumResourceLanguagesW(m, RtGroupIcon, name, languageCallback, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Could not enumerate RT_GROUP_ICON languages.");
                return true;
            };

            if (!EnumResourceNamesW(module, RtGroupIcon, nameCallback, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 1813 && error != 1814)
                    throw new Win32Exception(error, "Could not enumerate RT_GROUP_ICON resources.");
            }
        }

        private static void EnumerateIcons(IntPtr module, IconResourceInventory inventory)
        {
            EnumResourceNameCallback nameCallback = (m, t, name, parameter) =>
            {
                string iconName = ResourceName(name);
                ushort resourceId = NumericResourceId(name);
                EnumResourceLanguageCallback languageCallback = (lm, lt, ln, language, lp) =>
                {
                    byte[] iconBytes = ReadResource(lm, RtIcon, ln, language);
                    int width;
                    int height;
                    ushort bitCount;
                    ReadImageDimensions(iconBytes, out width, out height, out bitCount);
                    inventory.Icons.Add(new IconFrame
                    {
                        ResourceName = iconName,
                        LanguageId = language,
                        ResourceId = resourceId,
                        Width = width,
                        Height = height,
                        BitCount = bitCount,
                        ByteCount = iconBytes.Length,
                        Sha256 = Hash(iconBytes)
                    });
                    return true;
                };
                if (!EnumResourceLanguagesW(m, RtIcon, name, languageCallback, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Could not enumerate RT_ICON languages.");
                return true;
            };

            if (!EnumResourceNamesW(module, RtIcon, nameCallback, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 1813 && error != 1814)
                    throw new Win32Exception(error, "Could not enumerate RT_ICON resources.");
            }
        }

        private static IconGroup ParseGroup(
            IntPtr module, string name, ushort language, byte[] bytes)
        {
            if (bytes.Length < 6 || ReadUInt16(bytes, 0) != 0 || ReadUInt16(bytes, 2) != 1)
                throw new InvalidDataException("An RT_GROUP_ICON directory is invalid.");
            int count = ReadUInt16(bytes, 4);
            if (count < 1 || bytes.Length < 6 + (count * 14))
                throw new InvalidDataException("An RT_GROUP_ICON directory is truncated.");

            var group = new IconGroup { ResourceName = name, LanguageId = language };
            var images = new List<byte[]>();
            for (int index = 0; index < count; index++)
            {
                int offset = 6 + (index * 14);
                int declaredWidth = bytes[offset] == 0 ? 256 : bytes[offset];
                int declaredHeight = bytes[offset + 1] == 0 ? 256 : bytes[offset + 1];
                ushort declaredBitCount = ReadUInt16(bytes, offset + 6);
                uint declaredBytes = ReadUInt32(bytes, offset + 8);
                ushort resourceId = ReadUInt16(bytes, offset + 12);
                byte[] iconBytes = ReadResource(module, RtIcon, new IntPtr(resourceId), language);
                images.Add(iconBytes);
                int actualWidth;
                int actualHeight;
                ushort actualBitCount;
                ReadImageDimensions(iconBytes, out actualWidth, out actualHeight, out actualBitCount);
                if (actualWidth > 0 && actualWidth != declaredWidth)
                    throw new InvalidDataException("RT_GROUP_ICON width does not match RT_ICON data.");
                if (actualHeight > 0 && actualHeight != declaredHeight)
                    throw new InvalidDataException("RT_GROUP_ICON height does not match RT_ICON data.");
                if (declaredBytes != iconBytes.Length)
                    throw new InvalidDataException("RT_GROUP_ICON byte count does not match RT_ICON data.");

                group.Frames.Add(new IconFrame
                {
                    ResourceName = "#" + resourceId,
                    LanguageId = language,
                    ResourceId = resourceId,
                    Width = declaredWidth,
                    Height = declaredHeight,
                    BitCount = declaredBitCount != 0 ? declaredBitCount : actualBitCount,
                    ByteCount = iconBytes.Length,
                    Sha256 = Hash(iconBytes)
                });
            }
            group.ReconstructedIcoSha256 = Hash(ReconstructIco(bytes, images));
            return group;
        }

        private static byte[] ReconstructIco(byte[] groupBytes, List<byte[]> images)
        {
            int directorySize = checked(6 + (images.Count * 16));
            int totalSize = directorySize;
            foreach (byte[] image in images)
                totalSize = checked(totalSize + image.Length);
            byte[] ico = new byte[totalSize];
            Buffer.BlockCopy(groupBytes, 0, ico, 0, 6);
            int imageOffset = directorySize;
            for (int index = 0; index < images.Count; index++)
            {
                int groupOffset = 6 + (index * 14);
                int icoOffset = 6 + (index * 16);
                Buffer.BlockCopy(groupBytes, groupOffset, ico, icoOffset, 12);
                WriteUInt32(ico, icoOffset + 12, checked((uint)imageOffset));
                Buffer.BlockCopy(images[index], 0, ico, imageOffset, images[index].Length);
                imageOffset += images[index].Length;
            }
            return ico;
        }

        private static byte[] ReadResource(
            IntPtr module, IntPtr type, IntPtr name, ushort language)
        {
            IntPtr resource = FindResourceExW(module, type, name, language);
            if (resource == IntPtr.Zero)
                resource = FindResourceW(module, name, type);
            if (resource == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not find icon resource.");
            uint size = SizeofResource(module, resource);
            if (size == 0)
                throw new InvalidDataException("An icon resource is empty.");
            IntPtr loaded = LoadResource(module, resource);
            IntPtr locked = LockResource(loaded);
            if (loaded == IntPtr.Zero || locked == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load icon resource.");
            byte[] bytes = new byte[size];
            Marshal.Copy(locked, bytes, 0, checked((int)size));
            return bytes;
        }

        private static void ReadImageDimensions(
            byte[] bytes, out int width, out int height, out ushort bitCount)
        {
            width = 0;
            height = 0;
            bitCount = 0;
            if (bytes.Length >= 24 &&
                bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47)
            {
                width = ReadInt32BigEndian(bytes, 16);
                height = ReadInt32BigEndian(bytes, 20);
                return;
            }
            if (bytes.Length >= 16)
            {
                uint headerSize = ReadUInt32(bytes, 0);
                if (headerSize >= 12)
                {
                    if (headerSize == 12)
                    {
                        width = ReadUInt16(bytes, 4);
                        height = ReadUInt16(bytes, 6) / 2;
                        bitCount = ReadUInt16(bytes, 10);
                    }
                    else if (bytes.Length >= 16)
                    {
                        width = Math.Abs(ReadInt32(bytes, 4));
                        height = Math.Abs(ReadInt32(bytes, 8)) / 2;
                        bitCount = ReadUInt16(bytes, 14);
                    }
                }
            }
        }

        private static string ResourceName(IntPtr value)
        {
            ulong unsignedValue = unchecked((ulong)value.ToInt64());
            if ((unsignedValue >> 16) == 0)
                return "#" + (unsignedValue & 0xffff);
            return Marshal.PtrToStringUni(value) ?? "";
        }

        private static ushort NumericResourceId(IntPtr value)
        {
            ulong unsignedValue = unchecked((ulong)value.ToInt64());
            return (unsignedValue >> 16) == 0 ? (ushort)(unsignedValue & 0xffff) : (ushort)0;
        }

        private static string Hash(byte[] bytes)
        {
            using (SHA256 sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
        }

        private static ushort ReadUInt16(byte[] bytes, int offset)
        {
            return (ushort)(bytes[offset] | (bytes[offset + 1] << 8));
        }

        private static uint ReadUInt32(byte[] bytes, int offset)
        {
            return (uint)(bytes[offset] |
                (bytes[offset + 1] << 8) |
                (bytes[offset + 2] << 16) |
                (bytes[offset + 3] << 24));
        }

        private static void WriteUInt32(byte[] bytes, int offset, uint value)
        {
            bytes[offset] = (byte)value;
            bytes[offset + 1] = (byte)(value >> 8);
            bytes[offset + 2] = (byte)(value >> 16);
            bytes[offset + 3] = (byte)(value >> 24);
        }

        private static int ReadInt32(byte[] bytes, int offset)
        {
            return unchecked((int)ReadUInt32(bytes, offset));
        }

        private static int ReadInt32BigEndian(byte[] bytes, int offset)
        {
            return (bytes[offset] << 24) |
                (bytes[offset + 1] << 16) |
                (bytes[offset + 2] << 8) |
                bytes[offset + 3];
        }
    }
}
'@
}

function Get-EverVigilIcoFrameInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "ICO file was not found: $Path"
    }
    @([EverVigil.ReleaseAudit.NativeResources]::ReadIco(
            [IO.Path]::GetFullPath($Path)))
}

function Get-EverVigilExecutableIconInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Executable was not found: $Path"
    }
    [EverVigil.ReleaseAudit.NativeResources]::ReadExecutable(
        [IO.Path]::GetFullPath($Path))
}

function Get-EverVigilExecutableManifestAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Executable was not found: $Path"
    }
    $bytes = [EverVigil.ReleaseAudit.NativeResources]::ReadManifest(
        [IO.Path]::GetFullPath($Path))
    if ($bytes.Length -lt 1 -or $bytes.Length -gt 1048576) {
        throw 'The RT_MANIFEST resource has an invalid size.'
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) {
        $text = $text.Substring(1)
    }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = $null
    $stringReader = [IO.StringReader]::new($text)
    try {
        $reader = [Xml.XmlReader]::Create($stringReader, $settings)
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
    } finally {
        if ($reader) {
            $reader.Dispose()
        }
        $stringReader.Dispose()
    }
    $executionLevels = @($document.SelectNodes(
            '//*[local-name()="requestedExecutionLevel"]'))
    if ($executionLevels.Count -ne 1) {
        throw "The executable manifest must contain exactly one requestedExecutionLevel; found $($executionLevels.Count)."
    }
    $executionLevel = $executionLevels[0]
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $manifestHash = [BitConverter]::ToString(
            $sha256.ComputeHash($bytes)).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }
    [pscustomobject][ordered]@{
        byteCount = $bytes.Length
        sha256 = $manifestHash
        requestedExecutionLevelCount = $executionLevels.Count
        level = [string]$executionLevel.GetAttribute('level')
        uiAccess = [string]$executionLevel.GetAttribute('uiAccess')
    }
}

function Get-IconArgbPixelHash {
    param(
        [Parameter(Mandatory)][Drawing.Icon]$Icon,
        [Parameter(Mandatory)][int]$Size
    )

    $bitmap = [Drawing.Bitmap]::new(
        $Size,
        $Size,
        [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = $null
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.DrawIcon($Icon, [Drawing.Rectangle]::new(0, 0, $Size, $Size))
        $pixels = [byte[]]::new($Size * $Size * 4)
        $offset = 0
        for ($y = 0; $y -lt $Size; $y++) {
            for ($x = 0; $x -lt $Size; $x++) {
                $color = $bitmap.GetPixel($x, $y)
                $pixels[$offset++] = $color.A
                $pixels[$offset++] = $color.R
                $pixels[$offset++] = $color.G
                $pixels[$offset++] = $color.B
            }
        }
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pixels))
    } finally {
        if ($graphics) {
            $graphics.Dispose()
        }
        $bitmap.Dispose()
    }
}

function Get-EverVigilShellIconAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedIconPath,
        [ValidateRange(16, 256)][int]$ComparisonSize = 32
    )

    Add-Type -AssemblyName System.Drawing
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedExpectedIconPath = [IO.Path]::GetFullPath($ExpectedIconPath)
    $shellIcon = $null
    $expectedIcon = $null
    try {
        $shellIcon = [Drawing.Icon]::ExtractAssociatedIcon($resolvedPath)
        if (-not $shellIcon) {
            throw "Windows did not extract an associated shell icon from '$resolvedPath'."
        }
        $expectedIcon = [Drawing.Icon]::new(
            $resolvedExpectedIconPath,
            $ComparisonSize,
            $ComparisonSize)
        $shellHash = Get-IconArgbPixelHash -Icon $shellIcon -Size $ComparisonSize
        $expectedHash = Get-IconArgbPixelHash -Icon $expectedIcon -Size $ComparisonSize
        [pscustomobject][ordered]@{
            extractionMethod = 'System.Drawing.Icon.ExtractAssociatedIcon'
            comparison = "${ComparisonSize}x${ComparisonSize} normalized ARGB pixels"
            extractedNativeWidth = $shellIcon.Width
            extractedNativeHeight = $shellIcon.Height
            shellPixelSha256 = $shellHash
            placeholderPixelSha256 = $expectedHash
            matchesPlaceholder = [string]::Equals(
                $shellHash,
                $expectedHash,
                [StringComparison]::OrdinalIgnoreCase)
        }
    } finally {
        if ($expectedIcon) {
            $expectedIcon.Dispose()
        }
        if ($shellIcon) {
            $shellIcon.Dispose()
        }
    }
}

function Assert-EverVigilExecutableResources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Application', 'Broker', 'Installer', 'Uninstaller')]
        [string]$ArtifactKind,
        [Parameter(Mandatory)][string]$ExpectedIconPath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][hashtable]$ExpectedVersionInfo,
        [ValidateSet('asInvoker', 'highestAvailable', 'requireAdministrator')]
        [string]$ExpectedExecutionLevel,
        [string[]]$DenySha256 = @()
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $expectedFrames = @(Get-EverVigilIcoFrameInventory -Path $ExpectedIconPath)
    $inventory = Get-EverVigilExecutableIconInventory -Path $resolvedPath
    $failures = [Collections.Generic.List[string]]::new()

    if ($inventory.Groups.Count -lt 1) {
        $failures.Add('RT_GROUP_ICON is missing.')
    }
    if ($inventory.Icons.Count -lt 1) {
        $failures.Add('RT_ICON is missing.')
    }

    $expectedHashes = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($frame in $expectedFrames) {
        [void]$expectedHashes.Add($frame.Sha256)
    }
    $denyHashes = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($hash in $DenySha256) {
        if (-not [string]::IsNullOrWhiteSpace($hash)) {
            [void]$denyHashes.Add($hash.Trim())
        }
    }

    $matchingGroups = @($inventory.Groups | Where-Object {
            $_.Frames.Count -gt 0 -and
            @($_.Frames | Where-Object { -not $expectedHashes.Contains($_.Sha256) }).Count -eq 0
        })
    $matchingGroupNames = @($matchingGroups | ForEach-Object { $_.ResourceName })
    $nonMatchingGroupNames = @($inventory.Groups |
            Where-Object { $_.ResourceName -notin $matchingGroupNames } |
            ForEach-Object { $_.ResourceName })
    if ($matchingGroups.Count -lt 1) {
        $failures.Add('No RT_GROUP_ICON consists exclusively of placeholder ICO frames.')
    }
    if ($ArtifactKind -in @('Installer', 'Uninstaller') -and
        'MAINICON' -notin $matchingGroupNames) {
        $failures.Add('The Inno Setup MAINICON group is not the placeholder icon.')
    }

    $shellSelection = Get-EverVigilShellIconAudit `
        -Path $resolvedPath `
        -ExpectedIconPath $ExpectedIconPath `
        -ComparisonSize 32
    if (-not $shellSelection.matchesPlaceholder) {
        $failures.Add(
            'Windows Icon.ExtractAssociatedIcon selected pixels that do not match the placeholder icon.')
    }

    $requiredSizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    $matchedSizes = @($matchingGroups |
            ForEach-Object { $_.Frames } |
            ForEach-Object { $_.Width } |
            Sort-Object -Unique)
    foreach ($requiredSize in $requiredSizes) {
        if ($requiredSize -notin $matchedSizes) {
            $failures.Add("Placeholder icon frame ${requiredSize}px is missing.")
        }
    }
    foreach ($frame in @($inventory.Icons)) {
        if ($denyHashes.Contains($frame.Sha256)) {
            $failures.Add("Deny-listed RT_ICON hash was found: $($frame.Sha256)")
        }
    }
    foreach ($group in @($inventory.Groups)) {
        if ($denyHashes.Contains($group.ReconstructedIcoSha256)) {
            $failures.Add(
                "Deny-listed reconstructed RT_GROUP_ICON hash was found: $($group.ReconstructedIcoSha256)")
        }
    }
    $fileHash = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash
    if ($denyHashes.Contains($fileHash)) {
        $failures.Add("Deny-listed executable hash was found: $fileHash")
    }

    $manifestAudit = $null
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExecutionLevel)) {
        try {
            $manifestAudit = Get-EverVigilExecutableManifestAudit -Path $resolvedPath
            if ($manifestAudit.level -cne $ExpectedExecutionLevel) {
                $failures.Add(
                    "Manifest requestedExecutionLevel mismatch. Expected '$ExpectedExecutionLevel'; actual '$($manifestAudit.level)'.")
            }
            if ($manifestAudit.uiAccess -cne 'false') {
                $failures.Add(
                    "Manifest requestedExecutionLevel uiAccess must be false; actual '$($manifestAudit.uiAccess)'.")
            }
            if ($denyHashes.Contains([string]$manifestAudit.sha256)) {
                $failures.Add(
                    "Deny-listed RT_MANIFEST hash was found: $($manifestAudit.sha256)")
            }
        } catch {
            $failures.Add("RT_MANIFEST validation failed: $($_.Exception.Message)")
        }
    }

    $versionInfo = (Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop).VersionInfo
    $actualVersionInfo = [ordered]@{
        ProductName = ([string]$versionInfo.ProductName).Trim()
        CompanyName = ([string]$versionInfo.CompanyName).Trim()
        FileVersion = ([string]$versionInfo.FileVersion).Trim()
        ProductVersion = ([string]$versionInfo.ProductVersion).Trim()
        FileDescription = ([string]$versionInfo.FileDescription).Trim()
        OriginalFilename = ([string]$versionInfo.OriginalFilename).Trim()
    }
    foreach ($field in $ExpectedVersionInfo.Keys) {
        if (-not $actualVersionInfo.Contains($field)) {
            $failures.Add("Unknown expected VersionInfo field: $field")
            continue
        }
        $expectedPattern = [string]$ExpectedVersionInfo[$field]
        if ([string]::IsNullOrWhiteSpace($actualVersionInfo[$field]) -or
            $actualVersionInfo[$field] -notmatch $expectedPattern) {
            $failures.Add(
                "VersionInfo ${field} mismatch. Expected /$expectedPattern/; actual '$($actualVersionInfo[$field])'.")
        }
    }
    foreach ($field in $actualVersionInfo.Keys) {
        $value = [string]$actualVersionInfo[$field]
        foreach ($prohibited in @(
                ('Even Terminal ' + 'Supervisor'),
                ('even' + '-realities-favicon'),
                ('even-realities' + '\.ico'),
                ('Official ' + 'logo'),
                ('official Even Realities ' + 'icon')
            )) {
            if ($value -match $prohibited) {
                $failures.Add("VersionInfo ${field} contains prohibited legacy branding: $value")
            }
        }
    }

    $result = [ordered]@{
        artifactKind = $ArtifactKind
        path = $resolvedPath
        sha256 = $fileHash
        byteCount = (Get-Item -LiteralPath $resolvedPath).Length
        versionInfo = $actualVersionInfo
        manifest = $manifestAudit
        iconResources = [ordered]@{
            groupCount = $inventory.Groups.Count
            iconCount = $inventory.Icons.Count
            matchingPlaceholderGroupCount = $matchingGroups.Count
            matchingPlaceholderGroupNames = @($matchingGroupNames)
            nonMatchingGroupNames = @($nonMatchingGroupNames)
            nonMatchingGroupInterpretation = if ('Z_GROUPICON' -in $nonMatchingGroupNames) {
                'The Inno Setup-generated Z_GROUPICON is a secondary resource group. MAINICON is the placeholder group, and Windows shell-associated icon extraction selects placeholder pixels rather than Z_GROUPICON.'
            } else {
                'No Inno Setup Z_GROUPICON secondary resource group was present.'
            }
            shellSelection = $shellSelection
            selectionConclusion = if ($shellSelection.matchesPlaceholder) {
                'Windows shell-associated icon selection resolves to the placeholder pixels; non-matching groups are not selected for the file icon.'
            } else {
                'Windows shell-associated icon selection does not resolve to the placeholder pixels.'
            }
            matchedSizes = @($matchedSizes)
            groups = @($inventory.Groups)
            icons = @($inventory.Icons)
        }
        passed = $failures.Count -eq 0
        failures = @($failures)
    }
    if ($failures.Count -gt 0) {
        $exception = [IO.InvalidDataException]::new(
            "$ArtifactKind resource audit failed for '$resolvedPath': $($failures -join ' | ')")
        $exception.Data['AuditResult'] = $result
        throw $exception
    }
    [pscustomobject]$result
}

Export-ModuleMember -Function @(
    'Get-EverVigilIcoFrameInventory',
    'Get-EverVigilExecutableIconInventory',
    'Get-EverVigilExecutableManifestAudit',
    'Get-EverVigilShellIconAudit',
    'Assert-EverVigilExecutableResources'
)
