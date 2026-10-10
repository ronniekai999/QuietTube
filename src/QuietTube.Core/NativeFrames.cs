using System.Buffers.Binary;
using System.Text.Json;

namespace QuietTube.Core;

public static class NativeFrames
{
    public const int MaximumBytes = 64 * 1024;

    public static async Task<JsonDocument?> ReadAsync(Stream input, CancellationToken cancellationToken = default)
    {
        var header = new byte[4];
        var first = await input.ReadAsync(header.AsMemory(0, 1), cancellationToken);
        if (first == 0) return null;
        await input.ReadExactlyAsync(header.AsMemory(1, 3), cancellationToken);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (length == 0 || length > MaximumBytes) throw new InvalidDataException("Invalid native message length.");
        var payload = new byte[length];
        await input.ReadExactlyAsync(payload, cancellationToken);
        return JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 16 });
    }

    public static async Task WriteAsync(Stream output, SemaphoreSlim gate, object message, CancellationToken cancellationToken = default)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(message, Json.Options);
        if (payload.Length > MaximumBytes) throw new InvalidDataException("Native message exceeds the limit.");
        var header = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(header, (uint)payload.Length);
        await gate.WaitAsync(cancellationToken);
        try
        {
            await output.WriteAsync(header, cancellationToken);
            await output.WriteAsync(payload, cancellationToken);
            await output.FlushAsync(cancellationToken);
        }
        finally { gate.Release(); }
    }

    public static bool IsAllowedOrigin(string? origin, string extensionId) =>
        extensionId.Length == 32 && extensionId.All(c => c is >= 'a' and <= 'p')
        && origin == $"chrome-extension://{extensionId}/";
}
