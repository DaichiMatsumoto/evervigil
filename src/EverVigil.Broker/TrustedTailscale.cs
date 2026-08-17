using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using EverVigil.Broker.Protocol;

namespace EverVigil.Broker;

internal sealed class TrustedTailscale
{
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(60);
    private const int MaximumOutputCharacters = 4 * 1024 * 1024;
    private const int GenericAllAccessMask = 0x10000000;
    private const int GenericWriteAccessMask = 0x40000000;
    private static readonly SecurityIdentifier TrustedInstallerSid =
        (SecurityIdentifier)new NTAccount(@"NT SERVICE\TrustedInstaller")
            .Translate(typeof(SecurityIdentifier));
    private readonly string _path;

    private TrustedTailscale(string path)
    {
        _path = path;
    }

    internal string Path => _path;

    internal static TrustedTailscale Resolve(string authenticatedOwnerSid)
    {
        var programFiles = System.IO.Path.GetFullPath(Environment.GetFolderPath(
            Environment.SpecialFolder.ProgramFiles));
        var candidate = System.IO.Path.GetFullPath(System.IO.Path.Combine(
            programFiles,
            "Tailscale",
            "tailscale.exe"));
        if (!File.Exists(candidate))
        {
            throw new BrokerRefusalException(
                "Tailscale CLI was not found in its fixed Program Files location.",
                Protocol.PrivilegedBrokerErrorCode.ExternalCommandFailed);
        }
        ProtectedBrokerAccess.ValidateNoReparsePoints(programFiles, candidate);
        ValidateProtectedProgramFilesPath(programFiles, candidate, authenticatedOwnerSid);
        RequireTrustedAuthenticodeSignature(candidate);
        return new TrustedTailscale(candidate);
    }

    internal string ReadServeStatus() =>
        Run("serve", "status", "--json");

    internal TailscaleSelfIdentity ReadSelfIdentity()
    {
        var json = Run("status", "--json");
        try
        {
            using var document = JsonDocument.Parse(json);
            if (!document.RootElement.TryGetProperty("Self", out var self) ||
                self.ValueKind != JsonValueKind.Object ||
                !self.TryGetProperty("DNSName", out var dnsNameElement) ||
                dnsNameElement.ValueKind != JsonValueKind.String ||
                !self.TryGetProperty("TailscaleIPs", out var ipsElement) ||
                ipsElement.ValueKind != JsonValueKind.Array)
            {
                throw new InvalidDataException("Tailscale status has no exact Self identity.");
            }
            var dnsName = (dnsNameElement.GetString() ?? string.Empty)
                .Trim()
                .TrimEnd('.')
                .ToLowerInvariant();
            if (!TailscaleIdentityValidator.IsValidDnsName(dnsName))
            {
                throw new InvalidDataException("Tailscale Self DNSName is invalid.");
            }
            var ips = new List<string>();
            foreach (var entry in ipsElement.EnumerateArray())
            {
                if (entry.ValueKind != JsonValueKind.String ||
                    !IPAddress.TryParse(entry.GetString(), out var ipAddress) ||
                    !TailscaleIdentityValidator.IsTailnetAddress(ipAddress.ToString()))
                {
                    throw new InvalidDataException("Tailscale Self IP address is invalid.");
                }
                ips.Add(ipAddress.ToString());
            }
            if (ips.Count == 0)
            {
                throw new InvalidDataException("Tailscale Self identity has no Tailnet IP address.");
            }
            return new TailscaleSelfIdentity(
                dnsName,
                ips.Distinct(StringComparer.Ordinal)
                    .OrderBy(value => value, StringComparer.Ordinal)
                    .ToArray());
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException("Tailscale status JSON is invalid.", exception);
        }
    }

