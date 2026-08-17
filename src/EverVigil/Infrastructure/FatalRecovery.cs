using System.Diagnostics;

namespace EverVigil.Infrastructure;

internal static class FatalRecovery
{
    private static int _restartStarted;

    public static void Register(
        string[] arguments,
        BoundedLogger logger,
        Func<bool> serviceIsRunning)
    {
        ArgumentNullException.ThrowIfNull(serviceIsRunning);
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, eventArgs) =>
        {
            logger.Error($"Unhandled UI exception: {eventArgs.Exception}");
            TryRestart(arguments, logger, serviceIsRunning());
            Environment.Exit(1);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
        {
            logger.Error($"Unhandled fatal exception: {eventArgs.ExceptionObject}");
            TryRestart(arguments, logger, serviceIsRunning());
        };
        TaskScheduler.UnobservedTaskException += (_, eventArgs) =>
        {
            logger.Error($"Unobserved task exception: {eventArgs.Exception}");
            eventArgs.SetObserved();
        };
    }

    public static void WaitForPreviousProcess(string[] arguments)
    {
        var value = GetArgument(arguments, "--wait-for-pid");
        if (!int.TryParse(value, out var processId))
        {
            return;
        }

        try
        {
            using var process = Process.GetProcessById(processId);
            process.WaitForExit(30_000);
        }
        catch (ArgumentException)
        {
            // The previous process has already exited.
        }
    }

    private static void TryRestart(
        string[] arguments,
        BoundedLogger logger,
        bool serviceWasRunning)
    {
        if (Interlocked.Exchange(ref _restartStarted, 1) != 0)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var windowValue = GetArgument(arguments, "--recover-window");
        var countValue = GetArgument(arguments, "--recover-count");
        var window = long.TryParse(windowValue, out var milliseconds)
            ? DateTimeOffset.FromUnixTimeMilliseconds(milliseconds)
            : now;
        var count = int.TryParse(countValue, out var parsedCount) ? parsedCount : 0;
        if (now - window > TimeSpan.FromMinutes(5))
        {
            window = now;
            count = 0;
        }

        if (count >= 3)
        {
            logger.Error("Fatal recovery suppressed after three crashes in five minutes.");
            return;
        }

        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable))
        {
            return;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = AppContext.BaseDirectory
        };
        startInfo.ArgumentList.Add("--background");
        if (serviceWasRunning)
        {
            startInfo.ArgumentList.Add("--force-start-service");
        }
        startInfo.ArgumentList.Add("--wait-for-pid");
        startInfo.ArgumentList.Add(Environment.ProcessId.ToString());
        startInfo.ArgumentList.Add("--recover-window");
        startInfo.ArgumentList.Add(window.ToUnixTimeMilliseconds().ToString());
        startInfo.ArgumentList.Add("--recover-count");
        startInfo.ArgumentList.Add((count + 1).ToString());
        Process.Start(startInfo);
    }

    private static string? GetArgument(string[] arguments, string name)
    {
        var index = Array.FindIndex(arguments, argument =>
            string.Equals(argument, name, StringComparison.OrdinalIgnoreCase));
        return index >= 0 && index + 1 < arguments.Length ? arguments[index + 1] : null;
    }
}
