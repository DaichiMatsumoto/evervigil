using System.Net.Http.Headers;
using System.Text.Json;
using EverVigil.Core;
using EverVigil.Infrastructure;

namespace EverVigil.Services;

internal sealed class HealthProbe : IDisposable
{
    private readonly ProtectedTailscaleIdentityStore _tailscaleIdentityStore = new();
    private readonly HttpClient _client = new(new SocketsHttpHandler
    {
        UseProxy = false,
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromSeconds(5)
    });

    public async Task<bool> IsLocalEndpointReadyAsync(AppSettings settings, CancellationToken cancellationToken) =>
        await IsEndpointReadyAsync(
            new Uri($"http://127.0.0.1:{settings.BackendPort}/", UriKind.Absolute),
            cancellationToken).ConfigureAwait(false);

    public async Task<bool> IsPublicEndpointReadyAsync(
        AppSettings settings,
        string token,
        CancellationToken cancellationToken)
    {
        if (!_tailscaleIdentityStore.TryLoad(settings, out _))
        {
            return false;
        }

        return await IsSessionEndpointReadyAsync(
                BuildLoopbackSessionUri(settings),
                token,
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<bool> IsProviderReadyAsync(
        AppSettings settings,
        string token,
        CancellationToken cancellationToken) =>
        await IsSessionEndpointReadyAsync(
                BuildLoopbackSessionUri(settings),
                token,
                cancellationToken)
            .ConfigureAwait(false);

    internal static Uri BuildLoopbackSessionUri(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (settings.BackendPort is < 1024 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(settings));
        }

        return new Uri(
            $"http://127.0.0.1:{settings.BackendPort}/api/sessions?provider=codex&limit=1",
            UriKind.Absolute);
    }

    internal static bool IsSessionPayloadReady(JsonElement root) =>
        root.ValueKind == JsonValueKind.Object &&
        root.TryGetProperty("sessions", out var sessions) &&
        sessions.ValueKind == JsonValueKind.Array &&
        !root.TryGetProperty("error", out _);

    public void Dispose() => _client.Dispose();

    private async Task<bool> IsSessionEndpointReadyAsync(
        Uri uri,
        string token,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(20));
            using var response = await _client.SendAsync(
                request,
                HttpCompletionOption.ResponseContentRead,
                timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return false;
            }

            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: timeout.Token)
                .ConfigureAwait(false);
            return IsSessionPayloadReady(document.RootElement);
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or JsonException)
        {
            return false;
        }
    }

    private async Task<bool> IsEndpointReadyAsync(Uri uri, CancellationToken cancellationToken)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            using var response = await _client.GetAsync(
                uri,
                HttpCompletionOption.ResponseHeadersRead,
                timeout.Token).ConfigureAwait(false);
            return (int)response.StatusCode < 500;
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
        {
            return false;
        }
    }
}
