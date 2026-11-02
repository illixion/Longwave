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
/// "device-token", Quest session A0..AF, host session B0..BF), themselves
/// checked against CryptoKit; then the receiver end to end over loopback, with
/// a fake Quest on one side and a fake broker hub on the other.
/// </summary>
public sealed class QuestControllerTests
{
    private static readonly byte[] SenderSession = Enumerable.Range(0xA0, QuestSeal.SessionSize).Select(i => (byte)i).ToArray();
    private static readonly byte[] HostSession = Enumerable.Range(0xB0, QuestSeal.SessionSize).Select(i => (byte)i).ToArray();

    [Fact]
    public void MatchesControllerBridgeVectors()
    {
        Assert.Equal("e47ce0df43433ce3", Convert.ToHexString(QuestSeal.KeyId("device-token")).ToLowerInvariant());
        Assert.Equal("811c0cee6aaac0b7f5de670f13afb2ecf519d8b872c0b89ec60e3ed2ba30ea36",
            Convert.ToHexString(QuestSeal.SessionKey("device-token", SenderSession, default, QuestSeal.FromSender)).ToLowerInvariant());
        var hostKey = QuestSeal.SessionKey("device-token", SenderSession, HostSession, QuestSeal.FromHost);
        Assert.Equal("1bf5f1957ab1d1679a8ceddc475679e79df12918b83c2f3c6a64dcbf63c438d1",
            Convert.ToHexString(hostKey).ToLowerInvariant());

        var haptic = new byte[14];
        haptic[0] = 0x02;
        haptic[1] = 1;
        BinaryPrimitives.WriteSingleLittleEndian(haptic.AsSpan(2), 0.05f);
        BinaryPrimitives.WriteSingleLittleEndian(haptic.AsSpan(6), 160f);
        BinaryPrimitives.WriteSingleLittleEndian(haptic.AsSpan(10), 0.5f);
        var sealedHaptic = QuestSeal.Seal(hostKey, QuestSeal.KeyId("device-token"), HostSession, QuestSeal.FromHost, 7, haptic);
        Assert.Equal("e0020100e47ce0df43433ce3b0b1b2b3b4b5b6b7b8b9babbbcbdbebf0700000000000000213e2fea207bbbad448395e28b61fd6257cef1ff66791088d87648c7022d",
            Convert.ToHexString(sealedHaptic).ToLowerInvariant());
        Assert.Equal(haptic, QuestSeal.Open(hostKey, sealedHaptic));
        sealedHaptic[28] ^= 1;   // the counter is authenticated
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

        var questSession = Enumerable.Range(1, QuestSeal.SessionSize).Select(i => (byte)i).ToArray();
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

        // An unknown sender session is only a proposal. The host challenges it;
        // no controller packet reaches the broker until the challenge round trip.
        var challengeDatagram = await ReceiveAsync(quest);
        Assert.True(QuestSeal.TryPeek(challengeDatagram.Buffer, out var challengeHeader));
        Assert.Equal(QuestSeal.FromHost, challengeHeader.Direction);
        var hostKey = QuestSeal.SessionKey(token, questSession, challengeHeader.Session, QuestSeal.FromHost);
        var challenge = QuestSeal.Open(hostKey, challengeDatagram.Buffer);
        Assert.NotNull(challenge);
        Assert.Equal(0xF2, challenge![0]);
        Assert.Equal(questSession, challenge.AsSpan(1, QuestSeal.SessionSize).ToArray());
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(broker, 150));

