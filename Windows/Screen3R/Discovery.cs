//
//  Discovery.cs
//  Screen3R for Windows
//
//  Finds Screen3R viewers on the local network: the viewer advertises `_screen3r._tcp` with
//  Bonjour (mDNS/DNS-SD). Instead of depending on Apple's Bonjour service, we send standard
//  mDNS questions to 224.0.0.251:5353 from an ordinary UDP port ("legacy unicast",
//  RFC 6762 §6.7): responders answer straight to that port, so we never compete with Windows'
//  own mDNS responder for port 5353. Windows Firewall lets those unicast answers to a multicast
//  question in by default.
//
//  The DNS message parsing is platform-neutral and unit-tested (Screen3R.Tests).
//

using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace Screen3R;

public sealed record DiscoveredViewer(string Name, IPAddress Address, int Port);

public sealed class Discovery : IDisposable
{
    const string ServiceName = RD.ServiceType + ".local";
    static readonly IPEndPoint MdnsGroup = new(IPAddress.Parse("224.0.0.251"), 5353);

    sealed class Instance
    {
        public string? Target;
        public int Port;
        public DateTime Seen;
    }

    readonly object _lock = new();
    readonly Dictionary<string, Instance> _instances = new(StringComparer.OrdinalIgnoreCase);   // full instance name
    readonly Dictionary<string, (IPAddress Address, DateTime Seen)> _hosts = new(StringComparer.OrdinalIgnoreCase);
    readonly List<UdpClient> _sockets = new();
    System.Threading.Timer? _timer;
    volatile bool _disposed;

    /// Raised (on a background thread) when the list changes.
    public event Action? Changed;

    public void Start()
    {
        _timer = new System.Threading.Timer(_ => Query(), null, 0, 3000);
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
    }

    void OnNetworkChanged(object? sender, EventArgs e)
    {
        lock (_lock) CloseSockets();
        Query();
    }

