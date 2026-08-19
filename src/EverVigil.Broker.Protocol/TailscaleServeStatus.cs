using System.Globalization;
using System.Text;
using System.Text.Json;

namespace EverVigil.Broker.Protocol;

public static class TailscaleServeStatus
{
    public static ServeRootSnapshot ReadRootSnapshot(
        string statusJson,
        int publicPort,
        IReadOnlyCollection<int> ownedBackendPorts)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(statusJson);
        ArgumentNullException.ThrowIfNull(ownedBackendPorts);
        if (publicPort is < 1 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(publicPort));
        }
        if (ownedBackendPorts.Any(port => port is < 1 or > 65535))
        {
            throw new ArgumentOutOfRangeException(nameof(ownedBackendPorts));
        }

        try
        {
            using var document = JsonDocument.Parse(statusJson);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidDataException("Tailscale Serve status root is invalid.");
            }
            var funnelActive = HasActiveFunnel(root, publicPort);
            var tcpEntries = ReadTcpPortEntries(root, publicPort);
            var webEntries = ReadWebPortEntries(root, publicPort);
            if (tcpEntries.Count == 0 && webEntries.Count == 0)
            {
                return new ServeRootSnapshot(
                    ServeRootState.RootAbsent,
                    funnelActive,
                    "{}");
            }
            if (tcpEntries.Count != 1 ||
                !IsExactHttpTcpEntry(tcpEntries[0]) ||
                webEntries.Count != 1 ||
                webEntries[0].ValueKind != JsonValueKind.Object ||
                webEntries[0].EnumerateObject().Count() != 1 ||
                !webEntries[0].TryGetProperty("Handlers", out var handlers) ||
                handlers.ValueKind != JsonValueKind.Object)
            {
                return new ServeRootSnapshot(
                    ServeRootState.Unowned,
                    funnelActive,
                    string.Empty);
            }

            var unrelatedHandlers = CanonicalizeHandlersExceptRoot(handlers);
            if (!handlers.TryGetProperty("/", out var rootHandler))
            {
                return new ServeRootSnapshot(
                    ServeRootState.RootAbsent,
                    funnelActive,
                    unrelatedHandlers);
            }
            if (rootHandler.ValueKind != JsonValueKind.Object ||
                rootHandler.EnumerateObject().Count() != 1 ||
                !rootHandler.TryGetProperty("Proxy", out var proxy) ||
                proxy.ValueKind != JsonValueKind.String)
            {
                return new ServeRootSnapshot(
                    ServeRootState.Unowned,
                    funnelActive,
                    unrelatedHandlers);
            }
            var owned = ownedBackendPorts.Any(port => string.Equals(
                proxy.GetString(),
                $"http://127.0.0.1:{port}",
                StringComparison.Ordinal));
            return new ServeRootSnapshot(
                owned ? ServeRootState.Owned : ServeRootState.Unowned,
                funnelActive,
                unrelatedHandlers);
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException(
                "Tailscale Serve status JSON is invalid.",
                exception);
        }
    }

    private static List<JsonElement> ReadTcpPortEntries(
        JsonElement root,
        int publicPort)
    {
        if (!root.TryGetProperty("TCP", out var entries) ||
            entries.ValueKind == JsonValueKind.Null)
        {
            return [];
        }
        if (entries.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("Tailscale TCP status is invalid.");
        }
        var exactKey = publicPort.ToString(CultureInfo.InvariantCulture);
        return entries.EnumerateObject()
            .Where(entry => string.Equals(entry.Name, exactKey, StringComparison.Ordinal))
            .Select(entry => entry.Value)
            .ToList();
    }

    private static List<JsonElement> ReadWebPortEntries(
        JsonElement root,
        int publicPort)
    {
        if (!root.TryGetProperty("Web", out var entries) ||
            entries.ValueKind == JsonValueKind.Null)
        {
            return [];
        }
        if (entries.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("Tailscale Web status is invalid.");
        }
        return entries.EnumerateObject()
            .Where(entry => entry.Name.EndsWith(
                $":{publicPort}",
                StringComparison.OrdinalIgnoreCase))
            .Select(entry => entry.Value)
            .ToList();
    }

    private static bool IsExactHttpTcpEntry(JsonElement entry)
    {
        if (entry.ValueKind != JsonValueKind.Object)
        {
            return false;
        }
        var properties = entry.EnumerateObject().ToArray();
        return properties.Length == 1 &&
            string.Equals(properties[0].Name, "HTTP", StringComparison.Ordinal) &&
            properties[0].Value.ValueKind == JsonValueKind.True;
    }

    private static bool HasActiveFunnel(JsonElement root, int publicPort)
    {
        if (HasActiveFunnelEntry(root, publicPort))
        {
            return true;
        }
        if (!root.TryGetProperty("Foreground", out var foreground) ||
            foreground.ValueKind == JsonValueKind.Null)
        {
            return false;
        }
        if (foreground.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("Tailscale Foreground status is invalid.");
        }
        foreach (var session in foreground.EnumerateObject())
        {
            if (session.Value.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidDataException(
                    "Tailscale Foreground session status is invalid.");
            }
            if (HasActiveFunnelEntry(session.Value, publicPort))
            {
                return true;
            }
        }
        return false;
    }

    private static bool HasActiveFunnelEntry(
        JsonElement configuration,
        int publicPort)
    {
        if (!configuration.TryGetProperty("AllowFunnel", out var entries) ||
            entries.ValueKind == JsonValueKind.Null)
        {
            return false;
        }
        if (entries.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("Tailscale AllowFunnel status is invalid.");
        }
        foreach (var entry in entries.EnumerateObject().Where(entry =>
                     entry.Name.EndsWith(
                         $":{publicPort}",
                         StringComparison.OrdinalIgnoreCase)))
        {
            if (entry.Value.ValueKind == JsonValueKind.True)
            {
                return true;
            }
            if (entry.Value.ValueKind != JsonValueKind.False)
            {
                throw new InvalidDataException("Tailscale Funnel value is invalid.");
            }
        }
        return false;
    }

    private static string CanonicalizeHandlersExceptRoot(JsonElement handlers)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            foreach (var property in handlers.EnumerateObject()
                         .Where(property => !string.Equals(
                             property.Name,
                             "/",
                             StringComparison.Ordinal))
                         .OrderBy(property => property.Name, StringComparer.Ordinal))
            {
                writer.WritePropertyName(property.Name);
                WriteCanonical(writer, property.Value);
            }
            writer.WriteEndObject();
        }
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    private static void WriteCanonical(
        Utf8JsonWriter writer,
        JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in element.EnumerateObject()
                             .OrderBy(property => property.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteCanonical(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in element.EnumerateArray())
                {
                    WriteCanonical(writer, item);
                }
                writer.WriteEndArray();
                break;
            default:
                element.WriteTo(writer);
                break;
        }
    }
}

public sealed record ServeRootSnapshot(
    ServeRootState State,
    bool FunnelActive,
    string UnrelatedHandlersJson);

public enum ServeRootState
{
    RootAbsent,
    Owned,
    Unowned
}
