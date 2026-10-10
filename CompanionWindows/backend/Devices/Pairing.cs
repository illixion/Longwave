using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Modes;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;

namespace Longwave.WindowsCompanion.Backend.Devices;

/// <summary>
/// The six-digit numeric-comparison pairing, byte for byte as
/// <c>Shared/CompanionPairing.swift</c> runs it: the headset commits to its
/// X25519 key and nonce, this PC answers with its own, the headset reveals, and
/// both show a code drawn from the whole transcript. The agreed key seals the
/// grant — a token minted for that device alone — on its way to the headset.
///
/// Messages are Swift's synthesized <c>Codable</c> JSON for the
/// <c>PairingMessage</c> enum (<c>{"commit":{…}}</c>, <c>{"deny":{}}</c>),
/// <c>Data</c> as base64, each prefixed with a little-endian UInt32 length.
/// </summary>
public static class PairingExchange
{
    public const int MaxMessageBytes = 16 * 1024;

    public static byte[] Commitment(byte[] publicKey, byte[] nonce) => SHA256.HashData(Concat(publicKey, nonce));

    public sealed record Agreement(string Code, byte[] Key);

    /// <summary>Runs once all four values are known; null when the reveal
    /// doesn't match the commitment or the key is unusable.</summary>
    public static Agreement? Agree(
        X25519PrivateKeyParameters mine,
        byte[] commitment,
        byte[] headsetPublicKey, byte[] headsetNonce,
        byte[] hostPublicKey, byte[] hostNonce)
    {
        if (!CryptographicOperations.FixedTimeEquals(Commitment(headsetPublicKey, headsetNonce), commitment)) return null;
        if (headsetPublicKey.Length != 32) return null;
        var shared = new byte[32];
        try
        {
            var agreement = new X25519Agreement();
            agreement.Init(mine);
            agreement.CalculateAgreement(new X25519PublicKeyParameters(headsetPublicKey, 0), shared, 0);
        }
        catch { return null; }
        // CryptoKit rejects an all-zero shared secret (a small-order point).
        if (shared.All(b => b == 0)) return null;
        var transcript = SHA256.HashData(Concat(commitment, hostPublicKey, hostNonce, headsetPublicKey, headsetNonce));
        var key = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, transcript, Encoding.UTF8.GetBytes("Longwave-Pair-v1"));
        var number = BinaryPrimitives.ReadUInt32BigEndian(transcript) % 1_000_000;
        return new Agreement(number.ToString("D6"), key);
    }

    /// <summary>ChaChaPoly combined form, as CryptoKit writes it: nonce,
    /// ciphertext, tag.</summary>
    public static byte[] Seal(byte[] plaintext, byte[] key)
    {
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
        cipher.Init(true, new AeadParameters(new KeyParameter(key), 128, nonce));
        var output = new byte[cipher.GetOutputSize(plaintext.Length)];
        var length = cipher.ProcessBytes(plaintext, 0, plaintext.Length, output, 0);
        cipher.DoFinal(output, length);
        return Concat(nonce, output);
    }

    public static string Display(string code) => code.Length == 6 ? $"{code[..3]} {code[3..]}" : code;

    public static byte[] Frame(JsonNode message)
    {
        var body = Encoding.UTF8.GetBytes(message.ToJsonString());
        var frame = new byte[4 + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(frame, (uint)body.Length);
        body.CopyTo(frame, 4);
        return frame;
    }

    private static byte[] Concat(params byte[][] parts)
    {
        var result = new byte[parts.Sum(p => p.Length)];
        var offset = 0;
        foreach (var part in parts) { part.CopyTo(result, offset); offset += part.Length; }
        return result;
    }
}

/// <summary>A pairing waiting on the user, as the UI shows it.</summary>
public sealed record PairingRequest(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("deviceName")] string DeviceName,
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("requested")] IReadOnlyList<string> Requested,
    [property: JsonPropertyName("offered")] IReadOnlyList<string> Offered);

/// <summary>
/// The direct pairing port (4859): headsets that found this PC over Bonjour,
/// or from its address, dial it and run <see cref="PairingExchange"/>. The
/// user approves in the Companion window (<see cref="Requested"/> →
/// <see cref="Answer"/>), choosing what the device may do.
///
/// Prompts are rationed like the Mac's: one at a time, 20 s apart, five an
/// hour, and a decline pauses requests for a while, doubling each time.
/// </summary>
public sealed class PairingService : IDisposable
{
    public const int Port = 4859;

    private readonly ILogger _log;
    private readonly DeviceRegistry _devices;
    private readonly Func<string> _hostName;
    private TcpListener? _listener;
    private CancellationTokenSource? _cancel;
    private readonly object _gate = new();
    private Pending? _pending;
    private readonly List<DateTimeOffset> _promptTimes = new();
    private DateTimeOffset _lastEnded = DateTimeOffset.MinValue;
    private DateTimeOffset _pausedUntil = DateTimeOffset.MinValue;
    private TimeSpan _declinePause = TimeSpan.FromMinutes(2);

