# Agent sandbox account

Longwave's Projects tab on macOS runs Claude Code, Codex and Copilot as a separate, hidden
macOS user, `longwave-agent`, rather than as you. This directory is everything outside the
app that makes that work: a one-time installer, the root-side helper the app drives, and
the account's provisioning.

## Why a separate user

The agent CLIs ship their own sandboxes, but they break Xcode work. `xcodebuild`, the
simulators and Xcode talk to per-user XPC services (CoreSimulatorService, the build service)
that run outside any process sandbox, as the user and with that user's full access. Block them
and the tools fail; allow them and they become a way around the sandbox. A separate macOS
account puts the whole toolchain, services included, on the other side of a real Unix
permission boundary, and keeps native GPU access (VMs lose it).

## Threat model

It is meant to protect against an agent that has turned hostile, whether through prompt
injection from something it fetched or a bad tool call, doing any of these:

- reading or modifying your files,
- reaching your LAN, tailnet or localhost services,
- stealing long-lived credentials,
- persisting past a reset.

**Isolated:**
- **Your files.** Your home must be `700`. install.sh doesn't change it; the dev Mac's was
  fixed by hand, so check with `ls -ld ~`.
- **Your SSH agent, keychain and browser profiles.** They belong to your account.
- **The network.** A pf anchor keeps the agent off RFC1918, CGNAT/tailnet (`100.64/10`),
  link-local and multicast. On loopback it may only use ports `40000–40999`, its own range
  for dev servers. That blocks your localhost dev servers, debug/MCP endpoints, Screen
  Sharing, SSH and SMB. DNS (port 53) stays open. The internet stays open.
- **Credentials.** Each session gets short-lived tokens (Claude about 8 h, Codex's access
  token) on stdin from the app. Refresh tokens stay in the app's keychain, and nothing
  long-lived is written into the agent's home.
- **Persistence.** `reset` logs the agent out, restores its home from a golden copy with an
  APFS clone (seconds), and clears the places a standard user can still write outside its
  home: per-user `/private/var/folders` dirs, `/private/tmp`, `/Users/Shared`, launchd
  overrides. cron and at are denied to the account.
- **Scheduling.** Claude's `CronCreate`/`CronDelete`/`ScheduleWakeup`/`RemoteTrigger`
  tools are denied in its settings. The app is the only scheduler.

**Not isolated. Know these:**
- **Anything world-readable outside your home**, including `/opt/homebrew`, `/Applications`
  and `/Library`. The agent can use Homebrew's tools, but can't write to them.
- **Volumes mounted with ownership ignored (`noowners`).** This covers exFAT/FAT drives and
  APFS/HFS drives with "Ignore ownership" set. Every local user can read and write them.
  Enable ownership (`diskutil enableOwnership`), or don't mount them while agents run.
- **`/Users/Shared` and `/private/tmp`** are shared with every user between resets. Don't
  put anything there you'd mind the agent reading.
- **ICMP**, because pf's `user` match only covers TCP/UDP. The agent can ping LAN hosts, but
  can't connect to them.
- **SMB sharepoint groups.** New local users are in every `com.apple.sharepoint.group.*`
  through the nested `everyone` group, which can't be undone per user. The firewall keeps
  the agent off SMB, and it doesn't know its own password.
- **The kernel.** A local privilege escalation beats any user boundary. This setup raises the
  bar; it doesn't replace a VM or a separate Mac.

## GUI session and the visionOS semaphore

iOS simulators run fine with no desktop session. visionOS ones don't:
- At boot, CoreSimulator creates a Secure Enclave-backed device identity key.
- That key needs an unlocked user keybag.
- Only a real password login unlocks the keybag. Key-based and password SSH logins don't.

So the app logs the agent into a **Screen Sharing virtual session** over
`127.0.0.1:5900`. It uses ARD authentication with the password install.sh stored in your
keychain. The virtual session keeps running after the VNC connection closes. The first time,
you do macOS first-run setup yourself in that window, and then "Setup complete" snapshots the
golden home.

Separately, the in-simulator visionOS compositor (`wakeboardd`) opens a named POSIX semaphore,
`wakeboardd.first-boot`:
- Named semaphores are host-global and outlive their creator.
- macOS refuses cross-user opens **whatever the mode** (verified with a root-created `0666`
  one).
- So whichever user boots a visionOS simulator first after a host boot locks every other user
  out. Their `wakeboardd` aborts with `can't open first boot semaphore: Permission denied`,
  and the device sits at "Waiting on Data Migration" forever.

