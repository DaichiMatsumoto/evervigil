using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using EverVigil.Core;
using EverVigil.Services;
using Microsoft.Win32;

namespace EverVigil.Infrastructure;

internal sealed class PendingSystemConfigurationStore
{
    internal const string FileName = "pending-system-configuration.json";
    internal const int CurrentSchemaVersion = 1;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    private readonly string _path;
    private readonly string _dataRoot;
    private readonly string _ownerSid;
    private readonly bool _validateProductionPath;

    private PendingSystemConfigurationStore(
        string path,
        string ownerSid,
        bool validateProductionPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        _path = Path.GetFullPath(path);
        _dataRoot = Path.GetDirectoryName(_path) ??
            throw new ArgumentException("The pending system journal has no parent directory.", nameof(path));
        _ownerSid = NormalizeSid(ownerSid);
        _validateProductionPath = validateProductionPath;
        if (!string.Equals(Path.GetFileName(_path), FileName, StringComparison.Ordinal))
        {
            throw new InvalidDataException("The pending system journal path has an unexpected file name.");
        }
    }

    internal string JournalPath => _path;

    internal bool Exists => File.Exists(_path);

    internal static PendingSystemConfigurationStore ForCurrentUser(DataPaths paths, string ownerSid)
    {
        ArgumentNullException.ThrowIfNull(paths);
        var store = new PendingSystemConfigurationStore(
            paths.PendingSystemConfigurationPath,
            ownerSid,
            validateProductionPath: paths.IsProductionDataRoot);
        if (paths.IsProductionDataRoot)
        {
            store.ValidatePathForOwner();
        }
        return store;
    }

    internal static PendingSystemConfigurationStore ForElevatedHelper(
        string journalPath,
        string ownerSid)
    {
        var store = new PendingSystemConfigurationStore(
            journalPath,
            ownerSid,
            validateProductionPath: true);
        store.ValidatePathForOwner();
        return store;
    }

    internal static PendingSystemConfigurationStore ForTests(
        string journalPath,
        string ownerSid) =>
        new(journalPath, ownerSid, validateProductionPath: false);

    internal PendingSystemConfiguration Begin(
        AppSettings target,
        AppSettings? previous,
        bool previousMappingOwned,
        bool existingTargetMappingOwned,
        PendingSystemConfigurationInitiator initiator =
            PendingSystemConfigurationInitiator.Interactive)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (File.Exists(_path))
        {
            throw new InvalidOperationException(
                "A pending system configuration transaction already exists and must be recovered first.");
        }

