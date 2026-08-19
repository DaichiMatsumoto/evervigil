using System.Net.NetworkInformation;
using EverVigil.Core;
using EverVigil.Infrastructure;

namespace EverVigil.Services;

internal sealed class SupervisorEngine : IAsyncDisposable
{
    private readonly object _gate = new();
    private readonly SettingsStore _settingsStore;
    private readonly TokenStore _tokenStore;
    private readonly BoundedLogger _logger;
    private readonly HealthProbe _healthProbe;
    private readonly AsyncRestartSignal _restartSignal = new();
    private readonly ExponentialBackoffPolicy _backoff = new(
        TimeSpan.FromSeconds(10),
        TimeSpan.FromMinutes(5));

    private CancellationTokenSource? _lifetimeCancellation;
    private Task? _supervisorTask;
    private ManagedBridgeProcess? _activeProcess;
    private string? _requestedRestartReason;
    private bool _skipNextBackoff;
    private long _lifecycleVersion;
    private SupervisorSnapshot _snapshot = SupervisorSnapshot.Initial;

    public SupervisorEngine(
        SettingsStore settingsStore,
        TokenStore tokenStore,
        BoundedLogger logger,
        HealthProbe healthProbe)
    {
        _settingsStore = settingsStore;
        _tokenStore = tokenStore;
        _logger = logger;
        _healthProbe = healthProbe;
        Publish(SupervisorState.Stopped);
    }

    public event Action<SupervisorSnapshot>? SnapshotChanged;

    public SupervisorSnapshot Current
    {
        get
        {
            lock (_gate)
            {
                return _snapshot;
            }
        }
    }

    public bool IsRunning
    {
        get
        {
            lock (_gate)
            {
                return _supervisorTask is { IsCompleted: false };
            }
        }
    }

    public void Start()
    {
        if (_settingsStore.RequiresSystemConfiguration)
        {
            const string error =
                "System configuration must be reapplied before the backend can start.";
            _logger.Warn(error);
            Publish(SupervisorState.Faulted, lastError: error);
            return;
        }

        lock (_gate)
        {
            if (_supervisorTask is { IsCompleted: false })
            {
                return;
            }

            _lifetimeCancellation?.Dispose();
            var cancellation = new CancellationTokenSource();
            var lifecycleVersion = ++_lifecycleVersion;
            _lifetimeCancellation = cancellation;
            _supervisorTask = Task.Run(() => RunAsync(cancellation.Token, lifecycleVersion));
        }
    }

    public async Task StopAsync()
    {
        CancellationTokenSource? cancellation;
        Task? supervisorTask;
        ManagedBridgeProcess? activeProcess;
        long lifecycleVersion;
        lock (_gate)
        {
            cancellation = _lifetimeCancellation;
            supervisorTask = _supervisorTask;
            activeProcess = _activeProcess;
            lifecycleVersion = _lifecycleVersion;
        }

        if (supervisorTask is null)
        {
            lock (_gate)
            {
                if (_lifecycleVersion == lifecycleVersion && _supervisorTask is null)
                {
                    ClearManualRestartStateLocked();
                }
            }
            Publish(SupervisorState.Stopped, requiredLifecycleVersion: lifecycleVersion);
            return;
        }

        Publish(
            SupervisorState.Stopping,
            backendProcessId: activeProcess?.Id,
            requiredLifecycleVersion: lifecycleVersion);
        if (cancellation is not null)
        {
            try
            {
                await cancellation.CancelAsync().ConfigureAwait(false);
            }
            catch (ObjectDisposedException) when (supervisorTask.IsCompleted)
            {
                // A completed run can be replaced while this stop is awaiting cleanup.
            }
        }
        if (activeProcess is not null)
        {
            await activeProcess.StopAsync().ConfigureAwait(false);
        }

        try
        {
            await supervisorTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Expected during service shutdown.
        }

        var clearedLifecycle = false;
        lock (_gate)
        {
            if (_lifecycleVersion == lifecycleVersion &&
                ReferenceEquals(_supervisorTask, supervisorTask) &&
                ReferenceEquals(_lifetimeCancellation, cancellation))
            {
                _supervisorTask = null;
                _lifetimeCancellation = null;
                ClearManualRestartStateLocked();
                clearedLifecycle = true;
            }
        }

        if (clearedLifecycle)
        {
            cancellation?.Dispose();
            Publish(SupervisorState.Stopped, requiredLifecycleVersion: lifecycleVersion);
        }
    }

