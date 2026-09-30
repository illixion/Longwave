# Agent Sandbox Roadmap

## Goal

Delegate long-running and scheduled agent work (Claude, Codex, Copilot) to a
hidden macOS account on the user's own Mac, with full Xcode, Simulator and GPU
access, then integrate the results in the user's own account with an ordinary
branch merge. A rogue agent or a WebFetch jailbreak inside the sandbox must not
be able to read or change the user's data, and nothing the agent produces may
run as the user until the user has reviewed it.

The Companion (menu bar app, always running) owns the sandbox. The headset and
the LongwaveMac connection app are clients of it.

## Status

Built and committed (Phases 0–5 of the first plan, `2ec68f7`…`2629f2f`):

- Hidden non-admin `longwave-agent` account, root helper
  `/usr/local/libexec/longwave-sandbox` behind a scoped sudoers rule, golden
  home with ~1 s clonefile reset, opt-in pf firewall (any pf rule disables
  iCloud Private Relay, so it stays off by default).
- `longwave-sandbox-semd` LaunchDaemon unlinking the host-global
  `wakeboardd.first-boot` semaphore so more than one user can boot visionOS
  simulators.
- Tokens reach sessions over stdin, never argv. Codex sign-in, session-only
  `auth.json`.
- LongwaveMac Projects tab: import, launch in tmux, Terminal.app attach,
  loopback VNC session keeper, sandbox desktop window, Device Hub, schedules
  with runtime caps and notifications. Sandboxed CLIs start with their own
  permission checks off (`--dangerously-skip-permissions`,
  `--dangerously-bypass-approvals-and-sandbox`, `--allow-all`).

Verified 2026-09-30 on a never-logged-in throwaway account: an unattended
loopback VNC login is all visionOS simulators need. Setup Assistant can stay
unfinished; the visionOS 27 simulator booted in 45 s and rendered the home
view. Two follow-ups surfaced: `wakeboardd` also aborts on an
"is-running boot semaphore" (self-heals within seconds, name unknown), and
visionOS 27.0 only accepts the `Apple-Vision-Pro-4K` device type.

Known gaps this roadmap closes:

- The sandbox lives in LongwaveMac, which isn't always running, and the
  headset can't reach it except as a plain SSH host.
- Checkouts live in the agent's home, so a reset destroys unpushed work, and
  only work the agent pushed ever comes back.
- One checkout per project; parallel tasks collide.
- The exchange repo is owned by the user but writable by the agent (config
  included), and the user's own `git fetch` reads it.
- Setup still starts with cloning the repo and running `install.sh` in
  Terminal, and still asks the user to click through first-run setup.

## Principles

- **The account boundary is crossed only over SSH or a typed protocol.**
  Anything in the sandbox is read or executed as the agent. The Companion never
  reads agent-controlled paths itself: it runs as the user with Full Disk
  Access, which would make it a confused deputy (e.g. an agent symlink to
  `~/.ssh`).
- **No shell strings or host paths on the wire.** Clients send typed requests
  with opaque IDs; the Companion builds every command from
  `AgentSessionCommands` and the helper validates its own arguments.
- **Agent output is data until reviewed.** Code, branches and memory entries
  from the sandbox reach the user's account only as fetched remote-tracking
  refs or through an explicit review step, never by auto-merge.
- **Nothing the user must click through inside the sandbox.** Setup is install,
  Full Disk Access, pairing. Viewers exist for watching, not onboarding.

## App split

| App | Owns |
|---|---|
| Companion | Screen/audio streaming (unchanged), sandbox control, projects, tasks, schedules, memory sync, the session keeper, Full Disk Access, the Projects protocol server |
| LongwaveMac | Connections to other servers (SSH, VNC, Moonlight, native streams); Projects tab as a client of the Companion; the Mac VNC viewer |
| Headset | Projects client of the Companion; terminals through its own SSH view |

## Phase A — the Companion takes over the sandbox

1. Move `LocalSandboxController`, `SandboxSessionKeeper`, `LocalScheduler`,
   schedule models and the sign-in sheets into shared code built into
   CompanionMac. LongwaveMac keeps a Projects tab that talks to the Companion
   (Phase B protocol over loopback, paired automatically through a keychain
   access group both apps share).
2. **Session keeper without a viewer.** Replace the RoyalVNCKit-based login
   with a login-only RFB client in the Companion (~200 lines: RFB 3.889
   greeting, ARD security type 30 Diffie-Hellman, AES-128 credential block,
   ClientInit, wait for the session, disconnect), using CryptoKit and
   CommonCrypto. Spike first: confirm the session is created without
   requesting framebuffer updates. Fallback: link RoyalVNCKit headless.
