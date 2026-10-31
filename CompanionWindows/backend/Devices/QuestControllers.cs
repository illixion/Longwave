using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;

namespace Longwave.WindowsCompanion.Backend.Devices;

/// <summary>A paired Quest as the Companion window shows it.</summary>
public sealed record QuestControllerStatus(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("shortId")] string ShortId,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("connected")] bool Connected,
    [property: JsonPropertyName("address")] string? Address,
    [property: JsonPropertyName("packetsPerSecond")] int PacketsPerSecond,
    [property: JsonPropertyName("leftTracked")] bool LeftTracked,
    [property: JsonPropertyName("rightTracked")] bool RightTracked,
    [property: JsonPropertyName("batteryLeft")] int? BatteryLeft,
    [property: JsonPropertyName("batteryRight")] int? BatteryRight,
    [property: JsonPropertyName("lastSeen")] DateTimeOffset? LastSeen);

/// <summary>
/// Quest controllers paired with this PC (the "controllers" grant): the sealed
/// Controller Bridge stream on UDP <see cref="Grant.ControllerPort"/>.
///
/// Each datagram is opened with its device's token (<see cref="QuestSeal"/>);
/// anything that does not authenticate, comes from a device without the grant,
/// or replays an old counter is dropped unread. What opens is handed, as the
/// plain Controller Bridge packet in a small envelope naming the Quest, to the
/// broker's tracker hub on loopback (SessionBroker quest_source.h, 127.0.0.1:9523),
/// so no key ever leaves this process. The hub's haptics come back the same way
/// and go out sealed to wherever that Quest's packets last came from, with
/// heartbeats every 2 s — one socket each way, so a Quest behind NAT (Tailscale,
/// a hotel network) works.
///
/// The envelope: 'Q' (0x51), version 1, id length, the device id (UTF-8), the packet.
/// </summary>
public sealed class QuestControllers : IDisposable
{
    public const int BrokerPort = 9523;
    private const byte EnvelopeMagic = 0x51;
    private const byte EnvelopeVersion = 1;
    private const byte PacketState = 0x01, PacketHaptic = 0x02, PacketStatus = 0xF1;
    private static readonly TimeSpan HeartbeatEvery = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan ConnectedFor = TimeSpan.FromSeconds(3);

    /// <summary>A Quest that may stream here: its pairing id, name and token.</summary>
    public sealed record Credential(string Id, string Name, string Token);

    private readonly ILogger _log;
    private readonly Func<IReadOnlyList<Credential>> _credentials;
    private readonly int _port;
    private readonly IPEndPoint _broker;
    private readonly object _gate = new();
    private readonly byte[] _hostSession = RandomNumberGenerator.GetBytes(8);
    private Dictionary<string, Device> _byKeyId = new();
    private Socket? _remote;
    private Socket? _loopback;
    private CancellationTokenSource? _cancel;
    private Timer? _heartbeat;

    /// <summary>A Quest connected or went quiet.</summary>
    public event Action? Changed;
    /// <summary>Seen, for the registry's "last connected".</summary>
    public event Action<string>? Seen;

    private sealed class Device
    {
        public required Credential Credential;
        public required byte[] KeyId;
        // The Quest's current session.
        public byte[]? SenderSession;
        // Sessions this Quest has moved on from: a recording of one must not pull the
        // stream back to it (its packets still authenticate).
        public readonly Queue<string> Retired = new();
        public byte[]? ReceiveKey;
        public byte[]? SendKey;
        public ulong LastCounter;
        public ulong SendCounter;
        public IPEndPoint? EndPoint;
        public DateTimeOffset LastPacket;
        public DateTimeOffset LastHeartbeat;
        public uint Packets;
        public int WindowPackets;
        public long WindowStart;
        public int Rate;
        public bool LeftTracked, RightTracked;
        public int? BatteryLeft, BatteryRight;
        public bool WasConnected;
    }

