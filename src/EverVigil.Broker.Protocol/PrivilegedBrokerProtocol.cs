using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;

namespace EverVigil.Broker.Protocol;

public static class PrivilegedBrokerProtocol
{
    public const int SchemaVersion = 1;
    public const int MaximumFrameBytes = 64 * 1024;
    public const int NonceBytes = 32;

    public static async Task WriteFrameAsync<T>(
        Stream stream,
        T value,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        var payload = JsonSerializer.SerializeToUtf8Bytes(value, GetTypeInfo<T>());
        if (payload.Length is <= 0 or > MaximumFrameBytes)
        {
            throw new InvalidDataException("Privileged broker frame length is invalid.");
        }

        var header = new byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(header, payload.Length);
        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async Task<T> ReadFrameAsync<T>(
        Stream stream,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        var header = new byte[sizeof(int)];
        await ReadExactlyAsync(stream, header, cancellationToken).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length is <= 0 or > MaximumFrameBytes)
        {
            throw new InvalidDataException("Privileged broker frame length is invalid.");
        }

        var payload = new byte[length];
        await ReadExactlyAsync(stream, payload, cancellationToken).ConfigureAwait(false);
        try
        {
            return JsonSerializer.Deserialize(payload, GetTypeInfo<T>()) ??
                throw new InvalidDataException("Privileged broker frame was empty.");
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException("Privileged broker frame was invalid JSON.", exception);
        }
    }

    public static string CreateNonce()
    {
        var bytes = System.Security.Cryptography.RandomNumberGenerator.GetBytes(NonceBytes);
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    public static bool IsValidNonce(string? nonce)
    {
        if (nonce?.Length != NonceBytes * 2)
        {
            return false;
        }

        foreach (var character in nonce)
        {
            if (character is not (>= '0' and <= '9') and
                not (>= 'a' and <= 'f'))
            {
                return false;
            }
        }
        return true;
    }

    private static JsonTypeInfo<T> GetTypeInfo<T>() =>
        typeof(T) == typeof(PrivilegedBrokerRequest)
            ? (JsonTypeInfo<T>)(object)
                PrivilegedBrokerJsonContext.Default.PrivilegedBrokerRequest
            : typeof(T) == typeof(PrivilegedBrokerResponse)
                ? (JsonTypeInfo<T>)(object)
                    PrivilegedBrokerJsonContext.Default.PrivilegedBrokerResponse
                : throw new NotSupportedException(
                    $"Privileged broker framing does not support {typeof(T).FullName}.");

    private static async Task ReadExactlyAsync(
        Stream stream,
        Memory<byte> buffer,
        CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var count = await stream.ReadAsync(buffer[offset..], cancellationToken)
                .ConfigureAwait(false);
            if (count == 0)
            {
                throw new EndOfStreamException("Privileged broker pipe closed mid-frame.");
            }
            offset += count;
        }
    }
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = false,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    UseStringEnumConverter = true,
    GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(PrivilegedBrokerRequest))]
[JsonSerializable(typeof(PrivilegedBrokerResponse))]
internal sealed partial class PrivilegedBrokerJsonContext : JsonSerializerContext;

public sealed record PrivilegedBrokerRequest(
    int SchemaVersion,
    Guid TransactionId,
    string Nonce,
    PrivilegedBrokerOperation Operation,
    PrivilegedBrokerInitiator Initiator,
    int? PublicPort,
    int? BackendPort,
    bool MigrateLegacySystemState = false);

public sealed record PrivilegedBrokerResponse(
    int SchemaVersion,
    Guid TransactionId,
    bool Success,
    PrivilegedBrokerDisposition Disposition,
    PrivilegedBrokerErrorCode ErrorCode,
    string Message);

public enum PrivilegedBrokerOperation
{
    Apply,
    Recover,
    Rollback,
    Commit,
    UninstallCleanup,
    LegacyTaskCleanup,
    Status
}

public enum PrivilegedBrokerInitiator
{
    Interactive,
    Installer
}

public enum PrivilegedBrokerDisposition
{
    CanonicalReady,
    Completed,
    RetirementRequired,
    RolledBack,
    PendingRecovery,
    NoChange,
    Refused
}

public enum PrivilegedBrokerErrorCode
{
    None,
    InvalidRequest,
    AuthenticationFailed,
    ElevationRequired,
    ProtectedInstallationInvalid,
    PendingTransactionMismatch,
    OwnershipMismatch,
    FunnelDetected,
    ExternalCommandFailed,
    RecoveryRequired,
    UnsupportedOperation,
    InternalFailure
}
