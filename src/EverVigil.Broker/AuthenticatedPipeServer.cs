using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using EverVigil.Broker.Protocol;

namespace EverVigil.Broker;

internal static class AuthenticatedPipeServer
{
    private static readonly TimeSpan ConnectionTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(90);

    internal static NamedPipeServerStream CreatePrecreatedPipe(
        BrokerLaunchArguments launch,
        AuthenticatedClientProcess client)
    {
        ArgumentNullException.ThrowIfNull(launch);
        ArgumentNullException.ThrowIfNull(client);
        RequireAuthenticatedClientStillActive(client);

        var security = CreatePipeSecurity(client.UserSid);
        return CreateServerPipe(launch.PipeName, security);
    }

    internal static async Task<PrivilegedBrokerResponse> ServeOnceAsync(
        NamedPipeServerStream pipe,
        BrokerLaunchArguments launch,
        AuthenticatedClientProcess client,
        Func<PrivilegedBrokerRequest, string, PrivilegedBrokerResponse> dispatch)
    {
        ArgumentNullException.ThrowIfNull(pipe);
        ArgumentNullException.ThrowIfNull(launch);
        ArgumentNullException.ThrowIfNull(client);
        ArgumentNullException.ThrowIfNull(dispatch);
        RequireAuthenticatedClientStillActive(client);

        if (!pipe.IsConnected)
        {
            using var connectionCancellation = new CancellationTokenSource(ConnectionTimeout);
            await pipe.WaitForConnectionAsync(connectionCancellation.Token).ConfigureAwait(false);
        }

        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out var pipeClientPid) ||
            pipeClientPid != client.ProcessId)
        {
            throw new BrokerPipeAuthenticationException();
        }
        RequireAuthenticatedClientStillActive(client);

        using var requestCancellation = new CancellationTokenSource(RequestTimeout);
        var request = await PrivilegedBrokerProtocol.ReadFrameAsync<PrivilegedBrokerRequest>(
            pipe,
            requestCancellation.Token).ConfigureAwait(false);
        RequireAuthenticatedClientStillActive(client);
        try
        {
            ValidateEnvelope(request, launch);
        }
        catch (InvalidDataException exception)
        {
            throw new BrokerPipeAuthenticationException(exception);
        }
        var response = dispatch(request, client.UserSid.Value);
        ValidateResponse(response, request.TransactionId);
        await PrivilegedBrokerProtocol.WriteFrameAsync(
            pipe,
            response,
            requestCancellation.Token).ConfigureAwait(false);
        pipe.WaitForPipeDrain();
        return response;
    }

    internal static NamedPipeServerStream CreateServerPipe(
        string pipeName,
        PipeSecurity security)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        ArgumentNullException.ThrowIfNull(security);

        return NamedPipeServerStreamAcl.Create(
            pipeName,
            PipeDirection.InOut,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.WriteThrough,
            inBufferSize: PrivilegedBrokerProtocol.MaximumFrameBytes + sizeof(int),
            outBufferSize: PrivilegedBrokerProtocol.MaximumFrameBytes + sizeof(int),
            security,
            inheritability: HandleInheritability.None,
            additionalAccessRights: (PipeAccessRights)0);
    }

    private static void RequireAuthenticatedClientStillActive(
        AuthenticatedClientProcess client)
    {
        try
        {
            client.RequireOriginalProcessStillActive();
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new BrokerPipeAuthenticationException(exception);
        }
    }

    private static PipeSecurity CreatePipeSecurity(SecurityIdentifier clientSid)
    {
        var security = new PipeSecurity();
        security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new PipeAccessRule(
            clientSid,
            PipeAccessRights.ReadWrite | PipeAccessRights.Synchronize,
            AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        return security;
    }

    private static void ValidateEnvelope(
        PrivilegedBrokerRequest request,
        BrokerLaunchArguments launch)
    {
        if (request.SchemaVersion != PrivilegedBrokerProtocol.SchemaVersion ||
            request.TransactionId == Guid.Empty ||
            request.TransactionId != launch.TransactionId ||
            !PrivilegedBrokerProtocol.IsValidNonce(request.Nonce) ||
            !string.Equals(request.Nonce, launch.Nonce, StringComparison.Ordinal) ||
            !Enum.IsDefined(request.Operation) ||
            !Enum.IsDefined(request.Initiator))
        {
            throw new InvalidDataException("Privileged broker request envelope is invalid.");
        }

        if (request.Operation == PrivilegedBrokerOperation.Apply)
        {
            if (request.PublicPort is < 1024 or > 65535 ||
                request.BackendPort is < 1024 or > 65535 ||
                request.PublicPort == request.BackendPort)
            {
                throw new InvalidDataException("Privileged broker Apply ports are invalid.");
            }
        }
        else if (request.PublicPort is not null || request.BackendPort is not null)
        {
            throw new InvalidDataException(
                "Only Privileged broker Apply accepts port fields.");
        }
    }

    private static void ValidateResponse(PrivilegedBrokerResponse response, Guid transactionId)
    {
        if (response.SchemaVersion != PrivilegedBrokerProtocol.SchemaVersion ||
            response.TransactionId != transactionId ||
            !Enum.IsDefined(response.Disposition) ||
            !Enum.IsDefined(response.ErrorCode) ||
            response.Message.Length > 1024 ||
            response.Message.Contains('\r') ||
            response.Message.Contains('\n'))
        {
            throw new InvalidDataException("Privileged broker response is invalid.");
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(
        IntPtr pipe,
        out uint clientProcessId);
}
