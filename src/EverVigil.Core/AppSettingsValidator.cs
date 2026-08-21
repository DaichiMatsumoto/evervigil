using System.Globalization;
using EverVigil.Core.Localization;

namespace EverVigil.Core;

public static class AppSettingsValidator
{
    public static IReadOnlyList<string> Validate(
        AppSettings settings,
        bool requireExistingPaths = true,
        CultureInfo? culture = null,
        bool requireTrustedTailscalePath = true)
    {
        ArgumentNullException.ThrowIfNull(settings);
        culture ??= AppLocalizer.ResolveCulture(settings.UiLanguage);
        var errors = new List<string>();

        if (string.IsNullOrWhiteSpace(settings.UiLanguage) ||
            !AppLocalizer.IsSupportedLanguage(settings.UiLanguage))
        {
            errors.Add(AppLocalizer.Text("ValidationLanguage", culture));
        }

        if (string.IsNullOrWhiteSpace(settings.DisplayName) || settings.DisplayName.Length > 64)
        {
            errors.Add(AppLocalizer.Text("ValidationDisplayName", culture));
        }

        ValidatePort(settings.PublicPort, AppLocalizer.Text("FieldPublicPort", culture), culture, errors);
        ValidatePort(settings.BackendPort, AppLocalizer.Text("FieldBackendPort", culture), culture, errors);
        ValidatePort(settings.CodexAppServerPort, AppLocalizer.Text("FieldCodexPort", culture), culture, errors);
        if (new[] { settings.PublicPort, settings.BackendPort, settings.CodexAppServerPort }
            .Distinct()
            .Count() != 3)
        {
            errors.Add(AppLocalizer.Text("ValidationDistinctPorts", culture));
        }

        ValidateRange(settings.HealthIntervalSeconds, 5, 3600, AppLocalizer.Text("FieldHealthInterval", culture), culture, errors);
        ValidateRange(settings.ProviderCheckIntervalSeconds, 15, 3600, AppLocalizer.Text("FieldProviderInterval", culture), culture, errors);
        ValidateRange(settings.PublicCheckIntervalSeconds, 15, 3600, AppLocalizer.Text("FieldTailnetInterval", culture), culture, errors);
        ValidateRange(settings.StartupTimeoutSeconds, 10, 600, AppLocalizer.Text("FieldStartupTimeout", culture), culture, errors);
        ValidateRange(settings.StableRunSeconds, 30, 3600, AppLocalizer.Text("FieldStableRun", culture), culture, errors);
        ValidateRange(settings.FailureThreshold, 1, 20, AppLocalizer.Text("FieldFailureThreshold", culture), culture, errors);
        ValidateRange(settings.LogFileSizeMb, 1, 100, AppLocalizer.Text("FieldLogLimit", culture), culture, errors);
        ValidateRange(settings.LogFileCopies, 1, 10, AppLocalizer.Text("FieldLogCopies", culture), culture, errors);
        ValidateRange(settings.ClipboardClearSeconds, 15, 600, AppLocalizer.Text("FieldClipboardClear", culture), culture, errors);

        ValidatePath(settings.NodePath, AppLocalizer.Text("FieldNodePath", culture), requireExistingPaths, File.Exists, culture, errors);
        ValidatePath(settings.EvenTerminalCliPath, AppLocalizer.Text("FieldEvenTerminalPath", culture), requireExistingPaths, File.Exists, culture, errors);
        ValidatePath(settings.CodexPath, AppLocalizer.Text("FieldCodexPath", culture), requireExistingPaths, File.Exists, culture, errors);
        ValidatePath(settings.TailscalePath, AppLocalizer.Text("FieldTailscalePath", culture), requireExistingPaths, File.Exists, culture, errors);
        if (requireTrustedTailscalePath &&
            (string.IsNullOrWhiteSpace(settings.TailscalePath) ||
             !Path.IsPathFullyQualified(settings.TailscalePath) ||
             !string.Equals(
                 Path.GetFullPath(settings.TailscalePath),
                 AppSettings.FixedTailscalePath,
                 StringComparison.OrdinalIgnoreCase)))
        {
            errors.Add(AppLocalizer.Format(
                culture,
                "ValidationTrustedTailscalePath",
                AppSettings.FixedTailscalePath));
        }

        return errors;
    }

    private static void ValidatePort(
        int value,
        string label,
        CultureInfo culture,
        List<string> errors) =>
        ValidateRange(value, 1024, 65535, label, culture, errors);

    private static void ValidateRange(
        int value,
        int minimum,
        int maximum,
        string label,
        CultureInfo culture,
        List<string> errors)
    {
        if (value < minimum || value > maximum)
        {
            errors.Add(AppLocalizer.Format(culture, "ValidationPortRange", label, minimum, maximum));
        }
    }

    private static void ValidatePath(
        string value,
        string label,
        bool requireExistingPaths,
        Func<string, bool> exists,
        CultureInfo culture,
        List<string> errors)
    {
        if (string.IsNullOrWhiteSpace(value) || !Path.IsPathFullyQualified(value))
        {
            errors.Add(AppLocalizer.Format(culture, "ValidationAbsolutePath", label));
            return;
        }

        if (requireExistingPaths && !exists(value))
        {
            errors.Add(AppLocalizer.Format(culture, "ValidationPathMissing", label, value));
        }
    }
}
