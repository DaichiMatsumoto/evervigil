using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using EverVigil.Broker.Protocol;

namespace EverVigil.Broker;

internal sealed class BrokerStateStore
{
    internal const int SchemaVersion = 1;
    private const long MaximumStateFileBytes = 1024 * 1024;

    private readonly SecurityIdentifier _ownerSid;
    private readonly string _commonData;
    private readonly string _ownerRoot;
    private readonly string _pendingPath;
    private readonly string _appliedPath;
    private readonly string _receiptPath;
    private readonly bool _enforceProtectedAccess;
    private readonly Action<string>? _afterDurableBoundary;

    internal BrokerStateStore(string ownerSid)
        : this(
            ownerSid,
            Path.GetFullPath(Environment.GetFolderPath(
                Environment.SpecialFolder.CommonApplicationData)),
            enforceProtectedAccess: true,
            afterDurableBoundary: null)
    {
    }

    private BrokerStateStore(
        string ownerSid,
        string commonData,
        bool enforceProtectedAccess,
        Action<string>? afterDurableBoundary)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerSid);
        try
        {
            _ownerSid = new SecurityIdentifier(ownerSid);
        }
        catch (ArgumentException exception)
        {
            throw new InvalidDataException("Authenticated broker owner SID is invalid.", exception);
        }

        _commonData = Path.GetFullPath(commonData);
        _enforceProtectedAccess = enforceProtectedAccess;
        _afterDurableBoundary = afterDurableBoundary;
        _ownerRoot = PrivilegedBrokerPaths.GetOwnerStateRoot(_commonData, _ownerSid.Value);
        _pendingPath = PrivilegedBrokerPaths.GetPendingJournalPath(_commonData, _ownerSid.Value);
        _appliedPath = PrivilegedBrokerPaths.GetAppliedLedgerPath(_commonData, _ownerSid.Value);
        _receiptPath = PrivilegedBrokerPaths.GetTransactionReceiptPath(
            _commonData,
            _ownerSid.Value);
        EnsureProtectedLayout();
    }

    internal static BrokerStateStore ForTests(
        string commonData,
        string ownerSid,
        Action<string>? afterDurableBoundary = null) =>
        new(
            ownerSid,
            commonData,
            enforceProtectedAccess: false,
            afterDurableBoundary);

    internal bool PendingExists => File.Exists(_pendingPath);

    internal bool AppliedExists => File.Exists(_appliedPath);

    internal string PendingPath => _pendingPath;

    internal string AppliedPath => _appliedPath;

    internal string CommonData => _commonData;

    internal string OwnerRoot => _ownerRoot;

    internal bool EnforcesProtectedAccess => _enforceProtectedAccess;

    internal BrokerPendingJournal Begin(
        PrivilegedBrokerRequest request,
        BrokerSystemConfiguration target,
        BrokerSystemConfiguration? previous,
        LegacyTaskIdentity? legacyTask,
        TailscaleSelfIdentity observedSelf,
        BrokerSystemConfiguration? legacyV121Configuration = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(target);
        if (PendingExists)
        {
            throw new BrokerRefusalException(
                "A protected system transaction is already pending.",
                PrivilegedBrokerErrorCode.PendingTransactionMismatch,
                pendingRecovery: true);
        }

        var journal = new BrokerPendingJournal(
            SchemaVersion,
            request.TransactionId,
            _ownerSid.Value,
            request.Operation,
            request.Initiator,
            BrokerMutationPhase.Prepared,
            target,
            previous,
            previous is not null,
            previous is not null && previous.PublicPort == target.PublicPort,
            request.MigrateLegacySystemState,
            ObservedTargetRoot: null,
            ObservedPreviousRoot: null,
            TargetUnrelatedHandlersJson: null,
            PreviousUnrelatedHandlersJson: null,
            OriginalFirewallRules: [],
            LegacyTask: legacyTask,
            PreviousRouteMutationAuthorized: false,
            TargetRouteMutationAuthorized: false,
            FirewallMutationAuthorized: false,
            LegacyTaskMutationAuthorized: false,
            AppliedLedgerMutationAuthorized: false,
            ObservedSelf: observedSelf,
            PreviousAppliedLedger: LoadApplied(),
            AppliedLedgerCommitTimeUtc: null,
            LegacyV121Configuration: legacyV121Configuration);
        ValidatePending(journal);
        WriteAtomic(_pendingPath, journal, overwrite: false);
        return journal;
    }

    internal BrokerPendingJournal LoadPending(Guid transactionId)
    {
        var pending = LoadExistingPending();
        if (transactionId == Guid.Empty || pending.TransactionId != transactionId)
        {
            throw new BrokerRefusalException(
                "Protected pending transaction ID does not match the request.",
                PrivilegedBrokerErrorCode.PendingTransactionMismatch,
                pendingRecovery: true);
        }
        return pending;
    }

    internal BrokerPendingJournal LoadExistingPending()
    {
        var pending = Read<BrokerPendingJournal>(_pendingPath);
        ValidatePending(pending);
        return pending;
    }

    internal BrokerPendingJournal Update(
        Guid transactionId,
        Func<BrokerPendingJournal, BrokerPendingJournal> update)
    {
        ArgumentNullException.ThrowIfNull(update);
        var current = LoadPending(transactionId);
        var next = update(current);
        if (next.TransactionId != current.TransactionId ||
            !string.Equals(next.OwnerSid, current.OwnerSid, StringComparison.Ordinal) ||
            next.Operation != current.Operation ||
            next.Target != current.Target ||
            next.Previous != current.Previous ||
            !AppliedLedgerEquals(next.PreviousAppliedLedger, current.PreviousAppliedLedger) ||
            next.LegacyV121Configuration != current.LegacyV121Configuration)
        {
            throw new InvalidDataException("Protected pending journal immutable identity changed.");
        }
        ValidatePending(next);
        WriteAtomic(_pendingPath, next, overwrite: true);
        return next;
    }

    internal BrokerAppliedLedger? LoadApplied()
    {
        if (!AppliedExists)
        {
            return null;
        }
        var applied = Read<BrokerAppliedLedger>(_appliedPath);
        ValidateApplied(applied);
        return applied;
    }

    internal IReadOnlyList<BrokerAppliedLedger> LoadOtherOwnerAppliedLedgersForGlobalMutation()
    {
        var stateRoot = PrivilegedBrokerPaths.GetStateRoot(_commonData);
        if (!Directory.Exists(stateRoot))
        {
            return [];
        }
        if (_enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(_commonData, stateRoot);
            ProtectedBrokerAccess.CreateStateRootDirectory(stateRoot);
        }

        var ledgers = new List<BrokerAppliedLedger>();
        foreach (var ownerEntry in Directory.EnumerateFileSystemEntries(stateRoot)
                     .OrderBy(path => path, StringComparer.Ordinal))
        {
            var attributes = File.GetAttributes(ownerEntry);
            if ((attributes & FileAttributes.ReparsePoint) != 0 ||
                !Directory.Exists(ownerEntry))
            {
                throw new InvalidDataException(
                    "Protected global State contains a non-directory or redirected owner entry.");
            }

            SecurityIdentifier candidateSid;
            try
            {
                candidateSid = new SecurityIdentifier(Path.GetFileName(ownerEntry));
            }
            catch (ArgumentException exception)
            {
                throw new InvalidDataException(
                    "Protected global State contains a non-SID owner directory.",
                    exception);
            }
            if (!string.Equals(
                    Path.GetFileName(ownerEntry),
                    candidateSid.Value,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Protected global State owner directory is not a canonical SID.");
            }
            if (_enforceProtectedAccess)
            {
                ProtectedBrokerAccess.ValidateOwnerStateDirectory(ownerEntry, candidateSid);
            }

            var candidateStore = new BrokerStateStore(
                candidateSid.Value,
                _commonData,
                _enforceProtectedAccess,
                afterDurableBoundary: null);
            BrokerAppliedLedger? candidateApplied = null;
            foreach (var stateEntry in Directory.EnumerateFileSystemEntries(ownerEntry)
                         .OrderBy(path => path, StringComparer.Ordinal))
            {
                var stateAttributes = File.GetAttributes(stateEntry);
                if ((stateAttributes & FileAttributes.ReparsePoint) != 0 ||
                    Directory.Exists(stateEntry))
                {
                    throw new InvalidDataException(
                        "Protected owner State contains a directory or redirected entry.");
                }
                if (_enforceProtectedAccess)
                {
                    ProtectedBrokerAccess.ValidateOwnerStateFile(stateEntry, candidateSid);
                }

                var name = Path.GetFileName(stateEntry);
                if (string.Equals(
                        name,
                        PrivilegedBrokerPaths.PendingJournalFileName,
                        StringComparison.Ordinal))
                {
                    var pending = candidateStore.LoadExistingPending();
                    if (!candidateSid.Equals(_ownerSid))
                    {
                        throw new BrokerRefusalException(
                            "Another owner has a protected system transaction pending.",
                            PrivilegedBrokerErrorCode.PendingTransactionMismatch,
                            pendingRecovery: true);
                    }
                    _ = pending;
                    continue;
                }
                if (string.Equals(
                        name,
                        PrivilegedBrokerPaths.AppliedLedgerFileName,
                        StringComparison.Ordinal))
                {
                    candidateApplied = candidateStore.LoadApplied() ??
                        throw new InvalidDataException(
                            "Protected applied ledger disappeared during global inspection.");
                    continue;
                }
                if (string.Equals(
                        name,
                        PrivilegedBrokerPaths.TransactionReceiptFileName,
                        StringComparison.Ordinal))
                {
                    var receipt = candidateStore.Read<BrokerTransactionReceipt>(stateEntry);
                    candidateStore.ValidateReceipt(receipt);
                    continue;
                }
                if (IsKnownTemporaryStateFile(name))
                {
                    throw new BrokerRefusalException(
                        "Protected global State contains an incomplete atomic state file.",
                        PrivilegedBrokerErrorCode.RecoveryRequired,
                        pendingRecovery: true);
                }
                throw new InvalidDataException(
                    "Protected global State contains an unknown owner file.");
            }

            if (!candidateSid.Equals(_ownerSid) && candidateApplied is not null)
            {
                ledgers.Add(candidateApplied);
            }
        }
        return ledgers;
    }

    internal void CommitApplied(BrokerPendingJournal pending)
    {
        ArgumentNullException.ThrowIfNull(pending);
        ValidatePending(pending);
        if (pending.Phase is not (
                BrokerMutationPhase.MutationsCompleted or
                BrokerMutationPhase.AppliedLedgerCommitted) ||
            pending.ObservedSelf is null)
        {
            throw new InvalidDataException(
                "Protected transaction is not ready for applied-ledger commit.");
        }
        var applied = new BrokerAppliedLedger(
            SchemaVersion,
            _ownerSid.Value,
            pending.Target,
            pending.ObservedSelf,
            pending.AppliedLedgerCommitTimeUtc ??
                throw new InvalidDataException(
                    "Protected applied-ledger commit timestamp is missing."));
        ValidateApplied(applied);
        if (pending.Phase == BrokerMutationPhase.MutationsCompleted)
        {
            if (!pending.AppliedLedgerMutationAuthorized)
            {
                throw new InvalidDataException(
                    "Protected applied-ledger mutation was not durably authorized.");
            }
            WriteAtomic(_appliedPath, applied, overwrite: true);
            pending = Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.AppliedLedgerCommitted
            });
        }
        else if (!AppliedLedgerEquals(LoadApplied(), applied))
        {
            throw new InvalidDataException(
                "Protected applied ledger does not match the committed transaction.");
        }
        WriteReceipt(pending, PrivilegedBrokerDisposition.Completed);
        DeletePending(pending.TransactionId);
    }

    internal void RollbackAppliedLedger(BrokerPendingJournal pending)
    {
        ArgumentNullException.ThrowIfNull(pending);
        ValidatePending(pending);
        if (pending.AppliedLedgerMutationAuthorized)
        {
            pending = Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.AppliedLedgerRollbackPrepared
            });
            var current = LoadApplied();
            if (pending.PreviousAppliedLedger is null)
            {
                if (current is not null &&
                    !ConfigurationAndSelfEquals(
                        current,
                        pending.Target,
                        pending.ObservedSelf))
                {
                    throw new InvalidDataException(
                        "Protected rollback found an unrelated applied ledger.");
                }
                DeleteApplied();
            }
            else
            {
                ValidateApplied(pending.PreviousAppliedLedger);
                WriteAtomic(_appliedPath, pending.PreviousAppliedLedger, overwrite: true);
            }
            pending = Update(pending.TransactionId, value => value with
            {
                Phase = BrokerMutationPhase.AppliedLedgerRolledBack
            });
        }
        WriteReceipt(pending, PrivilegedBrokerDisposition.RolledBack);
        DeletePending(pending.TransactionId);
    }

    internal void CompleteWithoutAppliedMutation(
        BrokerPendingJournal pending,
        PrivilegedBrokerDisposition disposition)
    {
        ArgumentNullException.ThrowIfNull(pending);
        ValidatePending(pending);
        WriteReceipt(pending, disposition);
        DeletePending(pending.TransactionId);
    }

    internal void DiscardUnmutatedPending(BrokerPendingJournal pending)
    {
        ArgumentNullException.ThrowIfNull(pending);
        ValidatePending(pending);
        if (pending.Phase != BrokerMutationPhase.Prepared ||
            pending.PreviousRouteMutationAuthorized ||
            pending.TargetRouteMutationAuthorized ||
            pending.FirewallMutationAuthorized ||
            pending.LegacyTaskMutationAuthorized ||
            pending.AppliedLedgerMutationAuthorized)
        {
            throw new InvalidDataException(
                "Only a mutation-free Prepared journal may be discarded.");
        }
        DeletePending(pending.TransactionId);
    }

    internal BrokerTransactionReceipt? TryLoadReceipt(Guid transactionId)
    {
        if (transactionId == Guid.Empty || !File.Exists(_receiptPath))
        {
            return null;
        }
        var receipt = Read<BrokerTransactionReceipt>(_receiptPath);
        ValidateReceipt(receipt);
        return receipt.TransactionId == transactionId ? receipt : null;
    }

    internal void CleanupPendingAfterReceipt(BrokerTransactionReceipt receipt)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        ValidateReceipt(receipt);
        if (!PendingExists)
        {
            return;
        }
        var pending = LoadExistingPending();
        if (pending.TransactionId != receipt.TransactionId)
        {
            return;
        }
        var phaseMatches = receipt.Disposition switch
        {
            PrivilegedBrokerDisposition.Completed when
                receipt.SourceOperation == PrivilegedBrokerOperation.Apply =>
                pending.Phase == BrokerMutationPhase.AppliedLedgerCommitted,
            PrivilegedBrokerDisposition.Completed when
                receipt.SourceOperation == PrivilegedBrokerOperation.UninstallCleanup =>
                pending.Phase == BrokerMutationPhase.UninstallCompleted,
            PrivilegedBrokerDisposition.Completed when
                receipt.SourceOperation == PrivilegedBrokerOperation.LegacyTaskCleanup =>
                pending.Phase == BrokerMutationPhase.LegacyTaskRemoved,
            PrivilegedBrokerDisposition.RolledBack =>
                pending.Phase is (
                    BrokerMutationPhase.RecoveryPrepared or
                    BrokerMutationPhase.AppliedLedgerRolledBack),
            _ => false
        };
        if (!phaseMatches || pending.Operation != receipt.SourceOperation)
        {
            throw new InvalidDataException(
                "Protected receipt does not match its remaining pending journal.");
        }
        DeletePending(pending.TransactionId);
    }

    internal void DeleteApplied()
    {
        if (!File.Exists(_appliedPath))
        {
            return;
        }
        ProtectedBrokerAccess.ValidateOwnerStateFile(_appliedPath, _ownerSid);
        File.Delete(_appliedPath);
        if (File.Exists(_appliedPath))
        {
            throw new IOException("Protected applied ledger could not be deleted.");
        }
        _afterDurableBoundary?.Invoke(Path.GetFileName(_appliedPath) + ":deleted");
    }

    internal void DeletePending(Guid transactionId)
    {
        _ = LoadPending(transactionId);
        File.Delete(_pendingPath);
        if (File.Exists(_pendingPath))
        {
            throw new IOException("Protected pending journal could not be deleted.");
        }
        _afterDurableBoundary?.Invoke(Path.GetFileName(_pendingPath) + ":deleted");
    }

    internal void DeleteOwnerStateAfterUninstall()
    {
        if (PendingExists || AppliedExists)
        {
            throw new InvalidDataException(
                "Protected owner state cannot be retired while system ownership remains.");
        }
        if (!Directory.Exists(_ownerRoot))
        {
            return;
        }
        if (_enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateNoReparsePoints(_commonData, _ownerRoot);
            ProtectedBrokerAccess.ValidateOwnerStateDirectory(_ownerRoot, _ownerSid);
        }
        foreach (var entry in Directory.EnumerateFileSystemEntries(_ownerRoot))
        {
            if (Directory.Exists(entry) ||
                (File.GetAttributes(entry) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidDataException(
                    "Protected owner state contains an unexpected entry.");
            }
            var name = Path.GetFileName(entry);
            if (!string.Equals(
                    name,
                    PrivilegedBrokerPaths.TransactionReceiptFileName,
                    StringComparison.Ordinal) &&
                !IsKnownTemporaryStateFile(name))
            {
                throw new InvalidDataException(
                    "Protected owner state contains an unknown file.");
            }
            if (_enforceProtectedAccess)
            {
                ProtectedBrokerAccess.ValidateOwnerStateFile(entry, _ownerSid);
            }
            File.Delete(entry);
        }
        Directory.Delete(_ownerRoot, recursive: false);
        if (Directory.Exists(_ownerRoot))
        {
            throw new IOException("Protected owner state directory could not be retired.");
        }
    }

    private static bool IsKnownTemporaryStateFile(string name)
    {
        foreach (var stableName in new[]
                 {
                     PrivilegedBrokerPaths.PendingJournalFileName,
                     PrivilegedBrokerPaths.AppliedLedgerFileName,
                     PrivilegedBrokerPaths.TransactionReceiptFileName
                 })
        {
            var prefix = stableName + ".";
            if (!name.StartsWith(prefix, StringComparison.Ordinal) ||
                !name.EndsWith(".tmp", StringComparison.Ordinal))
            {
                continue;
            }
            var identifier = name[prefix.Length..^4];
            return identifier.Length == 32 &&
                identifier.All(character =>
                    character is >= '0' and <= '9' or >= 'a' and <= 'f');
        }
        return false;
    }

    private void EnsureProtectedLayout()
    {
        var brokerRoot = PrivilegedBrokerPaths.GetBrokerRoot(_commonData);
        var stateRoot = PrivilegedBrokerPaths.GetStateRoot(_commonData);
        if (!_enforceProtectedAccess)
        {
            Directory.CreateDirectory(_ownerRoot);
            return;
        }
        ProtectedBrokerAccess.ValidateNoReparsePoints(_commonData, brokerRoot);
        ProtectedBrokerAccess.ValidateDirectory(brokerRoot, allowUsersReadAndExecute: true);
        ProtectedBrokerAccess.ValidateNoReparsePoints(_commonData, stateRoot);
        ProtectedBrokerAccess.CreateStateRootDirectory(stateRoot);
        ProtectedBrokerAccess.ValidateNoReparsePoints(_commonData, _ownerRoot);
        ProtectedBrokerAccess.CreateOwnerStateDirectory(_ownerRoot, _ownerSid);
        if (File.Exists(_pendingPath))
        {
            ProtectedBrokerAccess.ValidateOwnerStateFile(_pendingPath, _ownerSid);
        }
        if (File.Exists(_appliedPath))
        {
            ProtectedBrokerAccess.ValidateOwnerStateFile(_appliedPath, _ownerSid);
        }
        if (File.Exists(_receiptPath))
        {
            ProtectedBrokerAccess.ValidateOwnerStateFile(_receiptPath, _ownerSid);
        }
    }

    private T Read<T>(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists)
        {
            throw new FileNotFoundException("Protected broker state was not found.", path);
        }
        if (info.Length is <= 0 or > MaximumStateFileBytes)
        {
            throw new InvalidDataException("Protected broker state size is invalid.");
        }
        if (_enforceProtectedAccess)
        {
            ProtectedBrokerAccess.ValidateOwnerStateFile(path, _ownerSid);
        }
        try
        {
            return JsonSerializer.Deserialize(
                       File.ReadAllText(path, Encoding.UTF8),
                       GetTypeInfo<T>()) ??
                throw new InvalidDataException("Protected broker state is empty.");
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException("Protected broker state is invalid JSON.", exception);
        }
    }

    private void WriteAtomic<T>(string path, T value, bool overwrite)
    {
        EnsureProtectedLayout();
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(value, GetTypeInfo<T>());
            if (bytes.LongLength is <= 0 or > MaximumStateFileBytes)
            {
                throw new InvalidDataException("Protected broker state size is invalid.");
            }
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
            if (_enforceProtectedAccess)
            {
                ProtectedBrokerAccess.ProtectOwnerStateFile(temporaryPath, _ownerSid);
            }
            File.Move(temporaryPath, path, overwrite);
            if (_enforceProtectedAccess)
            {
                ProtectedBrokerAccess.ProtectOwnerStateFile(path, _ownerSid);
            }
            _afterDurableBoundary?.Invoke(Path.GetFileName(path) + ":written");
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static JsonTypeInfo<T> GetTypeInfo<T>() =>
        typeof(T) == typeof(BrokerPendingJournal)
            ? (JsonTypeInfo<T>)(object)BrokerJsonContext.Default.BrokerPendingJournal
            : typeof(T) == typeof(BrokerAppliedLedger)
                ? (JsonTypeInfo<T>)(object)BrokerJsonContext.Default.BrokerAppliedLedger
                : typeof(T) == typeof(BrokerTransactionReceipt)
                    ? (JsonTypeInfo<T>)(object)
                        BrokerJsonContext.Default.BrokerTransactionReceipt
                    : throw new NotSupportedException(
                        $"Protected state serialization does not support {typeof(T).FullName}.");

    private void ValidatePending(BrokerPendingJournal pending)
    {
        if (pending.SchemaVersion != SchemaVersion ||
            pending.TransactionId == Guid.Empty ||
            !string.Equals(pending.OwnerSid, _ownerSid.Value, StringComparison.Ordinal) ||
            !Enum.IsDefined(pending.Operation) ||
            !Enum.IsDefined(pending.Initiator) ||
            !Enum.IsDefined(pending.Phase) ||
            pending.Operation is not (
                PrivilegedBrokerOperation.Apply or
                PrivilegedBrokerOperation.UninstallCleanup or
                PrivilegedBrokerOperation.LegacyTaskCleanup))
        {
            throw new InvalidDataException("Protected pending journal identity is invalid.");
        }
        ValidateConfiguration(pending.Target);
        if (pending.Previous is not null)
        {
            ValidateConfiguration(pending.Previous);
        }
        if (pending.LegacyV121Configuration is not null)
        {
            ValidateConfiguration(pending.LegacyV121Configuration);
        }
        if (pending.PreviousOwned != (pending.Previous is not null) ||
            pending.ExistingTargetOwned &&
            (!pending.PreviousOwned ||
             pending.Previous?.PublicPort != pending.Target.PublicPort) ||
            pending.MigrateLegacySystemState &&
            (pending.Operation != PrivilegedBrokerOperation.Apply ||
             pending.Initiator != PrivilegedBrokerInitiator.Installer) ||
            pending.MigrateLegacySystemState !=
                (pending.LegacyV121Configuration is not null))
        {
            throw new InvalidDataException("Protected pending journal ownership is invalid.");
        }
        if (pending.ObservedSelf is not null)
        {
            ValidateSelfIdentity(pending.ObservedSelf);
        }
        if (pending.PreviousAppliedLedger is not null)
        {
            ValidateApplied(pending.PreviousAppliedLedger);
            if (pending.Previous is null ||
                pending.PreviousAppliedLedger.Configuration != pending.Previous)
            {
                throw new InvalidDataException(
                    "Protected previous applied ledger does not match previous configuration.");
            }
        }
        var appliedCommitTimeIsInvalid =
            pending.AppliedLedgerCommitTimeUtc is { } appliedCommitTime &&
            appliedCommitTime == default;
        if (pending.Operation == PrivilegedBrokerOperation.Apply &&
            (pending.AppliedLedgerMutationAuthorized &&
                 (!pending.AppliedLedgerCommitTimeUtc.HasValue || appliedCommitTimeIsInvalid) ||
             !pending.AppliedLedgerMutationAuthorized &&
                 pending.AppliedLedgerCommitTimeUtc.HasValue) ||
            pending.Operation != PrivilegedBrokerOperation.Apply &&
            pending.AppliedLedgerCommitTimeUtc.HasValue)
        {
            throw new InvalidDataException(
                "Protected applied-ledger intent timestamp is invalid.");
        }
        if (pending.OriginalFirewallRules.Any(rule =>
                rule.BackendPort is < 1024 or > 65535 ||
                string.IsNullOrWhiteSpace(rule.Name) ||
                !rule.Enabled ||
                rule.Direction != 1 ||
                rule.Action != 0 ||
                rule.Protocol != 6))
        {
            throw new InvalidDataException("Protected firewall snapshot is invalid.");
        }
    }

    private void ValidateApplied(BrokerAppliedLedger applied)
    {
        if (applied.SchemaVersion != SchemaVersion ||
            !string.Equals(applied.OwnerSid, _ownerSid.Value, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Protected applied ledger identity is invalid.");
        }
        ValidateConfiguration(applied.Configuration);
        ValidateSelfIdentity(applied.TailscaleSelf);
    }

    private void ValidateReceipt(BrokerTransactionReceipt receipt)
    {
        if (receipt.SchemaVersion != SchemaVersion ||
            receipt.TransactionId == Guid.Empty ||
            !string.Equals(receipt.OwnerSid, _ownerSid.Value, StringComparison.Ordinal) ||
            !Enum.IsDefined(receipt.SourceOperation) ||
            receipt.Disposition is not (
                PrivilegedBrokerDisposition.Completed or
                PrivilegedBrokerDisposition.RolledBack) ||
            receipt.CompletedAtUtc == default)
        {
            throw new InvalidDataException("Protected transaction receipt is invalid.");
        }
    }

    private void WriteReceipt(
        BrokerPendingJournal pending,
        PrivilegedBrokerDisposition disposition)
    {
        var receipt = new BrokerTransactionReceipt(
            SchemaVersion,
            pending.TransactionId,
            _ownerSid.Value,
            pending.Operation,
            disposition,
            DateTimeOffset.UtcNow);
        ValidateReceipt(receipt);
        WriteAtomic(_receiptPath, receipt, overwrite: true);
    }

    private static bool AppliedLedgerEquals(
        BrokerAppliedLedger? left,
        BrokerAppliedLedger? right) =>
        left is null && right is null ||
        left is not null &&
        right is not null &&
        left.SchemaVersion == right.SchemaVersion &&
        string.Equals(left.OwnerSid, right.OwnerSid, StringComparison.Ordinal) &&
        left.Configuration == right.Configuration &&
        SelfIdentityEquals(left.TailscaleSelf, right.TailscaleSelf) &&
        left.CommittedAtUtc == right.CommittedAtUtc;

    private static bool ConfigurationAndSelfEquals(
        BrokerAppliedLedger applied,
        BrokerSystemConfiguration configuration,
        TailscaleSelfIdentity? self) =>
        applied.Configuration == configuration &&
        self is not null &&
        SelfIdentityEquals(applied.TailscaleSelf, self);

    private static bool SelfIdentityEquals(
        TailscaleSelfIdentity left,
        TailscaleSelfIdentity right) =>
        string.Equals(left.DnsName, right.DnsName, StringComparison.Ordinal) &&
        left.TailscaleIps.SequenceEqual(right.TailscaleIps, StringComparer.Ordinal);

    private static void ValidateConfiguration(BrokerSystemConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        if (configuration.PublicPort is < 1024 or > 65535 ||
            configuration.BackendPort is < 1024 or > 65535 ||
            configuration.PublicPort == configuration.BackendPort ||
            string.IsNullOrWhiteSpace(configuration.TailscalePath) ||
            !Path.IsPathFullyQualified(configuration.TailscalePath) ||
            !string.Equals(
                Path.GetFullPath(configuration.TailscalePath),
                configuration.TailscalePath,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Protected system configuration is invalid.");
        }
    }

    private static void ValidateSelfIdentity(TailscaleSelfIdentity identity)
    {
        if (!TailscaleIdentityValidator.IsValidDnsName(identity.DnsName) ||
            identity.TailscaleIps.Count == 0 ||
            identity.TailscaleIps.Any(ip =>
                !TailscaleIdentityValidator.IsTailnetAddress(ip)) ||
            !identity.TailscaleIps.SequenceEqual(
                identity.TailscaleIps.OrderBy(value => value, StringComparer.Ordinal),
                StringComparer.Ordinal))
        {
            throw new InvalidDataException("Protected Tailscale self identity is invalid.");
        }
    }
}

internal sealed record BrokerSystemConfiguration(
    int PublicPort,
    int BackendPort,
    string TailscalePath);

internal sealed record TailscaleSelfIdentity(
    string DnsName,
    IReadOnlyList<string> TailscaleIps);

internal sealed record BrokerAppliedLedger(
    int SchemaVersion,
    string OwnerSid,
    BrokerSystemConfiguration Configuration,
    TailscaleSelfIdentity TailscaleSelf,
    DateTimeOffset CommittedAtUtc);

internal sealed record BrokerPendingJournal(
    int SchemaVersion,
    Guid TransactionId,
    string OwnerSid,
    PrivilegedBrokerOperation Operation,
    PrivilegedBrokerInitiator Initiator,
    BrokerMutationPhase Phase,
    BrokerSystemConfiguration Target,
    BrokerSystemConfiguration? Previous,
    bool PreviousOwned,
    bool ExistingTargetOwned,
    bool MigrateLegacySystemState,
    ServeRootState? ObservedTargetRoot,
    ServeRootState? ObservedPreviousRoot,
    string? TargetUnrelatedHandlersJson,
    string? PreviousUnrelatedHandlersJson,
    IReadOnlyList<FirewallRuleIdentity> OriginalFirewallRules,
    LegacyTaskIdentity? LegacyTask,
    bool PreviousRouteMutationAuthorized,
    bool TargetRouteMutationAuthorized,
    bool FirewallMutationAuthorized,
    bool LegacyTaskMutationAuthorized,
    bool AppliedLedgerMutationAuthorized,
    TailscaleSelfIdentity? ObservedSelf,
    BrokerAppliedLedger? PreviousAppliedLedger,
    DateTimeOffset? AppliedLedgerCommitTimeUtc,
    BrokerSystemConfiguration? LegacyV121Configuration);

internal sealed record BrokerTransactionReceipt(
    int SchemaVersion,
    Guid TransactionId,
    string OwnerSid,
    PrivilegedBrokerOperation SourceOperation,
    PrivilegedBrokerDisposition Disposition,
    DateTimeOffset CompletedAtUtc);

internal sealed record FirewallRuleIdentity(
    string Name,
    int BackendPort,
    bool Enabled,
    int Direction,
    int Action,
    int Profiles,
    bool EdgeTraversal,
    int EdgeTraversalOptions,
    int Protocol,
    string? RemotePorts,
    string? LocalAddresses,
    string? RemoteAddresses,
    string? ApplicationName,
    string? LocalAppPackageId,
    IReadOnlyList<string> Interfaces,
    string? InterfaceTypes,
    string? ServiceName,
    int SecureFlags,
    string? LocalUserAuthorizedList,
    string? RemoteUserAuthorizedList,
    string? RemoteMachineAuthorizedList,
    string? Description,
    string? Grouping,
    string? IcmpTypesAndCodes);

internal sealed record LegacyTaskIdentity(
    string Name,
    string Xml);

internal enum BrokerMutationPhase
{
    Prepared,
    PreflightVerified,
    LegacyTaskMutationPrepared,
    LegacyTaskRemoved,
    PreviousRouteMutationPrepared,
    PreviousRouteRemoved,
    TargetRouteMutationPrepared,
    TargetRouteApplied,
    FirewallMutationPrepared,
    FirewallApplied,
    MutationsCompleted,
    AppliedLedgerCommitted,
    AppliedLedgerRollbackPrepared,
    AppliedLedgerRolledBack,
    RecoveryPrepared,
    UninstallRouteMutationPrepared,
    UninstallRouteRemoved,
    UninstallFirewallMutationPrepared,
    UninstallFirewallRemoved,
    UninstallTaskMutationPrepared,
    UninstallTaskRemoved,
    UninstallCompleted
}