    public IReadOnlyList<DiscoveredViewer> Viewers
    {
        get
        {
            var list = new List<DiscoveredViewer>();
            lock (_lock)
            {
                DateTime old = DateTime.UtcNow - TimeSpan.FromSeconds(12);
                foreach (var (full, inst) in _instances)
                {
                    if (inst.Seen < old || inst.Target == null || inst.Port == 0) continue;
                    if (!_hosts.TryGetValue(inst.Target, out var host) || host.Seen < old) continue;
                    string name = Wire.SanitizedName(InstanceLabel(full));
                    if (list.Any(v => v.Name == name)) continue;
                    list.Add(new DiscoveredViewer(name, host.Address, inst.Port));
                }
            }
            list.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));
            return list;
        }
    }

    static string InstanceLabel(string full) =>
        full.EndsWith("." + ServiceName, StringComparison.OrdinalIgnoreCase) ? full[..^(ServiceName.Length + 1)] : full;

    // MARK: - Network

    void Query()
    {
        if (_disposed) return;
        List<(UdpClient, byte[])> sends = new();
        lock (_lock)
        {
            if (_sockets.Count == 0) OpenSockets();
            var questions = new List<(string, ushort)> { (ServiceName, DnsMessage.TypePtr) };
            DateTime now = DateTime.UtcNow;
            foreach (var (full, inst) in _instances)
            {
                if (now - inst.Seen > TimeSpan.FromSeconds(12)) continue;
                if (inst.Target == null) questions.Add((full, DnsMessage.TypeSrv));
                else if (!_hosts.ContainsKey(inst.Target)) questions.Add((inst.Target, DnsMessage.TypeA));
            }
            byte[] query = DnsMessage.BuildQuery((ushort)Random.Shared.Next(1, 65535), questions);
            foreach (var s in _sockets) sends.Add((s, query));
        }
        foreach (var (socket, query) in sends)
        {
            try { socket.Send(query, query.Length, MdnsGroup); }
            catch (Exception e) when (e is SocketException or ObjectDisposedException) { }
        }
    }

    void OpenSockets()
    {
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up || !nic.SupportsMulticast ||
                nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var ua in nic.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                if (ua.Address.ToString().StartsWith("169.254.")) continue;
                try
                {
                    var client = new UdpClient(new IPEndPoint(ua.Address, 0));
                    client.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface,
                                                  ua.Address.GetAddressBytes());
                    client.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
                    _sockets.Add(client);
                    var thread = new Thread(() => ReceiveLoop(client)) { IsBackground = true, Name = "Screen3R mDNS" };
                    thread.Start();
                }
                catch (SocketException) { }
            }
        }
    }

    void CloseSockets()
    {
        foreach (var s in _sockets) s.Dispose();
        _sockets.Clear();
    }

    void ReceiveLoop(UdpClient client)
    {
        var any = new IPEndPoint(IPAddress.Any, 0);
        while (!_disposed)
        {
            byte[] data;
            try { data = client.Receive(ref any); }
            catch (Exception e) when (e is SocketException or ObjectDisposedException) { return; }
            if (DnsMessage.Parse(data) is { } records) Absorb(records);
        }
    }

    public void Absorb(IEnumerable<DnsRecord> records)
    {
        bool changed = false;
        DateTime now = DateTime.UtcNow;
        lock (_lock)
        {
            foreach (var r in records)
            {
                switch (r)
                {
                    case DnsRecord.Ptr p when p.Name.Equals(ServiceName, StringComparison.OrdinalIgnoreCase):
                        if (p.Ttl == 0) { changed |= _instances.Remove(p.Target); break; }
                        if (!_instances.TryGetValue(p.Target, out var inst))
                        {
                            _instances[p.Target] = inst = new Instance();
                            changed = true;
                        }
                        inst.Seen = now;
                        break;
                    case DnsRecord.Srv s when s.Name.EndsWith("." + ServiceName, StringComparison.OrdinalIgnoreCase):
                        if (!_instances.TryGetValue(s.Name, out var i2)) _instances[s.Name] = i2 = new Instance();
                        changed |= i2.Target != s.Target || i2.Port != s.Port;
                        i2.Target = s.Target;
                        i2.Port = s.Port;
                        i2.Seen = now;
                        break;
                    case DnsRecord.A a:
                        changed |= !_hosts.TryGetValue(a.Name, out var h) || !h.Address.Equals(a.Address);
                        _hosts[a.Name] = (a.Address, now);
                        break;
                }
            }
        }
        if (changed) Changed?.Invoke();
    }

    public void Dispose()
    {
        _disposed = true;
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        _timer?.Dispose();
        lock (_lock) CloseSockets();
    }
}

public abstract record DnsRecord(string Name, uint Ttl)
{
    public sealed record Ptr(string Name, uint Ttl, string Target) : DnsRecord(Name, Ttl);
    public sealed record Srv(string Name, uint Ttl, string Target, int Port) : DnsRecord(Name, Ttl);
    public sealed record A(string Name, uint Ttl, IPAddress Address) : DnsRecord(Name, Ttl);
}

/// Minimal DNS message reader/writer (RFC 1035 + name compression), strict about bounds.
public static class DnsMessage
{
    public const ushort TypeA = 1, TypePtr = 12, TypeSrv = 33;

    public static byte[] BuildQuery(ushort id, IEnumerable<(string Name, ushort Type)> questions)
    {
        var q = questions.ToList();
        var buf = new List<byte>(64);
        void U16(int v) { buf.Add((byte)(v >> 8)); buf.Add((byte)v); }
        U16(id); U16(0); U16(q.Count); U16(0); U16(0); U16(0);
        foreach (var (name, type) in q)
        {
            foreach (string label in SplitName(name))
            {
                byte[] bytes = Encoding.UTF8.GetBytes(label);
                if (bytes.Length is 0 or > 63) throw new ArgumentException("bad DNS label");
                buf.Add((byte)bytes.Length);
                buf.AddRange(bytes);
            }
            buf.Add(0);
            U16(type);
            U16(1);   // class IN; replies come back by unicast because we don't use port 5353
        }
        return buf.ToArray();
    }