    private sealed class Pending
    {
        public required PairingRequest Request;
        public readonly TaskCompletionSource<string[]?> Answer = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    /// <summary>A pairing needs the user (null: the pending one went away).</summary>
    public event Action<PairingRequest?>? Requested;
    public event Action<string>? Status;

    public PairingService(ILogger log, DeviceRegistry devices, Func<string> hostName)
    {
        _log = log;
        _devices = devices;
        _hostName = hostName;
    }

    public PairingRequest? CurrentRequest { get { lock (_gate) { return _pending?.Request; } } }

    public void Start()
    {
        _cancel = new CancellationTokenSource();
        _listener = new TcpListener(IPAddress.IPv6Any, Port);
        _listener.Server.DualMode = true;
        _listener.Start();
        _ = AcceptLoopAsync(_cancel.Token);
        _log.LogInformation("Direct pairing listening on {Port}", Port);
    }

    /// <summary>The user's answer: the grants ticked, or null to decline.</summary>
    public void Answer(string requestId, string[]? grants)
    {
        Pending? pending;
        lock (_gate) { pending = _pending?.Request.Id == requestId ? _pending : null; }
        pending?.Answer.TrySetResult(grants);
    }

    public void Dispose()
    {
        _cancel?.Cancel();
        try { _listener?.Stop(); } catch { }
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient tcp;
            try { tcp = await _listener!.AcceptTcpClientAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (Exception ex) { _log.LogWarning("Pairing accept failed: {Message}", ex.Message); continue; }
            if (!MayPrompt())
            {
                tcp.Close();
                continue;
            }
            _ = Task.Run(() => RunAsync(tcp, ct), ct);
        }
    }

    private bool MayPrompt()
    {
        lock (_gate)
        {
            var now = DateTimeOffset.UtcNow;
            if (_pending is not null || now < _pausedUntil || now - _lastEnded < TimeSpan.FromSeconds(20)) return false;
            _promptTimes.RemoveAll(t => now - t > TimeSpan.FromHours(1));
            if (_promptTimes.Count >= 5)
            {
                Status?.Invoke("Too many pairing requests; ignoring them for now.");
                return false;
            }
            _promptTimes.Add(now);
            return true;
        }
    }

