namespace EverVigil.Infrastructure;

internal sealed record DataPaths(
    string DataRoot,
    string SettingsPath,
    string TokenPath,
    string LogRoot,
    string LogPath,
    string StartupShortcutPath)
{
    internal bool IsProductionDataRoot { get; init; }

    internal string PendingSystemConfigurationPath => Path.Combine(
        DataRoot,
        PendingSystemConfigurationStore.FileName);

    public static DataPaths Create()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var startup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
        var dataRoot = Path.Combine(localAppData, ProductIdentity.DataRootDirectoryName);
        var logRoot = Path.Combine(dataRoot, ProductIdentity.LogDirectoryName);
        return new DataPaths(
            dataRoot,
            Path.Combine(dataRoot, ProductIdentity.SettingsFileName),
            Path.Combine(dataRoot, ProductIdentity.ProtectedTokenFileName),
            logRoot,
            Path.Combine(logRoot, ProductIdentity.LogFileName),
            Path.Combine(startup, ProductIdentity.StartupShortcutFileName))
        {
            IsProductionDataRoot = true
        };
    }
}
