using System.Net;
using System.Net.Sockets;

namespace EverVigil.Broker.Protocol;

public static class TailscaleIdentityValidator
{
    public static bool IsValidDnsName(string? dnsName) =>
        !string.IsNullOrWhiteSpace(dnsName) &&
        dnsName.Length <= 253 &&
        dnsName.EndsWith(".ts.net", StringComparison.Ordinal) &&
        dnsName.Length > ".ts.net".Length &&
        string.Equals(dnsName, dnsName.ToLowerInvariant(), StringComparison.Ordinal) &&
        !dnsName.Any(character =>
            char.IsWhiteSpace(character) || character is '/' or '\\' or ':' or '?' or '#');

    public static bool IsTailnetAddress(string? address)
    {
        if (!IPAddress.TryParse(address, out var parsed))
        {
            return false;
        }
        var bytes = parsed.GetAddressBytes();
        if (parsed.AddressFamily == AddressFamily.InterNetwork)
        {
            return bytes.Length == 4 && bytes[0] == 100 && bytes[1] is >= 64 and <= 127;
        }
        return parsed.AddressFamily == AddressFamily.InterNetworkV6 &&
            bytes.Length == 16 &&
            bytes[0] == 0xfd &&
            bytes[1] == 0x7a &&
            bytes[2] == 0x11 &&
            bytes[3] == 0x5c &&
            bytes[4] == 0xa1 &&
            bytes[5] == 0xe0;
    }
}