    public QuestControllers(ILogger log, Func<IReadOnlyList<Credential>> credentials,
                            int port = Grant.ControllerPort, IPEndPoint? broker = null)
    {
        _log = log;
        _credentials = credentials;
        _port = port;
        _broker = broker ?? new IPEndPoint(IPAddress.Loopback, BrokerPort);
    }

    /// <summary>The bound remote port (useful when constructed with 0).</summary>
    public int LocalPort => (_remote?.LocalEndPoint as IPEndPoint)?.Port ?? 0;

    public void Start()
    {
        Reload();
        _cancel = new CancellationTokenSource();
        _remote = new Socket(AddressFamily.InterNetworkV6, SocketType.Dgram, ProtocolType.Udp) { DualMode = true };
        IgnoreConnectionResets(_remote);
        _remote.Bind(new IPEndPoint(IPAddress.IPv6Any, _port));
        _loopback = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        IgnoreConnectionResets(_loopback);
        _loopback.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        _ = ReceiveRemoteAsync(_cancel.Token);
        _ = ReceiveLoopbackAsync(_cancel.Token);
        _heartbeat = new Timer(_ => Tick(), null, TimeSpan.FromMilliseconds(500), TimeSpan.FromMilliseconds(500));
        _log.LogInformation("Quest controllers: listening on UDP {Port}", LocalPort);
    }

    /// <summary>Re-read who may stream: after a pairing, a grant change or a revoke.
    /// A Quest that lost its grant is dropped at once.</summary>
    public void Reload()
    {
        var next = new Dictionary<string, Device>();
        lock (_gate)
        {
            var old = _byKeyId.Values.ToDictionary(d => d.Credential.Id);
            foreach (var credential in _credentials())
            {
                var keyId = QuestSeal.KeyId(credential.Token);
                var device = old.TryGetValue(credential.Id, out var existing) && existing.Credential.Token == credential.Token
                    ? existing
                    : new Device { Credential = credential, KeyId = keyId };
                device.Credential = credential;
                next[Convert.ToHexString(keyId)] = device;
            }
            _byKeyId = next;
        }
        Changed?.Invoke();
    }

    public IReadOnlyList<QuestControllerStatus> Status()
    {
        var now = DateTimeOffset.UtcNow;
        lock (_gate)
        {
            return _byKeyId.Values.Select(d =>
            {
                var connected = d.EndPoint is not null && now - d.LastPacket < ConnectedFor;
                return new QuestControllerStatus(d.Credential.Id, ShortId(d.Credential.Id), d.Credential.Name,
                    connected, connected ? Display(d.EndPoint!) : null, connected ? d.Rate : 0,
                    connected && d.LeftTracked, connected && d.RightTracked, d.BatteryLeft, d.BatteryRight,
                    d.LastPacket == default ? null : d.LastPacket);
            }).OrderBy(s => s.Name).ToList();
        }
    }

    /// <summary>What the broker's hub calls this Quest: "quest:&lt;ShortId&gt;-left".
    /// The first 8 letters or digits of the pairing id, upper-cased (quest_source.cpp).</summary>
    public static string ShortId(string deviceId)
    {
        var id = deviceId.StartsWith("quest-", StringComparison.Ordinal) ? deviceId[6..] : deviceId;
        return new string(id.Where(char.IsAsciiLetterOrDigit).Take(8).Select(char.ToUpperInvariant).ToArray());
    }

    public void Dispose()
    {
        _cancel?.Cancel();
        _heartbeat?.Dispose();
        _remote?.Dispose();
        _loopback?.Dispose();
    }

    private async Task ReceiveRemoteAsync(CancellationToken ct)
    {
        var buffer = new byte[2048];
        while (!ct.IsCancellationRequested)
        {
            SocketReceiveFromResult result;
            try
            {
                result = await _remote!.ReceiveFromAsync(buffer, SocketFlags.None, new IPEndPoint(IPAddress.IPv6Any, 0), ct)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException) { continue; }
            try
            {
                HandleRemote(buffer.AsSpan(0, result.ReceivedBytes), (IPEndPoint)result.RemoteEndPoint);
            }
            catch (Exception ex)
            {
                _log.LogDebug("Quest packet dropped: {Message}", ex.Message);
            }
        }
    }

