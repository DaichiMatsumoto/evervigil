namespace EverVigil.UI;

internal static class AppTheme
{
    // Independently selected placeholder palette, shared with the temporary icon.
    public static readonly Color Void = Color.FromArgb(21, 24, 36);
    public static readonly Color Canvas = Color.FromArgb(29, 33, 48);
    public static readonly Color Surface = Color.FromArgb(37, 42, 59);
    public static readonly Color SurfaceElevated = Color.FromArgb(48, 54, 75);
    public static readonly Color Line = Color.FromArgb(80, 90, 115);
    public static readonly Color Grid = Color.FromArgb(52, 58, 76);
    public static readonly Color Text = Color.FromArgb(247, 243, 232);
    public static readonly Color Muted = Color.FromArgb(167, 169, 180);
    public static readonly Color Neon = Color.FromArgb(79, 159, 142);
    public static readonly Color Cyan = Color.FromArgb(138, 180, 200);
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