The `pro.longwave.sandbox` LaunchDaemon runs `longwave-sandbox-semd`, which `sem_unlink`s
that name every 2 s:
- Running simulators keep their handle.
- The next boot creates a fresh semaphore owned by its own user.
- launchd_sim restarts a `wakeboardd` that lost the race, so it recovers a few seconds later.
- The only visible effect is that every boot counts as a "first boot".

## Install

```sh
sudo scripts/agent-sandbox/install.sh
```

Run it from your own admin account; it uses `SUDO_USER` as the owner. It does the following:

1. **Creates the account.** `longwave-agent` gets the first free uid ≥ 552. It's hidden and
   not an admin. It's added to `com.apple.access_ssh` and `com.apple.access_screensharing`,
   and denied cron and at.
2. **Sets a random password.** The password never goes through argv or output. It's stored in
   your login keychain as `pro.longwave.sandbox` / `longwave-agent`, and re-runs don't
   rotate it.
3. **Creates the shared layout.** `/Library/Longwave/`:
   - `sandbox.conf`
   - `state/`
   - `agent-golden/` (root `700`)
   - `authorized_keys`, the overlay re-applied on every reset
   - `exchange/`, group `longwave-exchange` (you and the agent), mode `2770`. It holds the
     bare repos you push work into and fetch results from. Fetching never runs hooks.
4. **Installs the root helper and daemon.** `/usr/local/libexec/longwave-sandbox`, plus
   `longwave-sandbox-semd` compiled from `semd.c`, and the LaunchDaemon.
5. **Adds the sudoers rule.** `/etc/sudoers.d/longwave-sandbox` lets **only you** run the
   helper without a password. It's checked with `visudo -c`.
6. **Sets up your SSH key.** `~/.ssh/longwave_sandbox_ed25519` is generated for you and
   authorized for the agent.
7. **Turns on the firewall.** The stock `/etc/pf.conf` already evaluates `com.apple/*`
   anchors, so it isn't edited. pf is enabled with a reference token (`pfctl -E`), not a
   bare `-e`, so other pf users keep their references.
8. **Provisions the home.** `provision-golden.sh` runs as the agent:
   - Claude, Codex and Copilot CLIs from their official installers, into `~/.local`
   - `PATH` in `~/.zprofile`
   - git identity "Longwave Agent"
   - Claude's scheduling deny list
   - Codex `sandbox_mode = "danger-full-access"`: the account is the sandbox, and Codex's
     Seatbelt breaks xcodebuild
   - a "Sandbox iPhone" and a "Sandbox Vision Pro" simulator

It needs Screen Sharing turned on (System Settings › General › Sharing) for the GUI session.

## Uninstall

```sh
sudo scripts/agent-sandbox/uninstall.sh [--keep-exchange]
```

It removes the account and its home, the golden copy, the daemon, the pf anchor and token,
the sudoers rule, the helpers, the keychain item and the SSH key. The exchange repos are
deleted too unless you pass `--keep-exchange`.

## The helper's verbs

Run as `sudo -n /usr/local/libexec/longwave-sandbox <verb>`:

| verb | what it does |
|---|---|
| `status [--size]` | JSON: account, uid, GUI session, tmux sessions, golden snapshot time, last reset, firewall and daemon state. `--size` adds `du` of the home, which is slower. |
| `stop` | `launchctl bootout user/<uid>`, which ends SSH and the GUI session, then `pkill -9 -u`. |
| `reset` | stop, delete the home, clone the golden copy back (or create a fresh home if there's no golden copy yet), re-apply authorized keys, clear per-user temp dirs, `/private/tmp`, `/Users/Shared` and cron/at. |
| `snapshot-golden` | stop, then save the current home as the golden copy. Keys are left out; they come from the overlay. |
| `authorize-key '<line>'` | add one `ssh-ed25519` or `ecdsa-sha2-nistp256` public key (checked with `ssh-keygen -l`, no options prefix allowed), e.g. the headset's Secure Enclave key. The key survives resets. |
| `firewall on\|off\|status` | load or flush the anchor and take or release the pf enable token. The setting persists across reboots through the daemon. |

## Loopback port range

The agent's loopback traffic is allowed only to and from ports **40000–40999**. Run dev
servers there when the agent, or a simulator app it launched, needs to reach them. Don't run
your own services in that range: the agent can reach anything listening there, whoever owns
it. To change the range, edit `AGENT_PORTS` in `/Library/Longwave/sandbox.conf` and run
`firewall on`.
