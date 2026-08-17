using QRCoder;

namespace EverVigil.UI;

internal static class QrCodeRenderer
{
    public static Bitmap Render(string value, int pixelsPerModule = 7)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(value, QRCodeGenerator.ECCLevel.Q);
        using var qrCode = new QRCode(data);
        return qrCode.GetGraphic(
            pixelsPerModule,
            Color.FromArgb(20, 22, 26),
            Color.White,
            drawQuietZones: true);
    }
}
