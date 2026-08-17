using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using EverVigil.Core;

namespace EverVigil.UI;

internal static class TrayIconFactory
{
    public static Icon Create(SupervisorState state)
    {
        var color = state switch
        {
            SupervisorState.Online => AppTheme.OnlineAccent,
            SupervisorState.Degraded => AppTheme.DegradedAccent,
            SupervisorState.Starting or SupervisorState.Restarting => AppTheme.StartingAccent,
            SupervisorState.Faulted => AppTheme.FaultedAccent,
            _ => AppTheme.StoppedAccent
        };

        using var source = BrandAssets.LoadLogoBitmap();
        using var bitmap = new Bitmap(32, 32);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Transparent);
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.DrawImage(source, new Rectangle(0, 0, 32, 32));

            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var borderBrush = new SolidBrush(Color.White);
            using var statusBrush = new SolidBrush(color);
            graphics.FillEllipse(borderBrush, 21, 21, 11, 11);
            graphics.FillEllipse(statusBrush, 23, 23, 7, 7);
        }

        var handle = bitmap.GetHicon();
        try
        {
            using var temporary = Icon.FromHandle(handle);
            return (Icon)temporary.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}
