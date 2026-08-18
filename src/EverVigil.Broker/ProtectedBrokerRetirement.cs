using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using EverVigil.Broker.Protocol;

namespace EverVigil.Broker;

internal static class ProtectedBrokerRetirement
{
    private const int SchemaVersion = 1;
    private const string RetirementState = "RetirementPrepared";
    private const int MaximumReceiptBytes = 64 * 1024;

    internal static bool ReceiptExists(string commonData, string version) =>
        File.Exists(PrivilegedBrokerPaths.GetRetirementReceiptPath(commonData, version));

    internal static BrokerRetirementReceipt ReadReceiptForTests(
        string commonData,
        string version) =>
        ReadReceipt(commonData, version, enforceProtectedAccess: false);

    internal static void RequireReceiptOwnerForTests(
        string commonData,
        string version,
        string ownerSid) =>
        RequireReceiptOwner(
            ReadReceipt(commonData, version, enforceProtectedAccess: false),
            ownerSid);

    internal static void ValidateReceiptJsonForTests(string json, string version)
    {
        ValidateReceiptShape(json);
        var receipt = JsonSerializer.Deserialize(
            json,
            BrokerJsonContext.Default.BrokerRetirementReceipt) ??
            throw new InvalidDataException(
                "Test retirement receipt is empty.");
        ValidateReceipt(receipt, version);
    }

    internal static bool AreRetirementOwnerRightsDeleteOnly(FileSystemRights rights)
    {
        const FileSystemRights forbidden =
            FileSystemRights.WriteData |
            FileSystemRights.CreateFiles |
            FileSystemRights.AppendData |
            FileSystemRights.CreateDirectories |
            FileSystemRights.WriteExtendedAttributes |
            FileSystemRights.DeleteSubdirectoriesAndFiles |
            FileSystemRights.WriteAttributes |
            FileSystemRights.ChangePermissions |
            FileSystemRights.TakeOwnership;
        return (rights & FileSystemRights.Delete) != 0 && (rights & forbidden) == 0;
    }

    internal static BrokerRetirementReceipt ValidateCanonicalRetirement(
        string commonData,
        string version,
        ProtectedBrokerIdentity loadedIdentity)
    {
        CleanupRetirementReceiptTemps(
            commonData,
            version,
            enforceProtectedAccess: true);
        var receipt = ReadReceipt(commonData, version, enforceProtectedAccess: true);
        var ownerSid = new SecurityIdentifier(receipt.OwnerSid);
        var canonicalPath = PrivilegedBrokerPaths.GetProtectedExecutablePath(
            commonData,
            version);
        ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, canonicalPath);
        ValidateStandardOrRetirementFile(canonicalPath, ownerSid);
        var actual = ProtectedBrokerInstallation.ReadIdentity(canonicalPath, version);
        if (actual.Length != loadedIdentity.Length ||
            !string.Equals(actual.Sha256, loadedIdentity.Sha256, StringComparison.Ordinal) ||
            actual.Length != receipt.Length ||
            !string.Equals(actual.Sha256, receipt.Sha256, StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Retiring canonical broker does not match its protected receipt.");
        }
        return receipt;
    }

