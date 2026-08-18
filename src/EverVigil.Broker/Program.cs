using EverVigil.Broker.Protocol;

namespace EverVigil.Broker;

internal static class Program
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        BrokerLaunchArguments launch;
        try
        {
            launch = BrokerLaunchArguments.Parse(arguments);
        }
        catch
        {
            return BrokerExitCodes.InvalidLaunchArguments;
        }

        try
        {
            AuthenticatedClientProcess.RequireBrokerHighIntegrity();
        }
        catch
        {
            return BrokerExitCodes.BrokerElevationFailure;
        }

        LockedBrokerImage loadedImage;
        try
        {
            loadedImage = ProtectedBrokerInstallation.LockLoadedImage();
        }
        catch
        {
            return BrokerExitCodes.LoadedImageValidationFailure;
        }

        using (loadedImage)
        {
            AuthenticatedClientProcess client;
            try
            {
                client = AuthenticatedClientProcess.OpenAndValidate(
                    launch.ClientProcessId);
            }
            catch
            {
                return BrokerExitCodes.ClientAuthenticationFailure;
            }

            using (client)
            {
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
                    return BrokerExitCodes.ProtectedInstallationFailure;
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
                try
                {
                    _ = AuthenticatedPipeServer.ServeOnceAsync(
                            launch,
                            client,
                            dispatch)
                        .GetAwaiter()
                        .GetResult();
                    return BrokerExitCodes.Success;
                }
                catch (BrokerPipeAuthenticationException)
                {
                    return BrokerExitCodes.AuthenticatedPipeFailure;
                }
                catch
                {
                    return BrokerExitCodes.InternalFailure;
                }
            }
        }
    }
}
