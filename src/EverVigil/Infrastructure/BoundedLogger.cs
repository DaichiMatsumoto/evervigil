using System.Globalization;
using EverVigil.Core;

namespace EverVigil.Infrastructure;

internal sealed class BoundedLogger
{
    private readonly object _gate = new();
    private readonly DataPaths _paths;
    private readonly Func<AppSettings> _settingsProvider;
    private readonly Func<string?> _tokenProvider;

    public BoundedLogger(
        DataPaths paths,
        Func<AppSettings> settingsProvider,
        Func<string?> tokenProvider)
    {
        _paths = paths;
        _settingsProvider = settingsProvider;
        _tokenProvider = tokenProvider;
        AccessControlService.RestrictDirectory(paths.LogRoot);
    }

    public void Info(string message) => Write("INFO", message);

    public void Warn(string message) => Write("WARN", message);

    public void Error(string message) => Write("ERROR", message);

    public void Clear()
    {
        lock (_gate)
        {
            File.Delete(_paths.LogPath);
            foreach (var (path, _) in EnumerateRotatedLogs())
            {
                File.Delete(path);
            }
        }
    }

    public void Diagnostic(string message)
    {
        if (_settingsProvider().DiagnosticLogging)
        {
            Write("DEBUG", message);
        }
    }

    private void Write(string level, string message)
    {
        lock (_gate)
        {
            try
            {
                RotateIfNeeded();
                var safeMessage = SecretRedactor.Redact(
                        message.Replace('\r', ' ').Replace('\n', ' '),
                        _tokenProvider() ?? string.Empty)
                    .Trim();
                var line = $"[{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}] [{level}] {safeMessage}";
                File.AppendAllText(_paths.LogPath, line + Environment.NewLine);
                AccessControlService.RestrictFile(_paths.LogPath);
            }
            catch
            {
                // Logging must never terminate the supervisor.
            }
        }
    }

    private void RotateIfNeeded()
    {
        var settings = _settingsProvider();
        PruneExcessGenerations(settings.LogFileCopies);
        if (!File.Exists(_paths.LogPath))
        {
            return;
        }

        var limit = settings.LogFileSizeMb * 1024L * 1024L;
        if (new FileInfo(_paths.LogPath).Length < limit)
        {
            return;
        }

        for (var index = settings.LogFileCopies; index >= 1; index--)
        {
            var source = index == 1 ? _paths.LogPath : $"{_paths.LogPath}.{index - 1}";
            var destination = $"{_paths.LogPath}.{index}";
            if (!File.Exists(source))
            {
                continue;
            }

            File.Move(source, destination, overwrite: true);
        }
    }

    private void PruneExcessGenerations(int retainedCopies)
    {
        foreach (var (path, generation) in EnumerateRotatedLogs())
        {
            if (generation > retainedCopies)
            {
                File.Delete(path);
            }
        }
    }

    private IEnumerable<(string Path, int Generation)> EnumerateRotatedLogs()
    {
        var baseName = Path.GetFileName(_paths.LogPath);
        var prefix = $"{baseName}.";
        foreach (var path in Directory.EnumerateFiles(_paths.LogRoot, $"{baseName}.*"))
        {
            var fileName = Path.GetFileName(path);
            if (!fileName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var suffix = fileName[prefix.Length..];
            if (int.TryParse(
                    suffix,
                    NumberStyles.None,
                    CultureInfo.InvariantCulture,
                    out var generation) &&
                generation > 0)
            {
                yield return (path, generation);
            }
        }
    }
}
