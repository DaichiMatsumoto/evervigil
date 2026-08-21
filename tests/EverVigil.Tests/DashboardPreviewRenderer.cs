using System.Reflection;
using EverVigil.Core;
using EverVigil.Core.Localization;
using EverVigil.Infrastructure;
using EverVigil.Services;
using EverVigil.UI;

internal static class DashboardPreviewRenderer
{
    public static int Render(string outputPath, int tabIndex, string language)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                RenderCore(Path.GetFullPath(outputPath), tabIndex, language);
            }
            catch (Exception exception)
            {
                failure = exception;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
        {
            Console.Error.WriteLine(failure);
            return 1;
        }

        Console.WriteLine($"Dashboard preview: {Path.GetFullPath(outputPath)}");
        return 0;
    }

    private static void RenderCore(string outputPath, int tabIndex, string language)
    {
        AppLocalizer.SetLanguage(language);
        var root = Path.Combine(Path.GetTempPath(), $"EverVigilPreview-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var paths = new DataPaths(
                root,
                Path.Combine(root, "settings.json"),
                Path.Combine(root, "token.dat"),
                Path.Combine(root, "Logs"),
                Path.Combine(root, "Logs", "evervigil.log"),
                Path.Combine(root, "Startup", "EverVigil.lnk"));
            var dependencyRoot = Path.Combine(root, "Dependencies");
            Directory.CreateDirectory(dependencyRoot);
            var nodePath = CreatePlaceholder(dependencyRoot, "node.exe");
            var cliPath = CreatePlaceholder(dependencyRoot, "cli.js");
            var codexPath = CreatePlaceholder(dependencyRoot, "codex.exe");
            var tailscalePath = CreatePlaceholder(dependencyRoot, "tailscale.exe");

            var settingsStore = new SettingsStore(paths);
            var settings = AppSettings.CreateDefault() with
            {
                UiLanguage = language,
                DisplayName = "PREVIEW DEVICE",
                NodePath = nodePath,
                EvenTerminalCliPath = cliPath,
                CodexPath = codexPath,
                TailscalePath = tailscalePath
            };
            settingsStore.Save(settings);
            settingsStore.MarkSystemConfigurationApplied(settings);
            var tokenStore = new TokenStore(paths);
            string? token = null;
            var logger = new BoundedLogger(paths, () => settingsStore.Current, () => token);
            token = tokenStore.GetOrCreate();
            using var healthProbe = new HealthProbe();
            var supervisor = new SupervisorEngine(settingsStore, tokenStore, logger, healthProbe);
            try
            {
                var startupRegistration = new StartupRegistration(paths);
                using var form = new DashboardForm(
                    settingsStore,
                    tokenStore,
                    supervisor,
                    startupRegistration,
                    logger,
                    paths);
                form.StartPosition = FormStartPosition.Manual;
                form.Location = new Point(-32_000, -32_000);
                form.ShowInTaskbar = false;
                form.Show();
                Application.DoEvents();
                var tabs = (TabControl)(typeof(DashboardForm)
                    .GetField("_tabs", BindingFlags.Instance | BindingFlags.NonPublic)?
                    .GetValue(form) ?? throw new InvalidOperationException("Dashboard tabs were not found."));
                tabs.SelectedIndex = Math.Clamp(tabIndex, 0, tabs.TabPages.Count - 1);
                if (tabs.SelectedIndex == 1)
                {
                    typeof(DashboardForm)
                        .GetMethod("ToggleSecrets", BindingFlags.Instance | BindingFlags.NonPublic)?
                        .Invoke(form, null);
                }
                form.PerformLayout();
                Application.DoEvents();

                Directory.CreateDirectory(Path.GetDirectoryName(outputPath) ?? ".");
                using var bitmap = new Bitmap(form.Width, form.Height);
                form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
                bitmap.Save(outputPath, System.Drawing.Imaging.ImageFormat.Png);
                form.Hide();
            }
            finally
            {
                supervisor.DisposeAsync().AsTask().GetAwaiter().GetResult();
            }
        }
        finally
        {
            if (Directory.Exists(root) &&
                Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    private static string CreatePlaceholder(string directory, string fileName)
    {
        var path = Path.Combine(directory, fileName);
        File.WriteAllText(path, string.Empty);
        return path;
    }
}
