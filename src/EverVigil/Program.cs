using System.Globalization;
using EverVigil.Core;
using EverVigil.Core.Localization;
using EverVigil.Infrastructure;
using EverVigil.Services;
using EverVigil.UI;

namespace EverVigil;

internal static class Program
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        if (HasArgument(arguments, "--bridge-launcher"))
        {
            return BridgeLauncher.Run(arguments);
        }

        if (HasArgument(arguments, "--verify-localization"))
        {
            return VerifyLocalizationResources() ? 0 : 3;
        }

        FatalRecovery.WaitForPreviousProcess(arguments);
        ApplicationConfiguration.Initialize();

        var paths = DataPaths.Create();
        var settingsStore = new SettingsStore(paths);
        AppLocalizer.SetLanguage(settingsStore.Current.UiLanguage);
        var tokenStore = new TokenStore(paths);
        string? token = null;
        var logger = new BoundedLogger(paths, () => settingsStore.Current, () => token);

        try
        {
            if (settingsStore.LastRecoveryMessage is not null)
            {
                logger.Warn(settingsStore.LastRecoveryMessage);
            }

            if (HasArgument(arguments, "--validate-settings"))
            {
                var errors = AppSettingsValidator.Validate(settingsStore.Current);
                if (errors.Count == 0)
                {
                    return 0;
                }

                logger.Warn($"Runtime configuration is incomplete: {string.Join(" ", errors)}");
                return 2;
            }

            var startupRegistration = new StartupRegistration(paths);
            if (HasArgument(arguments, "--register-startup"))
            {
                startupRegistration.Register();
                return 0;
            }

            if (HasArgument(arguments, "--unregister-startup"))
            {
                startupRegistration.Unregister();
                return 0;
            }

            if (HasArgument(arguments, "--commit-installer-system-config"))
            {
                var transactionId = ParseRequiredTransactionId(
                    arguments,
                    "--system-transaction-id");
                settingsStore.CommitInstallerSystemConfiguration(
                    transactionId,
                    settingsStore.Current);
                logger.Info("Installer-owned system configuration committed locally.");
                return 0;
            }

            if (HasArgument(arguments, "--mark-system-configured"))
            {
                settingsStore.MarkSystemConfigurationApplied(settingsStore.Current);
                logger.Info("System configuration requirement cleared.");
                return 0;
            }

            if (HasArgument(arguments, "--health-check"))
            {
                if (settingsStore.RequiresSystemConfiguration)
                {
                    return 1;
                }

                token = tokenStore.GetOrCreate();
                LogTokenRecovery(tokenStore, logger);
                using var probe = new HealthProbe();
                var settings = settingsStore.Current;
                var local = probe.IsLocalEndpointReadyAsync(settings, CancellationToken.None)
                    .GetAwaiter().GetResult();
                var provider = probe.IsProviderReadyAsync(settings, token, CancellationToken.None)
                    .GetAwaiter().GetResult();
                return IsInstallerRuntimeHealthy(local, provider) ? 0 : 1;
            }

            if (HasArgument(arguments, "--installer-runtime-check"))
            {
                if (settingsStore.RequiresSystemConfiguration)
                {
                    return 1;
                }

                token = tokenStore.GetOrCreate();
                LogTokenRecovery(tokenStore, logger);
                return RunInstallerRuntimeCheck(settingsStore, tokenStore, logger);
            }

            using var coordinator = new SingleInstanceCoordinator();
            if (HasArgument(arguments, "--shutdown"))
            {
                coordinator.SignalShutdown();
                return 0;
            }

            if (!coordinator.IsPrimary)
            {
                if (!HasArgument(arguments, "--background"))
                {
                    coordinator.SignalShow();
                }

                return 0;
            }

            token = tokenStore.GetOrCreate();
            LogTokenRecovery(tokenStore, logger);
            SupervisorEngine? supervisorForFatalRecovery = null;
            FatalRecovery.Register(
                arguments,
                logger,
                () => supervisorForFatalRecovery?.IsRunning == true);

            using var healthProbe = new HealthProbe();
            var supervisor = new SupervisorEngine(settingsStore, tokenStore, logger, healthProbe);
            supervisorForFatalRecovery = supervisor;
            var dashboard = new DashboardForm(
                settingsStore,
                tokenStore,
                supervisor,
                startupRegistration,
                logger,
                paths);
            using var context = new TrayApplicationContext(
                supervisor,
                startupRegistration,
                coordinator,
                logger,
                dashboard,
                showInitially: !HasArgument(arguments, "--background"));

            logger.Info("Tray application started.");
            var forceStartRequested = HasArgument(arguments, "--force-start-service");
            var startRequested = settingsStore.Current.AutoStartService || forceStartRequested;
            if (ShouldStartSupervisor(
                    settingsStore.Current,
                    settingsStore.RequiresSystemConfiguration,
                    startRequested,
                    forceStartRequested))
            {
                supervisor.Start();
            }
            else if (startRequested)
            {
                logger.Warn("Runtime dependencies are not configured. The tray application is waiting for settings.");
            }

            Application.Run(context);
            supervisor.DisposeAsync().AsTask().GetAwaiter().GetResult();
            logger.Info("Tray application exited.");
            return 0;
        }
        catch (Exception exception)
        {
            logger.Error($"Application startup failed: {exception}");
            if (ShouldShowStartupError(arguments))
            {
                MessageBox.Show(
                    exception.Message,
                    "EverVigil",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
            else
            {
                Console.Error.WriteLine(FormatHeadlessFailure(exception));
            }

            return 1;
        }
    }

    internal static bool VerifyLocalizationResources()
    {
        var english = AppLocalizer.Text("TabOverview", CultureInfo.GetCultureInfo("en-US"));
        var japanese = AppLocalizer.Text("TabOverview", CultureInfo.GetCultureInfo("ja-JP"));
        return string.Equals(english, "OVERVIEW", StringComparison.Ordinal) &&
            !string.Equals(japanese, english, StringComparison.Ordinal) &&
            !string.Equals(japanese, "TabOverview", StringComparison.Ordinal);
    }

    private static bool HasArgument(string[] arguments, string name) =>
        arguments.Any(argument => string.Equals(argument, name, StringComparison.OrdinalIgnoreCase));

    internal static bool ShouldShowStartupError(string[] arguments)
    {
        string[] headlessArguments =
        [
            "--background",
            "--bridge-launcher",
            "--health-check",
            "--installer-runtime-check",
            "--commit-installer-system-config",
            "--mark-system-configured",
            "--register-startup",
            "--shutdown",
            "--unregister-startup",
            "--validate-settings"
        ];
        return !headlessArguments.Any(argument => HasArgument(arguments, argument));
    }

    internal static bool IsInstallerRuntimeHealthy(bool local, bool provider) =>
        local && provider;

    private static int RunInstallerRuntimeCheck(
        SettingsStore settingsStore,
        TokenStore tokenStore,
        BoundedLogger logger)
    {
        var supervisor = new SupervisorEngine(
            settingsStore,
            tokenStore,
            logger,
            new HealthProbe());
        try
        {
            supervisor.Start();
            var deadline = DateTimeOffset.UtcNow + TimeSpan.FromMinutes(3);
            while (DateTimeOffset.UtcNow < deadline)
            {
                var snapshot = supervisor.Current;
                if (IsInstallerRuntimeHealthy(
                        snapshot.LocalEndpointReady,
                        snapshot.ProviderReady))
                {
                    logger.Info("Installer runtime check completed without launching the tray UI.");
                    return 0;
                }

                Thread.Sleep(500);
            }

            logger.Error("Installer runtime check timed out before local/provider readiness.");
            return 1;
        }
        finally
        {
            supervisor.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
    }

    internal static string FormatHeadlessFailure(Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        const int maximumMessageLength = 512;
        var message = exception.Message
            .Replace('\r', ' ')
            .Replace('\n', ' ')
            .Trim();
        if (message.Length > maximumMessageLength)
        {
            message = message[..maximumMessageLength];
        }

        return $"[evervigil-headless-error] {exception.GetType().Name}: {message}";
    }

    internal static bool ShouldStartSupervisor(
        AppSettings settings,
        bool requiresSystemConfiguration,
        bool startRequested,
        bool forceStartRequested = false)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return requiresSystemConfiguration ||
            (startRequested &&
                (forceStartRequested || AppSettingsValidator.Validate(settings).Count == 0));
    }

    internal static Guid ParseRequiredTransactionId(string[] arguments, string name)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        var matches = arguments
            .Select((argument, index) => (argument, index))
            .Where(entry => string.Equals(
                entry.argument,
                name,
                StringComparison.OrdinalIgnoreCase))
            .ToArray();
        if (matches.Length != 1 || matches[0].index + 1 >= arguments.Length)
        {
            throw new ArgumentException($"{name} must be specified exactly once.");
        }
        var value = arguments[matches[0].index + 1];
        if (!Guid.TryParseExact(value, "N", out var transactionId) ||
            !string.Equals(value, transactionId.ToString("N"), StringComparison.Ordinal))
        {
            throw new ArgumentException($"{name} must be a lowercase 32-character GUID.");
        }
        return transactionId;
    }

    private static void LogTokenRecovery(TokenStore tokenStore, BoundedLogger logger)
    {
        if (tokenStore.LastRecoveryMessage is not null)
        {
            logger.Warn(tokenStore.LastRecoveryMessage);
        }
    }

}
