# App Review notes

Text to paste into App Store Connect → App Review Information → Notes, plus the
checklist for the demo video that goes with it. Keep the pasted text under App Store
Connect's 4,000-character limit. The block below is about 2,500.

## Notes for the reviewer

```
Longwave is a remote desktop and streaming client for Apple Vision Pro. It connects to
computers the user owns: a Mac or PC on the same network, or on the user's own VPN.
It has no accounts and no server of its own. Nearly every feature needs a host
computer, so a demo video showing each one on real hardware is attached.

PCVR (the only paid feature)
- Needs a Windows 10/11 PC with an NVIDIA RTX graphics card, on the same network as
  the Vision Pro, running the free Longwave Companion for Windows
  (https://longwave.pro). Its PCVR tab installs the streaming host.
- In the app: PCVR tab → the PC is found automatically over Bonjour (or type its IP
  address) → Connect → choose a game. The game streams into a Full Space through
  Apple's FoveatedStreaming framework, using the
  com.apple.developer.foveated-streaming-session entitlement.
- Free to use with no trial period: every session ends after 20 minutes, with
  warnings at 5 and 1 minutes left. The in-app purchase removes the limit: a
  $24.99 non-consumable, or a $1.99 monthly auto-renewing subscription. The
  purchase screen opens from the seal icon in the PCVR tab toolbar, and when a
  session reaches the limit. It has Restore Purchases, Terms of Use and Privacy
  Policy links.
- Hand tracking and accessory tracking turn the user's hands, and any spatial game
  controller, into VR controllers for the game on the PC.

Other features (all free)
- VNC: connects to any VNC server, including macOS Screen Sharing (System Settings →
  General → Sharing → Screen Sharing on a Mac).
- Native Mac streaming and system audio: need the free Longwave Companion for Mac.
- SSH terminal and Projects: connects to any SSH server. Projects can run the Claude
  Code or GitHub Copilot command-line tools on that server; signing in to those
  services is optional and goes directly to Anthropic or GitHub.
- Broadcast: sends the chosen camera, microphone and screen to an RTSP server the
  user runs (for example mediamtx).

Permissions
- Local network: finding and connecting to the user's computers.
- Microphone: terminal dictation, broadcasts, and the user's voice in PCVR games.
- Camera: broadcasts.
- Hand and accessory tracking: PCVR controllers.
- Speech recognition: on-device dictation.

Network security: all internet traffic is HTTPS. NSAllowsLocalNetworking covers one
small plain-HTTP status request to the user's own PC during PCVR sessions.
Longwave contains no analytics, advertising or tracking.
```

## Demo video checklist

Record on device (Control Center screen recording, or a Mac mirroring the headset),
and keep it to a few minutes with no cuts in the middle of a flow. Upload it
unlisted and put the link at the top of the notes.

- [ ] **Start state.** A fresh launch, with the PCVR tab open and no purchase made.
- [ ] **PC side.** Longwave Companion on the Windows PC, PCVR tab showing the host
      running, and the RTX card visible (Task Manager → Performance → GPU is enough).
- [ ] **Discovery and connect.** The PC appears automatically, the connect tap, and the
      immersive space opening.
- [ ] **Gameplay.** One SteamVR or OpenXR title launched from the in-app library, played
      with hand tracking (pinch to click or grab). If you use a spatial controller,
      show it too.
- [ ] **Session limit.** The 5-minute warning banner, with the recording trimmed to
      that moment, then the paywall appearing when the session ends. Show both products
      with prices, the renewal text, Terms of Use and Privacy Policy links, and Restore
      Purchases.
- [ ] **Purchase.** A sandbox or TestFlight purchase, then a new session running past
      20 minutes. A clock overlay is enough to show this.
- [ ] **Desktop panel and wrist HUD.** Raise a palm, show the desktop panel, then quit
      the title.
- [ ] **VNC.** Connect to a Mac's Screen Sharing and type with the on-screen keyboard.
- [ ] **Native Mac stream and audio.** Connect through Longwave Companion for Mac and
      play some audio.
- [ ] **SSH.** Open a terminal session and run a command. Optionally, dictate a line.
- [ ] **Broadcast.** Start a broadcast to an RTSP server and show it playing elsewhere.

Before recording, check that the video shows nothing from outside the release build:
no developer menus, and no build flags in window titles.
