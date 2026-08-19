using System.Diagnostics;
using System.Text.Json;
using EverVigil.Compatibility;
using Microsoft.Win32;

namespace EverVigil.Broker;

internal static class LegacyV121Evidence
{
    internal static BrokerSystemConfiguration RequireConfiguration(
        string ownerSid,
        Guid transactionId,
        string trustedTailscalePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerSid);
        if (transactionId == Guid.Empty)
        {
            throw new ArgumentException("Legacy migration transaction ID is empty.", nameof(transactionId));
        }
        var ownerPaths = ResolveOwnerPaths(ownerSid);
        var profile = ownerPaths.ProfilePath;
        var localAppData = ownerPaths.LocalAppDataPath;
        RequireOwnedLegacyInstallation(profile, localAppData, ownerSid, transactionId);
        var configurations = new[]
            {
                Path.Combine(
                    localAppData,
                    LegacyCompatibility.Application.DataRootRelativeToLocalAppData,
                    LegacyCompatibility.Data.AppliedSystemConfigurationFileName),
                Path.Combine(
                    localAppData,
                    "EverVigil",
                    LegacyCompatibility.Data.AppliedSystemConfigurationFileName)
            }
            .Where(File.Exists)
            .Select(path => ReadApplied(path, trustedTailscalePath))
            .Distinct()
            .ToArray();
        if (configurations.Length != 1)
        {
            throw new BrokerRefusalException(
                "v1.2.1 migration requires one unambiguous owned applied-system record.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
        return configurations[0];
    }

    internal static (string ProfilePath, string LocalAppDataPath) ResolveOwnerPaths(
        string ownerSid)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerSid);
        var profile = ResolveProfilePath(ownerSid);
        return (profile, ResolveLocalAppData(ownerSid, profile));
    }

    private static void RequireOwnedLegacyInstallation(
        string profile,
        string localAppData,
        string ownerSid,
        Guid transactionId)
    {
        var transaction = transactionId.ToString("N");
        var candidates = BuildInstallCandidatePaths(
                localAppData,
                TryReadRegisteredInstallRoot(ownerSid),
                transaction)
            .Where(Directory.Exists)
            .Where(path => File.Exists(Path.Combine(
                path,
                LegacyCompatibility.Application.OwnershipMarkerFileName)))
            .Where(path => File.Exists(Path.Combine(
                path,
                LegacyCompatibility.Application.ExecutableFileName)))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var valid = new List<string>();
        foreach (var candidate in candidates)
        {
            try
            {
                ValidateNoReparseOnFixedDrive(candidate);
                var expectedInstallRoot = StripTransactionSuffix(candidate, transaction);
                ReadAndValidateMarker(
                    Path.Combine(
                        candidate,
                        LegacyCompatibility.Application.OwnershipMarkerFileName),
                    expectedInstallRoot,
                    ownerSid);
                RequireLegacyVersionInfo(Path.Combine(
                    candidate,
                    LegacyCompatibility.Application.ExecutableFileName));
                valid.Add(candidate);
            }
            catch (Exception exception) when (
                exception is InvalidDataException or IOException or UnauthorizedAccessException)
            {
                // A candidate with malformed ownership evidence is never adopted.
            }
        }
        if (valid.Count != 1)
        {
            throw new BrokerRefusalException(
                "v1.2.1 migration ownership marker and executable identity are not unambiguous.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
    }

    private static void ReadAndValidateMarker(
        string path,
        string expectedInstallRoot,
        string ownerSid)
    {
        var bytes = ReadBounded(path, 64 * 1024);
        using var document = ParseObjectExact(
            bytes,
            ["schemaVersion", "appId", "ownerSid", "installRoot"],
            "legacy ownership marker");
        var root = document.RootElement;
        if (!root.TryGetProperty("schemaVersion", out var schema) ||
            !schema.TryGetInt32(out var schemaVersion) || schemaVersion != 1 ||
            !TryGetExactString(root, "appId", out var appId) ||
            !string.Equals(
                appId,
                LegacyCompatibility.Application.AppId,
                StringComparison.OrdinalIgnoreCase) ||
            !TryGetExactString(root, "ownerSid", out var markerOwnerSid) ||
            !string.Equals(markerOwnerSid, ownerSid, StringComparison.Ordinal) ||
            !TryGetExactString(root, "installRoot", out var installRoot) ||
            !Path.IsPathFullyQualified(installRoot) ||
            !string.Equals(
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(installRoot)),
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(expectedInstallRoot)),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Legacy ownership marker identity is invalid.");
        }
    }

    private static BrokerSystemConfiguration ReadApplied(
        string path,
        string trustedTailscalePath)
    {
        ValidateNoReparseOnFixedDrive(path);
        var bytes = ReadBounded(path, 64 * 1024);
        using var document = ParseObjectExact(
            bytes,
            ["publicPort", "backendPort", "tailscalePath"],
            "legacy applied-system record");
        var root = document.RootElement;
        if (!root.TryGetProperty("publicPort", out var publicPortElement) ||
            !publicPortElement.TryGetInt32(out var publicPort) ||
            !root.TryGetProperty("backendPort", out var backendPortElement) ||
            !backendPortElement.TryGetInt32(out var backendPort) ||
            !TryGetExactString(root, "tailscalePath", out var oldTailscalePath) ||
            publicPort is < 1024 or > 65535 ||
            backendPort is < 1024 or > 65535 ||
            publicPort == backendPort ||
            !Path.IsPathFullyQualified(oldTailscalePath) ||
            !string.Equals(
                Path.GetFullPath(oldTailscalePath),
                trustedTailscalePath,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Legacy applied-system record is invalid.");
        }
        return new BrokerSystemConfiguration(publicPort, backendPort, trustedTailscalePath);
    }

    internal static BrokerSystemConfiguration ReadAppliedForTests(
        string profile,
        string path,
        string trustedTailscalePath)
    {
        _ = profile;
        return ReadApplied(path, trustedTailscalePath);
    }

    internal static string ExpandOwnerDataPathForTests(
        string raw,
        string profile,
        string systemDrive) =>
        ExpandOwnerPath(raw, profile, systemDrive, "test owner data path");

    internal static IReadOnlyList<string> BuildInstallCandidatePathsForTests(
        string localAppData,
        string? registeredInstallRoot,
        Guid transactionId) =>
        BuildInstallCandidatePaths(
            localAppData,
            registeredInstallRoot,
            transactionId.ToString("N"));

    private static IReadOnlyList<string> BuildInstallCandidatePaths(
        string localAppData,
        string? registeredInstallRoot,
        string transaction)
    {
        var bases = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            Path.GetFullPath(Path.Combine(
                localAppData,
                LegacyCompatibility.Application.InstallRootRelativeToLocalAppData)),
            Path.GetFullPath(Path.Combine(localAppData, "Programs", "EverVigil"))
        };
        if (!string.IsNullOrWhiteSpace(registeredInstallRoot))
        {
            bases.Add(Path.GetFullPath(registeredInstallRoot));
        }
        return bases.SelectMany(path => new[]
            {
                path,
                $"{path}.backup-{transaction}",
                $"{path}.relocated-{transaction}"
            })
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static void RequireLegacyVersionInfo(string path)
    {
        var version = FileVersionInfo.GetVersionInfo(path);
        if (!string.Equals(
                version.ProductName,
                LegacyCompatibility.Application.ProductName,
                StringComparison.Ordinal) ||
            !string.Equals(
                version.OriginalFilename,
                LegacyCompatibility.Application.ExecutableOriginalFileName,
                StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(
                version.FileVersion,
                LegacyCompatibility.Application.ExecutableFileVersion,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException("Legacy executable VersionInfo is not v1.2.1.");
        }
    }

    private static JsonDocument ParseObjectExact(
        byte[] bytes,
        IReadOnlyCollection<string> expectedProperties,
        string description)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(bytes);
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException($"The {description} JSON is invalid.", exception);
        }
        var properties = document.RootElement.ValueKind == JsonValueKind.Object
            ? document.RootElement.EnumerateObject().ToArray()
            : [];
        if (properties.Length != expectedProperties.Count ||
            properties.Select(property => property.Name)
                .Distinct(StringComparer.Ordinal).Count() != expectedProperties.Count ||
            !properties.Select(property => property.Name)
                .OrderBy(value => value, StringComparer.Ordinal)
                .SequenceEqual(expectedProperties.OrderBy(value => value, StringComparer.Ordinal)))
        {
            document.Dispose();
            throw new InvalidDataException($"The {description} schema is not exact.");
        }
        return document;
    }

    private static bool TryGetExactString(
        JsonElement root,
        string propertyName,
        out string value)
    {
        value = string.Empty;
        if (!root.TryGetProperty(propertyName, out var property) ||
            property.ValueKind != JsonValueKind.String)
        {
            return false;
        }
        value = property.GetString() ?? string.Empty;
        return value.Length > 0;
    }

    private static byte[] ReadBounded(string path, int maximumBytes)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length is <= 0 || info.Length > maximumBytes ||
            (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException("Legacy evidence file is missing, redirected, or oversized.");
        }
        return File.ReadAllBytes(path);
    }

    private static void ValidateNoReparseOnFixedDrive(string target)
    {
        var fullPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(target));
        var root = Path.GetPathRoot(fullPath);
        if (string.IsNullOrWhiteSpace(root) ||
            !string.Equals(
                Path.TrimEndingDirectorySeparator(root),
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Legacy installation drive root is invalid.");
        }
        var drive = new DriveInfo(root);
        if (drive.DriveType != DriveType.Fixed ||
            string.Equals(
                fullPath,
                Path.TrimEndingDirectorySeparator(root),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "Legacy installation is not below a fixed local drive root.");
        }

        var current = fullPath;
        while (current.Length >= root.Length)
        {
            if ((File.Exists(current) || Directory.Exists(current)) &&
                (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidDataException(
                    "Legacy installation contains a reparse point.");
            }
            if (string.Equals(
                    Path.TrimEndingDirectorySeparator(current),
                    Path.TrimEndingDirectorySeparator(root),
                    StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
            current = Path.GetDirectoryName(current) ??
                throw new InvalidDataException(
                    "Legacy installation ancestry is invalid.");
        }
    }

    private static string? TryReadRegisteredInstallRoot(string ownerSid)
    {
        using var key = Registry.Users.OpenSubKey(
            $@"{ownerSid}\{LegacyCompatibility.Application.UninstallRegistrySubKey}",
            writable: false);
        if (key is null)
        {
            return null;
        }
        if (!key.GetValueNames().Contains("InstallLocation", StringComparer.Ordinal) ||
            key.GetValueKind("InstallLocation") != RegistryValueKind.String)
        {
            throw new InvalidDataException(
                "Legacy uninstall registration InstallLocation type is invalid.");
        }
        var raw = key.GetValue(
            "InstallLocation",
            null,
            RegistryValueOptions.DoNotExpandEnvironmentNames) as string ?? string.Empty;
        if (string.IsNullOrWhiteSpace(raw) ||
            raw.Contains('%', StringComparison.Ordinal) ||
            !Path.IsPathFullyQualified(raw))
        {
            throw new InvalidDataException(
                "Legacy uninstall registration InstallLocation is invalid.");
        }
        var fullPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(raw));
        ValidateNoReparseOnFixedDrive(fullPath);
        return fullPath;
    }

    private static string StripTransactionSuffix(string candidate, string transaction)
    {
        foreach (var suffix in new[] { $".backup-{transaction}", $".relocated-{transaction}" })
        {
            if (candidate.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            {
                return candidate[..^suffix.Length];
            }
        }
        return candidate;
    }

    private static string ResolveProfilePath(string ownerSid)
    {
        using var key = Registry.LocalMachine.OpenSubKey(
            $@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{ownerSid}");
        var raw = key?.GetValue(
            "ProfileImagePath",
            null,
            RegistryValueOptions.DoNotExpandEnvironmentNames) as string ?? string.Empty;
        var systemDrive = Path.GetPathRoot(Environment.GetFolderPath(
            Environment.SpecialFolder.Windows))?.TrimEnd(Path.DirectorySeparatorChar) ??
            throw new InvalidDataException("Windows system drive is unavailable.");
        var profile = ExpandOwnerPath(
            raw,
            systemDrive + Path.DirectorySeparatorChar,
            systemDrive,
            "authenticated owner profile");
        if (!Directory.Exists(profile))
        {
            throw new InvalidDataException("Authenticated owner profile does not exist.");
        }
        ValidateNoReparseOnFixedDrive(profile);
        return profile;
    }

    private static string ResolveLocalAppData(string ownerSid, string profile)
    {
        string? configured = null;
        using (var key = Registry.Users.OpenSubKey(
                   $@"{ownerSid}\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
                   writable: false))
        {
            if (key?.GetValueNames().Contains("Local AppData", StringComparer.Ordinal) == true)
            {
                var kind = key.GetValueKind("Local AppData");
                if (kind is not (RegistryValueKind.String or RegistryValueKind.ExpandString))
                {
                    throw new InvalidDataException(
                        "Authenticated owner Local AppData registry type is invalid.");
                }
                configured = key.GetValue(
                    "Local AppData",
                    null,
                    RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                if (string.IsNullOrWhiteSpace(configured))
                {
                    throw new InvalidDataException(
                        "Authenticated owner Local AppData registry value is empty.");
                }
            }
        }

        var systemDrive = Path.GetPathRoot(Environment.GetFolderPath(
            Environment.SpecialFolder.Windows))?.TrimEnd(Path.DirectorySeparatorChar) ??
            throw new InvalidDataException("Windows system drive is unavailable.");
        var localAppData = ExpandOwnerPath(
            configured ?? Path.Combine(profile, "AppData", "Local"),
            profile,
            systemDrive,
            "authenticated owner Local AppData");
        if (!Directory.Exists(localAppData))
        {
            throw new InvalidDataException("Authenticated owner Local AppData does not exist.");
        }
        ValidateNoReparseOnFixedDrive(localAppData);
        return localAppData;
    }

    private static string ExpandOwnerPath(
        string raw,
        string profile,
        string systemDrive,
        string description)
    {
        if (string.IsNullOrWhiteSpace(raw) ||
            string.IsNullOrWhiteSpace(profile) ||
            string.IsNullOrWhiteSpace(systemDrive))
        {
            throw new InvalidDataException($"The {description} is unavailable.");
        }
        var canonicalProfile = Path.TrimEndingDirectorySeparator(Path.GetFullPath(profile));
        var profileRoot = Path.GetPathRoot(canonicalProfile)?.TrimEnd(Path.DirectorySeparatorChar) ??
            throw new InvalidDataException($"The {description} profile root is unavailable.");
        var homePath = canonicalProfile[profileRoot.Length..];
        var userName = Path.GetFileName(canonicalProfile);
        var expanded = raw
            .Replace("%SystemDrive%", systemDrive, StringComparison.OrdinalIgnoreCase)
            .Replace("%USERPROFILE%", canonicalProfile, StringComparison.OrdinalIgnoreCase)
            .Replace("%HOMEDRIVE%", profileRoot, StringComparison.OrdinalIgnoreCase)
            .Replace("%HOMEPATH%", homePath, StringComparison.OrdinalIgnoreCase)
            .Replace("%USERNAME%", userName, StringComparison.OrdinalIgnoreCase);
        if (expanded.Contains('%', StringComparison.Ordinal) ||
            !Path.IsPathFullyQualified(expanded))
        {
            throw new InvalidDataException($"The {description} could not be expanded safely.");
        }
        var result = Path.TrimEndingDirectorySeparator(Path.GetFullPath(expanded));
        var resultRoot = Path.GetPathRoot(result);
        if (string.IsNullOrWhiteSpace(resultRoot) ||
            new DriveInfo(resultRoot).DriveType != DriveType.Fixed ||
            string.Equals(
                result,
                Path.TrimEndingDirectorySeparator(resultRoot),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"The {description} is not below a fixed local drive.");
        }
        return result;
    }
}
