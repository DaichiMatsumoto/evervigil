using System.Diagnostics;
using EverVigil.Core;

namespace EverVigil.Services;

internal static class BridgeProcessEnvironment
{
    private static readonly string[] BaseVariableNames =
    [
        "SystemRoot",
        "WINDIR",
        "SystemDrive",
        "ComSpec",
        "PATHEXT",
        "TEMP",
        "TMP",
        "USERPROFILE",
        "HOME",
        "HOMEDRIVE",
        "HOMEPATH",
        "LOCALAPPDATA",
        "APPDATA",
        "ProgramData",
        "ALLUSERSPROFILE",
        "ProgramFiles",
        "ProgramW6432",
        "ProgramFiles(x86)"
    ];

    private static readonly string[] ApplicationVariableNames =
    [
        "PORT",
        "BRIDGE_TOKEN",
        "EVEN_TERMINAL_NAME",
        "DEFAULT_PROVIDER",
        "EVEN_HOST_MODE",
        "CODEX_APP_SERVER_PORT",
        "PATH"
    ];

    private static readonly HashSet<string> AllowedVariableNames = BaseVariableNames
        .Concat(ApplicationVariableNames)
        .ToHashSet(StringComparer.OrdinalIgnoreCase);

    internal static void ConfigureLauncher(
        ProcessStartInfo startInfo,
        AppSettings settings,
        string token)
    {
        ArgumentNullException.ThrowIfNull(startInfo);
        ArgumentNullException.ThrowIfNull(settings);
        if (!TokenUtility.IsValid(token))
        {
            throw new ArgumentException("The bridge token is invalid.", nameof(token));
        }

        var environment = BuildBaseEnvironment();
        environment["PORT"] = ValidatePort(settings.BackendPort).ToString();
        environment["BRIDGE_TOKEN"] = token;
        environment["EVEN_TERMINAL_NAME"] = ValidateText(
            settings.DisplayName,
            64,
            "The bridge display name is invalid.");
        environment["DEFAULT_PROVIDER"] = "codex";
        environment["EVEN_HOST_MODE"] = "tailscale";
        environment["CODEX_APP_SERVER_PORT"] = ValidatePort(
            settings.CodexAppServerPort).ToString();
        environment["PATH"] = BuildExecutablePath(settings, environment);
        ReplaceEnvironment(startInfo, environment);
    }

    internal static void ConfigureBridgeChild(
        ProcessStartInfo startInfo,
        string backendPort,
        string displayName)
    {
        var inherited = ApplicationVariableNames.ToDictionary(
            name => name,
            Environment.GetEnvironmentVariable,
            StringComparer.OrdinalIgnoreCase);
        ConfigureBridgeChild(
            startInfo,
            inherited,
            backendPort,
            displayName);
    }

