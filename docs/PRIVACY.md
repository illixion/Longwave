# Longwave Privacy Policy

_Last updated: 26 September 2026_

Longwave is a remote desktop, streaming and PCVR app for Apple Vision Pro. This policy
covers the Longwave app for visionOS and the Longwave Companion apps for macOS and
Windows.

## The short version

- The developer collects **no data** from you. There are no accounts, no analytics, no
  advertising, no tracking and no crash-reporting services in Longwave.
- Longwave connects **directly** to computers and services you choose. Nothing is
  relayed through servers run by the developer, because there are none.
- What you save in Longwave stays on your device.

## What stays on your device

- **Connections and settings** — host addresses, ports, display and audio preferences —
  are stored in the app's own storage on your Vision Pro.
- **SSH keys, sign-in tokens and the broadcast password** are stored in the device
  keychain, marked as available on this device only, and are not synced to iCloud.
  Saved connection passwords are kept in the app's own storage on the device.
- **Backups** are created only when you export one from Settings. The file goes where
  you choose to save it. Backups do not include passwords or tokens.
- **Speech dictation** in terminal sessions is transcribed on the device. Audio is not
  sent anywhere for transcription.

## What leaves your device, and where it goes

Everything below happens only when you start it, and goes only to the destination you
chose.

- **Remote desktop, terminal and streaming.** VNC, SSH, native Mac streaming, system
  audio and PCVR connect to computers you specify, usually on your local network or
  your own VPN. Your keyboard, pointer and controller input goes to that computer.
  Longwave encrypts the Companion, audio, native-stream and SSH links. The VNC protocol
  itself is not encrypted, so use it only on networks you trust.
- **PCVR.** During a PCVR session, head and hand tracking, spatial controller positions
  and your microphone are sent to your own PC so that games can use them. Hand-tracking
  data is used only while a session is running and is not stored.
- **Broadcast.** When you start a broadcast, the camera, microphone and screen content
  you selected are sent to the streaming server you configured.
- **Claude Code, GitHub Copilot and OpenAI Codex sign-in.** If you sign in to any of
  these services from the Projects tab, Longwave talks directly to Anthropic, GitHub or
  OpenAI (`auth.openai.com`) to get a sign-in token, then stores it in the device
  keychain. It sends a token only to the SSH hosts you connect those agents to. For
  Codex, the host receives a short-lived sign-in file without the long-lived renewal
  token, which stays on your Vision Pro. Those services' own privacy policies apply to
  your accounts with them.
- **Purchases.** In-app purchases are handled by Apple. The developer receives the
  standard, anonymous sales reports Apple provides to all developers. Longwave checks
  your purchase status with StoreKit on the device.

## Permissions

Longwave asks for these permissions only when a feature needs them. Each one can be
turned off in Settings:

- **Local network** — to find and connect to your computers.
- **Microphone** — for terminal dictation, for broadcasts you start, and to pass your
  voice to games during PCVR sessions.
- **Camera** — for broadcasts you start.
- **Hand tracking and accessory tracking** — to turn your hands and spatial controllers
  into VR controllers during PCVR sessions.
- **Speech recognition** — for on-device dictation.

## Children

Longwave is not directed at children and does not knowingly collect information from
anyone.

## Changes

If this policy changes, the updated version will be published at this address, with a
new date at the top.

## Contact

Questions about this policy can be raised as an issue at
[github.com/illixion/Longwave](https://github.com/illixion/Longwave/issues), or through
[longwave.pro](https://longwave.pro).
