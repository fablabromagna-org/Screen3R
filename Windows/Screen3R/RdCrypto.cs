//
//  RdCrypto.cs
//  Screen3R for Windows
//
//  The same protocol crypto as Shared/rd_crypto.c (used by the Mac apps), written with
//  System.Security.Cryptography. Every byte must match the C version: the Mac viewer checks
//  these proofs and decrypts these messages. Tests/windows_interop.sh runs this code against
//  rd_crypto.c to prove it.
//

using System.Buffers.Binary;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace Screen3R;

public static class RdCrypto
{
    public const int KeyLength = 32;
    public const int HashLength = 32;
    public const int PublicKeyLength = 65;   // uncompressed P-256 point: 0x04 || X || Y
    public const int NonceLength = 16;
    public const int TagLength = 16;
    public const int SealOverhead = 8 + TagLength;   // counter + tag

    /// Every domain-separation label starts with the project name (RD_LABEL in rd_crypto.c).
    static byte[] Label(string x) => Encoding.ASCII.GetBytes("Screen3R " + x);

    public static byte[] Random(int count) => RandomNumberGenerator.GetBytes(count);

    public static string Hex(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(data);

    public static byte[]? Unhex(string? text, int length)
    {
        if (text == null || text.Length != length * 2) return null;
        foreach (char c in text)
            if (!char.IsAsciiHexDigit(c)) return null;
        return Convert.FromHexString(text);
    }

    /// Identifiers are UUID strings: letters, digits and dashes, 1–64 characters.
    public static bool IsValidId(string? id) =>
        !string.IsNullOrEmpty(id) && id.Length <= 64 && id.All(c => char.IsAsciiLetterOrDigit(c) || c == '-');

    public static bool Equal(ReadOnlySpan<byte> a, ReadOnlySpan<byte> b) =>
        a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b);

    // MARK: - Primitives

    public static byte[] Sha256(ReadOnlySpan<byte> data) => SHA256.HashData(data);

    public static byte[] Hmac(ReadOnlySpan<byte> key, ReadOnlySpan<byte> data) => HMACSHA256.HashData(key, data);

    /// HKDF-SHA256 (RFC 5869), as rd_hkdf_sha256.
    public static byte[] Hkdf(byte[] ikm, byte[] salt, string label, int length) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, length, salt, Label(label));

    // MARK: - Transcripts

    /// Builds u16-length-prefixed fields, so concatenations are unambiguous (put_field in C).
    sealed class Fields
    {
        readonly MemoryStream _stream = new();
        public Fields Add(ReadOnlySpan<byte> data)
        {
            Span<byte> len = stackalloc byte[2];
            BinaryPrimitives.WriteUInt16BigEndian(len, (ushort)data.Length);
            _stream.Write(len);
            _stream.Write(data);
            return this;
        }
        public Fields Add(string id)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(id);
            return Add(bytes.AsSpan(0, Math.Min(bytes.Length, 64)));   // clamp_id
        }
        public byte[] Hash() => SHA256.HashData(_stream.ToArray());
    }

    public static byte[] Commitment(ReadOnlySpan<byte> pkHost)
    {
        byte[] label = Label("commit v1");
        byte[] buf = new byte[label.Length + pkHost.Length];
        label.CopyTo(buf, 0);
        pkHost.CopyTo(buf.AsSpan(label.Length));
        return SHA256.HashData(buf);
    }

    public static byte[] PairTranscript(string hostId, string viewerId, ReadOnlySpan<byte> pkHost, ReadOnlySpan<byte> pkViewer) =>
        new Fields().Add(Label("pair v1")).Add(hostId).Add(viewerId).Add(pkHost).Add(pkViewer).Hash();

    public static byte[] PairKey(byte[] sharedSecret, byte[] transcript) =>
        Hkdf(sharedSecret, transcript, "pairing key v1", KeyLength);

    /// The 6-digit code (0…999 999) both screens show.
    public static uint PairCode(ReadOnlySpan<byte> key, ReadOnlySpan<byte> transcript)
    {
        byte[] mac = LabelledMac(key, "SAS", transcript);
        return (uint)(BinaryPrimitives.ReadUInt64BigEndian(mac) % 1_000_000UL);
    }

    public static byte[] PairConfirm(ReadOnlySpan<byte> key, ReadOnlySpan<byte> transcript, bool fromHost) =>
        LabelledMac(key, fromHost ? "pair confirm host" : "pair confirm viewer", transcript);

    /// `encrypt` is the host's choice from its HELLO: binding it here means nobody in the middle
    /// can change it without the authentication failing.
    public static byte[] SessionTranscript(string hostId, string viewerId, ReadOnlySpan<byte> nonceHost,
                                           ReadOnlySpan<byte> nonceViewer, bool encrypt) =>
        new Fields().Add(Label("session v1")).Add(hostId).Add(viewerId).Add(nonceHost).Add(nonceViewer)
                    .Add([(byte)(encrypt ? 1 : 0)]).Hash();

    public static byte[] SessionProof(ReadOnlySpan<byte> key, ReadOnlySpan<byte> transcript, bool fromHost) =>
        LabelledMac(key, fromHost ? "auth host" : "auth viewer", transcript);

    static byte[] LabelledMac(ReadOnlySpan<byte> key, string label, ReadOnlySpan<byte> transcript)
    {
        byte[] l = Label(label);
        byte[] buf = new byte[l.Length + transcript.Length];
        l.CopyTo(buf, 0);
        transcript.CopyTo(buf.AsSpan(l.Length));
        return HMACSHA256.HashData(key, buf);
    }
}

