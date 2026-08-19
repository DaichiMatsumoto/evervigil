using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using EverVigil.Broker.Protocol;

namespace EverVigil.Broker;

internal static class ProtectedBrokerInstallation
{
    internal static LockedBrokerImage LockLoadedImage()
    {
        var sourcePath = Path.GetFullPath(Environment.ProcessPath ??
            throw new InvalidOperationException("Broker executable path is unavailable."));
        EnsureBootstrapSource(sourcePath);
        var stream = new FileStream(
            sourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            128 * 1024,
            FileOptions.SequentialScan);
        try
        {
            var finalPath = GetFinalPath(stream.SafeFileHandle.DangerousGetHandle());
            if (!string.Equals(finalPath, sourcePath, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException(
                    "Loaded broker image final path does not match Environment.ProcessPath.");
            }
            if (!GetFileInformationByHandle(
                    stream.SafeFileHandle.DangerousGetHandle(),
                    out var fileInformation))
            {
                throw new IOException(
                    "Could not read loaded broker file identity.",
                    Marshal.GetExceptionForHR(Marshal.GetHRForLastWin32Error()));
            }
            if (fileInformation.NumberOfLinks != 1)
            {
                throw new InvalidDataException("Loaded broker image must not be a hard link.");
            }
            var version = GetProductVersion();
            var identity = ReadIdentity(stream, version);
            return new LockedBrokerImage(
                sourcePath,
                stream,
                identity,
                fileInformation.VolumeSerialNumber,
                ((ulong)fileInformation.FileIndexHigh << 32) | fileInformation.FileIndexLow);
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    internal static ProtectedBrokerReadiness EnsureReady(
        bool bootstrapRequested,
        LockedBrokerImage loadedImage)
    {
        ArgumentNullException.ThrowIfNull(loadedImage);
        var sourcePath = loadedImage.Path;
        var commonData = Path.GetFullPath(Environment.GetFolderPath(
            Environment.SpecialFolder.CommonApplicationData));
        var version = GetProductVersion();
        var canonicalPath = PrivilegedBrokerPaths.GetProtectedExecutablePath(commonData, version);
        var receiptPath = PrivilegedBrokerPaths.GetInstallationReceiptPath(commonData, version);
        var sourceIsCanonical = string.Equals(
            sourcePath,
            canonicalPath,
            StringComparison.OrdinalIgnoreCase);
        var retirementPending = ProtectedBrokerRetirement.ReceiptExists(
            commonData,
            version);

        if (sourceIsCanonical)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, sourcePath);
            if (bootstrapRequested)
            {
                throw new InvalidOperationException(
                    "Protected broker invocation must not use bootstrap mode.");
            }
            if (retirementPending)
            {
                _ = ProtectedBrokerRetirement.ValidateCanonicalRetirement(
                    commonData,
                    version,
                    loadedImage.Identity);
                return new ProtectedBrokerReadiness(
                    loadedImage.Identity,
                    IsCanonicalInvocation: true,
                    InstalledNow: false,
                    RetirementPending: true);
            }
            var canonical = ValidateCanonical(commonData, version, canonicalPath, receiptPath);
            if (canonical.Length != loadedImage.Identity.Length ||
                !string.Equals(
                    canonical.Sha256,
                    loadedImage.Identity.Sha256,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Loaded canonical broker image does not match its protected receipt.");
            }
            return new ProtectedBrokerReadiness(
                canonical,
                IsCanonicalInvocation: true,
                InstalledNow: false);
        }

        if (!bootstrapRequested)
        {
            throw new UnauthorizedAccessException(
                "Only the canonical ProgramData broker may handle subsequent requests.");
        }
        EnsureBootstrapSource(sourcePath);

        if (retirementPending)
        {
            throw new UnauthorizedAccessException(
                "Protected broker retirement must be completed before bootstrap installation.");
        }

        var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(commonData, version);
        CleanupInstallationTemporaries(commonData, versionRoot);

        if (File.Exists(canonicalPath))
        {
            if (!File.Exists(receiptPath))
            {
                ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, canonicalPath);
                ProtectedBrokerAccess.ValidateFile(
                    canonicalPath,
                    allowUsersReadAndExecute: true);
                ValidateRegularSingleLinkFile(canonicalPath);
                var stranded = ReadIdentity(canonicalPath, version);
                if (stranded.Length != loadedImage.Identity.Length ||
                    !string.Equals(
                        stranded.Sha256,
                        loadedImage.Identity.Sha256,
                        StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "Receipt-less canonical broker does not match the locked bootstrap image.");
                }
                WriteReceipt(receiptPath, stranded);
                var repaired = ValidateCanonical(
                    commonData,
                    version,
                    canonicalPath,
                    receiptPath);
                return new ProtectedBrokerReadiness(
                    repaired,
                    IsCanonicalInvocation: false,
                    InstalledNow: true);
            }
            var installed = ValidateCanonical(commonData, version, canonicalPath, receiptPath);
            if (installed.Length != loadedImage.Identity.Length ||
                !string.Equals(
                    installed.Sha256,
                    loadedImage.Identity.Sha256,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "A different same-version protected broker is already installed.");
            }
            throw new UnauthorizedAccessException(
                "The protected broker already exists; invoke its canonical ProgramData path.");
        }

        if (File.Exists(receiptPath))
        {
            throw new InvalidDataException(
                "A protected installation receipt exists without its canonical broker image.");
        }

        InstallLoadedImage(
            commonData,
            version,
            loadedImage,
            canonicalPath,
            receiptPath);
        var installedNow = ValidateCanonical(
            commonData,
            version,
            canonicalPath,
            receiptPath);
        return new ProtectedBrokerReadiness(
            installedNow,
            IsCanonicalInvocation: false,
            InstalledNow: true);
    }

    internal static string GetProductVersion()
    {
        var versionText = BrokerBuildInfo.ProductVersion;
        if (!Version.TryParse(versionText, out var version) || version.Build < 0)
        {
            throw new InvalidDataException("Broker version is invalid.");
        }
        return $"{version.Major}.{version.Minor}.{version.Build}";
    }

    internal static ProtectedBrokerIdentity RecoverReceiptlessCanonicalForTests(
        string commonData,
        string version,
        string sourcePath)
    {
        var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(commonData, version);
        var canonicalPath = PrivilegedBrokerPaths.GetProtectedExecutablePath(
            commonData,
            version);
        var receiptPath = PrivilegedBrokerPaths.GetInstallationReceiptPath(
            commonData,
            version);
        CleanupInstallationTemporaries(
            commonData,
            versionRoot,
            enforceProtectedAccess: false);
        ValidateRegularSingleLinkFile(canonicalPath);
        var source = ReadIdentity(sourcePath, version);
        var canonical = ReadIdentity(canonicalPath, version);
        if (source.Length != canonical.Length ||
            !string.Equals(source.Sha256, canonical.Sha256, StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Receipt-less test canonical does not match its locked source identity.");
        }
        if (!File.Exists(receiptPath))
        {
            WriteReceipt(receiptPath, canonical, enforceProtectedAccess: false);
        }
        var json = File.ReadAllText(receiptPath, Encoding.UTF8);
        ValidateReceiptShape(json);
        var receipt = JsonSerializer.Deserialize(
            json,
            BrokerJsonContext.Default.ProtectedBrokerIdentity) ??
            throw new InvalidDataException(
                "Test installation receipt is empty.");
        if (receipt != canonical)
        {
            throw new InvalidDataException(
                "Test installation receipt does not match canonical identity.");
        }
        return canonical;
    }

    internal static void CleanupInstallationTemporariesForTests(
        string commonData,
        string version) =>
        CleanupInstallationTemporaries(
            commonData,
            PrivilegedBrokerPaths.GetVersionRoot(commonData, version),
            enforceProtectedAccess: false);

    internal static void RejectOrphanedInstallationReceiptForTests(
        string commonData,
        string version)
    {
        var canonicalPath = PrivilegedBrokerPaths.GetProtectedExecutablePath(
            commonData,
            version);
        var receiptPath = PrivilegedBrokerPaths.GetInstallationReceiptPath(
            commonData,
            version);
        if (!File.Exists(canonicalPath) && File.Exists(receiptPath))
        {
            throw new InvalidDataException(
                "A protected installation receipt exists without its canonical broker image.");
        }
    }

    internal static bool EnsureRetirementInstallationReceipt(
        string commonData,
        string version,
        ProtectedBrokerIdentity identity,
        SecurityIdentifier retirementOwnerSid,
        bool enforceProtectedAccess)
    {
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentNullException.ThrowIfNull(retirementOwnerSid);
        var receiptPath = PrivilegedBrokerPaths.GetInstallationReceiptPath(
            commonData,
            version);
        if (!File.Exists(receiptPath))
        {
            WriteReceipt(receiptPath, identity, enforceProtectedAccess);
            return true;
        }

        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, receiptPath);
            try
            {
                ProtectedBrokerAccess.ValidateFile(
                    receiptPath,
                    allowUsersReadAndExecute: true);
            }
            catch (InvalidDataException)
            {
                ProtectedBrokerAccess.ValidateRetirementFile(
                    receiptPath,
                    retirementOwnerSid);
            }
        }
        var json = File.ReadAllText(receiptPath, Encoding.UTF8);
        ValidateReceiptShape(json);
        var receipt = JsonSerializer.Deserialize(
            json,
            BrokerJsonContext.Default.ProtectedBrokerIdentity) ??
            throw new InvalidDataException(
            "Protected installation receipt is empty during retirement.");
        if (receipt != identity)
        {
            throw new InvalidDataException(
                "Protected installation receipt does not match the retiring canonical broker.");
        }
        return false;
    }

