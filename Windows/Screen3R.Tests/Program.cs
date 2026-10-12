//
//  Screen3R.Tests — checks of the Windows sender's platform-neutral code.
//
//    dotnet run -c Release                          unit tests (vectors produced by Shared/rd_crypto.c)
//    dotnet run -c Release -- interop PORT KEYS 1   acts as the host against Tests/fake_viewer.py
//

using System.Buffers.Binary;
using System.Text;
using Screen3R;

if (args.Length >= 1 && args[0] == "interop") return Interop.Run(args);

int failures = 0;
void Check(bool ok, string what)
{
    Console.WriteLine((ok ? "ok   " : "FAIL ") + what);
    if (!ok) failures++;
}
byte[] H(string hex) => Convert.FromHexString(hex);
string X(byte[] b) => Convert.ToHexStringLower(b);

// --- HKDF, RFC 5869 test case 1 (the C self-test checks the same vector)
{
    byte[] okm = System.Security.Cryptography.HKDF.DeriveKey(System.Security.Cryptography.HashAlgorithmName.SHA256,
        Enumerable.Repeat((byte)0x0b, 22).ToArray(), 42, H("000102030405060708090a0b0c"), H("f0f1f2f3f4f5f6f7f8f9"));
    Check(X(okm) == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
          "HKDF-SHA256 matches RFC 5869 test case 1");
}

// --- Vectors printed by rd_crypto.c (OpenSSL build) for fixed inputs
{
    byte[] pkH = new byte[65], pkV = new byte[65], z = new byte[32], key = new byte[32], nH = new byte[16], nV = new byte[16];
    for (int i = 0; i < 65; i++) { pkH[i] = (byte)(i * 3 + 1); pkV[i] = (byte)(200 - i); }
    pkH[0] = pkV[0] = 4;
    for (int i = 0; i < 32; i++) { z[i] = (byte)(i + 0x40); key[i] = (byte)(i + 1); }
    for (int i = 0; i < 16; i++) { nH[i] = (byte)(0xA0 + i); nV[i] = (byte)(0x10 + i); }
    const string h = "8C1F7A2E-4B6D-4C1A-9E2F-0123456789AB", v = "3B9D0C44-1111-2222-3333-444455556666";

    Check(X(RdCrypto.Commitment(pkH)) == "00177206083db9276ca1b2c5797c58ae0a05758f09cb15b94ad93173aad64245", "commitment = C");
    byte[] t = RdCrypto.PairTranscript(h, v, pkH, pkV);
    Check(X(t) == "9c2a7abaa03a50861c0bd67642a86a10d44381db674f84b78353d618d52301ee", "pairing transcript = C");
    byte[] k = RdCrypto.PairKey(z, t);
    Check(X(k) == "f300ec5ea4c915c31cc9c70793f07b58caa4dd1ffe7a0b6a7e88968e4a0a9fe3", "pairing key = C");
    Check(RdCrypto.PairCode(k, t) == 566287, "pairing code = C");
    Check(X(RdCrypto.PairConfirm(k, t, true)) == "accb1c93ed9702fdff960d06ad4e5ae7f90c628489312eb53ca80c4ed0d3f70b", "host confirmation = C");
    Check(X(RdCrypto.PairConfirm(k, t, false)) == "673aa9396423794f4a93b9ae0a99129857d5c4289a8cb3f917e2c3f940b90b77", "viewer confirmation = C");
    byte[] st = RdCrypto.SessionTranscript(h, v, nH, nV, true);
    Check(X(st) == "963f244fec5067d08e5e733810c86e2067f5191dd278704b75e55baa32735e51", "session transcript (encrypt) = C");
    Check(X(RdCrypto.SessionTranscript(h, v, nH, nV, false)) == "924f70e54f1a04f81618dcf94b28656d4dbefc4d3397fad56ea8f7d9b92220a6",
          "session transcript (clear) = C");
    Check(X(RdCrypto.SessionProof(key, st, true)) == "e1b54f2a5a5d5a178d4b1e0730bd60e1ab36a005542147c1c69b0681184e9036", "host proof = C");
    Check(X(RdCrypto.SessionProof(key, st, false)) == "086366ef9e75c63cb9797e9aecfd87228b45d15b0b32f8119a127d933d4e4433", "viewer proof = C");

    var (send, recv) = SecureChannel.ForHost(key, st);
    byte[] msg = Encoding.ASCII.GetBytes("Every time you do this, your iMac cries. 0123456789");
    Check(X(send.Seal(msg)!) == "0000000000000001728df8f131d11fb9b879ef236dfc9a598594b4aba2426f8ce42b67104768e204e60d84f356c1f89493ac0547d97169077edd2362b094ed26773de73f6caff8919ef819",
          "sealed message 1 = C (AES-CTR, HMAC, counter)");
    Check(X(send.Seal(msg)!) == "0000000000000002758a100513c17744b777f84b75ded4b384cbce9338b55f846fa1eea0e3535c858da58723d1e298e9305d8ea629faf002665306376b8f831951a18770b93827e04bfc71",
          "sealed message 2 = C");
    byte[] fromViewer = H("0000000000000001ce5a728941b217b9241996f02427ca53559c572d2b");
    byte[]? opened = recv.Open(fromViewer);
    Check(opened != null && Encoding.ASCII.GetString(opened) == "Every", "opens a message sealed by the viewer (C)");
    Check(recv.Open(fromViewer) == null, "replayed message rejected");
    var (_, recv2) = SecureChannel.ForHost(key, st);
    byte[] tampered = (byte[])fromViewer.Clone();
    tampered[10] ^= 1;
    Check(recv2.Open(tampered) == null, "tampered message rejected");
    Check(recv2.Open(fromViewer) != null, "…and the channel still accepts the genuine one");
}