    internal static PrivilegedBrokerResponse Resume(
        PrivilegedBrokerRequest request,
        string authenticatedOwnerSid,
        string commonData,
        string version)
    {
        if (request.Operation != PrivilegedBrokerOperation.UninstallCleanup)
        {
            throw new BrokerRefusalException(
                "The protected broker is retired and only uninstall cleanup may resume.",
                PrivilegedBrokerErrorCode.RecoveryRequired,
                pendingRecovery: true);
        }
        CleanupRetirementReceiptTemps(
            commonData,
            version,
            enforceProtectedAccess: true);
        var receipt = ReadReceipt(commonData, version, enforceProtectedAccess: true);
        RequireReceiptOwnerAndTransaction(
            receipt,
            authenticatedOwnerSid,
            request.TransactionId);
        if (HasOtherOwnerState(
                commonData,
                authenticatedOwnerSid,
                enforceProtectedAccess: true))
        {
            throw new BrokerRefusalException(
                "Another protected owner state appeared during broker retirement.",
                PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
        CleanupCurrentOwnerStateForRetirement(
            commonData,
            authenticatedOwnerSid,
            enforceProtectedAccess: true);
        DeleteEmptyStateRoot(commonData, enforceProtectedAccess: true);
        FinishDeleteAuthorization(
            commonData,
            version,
            receipt,
            enforceProtectedAccess: true,
            afterBoundary: null);
        return new PrivilegedBrokerResponse(
            PrivilegedBrokerProtocol.SchemaVersion,
            request.TransactionId,
            Success: true,
            PrivilegedBrokerDisposition.RetirementRequired,
            PrivilegedBrokerErrorCode.None,
            "Protected broker retirement is ready for fixed-path deletion after process exit.");
    }

    internal static bool RetireIfLastOwner(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store)
    {
        if (!store.EnforcesProtectedAccess)
        {
            store.DeleteOwnerStateAfterUninstall();
            return false;
        }
        return RetireIfLastOwnerCore(
            request,
            ownerSid,
            store,
            ProtectedBrokerInstallation.GetProductVersion(),
            enforceProtectedAccess: true,
            afterBoundary: null);
    }

    internal static bool RetireIfLastOwnerForTests(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store,
        string version,
        Action<string>? afterBoundary = null) =>
        RetireIfLastOwnerCore(
            request,
            ownerSid,
            store,
            version,
            enforceProtectedAccess: false,
            afterBoundary);

    private static bool RetireIfLastOwnerCore(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store,
        string version,
        bool enforceProtectedAccess,
        Action<string>? afterBoundary)
    {
        var commonData = store.CommonData;
        if (HasOtherOwnerState(commonData, ownerSid, enforceProtectedAccess))
        {
            store.DeleteOwnerStateAfterUninstall();
            afterBoundary?.Invoke("owner-state-deleted-shared");
            return false;
        }

        var receiptPath = PrivilegedBrokerPaths.GetRetirementReceiptPath(
            commonData,
            version);
        CleanupRetirementReceiptTemps(
            commonData,
            version,
            enforceProtectedAccess);
        BrokerRetirementReceipt receipt;
        if (File.Exists(receiptPath))
        {
            receipt = ReadReceipt(commonData, version, enforceProtectedAccess);
            RequireReceiptOwnerAndTransaction(
                receipt,
                ownerSid,
                request.TransactionId);
        }
        else
        {
            var canonicalPath = PrivilegedBrokerPaths.GetProtectedExecutablePath(
                commonData,
                version);
            var installationReceiptPath = PrivilegedBrokerPaths.GetInstallationReceiptPath(
                commonData,
                version);
            var identity = enforceProtectedAccess
                ? ProtectedBrokerInstallation.ValidateCanonical(
                    commonData,
                    version,
                    canonicalPath,
                    installationReceiptPath)
                : ProtectedBrokerInstallation.ReadIdentity(canonicalPath, version);
            receipt = new BrokerRetirementReceipt(
                SchemaVersion,
                request.TransactionId,
                ownerSid,
                version,
                PrivilegedBrokerPaths.BrokerFileName,
                identity.Length,
                identity.Sha256,
                RetirementState);
            WriteReceipt(receiptPath, receipt, enforceProtectedAccess);
            afterBoundary?.Invoke("retirement-receipt-written");
        }

        store.DeleteOwnerStateAfterUninstall();
        afterBoundary?.Invoke("owner-state-deleted");
        DeleteEmptyStateRoot(commonData, enforceProtectedAccess);
        afterBoundary?.Invoke("state-root-deleted");
        FinishDeleteAuthorization(
            commonData,
            version,
            receipt,
            enforceProtectedAccess,
            afterBoundary);
        return true;
    }

    private static void FinishDeleteAuthorization(
        string commonData,
        string version,
        BrokerRetirementReceipt receipt,
        bool enforceProtectedAccess,
        Action<string>? afterBoundary)
    {
        var ownerSid = new SecurityIdentifier(receipt.OwnerSid);
        var canonicalPath = PrivilegedBrokerPaths.GetProtectedExecutablePath(
            commonData,
            version);
        var installationReceiptPath = PrivilegedBrokerPaths.GetInstallationReceiptPath(
            commonData,
            version);
        var retirementReceiptPath = PrivilegedBrokerPaths.GetRetirementReceiptPath(
            commonData,
            version);
        var brokerRoot = PrivilegedBrokerPaths.GetBrokerRoot(commonData);
        var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(commonData, version);
        var productRoot = Path.GetDirectoryName(brokerRoot) ??
            throw new InvalidDataException("Protected product root is unavailable.");

        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, versionRoot);
            ValidateStandardOrRetirementFile(canonicalPath, ownerSid);
        }
        var image = ProtectedBrokerInstallation.ReadIdentity(canonicalPath, version);
        if (image.Length != receipt.Length ||
            !string.Equals(image.Sha256, receipt.Sha256, StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Protected retiring broker image changed after authorization.");
        }

        var installationReceiptRestored =
            ProtectedBrokerInstallation.EnsureRetirementInstallationReceipt(
                commonData,
                version,
                image,
                ownerSid,
                enforceProtectedAccess);
        if (installationReceiptRestored)
        {
            afterBoundary?.Invoke("installation-receipt-restored");
        }

        if (!File.Exists(installationReceiptPath) || !File.Exists(retirementReceiptPath) ||
            !Directory.Exists(versionRoot) || !Directory.Exists(brokerRoot) ||
            !Directory.Exists(productRoot))
        {
            throw new InvalidDataException(
                "Protected retirement layout is incomplete.");
        }
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.GrantDeleteOnlyFile(canonicalPath, ownerSid);
        }
        afterBoundary?.Invoke("delete-authorized-canonical");
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.GrantDeleteOnlyFile(installationReceiptPath, ownerSid);
        }
        afterBoundary?.Invoke("delete-authorized-installation-receipt");
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.GrantDeleteOnlyFile(retirementReceiptPath, ownerSid);
        }
        afterBoundary?.Invoke("delete-authorized-retirement-receipt");
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.GrantDeleteOnlyDirectory(versionRoot, ownerSid);
        }
        afterBoundary?.Invoke("delete-authorized-version-root");
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.GrantDeleteOnlyDirectory(brokerRoot, ownerSid);
        }
        afterBoundary?.Invoke("delete-authorized-broker-root");
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.GrantDeleteOnlyDirectory(productRoot, ownerSid);
        }
        afterBoundary?.Invoke("delete-authorized-product-root");

        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateRetirementFile(canonicalPath, ownerSid);
        }
        var authorizedIdentity = ProtectedBrokerInstallation.ReadIdentity(canonicalPath, version);
        if (authorizedIdentity.Length != receipt.Length ||
            !string.Equals(authorizedIdentity.Sha256, receipt.Sha256, StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Delete-authorized canonical broker image does not match its receipt.");
        }

        // The durable retirement receipt and delete-only ACLs let the medium
        // caller finish deletion after this broker process exits, and let a
        // later recovery retry safely after response loss or power failure.
        // Never enqueue this reusable canonical path for deletion at reboot:
        // a same-version reinstall before reboot would place a new broker at
        // the same path and Session Manager would delete the new image.
        afterBoundary?.Invoke("retirement-ready-for-post-exit-deletion");
    }

    internal static bool HasOtherOwnerStateForTests(
        string commonData,
        string ownerSid) =>
        HasOtherOwnerState(commonData, ownerSid, enforceProtectedAccess: false);

    private static bool HasOtherOwnerState(
        string commonData,
        string ownerSid,
        bool enforceProtectedAccess)
    {
        var stateRoot = PrivilegedBrokerPaths.GetStateRoot(commonData);
        if (!Directory.Exists(stateRoot))
        {
            return false;
        }
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, stateRoot);
            ProtectedBrokerAccess.CreateStateRootDirectory(stateRoot);
        }
        var otherOwnerFound = false;
        foreach (var entry in Directory.EnumerateFileSystemEntries(stateRoot))
        {
            if (!Directory.Exists(entry) ||
                (File.GetAttributes(entry) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidDataException(
                    "Protected State root contains an unexpected entry.");
            }
            var candidateSid = new SecurityIdentifier(Path.GetFileName(entry));
            if (enforceProtectedAccess)
            {
                ProtectedBrokerAccess.ValidateOwnerStateDirectory(entry, candidateSid);
            }
            if (!string.Equals(candidateSid.Value, ownerSid, StringComparison.Ordinal))
            {
                otherOwnerFound = true;
            }
        }
        return otherOwnerFound;
    }

    private static void CleanupCurrentOwnerStateForRetirement(
        string commonData,
        string ownerSid,
        bool enforceProtectedAccess)
    {
        var owner = new SecurityIdentifier(ownerSid);
        var ownerRoot = PrivilegedBrokerPaths.GetOwnerStateRoot(commonData, ownerSid);
        if (!Directory.Exists(ownerRoot))
        {
            return;
        }
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, ownerRoot);
            ProtectedBrokerAccess.ValidateOwnerStateDirectory(ownerRoot, owner);
        }
        foreach (var entry in Directory.EnumerateFileSystemEntries(ownerRoot))
        {
            if (Directory.Exists(entry) ||
                (File.GetAttributes(entry) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidDataException(
                    "Retiring owner state contains an unexpected entry.");
            }
            var name = Path.GetFileName(entry);
            if (string.Equals(
                    name,
                    PrivilegedBrokerPaths.PendingJournalFileName,
                    StringComparison.Ordinal) ||
                string.Equals(
                    name,
                    PrivilegedBrokerPaths.AppliedLedgerFileName,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Retiring owner still has pending or applied system ownership.");
            }
            if (!string.Equals(
                    name,
                    PrivilegedBrokerPaths.TransactionReceiptFileName,
                    StringComparison.Ordinal) &&
                !IsKnownStateTemporaryFile(name))
            {
                throw new InvalidDataException(
                    "Retiring owner state contains an unknown file.");
            }
            if (enforceProtectedAccess)
            {
                ProtectedBrokerAccess.ValidateOwnerStateFile(entry, owner);
            }
            File.Delete(entry);
        }
        Directory.Delete(ownerRoot, recursive: false);
    }

    private static bool IsKnownStateTemporaryFile(string name)
    {
        foreach (var stableName in new[]
                 {
                     PrivilegedBrokerPaths.PendingJournalFileName,
                     PrivilegedBrokerPaths.AppliedLedgerFileName,
                     PrivilegedBrokerPaths.TransactionReceiptFileName
                 })
        {
            if (IsStrictTemporaryName(name, stableName))
            {
                return true;
            }
        }
        return false;
    }

    private static void CleanupRetirementReceiptTemps(
        string commonData,
        string version,
        bool enforceProtectedAccess)
    {
        var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(commonData, version);
        if (!Directory.Exists(versionRoot))
        {
            return;
        }
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, versionRoot);
        }
        foreach (var entry in Directory.EnumerateFiles(versionRoot))
        {
            var name = Path.GetFileName(entry);
            if (!IsStrictTemporaryName(
                    name,
                    PrivilegedBrokerPaths.RetirementReceiptFileName))
            {
                continue;
            }
            var info = new FileInfo(entry);
            if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidDataException(
                    "Protected retirement temporary receipt is redirected.");
            }
            if (enforceProtectedAccess)
            {
                ProtectedBrokerAccess.ValidateProtectedTemporaryFile(entry);
            }
            File.Delete(entry);
        }
    }

    private static bool IsStrictTemporaryName(string name, string stableName)
    {
        var prefix = stableName + ".";
        if (!name.StartsWith(prefix, StringComparison.Ordinal) ||
            !name.EndsWith(".tmp", StringComparison.Ordinal))
        {
            return false;
        }
        var identifier = name[prefix.Length..^4];
        return identifier.Length == 32 && identifier.All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f');
    }

    private static void DeleteEmptyStateRoot(
        string commonData,
        bool enforceProtectedAccess)
    {
        var stateRoot = PrivilegedBrokerPaths.GetStateRoot(commonData);
        if (!Directory.Exists(stateRoot))
        {
            return;
        }
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, stateRoot);
            ProtectedBrokerAccess.CreateStateRootDirectory(stateRoot);
        }
        if (Directory.EnumerateFileSystemEntries(stateRoot).Any())
        {
            throw new InvalidDataException(
                "Protected State root was not empty at last-owner retirement.");
        }
        Directory.Delete(stateRoot, recursive: false);
    }

    private static void ValidateStandardOrRetirementFile(
        string path,
        SecurityIdentifier ownerSid)
    {
        try
        {
            ProtectedBrokerAccess.ValidateFile(path, allowUsersReadAndExecute: true);
        }
        catch (InvalidDataException)
        {
            ProtectedBrokerAccess.ValidateRetirementFile(path, ownerSid);
        }
    }

    private static BrokerRetirementReceipt ReadReceipt(
        string commonData,
        string version,
        bool enforceProtectedAccess)
    {
        var path = PrivilegedBrokerPaths.GetRetirementReceiptPath(commonData, version);
        if (enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(commonData, path);
        }
        var info = new FileInfo(path);
        if (!info.Exists || info.Length is <= 0 or > MaximumReceiptBytes ||
            (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException(
                "Protected broker retirement receipt is missing or invalid.");
        }
        var json = File.ReadAllText(path, Encoding.UTF8);
        ValidateReceiptShape(json);
        var receipt = JsonSerializer.Deserialize(
            json,
            BrokerJsonContext.Default.BrokerRetirementReceipt) ??
            throw new InvalidDataException(
                "Protected broker retirement receipt is empty.");
        ValidateReceipt(receipt, version);
        if (enforceProtectedAccess)
        {
            var ownerSid = new SecurityIdentifier(receipt.OwnerSid);
            ValidateStandardOrRetirementFile(path, ownerSid);
        }
        return receipt;
    }

    private static void WriteReceipt(
        string path,
        BrokerRetirementReceipt receipt,
        bool enforceProtectedAccess)
    {
        ValidateReceipt(receipt, receipt.Version);
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(
                receipt,
                BrokerJsonContext.Default.BrokerRetirementReceipt);
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

    private static void ValidateReceipt(
        BrokerRetirementReceipt receipt,
        string expectedVersion)
    {
        if (receipt.SchemaVersion != SchemaVersion ||
            receipt.TransactionId == Guid.Empty ||
            string.IsNullOrWhiteSpace(receipt.OwnerSid) ||
            !string.Equals(receipt.Version, expectedVersion, StringComparison.Ordinal) ||
            !string.Equals(
                receipt.CanonicalFileName,
                PrivilegedBrokerPaths.BrokerFileName,
                StringComparison.Ordinal) ||
            receipt.Length <= 0 ||
            !IsLowerHexSha256(receipt.Sha256) ||
            !string.Equals(receipt.State, RetirementState, StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                "Protected broker retirement receipt identity is invalid.");
        }
        _ = new SecurityIdentifier(receipt.OwnerSid);
    }

    private static void RequireReceiptOwner(
        BrokerRetirementReceipt receipt,
        string authenticatedOwnerSid)
    {
        if (!string.Equals(
                receipt.OwnerSid,
                authenticatedOwnerSid,
                StringComparison.Ordinal))
        {
            throw new BrokerRefusalException(
                "Protected broker retirement belongs to another authenticated owner.",
                PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
    }

    private static void RequireReceiptOwnerAndTransaction(
        BrokerRetirementReceipt receipt,
        string authenticatedOwnerSid,
        Guid transactionId)
    {
        RequireReceiptOwner(receipt, authenticatedOwnerSid);
        if (receipt.TransactionId != transactionId)
        {
            throw new BrokerRefusalException(
                "Protected broker retirement belongs to another transaction.",
                PrivilegedBrokerErrorCode.PendingTransactionMismatch,
                pendingRecovery: true);
        }
    }

    private static void ValidateReceiptShape(string json)
    {
        using var document = JsonDocument.Parse(json);
        var expected = new HashSet<string>(StringComparer.Ordinal)
        {
            "schemaVersion",
            "transactionId",
            "ownerSid",
            "version",
            "canonicalFileName",
            "length",
            "sha256",
            "state"
        };
        var observed = new HashSet<string>(StringComparer.Ordinal);
        if (document.RootElement.ValueKind != JsonValueKind.Object ||
            document.RootElement.EnumerateObject().Any(property =>
                !expected.Contains(property.Name) || !observed.Add(property.Name)) ||
            !observed.SetEquals(expected))
        {
            throw new InvalidDataException(
                "Protected broker retirement receipt schema is not exact.");
        }
    }

    private static bool IsLowerHexSha256(string value) =>
        value.Length == 64 && value.All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f');

}

internal sealed record BrokerRetirementReceipt(
    int SchemaVersion,
    Guid TransactionId,
    string OwnerSid,
    string Version,
    string CanonicalFileName,
    long Length,
    string Sha256,
    string State);