    private static void InstallLoadedImage(
        string commonData,
        string version,
        LockedBrokerImage loadedImage,
        string canonicalPath,
        string receiptPath)
    {
        var brokerRoot = PrivilegedBrokerPaths.GetBrokerRoot(commonData);
        var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(commonData, version);
        CreateProtectedAncestry(commonData, brokerRoot, versionRoot);
        CleanupInstallationTemporaries(commonData, versionRoot);

        var sourceIdentity = loadedImage.Identity;
        var temporaryPath = Path.Combine(
            versionRoot,
            $".{PrivilegedBrokerPaths.BrokerFileName}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var destination = new FileStream(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       128 * 1024,
                       FileOptions.WriteThrough))
            {
                loadedImage.Stream.Position = 0;
                loadedImage.Stream.CopyTo(destination);
                destination.Flush(flushToDisk: true);
            }
            ProtectedBrokerAccess.ProtectBinaryFile(temporaryPath);
            var copiedIdentity = ReadIdentity(temporaryPath, version);
            if (copiedIdentity.Length != sourceIdentity.Length ||
                !string.Equals(
                    copiedIdentity.Sha256,
                    sourceIdentity.Sha256,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException("Broker image changed during protected installation.");
            }
            File.Move(temporaryPath, canonicalPath, overwrite: false);
            ProtectedBrokerAccess.ProtectBinaryFile(canonicalPath);
            WriteReceipt(receiptPath, sourceIdentity);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static void CreateProtectedAncestry(
        string commonData,
        string brokerRoot,
        string versionRoot)
    {
        var productRoot = Path.GetDirectoryName(brokerRoot) ??
            throw new InvalidDataException("Broker product root is unavailable.");
        foreach (var directory in new[] { productRoot, brokerRoot, versionRoot })
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, directory);
            ProtectedBrokerAccess.CreateBinaryDirectory(directory);
        }

