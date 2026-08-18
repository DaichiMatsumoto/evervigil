using System.Buffers.Binary;
using System.Diagnostics;
using System.Security.AccessControl;
using System.Text;
using System.Text.Json;
using EverVigil.Broker;
using EverVigil.Broker.Protocol;

var failOnSkip = ParseFailOnSkipArgument(args);
var tests = new (string Name, Action Run)[]
{
    ("Fail-on-skip policy rejects skipped tests", FailOnSkipPolicyRejectsSkippedTests),
    ("Broker launch stages have distinct exit codes", BrokerLaunchStagesHaveDistinctExitCodes),
    ("Broker integrity validation has sufficient token rights", BrokerIntegrityValidationHasSufficientTokenRights),
    ("Serve exact root is owned", ServeExactRootIsOwned),
    ("Serve root removal preserves unrelated handlers", ServeRootRemovalPreservesUnrelatedHandlers),
    ("Serve parser rejects wrong TCP schema", ServeRejectsWrongTcpSchema),
    ("Serve parser rejects root extra fields", ServeRejectsRootExtraFields),
    ("Serve parser rejects Web extra fields", ServeRejectsWebExtraFields),
    ("Serve parser rejects unrelated root", ServeRejectsUnrelatedRoot),
    ("Serve parser detects Funnel", ServeDetectsFunnel),
    ("Serve parser supports custom v1 ports", ServeSupportsCustomPorts),
    ("Tailnet identity accepts only ts.net and CGNAT or ULA", TailnetIdentityIsStrict),
    ("Protocol framing round trips", ProtocolFramingRoundTrips),
    ("Protocol framing rejects unknown fields", ProtocolFramingRejectsUnknownFields),
    ("Firewall names isolate owner SID", FirewallNamesIsolateOwnerSid),
    ("Native COM automation activates fixed Windows services", NativeComAutomationProbe),
    ("Retained client handle detects process exit", RetainedClientDetectsExit),
    ("Applied write crash converges", AppliedWriteCrashConverges),
    ("Applied phase write crash converges", AppliedPhaseCrashConverges),
    ("Receipt write crash converges", ReceiptWriteCrashConverges),
    ("Pending delete response loss converges", PendingDeleteCrashConverges),
    ("Route rollback accepts exact restored state", RouteRollbackAcceptsRestoredState),
    ("Route rollback accepts exact mutation prestate", RouteRollbackAcceptsMutationPrestate),
    ("Route rollback rejects third-party state", RouteRollbackRejectsThirdPartyState),
    ("Rollback restores previous protected ledger", RollbackRestoresPreviousLedger),
    ("Rollback receipt requires a distinct cleanup transaction", RollbackReceiptRequiresDistinctCleanupTransaction),
    ("Prepared uninstall is safely discardable", PreparedUninstallIsDiscardable),
    ("Clean protected state reports no change", CleanStateReportsNoChange),
    ("Clean protected state uninstall reports no change", CleanStateUninstallReportsNoChange),
    ("Global shared route survives until the final owner", GlobalSharedRouteSurvivesUntilFinalOwner),
    ("Global Apply rejects conflicting owner ledgers", GlobalApplyRejectsConflictingOwners),
    ("Global uninstall preserves unrelated ports and rejects conflicts", GlobalUninstallClassifiesOtherOwners),
    ("Global owner State rejects pending and unknown entries", GlobalOwnerStateRejectsUnsafeEntries),
    ("Retirement crash boundaries converge", RetirementCrashBoundariesConverge),
    ("Retirement response loss converges", RetirementResponseLossConverges),
    ("Retirement rejects a different transaction", RetirementRejectsDifferentTransaction),
    ("Retirement repairs a missing installation receipt", RetirementRepairsMissingInstallationReceipt),
    ("Retirement schedules only canonical reboot deletion", RetirementSchedulesOnlyCanonicalDeletion),
    ("Retirement preserves another owner", RetirementPreservesAnotherOwner),
    ("Retirement rejects unknown State entry", RetirementRejectsUnknownStateEntry),
    ("Retirement rejects reparse State entry", RetirementRejectsReparseStateEntry),
    ("Retirement rejects canonical identity mismatch", RetirementRejectsIdentityMismatch),
    ("Retirement receipt schema and owner are strict", RetirementReceiptIsStrict),
    ("Retirement owner rights are delete-only", RetirementRightsAreDeleteOnly),
    ("Bootstrap repairs receipt-less exact canonical", BootstrapRepairsReceiptlessCanonical),
    ("Bootstrap rejects receipt-less identity mismatch", BootstrapRejectsIdentityMismatch),
    ("Bootstrap rejects receipt-less hard-linked canonical", BootstrapRejectsHardLinkedCanonical),
    ("Bootstrap rejects an orphaned installation receipt", BootstrapRejectsOrphanedInstallationReceipt),
    ("Bootstrap cleans only strict protected temporaries", BootstrapCleansStrictTemporaries),
    ("Legacy custom install root is discovered", LegacyCustomInstallRootIsDiscovered),
    ("Legacy owner paths use the authenticated profile only", LegacyOwnerPathsUseAuthenticatedProfile),
    ("Legacy task accepts redirected owner launcher paths", LegacyTaskAcceptsRedirectedOwnerLauncherPaths),
    ("Legacy custom ports are read exactly", LegacyCustomPortsAreReadExactly),
    ("Tailscale installation validates when present", InstalledTailscaleValidationProbe)
};

var failures = new List<string>();
var skipped = new List<string>();
foreach (var test in tests)
{
    try
    {
        test.Run();
        Console.WriteLine($"PASS  {test.Name}");
    }
    catch (TestSkippedException exception)
    {
        skipped.Add(test.Name);
        Console.WriteLine($"SKIP  {test.Name}: {exception.Message}");
    }
    catch (Exception exception)
    {
        failures.Add($"FAIL  {test.Name}: {exception}");
    }
}
foreach (var failure in failures)
{
    Console.Error.WriteLine(failure);
}
Console.WriteLine(
    $"Executed {tests.Length} broker tests; passed {tests.Length - failures.Count - skipped.Count}; " +
    $"skipped {skipped.Count}; failed {failures.Count}.");
if (failOnSkip && skipped.Count > 0)
{
    Console.Error.WriteLine(
        $"FAIL  Release gate forbids skipped broker tests; observed {skipped.Count}.");
}
return BrokerTestExitCode(failures.Count, skipped.Count, failOnSkip);

static bool ParseFailOnSkipArgument(string[] arguments)
{
    ArgumentNullException.ThrowIfNull(arguments);
    var failOnSkip = false;
    foreach (var argument in arguments)
    {
        if (!string.Equals(argument, "--fail-on-skip", StringComparison.Ordinal))
        {
            throw new ArgumentException($"Unknown broker-test argument: {argument}");
        }
        if (failOnSkip)
        {
            throw new ArgumentException("The --fail-on-skip argument was specified more than once.");
        }
        failOnSkip = true;
    }
    return failOnSkip;
}

static int BrokerTestExitCode(int failureCount, int skippedCount, bool failOnSkip)
{
    ArgumentOutOfRangeException.ThrowIfNegative(failureCount);
    ArgumentOutOfRangeException.ThrowIfNegative(skippedCount);
    return failureCount > 0 || failOnSkip && skippedCount > 0 ? 1 : 0;
}

static void FailOnSkipPolicyRejectsSkippedTests()
{
    Assert(BrokerTestExitCode(0, 0, failOnSkip: true) == 0,
        "The release gate rejected a fully executed test run.");
    Assert(BrokerTestExitCode(0, 1, failOnSkip: false) == 0,
        "The validation policy did not report a skip separately.");
    Assert(BrokerTestExitCode(0, 1, failOnSkip: true) != 0,
        "The release gate accepted a skipped broker test.");
    Assert(BrokerTestExitCode(1, 0, failOnSkip: false) != 0,
        "The normal validation policy accepted a failed broker test.");
}

