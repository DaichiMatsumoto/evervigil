namespace EverVigil.UI;

internal sealed class CyberTabControl : TabControl
{
    public CyberTabControl()
    {
        DrawMode = TabDrawMode.OwnerDrawFixed;
        ItemSize = new Size(118, 36);
        SizeMode = TabSizeMode.Fixed;
        Padding = new Point(0, 0);
        DoubleBuffered = true;
    }

    protected override void OnDrawItem(DrawItemEventArgs args)
    {
        var selected = args.Index == SelectedIndex;
        var bounds = GetTabRect(args.Index);
        using var background = new SolidBrush(selected ? AppTheme.SurfaceElevated : AppTheme.Canvas);
        args.Graphics.FillRectangle(background, bounds);

        if (selected)
        {
            using var accent = new SolidBrush(AppTheme.Neon);
            args.Graphics.FillRectangle(accent, bounds.Left + 10, bounds.Bottom - 3, bounds.Width - 20, 2);
        }

        using var font = new Font(
            "Cascadia Mono",
            8.5F,
            selected ? FontStyle.Bold : FontStyle.Regular);
        TextRenderer.DrawText(
            args.Graphics,
            TabPages[args.Index].Text,
            font,
            bounds,
            selected ? AppTheme.Neon : AppTheme.Muted,
            TextFormatFlags.HorizontalCenter |
            TextFormatFlags.VerticalCenter |
            TextFormatFlags.NoPrefix |
            TextFormatFlags.EndEllipsis);
    }

    protected override void OnSelectedIndexChanged(EventArgs args)
    {
        base.OnSelectedIndexChanged(args);
        Invalidate();
    }
}
