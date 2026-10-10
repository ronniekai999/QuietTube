using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace QuietTube.Core;

public sealed record Settings(int SchemaVersion, bool Enabled, DateTimeOffset? PausedUntilUtc, long Revision)
{
    public static Settings Default => new(1, true, null, 1);
    public bool IsEnabled(DateTimeOffset now) => Enabled && (PausedUntilUtc is null || PausedUntilUtc <= now);
    public string Label(DateTimeOffset now) => !Enabled ? "Protection off" : !IsEnabled(now) ? "Protection paused" : "Protection on";
}

public sealed class SettingsStore(string directory)
{
    private readonly string path = Path.Combine(Path.GetFullPath(directory), "settings.json");
    private readonly string mutexName = "QuietTube.State." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(directory))))[..24];

    private T Locked<T>(Func<T> action)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var mutex = new Mutex(false, mutexName);
        var acquired = false;
        try
        {
            try { acquired = mutex.WaitOne(TimeSpan.FromSeconds(5)); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) throw new IOException("Settings are busy. Please try again.");
            return action();
        }
        finally { if (acquired) mutex.ReleaseMutex(); }
    }

    private Settings ReadUnlocked()
    {
        if (!File.Exists(path))
        {
            AppPaths.WriteJsonAtomic(path, Settings.Default);
            return Settings.Default;
        }
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            foreach (var field in new[] { "schemaVersion", "enabled", "pausedUntilUtc", "revision" })
                if (!doc.RootElement.TryGetProperty(field, out _)) throw new JsonException("Missing setting: " + field);
            var state = JsonSerializer.Deserialize<Settings>(doc.RootElement.GetRawText(), Json.Options);
            if (state is null || state.SchemaVersion != 1 || state.Revision < 1) throw new JsonException("Unsupported settings format.");
            return state;
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException)
        {
            // Never silently re-enable protection after a corrupt settings file.
            throw new InvalidDataException("QuietTube settings could not be read. Preserve settings.json and reinstall or repair it.", ex);
        }
    }

    public Settings Read() => Locked(ReadUnlocked);
    public Settings SetProtection(bool enabled, int pauseMinutes = 0)
    {
        if (pauseMinutes is < 0 or > 1440) throw new ArgumentOutOfRangeException(nameof(pauseMinutes));
        return Locked(() =>
        {
            var previous = ReadUnlocked();
            var next = new Settings(1, enabled, enabled && pauseMinutes > 0 ? DateTimeOffset.UtcNow.AddMinutes(pauseMinutes) : null, checked(previous.Revision + 1));
            AppPaths.WriteJsonAtomic(path, next);
            return next;
        });
    }
}