        var stateRoot = PrivilegedBrokerPaths.GetStateRoot(commonData);
        ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, stateRoot);
        ProtectedBrokerAccess.CreateStateRootDirectory(stateRoot);
    }

    internal static ProtectedBrokerIdentity ValidateCanonical(
        string commonData,
        string version,
        string canonicalPath,
        string receiptPath)
    {
        var brokerRoot = PrivilegedBrokerPaths.GetBrokerRoot(commonData);
        var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(commonData, version);
        var productRoot = Path.GetDirectoryName(brokerRoot) ??
            throw new InvalidDataException("Broker product root is unavailable.");
        foreach (var directory in new[] { productRoot, brokerRoot, versionRoot })
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, directory);
            ProtectedBrokerAccess.ValidateDirectory(directory, allowUsersReadAndExecute: true);
        }
        ProtectedBrokerAccess.ValidateFile(canonicalPath, allowUsersReadAndExecute: true);
        ProtectedBrokerAccess.ValidateFile(receiptPath, allowUsersReadAndExecute: true);
        ValidateRegularSingleLinkFile(canonicalPath);

        var receiptJson = File.ReadAllText(receiptPath, Encoding.UTF8);
        ValidateReceiptShape(receiptJson);
        var receipt = JsonSerializer.Deserialize(
            receiptJson,
            BrokerJsonContext.Default.ProtectedBrokerIdentity) ??
            throw new InvalidDataException(
                "Protected broker installation receipt is empty.");
        var actual = ReadIdentity(canonicalPath, version);
        if (receipt.SchemaVersion != 1 ||
            !string.Equals(receipt.FileName, PrivilegedBrokerPaths.BrokerFileName, StringComparison.Ordinal) ||
            !string.Equals(receipt.Version, version, StringComparison.Ordinal) ||
            receipt.Length != actual.Length ||
            !string.Equals(receipt.Sha256, actual.Sha256, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Protected broker installation receipt does not match its image.");
        }
        return actual;
    }

    private static void ValidateReceiptShape(string json)
    {
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("Protected broker receipt root is invalid.");
        }
        var expected = new HashSet<string>(StringComparer.Ordinal)
        {
            "schemaVersion",
            "fileName",
            "version",
            "length",
            "sha256"
        };
        var observed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in document.RootElement.EnumerateObject())
        {
            if (!expected.Contains(property.Name) || !observed.Add(property.Name))
            {
                throw new InvalidDataException(
                    "Protected broker receipt has unknown or duplicate fields.");
            }
        }
        if (!observed.SetEquals(expected))
        {
            throw new InvalidDataException("Protected broker receipt fields are incomplete.");
        }
    }

    private static void EnsureBootstrapSource(string sourcePath)
    {
        var info = new FileInfo(sourcePath);
        if (!info.Exists ||
            (info.Attributes & FileAttributes.ReparsePoint) != 0 ||
            !string.Equals(
                info.Name,
                PrivilegedBrokerPaths.BrokerFileName,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Bootstrap broker is not a regular EverVigil.Broker.exe image.");
        }
    }

    internal static ProtectedBrokerIdentity ReadIdentity(string path, string version)
    {
        var info = new FileInfo(path);
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read);
        var hash = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        return new ProtectedBrokerIdentity(
            1,
            PrivilegedBrokerPaths.BrokerFileName,
            version,
            info.Length,
            hash);
    }

    private static void ValidateRegularSingleLinkFile(string path)
    {
        var expectedPath = Path.GetFullPath(path);
        using var stream = new FileStream(
            expectedPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read);
        var finalPath = GetFinalPath(stream.SafeFileHandle.DangerousGetHandle());
        if (!string.Equals(finalPath, expectedPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "Protected canonical broker final path is redirected.");
        }
        if (!GetFileInformationByHandle(
                stream.SafeFileHandle.DangerousGetHandle(),
                out var information))
        {
            throw new IOException(
                "Could not read protected canonical broker file identity.",
                Marshal.GetExceptionForHR(Marshal.GetHRForLastWin32Error()));
        }
        if (information.NumberOfLinks != 1)
        {
            throw new InvalidDataException(
                "Protected canonical broker must have exactly one hard link.");
        }
    }

    private static ProtectedBrokerIdentity ReadIdentity(FileStream stream, string version)
    {
        stream.Position = 0;
        var hash = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        stream.Position = 0;
        return new ProtectedBrokerIdentity(
            1,
            PrivilegedBrokerPaths.BrokerFileName,
            version,
            stream.Length,
            hash);
    }

    private static string GetFinalPath(IntPtr fileHandle)
    {
        var buffer = new StringBuilder(32768);
        var length = GetFinalPathNameByHandle(fileHandle, buffer, buffer.Capacity, 0);
        if (length == 0 || length >= buffer.Capacity)
        {
            throw new IOException(
                "Could not resolve loaded broker image final path.",
                Marshal.GetExceptionForHR(Marshal.GetHRForLastWin32Error()));
        }
        var path = buffer.ToString();
        const string extendedPrefix = @"\\?\";
        if (path.StartsWith(extendedPrefix, StringComparison.Ordinal))
        {
            path = path[extendedPrefix.Length..];
        }
        return Path.GetFullPath(path);
    }

    private static void WriteReceipt(
        string path,
        ProtectedBrokerIdentity identity,
        bool enforceProtectedAccess = true)
    {
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(
                identity,
                BrokerJsonContext.Default.ProtectedBrokerIdentity);
            using (var stream = new FileStream(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       4096,
                       FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.WriteByte((byte)'\n');
                stream.Flush(flushToDisk: true);
            }
            if (enforceProtectedAccess)
            {
                ProtectedBrokerAccess.ProtectBinaryFile(temporaryPath);
            }
            File.Move(temporaryPath, path, overwrite: false);
            if (enforceProtectedAccess)
            {
                ProtectedBrokerAccess.ProtectBinaryFile(path);
            }
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static void CleanupInstallationTemporaries(
        string commonData,
        string versionRoot,
        bool enforceProtectedAccess = true)
    {
        if (!Directory.Exists(versionRoot))
        {
            return;
        }
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, versionRoot);
            ProtectedBrokerAccess.ValidateDirectory(
                versionRoot,
                allowUsersReadAndExecute: true);
        }
        foreach (var entry in Directory.EnumerateFiles(versionRoot))
        {
            var name = Path.GetFileName(entry);
            if (!IsStrictTemporaryName(
                    name,
                    "." + PrivilegedBrokerPaths.BrokerFileName) &&
                !IsStrictTemporaryName(
                    name,
                    PrivilegedBrokerPaths.InstallationReceiptFileName))
            {
                continue;
            }
            if (enforceProtectedAccess)
            {
                ProtectedBrokerAccess.ValidateProtectedTemporaryFile(entry);
            }
            File.Delete(entry);
        }
    }

    private static bool IsStrictTemporaryName(string name, string stablePrefix)
    {
        var prefix = stablePrefix + ".";
        if (!name.StartsWith(prefix, StringComparison.Ordinal) ||
            !name.EndsWith(".tmp", StringComparison.Ordinal))
        {
            return false;
        }
        var identifier = name[prefix.Length..^4];
        return identifier.Length == 32 && identifier.All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f');
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(
        IntPtr file,
        StringBuilder filePath,
        int filePathLength,
        uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        IntPtr file,
        out ByHandleFileInformation fileInformation);

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
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
}

internal sealed record ProtectedBrokerIdentity(
    int SchemaVersion,
    string FileName,
    string Version,
    long Length,
    string Sha256);

internal sealed record ProtectedBrokerReadiness(
    ProtectedBrokerIdentity Identity,
    bool IsCanonicalInvocation,
    bool InstalledNow,
    bool RetirementPending = false);

internal sealed record LockedBrokerImage(
    string Path,
    FileStream Stream,
    ProtectedBrokerIdentity Identity,
    uint VolumeSerialNumber,
    ulong FileIndex) : IDisposable
{
    public void Dispose() => Stream.Dispose();
}
