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
    [property: JsonPropertyName("lastSeen")] DateTimeOffset? LastSeen,
    // The Quest app runs but the headset gave input to something else (a system
    // dialog or menu): why nothing is tracked. False from apps before 2.2.
    [property: JsonPropertyName("unfocused")] bool Unfocused = false);

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
    private const byte PacketSessionChallenge = 0xF2, PacketSessionConfirm = 0xF3, PacketSessionAccept = 0xF4;
    private static readonly TimeSpan HeartbeatEvery = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan ConnectedFor = TimeSpan.FromSeconds(3);
    private const long PendingSessionLifetimeMs = 5_000;
    private const long ChallengeResendIntervalMs = 500;

    /// <summary>A Quest that may stream here: its pairing id, name and token.</summary>
    public sealed record Credential(string Id, string Name, string Token);

    private readonly ILogger _log;
    private readonly Func<IReadOnlyList<Credential>> _credentials;
    private readonly int _port;
    private readonly IPEndPoint _broker;
    private readonly object _gate = new();
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
        public byte[]? HostSession;
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
        public bool LeftTracked, RightTracked, Unfocused;
        public int? BatteryLeft, BatteryRight;
        public bool WasConnected;
        public PendingSession? Pending;
        public byte[]? LastAcceptedChallenge;
        public byte[]? LastAcceptPacket;
    }

    private sealed class PendingSession
    {
        public required byte[] SenderSession;
        public required byte[] HostSession;
        public required byte[] ReceiveKey;
        public required byte[] Challenge;
        public required byte[] ChallengePacket;
        public required IPEndPoint EndPoint;
        public required ulong HighestSenderCounter;
        public required ulong HostChallengeCounter;
        public required bool IsEndpointMigration;
        public required long CreatedAt;
        public long LastChallengeSentAt;
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
                    d.LastPacket == default ? null : d.LastPacket, connected && d.Unfocused);
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
        byte[]? inner = null;
        byte[]? challengePacket = null;
        byte[]? acceptPacket = null;
        IPEndPoint? acceptEndpoint = null;
        bool becameConnected = false;
        string? id = null;
        bool acceptedSession = false;
        lock (_gate)
        {
            if (!_byKeyId.TryGetValue(Convert.ToHexString(header.KeyId), out device)) return;
            var sameSession = device.SenderSession is not null && device.SenderSession.AsSpan().SequenceEqual(header.Session);
            if (sameSession && header.Counter <= device.LastCounter) return;   // replayed or reordered
            var key = sameSession ? device.ReceiveKey! : QuestSeal.SessionKey(
                device.Credential.Token, header.Session, default, QuestSeal.FromSender);
            var opened = QuestSeal.Open(key, packet);
            if (opened is null) return;
            var now = Environment.TickCount64;
            if (device.Pending is { } pending && now - pending.CreatedAt >= PendingSessionLifetimeMs)
                device.Pending = null;

            if (sameSession && device.EndPoint is not null && !device.EndPoint.Equals(from))
            {
                // An authenticated packet can still be a captured datagram
                // replayed from another source. Do not retarget haptics or
                // accept input at the new address until it answers a challenge.
                var candidate = device.Pending;
                if (candidate is not null && candidate.IsEndpointMigration &&
                    candidate.SenderSession.AsSpan().SequenceEqual(header.Session) && candidate.EndPoint.Equals(from))
                {
                    if (IsConfirmation(opened, candidate) &&
                        header.Counter > Math.Max(candidate.HighestSenderCounter, device.LastCounter) &&
                        device.SendCounter < ulong.MaxValue)
                    {
                        device.LastCounter = header.Counter;
                        device.EndPoint = from;
                        device.Pending = null;
                        acceptPacket = MakeSessionAccept(device, candidate);
                        CacheSessionAccept(device, candidate, acceptPacket);
                        acceptEndpoint = from;
                        acceptedSession = true;
                    }
                    else if (now - candidate.LastChallengeSentAt >= ChallengeResendIntervalMs)
                    {
                        candidate.HighestSenderCounter = Math.Max(candidate.HighestSenderCounter, header.Counter);
                        candidate.LastChallengeSentAt = now;
                        challengePacket = candidate.ChallengePacket;
                    }
                    else candidate.HighestSenderCounter = Math.Max(candidate.HighestSenderCounter, header.Counter);
                }
                else if (candidate is null && opened.Length == 100 && opened[0] == PacketState)
                    challengePacket = BeginPendingSession(device, header.Session, key, from,
                        header.Counter, now, endpointMigration: true);
            }
            else if (sameSession)
            {
                device.LastCounter = header.Counter;
                inner = opened;
                device.EndPoint = from;
                if (IsConfirmation(inner, device.LastAcceptedChallenge) && device.LastAcceptPacket is not null)
                {
                    // The previous accept may have been lost. Re-send the same
                    // ciphertext (same key, nonce and plaintext), never reseal
                    // a different packet under a reused nonce.
                    acceptPacket = device.LastAcceptPacket;
                    acceptEndpoint = from;
                }
                else if (inner.Length == 100 && inner[0] == PacketState)
                {
                    UpdateState(device, inner);
                    becameConnected = !device.WasConnected;
                    device.WasConnected = true;
                    id = device.Credential.Id;
                }
            }
            else
            {
                var candidate = device.Pending;
                if (candidate is not null &&
                    !candidate.IsEndpointMigration && candidate.SenderSession.AsSpan().SequenceEqual(header.Session) &&
                    candidate.EndPoint.Equals(from))
                {
                    if (IsConfirmation(opened, candidate) && header.Counter > candidate.HighestSenderCounter &&
                        device.SendCounter < ulong.MaxValue)
                    {
                        device.SenderSession = header.Session;
                        device.ReceiveKey = candidate.ReceiveKey;
                        device.SendKey = QuestSeal.SessionKey(
                            device.Credential.Token, header.Session, candidate.HostSession, QuestSeal.FromHost);
                        device.HostSession = candidate.HostSession;
                        device.LastCounter = header.Counter;
                        device.SendCounter = candidate.HostChallengeCounter;
                        device.EndPoint = from;
                        device.Pending = null;
                        acceptPacket = MakeSessionAccept(device, candidate);
                        CacheSessionAccept(device, candidate, acceptPacket);
                        acceptEndpoint = from;
                        acceptedSession = true;
                    }
                    else if (now - candidate.LastChallengeSentAt >= ChallengeResendIntervalMs)
                    {
                        candidate.HighestSenderCounter = Math.Max(candidate.HighestSenderCounter, header.Counter);
                        candidate.LastChallengeSentAt = now;
                        challengePacket = candidate.ChallengePacket;
                    }
                    else candidate.HighestSenderCounter = Math.Max(candidate.HighestSenderCounter, header.Counter);
                }
                else if (candidate is null && opened.Length == 100 && opened[0] == PacketState)
                {
                    challengePacket = BeginPendingSession(device, header.Session, key, from,
                        header.Counter, now, endpointMigration: false);
                }
            }
        }

        if (challengePacket is not null) TrySend(challengePacket, from);
        if (acceptPacket is not null && acceptEndpoint is not null)
        {
            TrySend(acceptPacket, acceptEndpoint);
            SendHeartbeat(device!);
        }
        if (inner is { Length: 100 } && inner[0] == PacketState && id is not null) Forward(id, inner);
        if (becameConnected && id is not null && device is not null)
        {
            _log.LogInformation("Quest controllers: {Name} connected", device.Credential.Name);
            Seen?.Invoke(id);
            Changed?.Invoke();
        }
        if (acceptedSession && device is not null)
            _log.LogInformation("Quest controllers: {Name} authenticated a fresh stream session", device.Credential.Name);
    }

    private static bool IsConfirmation(byte[] inner, PendingSession pending) =>
        IsConfirmation(inner, pending.Challenge);

    private static bool IsConfirmation(byte[] inner, byte[]? challenge) =>
        challenge is not null &&
        inner.Length == 1 + QuestSeal.ChallengeSize && inner[0] == PacketSessionConfirm &&
        CryptographicOperations.FixedTimeEquals(inner.AsSpan(1), challenge);

    private byte[]? BeginPendingSession(Device device, byte[] senderSession, byte[] receiveKey,
                                       IPEndPoint from, ulong firstCounter, long now,
                                       bool endpointMigration)
    {
        var challenge = RandomNumberGenerator.GetBytes(QuestSeal.ChallengeSize);
        var payload = new byte[1 + QuestSeal.SessionSize + QuestSeal.ChallengeSize];
        payload[0] = PacketSessionChallenge;
        senderSession.CopyTo(payload, 1);
        challenge.CopyTo(payload, 1 + QuestSeal.SessionSize);

        byte[] hostKey;
        byte[] hostSession;
        ulong hostCounter;
        if (endpointMigration)
        {
            if (device.SendKey is null || device.HostSession is null || device.SendCounter == ulong.MaxValue) return null;
            hostKey = device.SendKey;
            hostSession = device.HostSession;
            hostCounter = ++device.SendCounter;
        }
        else
        {
            // A fresh host session also makes retries after a pending-session
            // timeout use a new key, so resetting the counter to 1 cannot reuse
            // an AEAD nonce even when the Quest repeats its sender session.
            hostSession = RandomNumberGenerator.GetBytes(QuestSeal.SessionSize);
            hostKey = QuestSeal.SessionKey(device.Credential.Token, senderSession, hostSession, QuestSeal.FromHost);
            hostCounter = 1;
        }
        var sealedChallenge = QuestSeal.Seal(hostKey, device.KeyId, hostSession,
            QuestSeal.FromHost, hostCounter, payload);
        device.Pending = new PendingSession
        {
            SenderSession = senderSession,
            HostSession = hostSession,
            ReceiveKey = receiveKey,
            Challenge = challenge,
            ChallengePacket = sealedChallenge,
            EndPoint = from,
            HighestSenderCounter = firstCounter,
            HostChallengeCounter = hostCounter,
            IsEndpointMigration = endpointMigration,
            CreatedAt = now,
            LastChallengeSentAt = now,
        };
        return sealedChallenge;
    }

    private byte[] MakeSessionAccept(Device device, PendingSession pending)
    {
        var accept = new byte[1 + QuestSeal.ChallengeSize];
        accept[0] = PacketSessionAccept;
        pending.Challenge.CopyTo(accept, 1);
        return QuestSeal.Seal(device.SendKey!, device.KeyId, pending.HostSession,
            QuestSeal.FromHost, ++device.SendCounter, accept);
    }

    private static void CacheSessionAccept(Device device, PendingSession pending, byte[] acceptPacket)
    {
        device.LastAcceptedChallenge = pending.Challenge.ToArray();
        device.LastAcceptPacket = acceptPacket;
    }

    private static void UpdateState(Device device, byte[] inner)
    {
        device.LastPacket = DateTimeOffset.UtcNow;
        device.Packets++;
        CountRate(device);
        var flags = BinaryPrimitives.ReadUInt16LittleEndian(inner.AsSpan(2));
        device.LeftTracked = (flags & 1) != 0;
        device.RightTracked = (flags & 2) != 0;
        device.Unfocused = (flags & 0x10) != 0;
        if ((flags & 4) != 0)
        {
            device.BatteryLeft = inner[96] <= 100 ? inner[96] : null;
            device.BatteryRight = inner[97] <= 100 ? inner[97] : null;
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
            if (device?.EndPoint is null || device.SendKey is null || device.SendCounter == ulong.MaxValue) return;
            datagram = QuestSeal.Seal(device.SendKey, device.KeyId, device.HostSession!, QuestSeal.FromHost,
                ++device.SendCounter, inner);
            to = device.EndPoint;
        }
        TrySend(datagram, to);
    }

    private void TrySend(byte[] datagram, IPEndPoint to)
    {
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