    private void HandleRemote(ReadOnlySpan<byte> packet, IPEndPoint from)
    {
        if (!QuestSeal.TryPeek(packet, out var header) || header.Direction != QuestSeal.FromSender) return;
        Device? device;
        byte[] inner;
        bool newSession = false, becameConnected;
        string id;
        lock (_gate)
        {
            if (!_byKeyId.TryGetValue(Convert.ToHexString(header.KeyId), out device)) return;
            var sameSession = device.SenderSession is not null && device.SenderSession.AsSpan().SequenceEqual(header.Session);
            if (sameSession && header.Counter <= device.LastCounter) return;   // replayed or reordered
            if (!sameSession && device.Retired.Contains(Convert.ToHexString(header.Session))) return;
            var key = sameSession
                ? device.ReceiveKey!
                : QuestSeal.SessionKey(device.Credential.Token, header.Session, default, QuestSeal.FromSender);
            var opened = QuestSeal.Open(key, packet);
            if (opened is null) return;
            inner = opened;
            if (!sameSession)
            {
                // A new stream from this Quest (it restarted, or a second one took over):
                // its keys replace the old ones, and replies start a fresh counter.
                newSession = true;
                if (device.SenderSession is not null)
                {
                    device.Retired.Enqueue(Convert.ToHexString(device.SenderSession));
                    while (device.Retired.Count > 16) device.Retired.Dequeue();
                }
                device.SenderSession = header.Session;
                device.ReceiveKey = key;
                device.SendKey = QuestSeal.SessionKey(device.Credential.Token, header.Session, _hostSession, QuestSeal.FromHost);
                device.SendCounter = 0;
            }
            device.LastCounter = header.Counter;
            device.EndPoint = from;
            device.LastPacket = DateTimeOffset.UtcNow;
            device.Packets++;
            CountRate(device);
            if (inner.Length >= 100 && inner[0] == PacketState)
            {
                var flags = BinaryPrimitives.ReadUInt16LittleEndian(inner.AsSpan(2));
                device.LeftTracked = (flags & 1) != 0;
                device.RightTracked = (flags & 2) != 0;
                if ((flags & 4) != 0)
                {
                    device.BatteryLeft = inner[96] <= 100 ? inner[96] : null;
                    device.BatteryRight = inner[97] <= 100 ? inner[97] : null;
                }
            }
            becameConnected = !device.WasConnected;
            device.WasConnected = true;
            id = device.Credential.Id;
        }

        if (inner.Length >= 100 && inner[0] == PacketState) Forward(id, inner);
        if (newSession) SendHeartbeat(device);
        if (becameConnected)
        {
            _log.LogInformation("Quest controllers: {Name} connected", device.Credential.Name);
            Seen?.Invoke(id);
            Changed?.Invoke();
        }
    }

    private static void CountRate(Device device)
    {
        var now = Environment.TickCount64;
        if (now - device.WindowStart >= 1000)
        {
            device.Rate = device.WindowStart == 0 ? 0 : device.WindowPackets;
            device.WindowStart = now;
            device.WindowPackets = 0;
        }
        device.WindowPackets++;
    }

    private void Forward(string deviceId, byte[] inner)
    {
        var id = Encoding.UTF8.GetBytes(deviceId);
        if (id.Length is 0 or > 64) return;
        var envelope = new byte[3 + id.Length + inner.Length];
        envelope[0] = EnvelopeMagic;
        envelope[1] = EnvelopeVersion;
        envelope[2] = (byte)id.Length;
        id.CopyTo(envelope, 3);
        inner.CopyTo(envelope, 3 + id.Length);
        try { _loopback?.SendTo(envelope, _broker); }
        catch (SocketException) { /* no broker running: nothing to drive */ }
        catch (ObjectDisposedException) { }
    }

