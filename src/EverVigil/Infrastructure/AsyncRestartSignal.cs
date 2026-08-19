namespace EverVigil.Infrastructure;

internal sealed class AsyncRestartSignal : IDisposable
{
    private readonly SemaphoreSlim _signal = new(0, 1);

    public void Signal()
    {
        try
        {
            _signal.Release();
        }
        catch (SemaphoreFullException)
        {
            // A pending restart signal already covers this request.
        }
    }

    public bool TryConsume() => _signal.Wait(0);

    public async Task<bool> WaitAsync(TimeSpan delay, CancellationToken cancellationToken)
    {
        if (delay <= TimeSpan.Zero)
        {
            return false;
        }

        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var delayTask = Task.Delay(delay, linkedCancellation.Token);
        var signalTask = _signal.WaitAsync(linkedCancellation.Token);
        var completedTask = await Task.WhenAny(delayTask, signalTask).ConfigureAwait(false);
        var wasSignaled = completedTask == signalTask;
        try
        {
            await completedTask.ConfigureAwait(false);
        }
        finally
        {
            await linkedCancellation.CancelAsync().ConfigureAwait(false);
            var remainingTask = completedTask == signalTask ? delayTask : signalTask;
            try
            {
                await remainingTask.ConfigureAwait(false);
                wasSignaled |= signalTask.IsCompletedSuccessfully;
            }
            catch (OperationCanceledException)
            {
                // The losing wait is canceled to avoid consuming a later signal.
            }
        }

        return wasSignaled;
    }

    public void Dispose() => _signal.Dispose();
}