/// One direction of an encrypted session: AES-128-CTR + HMAC-SHA256 (encrypt-then-MAC),
/// message counters that must increase by exactly one (no replay, no reordering).
/// Not thread-safe: the caller serialises seal (send lock) and open (reader thread).
public sealed class SecureChannel : IDisposable
{
    readonly Aes _aes;
    readonly byte[] _macKey;
    ulong _counter;   // last counter sent / received

    SecureChannel(ReadOnlySpan<byte> encKey, ReadOnlySpan<byte> macKey)
    {
        _aes = Aes.Create();
        _aes.Key = encKey.ToArray();
        _macKey = macKey.ToArray();
    }

    /// Both directions, from the host's point of view (rd_session_channels with isHost = true).
    public static (SecureChannel send, SecureChannel recv) ForHost(byte[] key, byte[] transcript)
    {
        byte[] m = RdCrypto.Hkdf(key, transcript, "channel keys v1", 96);
        var hostToViewer = new SecureChannel(m.AsSpan(0, 16), m.AsSpan(16, 32));
        var viewerToHost = new SecureChannel(m.AsSpan(48, 16), m.AsSpan(64, 32));
        CryptographicOperations.ZeroMemory(m);
        return (hostToViewer, viewerToHost);
    }

    /// counter (u64 BE) || AES-128-CTR(plain) || HMAC-SHA256(counter || ciphertext)[0..16]
    public byte[]? Seal(ReadOnlySpan<byte> plain)
    {
        if (_counter == ulong.MaxValue) return null;
        ulong counter = _counter + 1;
        byte[] output = new byte[plain.Length + RdCrypto.SealOverhead];
        BinaryPrimitives.WriteUInt64BigEndian(output, counter);
        Ctr(counter, plain, output.AsSpan(8, plain.Length));
        Span<byte> mac = stackalloc byte[32];
        HMACSHA256.HashData(_macKey, output.AsSpan(0, 8 + plain.Length), mac);
        mac[..RdCrypto.TagLength].CopyTo(output.AsSpan(8 + plain.Length));
        _counter = counter;
        return output;
    }

    /// Verifies (before decrypting) and decrypts. Null if anything is wrong.
    public byte[]? Open(ReadOnlySpan<byte> sealedMessage)
    {
        if (sealedMessage.Length < RdCrypto.SealOverhead) return null;
        int length = sealedMessage.Length - RdCrypto.SealOverhead;
        ulong counter = BinaryPrimitives.ReadUInt64BigEndian(sealedMessage);
        if (_counter == ulong.MaxValue || counter != _counter + 1) return null;   // replay / reorder
        Span<byte> mac = stackalloc byte[32];
        HMACSHA256.HashData(_macKey, sealedMessage[..(8 + length)], mac);
        if (!CryptographicOperations.FixedTimeEquals(mac[..RdCrypto.TagLength], sealedMessage.Slice(8 + length, RdCrypto.TagLength)))
            return null;
        byte[] plain = new byte[length];
        Ctr(counter, sealedMessage.Slice(8, length), plain);
        _counter = counter;
        return plain;
    }

