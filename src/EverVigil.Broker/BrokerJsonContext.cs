using System.Text.Json.Serialization;

namespace EverVigil.Broker;

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = false,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    UseStringEnumConverter = true,
    WriteIndented = true,
    GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(BrokerAppliedLedger))]
[JsonSerializable(typeof(BrokerPendingJournal))]
[JsonSerializable(typeof(BrokerTransactionReceipt))]
[JsonSerializable(typeof(ProtectedBrokerIdentity))]
[JsonSerializable(typeof(BrokerRetirementReceipt))]
internal sealed partial class BrokerJsonContext : JsonSerializerContext;
