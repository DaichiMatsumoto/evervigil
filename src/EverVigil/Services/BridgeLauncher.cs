using System.Diagnostics;
using System.IO.Pipes;
using System.Text;

namespace EverVigil.Services;

internal static class BridgeLauncher
{
    private static readonly TimeSpan GateTimeout = TimeSpan.FromSeconds(30);

    public static int Run(string[] arguments)
    {
        Process? process = null;
        try
        {
            var gateName = GetRequiredArgument(arguments, "--bridge-gate");
            var pidPipeName = GetRequiredArgument(arguments, "--bridge-pid-pipe");
            var nodePath = GetRequiredArgument(arguments, "--bridge-node-path");
            var cliPath = GetRequiredArgument(arguments, "--bridge-cli-path");
            var backendPort = GetRequiredArgument(arguments, "--bridge-backend-port");
            var displayName = GetRequiredArgument(arguments, "--bridge-display-name");

            using var gate = EventWaitHandle.OpenExisting(gateName);
            if (!gate.WaitOne(GateTimeout))
            {
                Console.Error.WriteLine("Bridge launch gate timed out.");
                return 2;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = nodePath,
                WorkingDirectory = Environment.CurrentDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            BridgeProcessEnvironment.ConfigureBridgeChild(
                startInfo,
                backendPort,
                displayName);
            startInfo.ArgumentList.Add(cliPath);
            startInfo.ArgumentList.Add("--port");
            startInfo.ArgumentList.Add(backendPort);
            startInfo.ArgumentList.Add("--name");
            startInfo.ArgumentList.Add(displayName);
            startInfo.ArgumentList.Add("--provider");
            startInfo.ArgumentList.Add("codex");
            startInfo.ArgumentList.Add("--tailscale");
            startInfo.ArgumentList.Add("--log-file");
            startInfo.ArgumentList.Add(@"\\.\NUL");

            process = Process.Start(startInfo) ??
                throw new InvalidOperationException("Even Terminal process did not start.");
            // The upstream process prints its full token, connection URL, and a
            // machine-readable QR code to stdout during startup. None of that
            // output is safe to forward into EverVigil's diagnostic logger.
            // Drain both streams to avoid blocking the child, but never relay or
            // persist them. EverVigil observes health and exit state separately.
            var outputTask = process.StandardOutput.BaseStream.CopyToAsync(Stream.Null);
            var errorTask = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
            using var pipe = new NamedPipeClientStream(
                ".",
                pidPipeName,
                PipeDirection.Out,
                PipeOptions.Asynchronous);
            pipe.Connect(10_000);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true);
            writer.WriteLine(process.Id);
            writer.Flush();
            process.WaitForExit();
            Task.WhenAll(outputTask, errorTask).GetAwaiter().GetResult();
            return process.ExitCode;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"Bridge launcher failed: {exception.Message}");
            try
            {
                if (process is { HasExited: false })
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(5_000);
                }
            }
            catch
            {
                // The supervisor's job object remains the final cleanup boundary.
            }
            return 1;
        }
        finally
        {
            process?.Dispose();
        }
    }

    private static string GetRequiredArgument(string[] arguments, string name)
    {
        var index = Array.FindIndex(arguments, argument =>
            string.Equals(argument, name, StringComparison.OrdinalIgnoreCase));
        if (index < 0 || index + 1 >= arguments.Length || string.IsNullOrWhiteSpace(arguments[index + 1]))
        {
            throw new ArgumentException($"Required launcher argument is missing: {name}");
        }

        return arguments[index + 1];
    }
}
