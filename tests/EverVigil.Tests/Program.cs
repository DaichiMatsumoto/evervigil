using System.Collections;
using System.Globalization;
using System.Resources;
using EverVigil;
using EverVigil.Core;
using EverVigil.Core.Localization;
using EverVigil.Infrastructure;
using EverVigil.UI;

if (args.Length == 2 &&
    string.Equals(args[0], "--connect-pid-test-pipe", StringComparison.Ordinal))
{
    using var client = new System.IO.Pipes.NamedPipeClientStream(
        ".",
        args[1],
        System.IO.Pipes.PipeDirection.InOut,
        System.IO.Pipes.PipeOptions.Asynchronous);
    client.Connect(10_000);
    return client.ReadByte() == 1 ? 0 : 2;
}

if (args.Length is >= 2 and <= 4 &&
    string.Equals(args[0], "--render-dashboard-preview", StringComparison.Ordinal))
{
    var tabIndex = args.Length >= 3
        ? int.Parse(args[2], System.Globalization.CultureInfo.InvariantCulture)
        : 1;
    var language = args.Length == 4 ? args[3] : "system";
    return DashboardPreviewRenderer.Render(args[1], tabIndex, language);
}

var tests = new (string Name, Action Run)[]
{
    ("default settings are structurally valid", DefaultSettingsAreValid),
    ("English and Japanese resources have matching complete keys", LocalizationResourcesAreComplete),
    ("application localization smoke check resolves both languages", ApplicationLocalizationSmokeCheck),
    ("display language selection is strict and switches at runtime", DisplayLanguageContract),
    ("legacy migration discovers portable dependencies", LegacyMigrationDiscoversPortableDependencies),
    ("Even Terminal CLI discovery preserves PATH precedence", EvenTerminalCliDiscoveryPreservesPathPrecedence),
    ("legacy defaults replace only newly created settings", LegacyDefaultsReplaceOnlyNewSettings),
    ("incomplete legacy defaults remain configurable", IncompleteLegacyDefaultsRemainConfigurable),
    ("invalid ports are rejected", InvalidPortsAreRejected),
    ("service ports must be distinct", DuplicatePortsAreRejected),
    ("production settings reject a custom Tailscale executable", CustomTailscalePathIsRejected),
    ("persisted custom Tailscale path is normalized and blocked", PersistedCustomTailscalePathIsNormalized),
    ("session health URI is loopback-only", SessionHealthUriIsLoopbackOnly),
    ("protected Tailscale identity requires matched evidence", ProtectedTailscaleIdentityRequiresMatchedEvidence),
    ("live Tailscale identity rejects stale DNS and logout", LiveTailscaleIdentityRejectsStaleDnsAndLogout),
    ("current Serve route must match the protected target", CurrentServeRouteMustMatchProtectedTarget),
    ("Serve status child inherits no credential environment", ServeStatusChildInheritsNoCredentialEnvironment),
    ("bridge children inherit only the explicit runtime environment", BridgeChildrenInheritOnlyExplicitRuntimeEnvironment),
    ("token generation is valid and unique", TokenGenerationIsValidAndUnique),
    ("connection URL contains required provider", ConnectionUrlContainsProvider),
    ("connection URL brackets IPv6 hosts", ConnectionUrlBracketsIpv6Host),
    ("invalid token cannot enter a URL", InvalidTokenIsRejected),
    ("redactor removes query tokens", RedactorRemovesQueryTokens),
    ("redactor removes bearer tokens", RedactorRemovesBearerTokens),
    ("redactor removes known secrets", RedactorRemovesKnownSecrets),
    ("session health payload requires a sessions array", SessionHealthPayloadRequiresSessionsArray),
    ("clipboard clear retries after a transient lock", ClipboardClearRetriesAfterTransientLock),
    ("clipboard disposal retries beyond the short UI retry window", ClipboardDisposeRetriesUntilClear),
    ("backoff grows and caps", BackoffGrowsAndCaps),
    ("backoff rejects invalid construction", BackoffRejectsInvalidConstruction),
    ("restart signal interrupts a pending delay", RestartSignalInterruptsDelay),
    ("restart signal survives a completed delay", RestartSignalSurvivesCompletedDelay),
    ("single instance acquires an existing unowned mutex", SingleInstanceAcquiresExistingUnownedMutex),
    ("single-instance kernel objects grant the current user full control", SingleInstanceObjectsGrantCurrentUserAccess),
    ("default single-instance scope spans login sessions", DefaultSingleInstanceScopeSpansLoginSessions),
    ("system transaction reopens with least privilege", SystemTransactionReopensWithLeastPrivilege),
    ("headless control commands suppress startup error dialogs", HeadlessCommandsSuppressStartupErrorDialogs),
    ("headless failures are safe for installer diagnostics", HeadlessFailuresAreSafeForInstallerDiagnostics),
    ("atomic files receive their protected ACL at creation", AtomicFilesReceiveProtectedAclAtCreation),
    ("atomic replacement preserves the protected ACL", AtomicReplacementPreservesProtectedAcl),
    ("startup waits for dependency configuration", StartupWaitsForDependencyConfiguration),
    ("installer health accepts the pre-commit runtime", InstallerHealthAcceptsPreCommitRuntime),
    ("concurrent token stores converge on one token", ConcurrentTokenStoresConvergeOnOneToken),
    ("legacy import preserves an existing DPAPI token", LegacyImportPreservesExistingDpapiToken),
    ("DPAPI token storage does not contain plaintext", DpapiTokenStorageIsEncrypted),
    ("failed token persistence keeps the cached token", FailedTokenPersistenceKeepsCachedToken),
    ("unreadable DPAPI token is quarantined", UnreadableTokenIsQuarantined),
    ("missing settings require system configuration", MissingSettingsRequireSystemConfiguration),
    ("invalid settings require system configuration", InvalidSettingsRequireSystemConfiguration),
    ("applied system configuration is recorded before unblocking", AppliedSystemConfigurationIsRecordedBeforeUnblocking),
    ("pending system journal commits only after durable mutation phases", PendingSystemJournalCommitsAfterDurablePhases),
    ("pending system journal rejects premature commit and mismatched transaction", PendingSystemJournalRejectsUnsafeCompletion),
    ("application cannot consume an installer-owned pending journal", InstallerPendingJournalIsNotCommittedByApplication),
    ("installer system configuration commits only by exact transaction", InstallerSystemConfigurationRequiresExactTransaction),
    ("installer PowerShell journal matches the production JSON contract", InstallerPowerShellJournalMatchesProductionContract),
    ("applied system configuration survives settings recovery", AppliedSystemConfigurationSurvivesSettingsRecovery),
    ("failed applied-state persistence keeps startup blocked", FailedAppliedStatePersistenceKeepsStartupBlocked),
    ("required system configuration blocks supervisor start", RequiredSystemConfigurationBlocksSupervisorStart),
    ("log clearing removes active and rotated generations", LogClearingRemovesActiveAndRotatedGenerations),
    ("log writes prune generations above a reduced limit", LogWritesPruneGenerationsAboveReducedLimit),
    ("QR renderer produces a nonblank bitmap", QrRendererProducesBitmap),
    ("placeholder brand asset and compact window contract", PlaceholderBrandAssetAndCompactWindowContract),
    ("application metadata exposes copyleft and copyright", ApplicationMetadataContract),
    ("status text colors meet WCAG AA contrast", StatusTextColorsMeetWcagContrast),
    ("concurrent bridge stops share one lifecycle task", ConcurrentBridgeStopsShareOneLifecycleTask),
    ("bridge PID pipe rejects a different same-user process", BridgePidPipeRejectsDifferentProcess),
    ("bridge launcher contains immediate descendants in its job", BridgeLauncherContainsImmediateDescendants),
    ("job object terminates its assigned process", JobObjectTerminatesProcess),
    ("process runner drains stdout and stderr concurrently", ProcessRunnerDrainsBothStreams)
};

