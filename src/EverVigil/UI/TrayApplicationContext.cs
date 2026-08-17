using EverVigil.Core;
using EverVigil.Core.Localization;
using EverVigil.Infrastructure;
using EverVigil.Services;

namespace EverVigil.UI;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly SupervisorEngine _supervisor;
    private readonly StartupRegistration _startupRegistration;
    private readonly SingleInstanceCoordinator _coordinator;
    private readonly BoundedLogger _logger;
    private readonly DashboardForm _dashboard;
    private readonly NotifyIcon _notifyIcon;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _startItem;
    private readonly ToolStripMenuItem _stopItem;
    private readonly ToolStripMenuItem _restartItem;
    private readonly ToolStripMenuItem _startupItem;
    private readonly ToolStripMenuItem _openItem;
    private readonly ToolStripMenuItem _connectionItem;
    private readonly ToolStripMenuItem _logsItem;
    private readonly ToolStripMenuItem _exitItem;
    private readonly System.Windows.Forms.Timer _commandTimer;
    private Icon? _currentIcon;
    private SupervisorState _lastState = SupervisorState.Initializing;
    private bool _exiting;
    private bool _synchronizingStartupState;

    public TrayApplicationContext(
        SupervisorEngine supervisor,
        StartupRegistration startupRegistration,
        SingleInstanceCoordinator coordinator,
        BoundedLogger logger,
        DashboardForm dashboard,
        bool showInitially)
    {
        _supervisor = supervisor;
        _startupRegistration = startupRegistration;
        _coordinator = coordinator;
        _logger = logger;
        _dashboard = dashboard;
        MainForm = dashboard;
        _ = dashboard.Handle;

        _statusItem = new ToolStripMenuItem("STOPPED") { Enabled = false };
        _startItem = new ToolStripMenuItem(AppLocalizer.Text("ButtonStart"), null, (_, _) => _supervisor.Start());
        _stopItem = new ToolStripMenuItem(AppLocalizer.Text("ButtonStop"), null, async (_, _) => await RunActionAsync(_supervisor.StopAsync));
        _restartItem = new ToolStripMenuItem(AppLocalizer.Text("ButtonRestart"), null, async (_, _) =>
            await RunActionAsync(() => _supervisor.RestartAsync("Tray restart requested.")));
        _startupItem = new ToolStripMenuItem(AppLocalizer.Text("TrayStartOnLogin"))
        {
            Checked = startupRegistration.IsRegistered,
            CheckOnClick = true
        };
        _startupItem.CheckedChanged += OnStartupChanged;
        _startupRegistration.RegistrationChanged += OnStartupRegistrationChanged;

        _openItem = new ToolStripMenuItem(
            AppLocalizer.Text("TrayOpenDashboard"),
            null,
            (_, _) => _dashboard.ShowDashboard());
        _connectionItem = new ToolStripMenuItem(
            AppLocalizer.Text("TrayConnection"),
            null,
            (_, _) => _dashboard.ShowDashboard(1));
        _logsItem = new ToolStripMenuItem(
            AppLocalizer.Text("TrayLogs"),
            null,
            (_, _) => _dashboard.ShowDashboard(3));
        _exitItem = new ToolStripMenuItem(
            AppLocalizer.Text("TrayExit"),
            null,
            async (_, _) => await ExitAsync());
        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_openItem);
        menu.Items.Add(_connectionItem);
        menu.Items.Add(_logsItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_startItem);
        menu.Items.Add(_stopItem);
        menu.Items.Add(_restartItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_startupItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_exitItem);

        _currentIcon = TrayIconFactory.Create(SupervisorState.Stopped);
        _notifyIcon = new NotifyIcon
        {
            Icon = _currentIcon,
            Text = "EverVigil: STOPPED",
            ContextMenuStrip = menu,
            Visible = true
        };
        _notifyIcon.DoubleClick += (_, _) => _dashboard.ShowDashboard();

        _commandTimer = new System.Windows.Forms.Timer { Interval = 250 };
        _commandTimer.Tick += OnCommandTimer;
        _commandTimer.Start();

        _supervisor.SnapshotChanged += OnSnapshotChanged;
        AppLocalizer.LanguageChanged += OnLanguageChanged;
        ApplyLocalization();

        if (showInitially)
        {
            _dashboard.ShowDashboard();
        }
        else
        {
            _dashboard.ShowInTaskbar = false;
            _dashboard.Hide();
        }

        SynchronizeStartupState(_startupRegistration.IsRegistered);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _commandTimer.Stop();
            _commandTimer.Dispose();
            _supervisor.SnapshotChanged -= OnSnapshotChanged;
            AppLocalizer.LanguageChanged -= OnLanguageChanged;
            _startupRegistration.RegistrationChanged -= OnStartupRegistrationChanged;
            _notifyIcon.Visible = false;
            _notifyIcon.ContextMenuStrip?.Dispose();
            _notifyIcon.Dispose();
            _currentIcon?.Dispose();
            _dashboard.Dispose();
        }

        base.Dispose(disposing);
    }

    private void OnSnapshotChanged(SupervisorSnapshot snapshot)
    {
        if (_dashboard.IsDisposed || _dashboard.Disposing)
        {
            return;
        }

        try
        {
            _dashboard.BeginInvoke(() => UpdateTray(snapshot));
        }
        catch (InvalidOperationException) when (_dashboard.IsDisposed || _dashboard.Disposing)
        {
            // Shutdown raced with a final supervisor state notification.
        }
    }

    private void UpdateTray(SupervisorSnapshot snapshot)
    {
        _statusItem.Text = GetStateText(snapshot.State);
        _startItem.Enabled = !_supervisor.IsRunning;
        _stopItem.Enabled = _supervisor.IsRunning;
        _restartItem.Enabled = _supervisor.IsRunning;

        var icon = TrayIconFactory.Create(snapshot.State);
        _notifyIcon.Icon = icon;
        _currentIcon?.Dispose();
        _currentIcon = icon;
        var notifyText = $"EverVigil: {GetStateText(snapshot.State)}";
        _notifyIcon.Text = notifyText[..Math.Min(63, notifyText.Length)];

        if (_lastState == SupervisorState.Online && snapshot.State is SupervisorState.Degraded or SupervisorState.Faulted)
        {
            _notifyIcon.ShowBalloonTip(
                5000,
                "EverVigil",
                snapshot.LastError ?? AppLocalizer.Text("TrayDegraded"),
                ToolTipIcon.Warning);
        }
        else if (_lastState is SupervisorState.Degraded or SupervisorState.Faulted && snapshot.State == SupervisorState.Online)
        {
            _notifyIcon.ShowBalloonTip(
                4000,
                "EverVigil",
                AppLocalizer.Text("TrayRecovered"),
                ToolTipIcon.Info);
        }

        _lastState = snapshot.State;
    }

    private void OnLanguageChanged(object? sender, EventArgs args)
    {
        if (_dashboard.IsDisposed || _dashboard.Disposing)
        {
            return;
        }

        try
        {
            if (_dashboard.InvokeRequired)
            {
                _dashboard.BeginInvoke(ApplyLocalization);
                return;
            }

            ApplyLocalization();
        }
        catch (InvalidOperationException) when (_dashboard.IsDisposed || _dashboard.Disposing)
        {
            // Shutdown raced with a language change.
        }
    }

    private void ApplyLocalization()
    {
        _openItem.Text = AppLocalizer.Text("TrayOpenDashboard");
        _connectionItem.Text = AppLocalizer.Text("TrayConnection");
        _logsItem.Text = AppLocalizer.Text("TrayLogs");
        _startItem.Text = AppLocalizer.Text("ButtonStart");
        _stopItem.Text = AppLocalizer.Text("ButtonStop");
        _restartItem.Text = AppLocalizer.Text("ButtonRestart");
        _startupItem.Text = AppLocalizer.Text("TrayStartOnLogin");
        _exitItem.Text = AppLocalizer.Text("TrayExit");
        UpdateTray(_supervisor.Current);
    }

    private static string GetStateText(SupervisorState state) => state switch
    {
        SupervisorState.Online => AppLocalizer.Text("StateOnline"),
        SupervisorState.Degraded => AppLocalizer.Text("StateDegraded"),
        SupervisorState.Starting => AppLocalizer.Text("StateStarting"),
        SupervisorState.Restarting => AppLocalizer.Text("StateRestarting"),
        SupervisorState.Faulted => AppLocalizer.Text("StateFaulted"),
        SupervisorState.Stopping => AppLocalizer.Text("StateStopping"),
        _ => AppLocalizer.Text("StateStopped")
    };

    private void OnCommandTimer(object? sender, EventArgs args)
    {
        if (_coordinator.ConsumeShowRequest())
        {
            _dashboard.ShowDashboard();
        }

        if (_coordinator.ConsumeShutdownRequest())
        {
            _ = ExitAsync();
        }
    }

    private void OnStartupChanged(object? sender, EventArgs args)
    {
        if (_synchronizingStartupState)
        {
            return;
        }

        try
        {
            if (_startupItem.Checked)
            {
                _startupRegistration.Register();
            }
            else
            {
                _startupRegistration.Unregister();
            }
        }
        catch (Exception exception)
        {
            _logger.Error($"Startup registration failed: {exception.Message}");
            SynchronizeStartupState(_startupRegistration.IsRegistered);
            MessageBox.Show(
                exception.Message,
                AppLocalizer.Text("StartupRegistrationFailedTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private void OnStartupRegistrationChanged(bool isRegistered)
    {
        if (_dashboard.IsDisposed || _dashboard.Disposing)
        {
            return;
        }

        try
        {
            if (_dashboard.InvokeRequired)
            {
                _dashboard.BeginInvoke(() => SynchronizeStartupState(isRegistered));
                return;
            }

            SynchronizeStartupState(isRegistered);
        }
        catch (InvalidOperationException) when (_dashboard.IsDisposed || _dashboard.Disposing)
        {
            // Shutdown raced with a startup-registration notification.
        }
    }

    private void SynchronizeStartupState(bool isRegistered)
    {
        _synchronizingStartupState = true;
        try
        {
            _startupItem.Checked = isRegistered;
        }
        finally
        {
            _synchronizingStartupState = false;
        }
    }

    private async Task RunActionAsync(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (Exception exception)
        {
            _logger.Error($"Tray action failed: {exception.Message}");
            MessageBox.Show(
                exception.Message,
                AppLocalizer.Text("ActionFailedTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private async Task ExitAsync()
    {
        if (_exiting)
        {
            return;
        }

        _exiting = true;
        _commandTimer.Stop();
        _notifyIcon.Visible = false;
        try
        {
            await _supervisor.StopAsync();
        }
        finally
        {
            _dashboard.AllowClose();
            ExitThread();
        }
    }
}