    internal void ApplyRoot(
        int publicPort,
        int backendPort,
        ServeRootState expectedState,
        int? expectedOwnedBackendPort,
        string unrelatedHandlersJson)
    {
        ValidatePortPair(publicPort, backendPort);
        if (expectedState == ServeRootState.Unowned ||
            expectedState == ServeRootState.Owned != expectedOwnedBackendPort.HasValue)
        {
            throw new InvalidDataException("Tailscale Serve expected prestate is invalid.");
        }
        var before = TailscaleServeStatus.ReadRootSnapshot(
            ReadServeStatus(),
            publicPort,
            expectedOwnedBackendPort is int expectedPort ? [expectedPort] : []);
        if (before.FunnelActive ||
            before.State != expectedState ||
            !string.Equals(
                before.UnrelatedHandlersJson,
                unrelatedHandlersJson,
                StringComparison.Ordinal))
        {
            throw new BrokerRefusalException(
                "Tailscale Serve root changed after durable preflight.",
                before.FunnelActive
                    ? Protocol.PrivilegedBrokerErrorCode.FunnelDetected
                    : Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
        Run(
            "serve",
            "--yes",
            "--bg",
            "--http",
            publicPort.ToString(CultureInfo.InvariantCulture),
            "--set-path",
            "/",
            $"http://127.0.0.1:{backendPort}");
        var snapshot = TailscaleServeStatus.ReadRootSnapshot(
            ReadServeStatus(),
            publicPort,
            [backendPort]);
        if (snapshot.FunnelActive ||
            snapshot.State != ServeRootState.Owned ||
            !string.Equals(
                snapshot.UnrelatedHandlersJson,
                unrelatedHandlersJson,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Tailscale Serve root was not applied without altering unrelated handlers.");
        }
    }

    internal void RestoreOwnedRoot(
        int publicPort,
        int desiredBackendPort,
        ServeRootState expectedMutationState,
        int? expectedMutationBackendPort,
        string unrelatedHandlersJson)
    {
        ValidatePortPair(publicPort, desiredBackendPort);
        var statusJson = ReadServeStatus();
        var decision = ClassifyRootRestore(
            statusJson,
            publicPort,
            desiredBackendPort,
            expectedMutationState,
            expectedMutationBackendPort,
            unrelatedHandlersJson);
        if (decision == ServeRootRestoreDecision.AlreadyRestored)
        {
            return;
        }

        ApplyRoot(
            publicPort,
            desiredBackendPort,
            expectedMutationState,
            expectedMutationBackendPort,
            unrelatedHandlersJson);
    }

    internal static ServeRootRestoreDecision ClassifyRootRestore(
        string statusJson,
        int publicPort,
        int desiredBackendPort,
        ServeRootState expectedMutationState,
        int? expectedMutationBackendPort,
        string unrelatedHandlersJson)
    {
        ValidatePortPair(publicPort, desiredBackendPort);
        if (expectedMutationState == ServeRootState.Unowned ||
            expectedMutationState == ServeRootState.Owned !=
                expectedMutationBackendPort.HasValue)
        {
            throw new InvalidDataException(
                "Tailscale Serve rollback prestate is invalid.");
        }

        var desired = TailscaleServeStatus.ReadRootSnapshot(
            statusJson,
            publicPort,
            [desiredBackendPort]);
        ValidateRestoreSnapshot(desired, unrelatedHandlersJson);
        if (desired.State == ServeRootState.Owned)
        {
            return ServeRootRestoreDecision.AlreadyRestored;
        }

        var expected = expectedMutationState == ServeRootState.RootAbsent
            ? desired
            : TailscaleServeStatus.ReadRootSnapshot(
                statusJson,
                publicPort,
                [expectedMutationBackendPort!.Value]);
        ValidateRestoreSnapshot(expected, unrelatedHandlersJson);
        if (expected.State != expectedMutationState)
        {
            throw new BrokerRefusalException(
                "Tailscale Serve root is neither the durable mutation prestate nor the exact rollback target.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
        return ServeRootRestoreDecision.RestoreFromExpectedMutationState;
    }

    private static void ValidateRestoreSnapshot(
        ServeRootSnapshot snapshot,
        string unrelatedHandlersJson)
    {
        if (snapshot.FunnelActive)
        {
            throw new BrokerRefusalException(
                "Tailscale Funnel was detected; rollback was refused.",
                Protocol.PrivilegedBrokerErrorCode.FunnelDetected,
                pendingRecovery: true);
        }
        if (!string.Equals(
                snapshot.UnrelatedHandlersJson,
                unrelatedHandlersJson,
                StringComparison.Ordinal))
        {
            throw new BrokerRefusalException(
                "Unrelated Tailscale Serve handlers changed after durable preflight.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
    }

    internal void RemoveOwnedRoot(
        int publicPort,
        int backendPort,
        string unrelatedHandlersJson)
    {
        ValidatePortPair(publicPort, backendPort);
        var before = TailscaleServeStatus.ReadRootSnapshot(
            ReadServeStatus(),
            publicPort,
            [backendPort]);
        if (before.FunnelActive)
        {
            throw new BrokerRefusalException(
                "Tailscale Funnel was detected; root removal was refused.",
                Protocol.PrivilegedBrokerErrorCode.FunnelDetected);
        }
        if (before.State == ServeRootState.RootAbsent)
        {
            if (!string.Equals(
                    before.UnrelatedHandlersJson,
                    unrelatedHandlersJson,
                    StringComparison.Ordinal))
            {
                throw new BrokerRefusalException(
                    "Unrelated Tailscale Serve handlers changed after durable preflight.",
                    Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
            }
            return;
        }
        if (before.State != ServeRootState.Owned ||
            !string.Equals(
                before.UnrelatedHandlersJson,
                unrelatedHandlersJson,
                StringComparison.Ordinal))
        {
            throw new BrokerRefusalException(
                "Tailscale Serve root does not match protected ownership evidence.",
                Protocol.PrivilegedBrokerErrorCode.OwnershipMismatch);
        }

        Run(
            "serve",
            "--yes",
            "--http",
            publicPort.ToString(CultureInfo.InvariantCulture),
            "--set-path",
            "/",
            "off");
        var after = TailscaleServeStatus.ReadRootSnapshot(
            ReadServeStatus(),
            publicPort,
            [backendPort]);
        if (after.FunnelActive ||
            after.State != ServeRootState.RootAbsent ||
            !string.Equals(
                after.UnrelatedHandlersJson,
                unrelatedHandlersJson,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Tailscale Serve root removal did not preserve unrelated handlers.");
        }
    }

    private string Run(params string[] arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = _path,
            WorkingDirectory = System.IO.Path.GetDirectoryName(_path) ??
                throw new InvalidDataException("Tailscale directory is unavailable."),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }
        startInfo.Environment.Clear();
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        startInfo.Environment["SystemRoot"] = windows;
        startInfo.Environment["WINDIR"] = windows;
        startInfo.Environment["TEMP"] = System.IO.Path.Combine(windows, "Temp");
        startInfo.Environment["TMP"] = System.IO.Path.Combine(windows, "Temp");

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException("Trusted Tailscale CLI did not start.");
        }
        var standardOutput = process.StandardOutput.ReadToEndAsync();
        var standardError = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit((int)CommandTimeout.TotalMilliseconds))
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit();
            throw new TimeoutException("Trusted Tailscale CLI timed out.");
        }
        Task.WaitAll(standardOutput, standardError);
        var output = standardOutput.Result;
        var error = standardError.Result;
        if (output.Length > MaximumOutputCharacters || error.Length > MaximumOutputCharacters)
        {
            throw new InvalidDataException("Trusted Tailscale CLI output was too large.");
        }
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"Trusted Tailscale CLI failed with exit code {process.ExitCode}.");
        }
        return output;
    }

    private static void ValidatePortPair(int publicPort, int backendPort)
    {
        if (publicPort is < 1024 or > 65535 ||
            backendPort is < 1024 or > 65535 ||
            publicPort == backendPort)
        {
            throw new ArgumentOutOfRangeException(nameof(publicPort));
        }
    }

    private static void ValidateProtectedProgramFilesPath(
        string programFiles,
        string executable,
        string authenticatedOwnerSid)
    {
        SecurityIdentifier ownerSid;
        try
        {
            ownerSid = new SecurityIdentifier(authenticatedOwnerSid);
        }
        catch (ArgumentException exception)
        {
            throw new InvalidDataException("Authenticated owner SID is invalid.", exception);
        }
        var current = executable;
        while (current.Length >= programFiles.Length)
        {
            FileSystemSecurity security = File.Exists(current)
                ? new FileInfo(current).GetAccessControl(
                    AccessControlSections.Access | AccessControlSections.Owner)
                : new DirectoryInfo(current).GetAccessControl(
                    AccessControlSections.Access | AccessControlSections.Owner);
            var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
            if (owner is null || !IsPrivilegedWriter(owner))
            {
                throw new InvalidDataException(
                    "Fixed Tailscale path owner is not an allowed privileged principal.");
            }
            foreach (FileSystemAccessRule rule in security.GetAccessRules(
                         includeExplicit: true,
                         includeInherited: true,
                         typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType != AccessControlType.Allow ||
                    (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0 ||
                    !HasDangerousRights(rule.FileSystemRights))
                {
                    continue;
                }
                var sid = (SecurityIdentifier)rule.IdentityReference;
                if (!IsPrivilegedWriter(sid))
                {
                    throw new InvalidDataException(
                        $"A non-privileged principal can modify the fixed Tailscale path: {sid.Value}");
                }
            }
            if (string.Equals(current, programFiles, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
            current = System.IO.Path.GetDirectoryName(current) ??
                throw new InvalidDataException("Tailscale path ancestry is invalid.");
        }
    }

    private static bool HasDangerousRights(FileSystemRights rights)
    {
        var accessMask = unchecked((int)rights);
        return (rights & GetDangerousRights()) != 0 ||
            (accessMask & GenericAllAccessMask) != 0 ||
            (accessMask & GenericWriteAccessMask) != 0;
    }

    private static FileSystemRights GetDangerousRights() =>
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

    private static bool IsPrivilegedWriter(SecurityIdentifier sid) =>
        sid.IsWellKnown(WellKnownSidType.LocalSystemSid) ||
        sid.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid) ||
        sid.Equals(TrustedInstallerSid);

    private static void RequireTrustedAuthenticodeSignature(string path)
    {
        try
        {
            using var certificate = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
            if (!string.Equals(
                    certificate.GetNameInfo(X509NameType.SimpleName, forIssuer: false),
                    "Tailscale Inc.",
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException("Tailscale Authenticode publisher is unexpected.");
            }
            RequireWinVerifyTrust(path);
        }
        catch (Exception exception) when (exception is CryptographicException or InvalidDataException)
        {
            throw new InvalidDataException(
                "Tailscale executable has no usable Authenticode signature.",
                exception);
        }
    }

    private static void RequireWinVerifyTrust(string path)
    {
        var filePathPointer = Marshal.StringToCoTaskMemUni(path);
        var fileInfoPointer = IntPtr.Zero;
        try
        {
            var fileInfo = new WinTrustFileInfo
            {
                StructureSize = (uint)Marshal.SizeOf<WinTrustFileInfo>(),
                FilePath = filePathPointer
            };
            fileInfoPointer = Marshal.AllocHGlobal(Marshal.SizeOf<WinTrustFileInfo>());
            Marshal.StructureToPtr(fileInfo, fileInfoPointer, fDeleteOld: false);
            var trustData = new WinTrustData
            {
                StructureSize = (uint)Marshal.SizeOf<WinTrustData>(),
                UiChoice = 2,
                RevocationChecks = 0,
                UnionChoice = 1,
                FileInfo = fileInfoPointer,
                StateAction = 0,
                ProviderFlags = 0x00000010 | 0x00001000,
                UiContext = 0
            };
            var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
            var result = WinVerifyTrust(IntPtr.Zero, action, ref trustData);
            if (result != 0)
            {
                throw new InvalidDataException(
                    $"Windows Authenticode trust validation failed (0x{result:x8}).");
            }
        }
        finally
        {
            if (fileInfoPointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(fileInfoPointer);
            }
            Marshal.FreeCoTaskMem(filePathPointer);
        }
    }

    [DllImport("wintrust.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int WinVerifyTrust(
        IntPtr windowHandle,
        [MarshalAs(UnmanagedType.LPStruct)] Guid actionId,
        ref WinTrustData trustData);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustFileInfo
    {
        internal uint StructureSize;
        internal IntPtr FilePath;
        internal IntPtr FileHandle;
        internal IntPtr KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustData
    {
        internal uint StructureSize;
        internal IntPtr PolicyCallbackData;
        internal IntPtr SipClientData;
        internal uint UiChoice;
        internal uint RevocationChecks;
        internal uint UnionChoice;
        internal IntPtr FileInfo;
        internal uint StateAction;
        internal IntPtr StateData;
        internal IntPtr UrlReference;
        internal uint ProviderFlags;
        internal uint UiContext;
        internal IntPtr SignatureSettings;
    }
}

internal enum ServeRootRestoreDecision
{
    AlreadyRestored,
    RestoreFromExpectedMutationState
}