    /// Splits at dots, except the instance label (which may itself contain dots) is kept whole
    /// when the name ends with the service type.
    static IEnumerable<string> SplitName(string name)
    {
        const string service = "._screen3r._tcp.local";
        if (name.EndsWith(service, StringComparison.OrdinalIgnoreCase) && name.Length > service.Length)
        {
            yield return name[..^service.Length];
            foreach (var l in service[1..].Split('.')) yield return l;
            yield break;
        }
        foreach (var l in name.Split('.', StringSplitOptions.RemoveEmptyEntries)) yield return l;
    }

    /// All answer, authority and additional records we understand; null if malformed.
    public static List<DnsRecord>? Parse(ReadOnlySpan<byte> m)
    {
        try
        {
            if (m.Length < 12) return null;
            ushort flags = BinaryPrimitives.ReadUInt16BigEndian(m[2..]);
            if ((flags & 0x8000) == 0) return null;   // a question, not a response
            int qd = BinaryPrimitives.ReadUInt16BigEndian(m[4..]);
            int rr = BinaryPrimitives.ReadUInt16BigEndian(m[6..]) + BinaryPrimitives.ReadUInt16BigEndian(m[8..])
                   + BinaryPrimitives.ReadUInt16BigEndian(m[10..]);
            int at = 12;
            for (int i = 0; i < qd; i++)
            {
                ReadName(m, ref at);
                at += 4;
            }
            var records = new List<DnsRecord>();
            for (int i = 0; i < rr && i < 256; i++)
            {
                string name = ReadName(m, ref at);
                if (at + 10 > m.Length) return null;
                ushort type = BinaryPrimitives.ReadUInt16BigEndian(m[at..]);
                uint ttl = BinaryPrimitives.ReadUInt32BigEndian(m[(at + 4)..]);
                int len = BinaryPrimitives.ReadUInt16BigEndian(m[(at + 8)..]);
                at += 10;
                if (at + len > m.Length) return null;
                int rdata = at;
                switch (type)
                {
                    case TypePtr:
                    {
                        int p = rdata;
                        records.Add(new DnsRecord.Ptr(name, ttl, ReadName(m, ref p)));
                        break;
                    }
                    case TypeSrv when len >= 7:
                    {
                        int port = BinaryPrimitives.ReadUInt16BigEndian(m[(rdata + 4)..]);
                        int p = rdata + 6;
                        records.Add(new DnsRecord.Srv(name, ttl, ReadName(m, ref p), port));
                        break;
                    }
                    case TypeA when len == 4:
                        records.Add(new DnsRecord.A(name, ttl, new IPAddress(m.Slice(rdata, 4))));
                        break;
                }
                at = rdata + len;
            }
            return records;
        }
        catch (Exception e) when (e is IndexOutOfRangeException or ArgumentOutOfRangeException or FormatException)
        {
            return null;
        }
    }

    /// Reads a possibly compressed name; labels are joined with dots (UTF-8).
    static string ReadName(ReadOnlySpan<byte> m, ref int at)
    {
        var labels = new List<string>();
        int pos = at, jumps = 0, total = 0;
        bool jumped = false;
        while (true)
        {
            if (pos >= m.Length) throw new FormatException();
            byte len = m[pos];
            if (len == 0)
            {
                pos++;
                break;
            }
            if ((len & 0xC0) == 0xC0)
            {
                if (pos + 1 >= m.Length || ++jumps > 16) throw new FormatException();
                int target = ((len & 0x3F) << 8) | m[pos + 1];
                if (!jumped) at = pos + 2;
                jumped = true;
                pos = target;
                continue;
            }
            if ((len & 0xC0) != 0 || pos + 1 + len > m.Length) throw new FormatException();
            total += len + 1;
            if (total > 255) throw new FormatException();
            labels.Add(Encoding.UTF8.GetString(m.Slice(pos + 1, len)));
            pos += 1 + len;
        }
        if (!jumped) at = pos;
        return string.Join('.', labels);
    }
}