static void BrokerLaunchStagesHaveDistinctExitCodes()
{
    var expected = new[]
    {
        BrokerExitCodes.Success,
        BrokerExitCodes.InternalFailure,
        BrokerExitCodes.InvalidLaunchArguments,
        BrokerExitCodes.ProtectedInstallationFailure,
        BrokerExitCodes.BrokerElevationFailure,
        BrokerExitCodes.LoadedImageValidationFailure,
        BrokerExitCodes.ClientAuthenticationFailure,
        BrokerExitCodes.AuthenticatedPipeFailure
    };
    Assert(expected.Distinct().Count() == expected.Length,
        "Broker launch stages reused an exit code.");
    Assert(BrokerExitCodes.Success == 0,
        "Broker success exit code changed unexpectedly.");
    Assert(BrokerExitCodes.InvalidLaunchArguments == 3,
        "The native pre-Main probe compatibility exit code changed unexpectedly.");
    Assert(BrokerExitCodes.ProtectedInstallationFailure == 4,
        "The protected installation failure exit code changed unexpectedly.");
}

static void BrokerIntegrityValidationHasSufficientTokenRights()
{
    try
    {
        AuthenticatedClientProcess.RequireBrokerHighIntegrity();
    }
    catch (UnauthorizedAccessException)
    {
        return;
    }
    catch (Exception exception)
    {
        throw new InvalidOperationException(
            "Broker integrity validation failed before producing its security decision.",
            exception);
    }
}

static void ServeExactRootIsOwned()
{
    var snapshot = TailscaleServeStatus.ReadRootSnapshot(
        ServeStatus(3456, 3457),
        3456,
        [3457]);
    Assert(snapshot.State == ServeRootState.Owned, "Exact Serve root was not owned.");
    Assert(!snapshot.FunnelActive, "Exact Serve root unexpectedly enabled Funnel.");
    Assert(snapshot.UnrelatedHandlersJson == "{}", "Exact root had unrelated handlers.");
}

static void NativeComAutomationProbe()
{
    using (var policy = NativeComDispatch.Create(NativeComDispatch.NetFwPolicy2ClassId))
    using (var rules = policy.GetDispatchProperty("Rules"))
    {
        Assert(rules.GetInt32Property("Count") >= 0,
            "Native Firewall COM rules count is invalid.");
    }

    using var scheduler = NativeComDispatch.Create(NativeComDispatch.TaskSchedulerClassId);
    scheduler.InvokeMethod("Connect");
    Assert(scheduler.GetBooleanProperty("Connected"),
        "Native Task Scheduler COM service did not connect.");
}

static void ServeRootRemovalPreservesUnrelatedHandlers()
{
    const string before = """
        {
          "TCP":{"3456":{"HTTP":true}},
          "Web":{"device.example.invalid:3456":{"Handlers":{
            "/":{"Proxy":"http://127.0.0.1:3457"},
            "/foo":{"Proxy":"http://127.0.0.1:4567"}
          }}}
        }
        """;
    const string after = """
        {
          "TCP":{"3456":{"HTTP":true}},
          "Web":{"device.example.invalid:3456":{"Handlers":{
            "/foo":{"Proxy":"http://127.0.0.1:4567"}
          }}}
        }
        """;
    var owned = TailscaleServeStatus.ReadRootSnapshot(before, 3456, [3457]);
    var removed = TailscaleServeStatus.ReadRootSnapshot(after, 3456, [3457]);
    Assert(owned.State == ServeRootState.Owned, "Root+foo was not owned.");
    Assert(removed.State == ServeRootState.RootAbsent, "Removed root was not absent.");
    Assert(
        owned.UnrelatedHandlersJson == removed.UnrelatedHandlersJson,
        "Unrelated /foo handler was not preserved exactly.");
}

static void ServeRejectsWrongTcpSchema()
{
    const string json = """
        {"TCP":{"3456":"HTTP"},"Web":{"device.invalid:3456":{"Handlers":{}}}}
        """;
    Assert(
        TailscaleServeStatus.ReadRootSnapshot(json, 3456, [3457]).State ==
            ServeRootState.Unowned,
        "String TCP schema was accepted.");
}

static void ServeRejectsRootExtraFields()
{
    const string json = """
        {"TCP":{"3456":{"HTTP":true}},"Web":{"device.invalid:3456":{"Handlers":{
          "/":{"Proxy":"http://127.0.0.1:3457","Extra":true}
        }}}}
        """;
    AssertUnowned(json, "Root handler extra field was accepted.");
}

static void ServeRejectsWebExtraFields()
{
    const string json = """
        {"TCP":{"3456":{"HTTP":true}},"Web":{"device.invalid:3456":{
          "Handlers":{"/":{"Proxy":"http://127.0.0.1:3457"}},"Extra":true
        }}}
        """;
    AssertUnowned(json, "Web entry extra field was accepted.");
}

static void ServeRejectsUnrelatedRoot()
{
    AssertUnowned(ServeStatus(3456, 9999), "Unrelated backend was accepted.");
}

static void ServeDetectsFunnel()
{
    const string json = """
        {
          "TCP":{"3456":{"HTTP":true}},
          "Web":{"device.invalid:3456":{"Handlers":{
            "/":{"Proxy":"http://127.0.0.1:3457"}
          }}},
          "AllowFunnel":{"device.invalid:3456":true}
        }
        """;
    var snapshot = TailscaleServeStatus.ReadRootSnapshot(json, 3456, [3457]);
    Assert(snapshot.FunnelActive, "Funnel was not detected.");
}

static void ServeSupportsCustomPorts()
{
    var snapshot = TailscaleServeStatus.ReadRootSnapshot(
        ServeStatus(4566, 4567),
        4566,
        [4567]);
    Assert(snapshot.State == ServeRootState.Owned, "Custom v1 ports were not recognized.");
}

static void TailnetIdentityIsStrict()
{
    var dns = "device.tail1234" + ".ts.net";
    Assert(TailscaleIdentityValidator.IsValidDnsName(dns), "Tailnet DNS was rejected.");
    Assert(!TailscaleIdentityValidator.IsValidDnsName("device.example.invalid"), "Public DNS was accepted.");
    Assert(TailscaleIdentityValidator.IsTailnetAddress("100." + "64.0.1"), "CGNAT address was rejected.");
    Assert(TailscaleIdentityValidator.IsTailnetAddress("fd7a:115c:" + "a1e0::1"), "Tailnet ULA was rejected.");
    Assert(!TailscaleIdentityValidator.IsTailnetAddress("8.8.8.8"), "Public IPv4 was accepted.");
    Assert(!TailscaleIdentityValidator.IsTailnetAddress("2001:4860:4860::8888"), "Public IPv6 was accepted.");
}

static void ProtocolFramingRoundTrips()
{
    var request = Request(Guid.NewGuid(), PrivilegedBrokerOperation.Apply, 3456, 3457);
    using var stream = new MemoryStream();
    PrivilegedBrokerProtocol.WriteFrameAsync(stream, request, CancellationToken.None)
        .GetAwaiter().GetResult();
    stream.Position = 0;
    var read = PrivilegedBrokerProtocol.ReadFrameAsync<PrivilegedBrokerRequest>(
        stream,
        CancellationToken.None).GetAwaiter().GetResult();
    Assert(read == request, "Protocol request did not round-trip.");
}

