namespace EverVigil.UI;

internal sealed class CyberPanel : Panel
{
    public CyberPanel()
    {
        DoubleBuffered = true;
        BackColor = AppTheme.Surface;
        ForeColor = AppTheme.Text;
        Padding = new Padding(14);
        Margin = new Padding(0);
    }

    public Color AccentColor { get; set; } = AppTheme.Neon;

    public bool ShowGrid { get; set; }

    protected override void OnPaint(PaintEventArgs args)
    {
        base.OnPaint(args);
        var bounds = ClientRectangle;
        if (bounds.Width <= 1 || bounds.Height <= 1)
        {
            return;
        }

        if (ShowGrid)
        {
            using var gridPen = new Pen(AppTheme.Grid);
            for (var x = 16; x < bounds.Width; x += 32)
            {
                args.Graphics.DrawLine(gridPen, x, 0, x, bounds.Height);
            }

            for (var y = 16; y < bounds.Height; y += 32)
            {
                args.Graphics.DrawLine(gridPen, 0, y, bounds.Width, y);
            }
        }

        using var borderPen = new Pen(AppTheme.Line);
        args.Graphics.DrawRectangle(borderPen, 0, 0, bounds.Width - 1, bounds.Height - 1);

        const int corner = 18;
        using var accentPen = new Pen(AccentColor, 2F);
        args.Graphics.DrawLine(accentPen, 0, 0, corner, 0);
        args.Graphics.DrawLine(accentPen, 0, 0, 0, corner);
        args.Graphics.DrawLine(
            accentPen,
            bounds.Width - 1 - corner,
            bounds.Height - 1,
            bounds.Width - 1,
            bounds.Height - 1);
        args.Graphics.DrawLine(
            accentPen,
            bounds.Width - 1,
            bounds.Height - 1 - corner,
            bounds.Width - 1,
            bounds.Height - 1);
    }
}
