# Companion-managed Projects

## Decision (2026-10-09)

Build on the existing Companion sandbox and shared OAuth implementation. The
Companion owns sandbox agent sign-ins, refreshes and launches. Mobile clients
receive project/session metadata and terminal bytes, never agent credentials,
the sandbox password or the Companion's SSH private key.

An SSH public key in authorized_keys is not a leaked private key. The remaining
credential exposure is the CLI's access token: code running as longwave-agent
can read that account's files/environment. Moving the refresh credential to the
owner's Keychain reduces that exposure; it cannot make an unmodified CLI's
access token invisible to the account running it. An API proxy could avoid
delegating an API key for supported providers, but subscription CLI protocols
are not a stable generic proxy contract. This implementation does not promise
that isolation.

## Implementation plan

1. Add a typed Projects service and terminal relay in the Companion. Commands
   use imported project IDs and tagged session IDs, never a client shell command
   or owner filesystem path. SSH remains loopback, crossing into the sandbox.
2. Issue separate, individually revocable device invitations from the Mac.
   Invitations contain a random Projects key, distinct from screen/audio pairing.
   Keep keys in each app's device-only Keychain; persist only names/IDs/addresses
   in preferences. TLS PSKs are domain-separated per invitation. Bind the device
   identity proof to this TLS session using its exporter. No native-stream token
   grants Projects access. Sharing an invitation is an intentional access grant.
3. Add Companion sandbox mode to the shared visionOS/iOS Projects UI. Import an
   invitation, list imported projects, start/stop sessions, and reconnect through
   the existing terminal UI. The Companion stays running for remote control.
4. Retain the existing SSH-account mode explicitly for full user access. Its
   credentials stay on the initiating device and retain the existing per-host
   policy; a sandbox invitation never authorizes this mode.
5. Disallow refresh-token delegation for sandbox credentials, including scheduled
   runs. Isolate sandbox Codex credential files by session and fail closed when
   writing credential setup fails. Serialize refreshes of the same credential,
   check Keychain writes and preserve a working item when an update fails. Keep
   current browser and device sign-in flows.
6. Verify framing, authentication, revocation, project/session validation, relay
   reconnect and builds for Companion, visionOS, iOS and macOS consumers.

## Access and lifetime

Each invitation grants control of the shared sandbox and its imported projects,
including stopping its tagged agent sessions. It does not grant reset, arbitrary
owner file access, host shell commands or reading credentials. Agent sign-in,
repository import, dependency copying, fetch-back, schedules and destructive
sandbox administration remain in the Mac's Projects window for this delivery.
Devices with access to the same sandbox account are not isolated from one another.
The invitation is reusable until revoked; issue a different one to each device.

Revocation closes connections and removes the key, but leaves tmux sessions
running. Disconnecting a terminal also leaves its session running. Attaching
from a second client takes over the tmux display, matching current attach -d
behavior. Reconnecting only attaches; it never replays credential injection or
automatically creates a replacement session after one has ended.

Short-lived access/ID tokens still reach the CLI over loopback SSH stdin. Codex
needs an access-only auth.json in the sandbox; refresh tokens stay on the owner
side. Pasted PATs may be long-lived: storing them in the Companion does not shorten
their provider-defined lifetime. Prefer browser OAuth when available. Existing
full-user SSH behavior is deliberate opt-in and retains its own credential policy.

## Follow-up work

The task-worktree, reviewed memory sync, schedule management and host repository
candidate APIs in AGENT_SANDBOX_PLAN.md remain separate work. The remote service
introduced here provides the session path without exposing those host actions.
Future enrollment can replace invitation sharing with native-paired requests
and local approval while keeping the independent Projects grant.