static void ProtocolFramingRejectsUnknownFields()
{
    var payload = Encoding.UTF8.GetBytes(
        "{\"schemaVersion\":1,\"transactionId\":\"00000000-0000-0000-0000-000000000001\"," +
        "\"nonce\":\"" + new string('a', 64) + "\",\"operation\":\"Status\"," +
        "\"initiator\":\"Interactive\",\"publicPort\":null,\"backendPort\":null," +
        "\"migrateLegacySystemState\":false,\"unexpected\":true}");
    using var stream = new MemoryStream();
    var header = new byte[sizeof(int)];
    BinaryPrimitives.WriteInt32LittleEndian(header, payload.Length);
    stream.Write(header);
    stream.Write(payload);
    stream.Position = 0;
    AssertThrows<InvalidDataException>(() =>
        PrivilegedBrokerProtocol.ReadFrameAsync<PrivilegedBrokerRequest>(
            stream,
            CancellationToken.None).GetAwaiter().GetResult());
}

static void FirewallNamesIsolateOwnerSid()
{
    const string firstSid = "S-1-5-21-1-2-3-1001";
    const string secondSid = "S-1-5-21-1-2-3-1002";
    var first = new BrokerFirewall(firstSid);
    var second = new BrokerFirewall(secondSid);
    Assert(first.CurrentMainName.Contains(firstSid, StringComparison.Ordinal), "Rule omitted owner SID.");
    Assert(first.CurrentMainName != second.CurrentMainName, "Two owners shared a rule name.");
}

static void RetainedClientDetectsExit()
{
    using var process = Process.Start(new ProcessStartInfo
    {
        FileName = Path.Combine(Environment.SystemDirectory, "ping.exe"),
        Arguments = "127.0.0.1 -n 30",
        UseShellExecute = false,
        CreateNoWindow = true
    }) ?? throw new InvalidOperationException("Test client process did not start.");
    using var retained = AuthenticatedClientProcess.OpenAndValidate((uint)process.Id);
    retained.RequireOriginalProcessStillActive();
    process.Kill(entireProcessTree: true);
    process.WaitForExit();
    AssertThrows<UnauthorizedAccessException>(retained.RequireOriginalProcessStillActive);
}

static void AppliedWriteCrashConverges() =>
    CommitFaultConverges(PrivilegedBrokerPaths.AppliedLedgerFileName + ":written");

static void AppliedPhaseCrashConverges() =>
    CommitFaultConverges(PrivilegedBrokerPaths.PendingJournalFileName + ":written");

static void ReceiptWriteCrashConverges() =>
    CommitFaultConverges(PrivilegedBrokerPaths.TransactionReceiptFileName + ":written");

static void PendingDeleteCrashConverges() =>
    CommitFaultConverges(PrivilegedBrokerPaths.PendingJournalFileName + ":deleted");

static void RouteRollbackAcceptsRestoredState()
{
    var status = ServeStatus(3456, 3457);
    var decision = TrustedTailscale.ClassifyRootRestore(
        status,
        3456,
        3457,
        ServeRootState.Owned,
        4567,
        "{}");
    Assert(
        decision == ServeRootRestoreDecision.AlreadyRestored,
        "An exact previously-restored root was not accepted as an idempotent no-op.");
}

static void RouteRollbackAcceptsMutationPrestate()
{
    var status = ServeStatus(3456, 4567);
    var decision = TrustedTailscale.ClassifyRootRestore(
        status,
        3456,
        3457,
        ServeRootState.Owned,
        4567,
        "{}");
    Assert(
        decision == ServeRootRestoreDecision.RestoreFromExpectedMutationState,
        "The exact durable mutation prestate was not accepted for restoration.");
}

static void RouteRollbackRejectsThirdPartyState()
{
    var status = ServeStatus(3456, 5567);
    AssertThrows<BrokerRefusalException>(() =>
        TrustedTailscale.ClassifyRootRestore(
            status,
            3456,
            3457,
            ServeRootState.Owned,
            4567,
            "{}"));
}

