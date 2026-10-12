//
//  Protocol.cs
//  Screen3R for Windows
//
//  Wire protocol shared with the Mac apps. See PROTOCOL.md.
//  Every message: [u8 type][u32 BE payload length][payload]
//

using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Screen3R;

public static class RD
{
    public const string ServiceType = "_screen3r._tcp";
    public const int Port = 52020;
    public const int ProtocolVersion = 2;   // 2: pairing, authentication, encryption
    /// The viewer only sends small messages (HELLO, ACK, PONG, stats, input).
    public const int MaxViewerMessageSize = 64 * 1024;
}

public enum MessageType : byte
{
    Hello = 0x01,            // both directions, JSON
    Format = 0x02,           // host -> viewer: H.264 parameter sets
    Frame = 0x03,            // host -> viewer: one encoded frame
    KeyframeRequest = 0x04,  // viewer -> host
    Ack = 0x05,              // viewer -> host: u32 seq
    Ping = 0x06,             // host -> viewer: u64 timestamp (µs)
    Pong = 0x07,             // viewer -> host: echo of ping payload
    CursorPosition = 0x08,   // host -> viewer: i16 x, i16 y, u8 flags (bit 0 = visible), u32 inputSeq
    CursorImage = 0x09,      // host -> viewer: u16 w, u16 h, u16 hotX, u16 hotY (points), u16 pixelW, u16 pixelH + raw BGRA
    ViewerStats = 0x0A,      // viewer -> host: JSON, about once a second
    PairCommit = 0x0B,       // host -> viewer: SHA-256 commitment to the host's public key
    PairKey = 0x0C,          // both: 65-byte P-256 public key
    PairConfirm = 0x0D,      // both: 32-byte proof of the new pairing key
    Auth = 0x0E,             // both: 32-byte proof of the stored pairing key
    NeedPairing = 0x0F,      // viewer -> host: no (valid) pairing for this host
    Secure = 0x10,           // both: encrypted envelope around one inner message
    InputControl = 0x11,     // host -> viewer: u8 flags (bit 0 = input accepted)
    InputMove = 0x12,        // viewer -> host: u32 seq, i16 dx, i16 dy (stream pixels), u32 modifier flags
    InputButton = 0x13,      // viewer -> host: u8 button, u8 down, u8 clickCount, u32 modifier flags
    InputScroll = 0x14,      // viewer -> host: u8 continuous, u8 phase, u8 momentumPhase, i32 dy, i32 dx, u32 flags
    InputKey = 0x15,         // viewer -> host: u16 keyCode, u8 bits (0 = down, 1 = repeat), u8 keyboardType, u32 flags
    InputReset = 0x16,       // viewer -> host: release every key and button held
    Cue = 0x17,              // host -> viewer: u8 cue
}

/// One keyboard or mouse event from the old Mac, already range-checked (as Protocol.swift).
public abstract record InputEvent
{
    public sealed record Move(uint Seq, short Dx, short Dy, uint Flags) : InputEvent;
    public sealed record Button(byte Number, bool Down, byte Clicks, uint Flags) : InputEvent;
    public sealed record Scroll(bool Continuous, byte Phase, byte Momentum, int Dy, int Dx, uint Flags) : InputEvent;
    public sealed record Key(ushort Code, bool Down, bool IsRepeat, byte KeyboardType, uint Flags) : InputEvent;
    public sealed record Reset : InputEvent;

    public static InputEvent? Parse(MessageType type, ReadOnlySpan<byte> p)
    {
        switch (type)
        {
            case MessageType.InputMove when p.Length >= 12:
                return new Move(BinaryPrimitives.ReadUInt32BigEndian(p), BinaryPrimitives.ReadInt16BigEndian(p[4..]),
                                BinaryPrimitives.ReadInt16BigEndian(p[6..]), BinaryPrimitives.ReadUInt32BigEndian(p[8..]));
            case MessageType.InputButton when p.Length >= 7:
                if (p[0] >= 32) return null;
                return new Button(p[0], p[1] != 0, Math.Min(p[2], (byte)3), BinaryPrimitives.ReadUInt32BigEndian(p[3..]));
            case MessageType.InputScroll when p.Length >= 15:
                static int Clamp(int v) => Math.Clamp(v, -10_000, 10_000);
                return new Scroll(p[0] != 0, p[1], p[2], Clamp(BinaryPrimitives.ReadInt32BigEndian(p[3..])),
                                  Clamp(BinaryPrimitives.ReadInt32BigEndian(p[7..])), BinaryPrimitives.ReadUInt32BigEndian(p[11..]));
            case MessageType.InputKey when p.Length >= 8:
                ushort code = BinaryPrimitives.ReadUInt16BigEndian(p);
                if (code > 0x7F) return null;
                return new Key(code, (p[2] & 1) != 0, (p[2] & 2) != 0, p[3], BinaryPrimitives.ReadUInt32BigEndian(p[4..]));
            case MessageType.InputReset:
                return new Reset();
            default:
                return null;
        }
    }
}