        // A later valid packet from this pending session advances its replay
        // window. An older captured confirmation must not authenticate it.
        await Task.Delay(550);
        await quest.SendAsync(QuestSeal.Seal(questKey, keyId, questSession, QuestSeal.FromSender, 3, state), target);
        var repeatedChallenge = await ReceiveAsync(quest);
        Assert.Equal(challengeDatagram.Buffer, repeatedChallenge.Buffer);
        var confirm = new byte[1 + QuestSeal.ChallengeSize];
        confirm[0] = 0xF3;
        challenge.AsSpan(1 + QuestSeal.SessionSize, QuestSeal.ChallengeSize).CopyTo(confirm.AsSpan(1));
        await quest.SendAsync(QuestSeal.Seal(questKey, keyId, questSession, QuestSeal.FromSender, 2, confirm), target);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(broker, 150));
        await quest.SendAsync(QuestSeal.Seal(questKey, keyId, questSession, QuestSeal.FromSender, 4, confirm), target);

        var acceptDatagram = await ReceiveAsync(quest);
        Assert.True(QuestSeal.TryPeek(acceptDatagram.Buffer, out var acceptHeader));
        Assert.Equal(challengeHeader.Session, acceptHeader.Session);
        var accepted = QuestSeal.Open(hostKey, acceptDatagram.Buffer);
        Assert.NotNull(accepted);
        Assert.Equal(0xF4, accepted![0]);
        Assert.Equal(confirm.AsSpan(1).ToArray(), accepted.AsSpan(1).ToArray());
        var heartbeat = await ReceiveAsync(quest);
        Assert.True(QuestSeal.TryPeek(heartbeat.Buffer, out var heartbeatHeader));
        Assert.Equal(QuestSeal.FromHost, heartbeatHeader.Direction);
        Assert.Equal(0xF1, QuestSeal.Open(hostKey, heartbeat.Buffer)![0]);

        // If the accept was lost, the sender retries the same challenge with a
        // fresh sender counter. The host must return the original ciphertext,
        // not encrypt under a reused host nonce.
        await quest.SendAsync(QuestSeal.Seal(questKey, keyId, questSession, QuestSeal.FromSender, 6, confirm), target);
        var retriedAccept = await ReceiveAsync(quest);
        Assert.Equal(acceptDatagram.Buffer, retriedAccept.Buffer);
        var retryHeartbeat = await ReceiveAsync(quest);
        Assert.Equal(0xF1, QuestSeal.Open(hostKey, retryHeartbeat.Buffer)![0]);

        // Only a later state packet is forwarded after the accept.
        var sealedStateAfterAccept = QuestSeal.Seal(questKey, keyId, questSession, QuestSeal.FromSender, 7, state);
        await quest.SendAsync(sealedStateAfterAccept, target);

        var forwarded = await ReceiveAsync(broker);
        Assert.Equal(0x51, forwarded.Buffer[0]);
        Assert.Equal(id, Encoding.UTF8.GetString(forwarded.Buffer, 3, forwarded.Buffer[2]));
        Assert.Equal(state, forwarded.Buffer[(3 + id.Length)..]);

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
        await quest.SendAsync(QuestSeal.Seal(questKey, keyId, questSession, QuestSeal.FromSender, 8, state), target);
        await ReceiveAsync(broker);
        status = Assert.Single(receiver.Status());
        Assert.True(status.Unfocused);
        Assert.False(status.LeftTracked);

        // Revoked (or the grant taken away): its packets stop opening at once.
        credentials.Clear();
        receiver.Reload();
        await quest.SendAsync(QuestSeal.Seal(questKey, keyId, questSession, QuestSeal.FromSender, 9, state), target);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(broker, 300));
        Assert.Empty(receiver.Status());
    }

    [Fact]
    public async Task ReplayedPacketAfterHostRestartCannotStartAControllerSession()
    {
        const string token = "restart-token";
        const string id = "quest-restart";
        using var broker = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        using var quest = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var credentials = new List<QuestControllers.Credential> { new(id, "Restart Quest", token) };
        var firstHost = new QuestControllers(NullLogger.Instance, () => credentials, 0,
            (IPEndPoint)broker.Client.LocalEndPoint!);
        firstHost.Start();

        var session = Enumerable.Range(0x30, QuestSeal.SessionSize).Select(i => (byte)i).ToArray();
        var senderKey = QuestSeal.SessionKey(token, session, default, QuestSeal.FromSender);
        var keyId = QuestSeal.KeyId(token);
        var state = new byte[100];
        state[0] = 0x01;
        var captured = QuestSeal.Seal(senderKey, keyId, session, QuestSeal.FromSender, 1, state);
        var port = firstHost.LocalPort;
        var target = new IPEndPoint(IPAddress.Loopback, port);

        await quest.SendAsync(captured, target);
        var firstChallenge = await ReceiveAsync(quest);
        var firstPlain = OpenChallenge(token, session, firstChallenge.Buffer, out _);
        Assert.Equal(0xF2, firstPlain[0]);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(broker, 150));

        firstHost.Dispose();
        using var restartedHost = new QuestControllers(NullLogger.Instance, () => credentials, port,
            (IPEndPoint)broker.Client.LocalEndPoint!);
        restartedHost.Start();

        // Replaying exactly the captured datagram after a restart gets a fresh
        // challenge, but the replay alone still cannot inject its old state.
        await quest.SendAsync(captured, target);
        var restartedChallenge = await ReceiveAsync(quest);
        var challengeHeader = default(QuestSeal.Header);
        var challenge = OpenChallenge(token, session, restartedChallenge.Buffer, out challengeHeader);
        Assert.Equal(0xF2, challenge[0]);
        Assert.NotEqual(firstPlain.AsSpan(1 + QuestSeal.SessionSize).ToArray(),
            challenge.AsSpan(1 + QuestSeal.SessionSize).ToArray());
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(broker, 150));

        var confirm = new byte[1 + QuestSeal.ChallengeSize];
        confirm[0] = 0xF3;
        challenge.AsSpan(1 + QuestSeal.SessionSize, QuestSeal.ChallengeSize).CopyTo(confirm.AsSpan(1));
        await quest.SendAsync(QuestSeal.Seal(senderKey, keyId, session, QuestSeal.FromSender, 2, confirm), target);
        var acceptDatagram = await ReceiveAsync(quest);
        Assert.True(QuestSeal.TryPeek(acceptDatagram.Buffer, out var acceptHeader));
        Assert.Equal(challengeHeader.Session, acceptHeader.Session);
        var hostKey = QuestSeal.SessionKey(token, session, challengeHeader.Session, QuestSeal.FromHost);
        Assert.Equal(0xF4, QuestSeal.Open(hostKey, acceptDatagram.Buffer)![0]);

        await ReceiveAsync(quest); // authenticated heartbeat after accept
        await quest.SendAsync(QuestSeal.Seal(senderKey, keyId, session, QuestSeal.FromSender, 3, state), target);
        var forwarded = await ReceiveAsync(broker);
        Assert.Equal(state, forwarded.Buffer[(3 + id.Length)..]);
    }

    [Fact]
    public async Task ExpiredHandshakeRetryGetsANewHostSessionKey()
    {
        const string token = "timeout-token";
        const string id = "quest-timeout";
        using var broker = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        using var quest = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var credentials = new List<QuestControllers.Credential> { new(id, "Timeout Quest", token) };
        using var receiver = new QuestControllers(NullLogger.Instance, () => credentials, 0,
            (IPEndPoint)broker.Client.LocalEndPoint!);
        receiver.Start();
        var target = new IPEndPoint(IPAddress.Loopback, receiver.LocalPort);
        var session = Enumerable.Range(0x60, QuestSeal.SessionSize).Select(i => (byte)i).ToArray();
        var senderKey = QuestSeal.SessionKey(token, session, default, QuestSeal.FromSender);
        var keyId = QuestSeal.KeyId(token);
        var state = new byte[100];
        state[0] = 0x01;
        var capturedProposal = QuestSeal.Seal(senderKey, keyId, session, QuestSeal.FromSender, 1, state);

        await quest.SendAsync(capturedProposal, target);
        var first = await ReceiveAsync(quest);
        OpenChallenge(token, session, first.Buffer, out var firstHeader);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(broker, 150));

        // Once the pending exchange expires, replaying the same proposal must
        // not reuse counter 1 under the previous challenge's host key.
        await Task.Delay(5_200);
        await quest.SendAsync(capturedProposal, target);
        var second = await ReceiveAsync(quest);
        OpenChallenge(token, session, second.Buffer, out var secondHeader);
        Assert.NotEqual(firstHeader.Session, secondHeader.Session);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(broker, 150));
    }

    [Fact]
    public async Task AuthenticatedTrafficCannotRetargetTheHapticEndpointWithoutAChallenge()
    {
        const string token = "endpoint-token";
        const string id = "quest-endpoint";
        using var broker = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        using var quest = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        using var movedQuest = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var credentials = new List<QuestControllers.Credential> { new(id, "Endpoint Quest", token) };
        using var receiver = new QuestControllers(NullLogger.Instance, () => credentials, 0,
            (IPEndPoint)broker.Client.LocalEndPoint!);
        receiver.Start();
        var target = new IPEndPoint(IPAddress.Loopback, receiver.LocalPort);
        var session = Enumerable.Range(0x50, QuestSeal.SessionSize).Select(i => (byte)i).ToArray();
        var senderKey = QuestSeal.SessionKey(token, session, default, QuestSeal.FromSender);
        var keyId = QuestSeal.KeyId(token);
        var state = new byte[100];
        state[0] = 0x01;

        await quest.SendAsync(QuestSeal.Seal(senderKey, keyId, session, QuestSeal.FromSender, 1, state), target);
        var initialChallenge = await ReceiveAsync(quest);
        var challenge = OpenChallenge(token, session, initialChallenge.Buffer, out var firstHostHeader);
        var firstHostKey = QuestSeal.SessionKey(token, session, firstHostHeader.Session, QuestSeal.FromHost);
        await quest.SendAsync(SealConfirmation(senderKey, keyId, session, 2, challenge), target);
        var initialAccept = await ReceiveAsync(quest);
        Assert.Equal(0xF4, QuestSeal.Open(firstHostKey, initialAccept.Buffer)![0]);
        await ReceiveAsync(quest);
        await quest.SendAsync(QuestSeal.Seal(senderKey, keyId, session, QuestSeal.FromSender, 3, state), target);
        await ReceiveAsync(broker);

        // A valid but captured packet arriving from a new source must not move
        // the host's haptic destination or forward this replayed controller state.
        await movedQuest.SendAsync(QuestSeal.Seal(senderKey, keyId, session, QuestSeal.FromSender, 4, state), target);
        var moveChallengeDatagram = await ReceiveAsync(movedQuest);
        var moveChallenge = OpenChallenge(token, session, moveChallengeDatagram.Buffer, out var moveHeader);
        Assert.Equal(firstHostHeader.Session, moveHeader.Session);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(broker, 150));

        await movedQuest.SendAsync(SealConfirmation(senderKey, keyId, session, 5, moveChallenge), target);
        var moveAccept = await ReceiveAsync(movedQuest);
        Assert.Equal(0xF4, QuestSeal.Open(firstHostKey, moveAccept.Buffer)![0]);
        await ReceiveAsync(movedQuest);
        await movedQuest.SendAsync(QuestSeal.Seal(senderKey, keyId, session, QuestSeal.FromSender, 6, state), target);
        var forwarded = await ReceiveAsync(broker);
        Assert.Equal(state, forwarded.Buffer[(3 + id.Length)..]);

        var haptic = new byte[14];
        haptic[0] = 0x02;
        haptic[1] = 1;
        var envelope = new byte[3 + id.Length + haptic.Length];
        envelope[0] = 0x51;
        envelope[1] = 1;
        envelope[2] = (byte)id.Length;
        Encoding.UTF8.GetBytes(id).CopyTo(envelope, 3);
        haptic.CopyTo(envelope, 3 + id.Length);
        await broker.SendAsync(envelope, forwarded.RemoteEndPoint);
        var routedHaptic = await ReceiveAsync(movedQuest);
        Assert.Equal(haptic, QuestSeal.Open(firstHostKey, routedHaptic.Buffer));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReceiveAsync(quest, 150));
    }

    private static byte[] OpenChallenge(string token, byte[] senderSession, byte[] datagram,
                                         out QuestSeal.Header header)
    {
        Assert.True(QuestSeal.TryPeek(datagram, out header));
        var key = QuestSeal.SessionKey(token, senderSession, header.Session, QuestSeal.FromHost);
        var payload = QuestSeal.Open(key, datagram);
        Assert.NotNull(payload);
        Assert.Equal(senderSession, payload!.AsSpan(1, QuestSeal.SessionSize).ToArray());
        return payload;
    }

    private static byte[] SealConfirmation(byte[] senderKey, byte[] keyId, byte[] session,
                                            ulong counter, byte[] challenge)
    {
        var confirm = new byte[1 + QuestSeal.ChallengeSize];
        confirm[0] = 0xF3;
        challenge.AsSpan(1 + QuestSeal.SessionSize, QuestSeal.ChallengeSize).CopyTo(confirm.AsSpan(1));
        return QuestSeal.Seal(senderKey, keyId, session, QuestSeal.FromSender, counter, confirm);
    }

    private static async Task<UdpReceiveResult> ReceiveAsync(UdpClient client, int timeoutMs = 2000)
    {
        using var cancel = new CancellationTokenSource(timeoutMs);
        return await client.ReceiveAsync(cancel.Token);
    }
}