// --- ECDH: both sides agree; points off the curve are refused
{
    using var a = new EcdhKeyPair();
    using var b = new EcdhKeyPair();
    byte[]? za = a.SharedSecret(b.PublicKey), zb = b.SharedSecret(a.PublicKey);
    Check(za != null && zb != null && za.SequenceEqual(zb), "ECDH P-256 shared secret agrees");
    byte[] bad = (byte[])b.PublicKey.Clone();
    bad[40] ^= 0x55;
    Check(a.SharedSecret(bad) == null, "public key not on the curve rejected");
    bad = (byte[])b.PublicKey.Clone();
    bad[0] = 0x02;
    Check(a.SharedSecret(bad) == null, "compressed/odd key format rejected");
}

// --- Annex B -> AVCC
{
    byte[] annexB = H("00000001" + "0910" + "00000001" + "6742c01e" + "000001" + "68ce3c80" +
                      "00000001" + "65888400ff" + "000001" + "419a0000");
    var au = AnnexB.Convert(annexB, annexB.Length);
    Check(au.IsKeyframe, "IDR slice -> keyframe");
    Check(au.ParameterSets.Count == 2 && au.ParameterSets[0][0] == 0x67 && au.ParameterSets[1][0] == 0x68,
          "SPS and PPS extracted, in order");
    Check(X(au.Avcc) == "00000005" + "65888400ff" + "00000002" + "419a", "AVCC: AUD/SPS/PPS dropped, lengths prefixed, zero padding trimmed");
    byte[] p = H("000001" + "419a1234");
    var au2 = AnnexB.Convert(p, p.Length);
    Check(!au2.IsKeyframe && au2.ParameterSets.Count == 0 && X(au2.Avcc) == "00000004419a1234", "P frame converted");
}

// --- mDNS
{
    byte[] q = DnsMessage.BuildQuery(7, [("_screen3r._tcp.local", DnsMessage.TypePtr), ("iMac di Riccardo._screen3r._tcp.local", DnsMessage.TypeSrv)]);
    Check(q.Length > 12 && q[5] == 2, "query with two questions");
    Check(Encoding.UTF8.GetString(q).Contains("iMac di Riccardo"), "instance label kept whole");

    // Response: PTR (answer) + SRV + A (additional), with name compression.
    var m = new List<byte>();
    void U16(int x) { m.Add((byte)(x >> 8)); m.Add((byte)x); }
    void U32(uint x) { U16((int)(x >> 16)); U16((int)(x & 0xFFFF)); }
    void Name(params string[] labels) { foreach (var l in labels) { var b = Encoding.UTF8.GetBytes(l); m.Add((byte)b.Length); m.AddRange(b); } m.Add(0); }
    U16(0); U16(0x8400); U16(0); U16(1); U16(0); U16(2);
    int service = m.Count;
    Name("_screen3r", "_tcp", "local");
    U16(12); U16(1); U32(4500);
    int rdlenAt = m.Count; U16(0);
    int instance = m.Count;
    m.Add(16); m.AddRange(Encoding.UTF8.GetBytes("iMac di Riccardo")); m.Add((byte)(0xC0 | (service >> 8))); m.Add((byte)service);
    int len = m.Count - instance; m[rdlenAt] = (byte)(len >> 8); m[rdlenAt + 1] = (byte)len;
    m.Add((byte)(0xC0 | (instance >> 8))); m.Add((byte)instance);
    U16(33); U16(0x8001); U32(120);
    rdlenAt = m.Count; U16(0);
    int srv = m.Count;
    U16(0); U16(0); U16(52020);
    int host = m.Count;
    m.Add(16); m.AddRange(Encoding.UTF8.GetBytes("iMac-di-Riccardo")); m.Add(0xC0); m.Add((byte)(service + 15));   // -> "local"
    len = m.Count - srv; m[rdlenAt] = (byte)(len >> 8); m[rdlenAt + 1] = (byte)len;
    m.Add((byte)(0xC0 | (host >> 8))); m.Add((byte)host);
    U16(1); U16(0x8001); U32(120); U16(4); m.AddRange(new byte[] { 192, 168, 1, 20 });
    var records = DnsMessage.Parse(m.ToArray());
    Check(records is { Count: 3 }, "response parsed (PTR, SRV, A)");
    var disco = new Discovery();
    disco.Absorb(records!);
    var viewers = disco.Viewers;
    Check(viewers.Count == 1 && viewers[0].Name == "iMac di Riccardo" && viewers[0].Address.ToString() == "192.168.1.20"
          && viewers[0].Port == 52020, "viewer found: name, address, port");
    byte[] loop = H("000084000000000100000000" + "c00c" + "000c0001000000010002c00c");
    Check(DnsMessage.Parse(loop) == null, "compression loop rejected");
    Check(DnsMessage.Parse(H("0000840000000001")) == null, "truncated message rejected");
}

