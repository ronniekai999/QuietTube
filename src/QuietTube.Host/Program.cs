using System.Text.Json;
using QuietTube.Core;

var store = new SettingsStore(AppPaths.DataDirectory);
if (args.Length == 2 && args[0] == "--set-enabled" && bool.TryParse(args[1], out var cliEnabled))
{
    Console.WriteLine(JsonSerializer.Serialize(store.SetProtection(cliEnabled), Json.Options));
    return 0;
}
if (args.Length == 1 && args[0] == "--status")
{
    Console.WriteLine(JsonSerializer.Serialize(new { settings = store.Read(), clients = ClientStore.ReadAll() }, Json.Options));
    return 0;
}
if (!NativeFrames.IsAllowedOrigin(args.FirstOrDefault(), AppPaths.ExtensionId))
{
    Console.Error.WriteLine("QuietTube native host must be launched by its registered browser extension.");
    return 2;
}

using var input = Console.OpenStandardInput();
using var output = Console.OpenStandardOutput();
using var writeGate = new SemaphoreSlim(1);
using var stateGate = new SemaphoreSlim(1);
using var stop = new CancellationTokenSource();
string? clientId = null;
string? lastSignature = null;
var browserName = "Chrome";
var extensionVersion = "unknown";
var engineVersion = "unknown";

Dictionary<string, object?> StateMessage()
{
    var state = store.Read();
    return new() { ["type"] = "state", ["requestId"] = null, ["schemaVersion"] = 1, ["enabled"] = state.Enabled,
        ["pausedUntilUtc"] = state.PausedUntilUtc, ["revision"] = state.Revision,
        ["effectiveEnabled"] = state.IsEnabled(DateTimeOffset.UtcNow), ["appRunning"] = ClientStore.IsTrayRunning(), ["appVersion"] = AppPaths.Version };
}

async Task SendState(string? requestId = null, bool onlyIfChanged = false)
{
    // Serialize snapshot creation as well as writing, so a watcher cannot send
    // an older revision after a command has already acknowledged a newer one.
    await stateGate.WaitAsync(stop.Token);
    try
    {
        var message = StateMessage();
        var signature = JsonSerializer.Serialize(message, Json.Options);
        if (onlyIfChanged && signature == lastSignature) return;
        message["requestId"] = requestId;
        await NativeFrames.WriteAsync(output, writeGate, message, stop.Token);
        lastSignature = signature;
    }
    finally { stateGate.Release(); }
}

var watcher = Task.Run(async () =>
{
    var lastPing = DateTimeOffset.UtcNow;
    try
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        while (await timer.WaitForNextTickAsync(stop.Token))
        {
            if (clientId is null) continue;
            await SendState(onlyIfChanged: true);
            if (DateTimeOffset.UtcNow - lastPing > TimeSpan.FromSeconds(20))
            {
                await NativeFrames.WriteAsync(output, writeGate, new { type = "ping" }, stop.Token);
                lastPing = DateTimeOffset.UtcNow;
            }
        }
    }
    catch (OperationCanceledException) { }
    catch (Exception ex)
    {
        Console.Error.WriteLine("QuietTube state watcher: " + ex.Message);
        stop.Cancel();
    }
});

try
{
    while (!stop.IsCancellationRequested)
    {
        using var message = await NativeFrames.ReadAsync(input, stop.Token);
        if (message is null) break;
        var body = message.RootElement;
        if (body.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Expected a message object.");
        var requestId = body.TryGetProperty("requestId", out var id) && id.ValueKind == JsonValueKind.String ? id.GetString() : null;
        if (requestId?.Length > 80) throw new InvalidDataException("Invalid request ID.");
        try
        {
            switch (body.GetProperty("type").GetString())
            {
                case "hello":
                    var incomingId = body.GetProperty("clientId").GetString();
                    if (!Guid.TryParse(incomingId, out _)) throw new InvalidDataException("Invalid client ID.");
                    clientId = incomingId;
                    browserName = body.GetProperty("browser").GetString() == "Edge" ? "Edge" : "Chrome";
                    extensionVersion = Bounded(body, "extensionVersion", 40);
                    engineVersion = Bounded(body, "engineVersion", 60);
                    await SendState(requestId);
                    break;
                case "getState":
                    RequireHello();
                    await SendState(requestId);
                    break;
                case "setProtection":
                    RequireHello();
                    var enabled = body.GetProperty("enabled").GetBoolean();
                    var minutes = body.TryGetProperty("pauseMinutes", out var pause) ? pause.GetInt32() : 0;
                    store.SetProtection(enabled, minutes);
                    await SendState(requestId);
                    break;
                case "status":
                    RequireHello();
                    var error = body.TryGetProperty("error", out var err) && err.ValueKind == JsonValueKind.String ? err.GetString() : null;
                    if (error?.Length > 300) error = error[..300];
                    var mode = body.GetProperty("youtubeMode").GetInt32();
                    var count = body.GetProperty("enabledRulesets").GetInt32();
                    var scripts = body.GetProperty("registeredScripts").GetInt32();
                    if (mode is < 0 or > 3 || count is < 0 or > 100 || scripts is < 0 or > 10000) throw new InvalidDataException("Invalid filtering status.");
                    ClientStore.Save(new(clientId!, browserName, extensionVersion, engineVersion,
                        body.GetProperty("appliedEnabled").GetBoolean(), body.GetProperty("appliedRevision").GetInt64(),
                        mode, count, scripts, error, DateTimeOffset.UtcNow));
                    break;
                default:
                    throw new InvalidDataException("Unsupported native command.");
            }
        }
        catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or KeyNotFoundException or ArgumentException or IOException or OverflowException)
        {
            await NativeFrames.WriteAsync(output, writeGate, new { type = "error", requestId, message = ex.Message }, stop.Token);
        }
    }
    return 0;
}
catch (Exception ex) when (ex is JsonException or IOException or OperationCanceledException or InvalidDataException or InvalidOperationException)
{
    Console.Error.WriteLine("QuietTube native host: " + ex.Message);
    return 3;
}
finally
{
    stop.Cancel();
    await watcher;
}

void RequireHello()
{
    if (clientId is null) throw new InvalidDataException("Send hello before commands.");
}

static string Bounded(JsonElement message, string property, int maximum)
{
    var text = message.GetProperty(property).GetString();
    if (string.IsNullOrWhiteSpace(text) || text.Length > maximum) throw new InvalidDataException("Invalid " + property + ".");
    return text;
}
