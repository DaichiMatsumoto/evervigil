using System.Net.Http.Headers;
using System.Net.Http.Json;
using EverVigil.Core;

namespace EverVigil.Services;

internal static class ProviderModelCatalog
{
    public static async Task<string[]> LoadAsync(AppSettings settings, string token, string provider)
    {
        if (settings.BackendPort is < 1024 or > 65535 ||
            !TokenUtility.IsValid(token) || provider is not ("codex" or "claude"))
        {
            throw new ArgumentException("The model catalog request is invalid.");
        }

        using var client = new HttpClient(new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false
        })
        { Timeout = TimeSpan.FromSeconds(35) };
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var catalog = await client.GetFromJsonAsync<ModelResponse>(
            $"http://127.0.0.1:{settings.BackendPort}/api/models?provider={provider}");
        if (catalog?.Models is not { Length: > 0 } models || models.Any(model =>
                string.IsNullOrEmpty(model) || model.Length > 200 ||
                model.Any(character => char.IsWhiteSpace(character) || char.IsControl(character))))
        {
            throw new InvalidDataException("The model catalog response is invalid.");
        }
        return models;
    }

    private sealed record ModelResponse(string[] Models);
}