    internal static void ConfigureBridgeChild(
        ProcessStartInfo startInfo,
        IReadOnlyDictionary<string, string?> inherited,
        string backendPort,
        string displayName)
    {
        ArgumentNullException.ThrowIfNull(startInfo);
        ArgumentNullException.ThrowIfNull(inherited);

        var expectedBackendPort = ParsePort(backendPort);
        var environment = BuildBaseEnvironment();
        foreach (var name in ApplicationVariableNames)
        {
            if (!inherited.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
            {
                throw new InvalidOperationException(
                    $"A required bridge environment entry is missing: {name}");
            }
            environment[name] = value;
        }

        if (ParsePort(environment["PORT"]) != expectedBackendPort ||
            ParsePort(environment["CODEX_APP_SERVER_PORT"]) == expectedBackendPort ||
            !TokenUtility.IsValid(environment["BRIDGE_TOKEN"]) ||
            !string.Equals(
                ValidateText(environment["EVEN_TERMINAL_NAME"], 64, "The bridge display name is invalid."),
                displayName,
                StringComparison.Ordinal) ||
            !string.Equals(environment["DEFAULT_PROVIDER"], "codex", StringComparison.Ordinal) ||
            !string.Equals(environment["EVEN_HOST_MODE"], "tailscale", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("The bridge environment does not match its launch request.");
        }
        ValidateSearchPath(environment["PATH"]);
        ReplaceEnvironment(startInfo, environment);
    }

    internal static bool IsAllowedVariableName(string name) =>
        AllowedVariableNames.Contains(name);

    private static Dictionary<string, string> BuildBaseEnvironment()
    {
        var windows = ValidateFullPath(GetKnownFolderPath(
            Environment.SpecialFolder.Windows, "WINDIR", "SystemRoot"));
        var systemDirectory = ValidateFullPath(Environment.SystemDirectory);
        var systemDrive = Path.GetPathRoot(windows)?.TrimEnd(Path.DirectorySeparatorChar) ??
            throw new InvalidOperationException("The Windows system drive is unavailable.");
        if (systemDrive.Length != 2 || systemDrive[1] != Path.VolumeSeparatorChar)
        {
            throw new InvalidOperationException("The Windows system drive is invalid.");
        }

        var userProfile = ValidateFullPath(GetKnownFolderPath(
            Environment.SpecialFolder.UserProfile, "USERPROFILE"));
        var profileRoot = Path.GetPathRoot(userProfile) ??
            throw new InvalidOperationException("The Windows user profile root is unavailable.");
        var profileDrive = profileRoot.TrimEnd(Path.DirectorySeparatorChar);
        if (profileDrive.Length != 2 || profileDrive[1] != Path.VolumeSeparatorChar)
        {
            throw new InvalidOperationException("The Windows user profile drive is invalid.");
        }
        var homePath = userProfile[(profileRoot.Length - 1)..];

        var localAppData = ValidateFullPath(GetKnownFolderPath(
            Environment.SpecialFolder.LocalApplicationData, "LOCALAPPDATA"));
        var roamingAppData = ValidateFullPath(GetKnownFolderPath(
            Environment.SpecialFolder.ApplicationData, "APPDATA"));
        var commonAppData = ValidateFullPath(GetKnownFolderPath(
            Environment.SpecialFolder.CommonApplicationData, "ProgramData"));
        var programFiles = ValidateFullPath(GetKnownFolderPath(
            Environment.SpecialFolder.ProgramFiles, "ProgramFiles"));
        var programFilesX86 = GetKnownFolderPath(
            Environment.SpecialFolder.ProgramFilesX86, "ProgramFiles(x86)");
        var temp = ValidateFullPath(Path.Combine(localAppData, "Temp"));

        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["SystemRoot"] = windows,
            ["WINDIR"] = windows,
            ["SystemDrive"] = systemDrive,
            ["ComSpec"] = Path.Combine(systemDirectory, "cmd.exe"),
            ["PATHEXT"] = ".COM;.EXE;.BAT;.CMD",
            ["TEMP"] = temp,
            ["TMP"] = temp,
            ["USERPROFILE"] = userProfile,
            ["HOME"] = userProfile,
            ["HOMEDRIVE"] = profileDrive,
            ["HOMEPATH"] = homePath,
            ["LOCALAPPDATA"] = localAppData,
            ["APPDATA"] = roamingAppData,
            ["ProgramData"] = commonAppData,
            ["ALLUSERSPROFILE"] = commonAppData,
            ["ProgramFiles"] = programFiles,
            ["ProgramW6432"] = programFiles
        };
        if (!string.IsNullOrWhiteSpace(programFilesX86))
        {
            result["ProgramFiles(x86)"] = ValidateFullPath(programFilesX86);
        }
        return result;
    }

    private static string BuildExecutablePath(
        AppSettings settings,
        IReadOnlyDictionary<string, string> baseEnvironment)
    {
        var windows = baseEnvironment["WINDIR"];
        var systemDirectory = Path.Combine(windows, "System32");
        var directories = new[]
        {
            GetExecutableDirectory(settings.EvenTerminalCliPath),
            GetExecutableDirectory(settings.NodePath),
            GetExecutableDirectory(settings.CodexPath),
            GetExecutableDirectory(settings.TailscalePath),
            systemDirectory,
            windows,
            Path.Combine(systemDirectory, "WindowsPowerShell", "v1.0")
        };
        var path = string.Join(
            Path.PathSeparator,
            directories
                .Select(ValidateFullPath)
                .Distinct(StringComparer.OrdinalIgnoreCase));
        ValidateSearchPath(path);
        return path;
    }

    private static string GetExecutableDirectory(string executablePath)
    {
        var fullPath = ValidateFullPath(executablePath);
        return Path.GetDirectoryName(fullPath) ??
            throw new InvalidOperationException("An executable directory is unavailable.");
    }

    private static string GetKnownFolderPath(
        Environment.SpecialFolder folder,
        params string[] environmentVariables)
    {
        var knownFolder = Environment.GetFolderPath(folder);
        if (!string.IsNullOrWhiteSpace(knownFolder))
        {
            return knownFolder;
        }

        foreach (var environmentVariable in environmentVariables)
        {
            var fallback = Environment.GetEnvironmentVariable(environmentVariable);
            if (!string.IsNullOrWhiteSpace(fallback))
            {
                return Path.GetFullPath(fallback);
            }
        }

        return string.Empty;
    }

    private static void ReplaceEnvironment(
        ProcessStartInfo startInfo,
        IReadOnlyDictionary<string, string> environment)
    {
        startInfo.Environment.Clear();
        foreach (var entry in environment)
        {
            startInfo.Environment[entry.Key] = entry.Value;
        }
    }

    private static int ValidatePort(int port)
    {
        if (port is < 1024 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(port));
        }
        return port;
    }

    private static int ParsePort(string value)
    {
        if (!int.TryParse(value, out var port))
        {
            throw new InvalidOperationException("A bridge port is invalid.");
        }
        return ValidatePort(port);
    }

    private static string ValidateFullPath(string value)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Contains('\0') ||
            value.Contains('"') ||
            !Path.IsPathFullyQualified(value))
        {
            throw new InvalidOperationException("A bridge environment path is invalid.");
        }
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
    }

    private static string ValidateText(string value, int maximumLength, string message)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > maximumLength ||
            value.Any(char.IsControl))
        {
            throw new InvalidOperationException(message);
        }
        return value;
    }

    private static void ValidateSearchPath(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 32767)
        {
            throw new InvalidOperationException("The bridge search path is invalid.");
        }
        var entries = value.Split(Path.PathSeparator);
        if (entries.Length == 0 || entries.Any(entry =>
                string.IsNullOrWhiteSpace(entry) ||
                !Path.IsPathFullyQualified(entry) ||
                entry.Contains('"') ||
                entry.Contains('\0')))
        {
            throw new InvalidOperationException("The bridge search path is invalid.");
        }
    }
}
