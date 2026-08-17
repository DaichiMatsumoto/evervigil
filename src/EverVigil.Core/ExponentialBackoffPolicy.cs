namespace EverVigil.Core;

public sealed class ExponentialBackoffPolicy
{
    private readonly TimeSpan _initialDelay;
    private readonly TimeSpan _maximumDelay;

    public ExponentialBackoffPolicy(TimeSpan initialDelay, TimeSpan maximumDelay)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(initialDelay, TimeSpan.Zero);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumDelay, initialDelay);

        _initialDelay = initialDelay;
        _maximumDelay = maximumDelay;
    }

    public TimeSpan GetDelay(int attempt)
    {
        if (attempt <= 0)
        {
            return TimeSpan.Zero;
        }

        var exponent = Math.Min(attempt - 1, 30);
        var ticks = _initialDelay.Ticks * Math.Pow(2, exponent);
        return TimeSpan.FromTicks((long)Math.Min(ticks, _maximumDelay.Ticks));
    }
}
