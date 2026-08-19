namespace EverVigil.UI;

internal static class AppTheme
{
    // Matrix-inspired palette: near-black surfaces with restrained fluorescent green.
    public static readonly Color Void = Color.FromArgb(4, 12, 8);
    public static readonly Color Canvas = Color.FromArgb(7, 19, 12);
    public static readonly Color Surface = Color.FromArgb(10, 31, 18);
    public static readonly Color SurfaceElevated = Color.FromArgb(14, 48, 26);
    public static readonly Color Line = Color.FromArgb(27, 91, 49);
    public static readonly Color Grid = Color.FromArgb(16, 54, 31);
    public static readonly Color Text = Color.FromArgb(225, 255, 232);
    public static readonly Color Muted = Color.FromArgb(139, 191, 151);
    public static readonly Color Neon = Color.FromArgb(57, 255, 136);
    public static readonly Color Cyan = Color.FromArgb(112, 255, 178);
    public static readonly Color Amber = Color.FromArgb(216, 163, 75);
    public static readonly Color Danger = Color.FromArgb(222, 113, 127);
    public static readonly Color Ink = Text;
    public static readonly Color Online = Neon;
    public static readonly Color Starting = Cyan;
    public static readonly Color Degraded = Amber;
    public static readonly Color Faulted = Danger;
    public static readonly Color Stopped = Color.FromArgb(181, 180, 174);
    public static readonly Color OnlineAccent = Neon;
    public static readonly Color StartingAccent = Cyan;
    public static readonly Color DegradedAccent = Amber;
    public static readonly Color FaultedAccent = Danger;
    public static readonly Color StoppedAccent = Color.FromArgb(116, 122, 136);
}
