using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;
using EverVigil.Broker.Protocol;

namespace EverVigil.Services;

internal static class PrivilegedBrokerClient
{
    internal const string BrokerVersion = "2.0.0";
    private static readonly TimeSpan PipeTimeout = TimeSpan.FromSeconds(90);
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
    private static readonly JsonSerializerOptions ReceiptSerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    internal static async Task<PrivilegedBrokerResponse> InvokeAsync(
        Guid transactionId,
        PrivilegedBrokerOperation operation,
        int? publicPort = null,
        int? backendPort = null,
        CancellationToken cancellationToken = default)
    {
        if (transactionId == Guid.Empty)
        {
            throw new ArgumentException("Privileged broker transaction ID is empty.", nameof(transactionId));
        }
        if (operation == PrivilegedBrokerOperation.Apply)
        {
            if (publicPort is < 1024 or > 65535 ||
                backendPort is < 1024 or > 65535 ||
                publicPort == backendPort)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(publicPort),
                    "Privileged broker ports are invalid.");
            }
        }
        else if (publicPort is not null || backendPort is not null)
        {
            throw new ArgumentException(
                "Only privileged broker Apply accepts ports.");
        }

        var executable = ValidateCanonicalInstallation();
        var pipeName = $"EverVigil.Broker.{Guid.NewGuid():N}";
        var nonce = PrivilegedBrokerProtocol.CreateNonce();
        var request = new PrivilegedBrokerRequest(
            PrivilegedBrokerProtocol.SchemaVersion,
            transactionId,
            nonce,
            operation,
            PrivilegedBrokerInitiator.Interactive,
            publicPort,
            backendPort);

        using var process = StartCanonicalBroker(
            executable,
            pipeName,
            nonce,
            transactionId);
        await using var pipe = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.WriteThrough);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(PipeTimeout);
        try
        {
            await pipe.ConnectAsync(timeout.Token).ConfigureAwait(true);
            await PrivilegedBrokerProtocol.WriteFrameAsync(
                pipe,
                request,
                timeout.Token).ConfigureAwait(true);
            var response = await PrivilegedBrokerProtocol
                .ReadFrameAsync<PrivilegedBrokerResponse>(pipe, timeout.Token)
                .ConfigureAwait(true);
            ValidateResponse(response, transactionId);
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(true);
            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    $"Protected privileged broker exited with code {process.ExitCode}.");
            }
            return response;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("Protected privileged broker timed out.");
        }
    }

    internal static string ValidateCanonicalInstallation()
    {
        var commonData = Path.GetFullPath(Environment.GetFolderPath(
            Environment.SpecialFolder.CommonApplicationData));
        var productRoot = Path.GetFullPath(Path.Combine(commonData, "EverVigil"));
        var brokerRoot = PrivilegedBrokerPaths.GetBrokerRoot(commonData);
        var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(commonData, BrokerVersion);
        var executable = PrivilegedBrokerPaths.GetProtectedExecutablePath(
            commonData,
            BrokerVersion);
        var receiptPath = PrivilegedBrokerPaths.GetInstallationReceiptPath(
            commonData,
            BrokerVersion);
        foreach (var path in new[] { productRoot, brokerRoot, versionRoot, executable, receiptPath })
        {
            ValidateProtectedPath(commonData, path);
        }

        var receipt = ReadStrictReceipt(receiptPath);
        receipt.ValidateSchema();
        var information = new FileInfo(executable);
        if (!string.Equals(
                receipt.FileName,
                PrivilegedBrokerPaths.BrokerFileName,
                StringComparison.Ordinal) ||
            !string.Equals(receipt.Version, BrokerVersion, StringComparison.Ordinal) ||
            receipt.Length <= 0 ||
            information.Length != receipt.Length ||
            !IsLowerHexSha256(receipt.Sha256))
        {
            throw new InvalidDataException("Protected broker installation receipt is invalid.");
        }
        using var stream = new FileStream(
            executable,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            128 * 1024,
            FileOptions.SequentialScan);
        var actualHash = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        if (!CryptographicOperations.FixedTimeEquals(
                Convert.FromHexString(receipt.Sha256),
                Convert.FromHexString(actualHash)))
        {
            throw new InvalidDataException(
                "Protected broker executable does not match its installation receipt.");
        }
        return executable;
    }

    private static Process StartCanonicalBroker(
        string executable,
        string pipeName,
        string nonce,
        Guid transactionId)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = true,
            Verb = "runas",
            WorkingDirectory = Path.GetDirectoryName(executable) ??
                throw new InvalidDataException("Protected broker directory is unavailable.")
        };
        startInfo.ArgumentList.Add("--client-pid");
        startInfo.ArgumentList.Add(Environment.ProcessId.ToString(
            System.Globalization.CultureInfo.InvariantCulture));
        startInfo.ArgumentList.Add("--pipe");
        startInfo.ArgumentList.Add(pipeName);
        startInfo.ArgumentList.Add("--nonce");
        startInfo.ArgumentList.Add(nonce);
        startInfo.ArgumentList.Add("--transaction-id");
        startInfo.ArgumentList.Add(transactionId.ToString("D"));
        try
        {
            return Process.Start(startInfo) ??
                throw new InvalidOperationException("Protected privileged broker did not start.");
        }
        catch (Win32Exception exception) when (exception.NativeErrorCode == 1223)
        {
            throw new OperationCanceledException("UAC confirmation was cancelled.", exception);
        }
    }

    private static BrokerInstallationReceipt ReadStrictReceipt(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length is <= 0 or > 64 * 1024)
        {
            throw new InvalidDataException("Protected broker receipt size is invalid.");
        }
        try
        {
            using var document = JsonDocument.Parse(bytes);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidDataException("Protected broker receipt root is invalid.");
            }
            var properties = document.RootElement.EnumerateObject().ToArray();
            var expected = new[] { "schemaVersion", "fileName", "version", "length", "sha256" };
            if (properties.Length != expected.Length ||
                properties.Select(property => property.Name)
                    .Distinct(StringComparer.Ordinal).Count() != expected.Length ||
                !properties.Select(property => property.Name)
                    .OrderBy(value => value, StringComparer.Ordinal)
                    .SequenceEqual(expected.OrderBy(value => value, StringComparer.Ordinal)))
            {
                throw new InvalidDataException(
                    "Protected broker receipt fields are not the exact schema.");
            }
            return JsonSerializer.Deserialize<BrokerInstallationReceipt>(
                       bytes,
                       ReceiptSerializerOptions) ??
                throw new InvalidDataException("Protected broker receipt is empty.");
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException("Protected broker receipt JSON is invalid.", exception);
        }
    }

    private static void ValidateProtectedPath(string commonData, string path)
    {
        var fullPath = Path.GetFullPath(path);
        if (!fullPath.StartsWith(
                Path.TrimEndingDirectorySeparator(commonData) + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(fullPath) && !Directory.Exists(fullPath) ||
            (File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException("Protected broker path is missing, redirected, or escaped.");
        }
        FileSystemSecurity security = File.Exists(fullPath)
            ? new FileInfo(fullPath).GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner)
            : new DirectoryInfo(fullPath).GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner);
        if (!security.AreAccessRulesProtected ||
            security.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner ||
            !IsPrivileged(owner))
        {
            throw new InvalidDataException("Protected broker ACL owner or inheritance is invalid.");
        }
        foreach (FileSystemAccessRule rule in security.GetAccessRules(
                     includeExplicit: true,
                     includeInherited: true,
                     typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow ||
                (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0 ||
                (rule.FileSystemRights & DangerousRights) == 0)
            {
                continue;
            }
            if (!IsPrivileged((SecurityIdentifier)rule.IdentityReference))
            {
                throw new InvalidDataException(
                    "A non-privileged principal can modify the protected broker path.");
            }
        }
    }

    private static bool IsPrivileged(SecurityIdentifier sid) =>
        sid.Equals(SystemSid) || sid.Equals(AdministratorsSid);

    private static bool IsLowerHexSha256(string value) =>
        value.Length == 64 && value.All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static void ValidateResponse(
        PrivilegedBrokerResponse response,
        Guid transactionId)
    {
        if (response.SchemaVersion != PrivilegedBrokerProtocol.SchemaVersion ||
            response.TransactionId != transactionId ||
            !Enum.IsDefined(response.Disposition) ||
            !Enum.IsDefined(response.ErrorCode) ||
            response.Message.Length > 1024 ||
            response.Message.Contains('\r') ||
            response.Message.Contains('\n') ||
            response.Success != (response.ErrorCode == PrivilegedBrokerErrorCode.None &&
                response.Disposition is not (
                    PrivilegedBrokerDisposition.Refused or
                    PrivilegedBrokerDisposition.PendingRecovery)))
        {
            throw new InvalidDataException("Protected privileged broker response is invalid.");
        }
    }

    private sealed record BrokerInstallationReceipt(
        int SchemaVersion,
        string FileName,
        string Version,
        long Length,
        string Sha256)
    {
        internal void ValidateSchema()
        {
            if (SchemaVersion != 1)
            {
                throw new InvalidDataException("Protected broker receipt schema is unsupported.");
            }
        }
    }
}
