using QuietTube.Core;

namespace QuietTube.Tray;

internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon tray;
    private readonly MainWindow window;
    private readonly System.Windows.Forms.Timer timer;
    private readonly RegisteredWaitHandle showRegistration;
    private readonly ToolStripMenuItem toggle;
    private readonly ToolStripMenuItem pause;
    private readonly SettingsStore store = new(AppPaths.DataDirectory);
    private string? lastLabel;

    public TrayContext(EventWaitHandle showEvent, bool background)
    {
        window = new MainWindow(store, Quit);
        _ = window.Handle;
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open QuietTube", null, (_, _) => ShowWindow());
        toggle = new("Turn protection off", null, (_, _) => Change(() => store.SetProtection(!store.Read().IsEnabled(DateTimeOffset.UtcNow))));
        pause = new("Pause for 15 minutes", null, (_, _) => Change(() => store.SetProtection(true, 15)));
        menu.Items.Add(toggle);
        menu.Items.Add(pause);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Open YouTube in Edge", null, (_, _) => MainWindow.OpenEdge("https://www.youtube.com/"));
        menu.Items.Add("Export diagnostics…", null, (_, _) => window.ExportDiagnostics());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit tray app", null, (_, _) => Quit());
        tray = new NotifyIcon { Icon = window.Icon, Text = "QuietTube", ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += (_, _) => ShowWindow();
        showRegistration = ThreadPool.RegisterWaitForSingleObject(showEvent, (_, _) =>
        {
            if (!window.IsDisposed) window.BeginInvoke(ShowWindow);
        }, null, Timeout.Infinite, false);
        timer = new System.Windows.Forms.Timer { Interval = 1000 };
        timer.Tick += (_, _) => Refresh();
        timer.Start();
        Refresh();
        if (!background) ShowWindow();
    }

    private void Change(Action operation)
    {
        try { operation(); Refresh(); }
        catch (Exception ex) { MessageBox.Show(window, ex.Message, "QuietTube", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    private void ShowWindow() { window.Show(); window.WindowState = FormWindowState.Normal; window.Activate(); }

    private void Refresh()
    {
        try
        {
            AppPaths.WriteJsonAtomic(AppPaths.TrayHeartbeat, new { seenAt = DateTimeOffset.UtcNow, pid = Environment.ProcessId });
            var state = store.Read();
            var now = DateTimeOffset.UtcNow;
            var clients = ClientStore.ReadAll();
            window.RefreshStatus(state, clients);
            var confirmed = clients.Any(c => c.IsConfirmed(state, now));
            var label = state.Label(now);
            tray.Text = $"QuietTube — {label}";
            toggle.Text = state.IsEnabled(now) ? "Turn protection off" : "Resume protection";
            pause.Enabled = state.IsEnabled(now);
            // Tray presence never implies the browser has acknowledged a change.
            if (lastLabel != label + confirmed)
            {
                lastLabel = label + confirmed;
                tray.Icon = confirmed ? window.Icon : SystemIcons.Information;
            }
        }
        catch (Exception ex) { window.ShowError(ex.Message); tray.Text = "QuietTube — needs attention"; }
    }

    private void Quit()
    {
        timer.Stop();
        tray.Visible = false;
        window.AllowClose = true;
        window.Close();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            showRegistration.Unregister(null);
            timer.Dispose();
            tray.Dispose();
            window.Dispose();
            try { File.Delete(AppPaths.TrayHeartbeat); } catch (IOException) { }
        }
        base.Dispose(disposing);
    }
}
