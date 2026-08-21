using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using EverVigil.Core;
using EverVigil.Infrastructure;

namespace EverVigil.Services;

internal sealed class ManagedBridgeProcess : IAsyncDisposable
{
    private readonly Process _process;
    private readonly Process _launcherProcess;
    private readonly WindowsJobObject _job;
    private readonly BoundedLogger _logger;
    private readonly object _lifecycleGate = new();
    private Task? _stopTask;
    private Task? _disposeTask;

    private ManagedBridgeProcess(
        Process process,
        Process launcherProcess,
        WindowsJobObject job,
        BoundedLogger logger)
    {
        _process = process;
        _launcherProcess = launcherProcess;
        _job = job;
        _logger = logger;
    }

    public int Id => _process.Id;

    public bool HasExited
    {
        get
        {
            try
            {
                return _process.HasExited;
            }
            catch (InvalidOperationException)
            {
                return true;
            }
        }
    }

    public int? ExitCode => HasExited ? _process.ExitCode : null;

    public static ManagedBridgeProcess Start(
        AppSettings settings,
        string token,
        BoundedLogger logger,
        string internalWorkingDirectory,
        string? launcherExecutable = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(internalWorkingDirectory);
        launcherExecutable ??= Environment.ProcessPath ??
            throw new InvalidOperationException("Application executable path is unavailable.");
        internalWorkingDirectory = PrepareInternalWorkingDirectory(internalWorkingDirectory);
        var launchId = Guid.NewGuid().ToString("N");
        var gateName = $"Local\\EverVigil-Launch-{launchId}";
        var pipeName = $"EverVigil-Pid-{launchId}";
        using var launchGate = new EventWaitHandle(false, EventResetMode.ManualReset, gateName);
        using var pidPipe = new NamedPipeServerStream(
            pipeName,
            PipeDirection.In,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

        var startInfo = new ProcessStartInfo
        {
            FileName = launcherExecutable,
            WorkingDirectory = internalWorkingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        startInfo.ArgumentList.Add("--bridge-launcher");
        startInfo.ArgumentList.Add("--bridge-gate");
        startInfo.ArgumentList.Add(gateName);
        startInfo.ArgumentList.Add("--bridge-pid-pipe");
        startInfo.ArgumentList.Add(pipeName);
        startInfo.ArgumentList.Add("--bridge-node-path");
        startInfo.ArgumentList.Add(settings.NodePath);
        startInfo.ArgumentList.Add("--bridge-cli-path");
        startInfo.ArgumentList.Add(settings.EvenTerminalCliPath);
        startInfo.ArgumentList.Add("--bridge-backend-port");
        startInfo.ArgumentList.Add(settings.BackendPort.ToString());
        startInfo.ArgumentList.Add("--bridge-display-name");
        startInfo.ArgumentList.Add(settings.DisplayName);

        BridgeProcessEnvironment.ConfigureLauncher(startInfo, settings, token);

        var launcherProcess = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        var job = new WindowsJobObject();
        Process? process = null;
        try
        {
            if (!launcherProcess.Start())
            {
                throw new InvalidOperationException("Bridge launcher did not start.");
            }

            job.Assign(launcherProcess);
            launchGate.Set();

            using var launchTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            pidPipe.WaitForConnectionAsync(launchTimeout.Token).GetAwaiter().GetResult();
            RequirePipeClientProcess(pidPipe, launcherProcess.Id);
            using var reader = new StreamReader(
                pidPipe,
                Encoding.UTF8,
                detectEncodingFromByteOrderMarks: true,
                bufferSize: 1024,
                leaveOpen: true);
            var pidValue = reader.ReadLineAsync(launchTimeout.Token).AsTask().GetAwaiter().GetResult();
            if (!int.TryParse(pidValue, out var processId) || processId <= 0)
            {
                throw new InvalidOperationException("Bridge launcher returned an invalid process ID.");
            }

            process = Process.GetProcessById(processId);
            if (!job.Contains(process))
            {
                throw new InvalidOperationException(
                    "The bridge launcher returned a process outside its supervisor job object.");
            }
            var actualNodePath = process.MainModule?.FileName ?? string.Empty;
            if (!string.Equals(
                    Path.GetFullPath(actualNodePath),
                    Path.GetFullPath(settings.NodePath),
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Bridge launcher returned an unexpected process.");
            }

            var managed = new ManagedBridgeProcess(process, launcherProcess, job, logger);
            launcherProcess.OutputDataReceived += managed.OnOutput;
            launcherProcess.ErrorDataReceived += managed.OnError;
            launcherProcess.BeginOutputReadLine();
            launcherProcess.BeginErrorReadLine();
            logger.Info($"Even Terminal started pid={process.Id} backendPort={settings.BackendPort}");
            return managed;
        }
        catch
        {
            try
            {
                job.Terminate();
            }
            catch
            {
                // Best-effort cleanup after a failed launch.
            }

            try
            {
                if (launcherProcess.Id != 0 && !launcherProcess.HasExited)
                {
                    launcherProcess.Kill(entireProcessTree: true);
                }
            }
            catch
            {
                // The launcher may not have started or may already have exited.
            }

            process?.Dispose();
            launcherProcess.Dispose();
            job.Dispose();
            throw;
        }
    }

    public Task WaitForExitAsync(CancellationToken cancellationToken) =>
        _process.WaitForExitAsync(cancellationToken);

    public Task StopAsync()
    {
        lock (_lifecycleGate)
        {
            return _stopTask ??= StopCoreAsync();
        }
    }

    public ValueTask DisposeAsync()
    {
        lock (_lifecycleGate)
        {
            _stopTask ??= StopCoreAsync();
            _disposeTask ??= DisposeCoreAsync(_stopTask);
            return new ValueTask(_disposeTask);
        }
    }

    private async Task StopCoreAsync()
    {
        try
        {
            if (!HasExited)
            {
                _job.Terminate();
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                await _process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            if (!HasExited)
            {
                _process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception exception)
        {
            _logger.Warn($"Process shutdown fallback: {exception.Message}");
            try
            {
                if (!HasExited)
                {
                    _process.Kill(entireProcessTree: true);
                }
            }
            catch
            {
                // The process may already have exited.
            }
        }
    }

    private async Task DisposeCoreAsync(Task stopTask)
    {
        await stopTask.ConfigureAwait(false);
        _launcherProcess.OutputDataReceived -= OnOutput;
        _launcherProcess.ErrorDataReceived -= OnError;
        _process.Dispose();
        _launcherProcess.Dispose();
        _job.Dispose();
    }

    private void OnOutput(object sender, DataReceivedEventArgs args)
    {
        if (!string.IsNullOrWhiteSpace(args.Data))
        {
            _logger.Diagnostic(Truncate(args.Data));
        }
    }

    private void OnError(object sender, DataReceivedEventArgs args)
    {
        if (!string.IsNullOrWhiteSpace(args.Data))
        {
            _logger.Warn($"Even Terminal: {Truncate(args.Data)}");
        }
    }

    private static string Truncate(string value) => value.Length <= 4000 ? value : value[..4000];

    internal static string PrepareInternalWorkingDirectory(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (!Path.IsPathFullyQualified(path))
        {
            throw new InvalidOperationException(
                "The internal bridge working directory must be fully qualified.");
        }

        var fullPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        var parent = Directory.GetParent(fullPath);
        if (parent is null || !parent.Exists ||
            (parent.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidOperationException(
                "The internal bridge host parent is unavailable or redirected.");
        }
        if (File.Exists(fullPath) ||
            (Directory.Exists(fullPath) &&
             (File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0))
        {
            throw new InvalidOperationException(
                "The internal bridge host path is not a regular directory.");
        }

        AccessControlService.RestrictDirectory(fullPath);
        parent.Refresh();
        if (!parent.Exists ||
            (parent.Attributes & FileAttributes.ReparsePoint) != 0 ||
            (File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidOperationException(
                "The internal bridge host path was redirected.");
        }
        return fullPath;
    }

    internal static int GetPipeClientProcessId(NamedPipeServerStream pipe)
    {
        ArgumentNullException.ThrowIfNull(pipe);
        if (!pipe.IsConnected)
        {
            throw new InvalidOperationException("The bridge PID pipe is not connected.");
        }

        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var processId) ||
            processId == 0 ||
            processId > int.MaxValue)
        {
            throw new InvalidOperationException(
                "The bridge PID pipe client identity could not be verified.");
        }

        return checked((int)processId);
    }

    internal static void RequirePipeClientProcess(
        NamedPipeServerStream pipe,
        int expectedProcessId)
    {
        if (expectedProcessId <= 0 || GetPipeClientProcessId(pipe) != expectedProcessId)
        {
            throw new InvalidOperationException(
                "The bridge PID pipe was connected by an unexpected process.");
        }
    }

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(
        Microsoft.Win32.SafeHandles.SafePipeHandle pipe,
        out uint clientProcessId);
}
