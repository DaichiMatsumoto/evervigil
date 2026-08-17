using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using EverVigil.Broker.Protocol;

namespace EverVigil.Broker;

internal static class PrivilegedSystemConfiguration
{
    internal static PrivilegedBrokerResponse Execute(
        PrivilegedBrokerRequest request,
        string authenticatedOwnerSid) =>
        BrokerSystemMutex.Execute(() => ExecuteUnderLock(request, authenticatedOwnerSid));

    private static PrivilegedBrokerResponse ExecuteUnderLock(
        PrivilegedBrokerRequest request,
        string ownerSid)
    {
        var store = new BrokerStateStore(ownerSid);
        return ExecuteWithStore(request, ownerSid, store);
    }

    internal static PrivilegedBrokerResponse ExecuteForTests(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store) =>
        ExecuteWithStore(request, ownerSid, store);

    private static PrivilegedBrokerResponse ExecuteWithStore(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store)
    {
        var otherAppliedLedgers = request.Operation == PrivilegedBrokerOperation.Status
            ? Array.Empty<BrokerAppliedLedger>()
            : store.LoadOtherOwnerAppliedLedgersForGlobalMutation();
        if (TryReplayCompleted(request, store) is { } replay)
        {
            return replay;
        }
        return request.Operation switch
        {
            PrivilegedBrokerOperation.Apply =>
                Apply(request, ownerSid, store, otherAppliedLedgers),
            PrivilegedBrokerOperation.Commit => Commit(request, ownerSid, store),
            PrivilegedBrokerOperation.Rollback => Rollback(request, ownerSid, store),
            PrivilegedBrokerOperation.Recover => Recover(request, ownerSid, store),
            PrivilegedBrokerOperation.UninstallCleanup =>
                UninstallCleanup(request, ownerSid, store, otherAppliedLedgers),
            PrivilegedBrokerOperation.LegacyTaskCleanup =>
                CleanupLegacyTask(request, ownerSid, store),
            PrivilegedBrokerOperation.Status => Status(request, store),
            _ => throw new BrokerRefusalException(
                "Privileged broker operation is not allow-listed.",
                PrivilegedBrokerErrorCode.UnsupportedOperation)
        };
    }

    private static PrivilegedBrokerResponse? TryReplayCompleted(
        PrivilegedBrokerRequest request,
        BrokerStateStore store)
    {
        var receipt = store.TryLoadReceipt(request.TransactionId);
        if (receipt is null)
        {
            return null;
        }
        store.CleanupPendingAfterReceipt(receipt);
        var compatible = request.Operation == receipt.SourceOperation ||
            receipt.SourceOperation == PrivilegedBrokerOperation.Apply &&
            request.Operation is (
                PrivilegedBrokerOperation.Commit or
                PrivilegedBrokerOperation.Recover) ||
            receipt.Disposition == PrivilegedBrokerDisposition.RolledBack &&
            request.Operation is (
                PrivilegedBrokerOperation.Rollback or
                PrivilegedBrokerOperation.Recover);
        if (!compatible)
        {
            throw new BrokerRefusalException(
                "Protected transaction ID was already finalized by another operation.",
                PrivilegedBrokerErrorCode.PendingTransactionMismatch);
        }
        if (receipt.SourceOperation == PrivilegedBrokerOperation.UninstallCleanup &&
            request.Operation == PrivilegedBrokerOperation.UninstallCleanup)
        {
            return null;
        }
        return Success(
            request,
            receipt.Disposition,
            "Protected transaction result was replayed from its durable receipt.");
    }

