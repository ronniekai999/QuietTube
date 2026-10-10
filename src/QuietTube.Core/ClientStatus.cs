using System.Text.Json;

namespace QuietTube.Core;

public sealed record ClientStatus(string ClientId, string Browser, string ExtensionVersion, string EngineVersion,
    bool AppliedEnabled, long AppliedRevision, int YoutubeMode, int EnabledRulesets, int RegisteredScripts,
    string? Error, DateTimeOffset LastSeenUtc)
{
    public bool IsFresh(DateTimeOffset now) => now - LastSeenUtc < TimeSpan.FromSeconds(70);
    public bool IsConfirmed(Settings settings, DateTimeOffset now) => IsFresh(now) && Error is null
        && AppliedEnabled == settings.IsEnabled(now) && AppliedRevision == settings.Revision
        && YoutubeMode == (AppliedEnabled ? 2 : 0) && (AppliedEnabled ? EnabledRulesets > 0 && RegisteredScripts > 0 : RegisteredScripts == 0);
}

public static class ClientStore
{
    public static void Save(ClientStatus client)
    {
        if (!Guid.TryParse(client.ClientId, out _)) throw new ArgumentException("Invalid client ID.");
        AppPaths.WriteJsonAtomic(Path.Combine(AppPaths.ClientsDirectory, Guid.Parse(client.ClientId).ToString("N") + ".json"), client);
    }

    public static IReadOnlyList<ClientStatus> ReadAll()
    {
        if (!Directory.Exists(AppPaths.ClientsDirectory)) return [];
        var clients = new List<ClientStatus>();
        foreach (var file in Directory.EnumerateFiles(AppPaths.ClientsDirectory, "*.json").Take(100))
        {
            try
            {
                var item = JsonSerializer.Deserialize<ClientStatus>(File.ReadAllText(file), Json.Options);
                if (item is not null) clients.Add(item);
            }
            catch (Exception ex) when (ex is IOException or JsonException) { }
        }
        return clients.OrderByDescending(c => c.LastSeenUtc).ToList();
    }

    public static bool IsTrayRunning()
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(AppPaths.TrayHeartbeat));
            return DateTimeOffset.UtcNow - doc.RootElement.GetProperty("seenAt").GetDateTimeOffset() < TimeSpan.FromSeconds(8);
        }
        catch (Exception ex) when (ex is IOException or JsonException or InvalidOperationException) { return false; }
    }
}
