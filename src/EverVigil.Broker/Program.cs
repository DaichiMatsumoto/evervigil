using EverVigil.Broker.Protocol;

namespace EverVigil.Broker;

internal static class Program
{
    private const int InternalFailureExitCode = 1;
    private const int AuthenticationFailureExitCode = 3;
    private const int ProtectedInstallationFailureExitCode = 4;

    [STAThread]
    private static int Main(string[] arguments)
    {
        BrokerLaunchArguments launch;
        try
        {
            launch = BrokerLaunchArguments.Parse(arguments);
            AuthenticatedClientProcess.RequireBrokerHighIntegrity();
        }
        catch
        {
            return AuthenticationFailureExitCode;
        }

        try
        {
            using var loadedImage = ProtectedBrokerInstallation.LockLoadedImage();
            using var client = AuthenticatedClientProcess.OpenAndValidate(
                launch.ClientProcessId);
            ProtectedBrokerReadiness readiness;
            try
            {
                readiness = BrokerSystemMutex.Execute(() =>
                    ProtectedBrokerInstallation.EnsureReady(
                        launch.Bootstrap,
                        loadedImage));
            }
            catch
            {
                return ProtectedInstallationFailureExitCode;
            }

            Func<PrivilegedBrokerRequest, string, PrivilegedBrokerResponse> dispatch =
                readiness.RetirementPending
                    ? (request, ownerSid) => BrokerSystemMutex.Execute(() =>
                        ProtectedBrokerRetirement.Resume(
                            request,
                            ownerSid,
                            Path.GetFullPath(Environment.GetFolderPath(
                                Environment.SpecialFolder.CommonApplicationData)),
                            ProtectedBrokerInstallation.GetProductVersion()))
                    : readiness.IsCanonicalInvocation
                    ? BrokerCommandDispatcher.Dispatch
                    : (request, _) => new PrivilegedBrokerResponse(
                        PrivilegedBrokerProtocol.SchemaVersion,
                        request.TransactionId,
                        Success: true,
                        PrivilegedBrokerDisposition.CanonicalReady,
                        PrivilegedBrokerErrorCode.None,
                        "Protected broker installation completed; invoke the canonical broker.");
            _ = AuthenticatedPipeServer.ServeOnceAsync(
                    launch,
                    client,
                    dispatch)
                .GetAwaiter()
                .GetResult();
            return 0;
        }
        catch (UnauthorizedAccessException)
        {
            return AuthenticationFailureExitCode;
        }
        catch
        {
            return InternalFailureExitCode;
        }
    }
}