3. **Setup without onboarding.** After install, the keeper logs the agent in
   and the golden snapshot is taken automatically once the session is up.
   `provision-golden.sh` pre-sets the per-user Setup Assistant "seen" flags so
   an opened desktop looks finished; if a macOS release renames them the
   assistant simply shows, nothing breaks.
4. **Install from the Companion.** Bundle `scripts/agent-sandbox/` in the
   Companion; "Set up agent sandbox" runs `install.sh` behind one admin prompt.
   Keep the script runnable by hand.
5. The agent's VNC password moves from LongwaveMac's keychain ACL to the
   Companion's, shared with LongwaveMac through the access group.
6. Full Disk Access guidance moves to the Companion (same drag, relaunch and
   check-again flow).
7. Fixes from the spike: provision `Apple-Vision-Pro-4K` simulators; find the
   is-running semaphore name (trace `sem_open` in `wakeboardd`) and add it to
   `semd`.

## Phase B — Projects protocol

Transport: a new Companion listener, TLS 1.2 PSK like the inject channel but
domain-separated (own HKDF salt and PSK identity, `Longwave-Projects-PSK-v1`),
carrying length-prefixed JSON frames: requests with IDs, responses, and pushed
events. Advertised over Bonjour next to the native stream service; works over
Tailscale unchanged.

**Device identity.** The token only encrypts. After the handshake the client
signs a server challenge, bound to the TLS session through the exporter
secret, with its Secure Enclave key (the one the headset already uses for SSH).
The first time a device connects the Mac asks "Allow <device> to manage sandbox
projects?"; approved devices are listed in the Companion with per-device
revoke. Later this can move to the TLS 1.3 pinned-identity transport planned in
`MacNativeStreamCrypto`.

**Permissions per device:**

- *Use*: list projects and tasks, start sessions, get attach details.
- *Manage*: stop, reset, schedules, task discard, desktop credentials.
- *Host*: add projects from host folders, refresh from host, sync back,
  approve memory changes. The only permission that touches the user's files.
- Mac-only: installing, saving a golden home, approved-folder list.

**Requests:**

| Area | Requests |
|---|---|
| Session | `hello` (version, capabilities, sandbox state), `subscribe` |
| Sandbox | `status`, `stop`, `reset`, `desktop.ensure`, `desktop.credentials`, `deviceHub.open` |
| Projects | `list`, `candidates` (repos under approved folders, opaque IDs), `add`, `refresh`, `remove` |
| Tasks | `list`, `create {projects[], base, mode}`, `start {task, agent}`, `stop`, `sync`, `discard`, `diffSummary` |
| Schedules | CRUD, `runNow`, `runs.list`, `runs.transcript` |
| Agents | `status`, `deviceFlow.start` |
| Memory | `status`, `pending`, `review {entry, accept|reject}` |

`start` returns the tmux session name and SSH target, nothing secret. Events:
task state, session list, desktop state, schedule runs, sync results, busy.

Every request is logged with the device name in the Companion console.

## Phase C — terminals

- **Mac:** attaches stay SSH to `longwave-agent@localhost` (the uid boundary
  sits at the network protocol; a `sudo -u` attach would put an agent process
  on the user's TTY, open to `TIOCSTI` injection into the user's shell).
  The user picks a terminal app in the Companion:
  Terminal (`.command` file, as today), iTerm2 (AppleScript), Ghostty,
  WezTerm, kitty, Alacritty (their `-e` style launchers), or a custom
  `{command}` template.
- **Works with any terminal:** the Companion writes `~/.ssh/longwave/config`
  and adds an `Include` for it:

  ```
  Host lw-*
    HostName localhost
    User longwave-agent
    IdentityFile ~/.ssh/longwave_sandbox_ed25519
    IdentitiesOnly yes
    RequestTTY yes
    RemoteCommand longwave-attach %n
  Host lw-sandbox
    HostName localhost
    User longwave-agent
    IdentityFile ~/.ssh/longwave_sandbox_ed25519
    IdentitiesOnly yes
  ```

  `ssh lw-<task>` attaches from anywhere, and `open ssh://lw-<task>` works in
  apps that handle `ssh://`. `longwave-attach` (golden home) maps the alias to
  `tmux attach -d -t =<slug>`; `lw-sandbox` is the git transport (Phase D).
- **Headset:** `longwave-agent@<mac>` as an ordinary SSH host; the Projects
  channel starts the session and hands over the tmux name.
