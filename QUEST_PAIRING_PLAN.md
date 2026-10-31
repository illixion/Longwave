# Quest controllers: pairing and streaming to several hosts

Status (2026-10-31): steps 1, 2 and 4 are built, and so is a GUI. A Quest 2 pairs with the
gaming PC and streams tracked controllers into the broker's hub, unattended on a desk:
the app starts at boot or on request, keeps the headset awake, and comes back by itself after
a sleep. The set-up steps are in the QuestControllerBridge README ("Leaving the Quest on a
desk"). A packet flag (`QCB_FLAG_UNFOCUSED`) reports when a system prompt on the headset has
the input, and the panel shows it.

- **Quest app** (`~/Projects/QuestControllerBridge`, public): pairs, then streams sealed
  packets to every enabled paired host next to any open host. `protocol/tests/run.sh` tests it
  on a desktop, and the APK builds.
- **Windows Companion:**
  - It grants `controllers`.
  - `QuestControllers` takes the sealed stream on UDP 9522 and opens it with each device's
    token.
  - It forwards the plain packets to the broker on 127.0.0.1:9523. Heartbeats and haptics go
    back sealed through the Quest's own socket.
  - `QuestStatus` reports who is streaming.
  - Tests: `backend-tests` covers the shared vectors and a loopback run with a fake Quest and a
    fake hub, on macOS and on Windows.
- **Broker:**
  - `quest_source` makes each Quest two hub devices, aligned like the Lighthouse wands.
  - `test_tracker_hub` covers it over loopback.
  - Built on the gaming PC.
- **GUI:** the PCVR page's **Controllers and trackers** drawer.
  - It shows paired Quests and the Lighthouse source, gives every device a role picker,
    alignment and OSC output, and edits through the PCVR host's `TrackersState` and
    `TrackersCommand`.
  - Checked in a browser with mock data.
  - The host's RPCs were driven over its pipe on the PC.
  - Not yet run in the Companion itself.

## Goal

A desk Quest's Touch controllers drive things in three places, and one Quest
should be able to feed more than one of them at once:

- **A visionOS app, standalone.** The user's own apps, through RAVEInput's
  `RAVEQuestBridgeSource`, standing in for PSVR2 Sense controllers. No PC
  involved. This works today on the open protocol and must keep working.
- **Longwave PCVR on a PC.** The broker's tracker hub, as a source like the
  Lighthouse wands. The controllers can then be assigned to hands or to body
  roles (legs for VRChat, with the Vision Pro's hands or other controllers on
  the hands).
- **The SteamVR driver** in the Controller Bridge repo, unchanged.

Today a Quest finds hosts with its own discovery (probes, a /22 sweep and
`_controllerbridge._udp`) and trusts whoever answers. Any packet retargets a
host's haptics, and a "last host" is remembered by its name. That is fine on a
home LAN with a Vision Pro but not for a PC. It also can't cross NAT, because
the host's replies go to a second port on the Quest.

## Decisions

- **Same pairing as the rest of Longwave.** The Quest plays the headset role
  of `CompanionPairing` (X25519 commit and reveal, six digits from the
  transcript, sealed grant). It shows the code, and the PC's user approves in
  the Companion's pairing window, ticking **Stream Quest controllers to this
  PC** (`controllers`). Discovery is the Companion's own `_longwave-mac._tcp`
  record (`os=windows`, `pp=4859`). A Tailscale or other address can be typed
  in and paired with directly on 4859. The address it answered on is kept
  first, ahead of the LAN addresses the grant lists.
- **Several hosts, one stream.** The Quest stores each paired host with its
  token, addresses and an on/off switch. Each stream goes to every enabled
  paired host, and also to one open (unpaired) host when one is chosen. The
  data is the same raw Quest-space poses for everyone. Each host aligns them
  to its own space, so the hosts don't interfere with each other.
- **Sealed datagrams, not a new protocol.** The open packets go inside
  ChaCha20-Poly1305 under a 28-byte header (`QCB_PACKET_SEALED`, 0xE0). The
  key id and session keys come from the device token, and each side picks a
  random session, so a restart on either end means new keys. Each paired host
  gets its own socket, and the host replies to wherever the last authenticated
  packet came from. That makes the stream NAT-safe, which an EC2 or other
  cloud host would need. The spec is in
  `QuestControllerBridge/protocol/quest_bridge_protocol.h` ("Paired hosts")
  and `qcb_crypto.h`.
- **The open protocol stays as it is**, at v3, for `RAVEQuestBridgeSource`
  and the SteamVR driver. Pairing is added alongside it.
- **Only Windows hosts are offered for pairing on the Quest for now.** The
  Mac's Swift `PairingMessage` decodes `requested` as `[CompanionGrant]`, so an
  unknown `controllers` would fail the whole commit there. The Swift side
  already drops unknown grants it is *given*, so a Windows PC granting
  `controllers` to a Vision Pro is harmless.
- **Crypto in C, shared.** Monocypher 4.0.2 (X25519, ChaCha20-Poly1305; CC0
  or BSD-2) is vendored in the Quest repo with a small SHA-256/HMAC/HKDF, all
  in `qcb_crypto.c`. The Quest uses it through JNI. A host in C++ (the
  broker) can compile the same files. A C# host would use BouncyCastle, as
  `Pairing.cs` already does, and check against the vectors in
  `test_qcb_crypto.c`.

## Steps

1. **Quest app: done.**
   - `PairingClient`, `PairedHosts` (tokens wrapped by an Android Keystore AES
     key), and a paired-PCs list. The list shows PCs found on the network as
     "Pair with …", and there is a "Pair with this address" button.
   - `paired_link.cpp` is one sealed link per host. Until the host answers, it
     sends to every known address, then locks onto the one that answered. It
     follows a host restart.
   - Auto-connect also starts with paired hosts only, once discovery settles.
   - The typed address of a paired PC is never also treated as an open host.
2. **PC receiver: built, in the Companion backend.** Something on the PC has to own UDP 9522, open sealed
   packets with the device's token, send heartbeats every 2 s and route
   haptics. I recommend the **Companion backend**, because it already holds the
   tokens (DPAPI, `DeviceRegistry`), the grants, the firewall rule and the
   UI. It would hand the opened plain packets to a loopback consumer:
   - the broker's hub, as a `QuestSource` (`TrackerSource`, a held candidate
     calibrated to ARKit hands like the wands);
   - or the SteamVR driver, as an open host on loopback.

   That keeps tokens out of the broker and also gives the SteamVR driver
   authenticated input without changing it. The alternative is the broker
   reading the tokens itself, which saves a loopback hop of well under a
   millisecond. Also needed for this step:
   - an installer firewall rule for UDP 9522;
   - "connected" and "last seen" for the Quest in the Devices list;
   - a C# test against the sealed-datagram vector.