    /// AES-128-CTR with a 128-bit big-endian counter block: message counter in the high
    /// 64 bits, block index (from 0) in the low 64 bits — exactly like CommonCrypto's CTR_BE
    /// mode started at the IV (message counter || 0).
    void Ctr(ulong messageCounter, ReadOnlySpan<byte> input, Span<byte> output)
    {
        if (input.Length == 0) return;
        int blocks = (input.Length + 15) / 16;
        byte[] stream = new byte[blocks * 16];
        for (int i = 0; i < blocks; i++)
        {
            BinaryPrimitives.WriteUInt64BigEndian(stream.AsSpan(i * 16), messageCounter);
            BinaryPrimitives.WriteUInt64BigEndian(stream.AsSpan(i * 16 + 8), (ulong)i);
        }
        _aes.EncryptEcb(stream, stream, PaddingMode.None);
        int n = input.Length, k = 0;
        int vec = Vector<byte>.Count;
        for (; k + vec <= n; k += vec)
            (new Vector<byte>(input.Slice(k, vec)) ^ new Vector<byte>(stream, k)).CopyTo(output.Slice(k, vec));
        for (; k < n; k++) output[k] = (byte)(input[k] ^ stream[k]);
    }

    public void Dispose() => _aes.Dispose();
}

/// Ephemeral P-256 key pair for one pairing attempt.
public sealed class EcdhKeyPair : IDisposable
{
    readonly ECDiffieHellman _key;
    public byte[] PublicKey { get; }

    public EcdhKeyPair()
    {
        _key = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        ECParameters p = _key.ExportParameters(false);
        PublicKey = new byte[RdCrypto.PublicKeyLength];
        PublicKey[0] = 0x04;
        LeftPad(p.Q.X!).CopyTo(PublicKey, 1);
        LeftPad(p.Q.Y!).CopyTo(PublicKey, 33);
    }

    /// Shared secret (32 bytes, X coordinate) with the peer's public key; null if the key is
    /// malformed or not a point of the curve.
    public byte[]? SharedSecret(ReadOnlySpan<byte> peer)
    {
        if (peer.Length != RdCrypto.PublicKeyLength || peer[0] != 0x04) return null;
        byte[] x = peer.Slice(1, 32).ToArray(), y = peer.Slice(33, 32).ToArray();
        if (!IsOnCurve(x, y)) return null;
        try
        {
            using var peerKey = ECDiffieHellman.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = x, Y = y },
            });
            byte[] z = _key.DeriveRawSecretAgreement(peerKey.PublicKey);
            return z.Length == 32 ? z : null;
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    static readonly BigInteger P = BigInteger.Parse("0FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF",
                                                    System.Globalization.NumberStyles.HexNumber);
    static readonly BigInteger B = BigInteger.Parse("05AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B",
                                                    System.Globalization.NumberStyles.HexNumber);

    /// y² = x³ − 3x + b (mod p), with 0 ≤ x, y < p (rejects invalid-curve attacks).
    static bool IsOnCurve(byte[] xBytes, byte[] yBytes)
    {
        var x = new BigInteger(xBytes, isUnsigned: true, isBigEndian: true);
        var y = new BigInteger(yBytes, isUnsigned: true, isBigEndian: true);
        if (x >= P || y >= P) return false;
        BigInteger left = BigInteger.ModPow(y, 2, P);
        BigInteger right = ((BigInteger.ModPow(x, 3, P) - 3 * x + B) % P + P) % P;
        return left == right;
    }

    static byte[] LeftPad(byte[] v)
    {
        if (v.Length == 32) return v;
        byte[] r = new byte[32];
        v.CopyTo(r, 32 - v.Length);
        return r;
    }

    public void Dispose() => _key.Dispose();
}
