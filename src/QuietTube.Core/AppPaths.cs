namespace QuietTube.Core;

public static class AppPaths
{
    public const string HostName = "com.quiettube.companion";
    public const string Version = "0.1.1";
    // The public key and exact extension ID are generated once and checked by the build.
    public static string ExtensionId => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "extension-id.txt")).Trim();
    public static string DataDirectory => Environment.GetEnvironmentVariable("QUIETTUBE_DATA_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "QuietTube", "data");
    public static string InstallDirectory => Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));
    public static string StateFile => Path.Combine(DataDirectory, "settings.json");
    public static string ClientsDirectory => Path.Combine(DataDirectory, "clients");
    public static string TrayHeartbeat => Path.Combine(DataDirectory, "tray.json");

    public static void WriteJsonAtomic<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, System.Text.Json.JsonSerializer.Serialize(value, Json.Options));
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

public static class Json
{
    public static readonly System.Text.Json.JsonSerializerOptions Options = new(System.Text.Json.JsonSerializerDefaults.Web)
    {
        WriteIndented = false
    };
}