// --- Messages
{
    var hello = ViewerHello.Parse(Encoding.UTF8.GetBytes(
        """{"proto":2,"id":"ABC-1","nonce":"00112233445566778899aabbccddeeff","name":"iMac","width":1920,"height":1080,"scale":1,"os":"10.13.6","features":["cursor","input"],"keyboardLayout":"iso","cry":"never"}"""));
    Check(hello is { Proto: 2, Width: 1920, Height: 1080, KeyboardLayout: "iso", Cry: "never" } && hello.Has("input"), "viewer HELLO parsed");
    Check(ViewerHello.Parse("[1,2]"u8) == null && ViewerHello.Parse("{\"proto\":2}"u8) == null, "bad HELLOs rejected");
    Check(Wire.SanitizedName("iMac‮evil\u0007") == "iMacevil", "names: control and bidi characters removed");
    byte[] key = new byte[8];
    BinaryPrimitives.WriteUInt16BigEndian(key, 0x80);
    Check(InputEvent.Parse(MessageType.InputKey, key) == null, "key codes above 127 rejected");
    byte[] button = [40, 1, 1, 0, 0, 0, 0];
    Check(InputEvent.Parse(MessageType.InputButton, button) == null, "button numbers above 31 rejected");
    byte[] scroll = new byte[15];
    BinaryPrimitives.WriteInt32BigEndian(scroll.AsSpan(3), 99999);
    Check(InputEvent.Parse(MessageType.InputScroll, scroll) is InputEvent.Scroll { Dy: 10000 }, "scroll deltas clamped");
}

// --- Keys
{
    Check(KeyMap.Map(0x00, MacKeyboardLayout.Iso, false) == new ScanCode(0x1E, false), "A -> scan code 0x1E");
    Check(KeyMap.Map(0x0A, MacKeyboardLayout.Iso, false) == new ScanCode(0x29, false) &&
          KeyMap.Map(0x32, MacKeyboardLayout.Iso, false) == new ScanCode(0x56, false), "ISO: § and < keys swapped back");
    Check(KeyMap.Map(0x32, MacKeyboardLayout.Ansi, false) == new ScanCode(0x29, false), "ANSI: grave key");
    Check(KeyMap.Map(0x37, MacKeyboardLayout.Iso, false) == new ScanCode(0x5B, true) &&
          KeyMap.Map(0x37, MacKeyboardLayout.Iso, true) == new ScanCode(0x1D, false), "⌘ = Windows key, or Ctrl");
    Check(KeyMap.Map(0x3D, MacKeyboardLayout.Iso, false) == new ScanCode(0x38, true), "right ⌥ = AltGr");
    int mapped = 0;
    for (ushort c = 0; c < 128; c++) if (KeyMap.Map(c, MacKeyboardLayout.Iso, false) != null) mapped++;
    Check(mapped >= 110, $"{mapped} Mac keys mapped");
}

// --- Easter egg schedule
{
    int countdown = 0, fired = 0, last = 0;
    var gaps = new List<int>();
    var random = new Random(3);
    for (int i = 1; i <= 600; i++)
        if (EasterEgg.ShouldFire("sometimes", ref countdown, random)) { fired++; gaps.Add(i - last); last = i; }
    Check(gaps.All(g => g is >= 4 and <= 6) && gaps.Distinct().Count() == 3, $"sometimes: every 4–6 connections ({fired} times in 600)");
    int c = 0;
    Check(Enumerable.Range(0, 20).All(_ => EasterEgg.ShouldFire("always", ref c, random)), "always: every connection");
    Check(Enumerable.Range(0, 20).All(_ => !EasterEgg.ShouldFire("never", ref c, random)), "never: no connection");
    c = 0;
    int olds = Enumerable.Range(0, 60).Count(_ => EasterEgg.ShouldFire(null, ref c, random));
    Check(olds is >= 10 and <= 15, "older viewers (no preference): sometimes");
}

Console.WriteLine(failures == 0 ? "All tests passed." : $"{failures} test(s) FAILED.");
return failures == 0 ? 0 : 1;
