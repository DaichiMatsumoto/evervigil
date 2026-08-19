namespace EverVigil.Broker;

internal static class BrokerExitCodes
{
    internal const int Success = 0;
    internal const int InternalFailure = 1;
    internal const int InvalidLaunchArguments = 3;
    internal const int ProtectedInstallationFailure = 4;
    internal const int BrokerElevationFailure = 5;
    internal const int LoadedImageValidationFailure = 6;
    internal const int ClientAuthenticationFailure = 7;
    internal const int AuthenticatedPipeFailure = 8;
}
