using System.Diagnostics;

namespace EverVigil.Infrastructure;

internal sealed record ProcessCommandResult(
    int ExitCode,
    string StandardOutput,
    string StandardError);

internal static class ProcessCommandRunner
{
    public static ProcessCommandResult Run(
        string executable,
        TimeSpan timeout,
        params string[] arguments)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executable);
        if (timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo) ??
            throw new InvalidOperationException($"Could not start {Path.GetFileName(executable)}.");
        var standardOutputTask = process.StandardOutput.ReadToEndAsync();
        var standardErrorTask = process.StandardError.ReadToEndAsync();
        var completionTask = Task.WhenAll(
            process.WaitForExitAsync(),
            standardOutputTask,
            standardErrorTask);

        try
        {
            completionTask.WaitAsync(timeout).GetAwaiter().GetResult();
        }
        catch (TimeoutException exception)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(5_000);
                }
            }
            catch
            {
                // Preserve the timeout as the primary failure.
            }

            throw new TimeoutException(
                $"{Path.GetFileName(executable)} did not exit within {timeout.TotalSeconds:0} seconds.",
                exception);
        }

        return new ProcessCommandResult(
            process.ExitCode,
            standardOutputTask.GetAwaiter().GetResult(),
            standardErrorTask.GetAwaiter().GetResult());
    }
}
