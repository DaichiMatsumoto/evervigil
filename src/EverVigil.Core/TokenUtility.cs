using System.Security.Cryptography;

namespace EverVigil.Core;

public static class TokenUtility
{
    public static string Generate()
    {
        Span<byte> bytes = stackalloc byte[16];
        RandomNumberGenerator.Fill(bytes);
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    public static bool IsValid(string? token) =>
        token is { Length: 32 } && token.All(Uri.IsHexDigit);
}
