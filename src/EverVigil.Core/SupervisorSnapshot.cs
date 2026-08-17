namespace EverVigil.Core;

public enum SupervisorState
{
    Initializing,
    Stopped,
    Starting,
    Online,
    Degraded,
    Restarting,
    Stopping,
    Faulted
}

public sealed record SupervisorSnapshot(
    SupervisorState State,
    DateTimeOffset UpdatedAt,
    DateTimeOffset StateSince,
    int? BackendProcessId,
    bool LocalEndpointReady,
    bool ProviderReady,
    bool PublicEndpointReady,
    int RestartAttempt,
    DateTimeOffset? NextRetryAt,
    string? LastError)
{
    public static SupervisorSnapshot Initial { get; } = new(
        SupervisorState.Initializing,
        DateTimeOffset.Now,
        DateTimeOffset.Now,
        null,
        false,
        false,
        false,
        0,
        null,
        null);
}
