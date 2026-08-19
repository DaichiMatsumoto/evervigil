using System.IO.Pipes;
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
                return RunAfterAuthenticatedClientValidation(
                    () => AuthenticatedPipeServer.CreatePrecreatedPipe(launch, client),
                    pipe => RunWithPrecreatedPipe(launch, loadedImage, client, pipe));
            }
        }
    }

    internal static int RunAfterAuthenticatedClientValidation(
        Func<NamedPipeServerStream> pipeFactory,
        Func<NamedPipeServerStream, int> continueWithPrecreatedPipe)
    {
        ArgumentNullException.ThrowIfNull(pipeFactory);
        ArgumentNullException.ThrowIfNull(continueWithPrecreatedPipe);

        NamedPipeServerStream pipe;
        try
        {
            pipe = pipeFactory() ??
                throw new InvalidOperationException("Authenticated pipe factory returned no handle.");
        }
        catch
        {
            return BrokerExitCodes.AuthenticatedPipeFailure;
        }

        using (pipe)
        {
            return continueWithPrecreatedPipe(pipe);
        }
    }

    private static int RunWithPrecreatedPipe(
        BrokerLaunchArguments launch,
        LockedBrokerImage loadedImage,
        AuthenticatedClientProcess client,
        NamedPipeServerStream pipe)
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
                : (request, ownerSid) => DispatchInstalledBootstrap(
                    readiness,
                    request,
                    ownerSid);
        try
        {
            _ = AuthenticatedPipeServer.ServeOnceAsync(
                    pipe,
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

    internal static bool CanDispatchInstalledBootstrap(
        ProtectedBrokerReadiness readiness,
        PrivilegedBrokerRequest request)
    {
        ArgumentNullException.ThrowIfNull(readiness);
        ArgumentNullException.ThrowIfNull(request);
        return readiness.InstalledNow &&
            request.Operation == PrivilegedBrokerOperation.Apply &&
            request.Initiator == PrivilegedBrokerInitiator.Installer;
    }

    private static PrivilegedBrokerResponse DispatchInstalledBootstrap(
        ProtectedBrokerReadiness readiness,
        PrivilegedBrokerRequest request,
        string ownerSid)
    {
        if (CanDispatchInstalledBootstrap(readiness, request))
        {
            return BrokerCommandDispatcher.Dispatch(request, ownerSid);
        }

        if (readiness.InstalledNow &&
            request.Operation == PrivilegedBrokerOperation.Status)
        {
            return new PrivilegedBrokerResponse(
                PrivilegedBrokerProtocol.SchemaVersion,
                request.TransactionId,
                Success: true,
                PrivilegedBrokerDisposition.CanonicalReady,
                PrivilegedBrokerErrorCode.None,
                "Protected broker installation completed.");
        }

        return new PrivilegedBrokerResponse(
            PrivilegedBrokerProtocol.SchemaVersion,
            request.TransactionId,
            Success: false,
            PrivilegedBrokerDisposition.Refused,
            PrivilegedBrokerErrorCode.UnsupportedOperation,
            "A newly installed protected broker accepts only the installer Apply request.");
    }
}
