using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using EverVigil.Broker.Protocol;
using EverVigil.Core;

namespace EverVigil.Infrastructure;

internal sealed class ProtectedTailscaleIdentityStore
{
    private const int MaximumLedgerBytes = 64 * 1024;
    private const int MaximumStatusCharacters = 1024 * 1024;
    private static readonly TimeSpan StatusCommandTimeout = TimeSpan.FromSeconds(5);

    private const FileSystemRights DangerousRights =
        FileSystemRights.WriteData |
        FileSystemRights.CreateFiles |
        FileSystemRights.AppendData |
        FileSystemRights.CreateDirectories |
        FileSystemRights.WriteExtendedAttributes |
        FileSystemRights.DeleteSubdirectoriesAndFiles |
        FileSystemRights.WriteAttributes |
        FileSystemRights.Delete |
        FileSystemRights.ChangePermissions |
        FileSystemRights.TakeOwnership;

    private static readonly SecurityIdentifier SystemSid = new(
        WellKnownSidType.LocalSystemSid,
        null);
    private static readonly SecurityIdentifier AdministratorsSid = new(
        WellKnownSidType.BuiltinAdministratorsSid,
        null);
    private static readonly SecurityIdentifier UsersSid = new(
        WellKnownSidType.BuiltinUsersSid,
        null);

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    private readonly string _commonData;
    private readonly SecurityIdentifier _ownerSid;
    private readonly string _ledgerPath;