    private async Task ReceiveLoopbackAsync(CancellationToken ct)
    {
        var buffer = new byte[512];
        while (!ct.IsCancellationRequested)
        {
            SocketReceiveFromResult result;
            try
            {
                result = await _loopback!.ReceiveFromAsync(buffer, SocketFlags.None, new IPEndPoint(IPAddress.Any, 0), ct)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException) { continue; }
            // Only the hub on this machine routes haptics.
            if (!IPAddress.IsLoopback(((IPEndPoint)result.RemoteEndPoint).Address)) continue;
            HandleLoopback(buffer, result.ReceivedBytes);
        }
    }

    /// <summary>A haptic from the hub, in its envelope: sealed and sent to that Quest.</summary>
    private void HandleLoopback(byte[] buffer, int length)
    {
        var data = buffer.AsSpan(0, length);
        if (data.Length < 3 || data[0] != EnvelopeMagic || data[1] != EnvelopeVersion) return;
        int idLength = data[2];
        if (idLength == 0 || data.Length < 3 + idLength + 14) return;
        var id = Encoding.UTF8.GetString(data.Slice(3, idLength));
        var inner = data[(3 + idLength)..];
        if (inner[0] != PacketHaptic) return;
        SendSealed(id, inner[..14].ToArray());
    }

    private void Tick()
    {
        List<Device> due = new();
        var changed = false;
        var now = DateTimeOffset.UtcNow;
        lock (_gate)
        {
            foreach (var device in _byKeyId.Values)
            {
                var connected = device.EndPoint is not null && now - device.LastPacket < ConnectedFor;
                if (device.WasConnected && !connected)
                {
                    device.WasConnected = false;
                    changed = true;
                    _log.LogInformation("Quest controllers: {Name} went quiet", device.Credential.Name);
                }
                if (connected && now - device.LastHeartbeat >= HeartbeatEvery) due.Add(device);
            }
        }
        foreach (var device in due) SendHeartbeat(device);
        if (changed) Changed?.Invoke();
    }

    private void SendHeartbeat(Device device)
    {
        var status = new byte[16];
        status[0] = PacketStatus;
        status[1] = 3;   // QCB_PROTOCOL_VERSION
        BinaryPrimitives.WriteUInt16LittleEndian(status.AsSpan(2), 1);   // QCB_STATUS_DRIVER_READY
        // nonce 0: an unsolicited heartbeat, not a probe reply
        uint packets;
        lock (_gate)
        {
            packets = device.Packets;
            device.LastHeartbeat = DateTimeOffset.UtcNow;
        }
        BinaryPrimitives.WriteUInt32LittleEndian(status.AsSpan(8), packets);
        SendSealed(device.Credential.Id, status);
    }

    private void SendSealed(string deviceId, byte[] inner)
    {
        byte[] datagram;
        IPEndPoint to;
        lock (_gate)
        {
            var device = _byKeyId.Values.FirstOrDefault(d => d.Credential.Id == deviceId);
            if (device?.EndPoint is null || device.SendKey is null) return;
            datagram = QuestSeal.Seal(device.SendKey, device.KeyId, _hostSession, QuestSeal.FromHost,
                ++device.SendCounter, inner);
            to = device.EndPoint;
        }
        try { _remote?.SendTo(datagram, to); }
        catch (SocketException) { }
        catch (ObjectDisposedException) { }
    }

    private static string Display(IPEndPoint endPoint)
    {
        var address = endPoint.Address.IsIPv4MappedToIPv6 ? endPoint.Address.MapToIPv4() : endPoint.Address;
        return address.ToString();
    }

    /// <summary>Windows reports an ICMP port-unreachable from an earlier send as a
    /// ConnectionReset on the next receive and, without this, keeps doing it.</summary>
    private static void IgnoreConnectionResets(Socket socket)
    {
        if (!OperatingSystem.IsWindows()) return;
        const int SIO_UDP_CONNRESET = unchecked((int)0x9800000C);
        try { socket.IOControl(SIO_UDP_CONNRESET, new byte[] { 0, 0, 0, 0 }, null); }
        catch (Exception) { }
    }
}
