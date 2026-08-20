using System.Diagnostics;
using EverVigil.Core;
using EverVigil.Core.Localization;
using EverVigil.Infrastructure;
using EverVigil.Services;

namespace EverVigil.UI;

internal sealed class DashboardForm : Form
{
    internal static readonly Size DefaultClientSize = new(720, 600);
    internal static readonly Size MinimumWindowSize = new(680, 560);
    internal const int SecretRevealSeconds = 60;

    private readonly SettingsStore _settingsStore;
    private readonly TokenStore _tokenStore;
    private readonly SupervisorEngine _supervisor;
    private readonly StartupRegistration _startupRegistration;
    private readonly BoundedLogger _logger;
    private readonly DataPaths _paths;
    private readonly ProtectedTailscaleIdentityStore _tailscaleIdentityStore = new();
    private readonly SensitiveClipboard _clipboard;
    private readonly System.Windows.Forms.Timer _secretTimer;
    private readonly System.Windows.Forms.Timer _displayTimer;
    private readonly SemaphoreSlim _systemConfigurationGate = new(1, 1);
    private readonly Icon _windowIcon = TrayIconFactory.Create(SupervisorState.Online);
    private readonly Bitmap _brandLogo = BrandAssets.LoadLogoBitmap();

    private readonly CyberTabControl _tabs = new();
    private readonly Label _headerNodeLabel = new();
    private readonly Label _stateLabel = new();
    private readonly Label _stateDetailLabel = new();
    private readonly Label _pidValue = new();
    private readonly Label _localValue = new();
    private readonly Label _providerValue = new();
    private readonly Label _publicValue = new();
    private readonly Label _updatedValue = new();
    private readonly Button _startButton = new();
    private readonly Button _stopButton = new();
    private readonly Button _restartButton = new();

    private readonly Label _publicBaseValue = new();
    private readonly TextBox _tokenValue = new();
    private readonly TextBox _connectionUrlValue = new();
    private readonly PictureBox _qrPicture = new();
    private readonly Label _qrHiddenLabel = new();
    private readonly Button _revealButton = new();
    private readonly Label _connectionActionStatus = new();

    private readonly ComboBox _languageInput = new();
    private readonly TextBox _displayNameInput = new();
    private readonly TextBox _publicHostInput = new();
    private readonly NumericUpDown _publicPortInput = NewPortInput();
    private readonly NumericUpDown _backendPortInput = NewPortInput();
    private readonly NumericUpDown _codexPortInput = NewPortInput();
    private readonly TextBox _nodePathInput = new();
    private readonly TextBox _cliPathInput = new();
    private readonly TextBox _codexPathInput = new();
    private readonly TextBox _tailscalePathInput = new();
    private readonly NumericUpDown _healthIntervalInput = NewNumberInput(5, 3600);
    private readonly NumericUpDown _providerIntervalInput = NewNumberInput(15, 3600);
    private readonly NumericUpDown _publicIntervalInput = NewNumberInput(15, 3600);
    private readonly NumericUpDown _failureThresholdInput = NewNumberInput(1, 20);
    private readonly NumericUpDown _logSizeInput = NewNumberInput(1, 100);
    private readonly NumericUpDown _logCopiesInput = NewNumberInput(1, 10);
    private readonly CheckBox _diagnosticLoggingInput = new();
    private readonly CheckBox _autoStartServiceInput = new();
    private readonly CheckBox _startOnLoginInput = new();
    private readonly Label _settingsStatus = new();

    private readonly RichTextBox _logText = new();
    private Func<string>? _settingsStatusFactory;
    private Func<string>? _connectionStatusFactory;
    private Func<string>? _logStatusFactory;
    private bool _allowClose;
    private bool _applyingLanguage;
    private bool _secretsVisible;

    public DashboardForm(
        SettingsStore settingsStore,
        TokenStore tokenStore,
        SupervisorEngine supervisor,
        StartupRegistration startupRegistration,
        BoundedLogger logger,
        DataPaths paths)
    {
        _settingsStore = settingsStore;
        _tokenStore = tokenStore;
        _supervisor = supervisor;
        _startupRegistration = startupRegistration;
        _logger = logger;
        _paths = paths;
        _clipboard = new SensitiveClipboard(settingsStore.Current.ClipboardClearSeconds);
        _secretTimer = new System.Windows.Forms.Timer { Interval = SecretRevealSeconds * 1000 };
        _secretTimer.Tick += (_, _) => HideSecrets();
        _displayTimer = new System.Windows.Forms.Timer { Interval = 1_000 };
        _displayTimer.Tick += (_, _) => UpdateOverview(_supervisor.Current);

        BuildWindow();
        AppLocalizer.LanguageChanged += OnLanguageChanged;
        LoadSettings();
        if (_settingsStore.LastRecoveryMessageResourceKey is not null)
        {
            SetSettingsStatus(_settingsStore.LastRecoveryMessageResourceKey);
        }
        RefreshConnectionView();
        if (_tokenStore.LastRecoveryMessageResourceKey is not null)
        {
            SetConnectionStatus(_tokenStore.LastRecoveryMessageResourceKey);
        }
        UpdateOverview(supervisor.Current);
        RefreshLogs();

        supervisor.SnapshotChanged += OnSnapshotChanged;
        startupRegistration.RegistrationChanged += OnStartupRegistrationChanged;
        FormClosing += OnFormClosing;
        Deactivate += (_, _) => HideSecrets();
        _displayTimer.Start();
    }

    public void ShowDashboard(int tabIndex = 0)
    {
        _tabs.SelectedIndex = Math.Clamp(tabIndex, 0, _tabs.TabPages.Count - 1);
        ShowInTaskbar = true;
        if (!Visible)
        {
            Show();
        }

        WindowState = FormWindowState.Normal;
        Activate();
        BringToFront();
        if (tabIndex == 3)
        {
            RefreshLogs();
        }
    }

    public void AllowClose()
    {
        _allowClose = true;
        Close();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            AppLocalizer.LanguageChanged -= OnLanguageChanged;
            _supervisor.SnapshotChanged -= OnSnapshotChanged;
            _startupRegistration.RegistrationChanged -= OnStartupRegistrationChanged;
            _secretTimer.Dispose();
            _displayTimer.Dispose();
            _clipboard.Dispose();
            _qrPicture.Image?.Dispose();
            _windowIcon.Dispose();
            _brandLogo.Dispose();
        }

