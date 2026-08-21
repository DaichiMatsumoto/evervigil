using System.Security.AccessControl;
using System.Security.Principal;
using EverVigil.Broker.Protocol;
using EverVigil.Core;
using EverVigil.Infrastructure;

namespace EverVigil.Services;

internal static class SystemConfigurationService
{
    private static readonly TimeSpan SystemTransactionTimeout = TimeSpan.FromMinutes(10);
    internal const string SystemTransactionMutexName =
        ProductIdentity.SystemTransactionMutexName;

    public static async Task ApplyElevatedAsync(
        AppSettings settings,
        AppSettings? previousSettings = null,
        bool previousMappingOwned = false,
        bool existingTargetMappingOwned = false)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ValidateFixedConfiguration(settings);
        var ownerSid = WindowsIdentity.GetCurrent().User?.Value ??
            throw new InvalidOperationException("The current Windows user SID is unavailable.");
        var paths = DataPaths.Create();
        var pendingStore = PendingSystemConfigurationStore.ForCurrentUser(paths, ownerSid);

        var existing = RunSystemTransaction(() =>
            pendingStore.Exists ? pendingStore.LoadExisting() : null);
        if (existing is not null)
        {
            if (existing.Initiator == PendingSystemConfigurationInitiator.Installer)
            {
                throw new InvalidOperationException(
                    "An installer-owned system transaction is pending. Finish or roll back setup first.");
            }
            var response = await PrivilegedBrokerClient.InvokeAsync(
                    existing.TransactionId,
                    PrivilegedBrokerOperation.Recover)
                .ConfigureAwait(true);
            var recoveredTargetMatchesRequest = RunSystemTransaction(() =>
                ReconcileLocalRecovery(pendingStore, existing, response, settings));
            if (recoveredTargetMatchesRequest)
            {
                return;
            }
        }