static void CommitFaultConverges(string faultBoundary)
{
    var root = NewTestRoot();
    const string sid = "S-1-5-21-1-2-3-1001";
    var armed = false;
    try
    {
        var store = BrokerStateStore.ForTests(root, sid, boundary =>
        {
            if (armed && string.Equals(boundary, faultBoundary, StringComparison.Ordinal))
            {
                armed = false;
                throw new InjectedFaultException(boundary);
            }
        });
        var pending = PrepareCompletedApply(store, Guid.NewGuid(), Target(3456, 3457));
        armed = true;
        AssertThrows<InjectedFaultException>(() => store.CommitApplied(pending));

        var recovered = BrokerStateStore.ForTests(root, sid);
        var receipt = recovered.TryLoadReceipt(pending.TransactionId);
        if (receipt is not null)
        {
            recovered.CleanupPendingAfterReceipt(receipt);
        }
        else
        {
            recovered.CommitApplied(recovered.LoadPending(pending.TransactionId));
        }
        var finalReceipt = recovered.TryLoadReceipt(pending.TransactionId);
        Assert(finalReceipt?.Disposition == PrivilegedBrokerDisposition.Completed, "Commit receipt was lost.");
        Assert(!recovered.PendingExists, "Pending journal remained after replay.");
        Assert(recovered.LoadApplied()?.Configuration == pending.Target, "Target ledger did not converge.");
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
}

static void RollbackRestoresPreviousLedger()
{
    var root = NewTestRoot();
    const string sid = "S-1-5-21-1-2-3-1001";
    try
    {
        var baselineStore = BrokerStateStore.ForTests(root, sid);
        var baseline = PrepareCompletedApply(
            baselineStore,
            Guid.NewGuid(),
            Target(3456, 3457));
        baselineStore.CommitApplied(baseline);
        var expected = baselineStore.LoadApplied() ??
            throw new InvalidOperationException("Baseline ledger was not committed.");

        var armed = false;
        var mutating = BrokerStateStore.ForTests(root, sid, boundary =>
        {
            if (armed && boundary == PrivilegedBrokerPaths.AppliedLedgerFileName + ":written")
            {
                armed = false;
                throw new InjectedFaultException(boundary);
            }
        });
        var update = PrepareCompletedApply(
            mutating,
            Guid.NewGuid(),
            Target(4566, 4567),
            expected.Configuration);
        armed = true;
        AssertThrows<InjectedFaultException>(() => mutating.CommitApplied(update));

        var recovering = BrokerStateStore.ForTests(root, sid);
        recovering.RollbackAppliedLedger(recovering.LoadPending(update.TransactionId));
        var restored = recovering.LoadApplied() ??
            throw new InvalidOperationException(
                "Rollback removed the previous protected ledger.");
        Assert(
            restored.Configuration == expected.Configuration &&
            restored.OwnerSid == expected.OwnerSid &&
            restored.CommittedAtUtc == expected.CommittedAtUtc &&
            restored.TailscaleSelf.DnsName == expected.TailscaleSelf.DnsName &&
            restored.TailscaleSelf.TailscaleIps.SequenceEqual(
                expected.TailscaleSelf.TailscaleIps,
                StringComparer.Ordinal),
            "Rollback did not restore the exact previous protected ledger.");
        Assert(
            recovering.TryLoadReceipt(update.TransactionId)?.Disposition ==
                PrivilegedBrokerDisposition.RolledBack,
            "Rollback receipt was not durable.");
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
}

static void RollbackReceiptRequiresDistinctCleanupTransaction()
{
    var root = NewTestRoot();
    const string sid = "S-1-5-21-1-2-3-1001";
    try
    {
        var store = BrokerStateStore.ForTests(root, sid);
        var mainTransactionId = Guid.NewGuid();
        var cleanupTransactionId = Guid.NewGuid();
        var pending = PrepareCompletedApply(
            store,
            mainTransactionId,
            Target(3456, 3457));
        store.RollbackAppliedLedger(pending);

        Assert(
            store.TryLoadReceipt(mainTransactionId)?.Disposition ==
                PrivilegedBrokerDisposition.RolledBack,
            "The main transaction rollback receipt was not durable.");
        AssertThrows<BrokerRefusalException>(() =>
            PrivilegedSystemConfiguration.ExecuteForTests(
                Request(mainTransactionId, PrivilegedBrokerOperation.UninstallCleanup),
                sid,
                store));

        var cleanup = PrivilegedSystemConfiguration.ExecuteForTests(
            Request(cleanupTransactionId, PrivilegedBrokerOperation.UninstallCleanup),
            sid,
            store);
        Assert(cleanup.Success, "The distinct cleanup transaction failed.");
        Assert(
            cleanup.Disposition == PrivilegedBrokerDisposition.NoChange,
            "The distinct cleanup transaction did not converge on clean protected state.");
        Assert(!store.PendingExists, "The cleanup transaction left a pending journal.");
        Assert(!store.AppliedExists, "The cleanup transaction left an applied ledger.");
        Assert(
            store.TryLoadReceipt(mainTransactionId) is null,
            "The completed cleanup retained the obsolete main rollback receipt.");
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
}

static void PreparedUninstallIsDiscardable()
{
    var root = NewTestRoot();
    const string sid = "S-1-5-21-1-2-3-1001";
    try
    {
        var store = BrokerStateStore.ForTests(root, sid);
        var target = Target(3456, 3457);
        var request = Request(Guid.NewGuid(), PrivilegedBrokerOperation.UninstallCleanup);
        var pending = store.Begin(request, target, target, null, Self());
        store.DiscardUnmutatedPending(pending);
        Assert(!store.PendingExists, "Mutation-free uninstall Prepared journal remained.");
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
}

static void CleanStateReportsNoChange() =>
    AssertCleanStateDisposition(PrivilegedBrokerOperation.Status);

static void CleanStateUninstallReportsNoChange() =>
    AssertCleanStateDisposition(PrivilegedBrokerOperation.UninstallCleanup);

static void AssertCleanStateDisposition(PrivilegedBrokerOperation operation)
{
    var root = NewTestRoot();
    const string sid = "S-1-5-21-1-2-3-1001";
    try
    {
        var store = BrokerStateStore.ForTests(root, sid);
        var response = PrivilegedSystemConfiguration.ExecuteForTests(
            Request(Guid.NewGuid(), operation),
            sid,
            store);
        Assert(response.Success, "Clean protected state operation failed.");
        Assert(
            response.Disposition == PrivilegedBrokerDisposition.NoChange,
            "Clean protected state did not return NoChange.");
        Assert(!store.PendingExists, "Clean protected state created a pending journal.");
        Assert(!store.AppliedExists, "Clean protected state created an applied ledger.");
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
}

static void GlobalSharedRouteSurvivesUntilFinalOwner()
{
    var root = NewTestRoot();
    const string ownerA = "S-1-5-21-1-2-3-1001";
    const string ownerB = "S-1-5-21-1-2-3-1002";
    try
    {
        var storeA = BrokerStateStore.ForTests(root, ownerA);
        var storeB = BrokerStateStore.ForTests(root, ownerB);
        var target = Target(3456, 3457);
        CommitTestLedger(storeA, target);
        CommitTestLedger(storeB, target);
        var appliedA = storeA.LoadApplied() ??
            throw new InvalidOperationException("Owner A applied ledger is missing.");
        var otherForA = storeA.LoadOtherOwnerAppliedLedgersForGlobalMutation();
        Assert(otherForA.Count == 1 && otherForA[0].OwnerSid == ownerB,
            "Global inspection did not find exactly owner B.");
        Assert(
            PrivilegedSystemConfiguration.RequireGlobalApplyCompatibility(
                target,
                Self(),
                appliedA,
                otherForA),
            "Identical owner B route was not classified as shared Apply ownership.");
        Assert(
            PrivilegedSystemConfiguration.RequireGlobalUninstallCompatibility(
                appliedA,
                Self(),
                target.TailscalePath,
                otherForA),
            "Owner A uninstall did not preserve owner B's identical route.");

        // Test stores intentionally skip production ACL materialization. Remove
        // the fixture ledger directly before exercising owner-root retirement;
        // DeleteApplied validates the production ACL contract by design.
        File.Delete(storeA.AppliedPath);
        storeA.DeleteOwnerStateAfterUninstall();
        var appliedB = storeB.LoadApplied() ??
            throw new InvalidOperationException("Owner B applied ledger is missing.");
        var otherForB = storeB.LoadOtherOwnerAppliedLedgersForGlobalMutation();
        Assert(otherForB.Count == 0,
            "Retired owner A remained a global route owner.");
        Assert(
            !PrivilegedSystemConfiguration.RequireGlobalUninstallCompatibility(
                appliedB,
                Self(),
                target.TailscalePath,
                otherForB),
            "Final owner B uninstall incorrectly preserved the route.");
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
}

static void GlobalApplyRejectsConflictingOwners()
{
    var target = Target(3456, 3457);
    var current = TestLedger("S-1-5-21-1-2-3-1001", target, Self());
    AssertThrows<BrokerRefusalException>(() =>
        PrivilegedSystemConfiguration.RequireGlobalApplyCompatibility(
            target,
            Self(),
            current,
            [TestLedger("S-1-5-21-1-2-3-1002", Target(4566, 4567), Self())]));
    var differentSelf = new TailscaleSelfIdentity(
        "other.tail1234" + ".ts.net",
        ["100." + "64.0.2"]);
    AssertThrows<BrokerRefusalException>(() =>
        PrivilegedSystemConfiguration.RequireGlobalApplyCompatibility(
            target,
            Self(),
            current,
            [TestLedger("S-1-5-21-1-2-3-1002", target, differentSelf)]));
    AssertThrows<BrokerRefusalException>(() =>
        PrivilegedSystemConfiguration.RequireGlobalApplyCompatibility(
            target,
            Self(),
            TestLedger("S-1-5-21-1-2-3-1001", Target(4566, 4567), Self()),
            [TestLedger("S-1-5-21-1-2-3-1002", target, Self())]));
}

static void GlobalUninstallClassifiesOtherOwners()
{
    var target = Target(3456, 3457);
    var current = TestLedger("S-1-5-21-1-2-3-1001", target, Self());
    Assert(
        !PrivilegedSystemConfiguration.RequireGlobalUninstallCompatibility(
            current,
            Self(),
            target.TailscalePath,
            [TestLedger("S-1-5-21-1-2-3-1002", Target(4566, 4567), Self())]),
        "A different public port was incorrectly classified as the shared route.");
    AssertThrows<BrokerRefusalException>(() =>
        PrivilegedSystemConfiguration.RequireGlobalUninstallCompatibility(
            current,
            Self(),
            target.TailscalePath,
            [TestLedger("S-1-5-21-1-2-3-1002", Target(3456, 4457), Self())]));
    Assert(
        PrivilegedSystemConfiguration.RequireGlobalUninstallCompatibility(
            current,
            Self(),
            target.TailscalePath,
            [TestLedger("S-1-5-21-1-2-3-1002", target, Self())]),
        "An exact same-port owner was not classified as shared.");
}

static void GlobalOwnerStateRejectsUnsafeEntries()
{
    var root = NewTestRoot();
    const string ownerA = "S-1-5-21-1-2-3-1001";
    const string ownerB = "S-1-5-21-1-2-3-1002";
    var reparsePath = Path.Combine(
        PrivilegedBrokerPaths.GetStateRoot(root),
        "S-1-5-21-1-2-3-1003");
    var reparseTarget = Path.Combine(root, "other-owner-target");
    try
    {
        var storeA = BrokerStateStore.ForTests(root, ownerA);
        var storeB = BrokerStateStore.ForTests(root, ownerB);
        var pending = storeB.Begin(
            Request(Guid.NewGuid(), PrivilegedBrokerOperation.Apply, 3456, 3457),
            Target(3456, 3457),
            previous: null,
            legacyTask: null,
            Self());
        AssertThrows<BrokerRefusalException>(() =>
            storeA.LoadOtherOwnerAppliedLedgersForGlobalMutation());
        storeB.DiscardUnmutatedPending(pending);

        var unknownPath = Path.Combine(storeB.OwnerRoot, "unknown.bin");
        File.WriteAllText(unknownPath, "unknown", Encoding.UTF8);
        AssertThrows<InvalidDataException>(() =>
            storeA.LoadOtherOwnerAppliedLedgersForGlobalMutation());
        File.Delete(unknownPath);

        var incompleteAtomicPath = Path.Combine(
            storeB.OwnerRoot,
            PrivilegedBrokerPaths.AppliedLedgerFileName + "." +
            Guid.NewGuid().ToString("N") + ".tmp");
        File.WriteAllText(incompleteAtomicPath, "partial", Encoding.UTF8);
        AssertThrows<BrokerRefusalException>(() =>
            storeA.LoadOtherOwnerAppliedLedgersForGlobalMutation());
        File.Delete(incompleteAtomicPath);

        Directory.CreateDirectory(reparseTarget);
        CreateDirectoryReparseOrSkip(reparsePath, reparseTarget);
        AssertThrows<InvalidDataException>(() =>
            storeA.LoadOtherOwnerAppliedLedgersForGlobalMutation());
    }
    finally
    {
        if (Directory.Exists(reparsePath) &&
            (File.GetAttributes(reparsePath) & FileAttributes.ReparsePoint) != 0)
        {
            Directory.Delete(reparsePath, recursive: false);
        }
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void RetirementCrashBoundariesConverge()
{
    var boundaries = new[]
    {
        "retirement-receipt-written",
        "owner-state-deleted",
        "state-root-deleted",
        "delete-authorized-canonical",
        "delete-authorized-installation-receipt",
        "delete-authorized-retirement-receipt",
        "delete-authorized-version-root",
        "delete-authorized-broker-root",
        "delete-authorized-product-root",
        "reboot-delete-canonical"
    };
    foreach (var boundary in boundaries)
    {
        var fixture = NewRetirementFixture();
        var armed = true;
        try
        {
            AssertThrows<InjectedFaultException>(() =>
                ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                    fixture.Request,
                    fixture.OwnerSid,
                    fixture.Store,
                    fixture.Version,
                    observed =>
                    {
                        if (armed && string.Equals(observed, boundary, StringComparison.Ordinal))
                        {
                            armed = false;
                            throw new InjectedFaultException(observed);
                        }
                    }));
            var recovered = BrokerStateStore.ForTests(fixture.Root, fixture.OwnerSid);
            Assert(
                ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                    fixture.Request,
                    fixture.OwnerSid,
                    recovered,
                    fixture.Version),
                $"Retirement did not converge after {boundary}.");
            AssertRetirementConverged(fixture);
        }
        finally
        {
            Directory.Delete(fixture.Root, recursive: true);
        }
    }
}

static void RetirementRepairsMissingInstallationReceipt()
{
    var fixture = NewRetirementFixture();
    try
    {
        AssertThrows<InjectedFaultException>(() =>
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                fixture.Store,
                fixture.Version,
                boundary =>
                {
                    if (boundary == "retirement-receipt-written")
                    {
                        throw new InjectedFaultException(boundary);
                    }
                }));
        var installationReceipt = PrivilegedBrokerPaths.GetInstallationReceiptPath(
            fixture.Root,
            fixture.Version);
        File.Delete(installationReceipt);

        var recoveryStore = BrokerStateStore.ForTests(fixture.Root, fixture.OwnerSid);
        AssertThrows<InjectedFaultException>(() =>
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                recoveryStore,
                fixture.Version,
                boundary =>
                {
                    if (boundary == "installation-receipt-restored")
                    {
                        throw new InjectedFaultException(boundary);
                    }
                }));
        Assert(
            File.Exists(installationReceipt),
            "Retirement did not durably restore the missing installation receipt.");
        Assert(
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                BrokerStateStore.ForTests(fixture.Root, fixture.OwnerSid),
                fixture.Version),
            "Retirement did not converge after installation receipt restoration.");
        AssertRetirementConverged(fixture);
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void RetirementSchedulesOnlyCanonicalDeletion()
{
    var fixture = NewRetirementFixture();
    try
    {
        var boundaries = new List<string>();
        Assert(
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                fixture.Store,
                fixture.Version,
                boundaries.Add),
            "Retirement did not reach its deletion handoff.");
        var rebootBoundaries = boundaries
            .Where(value => value.StartsWith("reboot-delete-", StringComparison.Ordinal))
            .ToArray();
        Assert(
            rebootBoundaries.SequenceEqual(["reboot-delete-canonical"], StringComparer.Ordinal),
            "Retirement scheduled authority receipts or directories for reboot deletion.");
        Assert(
            File.Exists(PrivilegedBrokerPaths.GetInstallationReceiptPath(
                fixture.Root,
                fixture.Version)) &&
            File.Exists(PrivilegedBrokerPaths.GetRetirementReceiptPath(
                fixture.Root,
                fixture.Version)),
            "Retirement removed an authority receipt before canonical process exit.");
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void RetirementResponseLossConverges()
{
    var fixture = NewRetirementFixture();
    try
    {
        Assert(
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                fixture.Store,
                fixture.Version),
            "Initial retirement did not require post-exit deletion.");
        var replayStore = BrokerStateStore.ForTests(fixture.Root, fixture.OwnerSid);
        Assert(
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                replayStore,
                fixture.Version),
            "Retirement response loss did not replay idempotently.");
        AssertRetirementConverged(fixture);
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void RetirementRejectsDifferentTransaction()
{
    var fixture = NewRetirementFixture();
    try
    {
        AssertThrows<InjectedFaultException>(() =>
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                fixture.Store,
                fixture.Version,
                boundary =>
                {
                    if (boundary == "retirement-receipt-written")
                    {
                        throw new InjectedFaultException(boundary);
                    }
                }));

        var receiptPath = PrivilegedBrokerPaths.GetRetirementReceiptPath(
            fixture.Root,
            fixture.Version);
        var receiptBefore = File.ReadAllBytes(receiptPath);
        var canonicalBefore = File.ReadAllBytes(fixture.CanonicalPath);
        var ownerRoot = PrivilegedBrokerPaths.GetOwnerStateRoot(
            fixture.Root,
            fixture.OwnerSid);
        var wrongTransaction = Request(
            Guid.NewGuid(),
            PrivilegedBrokerOperation.UninstallCleanup);

        AssertThrows<BrokerRefusalException>(() =>
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                wrongTransaction,
                fixture.OwnerSid,
                BrokerStateStore.ForTests(fixture.Root, fixture.OwnerSid),
                fixture.Version));
        Assert(
            File.ReadAllBytes(receiptPath).SequenceEqual(receiptBefore),
            "Wrong-transaction retry changed the protected retirement receipt.");
        Assert(
            File.ReadAllBytes(fixture.CanonicalPath).SequenceEqual(canonicalBefore),
            "Wrong-transaction retry changed the canonical broker.");
        Assert(
            Directory.Exists(ownerRoot),
            "Wrong-transaction retry removed protected owner state.");

        Assert(
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                BrokerStateStore.ForTests(fixture.Root, fixture.OwnerSid),
                fixture.Version),
            "Exact-transaction retry did not resume retirement.");
        AssertRetirementConverged(fixture);
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void RetirementPreservesAnotherOwner()
{
    var fixture = NewRetirementFixture();
    var otherOwnerRoot = PrivilegedBrokerPaths.GetOwnerStateRoot(
        fixture.Root,
        "S-1-5-21-1-2-3-1002");
    Directory.CreateDirectory(otherOwnerRoot);
    try
    {
        Assert(
            !ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                fixture.Store,
                fixture.Version),
            "Shared broker was retired while another owner state existed.");
        Assert(Directory.Exists(otherOwnerRoot), "Another owner's protected state was removed.");
        Assert(
            !ProtectedBrokerRetirement.ReceiptExists(fixture.Root, fixture.Version),
            "Shared-owner cleanup created a retirement receipt.");
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void RetirementRejectsUnknownStateEntry()
{
    var fixture = NewRetirementFixture();
    try
    {
        File.WriteAllText(
            Path.Combine(PrivilegedBrokerPaths.GetStateRoot(fixture.Root), "unexpected"),
            "x",
            Encoding.UTF8);
        AssertThrows<InvalidDataException>(() =>
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                fixture.Store,
                fixture.Version));
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void RetirementRejectsReparseStateEntry()
{
    var fixture = NewRetirementFixture();
    var target = Path.Combine(fixture.Root, "link-target");
    var link = Path.Combine(PrivilegedBrokerPaths.GetStateRoot(fixture.Root), "S-1-5-21-9-9-9-1009");
    try
    {
        Directory.CreateDirectory(target);
        try
        {
            Directory.CreateSymbolicLink(link, target);
        }
        catch (Exception exception) when (
            exception is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe"),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            startInfo.ArgumentList.Add("/d");
            startInfo.ArgumentList.Add("/c");
            startInfo.ArgumentList.Add("mklink");
            startInfo.ArgumentList.Add("/J");
            startInfo.ArgumentList.Add(link);
            startInfo.ArgumentList.Add(target);
            using var junction = Process.Start(startInfo) ??
                throw new TestSkippedException(
                    "Junction helper could not start for the reparse negative fixture.");
            junction.WaitForExit();
            if (junction.ExitCode != 0 || !Directory.Exists(link))
            {
                throw new TestSkippedException(
                    "Symlink and junction creation are unavailable for the reparse negative fixture.");
            }
        }
        AssertThrows<InvalidDataException>(() =>
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                fixture.Store,
                fixture.Version));
    }
    finally
    {
        if (Directory.Exists(link) &&
            (File.GetAttributes(link) & FileAttributes.ReparsePoint) != 0)
        {
            Directory.Delete(link, recursive: false);
        }
        if (Directory.Exists(fixture.Root))
        {
            Directory.Delete(fixture.Root, recursive: true);
        }
    }
}

static void RetirementRejectsIdentityMismatch()
{
    var fixture = NewRetirementFixture();
    try
    {
        AssertThrows<InjectedFaultException>(() =>
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                fixture.Store,
                fixture.Version,
                boundary =>
                {
                    if (boundary == "retirement-receipt-written")
                    {
                        throw new InjectedFaultException(boundary);
                    }
                }));
        File.AppendAllText(fixture.CanonicalPath, "tampered", Encoding.UTF8);
        var recovered = BrokerStateStore.ForTests(fixture.Root, fixture.OwnerSid);
        AssertThrows<InvalidDataException>(() =>
            ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
                fixture.Request,
                fixture.OwnerSid,
                recovered,
                fixture.Version));
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void RetirementReceiptIsStrict()
{
    var fixture = NewRetirementFixture();
    try
    {
        _ = ProtectedBrokerRetirement.RetireIfLastOwnerForTests(
            fixture.Request,
            fixture.OwnerSid,
            fixture.Store,
            fixture.Version);
        var receiptPath = PrivilegedBrokerPaths.GetRetirementReceiptPath(
            fixture.Root,
            fixture.Version);
        var json = File.ReadAllText(receiptPath, Encoding.UTF8);
        ProtectedBrokerRetirement.ValidateReceiptJsonForTests(json, fixture.Version);
        var unknown = json.TrimEnd().TrimEnd('}') + ",\"unexpected\":true}";
        AssertThrows<InvalidDataException>(() =>
            ProtectedBrokerRetirement.ValidateReceiptJsonForTests(unknown, fixture.Version));
        AssertThrows<BrokerRefusalException>(() =>
            ProtectedBrokerRetirement.RequireReceiptOwnerForTests(
                fixture.Root,
                fixture.Version,
                "S-1-5-21-1-2-3-1002"));
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void RetirementRightsAreDeleteOnly()
{
    Assert(
        ProtectedBrokerRetirement.AreRetirementOwnerRightsDeleteOnly(
            FileSystemRights.Delete | FileSystemRights.Read),
        "Delete plus read was not accepted for retirement cleanup.");
    foreach (var forbidden in new[]
             {
                 FileSystemRights.WriteData,
                 FileSystemRights.CreateFiles,
                 FileSystemRights.DeleteSubdirectoriesAndFiles,
                 FileSystemRights.ChangePermissions,
                 FileSystemRights.TakeOwnership
             })
    {
        Assert(
            !ProtectedBrokerRetirement.AreRetirementOwnerRightsDeleteOnly(
                FileSystemRights.Delete | forbidden),
            $"Forbidden retirement right was accepted: {forbidden}");
    }
}

static void BootstrapRepairsReceiptlessCanonical()
{
    var fixture = NewBootstrapRecoveryFixture(canonicalMatchesSource: true);
    try
    {
        var identity = ProtectedBrokerInstallation.RecoverReceiptlessCanonicalForTests(
            fixture.Root,
            fixture.Version,
            fixture.SourcePath);
        Assert(identity.Length > 0, "Recovered bootstrap identity was empty.");
        Assert(
            File.Exists(PrivilegedBrokerPaths.GetInstallationReceiptPath(
                fixture.Root,
                fixture.Version)),
            "Receipt-less exact canonical did not regenerate installation.json.");
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void BootstrapRejectsIdentityMismatch()
{
    var fixture = NewBootstrapRecoveryFixture(canonicalMatchesSource: false);
    try
    {
        AssertThrows<InvalidDataException>(() =>
            ProtectedBrokerInstallation.RecoverReceiptlessCanonicalForTests(
                fixture.Root,
                fixture.Version,
                fixture.SourcePath));
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void BootstrapRejectsHardLinkedCanonical()
{
    var fixture = NewBootstrapRecoveryFixture(canonicalMatchesSource: true);
    var canonical = PrivilegedBrokerPaths.GetProtectedExecutablePath(
        fixture.Root,
        fixture.Version);
    var hardLink = Path.Combine(fixture.Root, "canonical-hardlink.exe");
    try
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe"),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("/d");
        startInfo.ArgumentList.Add("/c");
        startInfo.ArgumentList.Add("mklink");
        startInfo.ArgumentList.Add("/H");
        startInfo.ArgumentList.Add(hardLink);
        startInfo.ArgumentList.Add(canonical);
        using var process = Process.Start(startInfo) ??
            throw new TestSkippedException("Hard-link fixture helper did not start.");
        process.WaitForExit();
        if (process.ExitCode != 0 || !File.Exists(hardLink))
        {
            throw new TestSkippedException("Hard-link creation is unavailable.");
        }
        AssertThrows<InvalidDataException>(() =>
            ProtectedBrokerInstallation.RecoverReceiptlessCanonicalForTests(
                fixture.Root,
                fixture.Version,
                fixture.SourcePath));
    }
    finally
    {
        if (File.Exists(hardLink))
        {
            File.Delete(hardLink);
        }
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void BootstrapRejectsOrphanedInstallationReceipt()
{
    const string version = "2.0.0";
    var root = NewTestRoot();
    try
    {
        var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(root, version);
        Directory.CreateDirectory(versionRoot);
        var receiptPath = PrivilegedBrokerPaths.GetInstallationReceiptPath(root, version);
        var receiptBytes = Encoding.UTF8.GetBytes("protected orphan receipt");
        File.WriteAllBytes(receiptPath, receiptBytes);

        AssertThrows<InvalidDataException>(() =>
            ProtectedBrokerInstallation.RejectOrphanedInstallationReceiptForTests(
                root,
                version));
        Assert(
            !File.Exists(PrivilegedBrokerPaths.GetProtectedExecutablePath(root, version)),
            "Orphaned installation receipt recovery created a new canonical broker.");
        Assert(
            File.ReadAllBytes(receiptPath).SequenceEqual(receiptBytes),
            "Orphaned installation receipt was modified instead of failing closed.");
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
}

static void BootstrapCleansStrictTemporaries()
{
    var fixture = NewBootstrapRecoveryFixture(canonicalMatchesSource: true);
    var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(fixture.Root, fixture.Version);
    var copyTemporary = Path.Combine(
        versionRoot,
        "." + PrivilegedBrokerPaths.BrokerFileName + "." + Guid.NewGuid().ToString("N") + ".tmp");
    var receiptTemporary = Path.Combine(
        versionRoot,
        PrivilegedBrokerPaths.InstallationReceiptFileName + "." + Guid.NewGuid().ToString("N") + ".tmp");
    var unrelated = Path.Combine(versionRoot, "unrelated.tmp");
    try
    {
        File.WriteAllText(copyTemporary, "copy", Encoding.UTF8);
        File.WriteAllText(receiptTemporary, "receipt", Encoding.UTF8);
        File.WriteAllText(unrelated, "preserve", Encoding.UTF8);
        ProtectedBrokerInstallation.CleanupInstallationTemporariesForTests(
            fixture.Root,
            fixture.Version);
        Assert(!File.Exists(copyTemporary), "Strict broker-copy temporary remained.");
        Assert(!File.Exists(receiptTemporary), "Strict receipt temporary remained.");
        Assert(File.Exists(unrelated), "Unrelated temporary was removed.");
    }
    finally
    {
        Directory.Delete(fixture.Root, recursive: true);
    }
}

static void LegacyCustomInstallRootIsDiscovered()
{
    var transactionId = Guid.NewGuid();
    var localAppData = Path.Combine(Path.GetTempPath(), "profile", "AppData", "Local");
    var custom = Path.Combine(Path.GetTempPath(), "custom-v121");
    var candidates = LegacyV121Evidence.BuildInstallCandidatePathsForTests(
        localAppData,
        custom,
        transactionId);
    Assert(candidates.Contains(Path.GetFullPath(custom), StringComparer.OrdinalIgnoreCase),
        "Registered custom v1.2.1 install root was not discovered.");
    Assert(candidates.Contains(
            Path.GetFullPath(custom) + ".backup-" + transactionId.ToString("N"),
            StringComparer.OrdinalIgnoreCase),
        "Custom v1.2.1 transaction backup root was not discovered.");
}

static void LegacyOwnerPathsUseAuthenticatedProfile()
{
    var root = NewTestRoot();
    try
    {
        var profile = Path.Combine(root, "Profiles", "Dawn");
        var systemDrive = Path.GetPathRoot(root)?.TrimEnd(Path.DirectorySeparatorChar) ??
            throw new InvalidOperationException("The test drive root is unavailable.");
        var redirected = Path.Combine(root, "Redirected", "LocalAppData");
        Assert(
            string.Equals(
                LegacyV121Evidence.ExpandOwnerDataPathForTests(
                    @"%USERPROFILE%\AppData\Local",
                    profile,
                    systemDrive),
                Path.Combine(profile, "AppData", "Local"),
                StringComparison.OrdinalIgnoreCase),
            "Original-user USERPROFILE expansion used a different account profile.");
        Assert(
            string.Equals(
                LegacyV121Evidence.ExpandOwnerDataPathForTests(
                    @"%HOMEDRIVE%%HOMEPATH%\LocalState",
                    profile,
                    systemDrive),
                Path.Combine(profile, "LocalState"),
                StringComparison.OrdinalIgnoreCase),
            "Original-user HOMEDRIVE/HOMEPATH expansion was not deterministic.");
        Assert(
            string.Equals(
                LegacyV121Evidence.ExpandOwnerDataPathForTests(
                    redirected,
                    profile,
                    systemDrive),
                redirected,
                StringComparison.OrdinalIgnoreCase),
            "A fixed-drive redirected Local AppData path was not preserved.");
        AssertThrows<InvalidDataException>(() =>
            LegacyV121Evidence.ExpandOwnerDataPathForTests(
                @"%USERPROFILE%\%ADMINPROFILE%\Local",
                profile,
                systemDrive));
        AssertThrows<InvalidDataException>(() =>
            LegacyV121Evidence.ExpandOwnerDataPathForTests(
                "relative\\Local",
                profile,
                systemDrive));
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
}

static void LegacyTaskAcceptsRedirectedOwnerLauncherPaths()
{
    const string ownerName = "FixtureOwner";
    var profile = FixedDrivePath('D', "Profiles", ownerName);
    var redirectedLocalAppData = FixedDrivePath('E', "Redirected", ownerName, "Local");
    Assert(
        LegacyScheduledTask.IsAllowedLauncherPathForTests(
            profile,
            redirectedLocalAppData,
            Path.Combine(
                redirectedLocalAppData,
                "EvenTerminalCodex",
                "Start-EvenTerminalCodex.ps1")),
        "A redirected original-user Local AppData launcher was rejected.");
    Assert(
        LegacyScheduledTask.IsAllowedLauncherPathForTests(
            profile,
            redirectedLocalAppData,
            Path.Combine(
                profile,
                "AppData",
                "Local",
                "EvenTerminalCodex",
                "Start-EvenTerminalCodex.ps1")),
        "The original-profile legacy launcher was rejected.");
    Assert(
        LegacyScheduledTask.IsAllowedLauncherPathForTests(
            profile,
            redirectedLocalAppData,
            FixedDrivePath(
                'F',
                "Users",
                ownerName,
                "Apps",
                "even-terminal",
                "Start-EvenTerminalCodex.ps1")),
        "A fixed-drive legacy launcher was rejected.");
    Assert(
        !LegacyScheduledTask.IsAllowedLauncherPathForTests(
            profile,
            redirectedLocalAppData,
            FixedDrivePath(
                'C',
                "Users",
                "DifferentOwner",
                "AppData",
                "Local",
                "EvenTerminalCodex",
                "Start-EvenTerminalCodex.ps1")),
        "A different account launcher was accepted.");
}

static string FixedDrivePath(char driveLetter, params string[] segments)
{
    var root = string.Concat(
        char.ToUpperInvariant(driveLetter),
        Path.VolumeSeparatorChar,
        Path.DirectorySeparatorChar);
    return Path.Combine([root, .. segments]);
}

static void LegacyCustomPortsAreReadExactly()
{
    var root = NewTestRoot();
    try
    {
        var dataRoot = Path.Combine(root, "AppData", "Local", "legacy");
        Directory.CreateDirectory(dataRoot);
        var path = Path.Combine(dataRoot, "applied.json");
        var tailscalePath = @"C:\Program Files\Tailscale\tailscale.exe";
        File.WriteAllText(
            path,
            "{\"publicPort\":4566,\"backendPort\":4567,\"tailscalePath\":\"" +
            tailscalePath.Replace("\\", "\\\\", StringComparison.Ordinal) + "\"}",
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        var configuration = LegacyV121Evidence.ReadAppliedForTests(
            root,
            path,
            tailscalePath);
        Assert(
            configuration.PublicPort == 4566 && configuration.BackendPort == 4567,
            "Custom v1.2.1 ports were not preserved from exact applied evidence.");
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
}

static void InstalledTailscaleValidationProbe()
{
    var path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        "Tailscale",
        "tailscale.exe");
    if (!File.Exists(path))
    {
        throw new TestSkippedException("Tailscale executable is not installed.");
    }
    _ = TrustedTailscale.Resolve("S-1-5-21-1-2-3-1001");
}

static RetirementTestFixture NewRetirementFixture()
{
    const string ownerSid = "S-1-5-21-1-2-3-1001";
    const string version = "2.0.0";
    var root = NewTestRoot();
    var store = BrokerStateStore.ForTests(root, ownerSid);
    var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(root, version);
    Directory.CreateDirectory(versionRoot);
    var canonicalPath = PrivilegedBrokerPaths.GetProtectedExecutablePath(root, version);
    File.WriteAllBytes(canonicalPath, Encoding.UTF8.GetBytes("fixed broker test image"));
    var canonicalIdentity = ProtectedBrokerInstallation.ReadIdentity(
        canonicalPath,
        version);
    File.WriteAllText(
        PrivilegedBrokerPaths.GetInstallationReceiptPath(root, version),
        JsonSerializer.Serialize(
            canonicalIdentity,
            new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase
            }),
        Encoding.UTF8);
    return new RetirementTestFixture(
        root,
        ownerSid,
        version,
        canonicalPath,
        store,
        Request(Guid.NewGuid(), PrivilegedBrokerOperation.UninstallCleanup));
}

static BootstrapRecoveryFixture NewBootstrapRecoveryFixture(bool canonicalMatchesSource)
{
    const string version = "2.0.0";
    var root = NewTestRoot();
    var versionRoot = PrivilegedBrokerPaths.GetVersionRoot(root, version);
    Directory.CreateDirectory(versionRoot);
    var sourcePath = Path.Combine(root, "source-broker.exe");
    var sourceBytes = Encoding.UTF8.GetBytes("locked bootstrap source image");
    File.WriteAllBytes(sourcePath, sourceBytes);
    File.WriteAllBytes(
        PrivilegedBrokerPaths.GetProtectedExecutablePath(root, version),
        canonicalMatchesSource
            ? sourceBytes
            : Encoding.UTF8.GetBytes("mismatched canonical image"));
    return new BootstrapRecoveryFixture(root, version, sourcePath);
}

static void AssertRetirementConverged(RetirementTestFixture fixture)
{
    Assert(
        ProtectedBrokerRetirement.ReceiptExists(fixture.Root, fixture.Version),
        "Protected retirement receipt was not durable.");
    Assert(
        !Directory.Exists(PrivilegedBrokerPaths.GetOwnerStateRoot(
            fixture.Root,
            fixture.OwnerSid)),
        "Retired owner State directory remained.");
    Assert(
        !Directory.Exists(PrivilegedBrokerPaths.GetStateRoot(fixture.Root)),
        "Empty protected State root remained.");
    Assert(File.Exists(fixture.CanonicalPath),
        "Canonical broker was removed before the Medium client handoff.");
}

static BrokerPendingJournal PrepareCompletedApply(
    BrokerStateStore store,
    Guid transactionId,
    BrokerSystemConfiguration target,
    BrokerSystemConfiguration? previous = null)
{
    var pending = store.Begin(
        Request(transactionId, PrivilegedBrokerOperation.Apply, target.PublicPort, target.BackendPort),
        target,
        previous,
        null,
        Self());
    return store.Update(transactionId, current => current with
    {
        Phase = BrokerMutationPhase.MutationsCompleted,
        AppliedLedgerMutationAuthorized = true,
        AppliedLedgerCommitTimeUtc = DateTimeOffset.UtcNow
    });
}

static BrokerAppliedLedger CommitTestLedger(
    BrokerStateStore store,
    BrokerSystemConfiguration target)
{
    var pending = PrepareCompletedApply(store, Guid.NewGuid(), target);
    store.CommitApplied(pending);
    return store.LoadApplied() ??
        throw new InvalidOperationException("Test applied ledger was not committed.");
}

static BrokerAppliedLedger TestLedger(
    string ownerSid,
    BrokerSystemConfiguration configuration,
    TailscaleSelfIdentity self) =>
    new(
        BrokerStateStore.SchemaVersion,
        ownerSid,
        configuration,
        self,
        DateTimeOffset.UtcNow);

static void CreateDirectoryReparseOrSkip(string link, string target)
{
    try
    {
        Directory.CreateSymbolicLink(link, target);
        return;
    }
    catch (Exception exception) when (
        exception is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe"),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("/d");
        startInfo.ArgumentList.Add("/c");
        startInfo.ArgumentList.Add("mklink");
        startInfo.ArgumentList.Add("/J");
        startInfo.ArgumentList.Add(link);
        startInfo.ArgumentList.Add(target);
        using var junction = Process.Start(startInfo) ??
            throw new TestSkippedException(
                "Junction helper could not start for the global State fixture.");
        junction.WaitForExit();
        if (junction.ExitCode != 0 || !Directory.Exists(link))
        {
            throw new TestSkippedException(
                "Symlink and junction creation are unavailable for the global State fixture.");
        }
    }
}

static PrivilegedBrokerRequest Request(
    Guid transactionId,
    PrivilegedBrokerOperation operation,
    int? publicPort = null,
    int? backendPort = null) =>
    new(
        PrivilegedBrokerProtocol.SchemaVersion,
        transactionId,
        new string('a', 64),
        operation,
        PrivilegedBrokerInitiator.Interactive,
        publicPort,
        backendPort,
        false);

static BrokerSystemConfiguration Target(int publicPort, int backendPort) =>
    new(publicPort, backendPort, @"C:\Program Files\Tailscale\tailscale.exe");

static TailscaleSelfIdentity Self() =>
    new("device.tail1234" + ".ts.net", ["100." + "64.0.1"]);

static string ServeStatus(int publicPort, int backendPort) =>
    "{\"TCP\":{\"" + publicPort + "\":{\"HTTP\":true}}," +
    "\"Web\":{\"device.example.invalid:" + publicPort + "\":{\"Handlers\":{" +
    "\"/\":{\"Proxy\":\"http://127.0.0.1:" + backendPort + "\"}}}}}";

static void AssertUnowned(string json, string message) =>
    Assert(
        TailscaleServeStatus.ReadRootSnapshot(json, 3456, [3457]).State ==
            ServeRootState.Unowned,
        message);

static string NewTestRoot()
{
    var path = Path.Combine(Path.GetTempPath(), $"EverVigil.Broker.Tests-{Guid.NewGuid():N}");
    Directory.CreateDirectory(path);
    return path;
}

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static void AssertThrows<TException>(Action action)
    where TException : Exception
{
    try
    {
        action();
    }
    catch (TException)
    {
        return;
    }
    throw new InvalidOperationException($"Expected {typeof(TException).Name} was not thrown.");
}

sealed class InjectedFaultException(string boundary) : Exception(boundary);

sealed class TestSkippedException(string message) : Exception(message);

sealed record RetirementTestFixture(
    string Root,
    string OwnerSid,
    string Version,
    string CanonicalPath,
    BrokerStateStore Store,
    PrivilegedBrokerRequest Request);

sealed record BootstrapRecoveryFixture(
    string Root,
    string Version,
    string SourcePath);
