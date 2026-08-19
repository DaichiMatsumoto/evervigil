namespace EverVigil.Core;

public static class ConnectionUrlBuilder
{
    public static string BuildBaseUrl(string tailscaleHost, int publicPort)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(tailscaleHost);
        if (publicPort is < 1024 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(publicPort));
        }

        var source = tailscaleHost.Trim();
        var host = source;
        if (host.Length >= 2 && host[0] == '[' && host[^1] == ']')
        {
            host = host[1..^1];
        }

        if (source.Contains("://", StringComparison.Ordinal) ||
            source.Contains('/') ||
            source.Contains('\\') ||
            source.Contains('?') ||
            source.Contains('#') ||
            source.Any(char.IsWhiteSpace) ||
            Uri.CheckHostName(host) == UriHostNameType.Unknown)
        {
            throw new ArgumentException(
                "The Tailscale host must be a host name or IP address without a scheme or path.",
                nameof(tailscaleHost));
        }

        var builder = new UriBuilder(Uri.UriSchemeHttp, host, publicPort);
        return builder.Uri.GetLeftPart(UriPartial.Authority);
    }

    public static string BuildConnectionUrl(
        string tailscaleHost,
        int publicPort,
        string token)
    {
        if (!TokenUtility.IsValid(token))
        {
            throw new ArgumentException("The token must contain exactly 32 hexadecimal characters.", nameof(token));
        }

        return $"{BuildBaseUrl(tailscaleHost, publicPort)}/?token={Uri.EscapeDataString(token)}&defaultProvider=codex";
    }
}
