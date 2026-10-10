# Companion enrollment, device grants and first-run setup

Status (2026-10-10): steps 1–3 implemented — setup assistant, in-app sandbox
install, per-device tokens and grants, the pairing dialog, Devices tab, address
link and direct pairing port, Projects and the watch lane on device keys, the
SSH key offered in the pairing commit (added to authorized_keys exactly while
the device holds `sshKey`), and the iPhone handing the watch its own device key.
Step 4 done for screen streaming: the Windows host pairs the same way (direct
port 4859, `os=windows`/`pp` in its `_longwave-mac._tcp` record, a "Pair a
Device" window, per-device keys with the identify proof), verified end to end
against the gaming PC including revocation. The `pcvr` grant waits for the own
foveated-streaming provider. Not done: a separate Windows first-run checklist
(its firewall rule now comes from the installer; drivers and hotspot already
explain their own prompts). Deviation: Windows reuses `_longwave-mac._tcp` with
an `os` key instead of a new `_longwave-host._tcp`, so no Info.plist changes.
Deviations: asking for more grants later pairs again (one code) rather than a
code-less request; Projects invitations were removed outright instead of
honoured for a transition (the feature was a day old).

## Problem

A Mac Companion grants access four unrelated ways, and none of them knows
about the others:

| credential | issued by | scope | client storage | revoke |
|---|---|---|---|---|
| Native token | 6-digit pairing, or Copy/AirDrop of a `longwave://` URL | Screen, Audio, typing — **one token shared by every device** | SwiftData field `SavedConnection.companionToken` (not Keychain) | Regenerate (unpairs everyone) |
| Projects invitation | "Create and Copy Invitation", Mac address typed by hand | sandbox sessions | Keychain + own UserDefaults device list | per device |
| SSH key | headset "Copy Public Key", pasted into the Remote tab | full-user SSH | — | per key |
| Watch token | nothing sends it (receiver only) | watch stills | watch Keychain | — |

The Windows Companion adds a raw Screen-streaming token. CloudXR's QR
pairing is the system's and stays as it is; it is out of scope.

Permissions are discovered lazily. There is no first-run window on either
Companion. Accessibility is requested only after a feature switch (off by
default) is turned on. Screen Recording and the system-audio tap prompt on the
Mac the first time a headset subscribes, while the user is wearing the headset.
Notifications prompt on server start, Music Automation whenever Music runs.
Full Disk Access has a good assistant, but only inside the Projects window.
On Windows the firewall relies on the first-listen prompt.

## Decisions

1. **One pairing, one token per device.** The 6-digit numeric-comparison
   pairing (`PairingExchange`) stays the enrollment path, but every pairing
   mints a fresh 32-byte token for that device instead of handing over the
   Companion's shared one. Revoking a device revokes only that device.
2. **Grants hang off the token.** The host keeps, per device: id (the
   headset's `longwaveHeadsetID`), name, token (Keychain), grants, paired-at,
   last-seen. Grants: `screen`, `audio`, `input` (mouse, keys, typing),
   `projects`, `sshKey`; later `pcvr` and `watch`.
3. **One-time permission dialog at enrollment** (AnyDesk's dialog, but once,
   not per connection). The Mac's pairing alert shows the code, the device name
   and a checkbox per feature the device asks for. Screen, Audio and Input are
   on by default; Projects is off. After that, connections never prompt.
   Grants are changed later in the Mac's Devices tab, or by the device asking
   for more over its authenticated channel, which shows the same dialog
   without a code.
4. **Feature keys stay separated.** Each server still derives its own PSK from
   the device token with its existing salt (`Longwave-MacNative-PSK-v1`,
   `Longwave-Audio-PSK-v5`, `Longwave-Inject-PSK-v1`, `Longwave-Projects-PSK-v1`).
   Today Native, Audio and Inject all use one fixed PSK identity
   (`MacNativeStreamCrypto`, `AudioCrypto` incl. its DTLS path,
   `CompanionInjectCrypto`); it becomes the device id, with every enrolled
   device's PSK added to the listener (Projects already works this way), so
   the server knows whose token to use and checks that device's grants before
   serving anything. A device without `projects` cannot complete the Projects
   handshake, so "Projects is a separate grant" from
   `docs/PROJECTS_REMOTE_ACCESS.md` still holds — it is a grant, not a
   separate secret.
5. **Sandbox administration is Mac-only.** Installing, resetting, golden
   snapshots, Full Disk Access, agent sign-ins, repository import/fetch-back and
   schedules happen in the Companion on the Mac. No grant lets a device trigger
   any of them; `projects` covers listing imported projects and starting,
   attaching to and stopping their tagged sessions, exactly as invitations do
   today.

## Enrollment flows

- **Nearby (default).** Connections → Add → Native → Macs Nearby → Pair. The
  device sends its requested features with the commit; the Mac's alert shows
  code + checkboxes; the sealed grant returns the device token and the granted
  set.
- **By address (no Bonjour: Tailscale, VPN, other subnet).** The pairing
  itself never changes; only how the headset finds the Mac does. The Mac's
  Devices tab has "Send This Mac's Address" (AirDrop, or Copy for anything
  else): a `longwave://pair?mac=<macID>&name=…&port=…&addr=…&addr=…` link
  listing every address the Mac has (LAN, Tailscale, other interfaces). It
  carries **no secret, nonce or token** — anyone could have made it, and it
  grants nothing. Opening it makes the headset try a direct connection to each
  address in turn and run the normal 6-digit numeric-comparison exchange and
  grant dialog over the first one that answers. To be reachable, the Mac keeps
  a fixed pairing port open for 10 minutes after the link is sent (and
  whenever "Allow connections by address" is on); a device that pairs this way
  stores the address that worked as its host. The link replaces the raw-token
  AirDrop, the manual "Companion Token" field and the paste-only
  `longwave-projects:` invitation. iPhones may open the same link from the
  Camera app; visionOS cannot scan QR codes, so nothing depends on scanning.
- **Asking for more later.** The Projects tab's Companion Sandbox list shows
  paired hosts; one without `projects` gets "Request access", which raises the
  grant dialog on the Mac. Same for "Authorize this device for full SSH",
  which sends its public key for the Mac to add (Remote Login still has to be
  on; setup checks it).
- **Watch.** The iPhone derives a watch credential from its own device token
  and sends it over WCSession; the watch receiver already exists.

## Client model

- A paired host is one `SavedConnection` (`.native`) with `companionMacID`.
  Its token moves to Keychain in an access group the future foveated-streaming
  provider extension can read; the SwiftData field is kept only to migrate
  from (see the SwiftData migration rules in KNOWN_CONSTRAINTS.md).
- The host returns the granted set on every hello, so each host's row shows
  what it offers (Desktop, Audio, Projects, later PCVR) and why something is
  unavailable.
- Companion Sandbox mode lists paired hosts with `projects` and resolves them
  through `CompanionLocator` (knock + lease) like Native does. No hand-typed
  address; port 4860 sits behind the same listen gate, with "Allow connections
  by address" as the fallback.

## Mac Companion layout

- Token tab → **Devices**: Pair status / Headsets Nearby, paired devices with
  their grants (edit, revoke), Send This Mac's Address, allow-by-address. The Remote
  tab's SSH key list and the Projects window's "Remote Projects access" section
  move here.
- The Projects window keeps sessions, sign-ins, schedules and sandbox
  administration, linked from Devices.

## First-run setup assistant (Mac)

Opens on first launch and from the menu's "Set Up…". It asks what the user wants
to do from the headset — see the screen, hear audio, control the Mac, run
agents, broadcast. Choosing a feature switches it on, so nothing waits on a
default-off switch. It then lists only the permissions those features need,
each with live status, a one-line reason and a Grant button:

| row | how |
|---|---|
| Local Network | already triggered at launch; keep PolicyDenied detection + Settings link |
| Screen & System Audio Recording | `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` here, not on first client; offer Relaunch if capture needs it |
| System audio tap | no known preflight: create a throwaway process tap from the assistant so the prompt appears in context |
| Accessibility / Device Control | existing `AccessibilityTrustMonitor` |
| Notifications | request here instead of on server start |
| Music Automation (optional) | `AEDeterminePermissionToAutomateTarget(askUserIfNeeded:)` |
| Agents | sandbox install from a button in the Companion (one admin prompt on the Mac — decided: it should be easy to switch on; `install.sh` stays for scripted setup), Full Disk Access via `FullDiskAccessAssistant`, Remote Login, Screen Sharing |

`AccessibilityTrustMonitor` generalizes into a `PermissionCenter` that tracks
all of these live. When a granted feature can't run because a permission is
missing, the host reports it in its status (as `accessibilityDenied` does
today): the headset names the missing permission, and the Mac posts a
notification that opens the assistant at that row. No system prompt surprises
someone wearing the headset.

## Windows

The device model and pairing are host-neutral, so the own foveated-streaming
provider only adds a `pcvr` grant to devices that already exist.

- Advertise `_longwave-host._tcp` with an `os=` TXT key; keep
  `_longwave-mac._tcp` for older builds.
- Port `PairingExchange` (X25519 commit-reveal, 6-digit code) to the Windows
  host with the same grant dialog in Electron; ship it for Screen streaming
  first, which retires that tab's raw token. .NET 8 has no X25519 in the BCL
  (needs NSec or BouncyCastle); the Swift host from the Phase 2 spike could use
  swift-crypto and share the Mac's code.
- Pairing protocol and fixed test vectors live in `Shared/`, so every
  implementation is checked against the vectors.
- Firewall rules are added during the already-elevated install.
- The same feature-first first-run checklist: firewall, hotspot elevation, and
  the PCVR drivers only when PCVR is chosen.

## Migration: old methods are deprecated

The 6-digit pairing is the only way to enroll. Everything else stops being
issued in the release that ships per-device tokens:

- **Shared token** (Token tab, Copy, Regenerate, the `setAudioToken` AirDrop
  URL, the manual "Companion Token" field on the client): no longer shown or
  accepted for new enrollments. A device still holding it is accepted for a
  transition period, shown in Devices as "Needs to pair again", and its
  connection tells the headset to re-pair (one code, one dialog). The host then
  stops accepting the shared token entirely once no device uses it, or when the
  user chooses "Stop accepting old devices".
- **Projects invitations** are no longer created; existing ones are honoured
  for the same transition and listed under the device that should replace them.
  The client's paste field goes away.
- **Pasted SSH keys** (Copy Public Key → Remote tab) are replaced by the
  `sshKey` request over the paired channel; already-authorized keys stay in
  `authorized_keys`.
- The `longwave://` scheme keeps only `pair` (address hint) and the broadcast
  setup link.

## Order

1. Setup assistant + `PermissionCenter` on the Mac (no protocol change).
2. Per-device tokens, grants, the enrollment dialog and the Devices tab;
   Projects over pairing; retire invitations and the shared token.
3. SSH key and watch credential over the paired channel.
4. Windows pairing for Screen streaming; `pcvr` grant with the provider work.
