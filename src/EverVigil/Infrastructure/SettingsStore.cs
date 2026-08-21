using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Security.Principal;
using EverVigil.Core;
using EverVigil.Core.Localization;
using EverVigil.Services;

namespace EverVigil.Infrastructure;

internal sealed class SettingsStore
{
    internal const string SystemConfigurationRequiredFileName =
        ProductIdentity.SystemConfigurationRequiredFileName;
    internal const string AppliedSystemConfigurationFileName =
        ProductIdentity.AppliedSystemConfigurationFileName;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = true
    };

    private readonly object _gate = new();
    private readonly DataPaths _paths;
    private readonly string _systemConfigurationRequiredPath;
    private readonly string _appliedSystemConfigurationPath;
    private AppSettings _current;
    private bool _requiresSystemConfiguration;

    public SettingsStore(DataPaths paths)
    {
        _paths = paths;
        _systemConfigurationRequiredPath = Path.Combine(
            paths.DataRoot,
            SystemConfigurationRequiredFileName);
        _appliedSystemConfigurationPath = Path.Combine(
            paths.DataRoot,
            AppliedSystemConfigurationFileName);
        AccessControlService.RestrictDirectory(paths.DataRoot);
        AccessControlService.RestrictDirectory(paths.LogRoot);
        _current = LoadOrCreate();
        _requiresSystemConfiguration = File.Exists(_systemConfigurationRequiredPath);
    }

    public string? LastRecoveryMessage { get; private set; }

    public string? LastRecoveryMessageResourceKey { get; private set; }

    internal string InternalBridgeHostPath => Path.Combine(_paths.DataRoot, "BridgeHost");

    public AppSettings Current
    {
        get
        {
            lock (_gate)
            {
                return _current with { };
            }
        }
    }

    public bool RequiresSystemConfiguration
    {
        get
        {
            lock (_gate)
            {
                return _requiresSystemConfiguration;
            }
        }
    }

    public AppSettings? GetLastAppliedSystemSettings()
    {
        lock (_gate)
        {
            if (!File.Exists(_appliedSystemConfigurationPath))
            {
                return null;
            }

            try
            {
                var json = File.ReadAllText(_appliedSystemConfigurationPath);
                var applied = JsonSerializer.Deserialize<AppliedSystemConfiguration>(json, SerializerOptions) ??
                    throw new InvalidDataException(AppLocalizer.Text("AppliedStateEmpty"));
                if (applied.PublicPort is < 1024 or > 65535 ||
                    applied.BackendPort is < 1024 or > 65535 ||
                    applied.PublicPort == applied.BackendPort ||
                    string.IsNullOrWhiteSpace(applied.TailscalePath) ||
                    applied.TailscalePath.Contains('"') ||
                    !Path.IsPathFullyQualified(applied.TailscalePath))
                {
                    throw new InvalidDataException(AppLocalizer.Text("AppliedStateInvalid"));
                }

                return _current with
                {
                    PublicPort = applied.PublicPort,
                    BackendPort = applied.BackendPort,
                    TailscalePath = Path.GetFullPath(applied.TailscalePath)
                };
            }
            catch (Exception exception) when (exception is JsonException or IOException or InvalidDataException)
            {
                throw new InvalidDataException(
                    AppLocalizer.Text("AppliedStateUnreadable"),
                    exception);
            }
        }
    }

    public void Save(AppSettings settings)
    {
        settings = NormalizeProductionSettings(settings);
        var errors = AppSettingsValidator.Validate(
            settings,
            requireTrustedTailscalePath: _paths.IsProductionDataRoot);
        if (errors.Count > 0)
        {
            throw new InvalidOperationException(string.Join(Environment.NewLine, errors));
        }

        lock (_gate)
        {
            WriteAtomically(settings);
            _current = settings with { };
        }
    }

    public void MarkSystemConfigurationRequired()
    {
        lock (_gate)
        {
            WriteSystemConfigurationRequiredMarker();
        }
    }

    public void MarkSystemConfigurationApplied(AppSettings settings)
    {
        settings = ValidateSystemConfigurationTarget(settings);

        lock (_gate)
        {
            SystemConfigurationService.ExecuteUnderSystemTransaction(() =>
            {
                var ownerSid = WindowsIdentity.GetCurrent().User?.Value ??
                    throw new InvalidOperationException("The current Windows user SID is unavailable.");
                var pendingStore = PendingSystemConfigurationStore.ForCurrentUser(_paths, ownerSid);
                if (pendingStore.Exists)
                {
                    var pending = pendingStore.LoadExisting();
                    if (pending.Initiator == PendingSystemConfigurationInitiator.Installer)
                    {
                        throw new InvalidOperationException(
                            "Installer-owned system configuration is pending completion.");
                    }
                    pendingStore.CommitApplied(pending.TransactionId, settings);
                }
                else
                {
                    WriteAppliedSystemConfigurationAtomically(new AppliedSystemConfiguration(
                        settings.PublicPort,
                        settings.BackendPort,
                        Path.GetFullPath(settings.TailscalePath)));
                    File.Delete(_systemConfigurationRequiredPath);
                }
            });
            _requiresSystemConfiguration = false;
        }
    }

    internal void CommitInstallerSystemConfiguration(
        Guid transactionId,
        AppSettings settings)
    {
        if (transactionId == Guid.Empty)
        {
            throw new ArgumentException(
                "The installer system transaction ID is empty.",
                nameof(transactionId));
        }
        settings = ValidateSystemConfigurationTarget(settings);

        lock (_gate)
        {
            SystemConfigurationService.ExecuteUnderSystemTransaction(() =>
            {
                var ownerSid = WindowsIdentity.GetCurrent().User?.Value ??
                    throw new InvalidOperationException(
                        "The current Windows user SID is unavailable.");
                var pendingStore = PendingSystemConfigurationStore.ForCurrentUser(
                    _paths,
                    ownerSid);
                var pending = pendingStore.Load(transactionId);
                if (pending.Initiator != PendingSystemConfigurationInitiator.Installer)
                {
                    throw new InvalidOperationException(
                        "Only an installer-owned system configuration may use the installer commit command.");
                }
                pendingStore.CommitApplied(transactionId, settings);
            });
            _requiresSystemConfiguration = false;
        }
    }

    private AppSettings LoadOrCreate()
    {
        if (!File.Exists(_paths.SettingsPath))
        {
            return CreateFailClosedDefaults("SettingsCreatedRecovery");
        }

        try
        {
            var json = File.ReadAllText(_paths.SettingsPath);
            var settings = JsonSerializer.Deserialize<AppSettings>(json, SerializerOptions) ??
                throw new InvalidDataException("Settings file was empty.");
            var normalized = NormalizeProductionSettings(settings);
            var tailscalePathWasNormalized = !string.Equals(
                settings.TailscalePath,
                normalized.TailscalePath,
                StringComparison.OrdinalIgnoreCase);
            settings = normalized;
            var errors = AppSettingsValidator.Validate(
                settings,
                requireExistingPaths: false,
                requireTrustedTailscalePath: _paths.IsProductionDataRoot);
            if (errors.Count > 0)
            {
                throw new InvalidDataException(string.Join(Environment.NewLine, errors));
            }

            var canonicalJson = JsonSerializer.Serialize(settings, SerializerOptions);
            if (!string.Equals(json, canonicalJson, StringComparison.Ordinal))
            {
                WriteAtomically(settings);
            }
            if (tailscalePathWasNormalized)
            {
                WriteSystemConfigurationRequiredMarker();
            }

            return settings;
        }
        catch (Exception exception) when (exception is JsonException or IOException or InvalidDataException)
        {
            var invalidPath =
                $"{_paths.SettingsPath}.invalid-{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}";
            File.Move(_paths.SettingsPath, invalidPath, overwrite: true);
            return CreateFailClosedDefaults("SettingsQuarantinedRecovery");
        }
    }

    private AppSettings CreateFailClosedDefaults(string resourceKey)
    {
        var defaults = AppSettings.CreateDefault();
        WriteSystemConfigurationRequiredMarker();
        WriteAtomically(defaults);
        LastRecoveryMessageResourceKey = resourceKey;
        LastRecoveryMessage = AppLocalizer.Text(resourceKey);
        return defaults;
    }

    private AppSettings NormalizeProductionSettings(AppSettings settings) =>
        _paths.IsProductionDataRoot
            ? settings with { TailscalePath = AppSettings.FixedTailscalePath }
            : settings;

    private AppSettings ValidateSystemConfigurationTarget(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        settings = NormalizeProductionSettings(settings);
        if (settings.PublicPort is < 1024 or > 65535 ||
            settings.BackendPort is < 1024 or > 65535 ||
            settings.PublicPort == settings.BackendPort)
        {
            throw new ArgumentOutOfRangeException(
                nameof(settings),
                "System configuration ports are invalid.");
        }
        if (string.IsNullOrWhiteSpace(settings.TailscalePath) ||
            settings.TailscalePath.Contains('"') ||
            !Path.IsPathFullyQualified(settings.TailscalePath))
        {
            throw new ArgumentException("Tailscale path is invalid.", nameof(settings));
        }
        return settings;
    }

    private void WriteSystemConfigurationRequiredMarker()
    {
        using (var stream = new FileStream(
                   _systemConfigurationRequiredPath,
                   FileMode.Create,
                   FileAccess.Write,
                   FileShare.Read,
                   bufferSize: 4096,
                   FileOptions.WriteThrough))
        using (var writer = new StreamWriter(stream, new UTF8Encoding(false), leaveOpen: true))
        {
            writer.Write($"System configuration required at {DateTimeOffset.Now:O}");
            writer.Flush();
            stream.Flush(flushToDisk: true);
        }

        AccessControlService.RestrictFile(_systemConfigurationRequiredPath);
        _requiresSystemConfiguration = true;
    }

    private void WriteAppliedSystemConfigurationAtomically(AppliedSystemConfiguration configuration)
    {
        var temporaryPath = $"{_appliedSystemConfigurationPath}.{Guid.NewGuid():N}.tmp";
        try
        {
            using (var stream = AccessControlService.CreateRestrictedFile(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileShare.None,
                       bufferSize: 4096,
                       FileOptions.WriteThrough))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false), leaveOpen: true))
            {
                writer.Write(JsonSerializer.Serialize(configuration, SerializerOptions));
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporaryPath, _appliedSystemConfigurationPath, overwrite: true);
            AccessControlService.RestrictFile(_appliedSystemConfigurationPath);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private void WriteAtomically(AppSettings settings)
    {
        var temporaryPath = $"{_paths.SettingsPath}.{Guid.NewGuid():N}.tmp";
        try
        {
            using (var stream = AccessControlService.CreateRestrictedFile(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileShare.None,
                       bufferSize: 4096,
                       FileOptions.WriteThrough))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false), leaveOpen: true))
            {
                writer.Write(JsonSerializer.Serialize(settings, SerializerOptions));
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporaryPath, _paths.SettingsPath, overwrite: true);
            AccessControlService.RestrictFile(_paths.SettingsPath);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}

internal sealed record AppliedSystemConfiguration(
    int PublicPort,
    int BackendPort,
    string TailscalePath);
