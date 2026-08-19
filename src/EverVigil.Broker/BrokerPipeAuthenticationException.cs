namespace EverVigil.Broker;

internal sealed class BrokerPipeAuthenticationException : Exception
{
    internal BrokerPipeAuthenticationException()
        : base("Authenticated broker pipe validation failed.")
    {
    }

    internal BrokerPipeAuthenticationException(Exception innerException)
        : base("Authenticated broker pipe validation failed.", innerException)
    {
    }
}
