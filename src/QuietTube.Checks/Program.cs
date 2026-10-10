using System.Buffers.Binary;
using System.Text.Json;
using QuietTube.Core;

var parent = args.FirstOrDefault() ?? Path.GetTempPath();
var directory = Path.Combine(parent, "quiettube-checks-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(directory);
var passed = new List<string>();
var failed = new List<string>();
await Check("Saved off state survives a new store", () =>
{
    var folder = Path.Combine(directory, "persist");
    var store = new SettingsStore(folder);
    Assert(store.Read().Enabled, "New installs should enable protection.");
    var off = store.SetProtection(false);
    var reopened = new SettingsStore(folder).Read();
    Assert(!reopened.IsEnabled(DateTimeOffset.UtcNow) && reopened.Revision == off.Revision, "Off state was not preserved.");
    return Task.CompletedTask;
});
await Check("Pause expires and explicit off does not expire", () =>
{
    var now = DateTimeOffset.UtcNow;
    var paused = new Settings(1, true, now.AddMinutes(15), 2);
    Assert(!paused.IsEnabled(now) && paused.IsEnabled(now.AddMinutes(16)), "Pause expiration is incorrect.");
    Assert(!new Settings(1, false, null, 3).IsEnabled(now.AddYears(1)), "Explicit off must remain off.");
    var store = new SettingsStore(Path.Combine(directory, "pause"));
    store.SetProtection(true, 15);
    Assert(store.SetProtection(true).PausedUntilUtc is null, "Resume must clear pause.");
    return Task.CompletedTask;
});
await Check("Concurrent controllers preserve every revision", async () =>
{
    var folder = Path.Combine(directory, "race");
    var store = new SettingsStore(folder);
    var before = store.Read().Revision;
    await Task.WhenAll(Enumerable.Range(0, 40).Select(i => Task.Run(() => new SettingsStore(folder).SetProtection(i % 2 == 0))));
    Assert(store.Read().Revision == before + 40, "Concurrent writes lost a revision.");
});
await Check("Corrupt or incomplete settings fail visibly", () =>
{
    var folder = Path.Combine(directory, "corrupt");
    Directory.CreateDirectory(folder);
    foreach (var invalid in new[] { "{bad-json", "{}", "{\"schemaVersion\":2,\"enabled\":false,\"pausedUntilUtc\":null,\"revision\":1}" })
    {
        File.WriteAllText(Path.Combine(folder, "settings.json"), invalid);
        AssertThrows<InvalidDataException>(() => new SettingsStore(folder).Read());
        Assert(File.ReadAllText(Path.Combine(folder, "settings.json")) == invalid, "Corrupt settings were overwritten.");
    }
    return Task.CompletedTask;
});
await Check("Native messages round-trip and clean EOF is accepted", async () =>
{
    using var stream = new MemoryStream();
    using var gate = new SemaphoreSlim(1);
    await NativeFrames.WriteAsync(stream, gate, new { type = "hello", value = "π" });
    stream.Position = 0;
    using var message = await NativeFrames.ReadAsync(stream);
    Assert(message!.RootElement.GetProperty("value").GetString() == "π", "UTF-8 frame corrupted.");
    Assert(await NativeFrames.ReadAsync(stream) is null, "Clean EOF should finish the host.");
});
await Check("Partial native frames are rejected", async () =>
{
    using var header = new MemoryStream(new byte[] { 4, 0 });
    await AssertThrowsAsync<EndOfStreamException>(async () => { using var _ = await NativeFrames.ReadAsync(header); });
    using var body = new MemoryStream(new byte[] { 8, 0, 0, 0, 123, 125 });
    await AssertThrowsAsync<EndOfStreamException>(async () => { using var _ = await NativeFrames.ReadAsync(body); });
});
await Check("Zero, oversized, and malformed native payloads are rejected", async () =>
{
    foreach (var length in new uint[] { 0, NativeFrames.MaximumBytes + 1u, uint.MaxValue })
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, length);
        using var stream = new MemoryStream(bytes);
        await AssertThrowsAsync<InvalidDataException>(async () => { using var _ = await NativeFrames.ReadAsync(stream); });
    }
    using var badJson = new MemoryStream(new byte[] { 1, 0, 0, 0, 123 });
    await AssertThrowsAsync<JsonException>(async () => { using var _ = await NativeFrames.ReadAsync(badJson); });
});
await Check("Native origin is restricted to the exact extension", () =>
{
    var id = new string('a', 32);
    Assert(NativeFrames.IsAllowedOrigin("chrome-extension://" + id + "/", id), "Valid origin rejected.");
    foreach (var origin in new[] { "https://youtube.com/", "chrome-extension://" + new string('b', 32) + "/", "chrome-extension://" + id + "/evil", "chrome-extension://" + id })
        Assert(!NativeFrames.IsAllowedOrigin(origin, id), "Unexpected origin accepted.");
    return Task.CompletedTask;
});
await Check("Connection alone never counts as confirmed protection", () =>
{
    var state = new Settings(1, true, null, 5);
    var now = DateTimeOffset.UtcNow;
    var client = new ClientStatus(Guid.NewGuid().ToString(), "Edge", "0.1.1", "test", true, 5, 2, 1, 1, null, now);
    Assert(client.IsConfirmed(state, now), "Valid acknowledgment rejected.");
    Assert(!(client with { AppliedRevision = 4 }).IsConfirmed(state, now), "Old revision counted as ready.");
    Assert(!(client with { RegisteredScripts = 0 }).IsConfirmed(state, now), "Missing scripts counted as ready.");
    Assert(!(client with { Error = "failed" }).IsConfirmed(state, now), "Failed engine counted as ready.");
    Assert(!client.IsConfirmed(state, now.AddMinutes(2)), "Stale connection counted as ready.");
    var off = new Settings(1, false, null, 5);
    var disabledClient = client with { AppliedEnabled = false, YoutubeMode = 0, RegisteredScripts = 0 };
    Assert(disabledClient.IsConfirmed(off, now), "Applied off state rejected.");
    Assert(!(disabledClient with { RegisteredScripts = 1 }).IsConfirmed(off, now), "Residual YouTube script counted as disabled.");
    return Task.CompletedTask;
});
await Check("Windows shutdown and application exit are never cancelled by close-to-tray", () =>
{
    // WinForms CloseReason: UserClosing=3, WindowsShutDown=1,
    // TaskManagerClosing=4, ApplicationExitCall=6.
    Assert(ClosePolicy.ShouldHide(false, 3), "Closing the window should hide it in the tray.");
    foreach (var reason in new[] { 0, 1, 2, 4, 5, 6 })
        Assert(!ClosePolicy.ShouldHide(false, reason), "A system or application close was cancelled.");
    Assert(!ClosePolicy.ShouldHide(true, 3), "Explicit Quit must close the app.");
    return Task.CompletedTask;
});
Console.WriteLine(JsonSerializer.Serialize(new { passed, failed }, new JsonSerializerOptions { WriteIndented = true }));
return failed.Count == 0 ? 0 : 1;

async Task Check(string name, Func<Task> test)
{
    try { await test(); passed.Add(name); }
    catch (Exception ex) { failed.Add(name + ": " + ex.Message); }
}
static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
static void AssertThrows<T>(Action action) where T : Exception
{
    try { action(); } catch (T) { return; }
    throw new Exception("Expected " + typeof(T).Name);
}
static async Task AssertThrowsAsync<T>(Func<Task> action) where T : Exception
{
    try { await action(); } catch (T) { return; }
    throw new Exception("Expected " + typeof(T).Name);
}
