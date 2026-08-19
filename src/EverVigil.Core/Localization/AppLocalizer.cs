using System.Globalization;
using System.Resources;

namespace EverVigil.Core.Localization;

public static class AppLocalizer
{
    public const string SystemLanguage = "system";
    public const string EnglishLanguage = "en";
    public const string JapaneseLanguage = "ja";

    private static readonly ResourceManager Resources = new(
        "EverVigil.Core.Localization.AppResources",
        typeof(AppLocalizer).Assembly);
    private static readonly object Gate = new();
    private static CultureInfo _culture = ResolveCulture(SystemLanguage);
    private static string _language = SystemLanguage;

    public static event EventHandler? LanguageChanged;

    public static string Language
    {
        get
        {
            lock (Gate)
            {
                return _language;
            }
        }
    }

    public static CultureInfo Culture
    {
        get
        {
            lock (Gate)
            {
                return _culture;
            }
        }
    }

    public static IReadOnlyList<string> SupportedLanguages { get; } =
        [SystemLanguage, EnglishLanguage, JapaneseLanguage];

    public static bool IsSupportedLanguage(string? language) =>
        SupportedLanguages.Contains(NormalizeLanguageCode(language), StringComparer.Ordinal);

    public static CultureInfo ResolveCulture(string? language)
    {
        var normalized = NormalizeLanguageCode(language);
        if (normalized == JapaneseLanguage)
        {
            return CultureInfo.GetCultureInfo("ja-JP");
        }

        if (normalized == EnglishLanguage)
        {
            return CultureInfo.GetCultureInfo("en-US");
        }

        return string.Equals(
            CultureInfo.CurrentUICulture.TwoLetterISOLanguageName,
            JapaneseLanguage,
            StringComparison.OrdinalIgnoreCase)
            ? CultureInfo.GetCultureInfo("ja-JP")
            : CultureInfo.GetCultureInfo("en-US");
    }

    public static void SetLanguage(string? language)
    {
        var normalized = NormalizeLanguageCode(language);
        if (!IsSupportedLanguage(normalized))
        {
            normalized = SystemLanguage;
        }

        var culture = ResolveCulture(normalized);
        var changed = false;
        lock (Gate)
        {
            if (!string.Equals(_language, normalized, StringComparison.Ordinal) ||
                !Equals(_culture, culture))
            {
                _language = normalized;
                _culture = culture;
                changed = true;
            }
        }

        if (changed)
        {
            LanguageChanged?.Invoke(null, EventArgs.Empty);
        }
    }

    public static string Text(string key) => Text(key, Culture);

    public static string Text(string key, CultureInfo culture)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        ArgumentNullException.ThrowIfNull(culture);
        return Resources.GetString(key, culture) ??
            Resources.GetString(key, CultureInfo.GetCultureInfo("en-US")) ??
            key;
    }

    public static string Format(string key, params object?[] arguments) =>
        Format(Culture, key, arguments);

    public static string Format(CultureInfo culture, string key, params object?[] arguments) =>
        string.Format(culture, Text(key, culture), arguments);

    private static string NormalizeLanguageCode(string? language)
    {
        if (string.IsNullOrWhiteSpace(language))
        {
            return SystemLanguage;
        }

        return language.Trim().ToLowerInvariant();
    }
}
