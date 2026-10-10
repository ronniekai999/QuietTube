using System.Diagnostics;
using System.Text.Json;
using Microsoft.Win32;
using QuietTube.Core;

namespace QuietTube.Tray;

internal sealed class MainWindow : Form
{
    private static readonly Color Background = Color.FromArgb(21, 26, 25);
    private static readonly Color Card = Color.FromArgb(32, 41, 35);
    private static readonly Color Accent = Color.FromArgb(184, 237, 156);
    private static readonly Color Muted = Color.FromArgb(186, 201, 188);
    private readonly SettingsStore store;
    private readonly Label title = TextLabel("Checking protection…", 23, true);
    private readonly Label detail = TextLabel("Checking the Windows companion.", 10);
    private readonly Label connections = TextLabel("Waiting for Edge…", 10);
    private readonly Button toggle = MakeButton("Turn protection off", true);
    private readonly Button pause = MakeButton("Pause 15 minutes");
    private readonly Label note = TextLabel("", 10);
    private Settings? latest;
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public bool AllowClose { get; set; }

    public MainWindow(SettingsStore store, Action quit)
    {
        this.store = store;
        Text = "QuietTube";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Shield;
        BackColor = Background;
        ForeColor = Color.FromArgb(237, 243, 237);
        Font = new Font("Segoe UI", 10);
        AutoScaleMode = AutoScaleMode.Dpi;
        MinimumSize = new Size(540, 640);
        Size = new Size(580, 690);
        StartPosition = FormStartPosition.CenterScreen;
        FormClosing += (_, e) =>
        {
            if (ClosePolicy.ShouldHide(AllowClose, (int)e.CloseReason)) { e.Cancel = true; Hide(); }
        };

        var root = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(28), ColumnCount = 1, RowCount = 9, AutoScroll = true };
        for (var i = 0; i < 9; i++) root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Controls.Add(root);
        var heading = TextLabel("QuietTube", 28, true);
        heading.ForeColor = Accent;
        root.Controls.Add(heading);
        root.Controls.Add(TextLabel("YouTube, with fewer interruptions.", 11));
        var protection = new TableLayoutPanel { Dock = DockStyle.Top, BackColor = Card, Padding = new Padding(20), AutoSize = true, ColumnCount = 1, Margin = new Padding(0, 22, 0, 16) };
        protection.Controls.Add(title);
        protection.Controls.Add(detail);
        root.Controls.Add(protection);
        var controlRow = Row(toggle, pause);
        toggle.Click += (_, _) => Change(() => store.SetProtection(!(latest?.IsEnabled(DateTimeOffset.UtcNow) ?? false)));
        pause.Click += (_, _) => Change(() => store.SetProtection(true, 15));
        root.Controls.Add(controlRow);
        var connectionBox = new TableLayoutPanel { Dock = DockStyle.Top, BackColor = Card, AutoSize = true, ColumnCount = 1, Padding = new Padding(16), Margin = new Padding(0, 16, 0, 14) };
        connectionBox.Controls.Add(TextLabel("BROWSER CONNECTION", 9, true));
        connectionBox.Controls.Add(connections);
        root.Controls.Add(connectionBox);

        var extensions = MakeButton("Edge extensions");
        extensions.Click += (_, _) => OpenEdge("edge://extensions/");
        var folder = MakeButton("Extension folder");
        folder.Click += (_, _) => OpenFile(Path.Combine(AppPaths.InstallDirectory, "extension"));
        var export = MakeButton("Export diagnostics");
        export.Click += (_, _) => ExportDiagnostics();
        root.Controls.Add(Row(extensions, folder, export));