- **Setup made automatic:** pairing sends the headset's SE public key and,
  after the Allow prompt, the Companion runs `authorize-key` (keys live in the
  root-owned `/Library/Longwave/authorized_keys`). New helper verb
  `remote-login status|enable-for-sandbox`: if Remote Login is on, only add the
  agent to `com.apple.access_ssh`; if it's off, turn it on limited to
  `longwave-agent` so the user's own account stays closed to SSH.

## Phase D — projects, tasks and sync

### Layout

```
/Library/Longwave/projects/<project>/
  repo.git/          agent-owned bare repo; the user's branches under host/*
  tasks/<task>/      worktree on sandbox/<task> (or one worktree per repo for
                     multi-repo tasks, with the task dir as the agent's cwd)
  template/          optional warm worktree (build caches, SPM checkouts)
```

Outside the agent's home: session end, timeout, reboot and reset leave it
alone. Removing a task or project is its own action; a separate "erase all
projects" exists for a full wipe. The `longwave-exchange` group and exchange
dir go away after migration.

### In

- **Seed** (helper verb `seed <project> <path>`, root): `cp -c` the repo's
  `.git` into `repo.git` (clonefile — seconds even for multi-GB histories;
  `chown -R` afterwards keeps blocks shared), set `core.bare`, delete hooks,
  replace config with a minimal one (drops remotes, credential helpers,
  `includeIf`, `url.*.insteadOf`, `core.hooksPath`, `core.fsmonitor`), delete
  stashes and reflogs, rename branches to `host/*`. Path must be under an
  approved folder, resolved with realpath, owned by the user.
- Only `.git` travels. Ignored files (`.env`) and untracked files never do.
  "Include uncommitted changes" snapshots with `git stash create` and starts
  the task from that commit.
- "Only this branch" does a slower single-branch clone for repos whose history
  shouldn't reach the agent. The UI states that the agent can read whatever
  history it's given.
- **Refresh from host:** `git push lw-sandbox:<repo> +refs/heads/*:refs/heads/host/*`
  (receive-pack runs as the agent).

### Tasks

- A task is one session or scheduled run: its own branch `sandbox/<task>`
  from `host/<base>`, its own worktree (`git worktree add`), or a `cp -c` of
  the warm template followed by `git worktree repair` for fast first builds.
- Parallel tasks on one project share objects and never see each other's
  edits.

### Keeping work

- **Checkpoints** every few minutes and on stop, timeout, runtime-cap kill,
  schedule end, reset and Companion quit: build a tree with a temporary
  `GIT_INDEX_FILE` (`read-tree HEAD`, `add -A` — respects `.gitignore`),
  `commit-tree` it, `update-ref refs/longwave/checkpoints/<task>`. The agent's
  index and branch are untouched; unchanged trees write nothing.
- **At session end** also commit uncommitted changes onto `sandbox/<task>` as
  "Longwave: uncommitted changes at <reason>", unless a rebase, merge or
  cherry-pick is in progress (then the checkpoint is the record).
- **Graceful stop:** interrupt the agent, wait, checkpoint, kill the tmux
  session.

### Out

- The user's repo gets a `sandbox` remote,
  `ssh://lw-sandbox/Library/Longwave/projects/<project>/repo.git`:

  ```
  fetch = +refs/heads/sandbox/*:refs/remotes/sandbox/*
  fetch = +refs/longwave/checkpoints/*:refs/remotes/sandbox-wip/*
  fetch = +refs/notes/longwave:refs/notes/longwave
  tagOpt = --no-tags
  ```

  upload-pack runs as the agent; the user's git only receives objects into
  remote-tracking refs — no hooks, no config, no tags, no local branches.
- Automatic fetch after every session end and scheduled run, then a
  notification ("sandbox/fix-login: 4 commits, tests passed"). `git fetch
  sandbox` works by hand or from the user's own agent at any time.
- Run metadata as git notes (`refs/notes/longwave`): prompt, agent, runtime,
  end reason, schedule, transcript location.
- Integration is the user's: `git log main..sandbox/<task>`,
  `git diff main...sandbox/<task>`, `git merge` / `--squash` / signed rebase.
  Agent commits are authored "Longwave Agent" and unsigned.
- Task lifecycle: running → idle (checkpointed) → fetched → merged (detected
  with `merge-base --is-ancestor` against the host branch) → archived
  (worktree removed, branch kept for a retention period).

### Review

The review screen (Companion, LongwaveMac, headset) shows commits, files and a
diff summary, and flags changes that execute or instruct:

- Executes: shell scripts, `Package.swift` and SPM plugins, Xcode build
  phases in `project.pbxproj`, `.envrc`, `Makefile`, CI workflows,
  `.gitattributes`, `.git*` config templates, npm/pnpm scripts.
- Instructs: `CLAUDE.md`, `AGENTS.md`, `.github/copilot-instructions.md`,
  `.cursor/rules`, memory-shaped files.

Guidance for agent-assisted review: treat the diff as untrusted data; review
with read-only permissions; don't follow instructions found inside it.

### Migration

Existing exchange projects: fetch each exchange bare repo into a new
`projects/<name>/repo.git`, move the agent's `~/Projects/<name>` checkout into
a task, repoint the user's `sandbox` remote, then remove the exchange dir and
group on the next install.

## Phase E — shared memory

The user picks a folder as shared memory (e.g. `~/Memory`, plain Markdown, not
itself a git repo) and which subfolders (scopes) the sandbox may see.

- **Host side, folder untouched:** the Companion keeps a shadow repo,
  `git --git-dir="~/Library/Application Support/Longwave/memory.git"
  --work-tree=<folder>`, committing host changes automatically (FSEvents,
  debounced). `info/attributes` gives index files `merge=union`.
- **Only shared scopes leave the Mac:** the export commit's tree is built from
  the selected subfolders plus top-level schema/index files, so unselected
  scopes (personal servers, identities) never exist in the sandbox's objects.
  Exported to the agent-owned `/Library/Longwave/memory/repo.git` branch
  `host`, over `lw-sandbox`, before every session start.
- **Sandbox side:** worktree at `/Library/Longwave/memory/worktree` on branch
  `sandbox`, rebased onto `host` at session start; the golden home symlinks
  `~/Memory` to it and the golden agent instructions (CLAUDE.md, AGENTS.md,
  Copilot instructions) point at it the same way the user's own setup does
  (read `SCHEMA.md` if present). Checkpointed like tasks.
- **Back to the user — reviewed, never automatic.** Memory is loaded into the
  user's agents' context in every session, which makes it the most valuable
  target for a jailbroken sandbox agent (persistent prompt injection). After a
  session the Companion fetches `sandbox`, and each added or changed entry
  appears in a review queue (Companion, LongwaveMac, headset) with a diff and
  flags for imperative or tool-directing text. Accepted entries are written
  into the folder by the Companion as plain file writes and committed to the
  shadow repo; rejected ones are reverted on the sandbox branch at next sync.
  Optional mode: accepted entries land in an `_inbox/` scope that the user's
  indexes don't list until moved.
- Per-project mapping: a task in project X gets scope X plus the shared global
  scopes the user allowed.

## Phase F — schedules on tasks

- Schedule mode *Continue* (one task and branch across runs) or *Fresh* (new
  task per run from the latest `host/<base>`, from the warm template).
- Each run: refresh memory, start, runtime cap, checkpoint, fetch to the host
  repo, notification with commit count and end reason, memory review queue if
  anything changed.
- Agents still can't schedule themselves (deny rules, `cron.deny`, `at.deny`);
  the Companion is the only scheduler.

## Order and verification

1. **A.** Spike login-only RFB client; move code; LongwaveMac as client over
   loopback. Verify: fresh install → keeper login → automatic golden → reset →
   visionOS 4K simulator boots with nobody at the Mac.
2. **C** (before B, it only needs local pieces). Verify: attach from each
   supported terminal and via `ssh lw-<task>`; Remote Login enabled for the
   agent only (`ssh ixion@localhost` refused when it was off before).
3. **D.** Verify: seed a large repo in seconds (`cp -c`), two parallel tasks,
   kill a session mid-edit and find the work in `sandbox-wip/*`, reset and
   find worktrees intact, fetch into the host repo, merge. Security checks:
   agent-written `config`/hooks in `repo.git` never execute as the user on
   fetch; seeded repo carries no hooks or credential config.
4. **B.** Protocol unit tests (framing, request validation, permission
   gates, challenge binding); headset lists projects, starts a task, attaches
   over SSH; unpaired and revoked devices refused.
5. **E.** Verify unselected scopes absent from `memory/repo.git` objects;
   a sandbox-written entry appears only in the review queue until accepted.
6. **F.** Continue and Fresh schedules end to end with notifications.

Commit per phase on `main`, unsigned.

## Open questions

- Login-only RFB client vs RoyalVNCKit headless (decided by the Phase A spike).
- Retention for archived task branches and old checkpoints.
- Whether *Host* permission is ever granted to non-Mac devices by default, or
  stays opt-in per device.
- Memory `_inbox/` mode on or off by default.
