namespace EverVigil.Infrastructure;

internal static class ProductIdentity
{
    internal const string DataRootDirectoryName = "EverVigil";
    internal const string SettingsFileName = "settings.json";
    internal const string ProtectedTokenFileName = "token.dat";
    internal const string AppliedSystemConfigurationFileName = "applied-system-configuration.json";
    internal const string SystemConfigurationRequiredFileName = "system-configuration-required";
    internal const string LogDirectoryName = "Logs";
    internal const string LogFileName = "evervigil.log";
    internal const string StartupShortcutFileName = "EverVigil.lnk";
    internal const string TokenEntropyContext = "EverVigil/token/v1";
    internal const string TokenMutexNameTemplate = "Global\\EverVigil-Token-{ownerSid}";
    internal const string InstanceScopeNameTemplate = "Global\\EverVigil-{ownerSid}";
    internal const string SystemTransactionMutexName = "Global\\EverVigil.SystemTransaction";
}
