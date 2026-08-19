using System.Globalization;
using EverVigil.Broker.Protocol;

namespace EverVigil.Broker;

internal sealed record BrokerLaunchArguments(
    bool Bootstrap,
    uint ClientProcessId,
    string PipeName,
    string Nonce,
    Guid TransactionId)
{
    internal static BrokerLaunchArguments Parse(string[] arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var bootstrap = false;
        for (var index = 0; index < arguments.Length; index++)
        {
            var name = arguments[index];
            if (string.Equals(name, "--bootstrap", StringComparison.Ordinal))
            {
                if (bootstrap)
                {
                    throw new ArgumentException("Broker bootstrap switch was duplicated.");
                }
                bootstrap = true;
                continue;
            }
            if (name is not ("--client-pid" or "--pipe" or "--nonce" or "--transaction-id") ||
                index + 1 >= arguments.Length ||
                arguments[index + 1].StartsWith("--", StringComparison.Ordinal) ||
                !values.TryAdd(name, arguments[++index]))
            {
                throw new ArgumentException("Privileged broker command line is invalid.");
            }
        }
        if (values.Count != 4 ||
            !uint.TryParse(
                Require(values, "--client-pid"),
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out var clientPid) ||
            clientPid == 0)
        {
            throw new ArgumentException("Broker client PID is invalid.");
        }

        var pipeName = Require(values, "--pipe");
        const string pipePrefix = "EverVigil.Broker.";
        if (!pipeName.StartsWith(pipePrefix, StringComparison.Ordinal) ||
            !Guid.TryParseExact(pipeName[pipePrefix.Length..], "N", out _))
        {
            throw new ArgumentException("Broker pipe name is invalid.");
        }
        var nonce = Require(values, "--nonce");
        if (!PrivilegedBrokerProtocol.IsValidNonce(nonce))
        {
            throw new ArgumentException("Broker nonce is invalid.");
        }
        if (!Guid.TryParseExact(
                Require(values, "--transaction-id"),
                "D",
                out var transactionId) ||
            transactionId == Guid.Empty)
        {
            throw new ArgumentException("Broker transaction ID is invalid.");
        }
        return new BrokerLaunchArguments(
            bootstrap,
            clientPid,
            pipeName,
            nonce,
            transactionId);
    }

    private static string Require(
        IReadOnlyDictionary<string, string> values,
        string name) =>
        values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Required broker argument is missing: {name}");
}