        var startup = new CheckBox { Text = "Start QuietTube when I sign in to Windows", AutoSize = true, Margin = new Padding(0, 18, 0, 10), ForeColor = Muted };
        using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) startup.Checked = key?.GetValue("QuietTube") is string;
        startup.CheckedChanged += (_, _) => Change(() =>
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (startup.Checked) key.SetValue("QuietTube", $"\"{Application.ExecutablePath}\" --background");
            else key.DeleteValue("QuietTube", false);
        });
        root.Controls.Add(startup);
        note.ForeColor = Muted;
        note.Text = "Load the installed extension once in Edge, then reload YouTube.\nClosing this window keeps QuietTube in the system tray.";
        root.Controls.Add(note);
        var updates = MakeButton("Check upstream updates");
        updates.Click += async (_, _) => await CheckUpdates(updates);
        var help = MakeButton("Setup help");
        help.Click += (_, _) => OpenFile(Path.Combine(AppPaths.InstallDirectory, "START-HERE.html"));
        var exit = MakeButton("Quit tray app");
        exit.Click += (_, _) => quit();
        root.Controls.Add(Row(updates, help, exit));
        toggle.AccessibleName = "Toggle YouTube protection";
        pause.AccessibleName = "Pause YouTube protection for 15 minutes";
    }

    public void RefreshStatus(Settings state, IReadOnlyList<ClientStatus> clients)
    {
        latest = state;
        var now = DateTimeOffset.UtcNow;
        title.Text = state.Label(now);
        detail.Text = state.IsEnabled(now) ? "Waiting for each browser to confirm filtering is ready." : state.Enabled && state.PausedUntilUtc is not null
            ? "Resumes at " + state.PausedUntilUtc.Value.ToLocalTime().ToString("t") + ". Reload an open video after changing protection."
            : "YouTube loads without QuietTube filtering. Reload an open video after changing protection.";
        toggle.Text = state.IsEnabled(now) ? "Turn protection off" : "Turn protection on";
        pause.Enabled = state.IsEnabled(now);
        var fresh = clients.Where(c => c.IsFresh(now)).ToList();
        if (fresh.Count == 0)
        {
            connections.Text = "Waiting for Edge. Load QuietTube in Edge’s Extensions page.\nIf it is already loaded, open its popup and choose Reconnect.";
        }
        else
        {
            connections.Text = string.Join("\n", fresh.Select((client, index) =>
                client.Error is not null ? $"{client.Browser} profile {index + 1}: {client.Error}"
                : client.IsConfirmed(state, now) ? $"{client.Browser} profile {index + 1}: {(state.IsEnabled(now) ? "filtering ready" : "pause/off confirmed")}"
                : $"{client.Browser} profile {index + 1}: synchronizing protection…"));
            if (state.IsEnabled(now) && fresh.All(c => c.IsConfirmed(state, now))) detail.Text = "Connected browsers have confirmed the YouTube filtering engine is active.\nReload any video that was already open.";
        }
    }

    public void ShowError(string message) { title.Text = "Needs attention"; detail.Text = message; }

    private void Change(Action action)
    {
        try { action(); RefreshStatus(store.Read(), ClientStore.ReadAll()); }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "QuietTube", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    public void ExportDiagnostics()
    {
        try
        {
            using var dialog = new SaveFileDialog { Title = "Save QuietTube diagnostics", Filter = "JSON file (*.json)|*.json", FileName = "QuietTube-diagnostics-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json" };
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            using var engine = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "engine-metadata.json")));
            File.WriteAllText(dialog.FileName, JsonSerializer.Serialize(new
            {
                appVersion = AppPaths.Version, createdAtUtc = DateTimeOffset.UtcNow, os = Environment.OSVersion.VersionString,
                settings = store.Read(), clients = ClientStore.ReadAll(), engine = engine.RootElement,
                privacy = "No browsing history, video URLs, account cookies, or page contents are collected."
            }, new JsonSerializerOptions(Json.Options) { WriteIndented = true }));
            MessageBox.Show(this, "Diagnostics saved. This file contains connection and protection status, without browsing history or account cookies.", "QuietTube");
        }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "QuietTube", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    private async Task CheckUpdates(Button button)
    {
        button.Enabled = false;
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            client.DefaultRequestHeaders.UserAgent.ParseAdd("QuietTube/" + AppPaths.Version);
            using var document = JsonDocument.Parse(await client.GetStringAsync("https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest"));
            var release = document.RootElement.GetProperty("tag_name").GetString();
            using var engine = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "engine-metadata.json")));
            var current = engine.RootElement.GetProperty("version").GetString();
            MessageBox.Show(this, $"Packaged filtering build: {current}\nLatest published upstream release: {release}\n\nQuietTube uses a modified extension. Apply fixes using a newer QuietTube ZIP, then reload the extension in Edge. This test build does not install upstream packages automatically.", "Filtering updates");
        }
        catch (Exception ex) { MessageBox.Show(this, "Could not check upstream updates: " + ex.Message, "QuietTube"); }
        finally { button.Enabled = true; }
    }

    public static void OpenEdge(string url)
    {
        try { Process.Start(new ProcessStartInfo("msedge.exe", url) { UseShellExecute = true }); }
        catch (Exception ex) { MessageBox.Show("Open Microsoft Edge and navigate to " + url + "\n" + ex.Message, "QuietTube"); }
    }

    private static void OpenFile(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) { MessageBox.Show(ex.Message, "QuietTube"); }
    }

    private static Label TextLabel(string text, float size, bool bold = false) => new()
    {
        Text = text, AutoSize = true, MaximumSize = new Size(470, 0), Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular),
        ForeColor = Muted, Margin = new Padding(0, 4, 0, 8), AccessibleName = text
    };

    private static Button MakeButton(string text, bool primary = false) => new()
    {
        Text = text, AutoSize = true, MinimumSize = new Size(110, 38), FlatStyle = FlatStyle.Flat,
        BackColor = primary ? Accent : Card, ForeColor = primary ? Color.FromArgb(23, 48, 28) : Muted,
        Padding = new Padding(8, 5, 8, 5), Margin = new Padding(0, 0, 8, 8), UseVisualStyleBackColor = false
    };

    private static FlowLayoutPanel Row(params Control[] controls)
    {
        var row = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true, Margin = new Padding(0) };
        row.Controls.AddRange(controls);
        return row;
    }
}