    internal ProtectedTailscaleIdentityStore()
    {
        _commonData = Path.TrimEndingDirectorySeparator(Path.GetFullPath(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData)));
        _ownerSid = WindowsIdentity.GetCurrent().User ??
            throw new InvalidOperationException("The current Windows user SID is unavailable.");
        _ledgerPath = PrivilegedBrokerPaths.GetAppliedLedgerPath(
            _commonData,
            _ownerSid.Value);
    }

    internal bool TryLoad(AppSettings settings, out TrustedTailnetEndpoint endpoint)
    {
        try
        {
            endpoint = Load(settings);
            return true;
        }
        catch (Exception exception) when (exception is
            IOException or
            UnauthorizedAccessException or
            System.Security.SecurityException or
            JsonException or
            InvalidDataException or
            ArgumentException or
            SocketException or
            NetworkInformationException or
            TimeoutException)
        {
            endpoint = default!;
            return false;
        }
    }

    internal TrustedTailnetEndpoint Load(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ValidateProtectedPath();

        var info = new FileInfo(_ledgerPath);
        if (!info.Exists || info.Length is <= 0 or > MaximumLedgerBytes)
        {
            throw new InvalidDataException("The protected Tailscale identity ledger is unavailable.");
        }
        ValidateProtectedFile(info, _ownerSid);

        using var stream = new FileStream(
            _ledgerPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            4096,
            FileOptions.SequentialScan);
        if (stream.Length is <= 0 or > MaximumLedgerBytes)
        {
            throw new InvalidDataException("The protected Tailscale identity ledger size is invalid.");
        }
        using var reader = new StreamReader(
            stream,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true),
            detectEncodingFromByteOrderMarks: true,
            bufferSize: 4096,
            leaveOpen: false);
        var json = reader.ReadToEnd();
        var endpoint = ParseAndValidate(json, _ownerSid.Value, settings, DateTimeOffset.UtcNow);
        ValidateLiveIdentity(endpoint);
        // The protected broker validates and commits the Serve route before it
        // writes this ledger.  The medium-integrity UI must not query the
        // administrator-only tailscaled pipe and turn a valid ledger into a
        // false negative.
        return endpoint;
    }

    internal static bool IsCurrentServeRoute(
        string statusJson,
        int publicPort,
        int backendPort)
    {
        try
        {
            var snapshot = TailscaleServeStatus.ReadRootSnapshot(
                statusJson,
                publicPort,
                [backendPort]);
            return snapshot.State == ServeRootState.Owned && !snapshot.FunnelActive;
        }
        catch (Exception exception) when (exception is
            ArgumentException or
            InvalidDataException)
        {
            return false;
        }
    }

    internal static TrustedTailnetEndpoint ParseAndValidate(
        string json,
        string expectedOwnerSid,
        AppSettings settings,
        DateTimeOffset nowUtc)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(json);
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedOwnerSid);
        ArgumentNullException.ThrowIfNull(settings);

        var ledger = JsonSerializer.Deserialize<ProtectedAppliedLedger>(
            json,
            SerializerOptions) ?? throw new InvalidDataException(
                "The protected Tailscale identity ledger is empty.");
        if (ledger.SchemaVersion != PrivilegedBrokerProtocol.SchemaVersion ||
            !string.Equals(ledger.OwnerSid, expectedOwnerSid, StringComparison.Ordinal) ||
            ledger.CommittedAtUtc == default ||
            ledger.CommittedAtUtc > nowUtc.AddMinutes(5))
        {
            throw new InvalidDataException("The protected Tailscale identity ledger is invalid.");
        }

        var configuration = ledger.Configuration ??
            throw new InvalidDataException("The protected system configuration is missing.");
        if (configuration.PublicPort != settings.PublicPort ||
            configuration.BackendPort != settings.BackendPort ||
            !Path.IsPathFullyQualified(configuration.TailscalePath) ||
            !string.Equals(
                Path.GetFullPath(configuration.TailscalePath),
                Path.GetFullPath(settings.TailscalePath),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "The protected Tailscale identity does not match the active settings.");
        }

        var identity = ledger.TailscaleSelf ??
            throw new InvalidDataException("The protected Tailscale Self identity is missing.");
        var dnsName = NormalizeDnsName(identity.DnsName);
        if (identity.TailscaleIps is null ||
            identity.TailscaleIps.Count is < 1 or > 16)
        {
            throw new InvalidDataException("The protected Tailscale address set is invalid.");
        }

        var addresses = new List<IPAddress>(identity.TailscaleIps.Count);
        foreach (var source in identity.TailscaleIps)
        {
            if (!IPAddress.TryParse(source, out var address) || !IsTailscaleAddress(address))
            {
                throw new InvalidDataException("The protected Tailscale address set is invalid.");
            }
            addresses.Add(address);
        }
        if (addresses.Select(address => address.ToString())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count() != addresses.Count)
        {
            throw new InvalidDataException("The protected Tailscale address set contains duplicates.");
        }

        return new TrustedTailnetEndpoint(
            dnsName,
            configuration.PublicPort,
            addresses.Select(address => address.ToString()).ToArray(),
            ledger.CommittedAtUtc);
    }

    private void ValidateProtectedPath()
    {
        var brokerRoot = PrivilegedBrokerPaths.GetBrokerRoot(_commonData);
        var productRoot = Path.GetDirectoryName(brokerRoot) ??
            throw new InvalidDataException("The protected broker product root is unavailable.");
        var stateRoot = PrivilegedBrokerPaths.GetStateRoot(_commonData);
        var ownerRoot = PrivilegedBrokerPaths.GetOwnerStateRoot(
            _commonData,
            _ownerSid.Value);
        foreach (var directory in new[] { productRoot, brokerRoot, stateRoot, ownerRoot })
        {
            EnsureNoReparsePoint(directory);
            ValidateProtectedDirectory(new DirectoryInfo(directory), _ownerSid);
        }
        EnsureNoReparsePoint(_ledgerPath);
    }

    private static void EnsureNoReparsePoint(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException("A protected broker path is a reparse point.");
        }
    }

    private static void ValidateProtectedDirectory(
        DirectoryInfo info,
        SecurityIdentifier ownerSid)
    {
        if (!info.Exists)
        {
            throw new InvalidDataException("A protected broker directory is missing.");
        }
        ValidateProtectedSecurity(
            info.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner),
            ownerSid,
            requireOwnerRead: string.Equals(info.Name, ownerSid.Value, StringComparison.Ordinal));
    }

    private static void ValidateProtectedFile(
        FileInfo info,
        SecurityIdentifier ownerSid) =>
        ValidateProtectedSecurity(
            info.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner),
            ownerSid,
            requireOwnerRead: true);

    private static void ValidateProtectedSecurity(
        FileSystemSecurity security,
        SecurityIdentifier ownerSid,
        bool requireOwnerRead)
    {
        if (!security.AreAccessRulesProtected)
        {
            throw new InvalidDataException("Protected broker ACL inheritance is enabled.");
        }
        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null || !owner.Equals(SystemSid) && !owner.Equals(AdministratorsSid))
        {
            throw new InvalidDataException("Protected broker ownership is invalid.");
        }

        var systemFullControl = false;
        var administratorsFullControl = false;
        var ownerRead = false;
        foreach (FileSystemAccessRule rule in security.GetAccessRules(
                     includeExplicit: true,
                     includeInherited: true,
                     typeof(SecurityIdentifier)))
        {
            if (rule.IsInherited || rule.AccessControlType != AccessControlType.Allow)
            {
                throw new InvalidDataException("Protected broker ACL contains an inherited or deny ACE.");
            }
            var sid = (SecurityIdentifier)rule.IdentityReference;
            if (sid.Equals(SystemSid))
            {
                systemFullControl |= (rule.FileSystemRights & FileSystemRights.FullControl) ==
                    FileSystemRights.FullControl;
                continue;
            }
            if (sid.Equals(AdministratorsSid))
            {
                administratorsFullControl |=
                    (rule.FileSystemRights & FileSystemRights.FullControl) ==
                    FileSystemRights.FullControl;
                continue;
            }
            if (sid.Equals(ownerSid))
            {
                if ((rule.FileSystemRights & DangerousRights) != 0)
                {
                    throw new InvalidDataException("The current user can modify protected broker state.");
                }
                ownerRead = true;
                continue;
            }
            if (sid.Equals(UsersSid))
            {
                if ((rule.FileSystemRights & DangerousRights) != 0)
                {
                    throw new InvalidDataException("Standard users can modify protected broker state.");
                }
                continue;
            }
            throw new InvalidDataException("Protected broker ACL contains an unexpected principal.");
        }

        if (!systemFullControl || !administratorsFullControl || requireOwnerRead && !ownerRead)
        {
            throw new InvalidDataException("Protected broker ACL is incomplete.");
        }
    }

    private static string NormalizeDnsName(string source)
    {
        var dnsName = source?.Trim().TrimEnd('.') ?? string.Empty;
        if (dnsName.Length is < 1 or > 253 ||
            Uri.CheckHostName(dnsName) != UriHostNameType.Dns ||
            !dnsName.EndsWith(".ts.net", StringComparison.OrdinalIgnoreCase) ||
            dnsName.Any(character =>
                char.IsWhiteSpace(character) || character is '/' or '\\' or ':' or '?' or '#'))
        {
            throw new InvalidDataException("The protected Tailscale DNS name is invalid.");
        }
        return dnsName;
    }

    internal static bool IsTailscaleAddress(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes.Length switch
        {
            4 => bytes[0] == 100 && (bytes[1] & 0xC0) == 0x40,
            16 => bytes[0] == 0xFD &&
                bytes[1] == 0x7A &&
                bytes[2] == 0x11 &&
                bytes[3] == 0x5C &&
                bytes[4] == 0xA1 &&
                bytes[5] == 0xE0,
            _ => false
        };
    }

    internal static bool IsLiveIdentityMatch(
        TrustedTailnetEndpoint endpoint,
        IEnumerable<IPAddress> localAddresses,
        IEnumerable<IPAddress> resolvedAddresses)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        ArgumentNullException.ThrowIfNull(localAddresses);
        ArgumentNullException.ThrowIfNull(resolvedAddresses);

        var protectedAddresses = endpoint.TailscaleIps
            .Select(IPAddress.Parse)
            .Select(NormalizeAddress)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var local = localAddresses
            .Where(IsTailscaleAddress)
            .Select(NormalizeAddress)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var resolved = resolvedAddresses.ToArray();
        return resolved.Length > 0 && resolved.All(address =>
        {
            if (!IsTailscaleAddress(address))
            {
                return false;
            }

            var normalized = NormalizeAddress(address);
            return protectedAddresses.Contains(normalized) && local.Contains(normalized);
        });
    }

    private static void ValidateLiveIdentity(TrustedTailnetEndpoint endpoint)
    {
        var localAddresses = NetworkInterface.GetAllNetworkInterfaces()
            .Where(network => network.OperationalStatus == OperationalStatus.Up)
            .SelectMany(network => network.GetIPProperties().UnicastAddresses)
            .Select(address => address.Address)
            .ToArray();
        var resolvedAddresses = Dns.GetHostAddressesAsync(endpoint.DnsName)
            .WaitAsync(TimeSpan.FromSeconds(3))
            .GetAwaiter()
            .GetResult();
        if (!IsLiveIdentityMatch(endpoint, localAddresses, resolvedAddresses))
        {
            throw new InvalidDataException(
                "The protected Tailscale identity no longer matches this device and DNS.");
        }
    }

    private static void ValidateLiveServeRoute(AppSettings settings)
    {
        var statusJson = ReadLiveServeStatus(settings.TailscalePath);
        if (!IsCurrentServeRoute(statusJson, settings.PublicPort, settings.BackendPort))
        {
            throw new InvalidDataException(
                "The current Tailscale Serve root is missing, public, or does not match the protected backend.");
        }
    }

    private static string ReadLiveServeStatus(string tailscalePath)
    {
        if (string.IsNullOrWhiteSpace(tailscalePath) ||
            !Path.IsPathFullyQualified(tailscalePath))
        {
            throw new InvalidDataException("The protected Tailscale CLI path is invalid.");
        }

        var startInfo = CreateServeStatusStartInfo(tailscalePath);

        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                throw new IOException("The Tailscale Serve status process did not start.");
            }
        }
        catch (Win32Exception exception)
        {
            throw new IOException("The Tailscale Serve status process could not start.", exception);
        }

        using var cancellation = new CancellationTokenSource(StatusCommandTimeout);
        var outputTask = ReadBoundedAsync(
            process.StandardOutput,
            MaximumStatusCharacters,
            cancellation.Token);
        var errorTask = ReadBoundedAsync(
            process.StandardError,
            MaximumStatusCharacters,
            cancellation.Token);
        try
        {
            process.WaitForExitAsync(cancellation.Token).GetAwaiter().GetResult();
            Task.WhenAll(outputTask, errorTask).GetAwaiter().GetResult();
        }
        catch (OperationCanceledException exception)
        {
            TryTerminate(process);
            throw new TimeoutException("The Tailscale Serve status command timed out.", exception);
        }
        catch
        {
            TryTerminate(process);
            throw;
        }

        if (process.ExitCode != 0)
        {
            throw new InvalidDataException("The Tailscale Serve status command failed.");
        }
        var statusJson = outputTask.GetAwaiter().GetResult();
        if (string.IsNullOrWhiteSpace(statusJson))
        {
            throw new InvalidDataException("The Tailscale Serve status command returned no JSON.");
        }
        return statusJson;
    }

    internal static ProcessStartInfo CreateServeStatusStartInfo(string tailscalePath)
    {
        if (string.IsNullOrWhiteSpace(tailscalePath) ||
            !Path.IsPathFullyQualified(tailscalePath))
        {
            throw new InvalidDataException("The protected Tailscale CLI path is invalid.");
        }

        var fullPath = Path.GetFullPath(tailscalePath);
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (string.IsNullOrWhiteSpace(windows) || !Path.IsPathFullyQualified(windows))
        {
            throw new InvalidDataException("The Windows directory is unavailable.");
        }
        var startInfo = new ProcessStartInfo
        {
            FileName = fullPath,
            WorkingDirectory = Path.GetDirectoryName(fullPath) ??
                throw new InvalidDataException("The protected Tailscale CLI directory is invalid."),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        startInfo.ArgumentList.Add("serve");
        startInfo.ArgumentList.Add("status");
        startInfo.ArgumentList.Add("--json");
        startInfo.Environment.Clear();
        startInfo.Environment["SystemRoot"] = windows;
        startInfo.Environment["WINDIR"] = windows;
        startInfo.Environment["TEMP"] = Path.Combine(windows, "Temp");
        startInfo.Environment["TMP"] = Path.Combine(windows, "Temp");
        return startInfo;
    }

    private static async Task<string> ReadBoundedAsync(
        StreamReader reader,
        int maximumCharacters,
        CancellationToken cancellationToken)
    {
        var buffer = new char[4096];
        var result = new StringBuilder();
        while (true)
        {
            var count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken)
                .ConfigureAwait(false);
            if (count == 0)
            {
                return result.ToString();
            }
            if (result.Length > maximumCharacters - count)
            {
                throw new InvalidDataException("Tailscale Serve status output exceeded the safe limit.");
            }
            result.Append(buffer, 0, count);
        }
    }

    private static void TryTerminate(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit();
            }
        }
        catch (Exception exception) when (exception is
            InvalidOperationException or
            Win32Exception)
        {
            // Best effort only. The original validation failure remains authoritative.
        }
    }

    private static string NormalizeAddress(IPAddress address) =>
        new IPAddress(address.GetAddressBytes()).ToString();

    private sealed record ProtectedAppliedLedger(
        int SchemaVersion,
        string OwnerSid,
        ProtectedSystemConfiguration Configuration,
        ProtectedTailscaleSelf TailscaleSelf,
        DateTimeOffset CommittedAtUtc);

    private sealed record ProtectedSystemConfiguration(
        int PublicPort,
        int BackendPort,
        string TailscalePath);

    private sealed record ProtectedTailscaleSelf(
        string DnsName,
        IReadOnlyList<string> TailscaleIps);
}

internal sealed record TrustedTailnetEndpoint(
    string DnsName,
    int PublicPort,
    IReadOnlyList<string> TailscaleIps,
    DateTimeOffset VerifiedAtUtc);