        var journal = new PendingSystemConfiguration(
            CurrentSchemaVersion,
            Guid.NewGuid(),
            _ownerSid,
            _dataRoot,
            initiator,
            ToIdentity(target),
            previous is null ? null : ToIdentity(previous),
            previousMappingOwned,
            existingTargetMappingOwned,
            PendingSystemConfigurationPhase.Prepared,
            ObservedTargetRouteOwnership: null,
            ObservedPreviousRouteOwnership: null,
            FirewallSnapshotCaptured: false,
            OriginalMainFirewallPort: null,
            OriginalTemporaryFirewallPort: null,
            PreviousRouteMutationAuthorized: false,
            TargetRouteMutationAuthorized: false,
            FirewallMutationAuthorized: false);
        Validate(journal);
        WriteAtomically(journal, overwrite: false);
        return journal;
    }

    internal PendingSystemConfiguration Load(Guid transactionId)
    {
        if (transactionId == Guid.Empty)
        {
            throw new ArgumentException("The pending system transaction ID is empty.", nameof(transactionId));
        }
        if (!File.Exists(_path))
        {
            throw new FileNotFoundException("The pending system configuration journal was not found.", _path);
        }
        EnsureRegularFile(_path);

        PendingSystemConfiguration journal;
        try
        {
            journal = JsonSerializer.Deserialize<PendingSystemConfiguration>(
                File.ReadAllText(_path, Encoding.UTF8),
                SerializerOptions) ?? throw new InvalidDataException(
                    "The pending system configuration journal is empty.");
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException(
                "The pending system configuration journal is invalid JSON.",
                exception);
        }

        Validate(journal);
        if (journal.TransactionId != transactionId)
        {
            throw new InvalidDataException(
                "The pending system configuration transaction ID does not match the request.");
        }
        return journal;
    }

    internal PendingSystemConfiguration LoadExisting()
    {
        if (!File.Exists(_path))
        {
            throw new FileNotFoundException("The pending system configuration journal was not found.", _path);
        }
        EnsureRegularFile(_path);
        PendingSystemConfiguration journal;
        try
        {
            journal = JsonSerializer.Deserialize<PendingSystemConfiguration>(
                File.ReadAllText(_path, Encoding.UTF8),
                SerializerOptions) ?? throw new InvalidDataException(
                    "The pending system configuration journal is empty.");
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException(
                "The pending system configuration journal is invalid JSON.",
                exception);
        }
        Validate(journal);
        return journal;
    }

    internal PendingSystemConfiguration RecordPreflight(
        Guid transactionId,
        ServeRootMappingOwnership targetOwnership,
        ServeRootMappingOwnership previousOwnership,
        int? originalMainFirewallPort,
        int? originalTemporaryFirewallPort)
    {
        var journal = Load(transactionId);
        RequirePhase(journal, PendingSystemConfigurationPhase.Prepared);
        var updated = journal with
        {
            Phase = PendingSystemConfigurationPhase.PreflightVerified,
            ObservedTargetRouteOwnership = targetOwnership,
            ObservedPreviousRouteOwnership = previousOwnership,
            FirewallSnapshotCaptured = true,
            OriginalMainFirewallPort = originalMainFirewallPort,
            OriginalTemporaryFirewallPort = originalTemporaryFirewallPort
        };
        WriteUpdated(updated);
        return updated;
    }

    internal PendingSystemConfiguration PreparePreviousRouteMutation(Guid transactionId)
    {
        var journal = Load(transactionId);
        RequirePhase(journal, PendingSystemConfigurationPhase.PreflightVerified);
        var updated = journal with
        {
            Phase = PendingSystemConfigurationPhase.PreviousRouteMutationPrepared,
            PreviousRouteMutationAuthorized = true
        };
        WriteUpdated(updated);
        return updated;
    }

    internal PendingSystemConfiguration MarkPreviousRouteRemoved(Guid transactionId)
    {
        var journal = Load(transactionId);
        RequirePhase(journal, PendingSystemConfigurationPhase.PreviousRouteMutationPrepared);
        var updated = journal with { Phase = PendingSystemConfigurationPhase.PreviousRouteRemoved };
        WriteUpdated(updated);
        return updated;
    }

    internal PendingSystemConfiguration PrepareTargetRouteMutation(Guid transactionId)
    {
        var journal = Load(transactionId);
        RequirePhase(
            journal,
            PendingSystemConfigurationPhase.PreflightVerified,
            PendingSystemConfigurationPhase.PreviousRouteRemoved);
        var updated = journal with
        {
            Phase = PendingSystemConfigurationPhase.TargetRouteMutationPrepared,
            TargetRouteMutationAuthorized = true
        };
        WriteUpdated(updated);
        return updated;
    }

    internal PendingSystemConfiguration MarkTargetRouteApplied(Guid transactionId)
    {
        var journal = Load(transactionId);
        RequirePhase(journal, PendingSystemConfigurationPhase.TargetRouteMutationPrepared);
        var updated = journal with { Phase = PendingSystemConfigurationPhase.TargetRouteApplied };
        WriteUpdated(updated);
        return updated;
    }

    internal PendingSystemConfiguration PrepareFirewallMutation(Guid transactionId)
    {
        var journal = Load(transactionId);
        RequirePhase(journal, PendingSystemConfigurationPhase.TargetRouteApplied);
        var updated = journal with
        {
            Phase = PendingSystemConfigurationPhase.FirewallMutationPrepared,
            FirewallMutationAuthorized = true
        };
        WriteUpdated(updated);
        return updated;
    }

    internal PendingSystemConfiguration MarkFirewallApplied(Guid transactionId)
    {
        var journal = Load(transactionId);
        RequirePhase(journal, PendingSystemConfigurationPhase.FirewallMutationPrepared);
        var updated = journal with { Phase = PendingSystemConfigurationPhase.FirewallApplied };
        WriteUpdated(updated);
        return updated;
    }

    internal PendingSystemConfiguration MarkMutationsCompleted(Guid transactionId)
    {
        var journal = Load(transactionId);
        RequirePhase(journal, PendingSystemConfigurationPhase.FirewallApplied);
        var updated = journal with { Phase = PendingSystemConfigurationPhase.MutationsCompleted };
        WriteUpdated(updated);
        return updated;
    }

    internal PendingSystemConfiguration MarkProtectedBrokerCompleted(Guid transactionId)
    {
        var journal = Load(transactionId);
        if (journal.Initiator != PendingSystemConfigurationInitiator.Interactive)
        {
            throw new InvalidDataException(
                "Only an interactive coordination journal may mirror protected broker completion.");
        }
        if (journal.Phase == PendingSystemConfigurationPhase.MutationsCompleted)
        {
            return journal;
        }
        if (journal.Phase != PendingSystemConfigurationPhase.Prepared)
        {
            throw new InvalidDataException(
                "Local coordination journal has unsupported legacy mutation evidence.");
        }
        var updated = journal with
        {
            Phase = PendingSystemConfigurationPhase.MutationsCompleted,
            ObservedTargetRouteOwnership = journal.ExistingTargetMappingOwned
                ? ServeRootMappingOwnership.Owned
                : ServeRootMappingOwnership.Unused,
            ObservedPreviousRouteOwnership = journal.PreviousMappingOwned
                ? ServeRootMappingOwnership.Owned
                : ServeRootMappingOwnership.Unused,
            FirewallSnapshotCaptured = true,
            TargetRouteMutationAuthorized = true,
            FirewallMutationAuthorized = true
        };
        WriteUpdated(updated);
        return updated;
    }

    internal PendingSystemConfiguration PrepareRecovery(Guid transactionId)
    {
        var journal = Load(transactionId);
        var updated = journal with { Phase = PendingSystemConfigurationPhase.RecoveryPrepared };
        WriteUpdated(updated);
        return updated;
    }

    internal void CancelUnmutated(Guid transactionId)
    {
        var journal = Load(transactionId);
        RequirePhase(
            journal,
            PendingSystemConfigurationPhase.Prepared,
            PendingSystemConfigurationPhase.PreflightVerified);
        DeleteJournal();
    }

    internal void CompleteRollback(Guid transactionId)
    {
        var journal = Load(transactionId);
        var hasMutationIntent = journal.PreviousRouteMutationAuthorized ||
            journal.TargetRouteMutationAuthorized ||
            journal.FirewallMutationAuthorized;
        if (hasMutationIntent &&
            journal.Phase != PendingSystemConfigurationPhase.RecoveryPrepared)
        {
            throw new InvalidOperationException(
                "A mutated pending system transaction must enter recovery before completion.");
        }
        DeleteJournal();
    }

    internal void CommitApplied(Guid transactionId, SystemConfigurationIdentity target)
    {
        ArgumentNullException.ThrowIfNull(target);
        var journal = Load(transactionId);
        RequirePhase(journal, PendingSystemConfigurationPhase.MutationsCompleted);
        if (journal.Target != target)
        {
            throw new InvalidDataException(
                "The applied system configuration does not match the pending transaction target.");
        }

        var appliedPath = Path.Combine(
            _dataRoot,
            SettingsStore.AppliedSystemConfigurationFileName);
        WriteJsonAtomically(
            appliedPath,
            new AppliedSystemConfiguration(
                target.PublicPort,
                target.BackendPort,
                target.TailscalePath),
            overwrite: true,
            transactionId: transactionId);
        File.Delete(Path.Combine(
            _dataRoot,
            SettingsStore.SystemConfigurationRequiredFileName));
        DeleteJournal();
    }

    internal void CommitApplied(Guid transactionId, AppSettings target) =>
        CommitApplied(transactionId, ToIdentity(target));

    private void WriteUpdated(PendingSystemConfiguration journal)
    {
        Validate(journal);
        WriteAtomically(journal, overwrite: true);
    }

    private void WriteAtomically(PendingSystemConfiguration journal, bool overwrite) =>
        WriteJsonAtomically(_path, journal, overwrite, journal.TransactionId);

    private void WriteJsonAtomically<T>(
        string destinationPath,
        T value,
        bool overwrite,
        Guid transactionId)
    {
        if (transactionId == Guid.Empty)
        {
            throw new ArgumentException(
                "The atomic write transaction ID is empty.",
                nameof(transactionId));
        }
        if (_validateProductionPath)
        {
            ValidatePathForOwner();
        }
        AccessControlService.RestrictDirectory(_dataRoot, _ownerSid);
        var temporaryPath = $"{destinationPath}.{transactionId:N}.tmp";
        if (File.Exists(temporaryPath))
        {
            EnsureRegularFile(temporaryPath);
            File.Delete(temporaryPath);
            if (File.Exists(temporaryPath))
            {
                throw new IOException(
                    "The transaction-owned atomic temporary file could not be removed.");
            }
        }
        try
        {
            using (var stream = AccessControlService.CreateRestrictedFile(
                       temporaryPath,
                       _ownerSid,
                       FileMode.CreateNew,
                       FileShare.None,
                       bufferSize: 4096,
                       FileOptions.WriteThrough))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false), leaveOpen: true))
            {
                writer.Write(JsonSerializer.Serialize(value, SerializerOptions));
                writer.Write('\n');
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }
            // The protected temporary is on the destination volume and already
            // carries the final ACL. Moving it is the last fallible commit point.
            File.Move(temporaryPath, destinationPath, overwrite);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private void DeleteJournal()
    {
        EnsureRegularFile(_path);
        File.Delete(_path);
        if (File.Exists(_path))
        {
            throw new IOException("The pending system configuration journal could not be removed.");
        }
    }

    private void Validate(PendingSystemConfiguration journal)
    {
        if (journal.SchemaVersion != CurrentSchemaVersion ||
            journal.TransactionId == Guid.Empty ||
            !Enum.IsDefined(journal.Initiator) ||
            !string.Equals(NormalizeSid(journal.OwnerSid), _ownerSid, StringComparison.Ordinal) ||
            !string.Equals(
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(journal.DataRoot)),
                Path.TrimEndingDirectorySeparator(_dataRoot),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("The pending system configuration journal identity is invalid.");
        }
        ValidateIdentity(journal.Target, "target");
        if (journal.Previous is not null)
        {
            ValidateIdentity(journal.Previous, "previous");
        }
        if (journal.PreviousMappingOwned && journal.Previous is null)
        {
            throw new InvalidDataException(
                "The pending journal claims ownership without a previous configuration.");
        }
        if (journal.ExistingTargetMappingOwned &&
            (!journal.PreviousMappingOwned ||
             journal.Previous?.PublicPort != journal.Target.PublicPort))
        {
            throw new InvalidDataException(
                "The pending journal target ownership is not derived from the previous configuration.");
        }
        if (journal.FirewallSnapshotCaptured &&
            (journal.OriginalMainFirewallPort is not null &&
             !IsValidPort(journal.OriginalMainFirewallPort.Value) ||
             journal.OriginalTemporaryFirewallPort is not null &&
             !IsValidPort(journal.OriginalTemporaryFirewallPort.Value)))
        {
            throw new InvalidDataException("The pending journal firewall snapshot is invalid.");
        }
        if (journal.Phase != PendingSystemConfigurationPhase.Prepared &&
            (!journal.FirewallSnapshotCaptured ||
             journal.ObservedTargetRouteOwnership is null ||
             journal.ObservedPreviousRouteOwnership is null))
        {
            throw new InvalidDataException("The pending journal has no durable preflight evidence.");
        }
        if (journal.PreviousRouteMutationAuthorized &&
            (!journal.PreviousMappingOwned || journal.Previous is null))
        {
            throw new InvalidDataException("The pending journal has an invalid previous-route intent.");
        }
        var phaseEvidenceValid = journal.Phase switch
        {
            PendingSystemConfigurationPhase.Prepared =>
                !journal.FirewallSnapshotCaptured &&
                journal.ObservedTargetRouteOwnership is null &&
                journal.ObservedPreviousRouteOwnership is null &&
                !journal.PreviousRouteMutationAuthorized &&
                !journal.TargetRouteMutationAuthorized &&
                !journal.FirewallMutationAuthorized,
            PendingSystemConfigurationPhase.PreflightVerified =>
                !journal.PreviousRouteMutationAuthorized &&
                !journal.TargetRouteMutationAuthorized &&
                !journal.FirewallMutationAuthorized,
            PendingSystemConfigurationPhase.PreviousRouteMutationPrepared or
            PendingSystemConfigurationPhase.PreviousRouteRemoved =>
                journal.PreviousRouteMutationAuthorized &&
                !journal.TargetRouteMutationAuthorized &&
                !journal.FirewallMutationAuthorized,
            PendingSystemConfigurationPhase.TargetRouteMutationPrepared or
            PendingSystemConfigurationPhase.TargetRouteApplied =>
                journal.TargetRouteMutationAuthorized &&
                !journal.FirewallMutationAuthorized,
            PendingSystemConfigurationPhase.FirewallMutationPrepared or
            PendingSystemConfigurationPhase.FirewallApplied or
            PendingSystemConfigurationPhase.MutationsCompleted =>
                journal.TargetRouteMutationAuthorized &&
                journal.FirewallMutationAuthorized,
            PendingSystemConfigurationPhase.RecoveryPrepared =>
                journal.PreviousRouteMutationAuthorized ||
                journal.TargetRouteMutationAuthorized ||
                journal.FirewallMutationAuthorized,
            _ => false
        };
        if (!phaseEvidenceValid)
        {
            throw new InvalidDataException(
                "The pending journal phase is inconsistent with its durable mutation evidence.");
        }
        if (journal.ObservedTargetRouteOwnership == ServeRootMappingOwnership.Unowned ||
            journal.ObservedTargetRouteOwnership == ServeRootMappingOwnership.Owned &&
            !journal.ExistingTargetMappingOwned ||
            journal.ObservedPreviousRouteOwnership == ServeRootMappingOwnership.Unowned)
        {
            throw new InvalidDataException(
                "The pending journal contains unowned preflight evidence.");
        }
        if (journal.PreviousRouteMutationAuthorized &&
            (journal.Previous is null ||
             journal.Previous.PublicPort == journal.Target.PublicPort ||
             journal.ObservedPreviousRouteOwnership != ServeRootMappingOwnership.Owned))
        {
            throw new InvalidDataException(
                "The pending journal previous-route mutation evidence is invalid.");
        }
    }

    private void ValidatePathForOwner()
    {
        var localAppData = ResolveLocalAppData(_ownerSid);
        var expectedCurrentRoot = Path.Combine(localAppData, "EverVigil");
        var expectedLegacyRoot = Path.Combine(
            localAppData,
            Compatibility.LegacyCompatibility.Application.DataRootRelativeToLocalAppData);
        if (!string.Equals(
                Path.TrimEndingDirectorySeparator(_dataRoot),
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(expectedCurrentRoot)),
                StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(
                Path.TrimEndingDirectorySeparator(_dataRoot),
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(expectedLegacyRoot)),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "The pending system journal is outside the invoking user's recognized data roots.");
        }
        EnsureNoReparsePoint(localAppData, _dataRoot);
        if (File.Exists(_path))
        {
            EnsureRegularFile(_path);
        }
    }

    private static string ResolveLocalAppData(string ownerSid)
    {
        var normalizedSid = NormalizeSid(ownerSid);
        var profilePath = ReadProfilePath(normalizedSid);
        string? configuredPath = null;
        using (var userShellFolders = Registry.Users.OpenSubKey(
                   $@"{normalizedSid}\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"))
        {
            configuredPath = userShellFolders?.GetValue(
                "Local AppData",
                null,
                RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        }

        if (string.IsNullOrWhiteSpace(configuredPath))
        {
            return Path.Combine(profilePath, "AppData", "Local");
        }
        var profileRoot = Path.GetPathRoot(profilePath) ??
            throw new InvalidDataException("The invoking user's profile root is unavailable.");
        var homeDrive = Path.TrimEndingDirectorySeparator(profileRoot);
        var homePath = profilePath[homeDrive.Length..];
        configuredPath = configuredPath
            .Replace("%USERPROFILE%", profilePath, StringComparison.OrdinalIgnoreCase)
            .Replace("%HOMEDRIVE%", homeDrive, StringComparison.OrdinalIgnoreCase)
            .Replace("%HOMEPATH%", homePath, StringComparison.OrdinalIgnoreCase)
            .Replace(
                "%USERNAME%",
                Path.GetFileName(profilePath),
                StringComparison.OrdinalIgnoreCase);
        configuredPath = Environment.ExpandEnvironmentVariables(configuredPath);
        if (configuredPath.Contains('%', StringComparison.Ordinal) ||
            !Path.IsPathFullyQualified(configuredPath))
        {
            throw new InvalidDataException(
                "The invoking user's Local AppData registry path could not be resolved safely.");
        }
        return Path.GetFullPath(configuredPath);
    }

    private static string ReadProfilePath(string ownerSid)
    {
        using var profileKey = Registry.LocalMachine.OpenSubKey(
            $@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{ownerSid}");
        var raw = profileKey?.GetValue(
            "ProfileImagePath",
            null,
            RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        if (string.IsNullOrWhiteSpace(raw))
        {
            throw new InvalidDataException("The invoking user's profile path could not be resolved.");
        }
        var expanded = Environment.ExpandEnvironmentVariables(raw);
        if (!Path.IsPathFullyQualified(expanded))
        {
            throw new InvalidDataException("The invoking user's profile path is not absolute.");
        }
        return Path.GetFullPath(expanded);
    }

    private static void EnsureNoReparsePoint(string basePath, string targetPath)
    {
        var expectedBase = Path.TrimEndingDirectorySeparator(Path.GetFullPath(basePath));
        var expectedTarget = Path.TrimEndingDirectorySeparator(Path.GetFullPath(targetPath));
        if (!expectedTarget.StartsWith(
                expectedBase + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(expectedTarget, expectedBase, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("The data root is outside Local AppData.");
        }

        var current = expectedTarget;
        while (current.Length >= expectedBase.Length)
        {
            if (Directory.Exists(current) &&
                (new DirectoryInfo(current).Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidDataException(
                    $"The pending system journal path contains a reparse point: {current}");
            }
            if (string.Equals(current, expectedBase, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
            current = Path.GetDirectoryName(current) ??
                throw new InvalidDataException("The data root ancestry is invalid.");
        }
    }

    private static void EnsureRegularFile(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException(
                "The pending system configuration journal is missing or is a reparse point.");
        }
    }

    private static void ValidateIdentity(SystemConfigurationIdentity identity, string description)
    {
        ArgumentNullException.ThrowIfNull(identity);
        if (!IsValidPort(identity.PublicPort) ||
            !IsValidPort(identity.BackendPort) ||
            identity.PublicPort == identity.BackendPort ||
            string.IsNullOrWhiteSpace(identity.TailscalePath) ||
            identity.TailscalePath.Contains('"') ||
            !Path.IsPathFullyQualified(identity.TailscalePath) ||
            !string.Equals(
                Path.GetFullPath(identity.TailscalePath),
                identity.TailscalePath,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                $"The pending system configuration {description} identity is invalid.");
        }
    }

    private static bool IsValidPort(int port) => port is >= 1024 and <= 65535;

    private static string NormalizeSid(string ownerSid)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerSid);
        try
        {
            return new SecurityIdentifier(ownerSid).Value;
        }
        catch (ArgumentException exception)
        {
            throw new InvalidDataException("The pending system configuration owner SID is invalid.", exception);
        }
    }

    private static SystemConfigurationIdentity ToIdentity(AppSettings settings) =>
        new(
            settings.PublicPort,
            settings.BackendPort,
            Path.GetFullPath(settings.TailscalePath));

    private static void RequirePhase(
        PendingSystemConfiguration journal,
        params PendingSystemConfigurationPhase[] expected)
    {
        if (!expected.Contains(journal.Phase))
        {
            throw new InvalidOperationException(
                $"Pending system transaction phase '{journal.Phase}' was unexpected.");
        }
    }
}

internal sealed record SystemConfigurationIdentity(
    int PublicPort,
    int BackendPort,
    string TailscalePath);

internal sealed record PendingSystemConfiguration(
    int SchemaVersion,
    Guid TransactionId,
    string OwnerSid,
    string DataRoot,
    PendingSystemConfigurationInitiator Initiator,
    SystemConfigurationIdentity Target,
    SystemConfigurationIdentity? Previous,
    bool PreviousMappingOwned,
    bool ExistingTargetMappingOwned,
    PendingSystemConfigurationPhase Phase,
    ServeRootMappingOwnership? ObservedTargetRouteOwnership,
    ServeRootMappingOwnership? ObservedPreviousRouteOwnership,
    bool FirewallSnapshotCaptured,
    int? OriginalMainFirewallPort,
    int? OriginalTemporaryFirewallPort,
    bool PreviousRouteMutationAuthorized,
    bool TargetRouteMutationAuthorized,
    bool FirewallMutationAuthorized);

internal enum PendingSystemConfigurationPhase
{
    Prepared,
    PreflightVerified,
    PreviousRouteMutationPrepared,
    PreviousRouteRemoved,
    TargetRouteMutationPrepared,
    TargetRouteApplied,
    FirewallMutationPrepared,
    FirewallApplied,
    MutationsCompleted,
    RecoveryPrepared
}

internal enum PendingSystemConfigurationInitiator
{
    Interactive,
    Installer
}
