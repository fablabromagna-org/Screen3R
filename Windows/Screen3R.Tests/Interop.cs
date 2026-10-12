//
//  Interop.cs — runs the real PeerConnection (host side) against Tests/fake_viewer.py, a viewer
//  simulated with the Mac apps' C crypto (Shared/rd_crypto.c). Prints what happens; exit 0 on success.
//

using System.Text.Json;
using Screen3R;

static class Interop
{
    sealed class FileKeys(string path) : IPairingKeys
    {
        Dictionary<string, string> Load() =>
            File.Exists(path) ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? new() : new();
        public byte[]? Get(string viewerId) => Load().TryGetValue(viewerId, out var hex) ? Convert.FromHexString(hex) : null;
        public void Store(string viewerId, byte[] key, string name)
        {
            var all = Load();
            all[viewerId] = Convert.ToHexString(key);
            File.WriteAllText(path, JsonSerializer.Serialize(all));
            Console.WriteLine($"STORED key for {name}");
        }
    }

    public static int Run(string[] args)
    {
        int port = int.Parse(args[1]);
        string keysPath = args[2];
        bool encrypt = args[3] == "1";
        var done = new ManualResetEventSlim();
        string? closeReason = "(not closed)";
        var inputs = new List<string>();
        int result = 1;

        var peer = new PeerConnection("127.0.0.1", port, "Fake iMac", encrypt, "WIN-HOST-0000-1111", "Test PC", new FileKeys(keysPath));
        peer.OnPairingCode = (code, name, decide) =>
        {
            Console.WriteLine($"CODE {code} from {name}");
            decide(true);
        };
        peer.OnHelloGate = (hello, resume) =>
        {
            // Like the tray app's message box: authentication waits, keep-alive goes on.
            Console.WriteLine($"GATE cry={hello.Cry}");
            new Thread(() => { Thread.Sleep(1500); resume(); }) { IsBackground = true }.Start();
        };
        peer.OnClosed = reason =>
        {
            closeReason = reason;
            done.Set();
        };
        peer.OnInput = e =>
        {
            lock (inputs) inputs.Add(e.ToString());
            Console.WriteLine($"INPUT {e}");
        };
        peer.OnReady = hello =>
        {
            Console.WriteLine($"READY {hello.Name} {hello.Width}x{hello.Height} features={string.Join(',', hello.Features)} layout={hello.KeyboardLayout}");
            new Thread(() =>
            {
                try
                {
                    peer.SetInputEnabled(true);
                    peer.SendCue(EasterEgg.CryCue);
                    peer.SendCue(EasterEgg.CryCue);   // second one must be suppressed
                    peer.SendFormat([[0x67, 0x42, 0xC0, 0x1E], [0x68, 0xCE, 0x3C, 0x80]], 4);
                    for (int i = 0; i < 6; i++)
                    {
                        var wait = DateTime.UtcNow.AddSeconds(3);
                        while (!peer.CanSendFrame() && DateTime.UtcNow < wait) Thread.Sleep(5);
                        if (!peer.CanSendFrame()) { Console.WriteLine("FAIL flow control: no ACKs"); return; }
                        byte[] frame = new byte[4 + 2000];
                        frame[2] = 2000 >> 8; frame[3] = 2000 & 0xFF; frame[4] = i == 0 ? (byte)0x65 : (byte)0x41;
                        peer.SendFrame(frame, keyframe: i == 0);
                    }
                    peer.SendCursorPosition(100, 200, true, 7);
                    peer.SendCursorImage(2, 2, 1, 1, 2, 2, new byte[16]);
                    Console.WriteLine("SENT frames, cursor, cue");
                    // The fake viewer sends input events, then closes.
                }
                catch (Exception e) { Console.WriteLine($"FAIL {e}"); }
            }) { IsBackground = true }.Start();
        };
        peer.Start();
        if (!done.Wait(TimeSpan.FromSeconds(30)))
        {
            Console.WriteLine("FAIL timeout");
            peer.Cancel();
            return 1;
        }
        Console.WriteLine($"CLOSED {closeReason}");
        lock (inputs)
        {
            bool expectInput = encrypt;
            bool gotInput = inputs.Any(i => i.Contains("Key")) && inputs.Any(i => i.Contains("Move"));
            if (expectInput == gotInput) result = 0;
            else Console.WriteLine($"FAIL input events: expected {(expectInput ? "some" : "none")}, got {inputs.Count}");
        }
        return result;
    }
}
