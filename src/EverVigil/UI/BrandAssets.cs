namespace EverVigil.UI;

internal static class BrandAssets
{
    private const string LogoResourceName =
        "EverVigil.Assets.evervigil-placeholder-source.png";

    public static Bitmap LoadLogoBitmap()
    {
        using var stream = typeof(BrandAssets).Assembly.GetManifestResourceStream(LogoResourceName) ??
            throw new InvalidOperationException($"Embedded brand asset was not found: {LogoResourceName}");
        using var source = new Bitmap(stream);
        return new Bitmap(source);
    }
}
