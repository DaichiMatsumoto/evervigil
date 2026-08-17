using EverVigil.Broker.Protocol;

namespace EverVigil.Broker;

internal static class BrokerCommandDispatcher
{
    internal static PrivilegedBrokerResponse Dispatch(
        PrivilegedBrokerRequest request,
        string authenticatedOwnerSid)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentException.ThrowIfNullOrWhiteSpace(authenticatedOwnerSid);
        try
        {
            return PrivilegedSystemConfiguration.Execute(request, authenticatedOwnerSid);
        }
        catch (BrokerRefusalException exception)
        {
            return new PrivilegedBrokerResponse(
                PrivilegedBrokerProtocol.SchemaVersion,
                request.TransactionId,
                Success: false,
                exception.PendingRecovery
                    ? PrivilegedBrokerDisposition.PendingRecovery
                    : PrivilegedBrokerDisposition.Refused,
                exception.ErrorCode,
                SanitizeMessage(exception.Message));
        }
        catch
        {
            return new PrivilegedBrokerResponse(
                PrivilegedBrokerProtocol.SchemaVersion,
                request.TransactionId,
                Success: false,
                PrivilegedBrokerDisposition.PendingRecovery,
                PrivilegedBrokerErrorCode.InternalFailure,
                "The privileged operation failed. Protected recovery state was preserved.");
        }
    }

    private static string SanitizeMessage(string message)
    {
        var sanitized = message.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return sanitized.Length <= 1024 ? sanitized : sanitized[..1024];
    }
}

internal sealed class BrokerRefusalException : Exception
{
    internal BrokerRefusalException(
        string message,
        PrivilegedBrokerErrorCode errorCode,
        bool pendingRecovery = false,
        Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
        PendingRecovery = pendingRecovery;
    }

    internal PrivilegedBrokerErrorCode ErrorCode { get; }

    internal bool PendingRecovery { get; }
}
