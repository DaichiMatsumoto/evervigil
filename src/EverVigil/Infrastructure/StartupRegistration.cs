using System.Reflection;
using System.Runtime.InteropServices;
using EverVigil.Compatibility;

namespace EverVigil.Infrastructure;

internal sealed class StartupRegistration
{
    private readonly DataPaths _paths;

    public StartupRegistration(DataPaths paths) => _paths = paths;

    public event Action<bool>? RegistrationChanged;

    public bool IsRegistered => IsCurrentShortcutOwned() || IsLegacyShortcutOwned();

    public void Register()
    {
        var executable = Environment.ProcessPath ??
            throw new InvalidOperationException("Application executable path is unavailable.");
        Directory.CreateDirectory(Path.GetDirectoryName(_paths.StartupShortcutPath)!);

        if (File.Exists(_paths.StartupShortcutPath) && !IsShortcutOwnedBy(
                _paths.StartupShortcutPath,
                executable))
        {
            throw new InvalidOperationException(
                "The startup shortcut already exists but is not owned by EverVigil.");
        }

        var shellType = Type.GetTypeFromProgID("WScript.Shell") ??
            throw new InvalidOperationException("Windows Script Host is unavailable.");
        object? shell = null;
        object? shortcut = null;
        try
        {
            shell = Activator.CreateInstance(shellType);
            shortcut = shellType.InvokeMember(
                "CreateShortcut",
                BindingFlags.InvokeMethod,
                binder: null,
                target: shell,
                args: new object[] { _paths.StartupShortcutPath });
            var shortcutType = shortcut?.GetType() ??
                throw new InvalidOperationException("Could not create the startup shortcut.");
            SetProperty(shortcutType, shortcut, "TargetPath", executable);
            SetProperty(shortcutType, shortcut, "Arguments", "--background");
            SetProperty(shortcutType, shortcut, "WorkingDirectory", AppContext.BaseDirectory);
            SetProperty(
                shortcutType,
                shortcut,
                "Description",
                "An independent Windows tray utility that keeps Even Terminal running and available.");
            SetProperty(shortcutType, shortcut, "IconLocation", $"{executable},0");
            shortcutType.InvokeMember(
                "Save",
                BindingFlags.InvokeMethod,
                binder: null,
                target: shortcut,
                args: null);
            DeleteLegacyShortcut();
            RegistrationChanged?.Invoke(true);
        }
        finally
        {
            if (shortcut is not null && Marshal.IsComObject(shortcut))
            {
                Marshal.FinalReleaseComObject(shortcut);
            }

            if (shell is not null && Marshal.IsComObject(shell))
            {
                Marshal.FinalReleaseComObject(shell);
            }
        }
    }

    public void Unregister()
    {
        DeleteOwnedShortcut(_paths.StartupShortcutPath, Environment.ProcessPath);

        DeleteLegacyShortcut();

        RegistrationChanged?.Invoke(false);
    }

    private bool IsCurrentShortcutOwned() =>
        IsShortcutOwnedBy(_paths.StartupShortcutPath, Environment.ProcessPath);

    private bool IsLegacyShortcutOwned() =>
        IsShortcutOwnedBy(_paths.LegacyStartupShortcutPath, GetLegacyExecutablePath());

    private void DeleteLegacyShortcut()
    {
        DeleteOwnedShortcut(_paths.LegacyStartupShortcutPath, GetLegacyExecutablePath());
    }

    private static string GetLegacyExecutablePath()
    {
        return Path.Combine(
            AppContext.BaseDirectory,
            LegacyCompatibility.Application.ExecutableFileName);
    }

    private static void DeleteOwnedShortcut(string? shortcutPath, string? expectedTargetPath)
    {
        if (IsShortcutOwnedBy(shortcutPath, expectedTargetPath))
        {
            File.Delete(shortcutPath!);
        }
    }

    private static bool IsShortcutOwnedBy(string? shortcutPath, string? expectedTargetPath)
    {
        if (string.IsNullOrWhiteSpace(shortcutPath) ||
            string.IsNullOrWhiteSpace(expectedTargetPath) ||
            !File.Exists(shortcutPath))
        {
            return false;
        }

        var shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType is null)
        {
            return false;
        }

        object? shell = null;
        object? shortcut = null;
        try
        {
            shell = Activator.CreateInstance(shellType);
            shortcut = shellType.InvokeMember(
                "CreateShortcut",
                BindingFlags.InvokeMethod,
                binder: null,
                target: shell,
                args: new object[] { shortcutPath });
            if (shortcut is null)
            {
                return false;
            }

            var shortcutType = shortcut.GetType();
            var targetPath = GetStringProperty(shortcutType, shortcut, "TargetPath");
            var arguments = GetStringProperty(shortcutType, shortcut, "Arguments");
            return PathsEqual(targetPath, expectedTargetPath) &&
                string.Equals(arguments, "--background", StringComparison.Ordinal);
        }
        catch (Exception)
        {
            return false;
        }
        finally
        {
            if (shortcut is not null && Marshal.IsComObject(shortcut))
            {
                Marshal.FinalReleaseComObject(shortcut);
            }

            if (shell is not null && Marshal.IsComObject(shell))
            {
                Marshal.FinalReleaseComObject(shell);
            }
        }
    }

    private static string? GetStringProperty(Type type, object target, string name) =>
        type.InvokeMember(
            name,
            BindingFlags.GetProperty,
            binder: null,
            target: target,
            args: null) as string;

    private static bool PathsEqual(string? left, string right)
    {
        if (string.IsNullOrWhiteSpace(left))
        {
            return false;
        }

        var normalizedLeft = Path.GetFullPath(Environment.ExpandEnvironmentVariables(left));
        var normalizedRight = Path.GetFullPath(Environment.ExpandEnvironmentVariables(right));
        return string.Equals(normalizedLeft, normalizedRight, StringComparison.OrdinalIgnoreCase);
    }

    private static void SetProperty(Type type, object target, string name, object value) =>
        type.InvokeMember(
            name,
            BindingFlags.SetProperty,
            binder: null,
            target: target,
            args: new[] { value });
}
