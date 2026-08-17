using System.Diagnostics;
using System.Runtime.InteropServices;

using EverVigil.Core.Localization;

namespace EverVigil.UI;

internal sealed class SensitiveClipboard : IDisposable
{
    private const int MaximumRetryIntervalMilliseconds = 5_000;
    private static readonly TimeSpan DisposeClearTimeout = TimeSpan.FromSeconds(15);
    private readonly ISensitiveClipboardAccess _clipboard;
    private readonly System.Windows.Forms.Timer _clearTimer;
    private readonly TimeSpan _disposeClearTimeout;
    private readonly Action<TimeSpan> _delay;
    private string? _lastValue;
    private int _clearRetryAttempt;
    private bool _disposed;

    public SensitiveClipboard(int clearAfterSeconds)
        : this(clearAfterSeconds, new WindowsSensitiveClipboardAccess())
    {
    }

    internal SensitiveClipboard(
        int clearAfterSeconds,
        ISensitiveClipboardAccess clipboard,
        TimeSpan? disposeClearTimeout = null,
        Action<TimeSpan>? delay = null)
    {
        _clipboard = clipboard ?? throw new ArgumentNullException(nameof(clipboard));
        _disposeClearTimeout = disposeClearTimeout ?? DisposeClearTimeout;
        if (_disposeClearTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(disposeClearTimeout));
        }
        _delay = delay ?? (duration => Thread.Sleep(duration));
        _clearTimer = new System.Windows.Forms.Timer
        {
            Interval = Math.Max(15, clearAfterSeconds) * 1000
        };
        _clearTimer.Tick += ClearIfUnchanged;
    }

    public void Set(string value, int clearAfterSeconds)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(value);
        Exception? lastError = null;
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                _clipboard.SetText(value);
                _lastValue = value;
                _clearRetryAttempt = 0;
                _clearTimer.Stop();
                _clearTimer.Interval = Math.Max(15, clearAfterSeconds) * 1000;
                _clearTimer.Start();
                return;
            }
            catch (ExternalException exception)
            {
                lastError = exception;
                Thread.Sleep(40 * (attempt + 1));
            }
        }

        throw new InvalidOperationException(AppLocalizer.Text("ClipboardUnavailable"), lastError);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _clearTimer.Stop();
        _clearTimer.Tick -= ClearIfUnchanged;
        var retryDelayMilliseconds = 50;
        var stopwatch = Stopwatch.StartNew();
        while (!TryClearIfUnchanged() && stopwatch.Elapsed < _disposeClearTimeout)
        {
            var remaining = _disposeClearTimeout - stopwatch.Elapsed;
            var delay = TimeSpan.FromMilliseconds(Math.Min(
                retryDelayMilliseconds,
                Math.Max(1, remaining.TotalMilliseconds)));
            _delay(delay);
            retryDelayMilliseconds = Math.Min(
                MaximumRetryIntervalMilliseconds,
                retryDelayMilliseconds * 2);
        }

        _lastValue = null;
        _clearTimer.Dispose();
    }

    private void ClearIfUnchanged(object? sender, EventArgs args)
    {
        _clearTimer.Stop();
        if (TryClearIfUnchanged())
        {
            _clearRetryAttempt = 0;
            return;
        }

        if (_disposed)
        {
            return;
        }

        _clearRetryAttempt++;
        _clearTimer.Interval = Math.Min(
            MaximumRetryIntervalMilliseconds,
            250 * (1 << Math.Min(_clearRetryAttempt - 1, 4)));
        _clearTimer.Start();
    }

    internal bool TryClearIfUnchanged()
    {
        if (_lastValue is null)
        {
            return true;
        }

        try
        {
            if (_clipboard.ContainsText() && _clipboard.GetText() == _lastValue)
            {
                _clipboard.Clear();
            }

            _lastValue = null;
            return true;
        }
        catch (ExternalException)
        {
            return false;
        }
    }
}

internal interface ISensitiveClipboardAccess
{
    void SetText(string value);

    bool ContainsText();

    string GetText();

    void Clear();
}

internal sealed class WindowsSensitiveClipboardAccess : ISensitiveClipboardAccess
{
    public void SetText(string value) => Clipboard.SetText(value);

    public bool ContainsText() => Clipboard.ContainsText();

    public string GetText() => Clipboard.GetText();

    public void Clear() => Clipboard.Clear();
}