    public async Task RestartAsync(string reason)
    {
        ManagedBridgeProcess? process;
        lock (_gate)
        {
            if (_supervisorTask is not { IsCompleted: false })
            {
                Start();
                return;
            }

            _requestedRestartReason = reason;
            _skipNextBackoff = true;
            process = _activeProcess;
        }

        _logger.Info($"Restart requested: {reason}");
        if (process is not null)
        {
            await process.StopAsync().ConfigureAwait(false);
        }
        else
        {
            _restartSignal.Signal();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _restartSignal.Dispose();
        _healthProbe.Dispose();
    }

    private async Task RunAsync(CancellationToken cancellationToken, long lifecycleVersion)
    {
        var restartAttempt = 0;
        _logger.Info("Supervisor started.");

        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var settings = _settingsStore.Current;
                var validationErrors = AppSettingsValidator.Validate(settings);
                if (validationErrors.Count > 0)
                {
                    var error = string.Join(" ", validationErrors);
                    Publish(SupervisorState.Faulted, restartAttempt: restartAttempt, lastError: error);
                    _logger.Error(error);
                    var interrupted = await DelayAfterFailureAsync(++restartAttempt, cancellationToken)
                        .ConfigureAwait(false);
                    if (interrupted)
                    {
                        var reason = "Manual restart requested.";
                        ConsumeManualRestart(ref reason);
                        restartAttempt = 0;
                    }
                    continue;
                }

                var token = _tokenStore.GetOrCreate();
                DateTimeOffset? readyAt = null;
                var restartReason = "Even Terminal process exited.";
                var manualRestart = false;

                try
                {
                    EnsureBackendPortAvailable(settings.BackendPort);
                    Publish(SupervisorState.Starting, restartAttempt: restartAttempt);
                    var process = ManagedBridgeProcess.Start(settings, token, _logger);
                    var restartWasPending = SetActiveProcess(process);
                    if (restartWasPending)
                    {
                        _restartSignal.TryConsume();
                        await process.StopAsync().ConfigureAwait(false);
                        throw new InvalidOperationException("A restart was requested before startup completed.");
                    }
                    Publish(
                        SupervisorState.Starting,
                        backendProcessId: process.Id,
                        restartAttempt: restartAttempt);

                    var startupResult = await WaitUntilReadyAsync(
                        process,
                        settings,
                        token,
                        cancellationToken).ConfigureAwait(false);
                    if (!startupResult.Ready)
                    {
                        throw new InvalidOperationException(startupResult.Error);
                    }

                    readyAt = DateTimeOffset.Now;
                    _logger.Info($"Backend online pid={process.Id}.");
                    Publish(
                        startupResult.PublicReady ? SupervisorState.Online : SupervisorState.Degraded,
                        process.Id,
                        localReady: true,
                        providerReady: true,
                        publicReady: startupResult.PublicReady,
                        restartAttempt: restartAttempt,
                        lastError: startupResult.PublicReady ? null : "Tailnet endpoint is unavailable.");

                    restartReason = await MonitorProcessAsync(
                        process,
                        settings,
                        token,
                        restartAttempt,
                        cancellationToken).ConfigureAwait(false);
                    manualRestart = ConsumeManualRestart(ref restartReason);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception exception)
                {
                    restartReason = exception.Message;
                    manualRestart = ConsumeManualRestart(ref restartReason);
                    _logger.Error(restartReason);
                }
                finally
                {
                    await ClearActiveProcessAsync().ConfigureAwait(false);
                }

                if (cancellationToken.IsCancellationRequested)
                {
                    break;
                }

                if (manualRestart)
                {
                    restartAttempt = 0;
                }
                else if (readyAt is not null &&
                         DateTimeOffset.Now - readyAt.Value >= TimeSpan.FromSeconds(settings.StableRunSeconds))
                {
                    restartAttempt = 0;
                }
                else
                {
                    restartAttempt++;
                }

                var delay = manualRestart ? TimeSpan.Zero : _backoff.GetDelay(restartAttempt);
                var nextRetryAt = delay > TimeSpan.Zero ? DateTimeOffset.Now + delay : DateTimeOffset.Now;
                Publish(
                    SupervisorState.Restarting,
                    restartAttempt: restartAttempt,
                    nextRetryAt: nextRetryAt,
                    lastError: restartReason);
                _logger.Warn(
                    $"Restarting reason={restartReason} delaySeconds={(int)delay.TotalSeconds} attempt={restartAttempt}");
                if (delay > TimeSpan.Zero)
                {
                    var interrupted = await _restartSignal.WaitAsync(delay, cancellationToken).ConfigureAwait(false);
                    if (interrupted)
                    {
                        ConsumeManualRestart(ref restartReason);
                        restartAttempt = 0;
                    }
                }
            }
        }
        finally
        {
            await ClearActiveProcessAsync().ConfigureAwait(false);
            _logger.Info("Supervisor stopped.");
            Publish(SupervisorState.Stopped, requiredLifecycleVersion: lifecycleVersion);
        }
    }

    private async Task<(bool Ready, bool PublicReady, string Error)> WaitUntilReadyAsync(
        ManagedBridgeProcess process,
        AppSettings settings,
        string token,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.Now + TimeSpan.FromSeconds(settings.StartupTimeoutSeconds);
        while (DateTimeOffset.Now < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (process.HasExited)
            {
                return (false, false, $"Even Terminal exited during startup with code {process.ExitCode}.");
            }

            var localReady = await _healthProbe.IsLocalEndpointReadyAsync(settings, cancellationToken)
                .ConfigureAwait(false);
            var providerReady = localReady && await _healthProbe
                .IsProviderReadyAsync(settings, token, cancellationToken)
                .ConfigureAwait(false);
            Publish(
                SupervisorState.Starting,
                process.Id,
                localReady,
                providerReady,
                publicReady: false,
                restartAttempt: Current.RestartAttempt);
            if (localReady && providerReady)
            {
                var publicReady = await _healthProbe
                    .IsPublicEndpointReadyAsync(settings, token, cancellationToken)
                    .ConfigureAwait(false);
                return (true, publicReady, string.Empty);
            }

            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false);
        }

        return (false, false, $"Backend did not become ready within {settings.StartupTimeoutSeconds} seconds.");
    }

    private async Task<string> MonitorProcessAsync(
        ManagedBridgeProcess process,
        AppSettings settings,
        string token,
        int restartAttempt,
        CancellationToken cancellationToken)
    {
        var localFailures = 0;
        var providerFailures = 0;
        var providerReady = true;
        var publicReady = Current.PublicEndpointReady;
        var nextProviderCheck = DateTimeOffset.Now + TimeSpan.FromSeconds(settings.ProviderCheckIntervalSeconds);
        var nextPublicCheck = DateTimeOffset.Now;
        var exited = process.WaitForExitAsync(cancellationToken);

        while (!cancellationToken.IsCancellationRequested)
        {
            var delay = Task.Delay(TimeSpan.FromSeconds(settings.HealthIntervalSeconds), cancellationToken);
            var completed = await Task.WhenAny(delay, exited).ConfigureAwait(false);
            if (completed == exited || process.HasExited)
            {
                await exited.ConfigureAwait(false);
                return ConsumeRestartReason($"Even Terminal exited with code {process.ExitCode}.");
            }

            var localReady = await _healthProbe.IsLocalEndpointReadyAsync(settings, cancellationToken)
                .ConfigureAwait(false);
            localFailures = localReady ? 0 : localFailures + 1;
            if (localFailures >= settings.FailureThreshold)
            {
                return $"Local health check failed {localFailures} times.";
            }

            var now = DateTimeOffset.Now;
            if (now >= nextProviderCheck)
            {
                providerReady = await _healthProbe.IsProviderReadyAsync(settings, token, cancellationToken)
                    .ConfigureAwait(false);
                providerFailures = providerReady ? 0 : providerFailures + 1;
                nextProviderCheck = now + TimeSpan.FromSeconds(settings.ProviderCheckIntervalSeconds);
                if (providerFailures >= settings.FailureThreshold)
                {
                    return $"Codex provider check failed {providerFailures} times.";
                }
            }

            if (now >= nextPublicCheck)
            {
                publicReady = await _healthProbe.IsPublicEndpointReadyAsync(settings, token, cancellationToken)
                    .ConfigureAwait(false);
                nextPublicCheck = now + TimeSpan.FromSeconds(settings.PublicCheckIntervalSeconds);
            }

            var state = localReady && providerReady && publicReady
                ? SupervisorState.Online
                : SupervisorState.Degraded;
            var error = publicReady
                ? providerReady ? null : "Codex provider is temporarily unavailable."
                : "Tailnet endpoint is unavailable.";
            Publish(
                state,
                process.Id,
                localReady,
                providerReady,
                publicReady,
                restartAttempt,
                lastError: error);
        }

        cancellationToken.ThrowIfCancellationRequested();
        return "Supervisor stopped.";
    }

    private async Task<bool> DelayAfterFailureAsync(int attempt, CancellationToken cancellationToken)
    {
        var delay = _backoff.GetDelay(attempt);
        Publish(
            SupervisorState.Restarting,
            restartAttempt: attempt,
            nextRetryAt: DateTimeOffset.Now + delay,
            lastError: Current.LastError);
        return await _restartSignal.WaitAsync(delay, cancellationToken).ConfigureAwait(false);
    }

    private bool SetActiveProcess(ManagedBridgeProcess process)
    {
        lock (_gate)
        {
            _activeProcess = process;
            return _skipNextBackoff;
        }
    }

    private async Task ClearActiveProcessAsync()
    {
        ManagedBridgeProcess? process;
        lock (_gate)
        {
            process = _activeProcess;
            _activeProcess = null;
        }

        if (process is not null)
        {
            await process.DisposeAsync().ConfigureAwait(false);
        }
    }

    private bool ConsumeManualRestart(ref string reason)
    {
        lock (_gate)
        {
            if (!_skipNextBackoff)
            {
                return false;
            }

            reason = _requestedRestartReason ?? reason;
            _requestedRestartReason = null;
            _skipNextBackoff = false;
            return true;
        }
    }

    private void ClearManualRestartStateLocked()
    {
        _requestedRestartReason = null;
        _skipNextBackoff = false;
        _restartSignal.TryConsume();
    }

    private string ConsumeRestartReason(string fallback)
    {
        lock (_gate)
        {
            return _requestedRestartReason ?? fallback;
        }
    }

    private void Publish(
        SupervisorState state,
        int? backendProcessId = null,
        bool localReady = false,
        bool providerReady = false,
        bool publicReady = false,
        int restartAttempt = 0,
        DateTimeOffset? nextRetryAt = null,
        string? lastError = null,
        long? requiredLifecycleVersion = null)
    {
        SupervisorSnapshot snapshot;
        lock (_gate)
        {
            if (requiredLifecycleVersion is not null &&
                requiredLifecycleVersion.Value != _lifecycleVersion)
            {
                return;
            }

            var now = DateTimeOffset.Now;
            var stateSince = _snapshot.State == state ? _snapshot.StateSince : now;
            var safeError = SecretRedactor.Redact(lastError, _tokenStore.GetOrCreate());
            snapshot = new SupervisorSnapshot(
                state,
                now,
                stateSince,
                backendProcessId,
                localReady,
                providerReady,
                publicReady,
                restartAttempt,
                nextRetryAt,
                string.IsNullOrWhiteSpace(safeError) ? null : safeError);
            _snapshot = snapshot;
        }

        SnapshotChanged?.Invoke(snapshot);
    }

    private static void EnsureBackendPortAvailable(int port)
    {
        try
        {
            var occupied = IPGlobalProperties.GetIPGlobalProperties()
                .GetActiveTcpListeners()
                .Any(endpoint => endpoint.Port == port);
            if (occupied)
            {
                throw new InvalidOperationException($"Backend port {port} is already in use.");
            }
        }
        catch (NetworkInformationException exception)
        {
            throw new InvalidOperationException($"Could not inspect backend port {port}.", exception);
        }
    }
}