    private async Task RunAsync(TcpClient tcp, CancellationToken ct)
    {
        using var _ = tcp;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(120));
        var stream = tcp.GetStream();
        var exchangeKey = new X25519PrivateKeyParameters(new SecureRandom());
        var hostPublic = exchangeKey.GeneratePublicKey().GetEncoded();
        var hostNonce = RandomNumberGenerator.GetBytes(32);
        Pending? pending = null;
        var outcome = "abandoned";
        var pause = TimeSpan.Zero;
        string deviceName = "A device";
        try
        {
            var commit = (await ReadAsync(stream, timeout.Token))?["commit"] as JsonObject
                ?? throw new InvalidDataException("expected commit");
            var headsetId = commit["headsetID"]?.GetValue<string>() ?? "";
            deviceName = Truncate(commit["headsetName"]?.GetValue<string>() ?? "A device", 80);
            var commitment = Convert.FromBase64String(commit["commitment"]?.GetValue<string>() ?? "");
            var requested = (commit["requested"] as JsonArray)?.Select(n => n?.GetValue<string>() ?? "").ToArray()
                ?? Grant.Offered;
            if (headsetId.Length is 0 or > 64 || commitment.Length != 32) throw new InvalidDataException("bad commit");

            await WriteAsync(stream, new JsonObject
            {
                ["macHello"] = new JsonObject
                {
                    ["macID"] = _devices.HostId,
                    ["macName"] = _hostName(),
                    ["publicKey"] = Convert.ToBase64String(hostPublic),
                    ["nonce"] = Convert.ToBase64String(hostNonce),
                },
            }, timeout.Token);

            var reveal = (await ReadAsync(stream, timeout.Token))?["reveal"] as JsonObject
                ?? throw new InvalidDataException("expected reveal");
            var headsetPublic = Convert.FromBase64String(reveal["publicKey"]?.GetValue<string>() ?? "");
            var headsetNonce = Convert.FromBase64String(reveal["nonce"]?.GetValue<string>() ?? "");
            var agreement = PairingExchange.Agree(exchangeKey, commitment, headsetPublic, headsetNonce, hostPublic, hostNonce)
                ?? throw new InvalidDataException("reveal didn't match its commitment");

            pending = new Pending
            {
                Request = new PairingRequest(Guid.NewGuid().ToString(), deviceName, agreement.Code,
                    requested.Where(g => Grant.Offered.Contains(g)).ToArray(), Grant.Offered),
            };
            lock (_gate) { _pending = pending; }
            Requested?.Invoke(pending.Request);

            // The user answers, or the device goes away, or time runs out.
            var peerGone = WatchForCloseAsync(stream, timeout.Token);
            var finished = await Task.WhenAny(pending.Answer.Task, peerGone).ConfigureAwait(false);
            var grants = finished == pending.Answer.Task ? await pending.Answer.Task : null;
            if (grants is null)
            {
                outcome = finished == pending.Answer.Task ? "declined" : "abandoned";
                if (outcome == "declined") await WriteAsync(stream, new JsonObject { ["deny"] = new JsonObject() }, timeout.Token);
                return;
            }

            var token = _devices.Enroll(headsetId, deviceName, grants);
            var grant = new JsonObject
            {
                ["token"] = token,
                ["macID"] = _devices.HostId,
                ["macName"] = _hostName(),
                ["addresses"] = new JsonArray(HostAddresses.Lan().Select(a => (JsonNode)a).ToArray()),
                ["grants"] = new JsonArray(grants.Where(g => Grant.Offered.Contains(g)).Distinct().Select(g => (JsonNode)g).ToArray()),
            };
            var sealedGrant = PairingExchange.Seal(Encoding.UTF8.GetBytes(grant.ToJsonString()), agreement.Key);
            await WriteAsync(stream, new JsonObject
            {
                ["accept"] = new JsonObject { ["sealedGrant"] = Convert.ToBase64String(sealedGrant) },
            }, timeout.Token);
            outcome = "paired";
            _log.LogInformation("Paired a device");
            // Let the grant reach the headset before the socket closes.
            await Task.Delay(500, CancellationToken.None);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or FormatException
                                       or JsonException or OperationCanceledException or InvalidOperationException)
        {
            _log.LogInformation("Pairing ended: {Message}", ex.Message);
        }
        finally
        {
            lock (_gate)
            {
                if (_pending == pending) _pending = null;
                _lastEnded = DateTimeOffset.UtcNow;
                if (outcome == "declined")
                {
                    pause = _declinePause;
                    _pausedUntil = _lastEnded + _declinePause;
                    _declinePause = TimeSpan.FromTicks(Math.Min(_declinePause.Ticks * 2, TimeSpan.FromHours(1).Ticks));
                }
                else if (outcome == "paired")
                {
                    _declinePause = TimeSpan.FromMinutes(2);
                }
            }
            if (pending is not null) Requested?.Invoke(null);
            Status?.Invoke(outcome switch
            {
                "paired" => $"Paired “{deviceName}”.",
                "declined" => $"Declined; ignoring pairing requests for {(int)pause.TotalMinutes} min.",
                _ => "Pairing didn't finish.",
            });
        }
    }

    private static string Truncate(string value, int length) => value.Length > length ? value[..length] : value;

    private static async Task<JsonNode?> ReadAsync(NetworkStream stream, CancellationToken ct)
    {
        var header = new byte[4];
        await stream.ReadExactlyAsync(header, ct);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (length > PairingExchange.MaxMessageBytes) throw new InvalidDataException("pairing message too large");
        var body = new byte[length];
        await stream.ReadExactlyAsync(body, ct);
        return JsonNode.Parse(body);
    }

    private static Task WriteAsync(NetworkStream stream, JsonNode message, CancellationToken ct) =>
        stream.WriteAsync(PairingExchange.Frame(message), ct).AsTask();

    /// <summary>Completes when the peer hangs up, so a dialog never outlives
    /// the device that asked.</summary>
    private static async Task WatchForCloseAsync(NetworkStream stream, CancellationToken ct)
    {
        var buffer = new byte[256];
        try
        {
            while (await stream.ReadAsync(buffer, ct) > 0) { }
        }
        catch { }
    }
}

/// <summary>This PC's IPv4 addresses, physical links first.</summary>
public static class HostAddresses
{
    public static IReadOnlyList<string> Lan()
    {
        try
        {
            var found = new List<(int Rank, string Address)>();
            foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;
                var rank = ni.NetworkInterfaceType switch
                {
                    System.Net.NetworkInformation.NetworkInterfaceType.Ethernet => 0,
                    System.Net.NetworkInformation.NetworkInterfaceType.Wireless80211 => 1,
                    _ => 2,
                };
                foreach (var ip in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ip.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    var text = ip.Address.ToString();
                    if (text.StartsWith("169.254.")) continue;
                    found.Add((rank, text));
                }
            }
            return found.OrderBy(x => x.Rank).Select(x => x.Address).Distinct().ToList();
        }
        catch { return Array.Empty<string>(); }
    }
}