3. **Standalone Vision Pro pairing.** Move the pairing responder and sealed
   links into RAVEInput: the exchange, plus a protocol mirror with golden
   bytes from `test_qcb_crypto.c`. Each app supplies the approve/decline UI
   and key storage, and advertises its own record. RAVEInput can't depend on
   RAVESDK, so this is a port of the exchange, not a reuse of `Shared/`. Until
   then, Vision Pro apps stay open hosts, which the Quest streams to at the
   same time.
4. **Hub priority: direct before forwarded. Built by the table's default order.** Assigned
   devices come first and `headset` last, so a directly paired Quest on a hand wins, and the
   forwarded copy only fills in. `assign` now also puts the device into a custom priority
   list. With the Vision Pro forwarding a
   Quest it also receives, the PC would see the same controllers twice:
   directly, and as the headset's 0x10. Put the direct Quest source above the
   headset candidate in each hand's list. The forwarded copy then only fills
   in when the direct one is absent. This is untested with a real Quest. So is
   the hub's held-candidate calibration for anything but the wands.

## Testing

- `QuestControllerBridge/protocol/tests/run.sh`: SHA-256, HMAC and HKDF against
  RFC vectors. Pairing against the CryptoKit values that
  `CompanionWindows/backend-tests/PairingInteropTests.cs` pins (code 741941).
  The sealed datagram is checked against CryptoKit with the header as AAD.
  `PairedLink` runs against a fake host: lock-on, haptics, replay, forgery,
  unsealed packets, and a host restart.
- `CompanionWindows/backend-tests`: still green with `controllers` offered.
  Defaults stay screen and input for headsets that don't name grants.
- On hardware, still to do:
  - pair the Quest with the gaming PC on the LAN and over Tailscale;
  - approve, then decline (check the pause doubles);
  - revoke on the PC, and check the Quest's stream stops authenticating;
  - after step 2, stream to the PC and the Vision Pro at once.

## Open questions

- Should a Quest that the PC revoked learn it and drop the host? Today it keeps
  sending into silence until the user forgets the host.
- Can one Quest feed two PCs at once? The design allows it, but nothing here
  needs it.
- A cloud host: the stream is NAT-safe, but pairing needs TCP 4859 reachable.
  Tailscale covers it; plain internet exposure isn't planned.