/// HELLO sent by the viewer right after the TCP connection is accepted.
public sealed record ViewerHello(int Proto, string Name, int Width, int Height, double Scale, string? Os,
                                 IReadOnlyList<string> Features, string? Id, string? Nonce, string? KeyboardLayout,
                                 string? Cry)
{
    public bool Has(string feature) => Features.Contains(feature);

    public static ViewerHello? Parse(ReadOnlySpan<byte> json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json.ToArray());
            JsonElement r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return null;
            int Int(string name) => r.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number
                                    && v.TryGetInt32(out int i) ? i : -1;
            string? Str(string name) => r.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
                                        ? v.GetString() : null;
            var features = new List<string>();
            if (r.TryGetProperty("features", out var f) && f.ValueKind == JsonValueKind.Array)
                foreach (var e in f.EnumerateArray())
                    if (e.ValueKind == JsonValueKind.String && features.Count < 32) features.Add(e.GetString()!);
            double scale = r.TryGetProperty("scale", out var s) && s.ValueKind == JsonValueKind.Number ? s.GetDouble() : 1;
            int width = Int("width"), height = Int("height"), proto = Int("proto");
            if (proto < 0 || width <= 0 || height <= 0) return null;
            return new ViewerHello(proto, Str("name") ?? "Old Mac", width, height, scale, Str("os"), features,
                                   Str("id"), Str("nonce"), Str("keyboardLayout"), Str("cry"));
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// Decoder statistics reported by the viewer.
public sealed record ViewerStats(bool? Hw, double? DecodeMs, int? Frames)
{
    public static ViewerStats? Parse(ReadOnlySpan<byte> json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json.ToArray());
            JsonElement r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return null;
            bool? hw = r.TryGetProperty("hw", out var h) && (h.ValueKind is JsonValueKind.True or JsonValueKind.False)
                ? h.GetBoolean() : null;
            double? ms = r.TryGetProperty("decodeMs", out var d) && d.ValueKind == JsonValueKind.Number ? d.GetDouble() : null;
            int? frames = r.TryGetProperty("frames", out var n) && n.ValueKind == JsonValueKind.Number && n.TryGetInt32(out int i)
                ? i : null;
            return new ViewerStats(hw, ms, frames);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

public static class Wire
{
    public static byte[] HostHello(string name, string id, string nonceHex, bool encrypt)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream))
        {
            w.WriteStartObject();
            w.WriteNumber("proto", RD.ProtocolVersion);
            w.WriteString("name", name);
            w.WriteString("id", id);
            w.WriteString("nonce", nonceHex);
            w.WriteBoolean("encrypt", encrypt);
            w.WriteEndObject();
        }
        return stream.ToArray();
    }

    public static byte[] Message(MessageType type, ReadOnlySpan<byte> payload)
    {
        byte[] m = new byte[5 + payload.Length];
        m[0] = (byte)type;
        BinaryPrimitives.WriteUInt32BigEndian(m.AsSpan(1), (uint)payload.Length);
        payload.CopyTo(m.AsSpan(5));
        return m;
    }

    /// Makes a name received from the network safe to show: no control/format characters
    /// (bidi overrides included), at most 64 characters.
    public static string SanitizedName(string? raw, string fallback = "Old Mac")
    {
        if (raw == null) return fallback;
        var sb = new StringBuilder();
        foreach (Rune r in raw.EnumerateRunes())
        {
            switch (Rune.GetUnicodeCategory(r))
            {
                case UnicodeCategory.Control:
                case UnicodeCategory.Format:
                case UnicodeCategory.LineSeparator:
                case UnicodeCategory.ParagraphSeparator:
                case UnicodeCategory.PrivateUse:
                case UnicodeCategory.Surrogate:
                case UnicodeCategory.OtherNotAssigned:
                    continue;
            }
            sb.Append(r.ToString());
        }
        string name = sb.ToString().Trim();
        var info = new StringInfo(name);
        if (info.LengthInTextElements > 64) name = info.SubstringByTextElements(0, 64) + "…";
        return name.Length == 0 ? fallback : name;
    }

    public static ulong MonotonicMicros() =>
        (ulong)((UInt128)(ulong)System.Diagnostics.Stopwatch.GetTimestamp() * 1_000_000
                / (ulong)System.Diagnostics.Stopwatch.Frequency);
}
