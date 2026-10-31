using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Longwave.WindowsCompanion.Backend.Devices;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Longwave.WindowsCompanion.Backend.Tests;

/// <summary>
/// The sealed Controller Bridge stream. The vectors are the ones
/// QuestControllerBridge/protocol/tests/test_qcb_crypto.c pins (token
/// "device-token", Quest session A0..A7, host session B0..B7), themselves
/// checked against CryptoKit; then the receiver end to end over loopback, with
/// a fake Quest on one side and a fake broker hub on the other.
/// </summary>
public sealed class QuestControllerTests
{
    private static readonly byte[] SenderSession = Enumerable.Range(0xA0, 8).Select(i => (byte)i).ToArray();
    private static readonly byte[] HostSession = Enumerable.Range(0xB0, 8).Select(i => (byte)i).ToArray();

    [Fact]
    public void MatchesControllerBridgeVectors()
    {
        Assert.Equal("e47ce0df43433ce3", Convert.ToHexString(QuestSeal.KeyId("device-token")).ToLowerInvariant());
        Assert.Equal("2a1566dd65b6e49ac88dd557c68866e6396fac6d5482176453dfba844e6e8130",
            Convert.ToHexString(QuestSeal.SessionKey("device-token", SenderSession, default, QuestSeal.FromSender)).ToLowerInvariant());
        var hostKey = QuestSeal.SessionKey("device-token", SenderSession, HostSession, QuestSeal.FromHost);
        Assert.Equal("58b6fa90b905f93f2564e7c2b22a84e801fae6cfd03239b960c8bfcc5bbdcbfe",
            Convert.ToHexString(hostKey).ToLowerInvariant());

        var haptic = new byte[14];
        haptic[0] = 0x02;
        haptic[1] = 1;
        BinaryPrimitives.WriteSingleLittleEndian(haptic.AsSpan(2), 0.05f);
        BinaryPrimitives.WriteSingleLittleEndian(haptic.AsSpan(6), 160f);
        BinaryPrimitives.WriteSingleLittleEndian(haptic.AsSpan(10), 0.5f);
        var sealedHaptic = QuestSeal.Seal(hostKey, QuestSeal.KeyId("device-token"), HostSession, QuestSeal.FromHost, 7, haptic);
        Assert.Equal("e0010100e47ce0df43433ce3b0b1b2b3b4b5b6b70700000000000000f5c9de7a68466b21aee96dafd8c2a4ad0fcf5702bc900f60e1a035777607",
            Convert.ToHexString(sealedHaptic).ToLowerInvariant());
        Assert.Equal(haptic, QuestSeal.Open(hostKey, sealedHaptic));
        sealedHaptic[20] ^= 1;   // the counter is authenticated
        Assert.Null(QuestSeal.Open(hostKey, sealedHaptic));
    }

    [Fact]
    public void ShortIdMatchesTheBrokersDeviceKeys()
    {
        Assert.Equal("1A2B3C4D", QuestControllers.ShortId("quest-1a2b3c4d-5e6f-7788-99aa-bbccddeeff00"));
    }