var failures = new List<string>();
foreach (var test in tests)
{
    try
    {
        test.Run();
        Console.WriteLine($"PASS  {test.Name}");
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

Console.WriteLine($"Executed {tests.Length} tests; passed {tests.Length - failures.Count}; failed {failures.Count}.");
return failures.Count == 0 ? 0 : 1;

static void DefaultSettingsAreValid()
{
    var errors = AppSettingsValidator.Validate(AppSettings.CreateDefault(), requireExistingPaths: false);
    Assert(errors.Count == 0, string.Join(" | ", errors));
}

static void LocalizationResourcesAreComplete()
{
    var resources = new ResourceManager(
        "EverVigil.Core.Localization.AppResources",
        typeof(AppLocalizer).Assembly);
    var english = resources.GetResourceSet(CultureInfo.GetCultureInfo("en-US"), true, true)
        ?? throw new InvalidOperationException("English resources were not found.");
    var japanese = resources.GetResourceSet(CultureInfo.GetCultureInfo("ja-JP"), true, true)
        ?? throw new InvalidOperationException("Japanese resources were not found.");

    static Dictionary<string, string> Read(ResourceSet resourceSet) => resourceSet
        .Cast<DictionaryEntry>()
        .ToDictionary(
            entry => (string)entry.Key,
            entry => entry.Value?.ToString() ?? string.Empty,
            StringComparer.Ordinal);

    var englishValues = Read(english);
    var japaneseValues = Read(japanese);
    Assert(
        englishValues.Keys.Order(StringComparer.Ordinal)
            .SequenceEqual(japaneseValues.Keys.Order(StringComparer.Ordinal), StringComparer.Ordinal),
        "English and Japanese resource keys differ.");
    Assert(
        englishValues.Count >= 120 &&
        englishValues.Values.All(value => !string.IsNullOrWhiteSpace(value)) &&
        japaneseValues.Values.All(value => !string.IsNullOrWhiteSpace(value)),
        "A localization resource is missing or empty.");
    Assert(
        englishValues.Values.All(value =>
            !value.Contains("telemetry", StringComparison.OrdinalIgnoreCase)) &&
        japaneseValues.Values.All(value =>
            !value.Contains("テレメトリ", StringComparison.Ordinal)),
        "Local-only runtime logs must not be presented as telemetry.");
    Assert(
        AppLocalizer.Text("TabOverview", CultureInfo.GetCultureInfo("fr-FR")) == "OVERVIEW",
        "Unsupported cultures do not fall back to English.");
}

static void ApplicationLocalizationSmokeCheck()
{
    Assert(
        EverVigil.Program.VerifyLocalizationResources(),
        "The application localization smoke check failed.");
}

static void DisplayLanguageContract()
{
    var notifications = 0;
    var previousUiCulture = CultureInfo.CurrentUICulture;
    EventHandler handler = (_, _) => notifications++;
    AppLocalizer.LanguageChanged += handler;
    try
    {
        Assert(AppLocalizer.IsSupportedLanguage("system"), "System language was rejected.");
        Assert(AppLocalizer.IsSupportedLanguage("EN"), "English language was rejected.");
        Assert(AppLocalizer.IsSupportedLanguage(" ja "), "Japanese language was rejected.");
        Assert(!AppLocalizer.IsSupportedLanguage("ja-JP"), "A noncanonical language was accepted.");
        Assert(!AppLocalizer.IsSupportedLanguage("fr"), "An unsupported language was accepted.");

        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("ja-JP");
        Assert(
            AppLocalizer.ResolveCulture("system").Name == "ja-JP",
            "System language did not follow the active Japanese display language.");
        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("fr-FR");
        Assert(
            AppLocalizer.ResolveCulture("system").Name == "en-US",
            "A non-Japanese display language did not fall back to English.");

        AppLocalizer.SetLanguage("ja");
        Assert(AppLocalizer.Text("TabOverview") == "概要", "Japanese was not activated.");
        AppLocalizer.SetLanguage("en");
        Assert(AppLocalizer.Text("TabOverview") == "OVERVIEW", "English was not activated.");
        Assert(notifications >= 2, "Runtime language changes were not published.");

        var invalid = AppSettings.CreateDefault() with { UiLanguage = "ja-JP" };
        Assert(
            AppSettingsValidator.Validate(invalid, false, CultureInfo.GetCultureInfo("en-US"))
                .Any(error => error.Contains("Display language", StringComparison.Ordinal)),
            "A noncanonical settings language was accepted.");
    }
    finally
    {
        AppLocalizer.LanguageChanged -= handler;
        CultureInfo.CurrentUICulture = previousUiCulture;
        AppLocalizer.SetLanguage("system");
    }
}

static void LegacyMigrationDiscoversPortableDependencies()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Legacy-{Guid.NewGuid():N}");
    var profileRoot = Path.Combine(root, "Profile");
    var appsRoot = Path.Combine(profileRoot, "Apps");
    var legacyRoot = Path.Combine(appsRoot, "even-terminal");
    var nodePath = Path.Combine(appsRoot, "nodejs", "node.exe");
    var cliPath = Path.Combine(
        appsRoot,
        "npm",
        "node_modules",
        "@evenrealities",
        "even-terminal",
        "bin",
        "cli.js");
    var tokenPath = Path.Combine(legacyRoot, "token.txt");
    try
    {
        Directory.CreateDirectory(Path.GetDirectoryName(nodePath)!);
        Directory.CreateDirectory(Path.GetDirectoryName(cliPath)!);
        Directory.CreateDirectory(legacyRoot);
        File.WriteAllText(nodePath, string.Empty);
        File.WriteAllText(cliPath, string.Empty);
        File.WriteAllText(tokenPath, new string('a', 32));

        var settings = EverVigil.Program.CreateLegacyMigrationDefaults(tokenPath, legacyRoot);

        Assert(settings.ProjectDirectory == profileRoot, "Legacy project directory was not preserved.");
        Assert(settings.NodePath == nodePath, "Legacy portable Node.js was not discovered.");
        Assert(settings.EvenTerminalCliPath == cliPath, "Legacy portable Even Terminal was not discovered.");
        var outsideToken = Path.Combine(root, "token.txt");
        File.WriteAllText(outsideToken, new string('b', 32));
        AssertThrows<InvalidDataException>(() =>
            EverVigil.Program.CreateLegacyMigrationDefaults(outsideToken, legacyRoot));
        File.WriteAllText(tokenPath, "not-a-valid-token");
        AssertThrows<InvalidDataException>(() =>
            EverVigil.Program.CreateLegacyMigrationDefaults(tokenPath, legacyRoot));
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void EvenTerminalCliDiscoveryPreservesPathPrecedence()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Path-{Guid.NewGuid():N}");
    var firstDirectory = Path.Combine(root, "first");
    var secondDirectory = Path.Combine(root, "second");
    var relativeCliPath = Path.Combine(
        "node_modules",
        "@evenrealities",
        "even-terminal",
        "bin",
        "cli.js");
    var firstCliPath = Path.Combine(firstDirectory, relativeCliPath);
    var secondCliPath = Path.Combine(secondDirectory, relativeCliPath);
    var originalPath = Environment.GetEnvironmentVariable(
        "PATH",
        EnvironmentVariableTarget.Process);
    try
    {
        Directory.CreateDirectory(Path.GetDirectoryName(firstCliPath)!);
        Directory.CreateDirectory(Path.GetDirectoryName(secondCliPath)!);
        File.WriteAllText(Path.Combine(firstDirectory, "even-terminal.cmd"), string.Empty);
        File.WriteAllText(Path.Combine(secondDirectory, "even-terminal.cmd"), string.Empty);
        File.WriteAllText(firstCliPath, string.Empty);
        File.WriteAllText(secondCliPath, string.Empty);
        var pathEntries = new[] { firstDirectory, secondDirectory, originalPath }
            .Where(entry => !string.IsNullOrWhiteSpace(entry));
        Environment.SetEnvironmentVariable(
            "PATH",
            string.Join(Path.PathSeparator, pathEntries),
            EnvironmentVariableTarget.Process);

        var settings = AppSettings.CreateDefault();

        Assert(
            string.Equals(
                settings.EvenTerminalCliPath,
                firstCliPath,
                StringComparison.OrdinalIgnoreCase),
            "Even Terminal CLI discovery reversed PATH precedence.");
    }
    finally
    {
        Environment.SetEnvironmentVariable(
            "PATH",
            originalPath,
            EnvironmentVariableTarget.Process);
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void IncompleteLegacyDefaultsRemainConfigurable()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Incomplete-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        Directory.CreateDirectory(root);
        var store = new EverVigil.Infrastructure.SettingsStore(paths);
        var incompleteDefaults = store.Current with
        {
            DisplayName = "LEGACY-INCOMPLETE",
            ProjectDirectory = root,
            NodePath = Path.Combine(root, "missing-node.exe"),
            EvenTerminalCliPath = Path.Combine(root, "missing-cli.js"),
            CodexPath = Path.Combine(root, "missing-codex.exe"),
            TailscalePath = Path.Combine(root, "missing-tailscale.exe")
        };

        Assert(
            AppSettingsValidator.Validate(
                incompleteDefaults,
                requireExistingPaths: false,
                requireTrustedTailscalePath: false).Count == 0,
            "Incomplete defaults were structurally invalid.");
        Assert(
            AppSettingsValidator.Validate(
                incompleteDefaults,
                requireTrustedTailscalePath: false).Count == 4,
            "Missing runtime dependencies were not reported.");
        Assert(
            store.TryReplaceNewlyCreatedDefaults(incompleteDefaults),
            "New settings rejected structurally valid migration defaults.");
        Assert(
            store.Current.DisplayName == "LEGACY-INCOMPLETE",
            "Configurable migration defaults were not persisted.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void LegacyDefaultsReplaceOnlyNewSettings()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Settings-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        Directory.CreateDirectory(root);
        var requiredFiles = new[] { "node.exe", "cli.js", "codex.exe", "tailscale.exe" }
            .Select(fileName => Path.Combine(root, fileName))
            .ToArray();
        foreach (var path in requiredFiles)
        {
            File.WriteAllText(path, string.Empty);
        }

        var store = new EverVigil.Infrastructure.SettingsStore(paths);
        var legacyDefaults = store.Current with
        {
            DisplayName = "LEGACY",
            ProjectDirectory = root,
            NodePath = requiredFiles[0],
            EvenTerminalCliPath = requiredFiles[1],
            CodexPath = requiredFiles[2],
            TailscalePath = requiredFiles[3]
        };
        Assert(
            store.TryReplaceNewlyCreatedDefaults(legacyDefaults),
            "New settings rejected validated legacy defaults.");
        Assert(store.Current.DisplayName == "LEGACY", "Legacy defaults were not persisted.");

        var reopened = new EverVigil.Infrastructure.SettingsStore(paths);
        Assert(
            !reopened.TryReplaceNewlyCreatedDefaults(legacyDefaults with { DisplayName = "OVERWRITE" }),
            "Existing settings were overwritten by migration defaults.");
        Assert(reopened.Current.DisplayName == "LEGACY", "Existing settings changed during migration retry.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void InvalidPortsAreRejected()
{
    var settings = AppSettings.CreateDefault() with { BackendPort = 80, PublicPort = 70_000 };
    var errors = AppSettingsValidator.Validate(
        settings,
        requireExistingPaths: false,
        CultureInfo.GetCultureInfo("en-US"));
    Assert(errors.Count(error => error.Contains("PORT", StringComparison.Ordinal)) >= 2, "Expected two port validation errors.");
}

static void DuplicatePortsAreRejected()
{
    var baseSettings = AppSettings.CreateDefault();
    var collisions = new[]
    {
        baseSettings with { PublicPort = baseSettings.BackendPort },
        baseSettings with { PublicPort = baseSettings.CodexAppServerPort },
        baseSettings with { BackendPort = baseSettings.CodexAppServerPort }
    };
    Assert(
        collisions.All(settings => AppSettingsValidator.Validate(
                settings,
                requireExistingPaths: false,
                CultureInfo.GetCultureInfo("en-US"))
            .Any(error => error.Contains("different", StringComparison.Ordinal))),
        "A duplicate service port was accepted.");
}

static void CustomTailscalePathIsRejected()
{
    var settings = AppSettings.CreateDefault() with
    {
        TailscalePath = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "tailscale.exe"))
    };
    var errors = AppSettingsValidator.Validate(settings, requireExistingPaths: false);
    Assert(
        errors.Any(error => error.Contains(
            AppSettings.FixedTailscalePath,
            StringComparison.OrdinalIgnoreCase)),
        "A custom Tailscale executable escaped the protected fixed-path policy.");
}

static void PersistedCustomTailscalePathIsNormalized()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.FixedTailscale-{Guid.NewGuid():N}");
    var paths = new DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"))
    {
        IsProductionDataRoot = true
    };
    try
    {
        Directory.CreateDirectory(root);
        var untrustedPath = Path.GetFullPath(Path.Combine(root, "untrusted-tailscale.exe"));
        var serialized = System.Text.Json.JsonSerializer.Serialize(
            AppSettings.CreateDefault() with { TailscalePath = untrustedPath },
            new System.Text.Json.JsonSerializerOptions
            {
                PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase
            });
        File.WriteAllText(paths.SettingsPath, serialized);

        var store = new SettingsStore(paths);
        Assert(
            string.Equals(
                store.Current.TailscalePath,
                AppSettings.FixedTailscalePath,
                StringComparison.OrdinalIgnoreCase),
            "A persisted custom Tailscale executable remained active.");
        Assert(
            store.RequiresSystemConfiguration,
            "Normalizing an untrusted Tailscale executable did not block startup for reconfiguration.");
        Assert(
            !File.ReadAllText(paths.SettingsPath).Contains(untrustedPath, StringComparison.OrdinalIgnoreCase),
            "The untrusted Tailscale executable remained in persisted settings.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void SessionHealthUriIsLoopbackOnly()
{
    var settings = AppSettings.CreateDefault() with { BackendPort = 4567 };
    var uri = EverVigil.Services.HealthProbe.BuildLoopbackSessionUri(settings);
    Assert(uri.Scheme == Uri.UriSchemeHttp, "Session health did not use HTTP loopback.");
    Assert(uri.Host == "127.0.0.1", $"Session health escaped loopback: {uri}");
    Assert(uri.Port == 4567, $"Session health used the wrong backend port: {uri}");
    Assert(
        uri.PathAndQuery == "/api/sessions?provider=codex&limit=1",
        $"Session health used the wrong endpoint: {uri}");
}

static void ProtectedTailscaleIdentityRequiresMatchedEvidence()
{
    const string ownerSid = "S-1-5-21-1000";
    var fixtureDnsName = "evervigil-device.tail1234." + "ts.net";
    var fixtureIpv4 = "100.100." + "10.20";
    var now = DateTimeOffset.Parse("2026-08-18T00:00:00Z", CultureInfo.InvariantCulture);
    var settings = AppSettings.CreateDefault() with
    {
        PublicPort = 4567,
        BackendPort = 4568,
        TailscalePath = @"C:\Program Files\Tailscale\tailscale.exe"
    };

    string BuildLedger(
        string? dnsName = null,
        string[]? tailscaleIps = null,
        string ledgerOwnerSid = ownerSid,
        int publicPort = 4567,
        DateTimeOffset? committedAtUtc = null) =>
        System.Text.Json.JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            ownerSid = ledgerOwnerSid,
            configuration = new
            {
                publicPort,
                backendPort = 4568,
                tailscalePath = @"C:\Program Files\Tailscale\tailscale.exe"
            },
            tailscaleSelf = new
            {
                dnsName = dnsName ?? fixtureDnsName,
                tailscaleIps = tailscaleIps ??
                    [fixtureIpv4, "fd7a:115c:a1e0::1234"]
            },
            committedAtUtc = committedAtUtc ?? now
        });

    var endpoint = ProtectedTailscaleIdentityStore.ParseAndValidate(
        BuildLedger(),
        ownerSid,
        settings,
        now);
    Assert(
        endpoint.DnsName == fixtureDnsName &&
        endpoint.PublicPort == 4567,
        "Protected Tailscale Self evidence was not accepted.");
    AssertThrows<InvalidDataException>(() =>
        ProtectedTailscaleIdentityStore.ParseAndValidate(
            BuildLedger(dnsName: "example.com"),
            ownerSid,
            settings,
            now));
    AssertThrows<InvalidDataException>(() =>
        ProtectedTailscaleIdentityStore.ParseAndValidate(
            BuildLedger(tailscaleIps: ["203.0.113.7"]),
            ownerSid,
            settings,
            now));
    AssertThrows<InvalidDataException>(() =>
        ProtectedTailscaleIdentityStore.ParseAndValidate(
            BuildLedger(ledgerOwnerSid: "S-1-5-21-2000"),
            ownerSid,
            settings,
            now));
    AssertThrows<InvalidDataException>(() =>
        ProtectedTailscaleIdentityStore.ParseAndValidate(
            BuildLedger(publicPort: 4569),
            ownerSid,
            settings,
            now));
    AssertThrows<InvalidDataException>(() =>
        ProtectedTailscaleIdentityStore.ParseAndValidate(
            BuildLedger(committedAtUtc: now.AddMinutes(6)),
            ownerSid,
            settings,
            now));
}

static void LiveTailscaleIdentityRejectsStaleDnsAndLogout()
{
    var fixtureDnsName = "evervigil-device.tail1234." + "ts.net";
    var fixtureIpv4 = "100.100." + "10.20";
    var staleIpv4 = "100.100." + "10.21";
    var otherIpv4 = "100.100." + "10.22";
    var endpoint = new TrustedTailnetEndpoint(
        fixtureDnsName,
        3456,
        [fixtureIpv4, "fd7a:115c:a1e0::1234"],
        DateTimeOffset.UtcNow);
    Assert(
        ProtectedTailscaleIdentityStore.IsLiveIdentityMatch(
            endpoint,
            [System.Net.IPAddress.Parse(fixtureIpv4)],
            [System.Net.IPAddress.Parse(fixtureIpv4)]),
        "Matching protected, local, and DNS Tailscale identity was rejected.");
    Assert(
        !ProtectedTailscaleIdentityStore.IsLiveIdentityMatch(
            endpoint,
            [System.Net.IPAddress.Parse(fixtureIpv4)],
            [System.Net.IPAddress.Parse(staleIpv4)]),
        "A stale DNS name reassigned to another Tailscale IP was accepted.");
    Assert(
        !ProtectedTailscaleIdentityStore.IsLiveIdentityMatch(
            endpoint,
            [System.Net.IPAddress.Parse(fixtureIpv4)],
            [
                System.Net.IPAddress.Parse(fixtureIpv4),
                System.Net.IPAddress.Parse("203.0.113.7")
            ]),
        "A DNS answer containing a public address was accepted.");
    Assert(
        !ProtectedTailscaleIdentityStore.IsLiveIdentityMatch(
            endpoint,
            [
                System.Net.IPAddress.Parse(fixtureIpv4),
                System.Net.IPAddress.Parse(otherIpv4)
            ],
            [
                System.Net.IPAddress.Parse("fd7a:115c:a1e0::1234"),
                System.Net.IPAddress.Parse(otherIpv4)
            ]),
        "Pairwise-only address overlap without a fully trusted DNS answer was accepted.");
    Assert(
        !ProtectedTailscaleIdentityStore.IsLiveIdentityMatch(
            endpoint,
            [System.Net.IPAddress.Loopback],
            [System.Net.IPAddress.Parse(fixtureIpv4)]),
        "A logged-out device without its protected Tailscale IP was accepted.");
}

static void CurrentServeRouteMustMatchProtectedTarget()
{
    const string exact = """
        {
          "TCP":{"3456":{"HTTP":true}},
          "Web":{"device.example.invalid:3456":{"Handlers":{
            "/":{"Proxy":"http://127.0.0.1:3457"},
            "/unrelated":{"Proxy":"http://127.0.0.1:4567"}
          }}}
        }
        """;
    Assert(
        ProtectedTailscaleIdentityStore.IsCurrentServeRoute(exact, 3456, 3457),
        "The exact tailnet-only Serve root was rejected.");

    const string missing = """{"TCP":null,"Web":null}""";
    Assert(
        !ProtectedTailscaleIdentityStore.IsCurrentServeRoute(missing, 3456, 3457),
        "A missing Serve route was accepted.");

    const string wrongBackend = """
        {"TCP":{"3456":{"HTTP":true}},"Web":{"device.invalid:3456":{"Handlers":{
          "/":{"Proxy":"http://127.0.0.1:9999"}
        }}}}
        """;
    Assert(
        !ProtectedTailscaleIdentityStore.IsCurrentServeRoute(wrongBackend, 3456, 3457),
        "A Serve route owned by another backend was accepted.");

    const string funnel = """
        {
          "TCP":{"3456":{"HTTP":true}},
          "Web":{"device.invalid:3456":{"Handlers":{
            "/":{"Proxy":"http://127.0.0.1:3457"}
          }}},
          "AllowFunnel":{"device.invalid:3456":true}
        }
        """;
    Assert(
        !ProtectedTailscaleIdentityStore.IsCurrentServeRoute(funnel, 3456, 3457),
        "A public Funnel route was accepted.");

    const string malformedTcp = """
        {"TCP":{"3456":"HTTP"},"Web":{"device.invalid:3456":{"Handlers":{
          "/":{"Proxy":"http://127.0.0.1:3457"}
        }}}}
        """;
    Assert(
        !ProtectedTailscaleIdentityStore.IsCurrentServeRoute(malformedTcp, 3456, 3457),
        "A malformed TCP Serve entry was accepted.");
}

static void ServeStatusChildInheritsNoCredentialEnvironment()
{
    const string canaryName = "EVERVIGIL_TEST_SECRET_CANARY";
    var original = Environment.GetEnvironmentVariable(canaryName);
    Environment.SetEnvironmentVariable(canaryName, "must-not-be-inherited");
    try
    {
        var startInfo = ProtectedTailscaleIdentityStore.CreateServeStatusStartInfo(
            @"C:\Program Files\Tailscale\tailscale.exe");
        Assert(
            startInfo.Environment.Count == 4 &&
            startInfo.Environment.ContainsKey("SystemRoot") &&
            startInfo.Environment.ContainsKey("WINDIR") &&
            startInfo.Environment.ContainsKey("TEMP") &&
            startInfo.Environment.ContainsKey("TMP"),
            "The Serve status child environment is not the fixed minimal set.");
        Assert(
            !startInfo.Environment.ContainsKey(canaryName) &&
            !startInfo.Environment.ContainsKey("BRIDGE_TOKEN") &&
            !startInfo.Environment.ContainsKey("OPENAI_API_KEY"),
            "A credential-bearing parent environment entry reached the Serve status child.");
    }
    finally
    {
        Environment.SetEnvironmentVariable(canaryName, original);
    }
}

static void BridgeChildrenInheritOnlyExplicitRuntimeEnvironment()
{
    const string token = "0123456789abcdef" + "0123456789abcdef";
    var settings = new AppSettings
    {
        DisplayName = "EverVigil test",
        BackendPort = 3457,
        CodexAppServerPort = 8765,
        ProjectDirectory = @"C:\Fixtures\EverVigil\Project",
        NodePath = @"C:\Fixtures\Node\node.exe",
        EvenTerminalCliPath = @"C:\Fixtures\EvenTerminal\cli.js",
        CodexPath = @"C:\Fixtures\Codex\codex.exe",
        TailscalePath = @"C:\Program Files\Tailscale\tailscale.exe"
    };
    var launcher = new System.Diagnostics.ProcessStartInfo();
    launcher.Environment["OPENAI_API_KEY"] = "must-not-be-inherited";
    launcher.Environment["GH_TOKEN"] = "must-not-be-inherited";
    launcher.Environment["EVERVIGIL_TEST_SECRET_CANARY"] = "must-not-be-inherited";
    launcher.Environment["PATH"] = @"C:\Fixtures\UnrelatedParentPath";
    EverVigil.Services.BridgeProcessEnvironment.ConfigureLauncher(
        launcher,
        settings,
        token);

    Assert(
        launcher.Environment.Keys.All(
            EverVigil.Services.BridgeProcessEnvironment.IsAllowedVariableName),
        "The bridge launcher received an environment entry outside the explicit allowlist.");
    Assert(
        !launcher.Environment.ContainsKey("OPENAI_API_KEY") &&
        !launcher.Environment.ContainsKey("GH_TOKEN") &&
        !launcher.Environment.ContainsKey("EVERVIGIL_TEST_SECRET_CANARY") &&
        string.Equals(launcher.Environment["BRIDGE_TOKEN"], token, StringComparison.Ordinal),
        "The bridge launcher inherited a parent credential or lost its application token.");
    Assert(
        !(launcher.Environment["PATH"] ?? string.Empty).Contains(
            @"C:\Fixtures\UnrelatedParentPath",
            StringComparison.OrdinalIgnoreCase),
        "The bridge launcher retained an unrelated user PATH entry.");

    var inherited = launcher.Environment.ToDictionary(
        entry => entry.Key,
        entry => entry.Value,
        StringComparer.OrdinalIgnoreCase);
    inherited["OPENAI_API_KEY"] = "must-not-be-inherited";
    inherited["CODEX_HOME"] = @"C:\Fixtures\SecretCodexHome";
    inherited["EVERVIGIL_TEST_SECRET_CANARY"] = "must-not-be-inherited";
    var child = new System.Diagnostics.ProcessStartInfo();
    EverVigil.Services.BridgeProcessEnvironment.ConfigureBridgeChild(
        child,
        inherited,
        settings.BackendPort.ToString(CultureInfo.InvariantCulture),
        settings.DisplayName,
        settings.ProjectDirectory);

    Assert(
        child.Environment.Keys.All(
            EverVigil.Services.BridgeProcessEnvironment.IsAllowedVariableName),
        "The Node bridge received an environment entry outside the explicit allowlist.");
    Assert(
        !child.Environment.ContainsKey("OPENAI_API_KEY") &&
        !child.Environment.ContainsKey("CODEX_HOME") &&
        !child.Environment.ContainsKey("EVERVIGIL_TEST_SECRET_CANARY") &&
        string.Equals(child.Environment["BRIDGE_TOKEN"], token, StringComparison.Ordinal),
        "The Node bridge inherited a parent credential or lost its application token.");

    var tampered = new Dictionary<string, string?>(inherited, StringComparer.OrdinalIgnoreCase)
    {
        ["BRIDGE_TOKEN"] = "not-a-token"
    };
    AssertThrows<InvalidOperationException>(() =>
        EverVigil.Services.BridgeProcessEnvironment.ConfigureBridgeChild(
            new System.Diagnostics.ProcessStartInfo(),
            tampered,
            settings.BackendPort.ToString(CultureInfo.InvariantCulture),
            settings.DisplayName,
            settings.ProjectDirectory));
}

static void TokenGenerationIsValidAndUnique()
{
    var tokens = Enumerable.Range(0, 100).Select(_ => TokenUtility.Generate()).ToArray();
    Assert(tokens.All(TokenUtility.IsValid), "A generated token was invalid.");
    Assert(tokens.Distinct(StringComparer.Ordinal).Count() == tokens.Length, "Generated tokens were not unique.");
}

static void PlaceholderBrandAssetAndCompactWindowContract()
{
    using var logo = BrandAssets.LoadLogoBitmap();
    Assert(
        logo.Width >= 512 && logo.Height >= 512 && logo.Width == logo.Height,
        $"Unexpected placeholder source size: {logo.Size}");
    var sampleStep = Math.Max(1, logo.Width / 16);
    var visibleSamples = new List<Color>();
    for (var y = 0; y < logo.Height; y += sampleStep)
    {
        for (var x = 0; x < logo.Width; x += sampleStep)
        {
            var color = logo.GetPixel(x, y);
            if (color.A > 0)
            {
                visibleSamples.Add(color);
            }
        }
    }
    Assert(visibleSamples.Count > 0, "The placeholder source is fully transparent.");
    Assert(
        visibleSamples.Select(color => color.ToArgb()).Distinct().Count() >= 3,
        "The placeholder source does not contain distinguishable geometric regions.");

    using var trayIcon = TrayIconFactory.Create(SupervisorState.Online);
    Assert(trayIcon.Width == 32 && trayIcon.Height == 32, "Tray icon is not 32x32.");
    Assert(
        DashboardForm.DefaultClientSize.Width <= 720 &&
        DashboardForm.DefaultClientSize.Height <= 600,
        $"Dashboard is not compact: {DashboardForm.DefaultClientSize}");
    Assert(
        DashboardForm.MinimumWindowSize.Width <= DashboardForm.DefaultClientSize.Width &&
        DashboardForm.MinimumWindowSize.Height <= DashboardForm.DefaultClientSize.Height,
        "Dashboard minimum size exceeds its default size.");
}

static void ApplicationMetadataContract()
{
    Assert(ApplicationMetadata.ProductName == "EverVigil", "Unexpected product name.");
    Assert(
        ApplicationMetadata.Copyright == "Copyright © 2026 Daichi Matsumoto",
        "The copyright holder is missing or incorrect.");
    Assert(
        ApplicationMetadata.LicenseName == "GNU GPL v3.0 only (Copyleft)",
        "The copyleft license is missing.");
    Assert(
        ApplicationMetadata.LicenseNotice.Contains("GPL-3.0-only", StringComparison.Ordinal),
        "The interactive GPL notice is missing.");
    Assert(
        ApplicationMetadata.LegalNotice ==
        "This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.",
        "The required independent-project notice changed.");
    Assert(
        ApplicationMetadata.Version == "2.1.1",
        $"Unexpected application version: {ApplicationMetadata.Version}");
    Assert(
        Uri.TryCreate(ApplicationMetadata.GitHubProfileUrl, UriKind.Absolute, out var profileUri) &&
        profileUri.Scheme == Uri.UriSchemeHttps &&
        profileUri.Host == "github.com" &&
        profileUri.AbsolutePath == "/DaichiMatsumoto",
        "The GitHub profile URL is invalid.");
}

static void StatusTextColorsMeetWcagContrast()
{
    var statusColors = new (string Name, Color Value)[]
    {
        (nameof(AppTheme.Online), AppTheme.Online),
        (nameof(AppTheme.Starting), AppTheme.Starting),
        (nameof(AppTheme.Degraded), AppTheme.Degraded),
        (nameof(AppTheme.Faulted), AppTheme.Faulted),
        (nameof(AppTheme.Stopped), AppTheme.Stopped)
    };
    var surfaces = new (string Name, Color Value)[]
    {
        (nameof(AppTheme.Surface), AppTheme.Surface),
        (nameof(AppTheme.Canvas), AppTheme.Canvas)
    };

    foreach (var statusColor in statusColors)
    {
        foreach (var surface in surfaces)
        {
            var ratio = ContrastRatio(statusColor.Value, surface.Value);
            Assert(
                ratio >= 4.5,
                $"{statusColor.Name} contrast on {surface.Name} is {ratio:F2}:1; expected at least 4.5:1.");
        }
    }
}

static double ContrastRatio(Color left, Color right)
{
    var lighter = Math.Max(RelativeLuminance(left), RelativeLuminance(right));
    var darker = Math.Min(RelativeLuminance(left), RelativeLuminance(right));
    return (lighter + 0.05) / (darker + 0.05);
}

static double RelativeLuminance(Color color)
{
    static double Linearize(byte channel)
    {
        var normalized = channel / 255.0;
        return normalized <= 0.04045
            ? normalized / 12.92
            : Math.Pow((normalized + 0.055) / 1.055, 2.4);
    }

    return (0.2126 * Linearize(color.R)) +
        (0.7152 * Linearize(color.G)) +
        (0.0722 * Linearize(color.B));
}

static void ConnectionUrlContainsProvider()
{
    var token = new string('a', 32);
    var url = ConnectionUrlBuilder.BuildConnectionUrl("host.example", 4567, token);
    Assert(url == $"http://host.example:4567/?token={token}&defaultProvider=codex", $"Unexpected URL: {url}");
}

static void ConnectionUrlBracketsIpv6Host()
{
    var token = new string('a', 32);
    var url = ConnectionUrlBuilder.BuildConnectionUrl("::1", 4567, token);
    Assert(url == $"http://[::1]:4567/?token={token}&defaultProvider=codex", $"Unexpected IPv6 URL: {url}");
    var bracketedUrl = ConnectionUrlBuilder.BuildConnectionUrl("[::1]", 4567, token);
    Assert(bracketedUrl == url, $"Bracketed IPv6 host was not normalized: {bracketedUrl}");
}

static void InvalidTokenIsRejected()
{
    var threw = false;
    try
    {
        ConnectionUrlBuilder.BuildConnectionUrl("host.example", 3456, "short");
    }
    catch (ArgumentException)
    {
        threw = true;
    }

    Assert(threw, "Invalid token was accepted.");
}

static void RedactorRemovesQueryTokens()
{
    var token = new string('a', 32);
    var result = SecretRedactor.Redact($"GET /?token={token}&defaultProvider=codex");
    Assert(!result.Contains(token, StringComparison.Ordinal), "Query token remained in output.");
    Assert(result.Contains("token=<redacted>", StringComparison.Ordinal), "Redaction marker was missing.");
}

static void RedactorRemovesBearerTokens()
{
    var result = SecretRedactor.Redact("Authorization: Bearer top-secret-value");
    Assert(!result.Contains("top-secret-value", StringComparison.Ordinal), "Bearer token remained in output.");
}

static void RedactorRemovesKnownSecrets()
{
    const string secret = "not-a-standard-token";
    var result = SecretRedactor.Redact($"value={secret}", secret);
    Assert(!result.Contains(secret, StringComparison.Ordinal), "Known secret remained in output.");
}

static void SessionHealthPayloadRequiresSessionsArray()
{
    using var valid = System.Text.Json.JsonDocument.Parse("""{"sessions":[]}""");
    using var wrongType = System.Text.Json.JsonDocument.Parse("""{"sessions":{}}""");
    using var error = System.Text.Json.JsonDocument.Parse("""{"sessions":[],"error":"provider failed"}""");

    Assert(
        EverVigil.Services.HealthProbe.IsSessionPayloadReady(valid.RootElement),
        "A valid sessions response was rejected.");
    Assert(
        !EverVigil.Services.HealthProbe.IsSessionPayloadReady(wrongType.RootElement),
        "A non-array sessions payload was accepted.");
    Assert(
        !EverVigil.Services.HealthProbe.IsSessionPayloadReady(error.RootElement),
        "A provider error payload was accepted.");
}

static void ClipboardClearRetriesAfterTransientLock()
{
    var access = new TestClipboardAccess();
    using var clipboard = new SensitiveClipboard(15, access);
    clipboard.Set("sensitive-value", 15);
    access.FailuresRemaining = 1;

    Assert(!clipboard.TryClearIfUnchanged(), "A locked clipboard was reported as cleared.");
    Assert(access.Text == "sensitive-value", "A failed clear attempt forgot the sensitive value.");
    Assert(clipboard.TryClearIfUnchanged(), "Clipboard clear did not recover after the lock was released.");
    Assert(access.Text is null, "Sensitive clipboard text remained after a successful retry.");
}

static void ClipboardDisposeRetriesUntilClear()
{
    var access = new TestClipboardAccess();
    var delays = 0;
    var clipboard = new SensitiveClipboard(
        15,
        access,
        TimeSpan.FromSeconds(1),
        _ => delays++);
    clipboard.Set("sensitive-value", 15);
    access.FailuresRemaining = 6;

    clipboard.Dispose();

    Assert(access.Text is null, "Sensitive clipboard text remained after disposal retries.");
    Assert(delays == 6, $"Unexpected disposal retry count: {delays}.");
}

static void BackoffGrowsAndCaps()
{
    var policy = new ExponentialBackoffPolicy(TimeSpan.FromSeconds(10), TimeSpan.FromMinutes(5));
    var expected = new[] { 0, 10, 20, 40, 80, 160, 300, 300 };
    var actual = Enumerable.Range(0, expected.Length)
        .Select(attempt => (int)policy.GetDelay(attempt).TotalSeconds)
        .ToArray();
    Assert(actual.SequenceEqual(expected), $"Unexpected sequence: {string.Join(",", actual)}");
}

static void BackoffRejectsInvalidConstruction()
{
    AssertThrows<ArgumentOutOfRangeException>(() =>
        new ExponentialBackoffPolicy(TimeSpan.Zero, TimeSpan.FromSeconds(1)));
    AssertThrows<ArgumentOutOfRangeException>(() =>
        new ExponentialBackoffPolicy(TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(1)));
}

static void RestartSignalInterruptsDelay()
{
    using var signal = new EverVigil.Infrastructure.AsyncRestartSignal();
    signal.Signal();
    var startedAt = DateTime.UtcNow;
    var interrupted = signal.WaitAsync(TimeSpan.FromSeconds(5), CancellationToken.None)
        .GetAwaiter()
        .GetResult();
    Assert(interrupted, "Pending restart signal did not interrupt the delay.");
    Assert(DateTime.UtcNow - startedAt < TimeSpan.FromSeconds(1), "Restart signal was not consumed promptly.");
}

static void RestartSignalSurvivesCompletedDelay()
{
    using var signal = new EverVigil.Infrastructure.AsyncRestartSignal();
    var interrupted = signal.WaitAsync(TimeSpan.FromMilliseconds(30), CancellationToken.None)
        .GetAwaiter()
        .GetResult();
    Assert(!interrupted, "An unsignaled delay was interrupted.");
    signal.Signal();
    Assert(
        signal.WaitAsync(TimeSpan.FromSeconds(2), CancellationToken.None).GetAwaiter().GetResult(),
        "A completed delay consumed a later restart signal.");
}

static void SingleInstanceAcquiresExistingUnownedMutex()
{
    var scope = $"Local\\EverVigil.Tests-{Guid.NewGuid():N}";
    var primary = new EverVigil.Infrastructure.SingleInstanceCoordinator(scope);
    var primaryDisposed = false;
    using var secondaryReady = new ManualResetEventSlim();
    using var releaseSecondary = new ManualResetEventSlim();
    Exception? secondaryError = null;
    var secondaryWasPrimary = true;
    var secondaryThread = new Thread(() =>
    {
        try
        {
            using var secondary = new EverVigil.Infrastructure.SingleInstanceCoordinator(scope);
            secondaryWasPrimary = secondary.IsPrimary;
            secondaryReady.Set();
            releaseSecondary.Wait(TimeSpan.FromSeconds(5));
        }
        catch (Exception exception)
        {
            secondaryError = exception;
            secondaryReady.Set();
        }
    });
    secondaryThread.IsBackground = true;

    try
    {
        Assert(primary.IsPrimary, "The first coordinator did not acquire the mutex.");
        secondaryThread.Start();
        Assert(secondaryReady.Wait(TimeSpan.FromSeconds(5)), "The secondary coordinator did not start.");
        Assert(secondaryError is null, $"The secondary coordinator failed: {secondaryError}");
        Assert(!secondaryWasPrimary, "A concurrent coordinator acquired the owned mutex.");

        primary.Dispose();
        primaryDisposed = true;
        using var replacement = new EverVigil.Infrastructure.SingleInstanceCoordinator(scope);
        Assert(replacement.IsPrimary, "An existing unowned mutex was not acquired.");
    }
    finally
    {
        releaseSecondary.Set();
        if (secondaryThread.IsAlive)
        {
            secondaryThread.Join(TimeSpan.FromSeconds(5));
        }
        if (!primaryDisposed)
        {
            primary.Dispose();
        }
    }
}

static void DefaultSingleInstanceScopeSpansLoginSessions()
{
    var scope = EverVigil.Infrastructure.SingleInstanceCoordinator.CreateDefaultScope();
    var sid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ??
        throw new InvalidOperationException("Current user SID is unavailable.");

    Assert(scope.StartsWith("Global\\", StringComparison.Ordinal), "Default scope is session-local.");
    Assert(scope.Contains(sid, StringComparison.Ordinal), "Default scope is not isolated by user SID.");
}

static void SystemTransactionReopensWithLeastPrivilege()
{
    var name = $"Local\\EverVigil.SystemTransaction.Tests-{Guid.NewGuid():N}";
    var security = new System.Security.AccessControl.MutexSecurity();
    security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
    security.AddAccessRule(new System.Security.AccessControl.MutexAccessRule(
        new System.Security.Principal.SecurityIdentifier(
            System.Security.Principal.WellKnownSidType.AuthenticatedUserSid,
            null),
        System.Security.AccessControl.MutexRights.Synchronize |
        System.Security.AccessControl.MutexRights.Modify,
        System.Security.AccessControl.AccessControlType.Allow));
    foreach (var identity in new[]
             {
                 new System.Security.Principal.SecurityIdentifier(
                     System.Security.Principal.WellKnownSidType.LocalSystemSid,
                     null),
                 new System.Security.Principal.SecurityIdentifier(
                     System.Security.Principal.WellKnownSidType.BuiltinAdministratorsSid,
                     null)
             })
    {
        security.AddAccessRule(new System.Security.AccessControl.MutexAccessRule(
            identity,
            System.Security.AccessControl.MutexRights.FullControl,
            System.Security.AccessControl.AccessControlType.Allow));
    }

    using var existing = System.Threading.MutexAcl.Create(
        initiallyOwned: false,
        name,
        out _,
        security);
    using var reopened = EverVigil.Services.SystemConfigurationService
        .CreateSystemTransactionMutex(name);
    Assert(reopened.WaitOne(TimeSpan.Zero), "The least-privilege mutex handle could not wait.");
    reopened.ReleaseMutex();
}

static void SingleInstanceObjectsGrantCurrentUserAccess()
{
    var scope = $"Local\\EverVigil.Tests-{Guid.NewGuid():N}";
    var sid = System.Security.Principal.WindowsIdentity.GetCurrent().User ??
        throw new InvalidOperationException("Current user SID is unavailable.");
    using var coordinator = new EverVigil.Infrastructure.SingleInstanceCoordinator(scope);
    using var mutex = System.Threading.MutexAcl.OpenExisting(
        $"{scope}-Mutex",
        System.Security.AccessControl.MutexRights.ReadPermissions);
    using var showEvent = System.Threading.EventWaitHandleAcl.OpenExisting(
        $"{scope}-Show",
        System.Security.AccessControl.EventWaitHandleRights.ReadPermissions);
    using var shutdownEvent = System.Threading.EventWaitHandleAcl.OpenExisting(
        $"{scope}-Shutdown",
        System.Security.AccessControl.EventWaitHandleRights.ReadPermissions);

    var mutexRules = mutex.GetAccessControl().GetAccessRules(
        includeExplicit: true,
        includeInherited: false,
        typeof(System.Security.Principal.SecurityIdentifier));
    Assert(
        mutexRules.OfType<System.Security.AccessControl.MutexAccessRule>().Any(rule =>
            sid.Equals(rule.IdentityReference) &&
            rule.AccessControlType == System.Security.AccessControl.AccessControlType.Allow &&
            (rule.MutexRights & System.Security.AccessControl.MutexRights.FullControl) ==
            System.Security.AccessControl.MutexRights.FullControl),
        "The current user does not have full control of the single-instance mutex.");

    foreach (var (name, handle) in new[]
             {
                 ("show", showEvent),
                 ("shutdown", shutdownEvent)
             })
    {
        var eventRules = handle.GetAccessControl().GetAccessRules(
            includeExplicit: true,
            includeInherited: false,
            typeof(System.Security.Principal.SecurityIdentifier));
        Assert(
            eventRules.OfType<System.Security.AccessControl.EventWaitHandleAccessRule>().Any(rule =>
                sid.Equals(rule.IdentityReference) &&
                rule.AccessControlType == System.Security.AccessControl.AccessControlType.Allow &&
                (rule.EventWaitHandleRights & System.Security.AccessControl.EventWaitHandleRights.FullControl) ==
                System.Security.AccessControl.EventWaitHandleRights.FullControl),
            $"The current user does not have full control of the {name} event.");
    }
}

static void HeadlessCommandsSuppressStartupErrorDialogs()
{
    foreach (var argument in new[]
             {
                 "--background",
                 "--bridge-launcher",
                 "--health-check",
                 "--import-token-file",
                 "--initialize-legacy-settings",
                 "--commit-installer-system-config",
                 "--mark-system-configured",
                 "--register-startup",
                 "--shutdown",
                 "--unregister-startup",
                 "--validate-settings"
             })
    {
        Assert(
            !EverVigil.Program.ShouldShowStartupError([argument]),
            $"{argument} would show a blocking startup error dialog.");
    }

    Assert(
        EverVigil.Program.ShouldShowStartupError([]),
        "An interactive launch would suppress its startup error dialog.");
}

static void HeadlessFailuresAreSafeForInstallerDiagnostics()
{
    var formatted = EverVigil.Program.FormatHeadlessFailure(
        new InvalidDataException("first line\r\nsecond line"));
    Assert(
        formatted == "[evervigil-headless-error] InvalidDataException: first line  second line",
        "The headless failure diagnostic changed its stable format.");
    Assert(
        !formatted.Contains('\r') && !formatted.Contains('\n'),
        "The headless failure diagnostic retained a line break.");

    var longMessage = new string('x', 600);
    var bounded = EverVigil.Program.FormatHeadlessFailure(new IOException(longMessage));
    Assert(
        bounded.Length == "[evervigil-headless-error] IOException: ".Length + 512,
        "The headless failure diagnostic was not bounded.");
}

static void AtomicFilesReceiveProtectedAclAtCreation()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-Acl-{Guid.NewGuid():N}");
    var path = Path.Combine(root, "atomic.tmp");
    try
    {
        AccessControlService.RestrictDirectory(root);
        using var stream = AccessControlService.CreateRestrictedFile(
            path,
            FileMode.CreateNew,
            FileShare.None,
            bufferSize: 4096,
            FileOptions.WriteThrough);
        AssertProtectedFileAcl(path);

        stream.WriteByte(1);
        stream.Flush(flushToDisk: true);
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void AtomicReplacementPreservesProtectedAcl()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-AclMove-{Guid.NewGuid():N}");
    var temporaryPath = Path.Combine(root, "state.transaction.tmp");
    var destinationPath = Path.Combine(root, "state.json");
    try
    {
        AccessControlService.RestrictDirectory(root);
        File.WriteAllText(destinationPath, "previous");
        using (var stream = AccessControlService.CreateRestrictedFile(
                   temporaryPath,
                   FileMode.CreateNew,
                   FileShare.None,
                   bufferSize: 4096,
                   FileOptions.WriteThrough))
        using (var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(false), leaveOpen: true))
        {
            writer.Write("replacement");
            writer.Flush();
            stream.Flush(flushToDisk: true);
        }

        File.Move(temporaryPath, destinationPath, overwrite: true);

        Assert(!File.Exists(temporaryPath), "The moved atomic temporary still exists.");
        Assert(File.ReadAllText(destinationPath) == "replacement", "The atomic replacement content is stale.");
        AssertProtectedFileAcl(destinationPath);
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void AssertProtectedFileAcl(string path)
{
    var security = System.IO.FileSystemAclExtensions.GetAccessControl(
        new FileInfo(path),
        System.Security.AccessControl.AccessControlSections.Access |
        System.Security.AccessControl.AccessControlSections.Owner);
    var currentSid = System.Security.Principal.WindowsIdentity.GetCurrent().User ??
        throw new InvalidOperationException("The current Windows user SID is unavailable.");
    var expectedSids = new HashSet<string>(StringComparer.Ordinal)
    {
        currentSid.Value,
        new System.Security.Principal.SecurityIdentifier(
            System.Security.Principal.WellKnownSidType.LocalSystemSid,
            null).Value,
        new System.Security.Principal.SecurityIdentifier(
            System.Security.Principal.WellKnownSidType.BuiltinAdministratorsSid,
            null).Value
    };
    var rules = security.GetAccessRules(
            includeExplicit: true,
            includeInherited: true,
            typeof(System.Security.Principal.SecurityIdentifier))
        .OfType<System.Security.AccessControl.FileSystemAccessRule>()
        .ToArray();

    Assert(security.AreAccessRulesProtected, "The atomic file inherited an access list.");
    var actualOwner = security.GetOwner(
        typeof(System.Security.Principal.SecurityIdentifier)) as
        System.Security.Principal.SecurityIdentifier;
    Assert(
        actualOwner is not null && expectedSids.Contains(actualOwner.Value),
        "The atomic file owner is not a trusted Windows principal.");
    Assert(
        rules.Length == expectedSids.Count &&
        rules.All(rule =>
            !rule.IsInherited &&
            rule.AccessControlType == System.Security.AccessControl.AccessControlType.Allow &&
            rule.IdentityReference is System.Security.Principal.SecurityIdentifier sid &&
            expectedSids.Contains(sid.Value) &&
            (rule.FileSystemRights & System.Security.AccessControl.FileSystemRights.FullControl) ==
            System.Security.AccessControl.FileSystemRights.FullControl),
        "The atomic file ACL was not the exact current-user/SYSTEM/Administrators allow-list.");
}

static AppSettings WithExistingDependencyFixtures(AppSettings settings, string root)
{
    var nodePath = Path.Combine(root, "node.exe");
    var cliPath = Path.Combine(root, "even-terminal-cli.js");
    var codexPath = Path.Combine(root, "codex.exe");
    var tailscalePath = Path.Combine(root, "tailscale.exe");
    foreach (var path in new[] { nodePath, cliPath, codexPath, tailscalePath })
    {
        File.WriteAllBytes(path, [0x4d, 0x5a]);
    }

    return settings with
    {
        NodePath = nodePath,
        EvenTerminalCliPath = cliPath,
        CodexPath = codexPath,
        TailscalePath = tailscalePath
    };
}

static void StartupWaitsForDependencyConfiguration()
{
    var settings = AppSettings.CreateDefault() with
    {
        NodePath = Path.Combine(Path.GetTempPath(), $"missing-node-{Guid.NewGuid():N}.exe")
    };

    Assert(
        !EverVigil.Program.ShouldStartSupervisor(
            settings,
            requiresSystemConfiguration: false,
            startRequested: true),
        "Invalid runtime dependencies entered the supervisor retry loop.");
    Assert(
        EverVigil.Program.ShouldStartSupervisor(
            settings,
            requiresSystemConfiguration: false,
            startRequested: true,
            forceStartRequested: true),
        "An explicit recovery start did not enter the bounded supervisor retry loop.");
    Assert(
        EverVigil.Program.ShouldStartSupervisor(
            settings,
            requiresSystemConfiguration: true,
            startRequested: false),
        "A system-configuration block was not surfaced through supervisor state.");
}

static void InstallerHealthAcceptsPreCommitRuntime()
{
    Assert(
        EverVigil.Program.IsInstallerRuntimeHealthy(local: true, provider: true),
        "A healthy local/provider runtime was rejected before protected commit.");
    Assert(
        !EverVigil.Program.IsInstallerRuntimeHealthy(local: false, provider: true) &&
        !EverVigil.Program.IsInstallerRuntimeHealthy(local: true, provider: false),
        "Installer runtime health accepted a failed local or provider endpoint.");
}

static void ConcurrentTokenStoresConvergeOnOneToken()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        var firstStore = new EverVigil.Infrastructure.TokenStore(paths);
        var secondStore = new EverVigil.Infrastructure.TokenStore(paths);
        using var start = new ManualResetEventSlim();
        var first = Task.Run(() =>
        {
            start.Wait();
            return firstStore.GetOrCreate();
        });
        var second = Task.Run(() =>
        {
            start.Wait();
            return secondStore.GetOrCreate();
        });

        start.Set();
        Task.WhenAll(first, second).WaitAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult();

        Assert(first.Result == second.Result, "Concurrent token stores generated different credentials.");
        Assert(
            new EverVigil.Infrastructure.TokenStore(paths).GetOrCreate() == first.Result,
            "The persisted token differs from the token returned to the primary caller.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void LegacyImportPreservesExistingDpapiToken()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.TokenImport-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    var legacyTokenPath = Path.Combine(root, "token.txt");
    try
    {
        Directory.CreateDirectory(root);
        var tokenStore = new EverVigil.Infrastructure.TokenStore(paths);
        var existingToken = tokenStore.GetOrCreate();
        File.WriteAllText(legacyTokenPath, new string('a', 32));

        Assert(
            !tokenStore.ImportLegacyFileIfMissing(legacyTokenPath),
            "Legacy import replaced an existing DPAPI token.");
        var reopened = new EverVigil.Infrastructure.TokenStore(paths);
        Assert(
            reopened.GetOrCreate() == existingToken,
            "The persisted DPAPI token changed during legacy import.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void DpapiTokenStorageIsEncrypted()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        var store = new EverVigil.Infrastructure.TokenStore(paths);
        var token = store.GetOrCreate();
        var protectedBytes = File.ReadAllBytes(paths.TokenPath);
        Assert(
            !System.Text.Encoding.ASCII.GetString(protectedBytes).Contains(token, StringComparison.Ordinal),
            "Token was stored in plaintext.");
        var reopened = new EverVigil.Infrastructure.TokenStore(paths).GetOrCreate();
        Assert(reopened == token, "DPAPI token did not round-trip.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void FailedTokenPersistenceKeepsCachedToken()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        var store = new EverVigil.Infrastructure.TokenStore(paths);
        var originalToken = store.GetOrCreate();
        File.Delete(paths.TokenPath);
        Directory.CreateDirectory(paths.TokenPath);

        var persistenceFailed = false;
        try
        {
            store.Regenerate();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            persistenceFailed = true;
        }

        Assert(persistenceFailed, "Token persistence unexpectedly succeeded.");
        Assert(store.GetOrCreate() == originalToken, "Failed persistence changed the cached token.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void UnreadableTokenIsQuarantined()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        Directory.CreateDirectory(root);
        File.WriteAllBytes(paths.TokenPath, new byte[] { 1, 2, 3, 4 });
        var store = new EverVigil.Infrastructure.TokenStore(paths);
        var token = store.GetOrCreate();
        Assert(TokenUtility.IsValid(token), "A replacement token was not generated.");
        Assert(store.LastRecoveryMessage is not null, "Token recovery was not reported.");
        Assert(
            store.LastRecoveryMessageResourceKey == "TokenQuarantinedRecovery",
            "Token recovery did not retain its localization resource key.");
        Assert(Directory.EnumerateFiles(root, "token.dat.invalid-*").Count() == 1, "Unreadable token was not quarantined.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void MissingSettingsRequireSystemConfiguration()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        var created = new EverVigil.Infrastructure.SettingsStore(paths);

        Assert(created.RequiresSystemConfiguration, "New settings did not create a fail-closed marker.");
        Assert(
            created.LastRecoveryMessageResourceKey == "SettingsCreatedRecovery",
            "New settings did not retain their localization resource key.");
        created.MarkSystemConfigurationApplied(created.Current);
        Assert(!created.RequiresSystemConfiguration, "Applying system configuration did not clear the marker.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void InvalidSettingsRequireSystemConfiguration()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        Directory.CreateDirectory(root);
        File.WriteAllText(paths.SettingsPath, "{ invalid json");

        var recovered = new EverVigil.Infrastructure.SettingsStore(paths);

        Assert(recovered.RequiresSystemConfiguration, "Invalid settings did not create a fail-closed marker.");
        Assert(recovered.LastRecoveryMessage is not null, "Settings recovery was not reported.");
        Assert(
            recovered.LastRecoveryMessageResourceKey == "SettingsQuarantinedRecovery",
            "Settings recovery did not retain its localization resource key.");
        Assert(
            Directory.EnumerateFiles(root, "settings.json.invalid-*").Count() == 1,
            "Invalid settings were not quarantined.");

        var reopened = new EverVigil.Infrastructure.SettingsStore(paths);
        Assert(reopened.RequiresSystemConfiguration, "The fail-closed marker did not survive restart.");
        reopened.MarkSystemConfigurationApplied(reopened.Current);
        Assert(!reopened.RequiresSystemConfiguration, "Applying system configuration did not clear the marker.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}


static void AppliedSystemConfigurationIsRecordedBeforeUnblocking()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        var store = new EverVigil.Infrastructure.SettingsStore(paths);
        store.MarkSystemConfigurationApplied(store.Current);
        Assert(!store.RequiresSystemConfiguration, "The initial startup block was not cleared.");
        var settings = store.Current with
        {
            PublicPort = 45_678,
            BackendPort = 45_679,
            ProjectDirectory = root,
            NodePath = Path.Combine(root, "node.exe"),
            EvenTerminalCliPath = Path.Combine(root, "cli.js"),
            CodexPath = Path.Combine(root, "codex.exe"),
            TailscalePath = Path.Combine(root, "tailscale.exe")
        };
        foreach (var executablePath in new[]
                 {
                     settings.NodePath,
                     settings.EvenTerminalCliPath,
                     settings.CodexPath,
                     settings.TailscalePath
                 })
        {
            File.WriteAllText(executablePath, string.Empty);
        }
        store.MarkSystemConfigurationRequired();
        store.Save(settings);
        Assert(store.RequiresSystemConfiguration, "Persisting settings cleared the fail-closed marker.");

        store.MarkSystemConfigurationApplied(settings);

        var statePath = Path.Combine(
            root,
            EverVigil.Infrastructure.SettingsStore.AppliedSystemConfigurationFileName);
        Assert(File.Exists(statePath), "Applied system configuration was not persisted.");
        using var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(statePath));
        var state = document.RootElement;
        Assert(state.GetProperty("publicPort").GetInt32() == settings.PublicPort, "Applied public port was not recorded.");
        Assert(state.GetProperty("backendPort").GetInt32() == settings.BackendPort, "Applied backend port was not recorded.");
        Assert(
            state.GetProperty("tailscalePath").GetString() == Path.GetFullPath(settings.TailscalePath),
            "Applied Tailscale path was not recorded.");
        Assert(!store.RequiresSystemConfiguration, "The marker remained after applied state was persisted.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void PendingSystemJournalCommitsAfterDurablePhases()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var journalPath = Path.Combine(
        root,
        EverVigil.Infrastructure.PendingSystemConfigurationStore.FileName);
    var ownerSid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ??
        throw new InvalidOperationException("The test owner SID is unavailable.");
    var tailscalePath = Path.GetFullPath(Path.Combine(root, "tailscale.exe"));
    var target = AppSettings.CreateDefault() with
    {
        PublicPort = 34_56,
        BackendPort = 34_57,
        TailscalePath = tailscalePath
    };
    var previous = target with { PublicPort = 45_56, BackendPort = 45_57 };
    try
    {
        var store = EverVigil.Infrastructure.PendingSystemConfigurationStore.ForTests(
            journalPath,
            ownerSid);
        var pending = store.Begin(
            target,
            previous,
            previousMappingOwned: true,
            existingTargetMappingOwned: false);
        Assert(File.Exists(journalPath), "The pending journal was not created before mutation.");
        store.RecordPreflight(
            pending.TransactionId,
            EverVigil.Services.ServeRootMappingOwnership.Unused,
            EverVigil.Services.ServeRootMappingOwnership.Owned,
            originalMainFirewallPort: previous.BackendPort,
            originalTemporaryFirewallPort: null);
        store.PreparePreviousRouteMutation(pending.TransactionId);
        store.MarkPreviousRouteRemoved(pending.TransactionId);
        store.PrepareTargetRouteMutation(pending.TransactionId);
        store.MarkTargetRouteApplied(pending.TransactionId);
        store.PrepareFirewallMutation(pending.TransactionId);
        store.MarkFirewallApplied(pending.TransactionId);
        store.MarkMutationsCompleted(pending.TransactionId);
        File.WriteAllText(
            Path.Combine(root, EverVigil.Infrastructure.SettingsStore.SystemConfigurationRequiredFileName),
            "required");

        store.CommitApplied(pending.TransactionId, target);

        Assert(!File.Exists(journalPath), "The committed pending journal remained on disk.");
        Assert(
            !File.Exists(Path.Combine(
                root,
                EverVigil.Infrastructure.SettingsStore.SystemConfigurationRequiredFileName)),
            "The system configuration marker survived a committed pending transaction.");
        var appliedPath = Path.Combine(
            root,
            EverVigil.Infrastructure.SettingsStore.AppliedSystemConfigurationFileName);
        using var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(appliedPath));
        Assert(
            document.RootElement.GetProperty("publicPort").GetInt32() == target.PublicPort &&
            document.RootElement.GetProperty("backendPort").GetInt32() == target.BackendPort,
            "The committed applied state does not match the pending target.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void PendingSystemJournalRejectsUnsafeCompletion()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var journalPath = Path.Combine(
        root,
        EverVigil.Infrastructure.PendingSystemConfigurationStore.FileName);
    var ownerSid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ??
        throw new InvalidOperationException("The test owner SID is unavailable.");
    var target = AppSettings.CreateDefault() with
    {
        TailscalePath = Path.GetFullPath(Path.Combine(root, "tailscale.exe"))
    };
    try
    {
        var store = EverVigil.Infrastructure.PendingSystemConfigurationStore.ForTests(
            journalPath,
            ownerSid);
        var pending = store.Begin(
            target,
            previous: null,
            previousMappingOwned: false,
            existingTargetMappingOwned: false);

        AssertThrows<InvalidDataException>(() => store.Load(Guid.NewGuid()));
        AssertThrows<InvalidOperationException>(() =>
            store.CommitApplied(pending.TransactionId, target));
        Assert(File.Exists(journalPath), "An unsafe commit discarded its recovery journal.");

        store.CancelUnmutated(pending.TransactionId);
        Assert(!File.Exists(journalPath), "An unmutated pending transaction was not cancelled.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void InstallerPendingJournalIsNotCommittedByApplication()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    var ownerSid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ??
        throw new InvalidOperationException("The test owner SID is unavailable.");
    try
    {
        var settingsStore = new EverVigil.Infrastructure.SettingsStore(paths);
        var target = settingsStore.Current with
        {
            TailscalePath = Path.GetFullPath(Path.Combine(root, "tailscale.exe"))
        };
        var pendingStore = EverVigil.Infrastructure.PendingSystemConfigurationStore.ForTests(
            paths.PendingSystemConfigurationPath,
            ownerSid);
        var pending = pendingStore.Begin(
            target,
            previous: null,
            previousMappingOwned: false,
            existingTargetMappingOwned: false,
            initiator: EverVigil.Infrastructure.PendingSystemConfigurationInitiator.Installer);
        pendingStore.RecordPreflight(
            pending.TransactionId,
            EverVigil.Services.ServeRootMappingOwnership.Unused,
            EverVigil.Services.ServeRootMappingOwnership.Unused,
            originalMainFirewallPort: null,
            originalTemporaryFirewallPort: null);
        pendingStore.PrepareTargetRouteMutation(pending.TransactionId);
        pendingStore.MarkTargetRouteApplied(pending.TransactionId);
        pendingStore.PrepareFirewallMutation(pending.TransactionId);
        pendingStore.MarkFirewallApplied(pending.TransactionId);
        pendingStore.MarkMutationsCompleted(pending.TransactionId);

        AssertThrows<InvalidOperationException>(() =>
            settingsStore.MarkSystemConfigurationApplied(target));
        Assert(
            File.Exists(paths.PendingSystemConfigurationPath),
            "The application consumed installer rollback evidence.");
        Assert(
            settingsStore.RequiresSystemConfiguration,
            "The application unblocked startup while installer configuration was pending.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void InstallerSystemConfigurationRequiresExactTransaction()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    var ownerSid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ??
        throw new InvalidOperationException("The test owner SID is unavailable.");
    try
    {
        var settingsStore = new EverVigil.Infrastructure.SettingsStore(paths);
        var target = WithExistingDependencyFixtures(settingsStore.Current with
        {
            PublicPort = 45_678,
            BackendPort = 45_679
        }, root);
        settingsStore.Save(target);
        var pendingStore = EverVigil.Infrastructure.PendingSystemConfigurationStore.ForTests(
            paths.PendingSystemConfigurationPath,
            ownerSid);
        var pending = pendingStore.Begin(
            target,
            previous: null,
            previousMappingOwned: false,
            existingTargetMappingOwned: false,
            initiator: EverVigil.Infrastructure.PendingSystemConfigurationInitiator.Installer);
        pendingStore.RecordPreflight(
            pending.TransactionId,
            EverVigil.Services.ServeRootMappingOwnership.Unused,
            EverVigil.Services.ServeRootMappingOwnership.Unused,
            originalMainFirewallPort: null,
            originalTemporaryFirewallPort: null);
        pendingStore.PrepareTargetRouteMutation(pending.TransactionId);
        pendingStore.MarkTargetRouteApplied(pending.TransactionId);
        pendingStore.PrepareFirewallMutation(pending.TransactionId);
        pendingStore.MarkFirewallApplied(pending.TransactionId);
        pendingStore.MarkMutationsCompleted(pending.TransactionId);

        AssertThrows<InvalidDataException>(() =>
            settingsStore.CommitInstallerSystemConfiguration(Guid.NewGuid(), target));
        AssertThrows<InvalidDataException>(() =>
            settingsStore.CommitInstallerSystemConfiguration(
                pending.TransactionId,
                target with { BackendPort = target.BackendPort + 1 }));
        Assert(
            File.Exists(paths.PendingSystemConfigurationPath),
            "An invalid installer commit discarded rollback evidence.");

        var appliedPath = Path.Combine(
            root,
            EverVigil.Infrastructure.SettingsStore.AppliedSystemConfigurationFileName);
        var ownedAppliedTemporaryPath =
            $"{appliedPath}.{pending.TransactionId:N}.tmp";
        var unrelatedAppliedTemporaryPath =
            $"{appliedPath}.{Guid.NewGuid():N}.tmp";
        File.WriteAllText(ownedAppliedTemporaryPath, "interrupted-owned-write");
        File.WriteAllText(unrelatedAppliedTemporaryPath, "unrelated-write");

        var requiredMarkerPath = Path.Combine(
            root,
            EverVigil.Infrastructure.SettingsStore.SystemConfigurationRequiredFileName);
        File.Delete(requiredMarkerPath);
        Directory.CreateDirectory(requiredMarkerPath);
        AssertThrows<UnauthorizedAccessException>(() =>
            settingsStore.CommitInstallerSystemConfiguration(pending.TransactionId, target));
        Assert(
            File.Exists(paths.PendingSystemConfigurationPath),
            "A required-marker deletion failure discarded rollback evidence.");
        Assert(
            File.Exists(appliedPath),
            "The durable applied identity was not written before marker deletion.");
        Assert(
            !File.Exists(ownedAppliedTemporaryPath) &&
            File.Exists(unrelatedAppliedTemporaryPath),
            "Atomic recovery did not remove only the transaction-owned applied temporary file.");
        Directory.Delete(requiredMarkerPath);

        File.SetAttributes(paths.PendingSystemConfigurationPath, FileAttributes.ReadOnly);
        AssertThrows<UnauthorizedAccessException>(() =>
            settingsStore.CommitInstallerSystemConfiguration(pending.TransactionId, target));
        Assert(
            File.Exists(paths.PendingSystemConfigurationPath),
            "A pending-journal deletion failure lost the journal before retry.");
        Assert(
            !File.Exists(requiredMarkerPath),
            "The required marker was recreated after the applied identity became durable.");
        File.SetAttributes(paths.PendingSystemConfigurationPath, FileAttributes.Normal);

        settingsStore.CommitInstallerSystemConfiguration(pending.TransactionId, target);
        Assert(
            !File.Exists(paths.PendingSystemConfigurationPath),
            "The exact installer commit retained its pending journal.");
        Assert(
            !settingsStore.RequiresSystemConfiguration,
            "The exact installer commit did not unblock startup.");
        using (var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(appliedPath)))
        {
            Assert(
                document.RootElement.GetProperty("publicPort").GetInt32() == target.PublicPort &&
                document.RootElement.GetProperty("backendPort").GetInt32() == target.BackendPort &&
                string.Equals(
                    document.RootElement.GetProperty("tailscalePath").GetString(),
                    target.TailscalePath,
                    StringComparison.OrdinalIgnoreCase),
                "The installer commit persisted a target other than its pending identity.");
        }
        AssertThrows<FileNotFoundException>(() =>
            settingsStore.CommitInstallerSystemConfiguration(pending.TransactionId, target));

        settingsStore.MarkSystemConfigurationRequired();
        var interactivePending = pendingStore.Begin(
            target,
            previous: null,
            previousMappingOwned: false,
            existingTargetMappingOwned: false);
        AssertThrows<InvalidOperationException>(() =>
            settingsStore.CommitInstallerSystemConfiguration(
                interactivePending.TransactionId,
                target));
        Assert(
            File.Exists(paths.PendingSystemConfigurationPath),
            "The installer command consumed an interactive pending journal.");
        pendingStore.CancelUnmutated(interactivePending.TransactionId);

        var fixedId = Guid.ParseExact("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "N");
        Assert(
            EverVigil.Program.ParseRequiredTransactionId(
                ["--system-transaction-id", fixedId.ToString("N")],
                "--system-transaction-id") == fixedId,
            "The exact lowercase installer transaction argument was not accepted.");
        AssertThrows<ArgumentException>(() =>
            EverVigil.Program.ParseRequiredTransactionId(
                ["--system-transaction-id", fixedId.ToString("N").ToUpperInvariant()],
                "--system-transaction-id"));
        AssertThrows<ArgumentException>(() =>
            EverVigil.Program.ParseRequiredTransactionId(
                [
                    "--system-transaction-id",
                    fixedId.ToString("N"),
                    "--system-transaction-id",
                    fixedId.ToString("N")
                ],
                "--system-transaction-id"));
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void InstallerPowerShellJournalMatchesProductionContract()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    var ownerSid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ??
        throw new InvalidOperationException("The test owner SID is unavailable.");
    var transactionId = Guid.NewGuid();
    try
    {
        var settingsStore = new EverVigil.Infrastructure.SettingsStore(paths);
        var target = WithExistingDependencyFixtures(settingsStore.Current with
        {
            PublicPort = 34_56,
            BackendPort = 34_57
        }, root);
        settingsStore.Save(target);

        var ownerJson = System.Text.Json.JsonSerializer.Serialize(ownerSid);
        var dataRootJson = System.Text.Json.JsonSerializer.Serialize(Path.GetFullPath(root));
        var tailscalePathJson = System.Text.Json.JsonSerializer.Serialize(target.TailscalePath);
        var installerJson = $$"""
            {
              "schemaVersion": 1,
              "transactionId": "{{transactionId:D}}",
              "ownerSid": {{ownerJson}},
              "dataRoot": {{dataRootJson}},
              "initiator": "Installer",
              "target": {
                "publicPort": {{target.PublicPort}},
                "backendPort": {{target.BackendPort}},
                "tailscalePath": {{tailscalePathJson}}
              },
              "previous": null,
              "previousMappingOwned": false,
              "existingTargetMappingOwned": false,
              "phase": "MutationsCompleted",
              "observedTargetRouteOwnership": "Unused",
              "observedPreviousRouteOwnership": "Unused",
              "firewallSnapshotCaptured": true,
              "originalMainFirewallPort": null,
              "originalTemporaryFirewallPort": null,
              "previousRouteMutationAuthorized": false,
              "targetRouteMutationAuthorized": true,
              "firewallMutationAuthorized": true
            }
            """;
        Directory.CreateDirectory(root);
        File.WriteAllText(
            paths.PendingSystemConfigurationPath,
            installerJson,
            new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

        settingsStore.CommitInstallerSystemConfiguration(transactionId, target);

        Assert(
            !File.Exists(paths.PendingSystemConfigurationPath),
            "The production reader retained a valid installer PowerShell journal.");
        Assert(
            File.Exists(Path.Combine(
                root,
                EverVigil.Infrastructure.SettingsStore.AppliedSystemConfigurationFileName)),
            "The production reader did not commit the installer PowerShell journal.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void AppliedSystemConfigurationSurvivesSettingsRecovery()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        var original = new EverVigil.Infrastructure.SettingsStore(paths);
        var applied = original.Current with
        {
            PublicPort = 45_678,
            BackendPort = 45_679,
            TailscalePath = Path.Combine(root, "tailscale.exe")
        };
        original.MarkSystemConfigurationApplied(applied);
        File.WriteAllText(paths.SettingsPath, "{ invalid json");

        var recovered = new EverVigil.Infrastructure.SettingsStore(paths);
        var lastApplied = recovered.GetLastAppliedSystemSettings() ??
            throw new InvalidOperationException("The last applied system configuration was lost.");

        Assert(recovered.RequiresSystemConfiguration, "Settings recovery did not restore the startup block.");
        Assert(lastApplied.PublicPort == applied.PublicPort, "The applied public port fell back to defaults.");
        Assert(lastApplied.BackendPort == applied.BackendPort, "The applied backend port fell back to defaults.");
        Assert(
            string.Equals(lastApplied.TailscalePath, applied.TailscalePath, StringComparison.OrdinalIgnoreCase),
            "The applied Tailscale path fell back to defaults.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void FailedAppliedStatePersistenceKeepsStartupBlocked()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        var store = new EverVigil.Infrastructure.SettingsStore(paths);
        var statePath = Path.Combine(
            root,
            EverVigil.Infrastructure.SettingsStore.AppliedSystemConfigurationFileName);
        Directory.CreateDirectory(statePath);

        var failed = false;
        try
        {
            store.MarkSystemConfigurationApplied(store.Current);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            failed = true;
        }

        Assert(failed, "Applied-state persistence unexpectedly succeeded.");
        Assert(store.RequiresSystemConfiguration, "A failed applied-state write cleared the startup block.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void RequiredSystemConfigurationBlocksSupervisorStart()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    EverVigil.Services.SupervisorEngine? supervisor = null;
    try
    {
        Directory.CreateDirectory(root);
        File.WriteAllText(paths.SettingsPath, "{ invalid json");
        var settingsStore = new EverVigil.Infrastructure.SettingsStore(paths);
        var tokenStore = new EverVigil.Infrastructure.TokenStore(paths);
        string? token = null;
        var logger = new EverVigil.Infrastructure.BoundedLogger(
            paths,
            () => settingsStore.Current,
            () => token);
        var probe = new EverVigil.Services.HealthProbe();
        supervisor = new EverVigil.Services.SupervisorEngine(
            settingsStore,
            tokenStore,
            logger,
            probe);

        supervisor.Start();

        Assert(!supervisor.IsRunning, "The supervisor started while system configuration was unverified.");
        Assert(supervisor.Current.State == SupervisorState.Faulted, "The blocked start was not reported as faulted.");
    }
    finally
    {
        if (supervisor is not null)
        {
            supervisor.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void LogClearingRemovesActiveAndRotatedGenerations()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        var logger = new EverVigil.Infrastructure.BoundedLogger(
            paths,
            AppSettings.CreateDefault,
            () => null);
        logger.Info("active");
        File.WriteAllText($"{paths.LogPath}.1", "first rotation");
        File.WriteAllText($"{paths.LogPath}.25", "old rotation");
        var unrelatedPath = $"{paths.LogPath}.backup";
        File.WriteAllText(unrelatedPath, "unrelated");

        logger.Clear();

        Assert(!File.Exists(paths.LogPath), "The active log was not removed.");
        Assert(!File.Exists($"{paths.LogPath}.1"), "The first rotated log was not removed.");
        Assert(!File.Exists($"{paths.LogPath}.25"), "An old rotated log was not removed.");
        Assert(File.Exists(unrelatedPath), "A non-generation file was removed.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void LogWritesPruneGenerationsAboveReducedLimit()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var paths = new EverVigil.Infrastructure.DataPaths(
        root,
        Path.Combine(root, "settings.json"),
        Path.Combine(root, "token.dat"),
        Path.Combine(root, "Logs"),
        Path.Combine(root, "Logs", "evervigil.log"),
        Path.Combine(root, "startup.lnk"));
    try
    {
        var settings = AppSettings.CreateDefault() with { LogFileCopies = 2 };
        var logger = new EverVigil.Infrastructure.BoundedLogger(
            paths,
            () => settings,
            () => null);
        logger.Info("active");
        File.WriteAllText($"{paths.LogPath}.1", "retained rotation");
        File.WriteAllText($"{paths.LogPath}.3", "excess rotation");
        File.WriteAllText($"{paths.LogPath}.25", "old excess rotation");
        var unrelatedPath = $"{paths.LogPath}.backup";
        File.WriteAllText(unrelatedPath, "unrelated");

        logger.Info("prune");

        Assert(File.Exists($"{paths.LogPath}.1"), "A retained log generation was removed.");
        Assert(!File.Exists($"{paths.LogPath}.3"), "An excess log generation was retained.");
        Assert(!File.Exists($"{paths.LogPath}.25"), "An old excess log generation was retained.");
        Assert(File.Exists(unrelatedPath), "A non-generation file was removed.");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void QrRendererProducesBitmap()
{
    var url = ConnectionUrlBuilder.BuildConnectionUrl(
        "host.example",
        3456,
        new string('a', 32));
    using var bitmap = EverVigil.UI.QrCodeRenderer.Render(url, pixelsPerModule: 3);
    Assert(bitmap.Width > 100 && bitmap.Height == bitmap.Width, "QR bitmap dimensions were invalid.");
    var colors = new HashSet<int>();
    for (var x = 0; x < bitmap.Width; x += 5)
    {
        for (var y = 0; y < bitmap.Height; y += 5)
        {
            colors.Add(bitmap.GetPixel(x, y).ToArgb());
        }
    }
    Assert(colors.Count >= 2, "QR bitmap was blank.");
}

static void ConcurrentBridgeStopsShareOneLifecycleTask()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var scriptPath = Path.Combine(root, "long-running.js");
    var applicationPath = Path.Combine(AppContext.BaseDirectory, "EverVigil.exe");
    var nodePath = FindExecutable("node.exe");
    EverVigil.Services.ManagedBridgeProcess? managed = null;
    try
    {
        Directory.CreateDirectory(root);
        File.WriteAllText(scriptPath, "setInterval(()=>{},1000);");
        Assert(File.Exists(applicationPath), $"Application executable was not built: {applicationPath}");
        var settings = AppSettings.CreateDefault() with
        {
            DisplayName = "lifecycle-test",
            BackendPort = 49_158,
            ProjectDirectory = root,
            NodePath = nodePath,
            EvenTerminalCliPath = scriptPath,
            CodexPath = nodePath,
            TailscalePath = nodePath
        };
        var paths = new EverVigil.Infrastructure.DataPaths(
            root,
            Path.Combine(root, "settings.json"),
            Path.Combine(root, "token.dat"),
            Path.Combine(root, "Logs"),
            Path.Combine(root, "Logs", "evervigil.log"),
            Path.Combine(root, "startup.lnk"));
        var logger = new EverVigil.Infrastructure.BoundedLogger(
            paths,
            () => settings,
            () => null);
        managed = EverVigil.Services.ManagedBridgeProcess.Start(
            settings,
            new string('a', 32),
            logger,
            applicationPath);

        var firstStop = managed.StopAsync();
        var secondStop = managed.StopAsync();
        Assert(ReferenceEquals(firstStop, secondStop), "Concurrent callers received different stop tasks.");
        var disposal = managed.DisposeAsync().AsTask();
        Task.WhenAll(firstStop, secondStop, disposal)
            .WaitAsync(TimeSpan.FromSeconds(15))
            .GetAwaiter()
            .GetResult();
    }
    finally
    {
        if (managed is not null)
        {
            try
            {
                managed.DisposeAsync().AsTask().Wait(TimeSpan.FromSeconds(10));
            }
            catch
            {
                // The job object remains the fallback for a failed lifecycle assertion.
            }
        }
        if (Directory.Exists(root))
        {
            DeleteDirectoryWithRetry(root);
        }
    }
}

static void BridgePidPipeRejectsDifferentProcess()
{
    var pipeName = $"EverVigil.Tests-Pid-Identity-{Guid.NewGuid():N}";
    var testExecutable = Path.Combine(AppContext.BaseDirectory, "EverVigil.Tests.exe");
    Assert(File.Exists(testExecutable), $"Test executable was not built: {testExecutable}");
    using var pipe = new System.IO.Pipes.NamedPipeServerStream(
        pipeName,
        System.IO.Pipes.PipeDirection.InOut,
        maxNumberOfServerInstances: 1,
        System.IO.Pipes.PipeTransmissionMode.Byte,
        System.IO.Pipes.PipeOptions.Asynchronous | System.IO.Pipes.PipeOptions.CurrentUserOnly);
    using var client = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
    {
        FileName = testExecutable,
        UseShellExecute = false,
        CreateNoWindow = true,
        ArgumentList =
        {
            "--connect-pid-test-pipe",
            pipeName
        }
    }) ?? throw new InvalidOperationException("Could not start the PID-pipe identity fixture.");
    try
    {
        pipe.WaitForConnectionAsync().WaitAsync(TimeSpan.FromSeconds(15)).GetAwaiter().GetResult();
        Assert(
            EverVigil.Services.ManagedBridgeProcess.GetPipeClientProcessId(pipe) == client.Id,
            "The PID pipe did not report the connecting process.");
        var rejected = false;
        try
        {
            EverVigil.Services.ManagedBridgeProcess.RequirePipeClientProcess(
                pipe,
                Environment.ProcessId);
        }
        catch (InvalidOperationException exception)
        {
            rejected = exception.Message.Contains(
                "unexpected process",
                StringComparison.OrdinalIgnoreCase);
        }
        Assert(rejected, "A different same-user PID-pipe client was accepted as the launcher.");
        pipe.WriteByte(1);
        pipe.Flush();
        Assert(client.WaitForExit(5_000), "The PID-pipe identity fixture did not exit.");
        Assert(client.ExitCode == 0, "The PID-pipe identity fixture failed.");
    }
    finally
    {
        if (!client.HasExited)
        {
            client.Kill(entireProcessTree: true);
            client.WaitForExit(5_000);
        }
    }
}

static void BridgeLauncherContainsImmediateDescendants()
{
    var root = Path.Combine(Path.GetTempPath(), $"EverVigil.Tests-{Guid.NewGuid():N}");
    var scriptPath = Path.Combine(root, "spawn-child.js");
    var childPidPath = Path.Combine(root, "child.pid");
    var applicationPath = Path.Combine(AppContext.BaseDirectory, "EverVigil.exe");
    var nodePath = FindExecutable("node.exe");
    var launchId = Guid.NewGuid().ToString("N");
    var gateName = $"Local\\EverVigil.Tests-Launch-{launchId}";
    var pipeName = $"EverVigil.Tests-Pid-{launchId}";
    const string stdoutCredential = "evervigil-test-qr-credential-must-not-be-forwarded";
    const string stderrCredential = "evervigil-test-secret-stderr-must-not-be-forwarded";
    System.Diagnostics.Process? launcher = null;
    System.Diagnostics.Process? node = null;
    System.Diagnostics.Process? child = null;
    System.Diagnostics.Process? unrelatedNode = null;
    EverVigil.Infrastructure.WindowsJobObject? job = null;
    var jobDisposed = false;
    try
    {
        Directory.CreateDirectory(root);
        File.WriteAllText(
            scriptPath,
            "const {spawn}=require('child_process');const fs=require('fs');" +
            $"process.stdout.write('{stdoutCredential}\\n');" +
            $"process.stderr.write('{stderrCredential}\\n');" +
            "const c=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});" +
            "fs.writeFileSync(require('path').join(process.cwd(),'child.pid'),String(c.pid));" +
            "setInterval(()=>{},1000);");
        Assert(File.Exists(applicationPath), $"Application executable was not built: {applicationPath}");

        using var gate = new EventWaitHandle(false, EventResetMode.ManualReset, gateName);
        using var pidPipe = new System.IO.Pipes.NamedPipeServerStream(
            pipeName,
            System.IO.Pipes.PipeDirection.In,
            maxNumberOfServerInstances: 1,
            System.IO.Pipes.PipeTransmissionMode.Byte,
            System.IO.Pipes.PipeOptions.Asynchronous | System.IO.Pipes.PipeOptions.CurrentUserOnly);
        var startInfo = new System.Diagnostics.ProcessStartInfo
        {
            FileName = applicationPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in new[]
                 {
                     "--bridge-launcher",
                     "--bridge-gate", gateName,
                     "--bridge-pid-pipe", pipeName,
                     "--bridge-node-path", nodePath,
                     "--bridge-cli-path", scriptPath,
                     "--bridge-backend-port", "49157",
                     "--bridge-display-name", "test",
                     "--bridge-project-directory", root
                 })
        {
            startInfo.ArgumentList.Add(argument);
        }
        EverVigil.Services.BridgeProcessEnvironment.ConfigureLauncher(
            startInfo,
            new AppSettings
            {
                DisplayName = "test",
                PublicPort = 49156,
                BackendPort = 49157,
                CodexAppServerPort = 49158,
                ProjectDirectory = root,
                NodePath = nodePath,
                EvenTerminalCliPath = scriptPath,
                CodexPath = nodePath,
                TailscalePath = AppSettings.FixedTailscalePath
            },
            new string('a', 32));

        launcher = System.Diagnostics.Process.Start(startInfo) ??
            throw new InvalidOperationException("Could not start the bridge launcher test process.");
        Thread.Sleep(250);
        Assert(!pidPipe.IsConnected, "The bridge process started before its job gate was released.");

        job = new EverVigil.Infrastructure.WindowsJobObject();
        job.Assign(launcher);
        gate.Set();
        pidPipe.WaitForConnectionAsync().WaitAsync(TimeSpan.FromSeconds(30)).GetAwaiter().GetResult();
        using var pidReader = new StreamReader(pidPipe, leaveOpen: true);
        var nodePidValue = pidReader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(30)).GetAwaiter().GetResult();
        Assert(int.TryParse(nodePidValue, out var nodePid), "The launcher did not return the Node process ID.");
        node = System.Diagnostics.Process.GetProcessById(nodePid);
        unrelatedNode = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = nodePath,
            Arguments = "-e \"setInterval(()=>{},1000)\"",
            UseShellExecute = false,
            CreateNoWindow = true
        }) ?? throw new InvalidOperationException("Could not start the unrelated Node fixture.");
        Assert(job.Contains(node), "The reported Node process was outside the launcher job.");
        Assert(!job.Contains(unrelatedNode), "An unrelated same-path Node process entered the launcher job.");

        var childPidDeadline = DateTime.UtcNow.AddSeconds(30);
        while (!File.Exists(childPidPath) && DateTime.UtcNow < childPidDeadline)
        {
            Assert(!launcher.HasExited, "The bridge launcher exited before the child PID was reported.");
            Thread.Sleep(100);
        }
        Assert(File.Exists(childPidPath), "The test Node process did not publish its child PID.");
        var childPidValue = File.ReadAllText(childPidPath);
        Assert(int.TryParse(childPidValue, out var childPid), "The test Node process did not report its child PID.");
        child = System.Diagnostics.Process.GetProcessById(childPid);
        Assert(!launcher.HasExited, "The bridge launcher exited while Node was still running.");

        job.Dispose();
        jobDisposed = true;
        Assert(node.WaitForExit(5_000), "The Node process survived job closure.");
        Assert(child.WaitForExit(5_000), "The immediate Node descendant survived job closure.");
        Assert(launcher.WaitForExit(5_000), "The bridge launcher survived job closure.");
        Assert(!unrelatedNode.HasExited, "Job closure terminated an unrelated same-path Node process.");
        var forwardedOutput = launcher.StandardOutput.ReadToEnd();
        Assert(
            !forwardedOutput.Contains(stdoutCredential, StringComparison.Ordinal),
            "The bridge launcher forwarded credential-bearing child stdout.");
        var forwardedError = launcher.StandardError.ReadToEnd();
        Assert(
            !forwardedError.Contains(stderrCredential, StringComparison.Ordinal),
            "The bridge launcher forwarded credential-bearing child stderr.");
    }
    finally
    {
        if (!jobDisposed)
        {
            try
            {
                job?.Terminate();
            }
            catch
            {
                // Best-effort cleanup for a failed containment test.
            }
            job?.Dispose();
        }
        foreach (var process in new[] { child, node, unrelatedNode, launcher })
        {
            try
            {
                if (process is { HasExited: false })
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(5_000);
                }
            }
            catch
            {
                // A concurrently terminated process no longer needs cleanup.
            }
            process?.Dispose();
        }
        if (Directory.Exists(root))
        {
            DeleteDirectoryWithRetry(root);
        }
    }
}

static void JobObjectTerminatesProcess()
{
    using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
    {
        FileName = Path.Combine(Environment.SystemDirectory, "ping.exe"),
        Arguments = "127.0.0.1 -n 60",
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true
    }) ?? throw new InvalidOperationException("Could not start test process.");
    using var job = new EverVigil.Infrastructure.WindowsJobObject();
    job.Assign(process);
    job.Terminate();
    Assert(process.WaitForExit(5_000), "Assigned process survived job termination.");
}

static void ProcessRunnerDrainsBothStreams()
{
    var powershellPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.Windows),
        "System32",
        "WindowsPowerShell",
        "v1.0",
        "powershell.exe");
    Assert(File.Exists(powershellPath), $"Windows PowerShell was not found: {powershellPath}");
    const string command =
        "$o='o'*64;$e='e'*64;for($i=0;$i-lt 4096;$i++){[Console]::Out.Write($o);[Console]::Error.Write($e)}";

    var result = EverVigil.Infrastructure.ProcessCommandRunner.Run(
        powershellPath,
        TimeSpan.FromSeconds(30),
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        command);

    Assert(result.ExitCode == 0, $"Stream test exited with {result.ExitCode}.");
    Assert(result.StandardOutput.Length >= 262_144, "Standard output was not fully drained.");
    Assert(result.StandardError.Length >= 262_144, "Standard error was not fully drained.");
}

static string FindExecutable(string fileName)
{
    var configuredPath = AppSettings.CreateDefault().NodePath;
    if (string.Equals(Path.GetFileName(configuredPath), fileName, StringComparison.OrdinalIgnoreCase) &&
        File.Exists(configuredPath))
    {
        return configuredPath;
    }

    foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(
                 Path.PathSeparator,
                 StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
    {
        var candidate = Path.Combine(directory, fileName);
        if (File.Exists(candidate))
        {
            return candidate;
        }
    }

    throw new FileNotFoundException($"Required test executable was not found: {fileName}");
}

static void DeleteDirectoryWithRetry(string path)
{
    for (var attempt = 0; attempt < 20; attempt++)
    {
        try
        {
            Directory.Delete(path, recursive: true);
            return;
        }
        catch (IOException) when (attempt < 19)
        {
            Thread.Sleep(100);
        }
        catch (UnauthorizedAccessException) when (attempt < 19)
        {
            Thread.Sleep(100);
        }
    }
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

    throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
}

sealed class TestClipboardAccess : ISensitiveClipboardAccess
{
    public string? Text { get; private set; }

    public int FailuresRemaining { get; set; }

    public void SetText(string value) => Text = value;

    public bool ContainsText()
    {
        ThrowIfLocked();
        return Text is not null;
    }

    public string GetText()
    {
        ThrowIfLocked();
        return Text ?? string.Empty;
    }

    public void Clear()
    {
        ThrowIfLocked();
        Text = null;
    }

    private void ThrowIfLocked()
    {
        if (FailuresRemaining <= 0)
        {
            return;
        }

        FailuresRemaining--;
        throw new System.Runtime.InteropServices.ExternalException("Clipboard is locked for this test.");
    }
}
