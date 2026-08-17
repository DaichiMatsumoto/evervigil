using System.Text.RegularExpressions;

namespace EverVigil.Core;

public static partial class SecretRedactor
{
    public static string Redact(string? value, params string[] knownSecrets)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value ?? string.Empty;
        }

        var result = value;
        foreach (var secret in knownSecrets.Where(static secret => !string.IsNullOrWhiteSpace(secret)))
        {
            result = result.Replace(secret, "<redacted>", StringComparison.Ordinal);
        }

        result = AuthorizationRegex().Replace(result, "$1<redacted>");
        result = TokenQueryRegex().Replace(result, "$1<redacted>");
        result = HexTokenRegex().Replace(result, "<redacted>");
        return result;
    }

    [GeneratedRegex("(?i)(authorization\\s*[:=]\\s*bearer\\s+)[^\\s,;]+")]
    private static partial Regex AuthorizationRegex();

    [GeneratedRegex("(?i)(token(?:=|%3D))[^&\\s]+")]
    private static partial Regex TokenQueryRegex();

    [GeneratedRegex("\\b[0-9a-fA-F]{32}\\b")]
    private static partial Regex HexTokenRegex();
}
