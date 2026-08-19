using System.Reflection;

namespace EverVigil;

internal static class ApplicationMetadata
{
    internal const string ProductName = "EverVigil";
    internal const string LegalNotice =
        "This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.";
    internal const string Copyright = "Copyright \u00A9 2026 Daichi Matsumoto";
    internal const string LicenseName = "GNU GPL v3.0 only (Copyleft)";
    internal const string LicenseNotice =
        "Provided without warranty under GPL-3.0-only.";
    internal const string GitHubProfileUrl = "https://github.com/DaichiMatsumoto";
    internal const string RepositoryUrl = "https://github.com/DaichiMatsumoto/evervigil";
    internal const string LicenseUrl = RepositoryUrl + "/blob/main/LICENSE";

    internal static string Version
    {
        get
        {
            var assembly = typeof(ApplicationMetadata).Assembly;
            var informationalVersion = assembly
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
                .InformationalVersion;
            if (!string.IsNullOrWhiteSpace(informationalVersion))
            {
                var buildSeparator = informationalVersion.IndexOf('+', StringComparison.Ordinal);
                return buildSeparator >= 0
                    ? informationalVersion[..buildSeparator]
                    : informationalVersion;
            }

            return assembly.GetName().Version?.ToString(3) ?? "unknown";
        }
    }
}