        var pending = RunSystemTransaction(() => pendingStore.Begin(
            settings,
            previousSettings,
            previousMappingOwned,
            existingTargetMappingOwned));
        try
        {
            var response = await PrivilegedBrokerClient.InvokeAsync(
                    pending.TransactionId,
                    PrivilegedBrokerOperation.Apply,
                    settings.PublicPort,
                    settings.BackendPort)
                .ConfigureAwait(true);
            if (!response.Success ||
                response.Disposition != PrivilegedBrokerDisposition.Completed)
            {
                HandleFailedBrokerResponse(pendingStore, pending.TransactionId, response);
            }
            RunSystemTransaction(() =>
                pendingStore.MarkProtectedBrokerCompleted(pending.TransactionId));
        }
        catch (OperationCanceledException)
        {
            RunSystemTransaction(() =>
            {
                if (pendingStore.Exists)
                {
                    var current = pendingStore.Load(pending.TransactionId);
                    if (current.Phase == PendingSystemConfigurationPhase.Prepared)
                    {
                        pendingStore.CancelUnmutated(pending.TransactionId);
                    }
                }
            });
            throw;
        }
    }

    internal static void ExecuteUnderSystemTransaction(Action action) =>
        RunSystemTransaction(action);

    private static bool ReconcileLocalRecovery(
        PendingSystemConfigurationStore pendingStore,
        PendingSystemConfiguration existing,
        PrivilegedBrokerResponse response,
        AppSettings requested)
    {
        if (!pendingStore.Exists)
        {
            throw new SystemConfigurationRollbackException(
                "Local system transaction disappeared during protected recovery.");
        }
        if (!response.Success)
        {
            throw new SystemConfigurationRollbackException(response.Message);
        }
        switch (response.Disposition)
        {
            case PrivilegedBrokerDisposition.Completed:
                pendingStore.MarkProtectedBrokerCompleted(existing.TransactionId);
                if (IdentityMatches(existing.Target, requested))
                {
                    return true;
                }
                pendingStore.CommitApplied(existing.TransactionId, existing.Target);
                return false;
            case PrivilegedBrokerDisposition.RolledBack:
                pendingStore.CompleteRollback(existing.TransactionId);
                return false;
            case PrivilegedBrokerDisposition.NoChange:
                if (existing.Phase != PendingSystemConfigurationPhase.Prepared)
                {
                    throw new SystemConfigurationRollbackException(
                        "Protected broker has no transaction matching mutated local evidence.");
                }
                pendingStore.CancelUnmutated(existing.TransactionId);
                return false;
            default:
                throw new SystemConfigurationRollbackException(
                    "Protected recovery returned an unsupported disposition.");
        }
    }

    private static void HandleFailedBrokerResponse(
        PendingSystemConfigurationStore pendingStore,
        Guid transactionId,
        PrivilegedBrokerResponse response)
    {
        if (response.Success && response.Disposition == PrivilegedBrokerDisposition.RolledBack)
        {
            RunSystemTransaction(() => pendingStore.CompleteRollback(transactionId));
            throw new InvalidOperationException("Protected system configuration was rolled back.");
        }
        throw new SystemConfigurationRollbackException(response.Message);
    }

    private static void ValidateFixedConfiguration(AppSettings settings)
    {
        if (settings.PublicPort is < 1024 or > 65535 ||
            settings.BackendPort is < 1024 or > 65535 ||
            settings.PublicPort == settings.BackendPort)
        {
            throw new ArgumentOutOfRangeException(
                nameof(settings),
                "System configuration ports are invalid.");
        }
        var expected = Path.GetFullPath(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "Tailscale",
            "tailscale.exe"));
        if (!string.Equals(
                Path.GetFullPath(settings.TailscalePath),
                expected,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "Tailscale must use the fixed protected Program Files installation.");
        }
    }

    private static bool IdentityMatches(
        SystemConfigurationIdentity identity,
        AppSettings settings) =>
        identity.PublicPort == settings.PublicPort &&
        identity.BackendPort == settings.BackendPort &&
        string.Equals(
            identity.TailscalePath,
            Path.GetFullPath(settings.TailscalePath),
            StringComparison.OrdinalIgnoreCase);

    private static void RunSystemTransaction(Action action) =>
        RunSystemTransaction(() =>
        {
            action();
            return true;
        });

    private static T RunSystemTransaction<T>(Func<T> action)
    {
        ArgumentNullException.ThrowIfNull(action);
        using var transactionMutex = CreateSystemTransactionMutex();
        var lockTaken = false;
        try
        {
            try
            {
                lockTaken = transactionMutex.WaitOne(SystemTransactionTimeout);
            }
            catch (AbandonedMutexException)
            {
                lockTaken = true;
            }
            if (!lockTaken)
            {
                throw new TimeoutException(
                    "Another EverVigil system transaction did not finish within 10 minutes.");
            }
            return action();
        }
        finally
        {
            if (lockTaken)
            {
                transactionMutex.ReleaseMutex();
            }
        }
    }

    private static Mutex CreateSystemTransactionMutex() =>
        CreateSystemTransactionMutex(SystemTransactionMutexName);

    internal static Mutex CreateSystemTransactionMutex(string name)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        const MutexRights requiredRights = MutexRights.Synchronize | MutexRights.Modify;
        try
        {
            return MutexAcl.OpenExisting(name, requiredRights);
        }
        catch (WaitHandleCannotBeOpenedException)
        {
            // Create the mutex below. Another process may win that race.
        }

        var security = new MutexSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new MutexAccessRule(
            new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null),
            requiredRights,
            AccessControlType.Allow));
        foreach (var identity in new[]
                 {
                     new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                     new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null)
                 })
        {
            security.AddAccessRule(new MutexAccessRule(
                identity,
                MutexRights.FullControl,
                AccessControlType.Allow));
        }
        try
        {
            return MutexAcl.Create(
                initiallyOwned: false,
                name,
                out _,
                security);
        }
        catch (UnauthorizedAccessException)
        {
            return MutexAcl.OpenExisting(name, requiredRights);
        }
    }
}

internal enum ServeRootMappingOwnership
{
    Unused,
    Owned,
    Unowned
}

internal sealed class SystemConfigurationRollbackException : Exception
{
    public SystemConfigurationRollbackException(string message)
        : base(message)
    {
    }

    public SystemConfigurationRollbackException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