        base.Dispose(disposing);
    }

    private void BuildWindow()
    {
        Text = "EverVigil";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = DefaultClientSize;
        MinimumSize = MinimumWindowSize;
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI Variable Text", 9F, FontStyle.Regular);
        BackColor = AppTheme.Canvas;
        ForeColor = AppTheme.Text;
        Icon = _windowIcon;
        ShowInTaskbar = false;

        var header = new Panel
        {
            Dock = DockStyle.Top,
            Height = 78,
            BackColor = AppTheme.Void,
            Padding = new Padding(18, 12, 18, 10)
        };
        header.Paint += (_, args) => PaintHeader(header, args);
        var logo = new PictureBox
        {
            Image = _brandLogo,
            Location = new Point(18, 16),
            Size = new Size(44, 44),
            SizeMode = PictureBoxSizeMode.Zoom
        };
        var title = new Label
        {
            AutoSize = true,
            Text = "EverVigil",
            Font = new Font("Cascadia Mono", 14F, FontStyle.Bold),
            ForeColor = AppTheme.Neon,
            Location = new Point(76, 13)
        };
        var subtitle = new Label
        {
            AutoSize = true,
            Tag = "loc:AppSubtitle",
            ForeColor = AppTheme.Muted,
            Font = new Font("Cascadia Mono", 8F),
            Location = new Point(77, 43)
        };
        _headerNodeLabel.AutoSize = false;
        _headerNodeLabel.Anchor = AnchorStyles.Top;
        _headerNodeLabel.Location = new Point(ClientSize.Width - 306, 19);
        _headerNodeLabel.Size = new Size(284, 34);
        _headerNodeLabel.TextAlign = ContentAlignment.MiddleRight;
        _headerNodeLabel.Font = new Font("Cascadia Mono", 8F, FontStyle.Bold);
        _headerNodeLabel.ForeColor = AppTheme.Cyan;
        header.Controls.Add(logo);
        header.Controls.Add(title);
        header.Controls.Add(subtitle);
        header.Controls.Add(_headerNodeLabel);
        header.Resize += (_, _) =>
        {
            _headerNodeLabel.Visible = header.ClientSize.Width >= 700;
            _headerNodeLabel.Left = Math.Max(390, header.ClientSize.Width - 302);
        };

        _tabs.Dock = DockStyle.Fill;
        _tabs.BackColor = AppTheme.Canvas;
        _tabs.TabPages.Add(BuildOverviewPage());
        _tabs.TabPages.Add(BuildConnectionPage());
        _tabs.TabPages.Add(BuildSettingsPage());
        _tabs.TabPages.Add(BuildLogsPage());
        _tabs.TabPages.Add(BuildAboutPage());

        Controls.Add(_tabs);
        Controls.Add(header);
        ApplyLocalization();
    }

    private TabPage BuildOverviewPage()
    {
        var page = NewTabPage("TabOverview");
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = AppTheme.Canvas,
            Padding = new Padding(16),
            ColumnCount = 1,
            RowCount = 2
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 110));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var statusPanel = new CyberPanel
        {
            Dock = DockStyle.Fill,
            ShowGrid = true,
            AccentColor = AppTheme.Neon,
            Margin = new Padding(0, 0, 0, 10)
        };
        _stateLabel.AutoSize = true;
        _stateLabel.Font = new Font("Cascadia Mono", 23F, FontStyle.Bold);
        _stateLabel.Location = new Point(18, 15);
        _stateDetailLabel.AutoSize = false;
        _stateDetailLabel.Location = new Point(20, 64);
        _stateDetailLabel.Size = new Size(260, 24);
        _stateDetailLabel.Font = new Font("Cascadia Mono", 8.5F);
        _stateDetailLabel.ForeColor = AppTheme.Muted;
        _stateDetailLabel.AutoEllipsis = true;
        statusPanel.Controls.Add(_stateLabel);
        statusPanel.Controls.Add(_stateDetailLabel);

        var actions = new FlowLayoutPanel
        {
            Dock = DockStyle.Right,
            Width = 352,
            FlowDirection = FlowDirection.RightToLeft,
            WrapContents = false,
            BackColor = Color.Transparent,
            Padding = new Padding(0, 24, 10, 0)
        };
        ConfigureActionButton(_startButton, "ButtonStart", async (_, _) => await RunUiActionAsync(() =>
        {
            _supervisor.Start();
            return Task.CompletedTask;
        }));
        ConfigureActionButton(_stopButton, "ButtonStop", async (_, _) =>
            await RunUiActionAsync(_supervisor.StopAsync));
        ConfigureActionButton(_restartButton, "ButtonRestart", async (_, _) =>
            await RunUiActionAsync(() => _supervisor.RestartAsync("User requested restart.")));
        var refresh = NewCommandButton("ButtonRefresh", (_, _) => UpdateOverview(_supervisor.Current));
        actions.Controls.AddRange(new Control[] { refresh, _restartButton, _stopButton, _startButton });
        statusPanel.Controls.Add(actions);
        void ResizeStatusDetail()
        {
            var availableWidth = statusPanel.ClientSize.Width - actions.Width - 40;
            _stateDetailLabel.Width = Math.Max(80, availableWidth);
        }
        statusPanel.Resize += (_, _) => ResizeStatusDetail();
        ResizeStatusDetail();

        var signals = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = AppTheme.Canvas,
            ColumnCount = 2,
            RowCount = 2,
            Margin = Padding.Empty
        };
        signals.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        signals.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        signals.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
        signals.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
        signals.Controls.Add(BuildSignalCard("FieldLocalEndpoint", _localValue, AppTheme.Neon), 0, 0);
        signals.Controls.Add(BuildSignalCard("FieldCodexProvider", _providerValue, AppTheme.Cyan), 1, 0);
        signals.Controls.Add(BuildSignalCard("FieldTailnetEndpoint", _publicValue, AppTheme.Amber), 0, 1);
        signals.Controls.Add(BuildRuntimeCard(), 1, 1);

        root.Controls.Add(statusPanel, 0, 0);
        root.Controls.Add(signals, 0, 1);
        page.Controls.Add(root);
        return page;
    }

    private TabPage BuildConnectionPage()
    {
        var page = NewTabPage("TabConnection");
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = AppTheme.Canvas,
            Padding = new Padding(16),
            ColumnCount = 2,
            RowCount = 1
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 62));
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 38));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var credentials = new CyberPanel
        {
            Dock = DockStyle.Fill,
            AccentColor = AppTheme.Cyan,
            Margin = new Padding(0, 0, 6, 0)
        };
        var fields = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.Transparent,
            ColumnCount = 3,
            RowCount = 7,
            Padding = new Padding(2)
        };
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 94));
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 72));
        fields.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        fields.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        fields.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        fields.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        fields.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        fields.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        fields.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var credentialsTitle = NewSectionTitle("SectionCredentials");
        fields.Controls.Add(credentialsTitle, 0, 0);
        fields.SetColumnSpan(credentialsTitle, 3);

        ConfigureValueLabel(_publicBaseValue);
        AddFieldLabel(fields, "FieldConnectionEndpoint", 1);
        fields.Controls.Add(_publicBaseValue, 1, 1);
        fields.SetColumnSpan(_publicBaseValue, 2);

        ConfigureInput(_tokenValue);
        _tokenValue.Font = new Font("Cascadia Mono", 7.25F);
        _tokenValue.ReadOnly = true;
        _tokenValue.UseSystemPasswordChar = true;
        AddFieldLabel(fields, "FieldToken", 2);
        fields.Controls.Add(_tokenValue, 1, 2);
        fields.Controls.Add(NewCommandButton("ButtonCopy", (_, _) => CopyToken()), 2, 2);

        ConfigureInput(_connectionUrlValue);
        _connectionUrlValue.Font = new Font("Cascadia Mono", 7.25F);
        _connectionUrlValue.Multiline = false;
        _connectionUrlValue.ReadOnly = true;
        _connectionUrlValue.ScrollBars = ScrollBars.None;
        AddFieldLabel(fields, "FieldConnectionUrl", 3);
        fields.Controls.Add(_connectionUrlValue, 1, 3);
        fields.Controls.Add(NewCommandButton("ButtonCopy", (_, _) => CopyUrl()), 2, 3);

        var connectionActions = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            BackColor = Color.Transparent,
            Padding = new Padding(0, 7, 0, 0)
        };
        ConfigureCommandButton(_revealButton, "ButtonReveal");
        _revealButton.Click += (_, _) => ToggleSecrets();
        var regenerate = NewCommandButton("ButtonRegenerate", async (_, _) =>
            await RunUiActionAsync(RegenerateTokenAsync));
        connectionActions.Controls.Add(_revealButton);
        connectionActions.Controls.Add(regenerate);
        fields.Controls.Add(connectionActions, 1, 4);
        fields.SetColumnSpan(connectionActions, 2);

        _connectionActionStatus.Dock = DockStyle.Fill;
        _connectionActionStatus.ForeColor = AppTheme.Muted;
        _connectionActionStatus.Font = new Font("Cascadia Mono", 8F);
        _connectionActionStatus.TextAlign = ContentAlignment.MiddleLeft;
        fields.Controls.Add(_connectionActionStatus, 1, 5);
        fields.SetColumnSpan(_connectionActionStatus, 2);
        credentials.Controls.Add(fields);

        var pairing = new CyberPanel
        {
            Dock = DockStyle.Fill,
            AccentColor = AppTheme.Neon,
            ShowGrid = true,
            Margin = new Padding(6, 0, 0, 0)
        };
        var pairingLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.Transparent,
            ColumnCount = 1,
            RowCount = 2
        };
        pairingLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        pairingLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        pairingLayout.Controls.Add(NewSectionTitle("SectionQr"), 0, 0);
        var qrHost = new Panel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.Transparent,
            Margin = new Padding(6, 8, 6, 6)
        };
        var qrPanel = new Panel
        {
            BackColor = Color.White,
            Size = new Size(220, 220),
            Padding = new Padding(12)
        };
        qrHost.Resize += (_, _) =>
        {
            var side = Math.Min(260, Math.Min(qrHost.ClientSize.Width - 8, qrHost.ClientSize.Height - 8));
            if (side <= 0)
            {
                return;
            }

            qrPanel.Bounds = new Rectangle(
                Math.Max(0, (qrHost.ClientSize.Width - side) / 2),
                Math.Max(0, (qrHost.ClientSize.Height - side) / 2),
                side,
                side);
        };
        _qrPicture.Dock = DockStyle.Fill;
        _qrPicture.SizeMode = PictureBoxSizeMode.Zoom;
        _qrPicture.BackColor = Color.White;
        _qrHiddenLabel.Dock = DockStyle.Fill;
        _qrHiddenLabel.Tag = "loc:QrHidden";
        _qrHiddenLabel.TextAlign = ContentAlignment.MiddleCenter;
        _qrHiddenLabel.Font = new Font("Cascadia Mono", 9F, FontStyle.Bold);
        _qrHiddenLabel.ForeColor = AppTheme.Muted;
        _qrHiddenLabel.BackColor = AppTheme.Void;
        qrPanel.Controls.Add(_qrPicture);
        qrPanel.Controls.Add(_qrHiddenLabel);
        qrHost.Controls.Add(qrPanel);
        _qrPicture.Visible = false;
        _qrHiddenLabel.Visible = true;
        pairingLayout.Controls.Add(qrHost, 0, 1);
        pairing.Controls.Add(pairingLayout);

        root.Controls.Add(credentials, 0, 0);
        root.Controls.Add(pairing, 1, 0);
        page.Controls.Add(root);
        return page;
    }

    private TabPage BuildSettingsPage()
    {
        var page = NewTabPage("TabSettings");
        var outer = new Panel
        {
            Dock = DockStyle.Fill,
            AutoScroll = true,
            BackColor = AppTheme.Canvas
        };
        var grid = new TableLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Top,
            BackColor = AppTheme.Canvas,
            ColumnCount = 2,
            RowCount = 4,
            Padding = new Padding(16)
        };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));

        var languagePanel = BuildLanguagePanel();
        grid.Controls.Add(languagePanel, 0, 0);
        grid.SetColumnSpan(languagePanel, 2);

        var networkPanel = BuildSettingsSection("SectionNetwork", AppTheme.Cyan, out var network);
        AddSettingsRow(network, "FieldDisplayName", _displayNameInput);
        _publicHostInput.ReadOnly = true;
        _publicHostInput.TabStop = false;
        AddSettingsRow(network, "FieldPublicHost", _publicHostInput);
        AddSettingsRow(network, "FieldPublicPort", _publicPortInput);
        AddSettingsRow(network, "FieldBackendPort", _backendPortInput);
        AddSettingsRow(network, "FieldCodexPort", _codexPortInput);
        grid.Controls.Add(networkPanel, 0, 1);

        var policyPanel = BuildSettingsSection("SectionPolicy", AppTheme.Amber, out var policy);
        AddSettingsRow(policy, "FieldHealthInterval", _healthIntervalInput);
        AddSettingsRow(policy, "FieldProviderInterval", _providerIntervalInput);
        AddSettingsRow(policy, "FieldTailnetInterval", _publicIntervalInput);
        AddSettingsRow(policy, "FieldFailureThreshold", _failureThresholdInput);
        AddSettingsRow(policy, "FieldLogLimit", _logSizeInput);
        AddSettingsRow(policy, "FieldLogCopies", _logCopiesInput);
        ConfigureCheckBox(_diagnosticLoggingInput, "OptionDiagnosticLogging");
        ConfigureCheckBox(_autoStartServiceInput, "OptionAutoStartService");
        ConfigureCheckBox(_startOnLoginInput, "OptionStartOnLogin");
        AddSettingsControl(policy, _diagnosticLoggingInput);
        AddSettingsControl(policy, _autoStartServiceInput);
        AddSettingsControl(policy, _startOnLoginInput);
        grid.Controls.Add(policyPanel, 1, 1);

        var dependenciesPanel = BuildSettingsSection(
            "SectionDependencies",
            AppTheme.Neon,
            out var dependencies,
            includeBrowseColumn: true);
        AddPathRow(dependencies, "FieldNodePath", _nodePathInput, () => SelectExecutable(_nodePathInput, "node.exe"));
        AddPathRow(
            dependencies,
            "FieldEvenTerminalPath",
            _cliPathInput,
            () => SelectFile(_cliPathInput, "JavaScript (*.js)|*.js|All files (*.*)|*.*"));
        AddPathRow(dependencies, "FieldCodexPath", _codexPathInput, () => SelectExecutable(_codexPathInput, "codex.exe"));
        _tailscalePathInput.ReadOnly = true;
        _tailscalePathInput.TabStop = false;
        AddSettingsRow(dependencies, "FieldTailscalePath", _tailscalePathInput);
        grid.Controls.Add(dependenciesPanel, 0, 2);
        grid.SetColumnSpan(dependenciesPanel, 2);

        var actions = new FlowLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = true,
            BackColor = AppTheme.Canvas,
            Padding = new Padding(0, 10, 0, 12),
            Margin = new Padding(0, 6, 0, 0)
        };
        actions.Controls.Add(NewPrimaryButton("ButtonSaveRestart", async (_, _) => await SaveSettingsAsync()));
        actions.Controls.Add(NewCommandButton("ButtonApplyNetwork", async (_, _) => await ApplySystemConfigurationAsync()));
        _settingsStatus.AutoSize = true;
        _settingsStatus.ForeColor = AppTheme.Muted;
        _settingsStatus.Font = new Font("Cascadia Mono", 8F);
        _settingsStatus.Margin = new Padding(8, 8, 0, 0);
        actions.Controls.Add(_settingsStatus);
        grid.Controls.Add(actions, 0, 3);
        grid.SetColumnSpan(actions, 2);

        outer.Controls.Add(grid);
        page.Controls.Add(outer);
        return page;
    }

    private TabPage BuildLogsPage()
    {
        var page = NewTabPage("TabLogs");
        var shell = new CyberPanel
        {
            Dock = DockStyle.Fill,
            AccentColor = AppTheme.Neon,
            Margin = new Padding(16),
            Padding = new Padding(14)
        };
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.Transparent,
            ColumnCount = 1,
            RowCount = 2
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var actions = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            BackColor = Color.Transparent
        };
        var title = NewSectionTitle("SectionTerminal");
        title.Width = 230;
        actions.Controls.Add(title);
        actions.Controls.Add(NewCommandButton("ButtonRefresh", (_, _) => RefreshLogs()));
        actions.Controls.Add(NewCommandButton("ButtonOpenFolder", (_, _) => OpenLogFolder()));
        actions.Controls.Add(NewCommandButton("ButtonClear", (_, _) => ClearLogs()));

        _logText.Dock = DockStyle.Fill;
        _logText.ReadOnly = true;
        _logText.WordWrap = false;
        _logText.BackColor = AppTheme.Void;
        _logText.ForeColor = AppTheme.Neon;
        _logText.Font = new Font("Cascadia Mono", 9F);
        _logText.BorderStyle = BorderStyle.None;
        _logText.DetectUrls = false;

        root.Controls.Add(actions, 0, 0);
        root.Controls.Add(_logText, 0, 1);
        shell.Controls.Add(root);
        page.Controls.Add(shell);
        return page;
    }

    private TabPage BuildAboutPage()
    {
        var page = NewTabPage("TabAbout");
        var shell = new CyberPanel
        {
            Dock = DockStyle.Fill,
            AccentColor = AppTheme.Cyan,
            ShowGrid = true,
            Margin = new Padding(16),
            Padding = new Padding(22)
        };
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.Transparent,
            ColumnCount = 2,
            RowCount = 1
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 190));
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var logo = new PictureBox
        {
            Image = _brandLogo,
            Dock = DockStyle.Top,
            Height = 150,
            SizeMode = PictureBoxSizeMode.Zoom,
            Margin = new Padding(10, 22, 28, 0)
        };
        var details = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.Transparent,
            ColumnCount = 1,
            RowCount = 9,
            Padding = new Padding(12, 24, 0, 0)
        };
        details.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
        details.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        details.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        details.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        details.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
        details.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        details.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        details.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        details.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var productName = new Label
        {
            AutoSize = true,
            Text = ApplicationMetadata.ProductName,
            Font = new Font("Cascadia Mono", 17F, FontStyle.Bold),
            ForeColor = AppTheme.Neon,
            Margin = new Padding(0)
        };
        var version = new Label
        {
            AutoSize = true,
            Tag = "locfmt:AboutVersion|version",
            ForeColor = AppTheme.Muted,
            Font = new Font("Cascadia Mono", 9F),
            Margin = new Padding(0)
        };
        var copyright = new Label
        {
            AutoSize = true,
            Text = ApplicationMetadata.Copyright,
            ForeColor = AppTheme.Text,
            Margin = new Padding(0)
        };
        var license = new Label
        {
            AutoSize = true,
            Text = ApplicationMetadata.LicenseName,
            ForeColor = AppTheme.Cyan,
            Font = new Font("Cascadia Mono", 9F, FontStyle.Bold),
            Margin = new Padding(0)
        };
        var licenseNotice = new Label
        {
            AutoSize = false,
            Dock = DockStyle.Fill,
            Tag = "loc:AboutLicenseNotice",
            ForeColor = AppTheme.Muted,
            Margin = new Padding(0)
        };
        var licenseLink = NewExternalLink("AboutLicenseLink", ApplicationMetadata.LicenseUrl);
        var profileLink = NewExternalLink(
            "github.com/DaichiMatsumoto",
            ApplicationMetadata.GitHubProfileUrl,
            localize: false);
        var repositoryLink = NewExternalLink(
            "AboutSourceLink",
            ApplicationMetadata.RepositoryUrl);
        var communityNotice = new Label
        {
            AutoSize = false,
            Dock = DockStyle.Fill,
            Text = ApplicationMetadata.LegalNotice,
            ForeColor = AppTheme.Muted,
            Margin = new Padding(0),
            TextAlign = ContentAlignment.TopLeft
        };

        details.Controls.Add(productName, 0, 0);
        details.Controls.Add(version, 0, 1);
        details.Controls.Add(copyright, 0, 2);
        details.Controls.Add(license, 0, 3);
        details.Controls.Add(licenseNotice, 0, 4);
        details.Controls.Add(licenseLink, 0, 5);
        details.Controls.Add(profileLink, 0, 6);
        details.Controls.Add(repositoryLink, 0, 7);
        details.Controls.Add(communityNotice, 0, 8);
        root.Controls.Add(logo, 0, 0);
        root.Controls.Add(details, 1, 0);
        shell.Controls.Add(root);
        page.Controls.Add(shell);
        return page;
    }

    private void LoadSettings()
    {
        var settings = _settingsStore.Current;
        PopulateLanguageOptions(settings.UiLanguage);
        _displayNameInput.Text = settings.DisplayName;
        _publicPortInput.Value = settings.PublicPort;
        _backendPortInput.Value = settings.BackendPort;
        _codexPortInput.Value = settings.CodexAppServerPort;
        _nodePathInput.Text = settings.NodePath;
        _cliPathInput.Text = settings.EvenTerminalCliPath;
        _codexPathInput.Text = settings.CodexPath;
        _tailscalePathInput.Text = settings.TailscalePath;
        _healthIntervalInput.Value = settings.HealthIntervalSeconds;
        _providerIntervalInput.Value = settings.ProviderCheckIntervalSeconds;
        _publicIntervalInput.Value = settings.PublicCheckIntervalSeconds;
        _failureThresholdInput.Value = settings.FailureThreshold;
        _logSizeInput.Value = settings.LogFileSizeMb;
        _logCopiesInput.Value = settings.LogFileCopies;
        _diagnosticLoggingInput.Checked = settings.DiagnosticLogging;
        _autoStartServiceInput.Checked = settings.AutoStartService;
        _startOnLoginInput.Checked = _startupRegistration.IsRegistered;
        RefreshTrustedTailnetEndpoint(settings);
    }

    private async Task SaveSettingsAsync()
    {
        if (!_systemConfigurationGate.Wait(0))
        {
            SetSettingsStatus("SettingsBusy");
            return;
        }

        try
        {
            await SaveSettingsCoreAsync();
        }
        finally
        {
            _systemConfigurationGate.Release();
        }
    }

    private async Task SaveSettingsCoreAsync()
    {
        var current = _settingsStore.Current;
        var updated = current with
        {
            UiLanguage = GetSelectedLanguage(),
            DisplayName = _displayNameInput.Text.Trim(),
            PublicPort = decimal.ToInt32(_publicPortInput.Value),
            BackendPort = decimal.ToInt32(_backendPortInput.Value),
            CodexAppServerPort = decimal.ToInt32(_codexPortInput.Value),
            NodePath = _nodePathInput.Text.Trim(),
            EvenTerminalCliPath = _cliPathInput.Text.Trim(),
            CodexPath = _codexPathInput.Text.Trim(),
            TailscalePath = AppSettings.FixedTailscalePath,
            HealthIntervalSeconds = decimal.ToInt32(_healthIntervalInput.Value),
            ProviderCheckIntervalSeconds = decimal.ToInt32(_providerIntervalInput.Value),
            PublicCheckIntervalSeconds = decimal.ToInt32(_publicIntervalInput.Value),
            FailureThreshold = decimal.ToInt32(_failureThresholdInput.Value),
            LogFileSizeMb = decimal.ToInt32(_logSizeInput.Value),
            LogFileCopies = decimal.ToInt32(_logCopiesInput.Value),
            DiagnosticLogging = _diagnosticLoggingInput.Checked,
            AutoStartService = _autoStartServiceInput.Checked
        };

        var errors = AppSettingsValidator.Validate(updated);
        if (errors.Count > 0)
        {
            MessageBox.Show(
                this,
                string.Join(Environment.NewLine, errors),
                AppLocalizer.Text("SettingsSaveFailedTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }

        try
        {
            var requiresSystemUpdate = !HasSameSystemConfiguration(updated, current);
            var previousSystemSettings = current;
            var previousSystemSettingsOwned = false;
            AppSettings? lastAppliedSystemSettings = null;
            if (requiresSystemUpdate)
            {
                try
                {
                    lastAppliedSystemSettings = _settingsStore.GetLastAppliedSystemSettings();
                    previousSystemSettings = lastAppliedSystemSettings ?? current;
                    previousSystemSettingsOwned = lastAppliedSystemSettings is not null;
                }
                catch (Exception exception)
                {
                    SetSettingsStatus("AppliedSettingsUnreadable");
                    _logger.Error($"Applied system configuration read failed: {exception.Message}");
                    MessageBox.Show(
                        this,
                        exception.Message,
                        AppLocalizer.Text("SettingsSaveFailedTitle"),
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                    return;
                }
            }
            var wasRunning = _supervisor.IsRunning;
            var supervisorWasStopped = false;
            var systemConfigurationWasRequired = _settingsStore.RequiresSystemConfiguration;
            var installerCompletionRequired = systemConfigurationWasRequired &&
                lastAppliedSystemSettings is null;
            var deferSystemUpdateToInstaller = requiresSystemUpdate && installerCompletionRequired;
            if (requiresSystemUpdate)
            {
                _settingsStore.MarkSystemConfigurationRequired();
            }
            if (requiresSystemUpdate &&
                systemConfigurationWasRequired &&
                lastAppliedSystemSettings is not null)
            {
                if (wasRunning)
                {
                    SetSettingsStatus("StoppingBackend");
                    await _supervisor.StopAsync();
                    supervisorWasStopped = true;
                }

                SetSettingsStatus("ReconcilingSystemConfiguration");
                await SystemConfigurationService.ApplyElevatedAsync(
                    current,
                    lastAppliedSystemSettings,
                    previousMappingOwned: true,
                    existingTargetMappingOwned:
                        lastAppliedSystemSettings.PublicPort == current.PublicPort);
                _settingsStore.MarkSystemConfigurationApplied(current);
                systemConfigurationWasRequired = false;
                previousSystemSettings = current;
                previousSystemSettingsOwned = true;
            }

            if (requiresSystemUpdate && wasRunning && !supervisorWasStopped)
            {
                SetSettingsStatus("StoppingBackend");
                await _supervisor.StopAsync();
            }

            if (requiresSystemUpdate)
            {
                _settingsStore.MarkSystemConfigurationRequired();
            }
            _settingsStore.Save(updated);
            AppLocalizer.SetLanguage(updated.UiLanguage);
            if (requiresSystemUpdate && !deferSystemUpdateToInstaller)
            {
                var systemConfigurationApplied = false;
                try
                {
                    SetSettingsStatus("AwaitingUac");
                    await SystemConfigurationService.ApplyElevatedAsync(
                        updated,
                        previousSystemSettings,
                        previousMappingOwned: previousSystemSettingsOwned,
                        existingTargetMappingOwned:
                            previousSystemSettingsOwned &&
                            previousSystemSettings.PublicPort == updated.PublicPort);
                    systemConfigurationApplied = true;
                    _settingsStore.MarkSystemConfigurationApplied(updated);
                }
                catch (Exception systemException)
                {
                    if (systemConfigurationApplied)
                    {
                        throw new InvalidOperationException(
                            AppLocalizer.Text("SystemAppliedStateFailed"),
                            systemException);
                    }

                    _settingsStore.Save(current);
                    AppLocalizer.SetLanguage(current.UiLanguage);
                    if (!systemConfigurationWasRequired &&
                        systemException is not SystemConfigurationRollbackException &&
                        HasSameSystemConfiguration(current, previousSystemSettings))
                    {
                        _settingsStore.MarkSystemConfigurationApplied(previousSystemSettings);
                    }
                    LoadSettings();
                    if (wasRunning && !_settingsStore.RequiresSystemConfiguration)
                    {
                        _supervisor.Start();
                    }
                    throw;
                }
            }

            if (wasRunning && requiresSystemUpdate)
            {
                if (!_settingsStore.RequiresSystemConfiguration)
                {
                    _supervisor.Start();
                }
            }
            else if (wasRunning)
            {
                await _supervisor.RestartAsync("Settings changed.");
            }

            if (_startOnLoginInput.Checked)
            {
                _startupRegistration.Register();
            }
            else
            {
                _startupRegistration.Unregister();
            }

            _logger.Info("Settings updated.");
            RefreshConnectionView();
            UpdateHeaderNode(updated.DisplayName);
            if (installerCompletionRequired)
            {
                SetSettingsStatus("SettingsSavedInstaller");
            }
            else
            {
                var savedAt = DateTime.Now;
                SetSettingsStatus(() => AppLocalizer.Format(
                    "SettingsSavedAt",
                    savedAt.ToString("T", AppLocalizer.Culture)));
            }
        }
        catch (Exception exception)
        {
            AppLocalizer.SetLanguage(_settingsStore.Current.UiLanguage);
            PopulateLanguageOptions(_settingsStore.Current.UiLanguage);
            _startOnLoginInput.Checked = _startupRegistration.IsRegistered;
            _logger.Error($"Settings update failed: {exception.Message}");
            MessageBox.Show(
                this,
                exception.Message,
                AppLocalizer.Text("SettingsSaveFailedTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private async Task ApplySystemConfigurationAsync()
    {
        if (!_systemConfigurationGate.Wait(0))
        {
            SetSettingsStatus("SettingsBusy");
            return;
        }

        try
        {
            await ApplySystemConfigurationCoreAsync();
        }
        finally
        {
            _systemConfigurationGate.Release();
        }
    }

    private async Task ApplySystemConfigurationCoreAsync()
    {
        var settings = _settingsStore.Current;
        var previousSystemSettings = settings;
        var previousSystemSettingsOwned = false;
        var wasRunning = _supervisor.IsRunning;
        var systemConfigurationWasRequired = _settingsStore.RequiresSystemConfiguration;
        var markedForAttempt = false;
        try
        {
            var lastAppliedSystemSettings = _settingsStore.GetLastAppliedSystemSettings();
            previousSystemSettings = lastAppliedSystemSettings ?? settings;
            previousSystemSettingsOwned = lastAppliedSystemSettings is not null;
            _settingsStore.MarkSystemConfigurationRequired();
            markedForAttempt = true;
            if (wasRunning)
            {
                SetSettingsStatus("StoppingBackend");
                await _supervisor.StopAsync();
            }

            SetSettingsStatus("AwaitingUac");
            await SystemConfigurationService.ApplyElevatedAsync(
                settings,
                previousSystemSettings,
                previousMappingOwned: previousSystemSettingsOwned,
                existingTargetMappingOwned:
                    previousSystemSettingsOwned &&
                    previousSystemSettings.PublicPort == settings.PublicPort);
            _settingsStore.MarkSystemConfigurationApplied(settings);
            if (wasRunning)
            {
                _supervisor.Start();
            }
            var appliedAt = DateTime.Now;
            SetSettingsStatus(() => AppLocalizer.Format(
                "SystemAppliedAt",
                appliedAt.ToString("T", AppLocalizer.Culture)));
            _logger.Info("Tailscale Serve and firewall configuration applied.");
        }
        catch (Exception exception)
        {
            try
            {
                if (markedForAttempt &&
                    !systemConfigurationWasRequired &&
                    exception is not SystemConfigurationRollbackException &&
                    HasSameSystemConfiguration(settings, previousSystemSettings))
                {
                    _settingsStore.MarkSystemConfigurationApplied(previousSystemSettings);
                }
                if (wasRunning && !_settingsStore.RequiresSystemConfiguration)
                {
                    _supervisor.Start();
                }
            }
            catch (Exception recoveryException)
            {
                exception = new AggregateException(exception, recoveryException);
            }

            if (exception is OperationCanceledException)
            {
                SetSettingsStatus("SystemNotChanged");
                return;
            }

            SetSettingsStatus("SystemFailed");
            _logger.Error($"System configuration failed: {exception.Message}");
            MessageBox.Show(
                this,
                exception.Message,
                AppLocalizer.Text("SystemFailedTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private static bool HasSameSystemConfiguration(AppSettings left, AppSettings right) =>
        left.PublicPort == right.PublicPort &&
        left.BackendPort == right.BackendPort &&
        string.Equals(left.TailscalePath, right.TailscalePath, StringComparison.OrdinalIgnoreCase);

    private async Task RegenerateTokenAsync()
    {
        var answer = MessageBox.Show(
            this,
            AppLocalizer.Text("TokenRegeneratePrompt"),
            AppLocalizer.Text("TokenRegenerateTitle"),
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2);
        if (answer != DialogResult.Yes)
        {
            return;
        }

        var wasRunning = _supervisor.IsRunning;
        _tokenStore.Regenerate();
        _logger.Info("Connection token regenerated.");
        RefreshConnectionView();
        HideSecrets();
        SetConnectionStatus("TokenRegenerated");
        if (wasRunning)
        {
            await _supervisor.RestartAsync("Connection token regenerated.");
        }
    }

    private void RefreshConnectionView()
    {
        var settings = _settingsStore.Current;
        var token = _tokenStore.GetOrCreate();
        var endpoint = RefreshTrustedTailnetEndpoint(settings);
        _publicBaseValue.Text = endpoint is null
            ? AppLocalizer.Text("TailnetIdentityUnavailable")
            : ConnectionUrlBuilder.BuildBaseUrl(endpoint.DnsName, endpoint.PublicPort);
        _tokenValue.Text = token;
        _connectionUrlValue.Text = _secretsVisible && endpoint is not null
            ? BuildConnectionUrl(endpoint, token)
            : AppLocalizer.Text("SecretHidden");
        _tokenValue.UseSystemPasswordChar = !_secretsVisible;
        if (_secretsVisible && endpoint is not null)
        {
            RenderQrCode(endpoint);
        }
        else if (_secretsVisible)
        {
            HideSecrets();
        }
    }

    private void ToggleSecrets()
    {
        if (_secretsVisible)
        {
            HideSecrets();
            return;
        }

        var endpoint = RefreshTrustedTailnetEndpoint(_settingsStore.Current);
        if (endpoint is null)
        {
            HideSecrets();
            SetConnectionStatus("TailnetIdentityUnavailable");
            MessageBox.Show(
                this,
                AppLocalizer.Text("TailnetIdentityUnavailableMessage"),
                AppLocalizer.Text("TailnetIdentityUnavailableTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }

        _secretsVisible = true;
        _tokenValue.UseSystemPasswordChar = false;
        _connectionUrlValue.Text = BuildConnectionUrl(endpoint, _tokenStore.GetOrCreate());
        _revealButton.Text = AppLocalizer.Text("ButtonConceal");
        RenderQrCode(endpoint);
        _qrPicture.Visible = true;
        _qrHiddenLabel.Visible = false;
        _secretTimer.Stop();
        _secretTimer.Interval = SecretRevealSeconds * 1000;
        _secretTimer.Start();
    }

    private void HideSecrets()
    {
        _secretTimer.Stop();
        _secretsVisible = false;
        _tokenValue.UseSystemPasswordChar = true;
        _connectionUrlValue.Text = AppLocalizer.Text("SecretHidden");
        _revealButton.Text = AppLocalizer.Text("ButtonReveal");
        _qrPicture.Visible = false;
        _qrHiddenLabel.Visible = true;
        _qrPicture.Image?.Dispose();
        _qrPicture.Image = null;
    }

    private void RenderQrCode(TrustedTailnetEndpoint endpoint)
    {
        var url = BuildConnectionUrl(endpoint, _tokenStore.GetOrCreate());
        var image = QrCodeRenderer.Render(url);
        var oldImage = _qrPicture.Image;
        _qrPicture.Image = image;
        oldImage?.Dispose();
    }

    private void CopyToken() => CopySensitive(_tokenStore.GetOrCreate(), "TokenCopied");

    private void CopyUrl()
    {
        var endpoint = RefreshTrustedTailnetEndpoint(_settingsStore.Current);
        if (endpoint is null)
        {
            SetConnectionStatus("TailnetIdentityUnavailable");
            MessageBox.Show(
                this,
                AppLocalizer.Text("TailnetIdentityUnavailableMessage"),
                AppLocalizer.Text("TailnetIdentityUnavailableTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }

        CopySensitive(
            BuildConnectionUrl(endpoint, _tokenStore.GetOrCreate()),
            "UrlCopied");
    }

    private TrustedTailnetEndpoint? RefreshTrustedTailnetEndpoint(AppSettings settings)
    {
        if (_tailscaleIdentityStore.TryLoad(settings, out var endpoint))
        {
            _publicHostInput.Text = endpoint.DnsName;
            return endpoint;
        }

        _publicHostInput.Text = AppLocalizer.Text("TailnetIdentityUnavailable");
        return null;
    }

    private static string BuildConnectionUrl(
        TrustedTailnetEndpoint endpoint,
        string token) =>
        ConnectionUrlBuilder.BuildConnectionUrl(
            endpoint.DnsName,
            endpoint.PublicPort,
            token);

    private void CopySensitive(string value, string messageKey)
    {
        try
        {
            var seconds = _settingsStore.Current.ClipboardClearSeconds;
            _clipboard.Set(value, seconds);
            SetConnectionStatus(() => AppLocalizer.Format(
                "ClipboardClears",
                AppLocalizer.Text(messageKey),
                seconds));
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                this,
                exception.Message,
                AppLocalizer.Text("CopyFailedTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
    }

    private void UpdateOverview(SupervisorSnapshot snapshot)
    {
        var (text, color) = snapshot.State switch
        {
            SupervisorState.Online => (AppLocalizer.Text("StateOnline"), AppTheme.Online),
            SupervisorState.Degraded => (AppLocalizer.Text("StateDegraded"), AppTheme.Degraded),
            SupervisorState.Starting => (AppLocalizer.Text("StateStarting"), AppTheme.Starting),
            SupervisorState.Restarting => (AppLocalizer.Text("StateRestarting"), AppTheme.Starting),
            SupervisorState.Faulted => (AppLocalizer.Text("StateFaulted"), AppTheme.Faulted),
            SupervisorState.Stopping => (AppLocalizer.Text("StateStopping"), AppTheme.Stopped),
            _ => (AppLocalizer.Text("StateStopped"), AppTheme.Stopped)
        };
        _stateLabel.Text = text;
        _stateLabel.ForeColor = color;
        _stateDetailLabel.Text = snapshot.LastError ?? AppLocalizer.Format(
            "StateDuration",
            FormatDuration(DateTimeOffset.Now - snapshot.StateSince));
        _pidValue.Text = snapshot.BackendProcessId?.ToString() ?? "-";
        SetEndpointValue(_localValue, snapshot.LocalEndpointReady);
        SetEndpointValue(_providerValue, snapshot.ProviderReady);
        SetEndpointValue(_publicValue, snapshot.PublicEndpointReady);
        _updatedValue.Text = snapshot.UpdatedAt.LocalDateTime.ToString(
            "yyyy-MM-dd HH:mm:ss",
            AppLocalizer.Culture);
        _startButton.Enabled = !_supervisor.IsRunning;
        _stopButton.Enabled = _supervisor.IsRunning;
        _restartButton.Enabled = _supervisor.IsRunning;
    }

    private void OnSnapshotChanged(SupervisorSnapshot snapshot)
    {
        if (IsDisposed || Disposing)
        {
            return;
        }

        try
        {
            if (InvokeRequired)
            {
                BeginInvoke(() => UpdateOverview(snapshot));
            }
            else
            {
                UpdateOverview(snapshot);
            }
        }
        catch (InvalidOperationException) when (IsDisposed || Disposing)
        {
            // Shutdown raced with a final supervisor state notification.
        }
    }

    private void OnStartupRegistrationChanged(bool isRegistered)
    {
        if (IsDisposed || Disposing)
        {
            return;
        }

        try
        {
            if (InvokeRequired)
            {
                BeginInvoke(() => OnStartupRegistrationChanged(isRegistered));
                return;
            }

            _startOnLoginInput.Checked = isRegistered;
        }
        catch (InvalidOperationException) when (IsDisposed || Disposing)
        {
            // Shutdown raced with a startup-registration notification.
        }
    }

    private void RefreshLogs()
    {
        try
        {
            if (File.Exists(_paths.LogPath))
            {
                _logStatusFactory = null;
                _logText.Text = string.Join(
                    Environment.NewLine,
                    File.ReadLines(_paths.LogPath).TakeLast(300));
            }
            else
            {
                SetLogStatus("LogsEmpty");
            }
            _logText.SelectionStart = _logText.TextLength;
            _logText.ScrollToCaret();
        }
        catch (IOException exception)
        {
            SetLogStatus(() => AppLocalizer.Format("LogsReadFailed", exception.Message));
        }
    }

    private void OpenLogFolder()
    {
        Directory.CreateDirectory(_paths.LogRoot);
        Process.Start(new ProcessStartInfo("explorer.exe", _paths.LogRoot) { UseShellExecute = true });
    }

    private void ClearLogs()
    {
        if (MessageBox.Show(
                this,
                AppLocalizer.Text("LogsClearPrompt"),
                AppLocalizer.Text("LogsClearTitle"),
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question) != DialogResult.Yes)
        {
            return;
        }

        try
        {
            _logger.Clear();
            _logger.Info("Log cleared by user.");
            RefreshLogs();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(
                this,
                exception.Message,
                AppLocalizer.Text("LogsClearFailedTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private void OnFormClosing(object? sender, FormClosingEventArgs args)
    {
        if (_allowClose || args.CloseReason == CloseReason.WindowsShutDown)
        {
            return;
        }

        args.Cancel = true;
        HideSecrets();
        ShowInTaskbar = false;
        Hide();
    }

    private async Task RunUiActionAsync(Func<Task> action)
    {
        try
        {
            UseWaitCursor = true;
            await action();
        }
        catch (Exception exception)
        {
            _logger.Error($"UI action failed: {exception.Message}");
            MessageBox.Show(
                this,
                exception.Message,
                AppLocalizer.Text("ActionFailedTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        finally
        {
            UseWaitCursor = false;
        }
    }

    private static TabPage NewTabPage(string resourceKey) => new(AppLocalizer.Text(resourceKey))
    {
        Tag = $"loc:{resourceKey}",
        BackColor = AppTheme.Canvas,
        ForeColor = AppTheme.Text,
        Padding = Padding.Empty
    };

    private LinkLabel NewExternalLink(string text, string url, bool localize = true)
    {
        var link = new LinkLabel
        {
            AutoSize = true,
            Text = localize ? AppLocalizer.Text(text) : text,
            Tag = localize ? $"loc:{text}" : null,
            LinkColor = AppTheme.Cyan,
            ActiveLinkColor = AppTheme.Neon,
            VisitedLinkColor = AppTheme.Cyan,
            Font = new Font("Cascadia Mono", 8.5F, FontStyle.Bold),
            Margin = Padding.Empty
        };
        link.LinkClicked += (_, _) =>
        {
            try
            {
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            }
            catch (Exception exception) when (
                exception is InvalidOperationException or System.ComponentModel.Win32Exception)
            {
                _logger.Error($"Could not open external link: {exception.Message}");
                MessageBox.Show(
                    this,
                    AppLocalizer.Text("ExternalLinkFailed"),
                    ApplicationMetadata.ProductName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        };
        return link;
    }

    private static Button NewCommandButton(string resourceKey, EventHandler clickHandler)
    {
        var button = new Button();
        ConfigureCommandButton(button, resourceKey);
        button.Click += clickHandler;
        return button;
    }

    private static Button NewPrimaryButton(string resourceKey, EventHandler clickHandler)
    {
        var button = NewCommandButton(resourceKey, clickHandler);
        button.BackColor = AppTheme.Neon;
        button.ForeColor = AppTheme.Void;
        button.FlatAppearance.BorderColor = AppTheme.Neon;
        return button;
    }

    private static void ConfigureCommandButton(Button button, string resourceKey)
    {
        button.Text = AppLocalizer.Text(resourceKey);
        button.Tag = $"loc:{resourceKey}";
        button.AutoSize = true;
        button.MinimumSize = new Size(72, 32);
        button.Height = 32;
        button.Padding = new Padding(10, 2, 10, 2);
        button.BackColor = AppTheme.SurfaceElevated;
        button.ForeColor = AppTheme.Text;
        button.Font = new Font("Cascadia Mono", 8F, FontStyle.Bold);
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderColor = AppTheme.Line;
        button.FlatAppearance.MouseOverBackColor = Color.FromArgb(53, 94, 88);
        button.FlatAppearance.MouseDownBackColor = Color.FromArgb(62, 112, 104);
        button.Margin = new Padding(0, 0, 8, 0);
        button.UseVisualStyleBackColor = false;
    }

    private static void ConfigureActionButton(
        Button button,
        string resourceKey,
        EventHandler clickHandler)
    {
        ConfigureCommandButton(button, resourceKey);
        button.ForeColor = AppTheme.Neon;
        button.FlatAppearance.BorderColor = AppTheme.Neon;
        button.Click += clickHandler;
    }

    private static CyberPanel BuildSignalCard(
        string resourceKey,
        Label value,
        Color accent)
    {
        var card = new CyberPanel
        {
            Dock = DockStyle.Fill,
            AccentColor = accent,
            Margin = new Padding(4)
        };
        var title = new Label
        {
            Tag = $"loc:{resourceKey}",
            Text = AppLocalizer.Text(resourceKey),
            Dock = DockStyle.Top,
            Height = 26,
            ForeColor = AppTheme.Muted,
            Font = new Font("Cascadia Mono", 8F, FontStyle.Bold)
        };
        value.Dock = DockStyle.Fill;
        value.TextAlign = ContentAlignment.MiddleLeft;
        value.Font = new Font("Cascadia Mono", 18F, FontStyle.Bold);
        value.ForeColor = accent;
        value.Padding = new Padding(0, 2, 0, 0);
        card.Controls.Add(value);
        card.Controls.Add(title);
        return card;
    }

    private CyberPanel BuildRuntimeCard()
    {
        var card = new CyberPanel
        {
            Dock = DockStyle.Fill,
            AccentColor = AppTheme.Cyan,
            Margin = new Padding(4)
        };
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.Transparent,
            ColumnCount = 2,
            RowCount = 2
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 42));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 58));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
        AddRuntimeValue(layout, 0, "FieldBackendPid", _pidValue);
        AddRuntimeValue(layout, 1, "FieldLastUpdated", _updatedValue);
        card.Controls.Add(layout);
        return card;
    }

    private static void AddRuntimeValue(
        TableLayoutPanel table,
        int row,
        string resourceKey,
        Label value)
    {
        var label = new Label
        {
            Tag = $"loc:{resourceKey}",
            Text = AppLocalizer.Text(resourceKey),
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = AppTheme.Muted,
            Font = new Font("Cascadia Mono", 7.5F, FontStyle.Bold)
        };
        value.Dock = DockStyle.Fill;
        value.TextAlign = ContentAlignment.MiddleLeft;
        value.ForeColor = AppTheme.Text;
        value.Font = new Font("Cascadia Mono", row == 0 ? 13F : 8F, FontStyle.Bold);
        value.AutoEllipsis = true;
        table.Controls.Add(label, 0, row);
        table.Controls.Add(value, 1, row);
    }

    private CyberPanel BuildLanguagePanel()
    {
        var panel = new CyberPanel
        {
            Dock = DockStyle.Fill,
            Height = 68,
            AccentColor = AppTheme.Cyan,
            Margin = new Padding(0, 0, 0, 10),
            Padding = new Padding(14, 10, 14, 10)
        };
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.Transparent,
            ColumnCount = 2,
            RowCount = 1
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 190));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.Controls.Add(NewSectionTitle("FieldLanguage"), 0, 0);
        _languageInput.DropDownStyle = ComboBoxStyle.DropDownList;
        _languageInput.Dock = DockStyle.Fill;
        _languageInput.Margin = new Padding(0, 5, 0, 5);
        ConfigureInput(_languageInput);
        _languageInput.SelectedIndexChanged += OnLanguageSelectionChanged;
        layout.Controls.Add(_languageInput, 1, 0);
        panel.Controls.Add(layout);
        return panel;
    }

    private static CyberPanel BuildSettingsSection(
        string resourceKey,
        Color accent,
        out TableLayoutPanel fields,
        bool includeBrowseColumn = false)
    {
        var panel = new CyberPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Fill,
            AccentColor = accent,
            Margin = new Padding(0, 0, includeBrowseColumn ? 0 : 6, 10),
            Padding = new Padding(14, 10, 14, 12)
        };
        var shell = new TableLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Top,
            BackColor = Color.Transparent,
            ColumnCount = 1,
            RowCount = 2
        };
        shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        shell.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        shell.Controls.Add(NewSectionTitle(resourceKey), 0, 0);
        fields = new TableLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Top,
            BackColor = Color.Transparent,
            ColumnCount = includeBrowseColumn ? 3 : 2,
            RowCount = 0
        };
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, includeBrowseColumn ? 164 : 148));
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        if (includeBrowseColumn)
        {
            fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 84));
        }

        shell.Controls.Add(fields, 0, 1);
        panel.Controls.Add(shell);
        return panel;
    }

    private static Label NewSectionTitle(string resourceKey) => new()
    {
        Tag = $"loc:{resourceKey}",
        Text = AppLocalizer.Text(resourceKey),
        Dock = DockStyle.Fill,
        TextAlign = ContentAlignment.MiddleLeft,
        ForeColor = AppTheme.Neon,
        Font = new Font("Cascadia Mono", 9F, FontStyle.Bold),
        AutoEllipsis = true,
        Margin = Padding.Empty
    };

    private static void ConfigureValueLabel(Label label)
    {
        label.Dock = DockStyle.Fill;
        label.TextAlign = ContentAlignment.MiddleLeft;
        label.AutoEllipsis = true;
        label.ForeColor = AppTheme.Text;
        label.Font = new Font("Cascadia Mono", 8.5F);
    }

    private static void SetEndpointValue(Label label, bool ready)
    {
        label.Text = AppLocalizer.Text(ready ? "StatusReady" : "StatusDown");
        label.ForeColor = ready ? AppTheme.Online : AppTheme.Faulted;
    }

    private static string FormatDuration(TimeSpan duration)
    {
        if (duration.TotalHours >= 1)
        {
            return AppLocalizer.Format("DurationHours", (int)duration.TotalHours, duration.Minutes);
        }

        return duration.TotalMinutes >= 1
            ? AppLocalizer.Format("DurationMinutes", (int)duration.TotalMinutes)
            : AppLocalizer.Format("DurationSeconds", Math.Max(0, duration.Seconds));
    }

    private static void AddFieldLabel(TableLayoutPanel table, string resourceKey, int row)
    {
        table.Controls.Add(new Label
        {
            Tag = $"loc:{resourceKey}",
            Text = AppLocalizer.Text(resourceKey),
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = AppTheme.Muted,
            Font = new Font("Cascadia Mono", 7.5F, FontStyle.Bold),
            AutoEllipsis = true
        }, 0, row);
    }

    private static void AddSettingsRow(
        TableLayoutPanel table,
        string resourceKey,
        Control control)
    {
        var row = table.RowCount++;
        table.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        AddFieldLabel(table, resourceKey, row);
        ConfigureInput(control);
        control.Margin = new Padding(0, 3, 0, 3);
        table.Controls.Add(control, 1, row);
    }

    private static void AddSettingsControl(TableLayoutPanel table, Control control)
    {
        var row = table.RowCount++;
        table.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
        control.Dock = DockStyle.Fill;
        table.Controls.Add(control, 0, row);
        table.SetColumnSpan(control, table.ColumnCount);
    }

    private static void AddPathRow(
        TableLayoutPanel table,
        string resourceKey,
        TextBox input,
        Action browseAction)
    {
        var row = table.RowCount++;
        table.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        AddFieldLabel(table, resourceKey, row);
        ConfigureInput(input);
        input.Margin = new Padding(0, 3, 8, 3);
        var browse = NewCommandButton("ButtonBrowse", (_, _) => browseAction());
        browse.Dock = DockStyle.Fill;
        browse.Margin = new Padding(0, 3, 0, 3);
        table.Controls.Add(input, 1, row);
        table.Controls.Add(browse, 2, row);
    }

    private static void ConfigureInput(Control control)
    {
        control.Dock = DockStyle.Fill;
        control.BackColor = AppTheme.Void;
        control.ForeColor = AppTheme.Text;
        control.Font = new Font("Cascadia Mono", 8.5F);
        if (control is TextBox textBox)
        {
            textBox.BorderStyle = BorderStyle.FixedSingle;
        }
    }

    private static void ConfigureCheckBox(CheckBox checkBox, string resourceKey)
    {
        checkBox.Tag = $"loc:{resourceKey}";
        checkBox.Text = AppLocalizer.Text(resourceKey);
        checkBox.AutoSize = true;
        checkBox.ForeColor = AppTheme.Text;
        checkBox.Font = new Font("Segoe UI Variable Text", 8.5F);
        checkBox.Margin = new Padding(0, 4, 0, 2);
    }

    private void OnLanguageSelectionChanged(object? sender, EventArgs args)
    {
        if (_applyingLanguage || _languageInput.SelectedItem is not LanguageChoice choice)
        {
            return;
        }

        AppLocalizer.SetLanguage(choice.Code);
    }

    private void OnLanguageChanged(object? sender, EventArgs args)
    {
        if (IsDisposed || Disposing)
        {
            return;
        }

        if (InvokeRequired)
        {
            BeginInvoke(() => OnLanguageChanged(sender, args));
            return;
        }

        ApplyLocalization();
    }

    private void SetSettingsStatus(string resourceKey) =>
        SetSettingsStatus(() => AppLocalizer.Text(resourceKey));

    private void SetSettingsStatus(Func<string> textFactory)
    {
        _settingsStatusFactory = textFactory;
        _settingsStatus.Text = textFactory();
    }

    private void SetConnectionStatus(string resourceKey) =>
        SetConnectionStatus(() => AppLocalizer.Text(resourceKey));

    private void SetConnectionStatus(Func<string> textFactory)
    {
        _connectionStatusFactory = textFactory;
        _connectionActionStatus.Text = textFactory();
    }

    private void SetLogStatus(string resourceKey) =>
        SetLogStatus(() => AppLocalizer.Text(resourceKey));

    private void SetLogStatus(Func<string> textFactory)
    {
        _logStatusFactory = textFactory;
        _logText.Text = textFactory();
    }

    private void UpdateHeaderNode(string? displayName = null)
    {
        var nodeName = string.IsNullOrWhiteSpace(displayName)
            ? string.IsNullOrWhiteSpace(_displayNameInput.Text)
                ? _settingsStore.Current.DisplayName
                : _displayNameInput.Text.Trim()
            : displayName.Trim();
        _headerNodeLabel.Text = AppLocalizer.Format("HeaderNode", nodeName);
    }

    private void ApplyLocalization()
    {
        ApplyLocalization(this);
        UpdateHeaderNode();
        var selectedLanguage = (_languageInput.SelectedItem as LanguageChoice)?.Code ??
            _settingsStore.Current.UiLanguage;
        PopulateLanguageOptions(selectedLanguage);
        _revealButton.Text = AppLocalizer.Text(_secretsVisible ? "ButtonConceal" : "ButtonReveal");
        if (!_secretsVisible)
        {
            _connectionUrlValue.Text = AppLocalizer.Text("SecretHidden");
        }

        if (_settingsStatusFactory is not null)
        {
            _settingsStatus.Text = _settingsStatusFactory();
        }
        if (_connectionStatusFactory is not null)
        {
            _connectionActionStatus.Text = _connectionStatusFactory();
        }
        if (_logStatusFactory is not null)
        {
            _logText.Text = _logStatusFactory();
        }

        UpdateOverview(_supervisor.Current);
        _tabs.Invalidate();
    }

    private static void ApplyLocalization(Control root)
    {
        if (root.Tag is string tag)
        {
            if (tag.StartsWith("loc:", StringComparison.Ordinal))
            {
                root.Text = AppLocalizer.Text(tag[4..]);
            }
            else if (string.Equals(tag, "locfmt:AboutVersion|version", StringComparison.Ordinal))
            {
                root.Text = AppLocalizer.Format("AboutVersion", ApplicationMetadata.Version);
            }
        }

        foreach (Control child in root.Controls)
        {
            ApplyLocalization(child);
        }
    }

    private void PopulateLanguageOptions(string language)
    {
        _applyingLanguage = true;
        try
        {
            _languageInput.Items.Clear();
            _languageInput.Items.Add(new LanguageChoice(
                AppLocalizer.SystemLanguage,
                AppLocalizer.Text("LanguageSystem")));
            _languageInput.Items.Add(new LanguageChoice(
                AppLocalizer.EnglishLanguage,
                AppLocalizer.Text("LanguageEnglish")));
            _languageInput.Items.Add(new LanguageChoice(
                AppLocalizer.JapaneseLanguage,
                AppLocalizer.Text("LanguageJapanese")));
            var normalized = AppLocalizer.IsSupportedLanguage(language)
                ? language.Trim().ToLowerInvariant()
                : AppLocalizer.SystemLanguage;
            _languageInput.SelectedIndex = Enumerable.Range(0, _languageInput.Items.Count)
                .FirstOrDefault(index =>
                    _languageInput.Items[index] is LanguageChoice choice &&
                    string.Equals(choice.Code, normalized, StringComparison.Ordinal));
        }
        finally
        {
            _applyingLanguage = false;
        }
    }

    private string GetSelectedLanguage() =>
        (_languageInput.SelectedItem as LanguageChoice)?.Code ?? AppLocalizer.SystemLanguage;

    private static void PaintHeader(Panel header, PaintEventArgs args)
    {
        using var gridPen = new Pen(AppTheme.Grid);
        for (var x = 0; x < header.Width; x += 32)
        {
            args.Graphics.DrawLine(gridPen, x, 0, x, header.Height);
        }

        using var linePen = new Pen(AppTheme.Line);
        args.Graphics.DrawLine(linePen, 0, header.Height - 1, header.Width, header.Height - 1);
        using var accentPen = new Pen(AppTheme.Neon, 2F);
        args.Graphics.DrawLine(accentPen, 18, header.Height - 2, 220, header.Height - 2);
    }

    private sealed record LanguageChoice(string Code, string Label)
    {
        public override string ToString() => Label;
    }

    private void SelectExecutable(TextBox target, string fileName) =>
        SelectFile(target, $"{fileName}|{fileName}|Executable files (*.exe)|*.exe|All files (*.*)|*.*");

    private void SelectFile(TextBox target, string filter)
    {
        using var dialog = new OpenFileDialog
        {
            Filter = filter,
            CheckFileExists = true,
            InitialDirectory = File.Exists(target.Text)
                ? Path.GetDirectoryName(target.Text)
                : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
        };
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            target.Text = dialog.FileName;
        }
    }

    private static NumericUpDown NewPortInput() => NewNumberInput(1024, 65535);

    private static NumericUpDown NewNumberInput(int minimum, int maximum) => new()
    {
        Minimum = minimum,
        Maximum = maximum,
        ThousandsSeparator = false,
        TextAlign = HorizontalAlignment.Right
    };
}
