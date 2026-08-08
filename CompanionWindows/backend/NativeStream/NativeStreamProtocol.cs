using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VisionVNC.Hotspot.Backend.NativeStream;

/// <summary>
/// C# port of <c>Shared/MacNativeStreamProtocol.swift</c> — the framed wire
/// protocol the visionOS viewer speaks on port 4857. Framing is
/// <c>[UInt32 LE length][UInt8 type][payload]</c> where length counts the type
/// byte plus the payload. All multi-byte fields are little-endian; JSON
/// payloads use the Swift Codable key names (camelCase properties).
/// </summary>
public static class NativeStreamProtocol
{
    public const ushort DefaultPort = 4857;
    public const int ProtocolVersion = 2;
    /// <summary>Stream ID of the whole-desktop stream; real window IDs are never 0.</summary>
    public const uint DesktopStreamId = 0;
    public const uint MaxFrameBytes = 64 * 1024 * 1024;
    public const int FrameLengthPrefixSize = 4;

    public enum FrameType : byte
    {
        KeepAlive = 0x07,
        Hello = 0x10,
        HelloAck = 0x11,
        FormatDescription = 0x20, // v1 legacy desktop format (CoreMedia blob) — never sent by this host
        VideoFrame = 0x21,        // v1 legacy desktop video — never sent by this host
        Replaced = 0x30,
        Error = 0x31,
        MouseMove = 0x40,
        MouseDown = 0x41,
        MouseUp = 0x42,
        Scroll = 0x43,
        KeyDown = 0x44,
        KeyUp = 0x45,
        MouseStatus = 0x46,
        KeyboardStatus = 0x47,
        WindowList = 0x50,
        WindowStreamStart = 0x51,
        WindowStreamStop = 0x52,
        WindowFormatDescription = 0x53,
        WindowVideoFrame = 0x54,
        WindowClosed = 0x55,
        FocusWindow = 0x56,
        WindowMouseMove = 0x60,
        WindowMouseDown = 0x61,
        WindowMouseUp = 0x62,
        WindowScroll = 0x63,
    }

    public enum FormatKind : byte
    {
        /// <summary>CoreMedia big-endian ImageDescription blob (macOS hosts).</summary>
        CoreMediaImageDescription = 0,
        /// <summary>Concatenated Annex-B HEVC VPS/SPS/PPS; samples are 4-byte
        /// big-endian length-prefixed NAL units. What this host sends.</summary>
        HevcParameterSets = 1,
    }

    public enum RemoteControlStatus : byte
    {
        Available = 0,
        Disabled = 1,
        AccessibilityDenied = 2, // macOS concept; unused here
    }

    public enum MouseButton : byte
    {
        Left = 0,
        Right = 1,
        Other = 2,
    }

    public sealed record Hello
    {
        [JsonPropertyName("deviceName")] public string DeviceName { get; init; } = "";
        [JsonPropertyName("protocolVersion")] public int? Version { get; init; }
    }

    public sealed record HelloAck
    {
        [JsonPropertyName("protocolVersion")] public int Version { get; init; } = ProtocolVersion;
        [JsonPropertyName("platform")] public string Platform { get; init; } = "windows";
        /// <summary>"hidUsage": the client sends raw USB HID keyboard usages.</summary>
        [JsonPropertyName("keyCodeSpace")] public string KeyCodeSpace { get; init; } = "hidUsage";
        [JsonPropertyName("supportsWindowStreams")] public bool SupportsWindowStreams { get; init; } = true;
        [JsonPropertyName("supportsTransparentDesktop")] public bool SupportsTransparentDesktop { get; init; }
    }

    public sealed record WindowInfo
    {
        [JsonPropertyName("id")] public uint Id { get; init; }
        [JsonPropertyName("title")] public string Title { get; init; } = "";
        [JsonPropertyName("appName")] public string AppName { get; init; } = "";
        /// <summary>Window size in host points (device-independent pixels).</summary>
        [JsonPropertyName("width")] public double Width { get; init; }
        [JsonPropertyName("height")] public double Height { get; init; }
        [JsonPropertyName("isFocused")] public bool IsFocused { get; init; }
    }