    private static PrivilegedBrokerResponse Apply(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store,
        IReadOnlyList<BrokerAppliedLedger> otherAppliedLedgers)
    {
        if (store.PendingExists)
        {
            var existingPending = store.LoadExistingPending();
            if (existingPending.TransactionId == request.TransactionId &&
                existingPending.Operation == PrivilegedBrokerOperation.Apply)
            {
                return ResumeExistingApply(
                    request,
                    ownerSid,
                    store,
                    existingPending,
                    otherAppliedLedgers);
            }
            throw new BrokerRefusalException(
                "Another protected system transaction requires recovery.",
                PrivilegedBrokerErrorCode.PendingTransactionMismatch,
                pendingRecovery: true);
        }

        var tailscale = TrustedTailscale.Resolve(ownerSid);
        var selfIdentity = tailscale.ReadSelfIdentity();
        var applied = store.LoadApplied();
        if (applied is not null &&
            !string.Equals(
                applied.Configuration.TailscalePath,
                tailscale.Path,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new BrokerRefusalException(
                "Protected applied Tailscale path does not match the fixed trusted path.",
                PrivilegedBrokerErrorCode.OwnershipMismatch);
        }

        var target = new BrokerSystemConfiguration(
            request.PublicPort!.Value,
            request.BackendPort!.Value,
            tailscale.Path);
        var targetRouteShared = RequireGlobalApplyCompatibility(
            target,
            selfIdentity,
            applied,
            otherAppliedLedgers);

        var legacyTaskService = new LegacyScheduledTask(ownerSid);
        var legacyTask = legacyTaskService.CaptureIfOwned();
        if (legacyTask is not null && !request.MigrateLegacySystemState)
        {
            throw new BrokerRefusalException(
                "A fixed legacy task exists outside an authorized installer migration.",
                PrivilegedBrokerErrorCode.OwnershipMismatch);
        }

        var previous = applied?.Configuration;
        BrokerSystemConfiguration? legacyV121Configuration = null;
        if (request.MigrateLegacySystemState)
        {
            legacyV121Configuration = LegacyV121Evidence.RequireConfiguration(
                ownerSid,
                request.TransactionId,
                tailscale.Path);
        }
        if (previous is null && request.MigrateLegacySystemState)
        {
            var legacySnapshot = TailscaleServeStatus.ReadRootSnapshot(
                tailscale.ReadServeStatus(),
                legacyV121Configuration!.PublicPort,
                [legacyV121Configuration.BackendPort]);
            if (legacySnapshot.FunnelActive)
            {
                throw new BrokerRefusalException(
                    "Tailscale Funnel was detected on the fixed legacy port.",
                    PrivilegedBrokerErrorCode.FunnelDetected);
            }
            if (legacySnapshot.State == ServeRootState.Unowned)
            {
                throw new BrokerRefusalException(
                    "Legacy Tailscale route does not match the fixed v1 identity.",
                    PrivilegedBrokerErrorCode.OwnershipMismatch);
            }
            if (legacySnapshot.State == ServeRootState.Owned)
            {
                previous = legacyV121Configuration;
            }
        }

        var pending = store.Begin(
            request,
            target,
            previous,
            legacyTask,
            selfIdentity,
            legacyV121Configuration);
        try
        {
            pending = RecordApplyPreflight(
                store,
                pending,
                tailscale,
                new BrokerFirewall(ownerSid),
                applied,
                request.MigrateLegacySystemState,
                targetRouteShared);
            pending = ApplyMutations(
                store,
                pending,
                tailscale,
                new BrokerFirewall(ownerSid),
                legacyTaskService,
                targetRouteShared);
            if (request.Initiator == PrivilegedBrokerInitiator.Interactive)
            {
                CommitCompleted(store, pending, tailscale, new BrokerFirewall(ownerSid));
            }
            return Success(
                request,
                PrivilegedBrokerDisposition.Completed,
                "Protected system configuration completed.");
        }
        catch (Exception applyException)
        {
            try
            {
                if (store.PendingExists)
                {
                    RollbackPending(
                        store,
                        store.LoadExistingPending(),
                        ownerSid);
                }
            }
            catch (Exception rollbackException)
            {
                throw new BrokerRefusalException(
                    "System configuration failed and protected rollback requires recovery.",
                    PrivilegedBrokerErrorCode.RecoveryRequired,
                    pendingRecovery: true,
                    new AggregateException(applyException, rollbackException));
            }
            throw new BrokerRefusalException(
                "System configuration was refused and the protected previous state was restored.",
                MapErrorCode(applyException),
                innerException: applyException);
        }
    }

    private static PrivilegedBrokerResponse ResumeExistingApply(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store,
        BrokerPendingJournal pending,
        IReadOnlyList<BrokerAppliedLedger> otherAppliedLedgers)
    {
        _ = RequireGlobalApplyCompatibility(
            pending.Target,
            pending.ObservedSelf ??
                throw new InvalidDataException(
                    "Protected Apply recovery is missing Tailscale Self identity."),
            store.LoadApplied(),
            otherAppliedLedgers);
        if (pending.Phase is (
                BrokerMutationPhase.MutationsCompleted or
                BrokerMutationPhase.AppliedLedgerCommitted))
        {
            if (pending.Initiator == PrivilegedBrokerInitiator.Interactive)
            {
                var tailscale = TrustedTailscale.Resolve(ownerSid);
                CommitCompleted(store, pending, tailscale, new BrokerFirewall(ownerSid));
            }
            return Success(
                request,
                PrivilegedBrokerDisposition.Completed,
                "Existing protected Apply transaction is complete.");
        }
        RollbackPending(store, pending, ownerSid);
        throw new BrokerRefusalException(
            "Interrupted Apply was rolled back; retry with a new transaction ID.",
            PrivilegedBrokerErrorCode.RecoveryRequired);
    }

    private static BrokerPendingJournal RecordApplyPreflight(
        BrokerStateStore store,
        BrokerPendingJournal pending,
        TrustedTailscale tailscale,
        BrokerFirewall firewall,
        BrokerAppliedLedger? applied,
        bool legacyTaskAuthorized,
        bool targetRouteShared)
    {
        var status = tailscale.ReadServeStatus();
        var targetOwnedBackends = targetRouteShared
            ? new[] { pending.Target.BackendPort }
            : pending.Previous is not null &&
                                   pending.Previous.PublicPort == pending.Target.PublicPort
            ? new[] { pending.Previous.BackendPort }
            : Array.Empty<int>();
        var targetRoot = TailscaleServeStatus.ReadRootSnapshot(
            status,
            pending.Target.PublicPort,
            targetOwnedBackends);
        if (targetRoot.FunnelActive)
        {
            throw new BrokerRefusalException(
                "Tailscale Funnel was detected on the target port.",
                PrivilegedBrokerErrorCode.FunnelDetected);
        }
        if (targetRoot.State == ServeRootState.Unowned)
        {
            throw new BrokerRefusalException(
                "Target Tailscale Serve root is not protected-owned or absent.",
                PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
        if (targetRouteShared && targetRoot.State != ServeRootState.Owned)
        {
            throw new BrokerRefusalException(
                "Another protected owner shares the target route, but the live root is absent.",
                PrivilegedBrokerErrorCode.OwnershipMismatch);
        }

        var previousRoot = new ServeRootSnapshot(
            ServeRootState.RootAbsent,
            FunnelActive: false,
            UnrelatedHandlersJson: "{}");
        if (pending.Previous is not null)
        {
            previousRoot = pending.Previous.PublicPort == pending.Target.PublicPort
                ? targetRoot
                : TailscaleServeStatus.ReadRootSnapshot(
                    status,
                    pending.Previous.PublicPort,
                    [pending.Previous.BackendPort]);
            if (previousRoot.FunnelActive)
            {
                throw new BrokerRefusalException(
                    "Tailscale Funnel was detected on the previous port.",
                    PrivilegedBrokerErrorCode.FunnelDetected);
            }
            if (previousRoot.State != ServeRootState.Owned)
            {
                throw new BrokerRefusalException(
                    "Previous Tailscale Serve root does not match protected ownership.",
                    PrivilegedBrokerErrorCode.OwnershipMismatch);
            }
        }

        var firewallSnapshot = firewall.CapturePreflight(
            applied,
            allowLegacyMigration: legacyTaskAuthorized,
            legacyBackendPort: pending.LegacyV121Configuration?.BackendPort ?? 3457);
        return store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.PreflightVerified,
            ObservedTargetRoot = targetRoot.State,
            ObservedPreviousRoot = previousRoot.State,
            TargetUnrelatedHandlersJson = targetRoot.UnrelatedHandlersJson,
            PreviousUnrelatedHandlersJson = previousRoot.UnrelatedHandlersJson,
            OriginalFirewallRules = firewallSnapshot
        });
    }

    private static BrokerPendingJournal ApplyMutations(
        BrokerStateStore store,
        BrokerPendingJournal pending,
        TrustedTailscale tailscale,
        BrokerFirewall firewall,
        LegacyScheduledTask legacyTaskService,
        bool targetRouteShared)
    {
        if (pending.LegacyTask is not null)
        {
            var legacyTaskSnapshot = pending.LegacyTask;
            pending = store.Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.LegacyTaskMutationPrepared,
                LegacyTaskMutationAuthorized = true
            });
            legacyTaskService.RemoveOwned(legacyTaskSnapshot);
            pending = store.Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.LegacyTaskRemoved
            });
        }

        if (!targetRouteShared)
        {
            RequireBackendPortAvailable(pending.Target.BackendPort);
        }
        if (pending.Previous is not null &&
            pending.Previous.PublicPort != pending.Target.PublicPort)
        {
            var previous = pending.Previous;
            pending = store.Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.PreviousRouteMutationPrepared,
                PreviousRouteMutationAuthorized = true
            });
            tailscale.RemoveOwnedRoot(
                previous.PublicPort,
                previous.BackendPort,
                pending.PreviousUnrelatedHandlersJson ??
                    throw new InvalidDataException("Previous unrelated handler snapshot is missing."));
            pending = store.Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.PreviousRouteRemoved
            });
        }

        if (!targetRouteShared)
        {
            pending = store.Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.TargetRouteMutationPrepared,
                TargetRouteMutationAuthorized = true
            });
            tailscale.ApplyRoot(
                pending.Target.PublicPort,
                pending.Target.BackendPort,
                pending.ObservedTargetRoot ??
                    throw new InvalidDataException("Target route prestate is missing."),
                pending.ObservedTargetRoot == ServeRootState.Owned
                    ? pending.Previous?.BackendPort ??
                        throw new InvalidDataException("Owned target prestate has no previous backend.")
                    : null,
                pending.TargetUnrelatedHandlersJson ??
                    throw new InvalidDataException("Target unrelated handler snapshot is missing."));
            pending = store.Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.TargetRouteApplied
            });
        }

        pending = store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.FirewallMutationPrepared,
            FirewallMutationAuthorized = true
        });
        firewall.ConfigureTarget(
            pending.Target.BackendPort,
            pending.OriginalFirewallRules,
            removeLegacy: pending.MigrateLegacySystemState);
        pending = store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.FirewallApplied
        });
        return store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.MutationsCompleted
        });
    }

    private static PrivilegedBrokerResponse Commit(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store)
    {
        var pending = store.LoadPending(request.TransactionId);
        if (pending.Operation != PrivilegedBrokerOperation.Apply ||
            pending.Initiator != PrivilegedBrokerInitiator.Installer ||
            pending.Phase is not (
                BrokerMutationPhase.MutationsCompleted or
                BrokerMutationPhase.AppliedLedgerCommitted))
        {
            throw new BrokerRefusalException(
                "Protected transaction is not an installer Apply ready for commit.",
                PrivilegedBrokerErrorCode.PendingTransactionMismatch,
                pendingRecovery: true);
        }
        var tailscale = TrustedTailscale.Resolve(ownerSid);
        CommitCompleted(store, pending, tailscale, new BrokerFirewall(ownerSid));
        return Success(
            request,
            PrivilegedBrokerDisposition.Completed,
            "Protected installer system transaction committed.");
    }

    private static PrivilegedBrokerResponse Rollback(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store)
    {
        if (!store.PendingExists)
        {
            return Success(
                request,
                PrivilegedBrokerDisposition.NoChange,
                "No protected pending transaction exists to roll back.");
        }
        var pending = store.LoadPending(request.TransactionId);
        RollbackPending(store, pending, ownerSid);
        return Success(
            request,
            PrivilegedBrokerDisposition.RolledBack,
            "Protected system transaction rolled back.");
    }

    private static PrivilegedBrokerResponse Recover(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store)
    {
        if (!store.PendingExists)
        {
            return Success(
                request,
                PrivilegedBrokerDisposition.NoChange,
                "No protected pending transaction exists to recover.");
        }
        var pending = store.LoadPending(request.TransactionId);
        if (pending.Operation == PrivilegedBrokerOperation.UninstallCleanup)
        {
            ResumeUninstall(store, pending, ownerSid);
            return Success(
                request,
                PrivilegedBrokerDisposition.Completed,
                "Protected uninstall cleanup resumed and completed.");
        }
        if (pending.Operation != PrivilegedBrokerOperation.Apply)
        {
            throw new BrokerRefusalException(
                "Protected pending operation cannot be recovered by this verb.",
                PrivilegedBrokerErrorCode.PendingTransactionMismatch,
                pendingRecovery: true);
        }
        if (pending.Phase is (
                BrokerMutationPhase.MutationsCompleted or
                BrokerMutationPhase.AppliedLedgerCommitted))
        {
            var tailscale = TrustedTailscale.Resolve(ownerSid);
            CommitCompleted(store, pending, tailscale, new BrokerFirewall(ownerSid));
            return Success(
                request,
                PrivilegedBrokerDisposition.Completed,
                "Completed protected Apply transaction was finalized.");
        }
        RollbackPending(store, pending, ownerSid);
        return Success(
            request,
            PrivilegedBrokerDisposition.RolledBack,
            "Interrupted protected Apply transaction was rolled back.");
    }

    private static void CommitCompleted(
        BrokerStateStore store,
        BrokerPendingJournal pending,
        TrustedTailscale tailscale,
        BrokerFirewall firewall)
    {
        VerifyCompleted(pending, tailscale, firewall);
        pending = store.Update(pending.TransactionId, current => current with
        {
            AppliedLedgerMutationAuthorized = true,
            AppliedLedgerCommitTimeUtc = current.AppliedLedgerCommitTimeUtc ??
                DateTimeOffset.UtcNow
        });
        store.CommitApplied(pending);
    }

    private static void VerifyCompleted(
        BrokerPendingJournal pending,
        TrustedTailscale tailscale,
        BrokerFirewall firewall)
    {
        var targetRoot = TailscaleServeStatus.ReadRootSnapshot(
            tailscale.ReadServeStatus(),
            pending.Target.PublicPort,
            [pending.Target.BackendPort]);
        if (targetRoot.FunnelActive ||
            targetRoot.State != ServeRootState.Owned ||
            !string.Equals(
                targetRoot.UnrelatedHandlersJson,
                pending.TargetUnrelatedHandlersJson,
                StringComparison.Ordinal))
        {
            throw new BrokerRefusalException(
                "Completed Tailscale root no longer matches protected target identity.",
                targetRoot.FunnelActive
                    ? PrivilegedBrokerErrorCode.FunnelDetected
                    : PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
        firewall.VerifyTarget(
            pending.Target.BackendPort,
            requireLegacyAbsent: pending.MigrateLegacySystemState);
        var currentSelf = tailscale.ReadSelfIdentity();
        if (!SelfIdentityEquals(pending.ObservedSelf, currentSelf))
        {
            throw new BrokerRefusalException(
                "Tailscale Self identity changed before protected commit.",
                PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
    }

    private static bool SelfIdentityEquals(
        TailscaleSelfIdentity? left,
        TailscaleSelfIdentity? right) =>
        left is not null &&
        right is not null &&
        string.Equals(left.DnsName, right.DnsName, StringComparison.Ordinal) &&
        left.TailscaleIps.SequenceEqual(right.TailscaleIps, StringComparer.Ordinal);

    private static void RollbackPending(
        BrokerStateStore store,
        BrokerPendingJournal pending,
        string ownerSid)
    {
        if (pending.Operation == PrivilegedBrokerOperation.UninstallCleanup)
        {
            ResumeUninstall(store, pending, ownerSid);
            return;
        }
        if (pending.Operation != PrivilegedBrokerOperation.Apply)
        {
            if (!pending.LegacyTaskMutationAuthorized)
            {
                store.DeletePending(pending.TransactionId);
                return;
            }
            throw new BrokerRefusalException(
                "Protected pending operation cannot be rolled back safely.",
                PrivilegedBrokerErrorCode.RecoveryRequired,
                pendingRecovery: true);
        }

        pending = store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.RecoveryPrepared
        });
        var tailscale = TrustedTailscale.Resolve(ownerSid);
        var firewall = new BrokerFirewall(ownerSid);
        if (pending.FirewallMutationAuthorized)
        {
            firewall.RestoreSnapshot(
                pending.OriginalFirewallRules,
                pending.Target.BackendPort);
        }
        if (pending.TargetRouteMutationAuthorized)
        {
            if (pending.Previous is not null &&
                pending.Previous.PublicPort == pending.Target.PublicPort)
            {
                tailscale.RestoreOwnedRoot(
                    pending.Previous.PublicPort,
                    pending.Previous.BackendPort,
                    ServeRootState.Owned,
                    pending.Target.BackendPort,
                    pending.PreviousUnrelatedHandlersJson ??
                        throw new InvalidDataException(
                            "Previous unrelated handler snapshot is missing."));
            }
            else if (pending.ObservedTargetRoot == ServeRootState.RootAbsent)
            {
                tailscale.RemoveOwnedRoot(
                    pending.Target.PublicPort,
                    pending.Target.BackendPort,
                    pending.TargetUnrelatedHandlersJson ??
                        throw new InvalidDataException(
                            "Target unrelated handler snapshot is missing."));
            }
        }
        if (pending.PreviousRouteMutationAuthorized && pending.Previous is not null)
        {
            tailscale.RestoreOwnedRoot(
                pending.Previous.PublicPort,
                pending.Previous.BackendPort,
                ServeRootState.RootAbsent,
                expectedMutationBackendPort: null,
                pending.PreviousUnrelatedHandlersJson ??
                    throw new InvalidDataException(
                        "Previous unrelated handler snapshot is missing."));
        }
        if (pending.LegacyTaskMutationAuthorized && pending.LegacyTask is not null)
        {
            new LegacyScheduledTask(ownerSid).RestoreOwned(pending.LegacyTask);
        }
        store.RollbackAppliedLedger(pending);
    }

    private static PrivilegedBrokerResponse UninstallCleanup(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store,
        IReadOnlyList<BrokerAppliedLedger> otherAppliedLedgers)
    {
        var systemCleanupPerformed = false;
        if (store.PendingExists)
        {
            var existing = store.LoadExistingPending();
            if (existing.Operation == PrivilegedBrokerOperation.UninstallCleanup)
            {
                if (existing.Phase == BrokerMutationPhase.Prepared &&
                    !existing.PreviousRouteMutationAuthorized &&
                    !existing.TargetRouteMutationAuthorized &&
                    !existing.FirewallMutationAuthorized &&
                    !existing.LegacyTaskMutationAuthorized &&
                    !existing.AppliedLedgerMutationAuthorized)
                {
                    store.DiscardUnmutatedPending(existing);
                }
                else
                {
                    ResumeUninstall(store, existing, ownerSid);
                    systemCleanupPerformed = true;
                }
            }
            else
            {
                RollbackPending(store, existing, ownerSid);
                systemCleanupPerformed = true;
            }
        }
        var applied = store.LoadApplied();
        if (applied is null)
        {
            return FinishUninstall(
                request,
                ownerSid,
                store,
                systemCleanupPerformed);
        }

        var tailscale = TrustedTailscale.Resolve(ownerSid);
        var liveSelf = tailscale.ReadSelfIdentity();
        var preserveSharedRoute = RequireGlobalUninstallCompatibility(
            applied,
            liveSelf,
            tailscale.Path,
            otherAppliedLedgers);
        var taskService = new LegacyScheduledTask(ownerSid);
        var legacyTask = taskService.CaptureIfOwned();
        var pending = store.Begin(
            request,
            applied.Configuration,
            applied.Configuration,
            legacyTask,
            applied.TailscaleSelf);
        var targetRoot = TailscaleServeStatus.ReadRootSnapshot(
            tailscale.ReadServeStatus(),
            applied.Configuration.PublicPort,
            [applied.Configuration.BackendPort]);
        if (targetRoot.FunnelActive || targetRoot.State == ServeRootState.Unowned)
        {
            throw new BrokerRefusalException(
                "Uninstall found Funnel or an unowned Tailscale root.",
                targetRoot.FunnelActive
                    ? PrivilegedBrokerErrorCode.FunnelDetected
                    : PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
        if (preserveSharedRoute && targetRoot.State != ServeRootState.Owned)
        {
            throw new BrokerRefusalException(
                "A shared protected Tailscale route is missing during uninstall.",
                PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }
        var firewall = new BrokerFirewall(ownerSid);
        var firewallSnapshot = firewall.CapturePreflight(
            applied,
            allowLegacyMigration: false);
        pending = store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.PreflightVerified,
            ObservedTargetRoot = targetRoot.State,
            ObservedPreviousRoot = targetRoot.State,
            TargetUnrelatedHandlersJson = targetRoot.UnrelatedHandlersJson,
            PreviousUnrelatedHandlersJson = targetRoot.UnrelatedHandlersJson,
            OriginalFirewallRules = firewallSnapshot
        });
        ResumeUninstall(store, pending, ownerSid);
        return FinishUninstall(
            request,
            ownerSid,
            store,
            systemCleanupPerformed: true);
    }

    private static PrivilegedBrokerResponse FinishUninstall(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store,
        bool systemCleanupPerformed)
    {
        var retirementRequired = ProtectedBrokerRetirement.RetireIfLastOwner(
            request,
            ownerSid,
            store);
        return Success(
            request,
            retirementRequired
                ? PrivilegedBrokerDisposition.RetirementRequired
                : systemCleanupPerformed
                    ? PrivilegedBrokerDisposition.Completed
                    : PrivilegedBrokerDisposition.NoChange,
            retirementRequired
                ? "Protected system cleanup completed; fixed-path broker retirement is ready after process exit."
                : systemCleanupPerformed
                    ? "Protected uninstall system cleanup completed."
                    : "No protected applied system configuration exists.");
    }

    private static void ResumeUninstall(
        BrokerStateStore store,
        BrokerPendingJournal pending,
        string ownerSid)
    {
        if (pending.Operation != PrivilegedBrokerOperation.UninstallCleanup)
        {
            throw new InvalidDataException("Protected pending operation is not uninstall cleanup.");
        }
        if (pending.Phase == BrokerMutationPhase.Prepared)
        {
            throw new BrokerRefusalException(
                "Uninstall cleanup did not durably finish preflight.",
                PrivilegedBrokerErrorCode.RecoveryRequired,
                pendingRecovery: true);
        }
        var applied = store.LoadApplied();
        var effectiveApplied = applied ?? new BrokerAppliedLedger(
            BrokerStateStore.SchemaVersion,
            pending.OwnerSid,
            pending.Target,
            pending.ObservedSelf ??
                throw new InvalidDataException("Uninstall Tailscale identity is missing."),
            DateTimeOffset.UnixEpoch);
        var tailscale = TrustedTailscale.Resolve(ownerSid);
        var firewall = new BrokerFirewall(ownerSid);

        var liveSelf = tailscale.ReadSelfIdentity();
        var preserveSharedRoute = RequireGlobalUninstallCompatibility(
            effectiveApplied,
            liveSelf,
            tailscale.Path,
            store.LoadOtherOwnerAppliedLedgersForGlobalMutation());

        if (preserveSharedRoute)
        {
            if (pending.PreviousRouteMutationAuthorized)
            {
                throw new BrokerRefusalException(
                    "A shared route appeared after uninstall route mutation was authorized.",
                    PrivilegedBrokerErrorCode.RecoveryRequired,
                    pendingRecovery: true);
            }
            var sharedRoot = TailscaleServeStatus.ReadRootSnapshot(
                tailscale.ReadServeStatus(),
                pending.Target.PublicPort,
                [pending.Target.BackendPort]);
            if (sharedRoot.FunnelActive ||
                sharedRoot.State != ServeRootState.Owned ||
                !string.Equals(
                    sharedRoot.UnrelatedHandlersJson,
                    pending.TargetUnrelatedHandlersJson,
                    StringComparison.Ordinal))
            {
                throw new BrokerRefusalException(
                    "Shared protected Tailscale route changed during uninstall.",
                    sharedRoot.FunnelActive
                        ? PrivilegedBrokerErrorCode.FunnelDetected
                        : PrivilegedBrokerErrorCode.OwnershipMismatch,
                    pendingRecovery: true);
            }
        }
        else
        {
            if (!pending.PreviousRouteMutationAuthorized)
            {
                pending = store.Update(pending.TransactionId, current => current with
                {
                    Phase = BrokerMutationPhase.UninstallRouteMutationPrepared,
                    PreviousRouteMutationAuthorized = true
                });
            }
            tailscale.RemoveOwnedRoot(
                pending.Target.PublicPort,
                pending.Target.BackendPort,
                pending.TargetUnrelatedHandlersJson ??
                    throw new InvalidDataException("Uninstall unrelated handler snapshot is missing."));
            pending = store.Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.UninstallRouteRemoved
            });
        }

        if (!pending.FirewallMutationAuthorized)
        {
            pending = store.Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.UninstallFirewallMutationPrepared,
                FirewallMutationAuthorized = true
            });
        }
        firewall.RemoveAppliedRules(effectiveApplied, pending.OriginalFirewallRules);
        pending = store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.UninstallFirewallRemoved
        });

        if (pending.LegacyTask is not null)
        {
            var legacyTaskSnapshot = pending.LegacyTask;
            if (!pending.LegacyTaskMutationAuthorized)
            {
                pending = store.Update(pending.TransactionId, current => current with
                {
                    Phase = BrokerMutationPhase.UninstallTaskMutationPrepared,
                    LegacyTaskMutationAuthorized = true
                });
            }
            new LegacyScheduledTask(ownerSid).RemoveOwned(legacyTaskSnapshot);
            pending = store.Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.UninstallTaskRemoved
            });
        }
        pending = store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.UninstallCompleted,
            AppliedLedgerMutationAuthorized = true
        });
        store.DeleteApplied();
        store.CompleteWithoutAppliedMutation(
            pending,
            PrivilegedBrokerDisposition.Completed);
    }

    private static PrivilegedBrokerResponse CleanupLegacyTask(
        PrivilegedBrokerRequest request,
        string ownerSid,
        BrokerStateStore store)
    {
        if (store.PendingExists)
        {
            var existing = store.LoadExistingPending();
            if (existing.Operation == PrivilegedBrokerOperation.LegacyTaskCleanup)
            {
                ResumeLegacyTaskCleanup(store, existing, ownerSid);
                return Success(
                    request,
                    PrivilegedBrokerDisposition.Completed,
                    "Interrupted fixed legacy task cleanup was resumed.");
            }
            throw new BrokerRefusalException(
                "Another protected transaction requires recovery.",
                PrivilegedBrokerErrorCode.PendingTransactionMismatch,
                pendingRecovery: true);
        }
        var applied = store.LoadApplied();
        if (applied is null)
        {
            return Success(
                request,
                PrivilegedBrokerDisposition.NoChange,
                "No protected applied ownership exists for legacy-task repair.");
        }
        var taskService = new LegacyScheduledTask(ownerSid);
        var task = taskService.CaptureIfOwned();
        if (task is null)
        {
            return Success(
                request,
                PrivilegedBrokerDisposition.NoChange,
                "No fixed legacy scheduled task exists.");
        }
        var pending = store.Begin(
            request,
            applied.Configuration,
            applied.Configuration,
            task,
            applied.TailscaleSelf);
        pending = store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.PreflightVerified
        });
        pending = store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.LegacyTaskMutationPrepared,
            LegacyTaskMutationAuthorized = true
        });
        ResumeLegacyTaskCleanup(store, pending, ownerSid);
        return Success(
            request,
            PrivilegedBrokerDisposition.Completed,
            "Fixed legacy scheduled task cleanup completed.");
    }

    private static void ResumeLegacyTaskCleanup(
        BrokerStateStore store,
        BrokerPendingJournal pending,
        string ownerSid)
    {
        if (pending.Operation != PrivilegedBrokerOperation.LegacyTaskCleanup ||
            pending.LegacyTask is null)
        {
            throw new InvalidDataException(
                "Protected pending operation is not a legacy-task cleanup.");
        }
        var legacyTask = pending.LegacyTask;
        if (!pending.LegacyTaskMutationAuthorized)
        {
            pending = store.Update(pending.TransactionId, current => current with
            {
                Phase = BrokerMutationPhase.LegacyTaskMutationPrepared,
                LegacyTaskMutationAuthorized = true
            });
        }
        new LegacyScheduledTask(ownerSid).RemoveOwned(legacyTask);
        pending = store.Update(pending.TransactionId, current => current with
        {
            Phase = BrokerMutationPhase.LegacyTaskRemoved
        });
        store.CompleteWithoutAppliedMutation(
            pending,
            PrivilegedBrokerDisposition.Completed);
    }

    private static PrivilegedBrokerResponse Status(
        PrivilegedBrokerRequest request,
        BrokerStateStore store)
    {
        _ = store.LoadApplied();
        if (store.PendingExists)
        {
            _ = store.LoadExistingPending();
            throw new BrokerRefusalException(
                "A protected system transaction requires recovery.",
                PrivilegedBrokerErrorCode.RecoveryRequired,
                pendingRecovery: true);
        }
        return Success(
            request,
            PrivilegedBrokerDisposition.NoChange,
            "Protected broker state is consistent.");
    }

    internal static bool RequireGlobalApplyCompatibility(
        BrokerSystemConfiguration target,
        TailscaleSelfIdentity liveSelf,
        BrokerAppliedLedger? currentApplied,
        IReadOnlyList<BrokerAppliedLedger> otherAppliedLedgers)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(liveSelf);
        ArgumentNullException.ThrowIfNull(otherAppliedLedgers);
        if (currentApplied is not null &&
            (!string.Equals(
                 currentApplied.Configuration.TailscalePath,
                 target.TailscalePath,
                 StringComparison.OrdinalIgnoreCase) ||
             !SelfIdentityEquals(currentApplied.TailscaleSelf, liveSelf)))
        {
            throw new BrokerRefusalException(
                "Current protected applied ownership does not match live Tailscale identity.",
                PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
        if (otherAppliedLedgers.Count == 0)
        {
            return false;
        }

        if (otherAppliedLedgers.Any(applied =>
                !ConfigurationEquals(applied.Configuration, target) ||
                !SelfIdentityEquals(applied.TailscaleSelf, liveSelf)) ||
            currentApplied is not null &&
            !ConfigurationEquals(currentApplied.Configuration, target))
        {
            throw new BrokerRefusalException(
                "Another protected owner has a different global Tailscale route.",
                PrivilegedBrokerErrorCode.OwnershipMismatch);
        }
        return true;
    }

    internal static bool RequireGlobalUninstallCompatibility(
        BrokerAppliedLedger currentApplied,
        TailscaleSelfIdentity liveSelf,
        string trustedTailscalePath,
        IReadOnlyList<BrokerAppliedLedger> otherAppliedLedgers)
    {
        ArgumentNullException.ThrowIfNull(currentApplied);
        ArgumentNullException.ThrowIfNull(liveSelf);
        ArgumentException.ThrowIfNullOrWhiteSpace(trustedTailscalePath);
        ArgumentNullException.ThrowIfNull(otherAppliedLedgers);
        if (!string.Equals(
                currentApplied.Configuration.TailscalePath,
                trustedTailscalePath,
                StringComparison.OrdinalIgnoreCase) ||
            !SelfIdentityEquals(currentApplied.TailscaleSelf, liveSelf))
        {
            throw new BrokerRefusalException(
                "Current protected uninstall ownership does not match live Tailscale identity.",
                PrivilegedBrokerErrorCode.OwnershipMismatch,
                pendingRecovery: true);
        }

        var shared = false;
        foreach (var other in otherAppliedLedgers)
        {
            if (!string.Equals(
                    other.Configuration.TailscalePath,
                    trustedTailscalePath,
                    StringComparison.OrdinalIgnoreCase) ||
                !SelfIdentityEquals(other.TailscaleSelf, liveSelf))
            {
                throw new BrokerRefusalException(
                    "Another protected owner has a mismatched Tailscale identity.",
                    PrivilegedBrokerErrorCode.OwnershipMismatch,
                    pendingRecovery: true);
            }
            if (other.Configuration.PublicPort != currentApplied.Configuration.PublicPort)
            {
                continue;
            }
            if (!ConfigurationEquals(
                    other.Configuration,
                    currentApplied.Configuration))
            {
                throw new BrokerRefusalException(
                    "Another protected owner conflicts on the same Tailscale public port.",
                    PrivilegedBrokerErrorCode.OwnershipMismatch,
                    pendingRecovery: true);
            }
            shared = true;
        }
        return shared;
    }

    private static bool ConfigurationEquals(
        BrokerSystemConfiguration left,
        BrokerSystemConfiguration right) =>
        left.PublicPort == right.PublicPort &&
        left.BackendPort == right.BackendPort &&
        string.Equals(
            left.TailscalePath,
            right.TailscalePath,
            StringComparison.OrdinalIgnoreCase);

    private static void RequireBackendPortAvailable(int port)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (DateTime.UtcNow < deadline)
        {
            if (IsBackendPortAvailable(port))
            {
                return;
            }
            Thread.Sleep(100);
        }
        throw new BrokerRefusalException(
            "Backend loopback port remains occupied.",
            PrivilegedBrokerErrorCode.OwnershipMismatch);
    }

    private static bool IsBackendPortAvailable(int port)
    {
        if (IPGlobalProperties.GetIPGlobalProperties()
            .GetActiveTcpListeners()
            .Any(endpoint => endpoint.Port == port))
        {
            return false;
        }
        TcpListener? listener = null;
        try
        {
            listener = new TcpListener(IPAddress.Loopback, port)
            {
                ExclusiveAddressUse = true
            };
            listener.Start();
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
        finally
        {
            listener?.Stop();
        }
    }

    private static PrivilegedBrokerErrorCode MapErrorCode(Exception exception) =>
        exception switch
        {
            BrokerRefusalException refusal => refusal.ErrorCode,
            TimeoutException => PrivilegedBrokerErrorCode.ExternalCommandFailed,
            InvalidDataException => PrivilegedBrokerErrorCode.OwnershipMismatch,
            _ => PrivilegedBrokerErrorCode.ExternalCommandFailed
        };

    private static PrivilegedBrokerResponse Success(
        PrivilegedBrokerRequest request,
        PrivilegedBrokerDisposition disposition,
        string message) =>
        new(
            PrivilegedBrokerProtocol.SchemaVersion,
            request.TransactionId,
            Success: true,
            disposition,
            PrivilegedBrokerErrorCode.None,
            message);
}
