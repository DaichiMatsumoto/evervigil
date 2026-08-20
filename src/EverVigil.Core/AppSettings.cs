namespace EverVigil.Core;

public sealed record AppSettings
{
    public string UiLanguage { get; set; } = "system";

    public string DisplayName { get; set; } = Environment.MachineName;

    public int PublicPort { get; set; } = 3456;

    public int BackendPort { get; set; } = 3457;

    public int CodexAppServerPort { get; set; } = 8765;

    public string NodePath { get; set; } = string.Empty;

    public string EvenTerminalCliPath { get; set; } = string.Empty;

    public string CodexPath { get; set; } = string.Empty;

    public string TailscalePath { get; set; } = @"C:\Program Files\Tailscale\tailscale.exe";

    public int HealthIntervalSeconds { get; set; } = 30;

    public int ProviderCheckIntervalSeconds { get; set; } = 300;

    public int PublicCheckIntervalSeconds { get; set; } = 300;

    public int StartupTimeoutSeconds { get; set; } = 120;

    public int StableRunSeconds { get; set; } = 600;

    public int FailureThreshold { get; set; } = 3;

    public int LogFileSizeMb { get; set; } = 5;

    public int LogFileCopies { get; set; } = 3;

    public int ClipboardClearSeconds { get; set; } = 60;

    public bool DiagnosticLogging { get; set; }

    public bool AutoStartService { get; set; } = true;

    public static string FixedTailscalePath => Path.GetFullPath(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        "Tailscale",
        "tailscale.exe"));

    public static AppSettings CreateDefault() => CreateDefault(legacyInstallationRoot: null);

    public static AppSettings CreateDefault(string? legacyInstallationRoot)
    {
        var legacyAppsDirectory = GetLegacyAppsDirectory(legacyInstallationRoot);
        var tailscalePath = FixedTailscalePath;

        var nodePreferredPaths = new List<string>();
        if (legacyAppsDirectory is not null)
        {
            var legacyNodePath = Path.Combine(legacyAppsDirectory, "nodejs", "node.exe");
            if (File.Exists(legacyNodePath))
            {
                nodePreferredPaths.Add(legacyNodePath);
            }
        }
        nodePreferredPaths.Add(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "nodejs",
            "node.exe"));

        return new AppSettings
        {
            DisplayName = Environment.MachineName,
            NodePath = ResolveExecutable("node.exe", nodePreferredPaths.ToArray()),
            EvenTerminalCliPath = GetDefaultEvenTerminalCliPath(legacyAppsDirectory),
            CodexPath = GetDefaultCodexPath(),
            TailscalePath = tailscalePath
        };
    }

    private static string GetDefaultEvenTerminalCliPath(string? legacyAppsDirectory)
    {
        var relativeCliPath = Path.Combine(
            "node_modules",
            "@evenrealities",
            "even-terminal",
            "bin",
            "cli.js");
        if (legacyAppsDirectory is not null)
        {
            var legacyCliPath = Path.Combine(legacyAppsDirectory, "npm", relativeCliPath);
            if (File.Exists(legacyCliPath))
            {
                return Path.GetFullPath(legacyCliPath);
            }
        }

        var shimBackedCandidates = new List<string>();
        var fallbackCandidates = new List<string>
        {
            Path.Combine(
                GetKnownFolderPath(Environment.SpecialFolder.ApplicationData, "APPDATA"),
                "npm",
                relativeCliPath)
        };

        foreach (var directory in GetSearchDirectories())
        {
            var cliCandidate = Path.Combine(directory, relativeCliPath);
            fallbackCandidates.Add(cliCandidate);
            var shim = Path.Combine(directory, "even-terminal.cmd");
            if (File.Exists(shim))
            {
                shimBackedCandidates.Add(cliCandidate);
            }
        }

        var candidates = shimBackedCandidates
            .Concat(fallbackCandidates)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        return candidates.FirstOrDefault(File.Exists) ?? candidates[0];
    }

    private static string? GetLegacyAppsDirectory(
        string? legacyInstallationRoot)
    {
        if (string.IsNullOrWhiteSpace(legacyInstallationRoot))
        {
            return null;
        }

        var installationDirectory = new DirectoryInfo(Path.GetFullPath(legacyInstallationRoot));
        if (!installationDirectory.Exists ||
            !string.Equals(
                installationDirectory.Name,
                "even-terminal",
                StringComparison.OrdinalIgnoreCase) ||
            installationDirectory.Parent is not { } appsDirectory ||
            !string.Equals(appsDirectory.Name, "Apps", StringComparison.OrdinalIgnoreCase) ||
            !appsDirectory.Exists)
        {
            return null;
        }

        return appsDirectory.FullName;
    }

    private static string GetDefaultCodexPath()
    {
        var preferred = Path.Combine(
            GetKnownFolderPath(Environment.SpecialFolder.LocalApplicationData, "LOCALAPPDATA"),
            "Programs",
            "OpenAI",
            "Codex",
            "bin",
            "codex.exe");
        if (File.Exists(preferred))
        {
            return preferred;
        }

        foreach (var directory in GetSearchDirectories())
        {
            foreach (var fileName in new[] { "codex.exe", "codex.cmd" })
            {
                var candidate = Path.Combine(directory, fileName);
                if (File.Exists(candidate))
                {
                    return Path.GetFullPath(candidate);
                }
            }
        }

        return preferred;
    }

    private static string ResolveExecutable(string fileName, params string[] preferredPaths)
    {
        foreach (var candidate in preferredPaths.Concat(
                     GetSearchDirectories().Select(directory => Path.Combine(directory, fileName))))
        {
            if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        return preferredPaths.FirstOrDefault(path => !string.IsNullOrWhiteSpace(path)) ?? fileName;
    }

    private static IEnumerable<string> GetSearchDirectories()
    {
        var paths = new[]
        {
            Environment.GetEnvironmentVariable("PATH"),
            Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User),
            Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Machine)
        };

        return paths
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .SelectMany(path => path!.Split(
                Path.PathSeparator,
                StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .Select(path => path.Trim('"'))
            .Where(Directory.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase);
    }

    private static string GetKnownFolderPath(
        Environment.SpecialFolder folder,
        string environmentVariable)
    {
        var knownFolder = Environment.GetFolderPath(folder);
        if (!string.IsNullOrWhiteSpace(knownFolder))
        {
            return knownFolder;
        }

        var fallback = Environment.GetEnvironmentVariable(environmentVariable);
        return string.IsNullOrWhiteSpace(fallback)
            ? string.Empty
            : Path.GetFullPath(fallback);
    }

}