    private sealed record WindowInventory
    {
        [JsonPropertyName("windows")] public List<WindowInfo> Windows { get; init; } = new();
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    // MARK: Encoding

    public static byte[] EncodeFrame(FrameType type, ReadOnlySpan<byte> payload = default)
    {
        var frame = new byte[FrameLengthPrefixSize + 1 + payload.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(frame, (uint)(1 + payload.Length));
        frame[4] = (byte)type;
        payload.CopyTo(frame.AsSpan(5));
        return frame;
    }

    public static byte[] EncodeHelloAck(HelloAck ack) =>
        EncodeFrame(FrameType.HelloAck, JsonSerializer.SerializeToUtf8Bytes(ack, JsonOpts));

    public static byte[] EncodeWindowInventory(IEnumerable<WindowInfo> windows) =>
        EncodeFrame(
            FrameType.WindowList,
            JsonSerializer.SerializeToUtf8Bytes(new WindowInventory { Windows = windows.ToList() }, JsonOpts));

    public static byte[] EncodeWindowFormatDescription(uint windowId, FormatKind kind, ReadOnlySpan<byte> data)
    {
        var payload = new byte[5 + data.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(payload, windowId);
        payload[4] = (byte)kind;
        data.CopyTo(payload.AsSpan(5));
        return EncodeFrame(FrameType.WindowFormatDescription, payload);
    }

    public static byte[] EncodeWindowVideoFrame(
        uint windowId, ReadOnlySpan<byte> data, bool isKeyFrame, ulong sequence, ulong ptsNanos)
    {
        var payload = new byte[21 + data.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(payload, windowId);
        payload[4] = (byte)(isKeyFrame ? 1 : 0);
        BinaryPrimitives.WriteUInt64LittleEndian(payload.AsSpan(5), sequence);
        BinaryPrimitives.WriteUInt64LittleEndian(payload.AsSpan(13), ptsNanos);
        data.CopyTo(payload.AsSpan(21));
        return EncodeFrame(FrameType.WindowVideoFrame, payload);
    }

    public static byte[] EncodeWindowClosed(uint windowId, string? reason)
    {
        var reasonBytes = reason is null ? Array.Empty<byte>() : Encoding.UTF8.GetBytes(reason);
        var payload = new byte[4 + reasonBytes.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(payload, windowId);
        reasonBytes.CopyTo(payload.AsSpan(4));
        return EncodeFrame(FrameType.WindowClosed, payload);
    }

    public static byte[] EncodeStatus(FrameType type, RemoteControlStatus status) =>
        EncodeFrame(type, new[] { (byte)status });

    public static byte[] EncodeReplaced(string deviceName) =>
        EncodeFrame(FrameType.Replaced, Encoding.UTF8.GetBytes(deviceName));

    public static byte[] EncodeError(string message) =>
        EncodeFrame(FrameType.Error, Encoding.UTF8.GetBytes(message));

    // MARK: Decoding

    public static Hello? DecodeHello(ReadOnlySpan<byte> payload)
    {
        try { return JsonSerializer.Deserialize<Hello>(payload, JsonOpts); }
        catch { return null; }
    }

    public static uint? DecodeWindowId(ReadOnlySpan<byte> payload) =>
        payload.Length >= 4 ? BinaryPrimitives.ReadUInt32LittleEndian(payload) : null;

    public static (ushort X, ushort Y)? DecodeMouseMove(ReadOnlySpan<byte> payload)
    {
        if (payload.Length < 4) return null;
        return (BinaryPrimitives.ReadUInt16LittleEndian(payload),
                BinaryPrimitives.ReadUInt16LittleEndian(payload[2..]));
    }

    public static (MouseButton Button, ushort X, ushort Y)? DecodeMouseButton(ReadOnlySpan<byte> payload)
    {
        if (payload.Length < 5) return null;
        return ((MouseButton)payload[0],
                BinaryPrimitives.ReadUInt16LittleEndian(payload[1..]),
                BinaryPrimitives.ReadUInt16LittleEndian(payload[3..]));
    }

    public static (ushort X, ushort Y, short DeltaX, short DeltaY)? DecodeScroll(ReadOnlySpan<byte> payload)
    {
        if (payload.Length < 8) return null;
        return (BinaryPrimitives.ReadUInt16LittleEndian(payload),
                BinaryPrimitives.ReadUInt16LittleEndian(payload[2..]),
                BinaryPrimitives.ReadInt16LittleEndian(payload[4..]),
                BinaryPrimitives.ReadInt16LittleEndian(payload[6..]));
    }

    public static (ushort KeyCode, uint Modifiers)? DecodeKeyEvent(ReadOnlySpan<byte> payload)
    {
        if (payload.Length < 6) return null;
        return (BinaryPrimitives.ReadUInt16LittleEndian(payload),
                BinaryPrimitives.ReadUInt32LittleEndian(payload[2..]));
    }

    public static (uint WindowId, ushort X, ushort Y)? DecodeWindowMouseMove(ReadOnlySpan<byte> payload)
    {
        if (payload.Length < 8) return null;
        var inner = DecodeMouseMove(payload[4..]);
        return inner is null ? null : (BinaryPrimitives.ReadUInt32LittleEndian(payload), inner.Value.X, inner.Value.Y);
    }

    public static (uint WindowId, MouseButton Button, ushort X, ushort Y)? DecodeWindowMouseButton(ReadOnlySpan<byte> payload)
    {
        if (payload.Length < 9) return null;
        var inner = DecodeMouseButton(payload[4..]);
        return inner is null
            ? null
            : (BinaryPrimitives.ReadUInt32LittleEndian(payload), inner.Value.Button, inner.Value.X, inner.Value.Y);
    }

    public static (uint WindowId, ushort X, ushort Y, short DeltaX, short DeltaY)? DecodeWindowScroll(ReadOnlySpan<byte> payload)
    {
        if (payload.Length < 12) return null;
        var inner = DecodeScroll(payload[4..]);
        return inner is null
            ? null
            : (BinaryPrimitives.ReadUInt32LittleEndian(payload),
               inner.Value.X, inner.Value.Y, inner.Value.DeltaX, inner.Value.DeltaY);
    }

    /// <summary>
    /// Incremental frame parser over an append-only receive buffer — the C#
    /// counterpart of Swift's <c>drainFrames</c>. Oversized or zero-length
    /// frames poison the buffer (it's cleared), matching the Swift behavior.
    /// </summary>
    public sealed class FrameReader
    {
        private readonly MemoryStream _buffer = new();

        public void Append(ReadOnlySpan<byte> data) => _buffer.Write(data);

        public List<(FrameType Type, byte[] Payload)> Drain()
        {
            var frames = new List<(FrameType, byte[])>();
            var span = _buffer.GetBuffer().AsSpan(0, (int)_buffer.Length);
            var offset = 0;
            while (span.Length - offset >= FrameLengthPrefixSize)
            {
                var length = BinaryPrimitives.ReadUInt32LittleEndian(span[offset..]);
                if (length < 1 || length > MaxFrameBytes)
                {
                    _buffer.SetLength(0);
                    return frames;
                }
                var frameEnd = offset + FrameLengthPrefixSize + (int)length;
                if (span.Length < frameEnd) break;

                var type = (FrameType)span[offset + FrameLengthPrefixSize];
                frames.Add((type, span[(offset + FrameLengthPrefixSize + 1)..frameEnd].ToArray()));
                offset = frameEnd;
            }

            if (offset > 0)
            {
                var remaining = span[offset..].ToArray();
                _buffer.SetLength(0);
                _buffer.Write(remaining);
            }
            return frames;
        }
    }
}