    [Fact]
    public async Task OpensForwardsAndAnswersOverLoopback()
    {
        const string token = "quest-token";
        const string id = "quest-1a2b3c4d-5e6f";
        using var broker = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        using var quest = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var credentials = new List<QuestControllers.Credential> { new(id, "Desk Quest", token) };
        using var receiver = new QuestControllers(NullLogger.Instance, () => credentials, 0,
            (IPEndPoint)broker.Client.LocalEndPoint!);
        receiver.Start();
        var target = new IPEndPoint(IPAddress.Loopback, receiver.LocalPort);

        var questSession = Enumerable.Range(1, 8).Select(i => (byte)i).ToArray();
        var questKey = QuestSeal.SessionKey(token, questSession, default, QuestSeal.FromSender);
        var keyId = QuestSeal.KeyId(token);
        var state = new byte[100];
        state[0] = 0x01;
        BinaryPrimitives.WriteUInt16LittleEndian(state.AsSpan(2), 1 | 4);   // left tracked, battery
        state[96] = 77;
        state[97] = 0xFF;

        // Unsealed, or sealed with the wrong token: nothing reaches the hub.
        await quest.SendAsync(state, target);
        await quest.SendAsync(QuestSeal.Seal(QuestSeal.SessionKey("other", questSession, default, 0),
            keyId, questSession, QuestSeal.FromSender, 1, state), target);

        var sealedState = QuestSeal.Seal(questKey, keyId, questSession, QuestSeal.FromSender, 1, state);
        await quest.SendAsync(sealedState, target);

        var forwarded = await ReceiveAsync(broker);
        Assert.Equal(0x51, forwarded.Buffer[0]);
        Assert.Equal(id, Encoding.UTF8.GetString(forwarded.Buffer, 3, forwarded.Buffer[2]));
        Assert.Equal(state, forwarded.Buffer[(3 + id.Length)..]);

        // The first packet of a session gets a heartbeat back, sealed for this Quest.
        var heartbeat = await ReceiveAsync(quest);
        Assert.True(QuestSeal.TryPeek(heartbeat.Buffer, out var header));
        Assert.Equal(QuestSeal.FromHost, header.Direction);
        var hostKey = QuestSeal.SessionKey(token, questSession, header.Session, QuestSeal.FromHost);
        var beat = QuestSeal.Open(hostKey, heartbeat.Buffer);
        Assert.NotNull(beat);
        Assert.Equal(0xF1, beat![0]);

        // A replay is dropped: the hub sees nothing new.
        await quest.SendAsync(sealedState, target);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(broker, 300));

        // The hub's haptic goes back sealed to the Quest.
        var envelope = new byte[3 + id.Length + 14];
        envelope[0] = 0x51;
        envelope[1] = 1;
        envelope[2] = (byte)id.Length;
        Encoding.UTF8.GetBytes(id).CopyTo(envelope, 3);
        envelope[3 + id.Length] = 0x02;
        envelope[4 + id.Length] = 1;
        await broker.SendAsync(envelope, forwarded.RemoteEndPoint);
        var haptic = await ReceiveAsync(quest);
        var opened = QuestSeal.Open(hostKey, haptic.Buffer);
        Assert.NotNull(opened);
        Assert.Equal(0x02, opened![0]);
        Assert.Equal(1, opened[1]);

        var status = Assert.Single(receiver.Status());
        Assert.True(status.Connected);
        Assert.Equal("1A2B3C4D", status.ShortId);
        Assert.Equal(77, status.BatteryLeft);
        Assert.True(status.LeftTracked);
        Assert.False(status.RightTracked);
        Assert.False(status.Unfocused);

        // A system prompt took the headset's input: the next packet says so.
        BinaryPrimitives.WriteUInt16LittleEndian(state.AsSpan(2), 0x10);   // QCB_FLAG_UNFOCUSED
        await quest.SendAsync(QuestSeal.Seal(questKey, keyId, questSession, QuestSeal.FromSender, 2, state), target);
        await ReceiveAsync(broker);
        status = Assert.Single(receiver.Status());
        Assert.True(status.Unfocused);
        Assert.False(status.LeftTracked);

        // Revoked (or the grant taken away): its packets stop opening at once.
        credentials.Clear();
        receiver.Reload();
        await quest.SendAsync(QuestSeal.Seal(questKey, keyId, questSession, QuestSeal.FromSender, 3, state), target);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(broker, 300));
        Assert.Empty(receiver.Status());
    }

    private static async Task<UdpReceiveResult> ReceiveAsync(UdpClient client, int timeoutMs = 2000)
    {
        using var cancel = new CancellationTokenSource(timeoutMs);
        return await client.ReceiveAsync(cancel.Token);
    }
}
