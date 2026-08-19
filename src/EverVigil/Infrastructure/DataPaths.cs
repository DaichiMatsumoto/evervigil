using EverVigil.Compatibility;

namespace EverVigil.Infrastructure;

internal sealed record DataPaths(
    string DataRoot,
    string SettingsPath,
    string TokenPath,
    string LogRoot,
    string LogPath,
    string StartupShortcutPath)
{
    internal bool UsesLegacyDataRoot { get; init; }

    internal string TokenEntropyContext { get; init; } = "EverVigil/token/v1";

    internal string TokenMutexNameTemplate { get; init; } = "Global\\EverVigil-Token-{ownerSid}";

    internal string? LegacyStartupShortcutPath { get; init; }

    internal bool IsProductionDataRoot { get; init; }

    internal string PendingSystemConfigurationPath => Path.Combine(
        DataRoot,
        PendingSystemConfigurationStore.FileName);

    public static DataPaths Create()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var startup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
        var currentDataRoot = Path.Combine(localAppData, "EverVigil");
        var legacyDataRoot = Path.Combine(
            localAppData,
            LegacyCompatibility.Application.DataRootRelativeToLocalAppData);
        var currentHasState = HasPersistentState(currentDataRoot);
        var legacyHasState = HasPersistentState(legacyDataRoot);
        if (currentHasState && legacyHasState)
        {
            throw new InvalidOperationException(
                "Both current and legacy application data contain persistent state. " +
                "Resolve the interrupted migration before starting EverVigil.");
        }

        var useLegacyDataRoot = legacyHasState && !currentHasState;
        var dataRoot = useLegacyDataRoot ? legacyDataRoot : currentDataRoot;
        var logRoot = Path.Combine(dataRoot, "Logs");
        return new DataPaths(
            dataRoot,
            Path.Combine(dataRoot, LegacyCompatibility.Data.SettingsFileName),
            Path.Combine(dataRoot, LegacyCompatibility.Data.ProtectedTokenFileName),
            logRoot,
            Path.Combine(logRoot, useLegacyDataRoot ? "supervisor.log" : "evervigil.log"),
            Path.Combine(startup, "EverVigil.lnk"))
        {
            IsProductionDataRoot = true,
            UsesLegacyDataRoot = useLegacyDataRoot,
            TokenEntropyContext = useLegacyDataRoot
                ? LegacyCompatibility.Cryptography.DpapiEntropyContext
                : "EverVigil/token/v1",
            TokenMutexNameTemplate = useLegacyDataRoot
                ? LegacyCompatibility.Synchronization.TokenMutexTemplate
                : "Global\\EverVigil-Token-{ownerSid}",
            LegacyStartupShortcutPath = Path.Combine(
                startup,
                LegacyCompatibility.Application.StartupShortcutFileName)
        };
    }

    internal static bool HasPersistentState(string dataRoot)
    {
        if (!Directory.Exists(dataRoot))
        {
            return false;
        }

        return File.Exists(Path.Combine(dataRoot, LegacyCompatibility.Data.SettingsFileName)) ||
            File.Exists(Path.Combine(dataRoot, LegacyCompatibility.Data.ProtectedTokenFileName)) ||
            File.Exists(Path.Combine(dataRoot, LegacyCompatibility.Data.TransactionJournalFileName)) ||
            File.Exists(Path.Combine(
                dataRoot,
                LegacyCompatibility.Data.AppliedSystemConfigurationFileName)) ||
            File.Exists(Path.Combine(
                dataRoot,
                LegacyCompatibility.Data.SystemConfigurationRequiredFileName)) ||
            File.Exists(Path.Combine(
                dataRoot,
                PendingSystemConfigurationStore.FileName)) ||
            File.Exists(Path.Combine(
                dataRoot,
                LegacyCompatibility.Data.DiagnosticLoggingMarkerFileName)) ||
            Directory.Exists(Path.Combine(
                dataRoot,
                LegacyCompatibility.Data.TransactionRecoveryDirectoryName));
    }
}
