import Foundation

// Pure command builders for app-managed agent sessions: tmux create/attach
// lines, the stdin env payload, the host-side reaper and session discovery.
//
// They live in a protocol extension rather than on `SSHTerminalManager` so the
// macOS client — which has no in-app terminal (its Projects tab attaches in
// Terminal.app) and doesn't compile `SSHTerminalManager` — builds exactly the
// same commands through `AgentSessionCommands`, while every existing
// `SSHTerminalManager.xxx` / `Self.xxx` call site keeps working unchanged.
// Protocol extensions can't hold stored statics, hence the computed `static var`
// constants.

/// A managed agent launch, split in two so no secret is ever in an argv.
///
/// Everything on a process's command line is readable by every local user
/// through `ps` — macOS redacts another user's *environment*, not its argv.
/// Inlining `TOKEN='…'` into the exec'd `zsh -lic '<line>'` therefore
/// published the token for as long as that zsh lived, which includes the
/// whole of its rc-file startup. On a single-user Mac that was moot; with a
/// second local account (the agent sandbox) it isn't.
///
/// So `create` runs first on its own non-PTY exec channel and reads the
/// environment from **stdin** (`payload`, one `NAME=<base64>` line per
/// variable), exports it inside the shell — never on a command line — and
/// creates the tmux session. `attach` then goes down the PTY channel and
/// carries no env at all; it is the same command rediscovered sessions use.
struct AgentLaunch: Sendable {
    /// Exec'd on a non-PTY channel with `payload` on stdin.
    let create: String
    /// `NAME=<base64(value)>\n` per variable. Send it, then EOF.
    let payload: Data
    /// Exec'd under the PTY once `create` has succeeded.
    let attach: String
}

protocol AgentSessionCommandBuilding {}

/// The builders, for callers without an `SSHTerminalManager` (the Mac client).
enum AgentSessionCommands: AgentSessionCommandBuilding {}

extension AgentSessionCommandBuilding {
    /// tmux-safe session name: alphanumerics, dashes collapsed, never empty.
    static func slug(_ input: String) -> String {
        let scalars = input.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        var out = String(scalars)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "claude" : out
    }

    static func folderName(_ path: String) -> String {
        let trimmed = (path.hasSuffix("/") && path != "/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    /// Wrap a string as a single-quoted shell token (robust against spaces and
    /// quotes via the close/escape/reopen idiom). Applied twice for the Claude
    /// command — once for the folder, once for the whole inner command — so the
    /// double shell nesting (sshd's `$SHELL -c` → `zsh -lic`) stays correct.
    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A tmux `-t` target for exactly this session, quoted. The leading `=` is
    /// tmux's exact-match prefix: without it `-t` falls back to *prefix*
    /// matching, so `kill-session -t longwave` would happily take out
    /// `longwave-reaper`, and an attach could land on a neighbouring session.
    ///
    /// Accepted by `has-session`, `attach-session`, `kill-session` and
    /// `set-environment` — **not** by `set-option`, whose `-t` is a *pane*
    /// target and which answers `no such session: =name`. Use `optionTarget`
    /// there; a bare name is safe for it because tmux prefers an exact match
    /// and the session has just been created under that exact name.
    static func target(_ tmuxSession: String) -> String {
        shellSingleQuote("=" + tmuxSession)
    }

    /// `set-option -t` target: quoted, but without the `=` exact-match prefix
    /// that `set-option` rejects. Verified against tmux 3.6 — and it fails into
    /// the `2>/dev/null` these lines carry, so getting it wrong would silently
    /// drop the `@longwave` tag (breaking rediscovery and the reaper) and
    /// `mouse on` (breaking scrollback) with no visible error at all.
    static func optionTarget(_ tmuxSession: String) -> String {
        shellSingleQuote(tmuxSession)
    }

    /// Wrap `inner` in a login + interactive shell.
    ///
    /// Interactive is not optional: an SSH *exec* channel runs the login shell
    /// non-interactively, which on macOS sources neither `/etc/zprofile` nor
    /// `~/.zshrc`, so `PATH` comes back as the bare system one. Homebrew's
    /// `/opt/homebrew/bin` is absent from it and `tmux` is simply not found —
    /// verified on this host, where `zsh -c 'command -v tmux'` finds nothing
    /// and `zsh -lic` finds `/opt/homebrew/bin/tmux`. Every remote tmux call
    /// goes through here for that reason.
    static func loginShellCommand(_ inner: String) -> String {
        "zsh -lic \(shellSingleQuote(inner))"
    }

    /// The tmux create-or-attach line for persistent shell sessions. Empty
    /// `client` → tmux runs its default shell. Managed agent sessions don't use
    /// this: their environment carries tokens, so they split creation onto its
    /// own channel (`agentLaunch`) instead of inlining values here.
    static func tmuxLaunchLine(tmuxSession: String, folder: String,
                                       client: String,
                                       environment: [(name: String, value: String)]) -> String {
        var line = tmuxCreateLine(tmuxSession: tmuxSession, folder: folder, client: client,
                                  environment: environment, inlineValues: true)
        line += sessionOptions(tmuxSession: tmuxSession)
        // `attach -d` detaches stale clients left behind by dropped connections
        // (tracking loss) so they can't pin the tmux window at the old size —
        // it also displaces any other legitimately attached client, accepted
        // for this app's one-window-per-session model.
        line += "exec tmux attach -d -t \(target(tmuxSession))"
        return line
    }

    /// Registers the env names with tmux, creates the session if absent and tags
    /// it. With `inlineValues` the values ride as `NAME='value'` assignments on
    /// `tmux new` (shell sessions, whose environment is non-secret by contract);
    /// without, the caller must already have exported them into this shell.
    static func tmuxCreateLine(tmuxSession: String, folder: String, client: String,
                                       environment: [(name: String, value: String)],
                                       inlineValues: Bool) -> String {
        let vars = environment.filter { !$0.name.isEmpty }
        var line = ""
        // A tmux server started before these vars existed snapshots an env
        // without them, and new sessions inherit that snapshot. Registering the
        // names in update-environment makes tmux import them from this client
        // when the session is created — so the token reaches `claude` even if a
        // server is already running, while staying scoped to this session (not
        // the server's global env). Verified on tmux 3.6.
        for v in vars {
            line += "tmux set -gqa update-environment \(shellSingleQuote(v.name)) >/dev/null 2>&1; "
        }
        // Create only if it isn't already there. NOT `tmux new -A -d`: with
        // `-A`, an existing session turns the command into `attach-session`,
        // and tmux then reads `-d` as attach's own flag rather than "stay
        // detached" (the man page maps new-session's `-D` onto it). So the
        // create line silently *attached* whenever the session already
        // existed — verified: `session_attached` goes 0 → 1. `has-session`
        // has no such double meaning. A simultaneous second launch loses the
        // create race with a harmless "duplicate session" on discarded stderr.
        line += "tmux has-session -t \(target(tmuxSession)) 2>/dev/null || "
        // Interactive shells honor TMOUT only while sitting at a prompt. It
        // lets abandoned shell sessions close themselves without interrupting
        // a command or agent that is still running.
        line += "TMOUT=\(promptIdleTimeoutSeconds) "
        if inlineValues {
            for v in vars {
                line += "\(v.name)=\(shellSingleQuote(v.value)) "
            }
        }
        line += "tmux new -d -s \(tmuxSession)"
        if !folder.isEmpty { line += " -c \(shellSingleQuote(folder))" }
        if !client.isEmpty { line += " \(client)" }
        line += "; "
        // Tag sessions this app creates with a user option so rediscovery after
        // an app restart can tell them apart from the user's own stray tmux
        // sessions (which it must never list or offer to kill).
        line += "tmux set-option -t \(optionTarget(tmuxSession)) @longwave 1 >/dev/null 2>&1; "
        return line
    }


    /// Printed by a successful create step; its absence means the create failed.
    static var agentCreatedMarker: String { "LONGWAVE-SESSION-READY" }
    /// Printed when the host has no tmux, so the UI can say so instead of
    /// retrying a launch that can never work.
    static var agentNoTmuxMarker: String { "LONGWAVE-NO-TMUX" }

    /// `setup` (see `AgentSessionSetup`) runs after the environment is exported;
    /// the names it consumes cross stdin but are kept out of tmux, and the names
    /// it exports are registered with tmux alongside the rest.
    static func agentLaunch(tmuxSession: String, folder: String,
                            clientCommand: String = "claude",
                            environment: [(name: String, value: String)] = [],
                            setup: AgentSessionSetup? = nil) -> AgentLaunch {
        let vars = environment.filter { AgentEnvironment.isValidEnvName($0.name) }
        var names = vars.map(\.name).filter { !(setup?.consumedNames.contains($0) ?? false) }
        for name in setup?.exportedNames ?? [] where AgentEnvironment.isValidEnvName(name) && !names.contains(name) {
            names.append(name)
        }
        let inner = agentCreateScript(tmuxSession: tmuxSession, folder: folder,
                                      clientCommand: clientCommand, names: names,
                                      setupScript: setup?.script ?? "")
        // The reader runs in a plain POSIX `sh` *before* the login shell, so an
        // rc file can't swallow stdin, and whatever shell sshd hands us (bash,
        // zsh, fish) only has to exec `/bin/sh`. The exported values reach
        // `zsh -lic` — and from it `tmux new` — through the environment.
        let create = "/bin/sh -c " + shellSingleQuote(envStdinReader + "exec " + loginShellCommand(inner))
        return AgentLaunch(create: create, payload: envPayload(vars),
                           attach: attachCommand(tmuxSession: tmuxSession))
    }

    /// The login-shell half of `AgentLaunch.create`: registers `names` with
    /// tmux (their values are already exported by `envStdinReader`), creates
    /// and tags the session, and reports the outcome on stdout.
    static func agentCreateScript(tmuxSession: String, folder: String,
                                  clientCommand: String, names: [String],
                                  setupScript: String = "") -> String {
        let client = clientCommand.isEmpty ? "claude" : clientCommand
        var script = "command -v tmux >/dev/null 2>&1 || { echo \(agentNoTmuxMarker); exit 1; }; "
        script += setupScript
        script += tmuxCreateLine(tmuxSession: tmuxSession, folder: folder, client: client,
                                 environment: names.map { (name: $0, value: "") },
                                 inlineValues: false)
        script += "tmux has-session -t \(target(tmuxSession)) 2>/dev/null && echo \(agentCreatedMarker)"
        return script
    }

    /// Encodes `environment` for `envStdinReader`: base64 keeps quotes,
    /// newlines and `$` in values from ever meeting a shell parser.
    static func envPayload(_ environment: [(name: String, value: String)]) -> Data {
        var out = ""
        for v in environment where AgentEnvironment.isValidEnvName(v.name) {
            out += "\(v.name)=\(Data(v.value.utf8).base64EncodedString())\n"
        }
        return Data(out.utf8)
    }

    /// POSIX `sh` that exports each `NAME=<base64>` line from stdin.
    ///
    /// Every step that touches a value is a builtin (`read`, `printf`, `export`)
    /// or reads it from a pipe (`base64`), so no value is ever an argument of an
    /// exec'd process. The name check mirrors `AgentEnvironment.isValidEnvName`.
    /// `printf x` / `${v%x}` preserves trailing newlines that command
    /// substitution would otherwise strip. GNU coreutils decodes with `-d`,
    /// older macOS `base64` only knew `-D`.
    static var envStdinReader: String {
        "if printf eA== | base64 -d >/dev/null 2>&1; then d=-d; else d=-D; fi; "
        + "while IFS= read -r l || [ -n \"$l\" ]; do "
        + "case $l in *=*) ;; *) continue;; esac; "
        + "n=${l%%=*}; v=${l#*=}; "
        + "case $n in ''|[0-9]*|*[!A-Za-z0-9_]*) continue;; esac; "
        + "v=$(printf %s \"$v\" | base64 $d; printf x); v=${v%x}; "
        + "export \"$n=$v\"; "
        + "done; "
    }

    /// Re-attach an already-running tmux session — no create, no command, no
    /// token (the live session already carries the agent and its env). Used to
    /// reconnect to sessions rediscovered on the host after an app restart.
    /// Session options are deliberately re-applied here so sessions created by
    /// older Longwave versions gain scrolling and the prompt timeout too.
    static func attachCommand(tmuxSession: String) -> String {
        let inner = sessionOptions(tmuxSession: tmuxSession)
            + "exec tmux attach -d -t \(target(tmuxSession))"
        return loginShellCommand(inner)
    }

    /// Options every app-managed session must have, including old sessions
    /// being re-attached after an upgrade.
    ///
    /// `TMOUT` here only ever reaches a **shell**, and only one sitting at a
    /// prompt. A managed agent session's pane process is the agent itself
    /// (verified: `pane_current_command` is the `claude` binary, not a shell), so
    /// TMOUT is structurally incapable of closing one — that's the watchdog's job.
    static func sessionOptions(tmuxSession: String) -> String {
        "tmux set-environment -t \(target(tmuxSession)) TMOUT \(promptIdleTimeoutSeconds) >/dev/null 2>&1; "
            + mouseOption(tmuxSession: tmuxSession)
            + reaperWatchdogCommand(ttlSeconds: staleSessionTTLSeconds,
                                    intervalSeconds: reaperIntervalSeconds)
    }

    /// Turn on tmux's own mouse handling, scoped to this session.
    ///
    /// Without it the terminal has nothing to scroll: tmux is a full-screen
    /// program, so it lives in the alternate screen buffer where the emulator
    /// keeps no scrollback of its own — the history is tmux's, and only tmux can
    /// move it. With `mouse on` tmux enables mouse tracking (verified: it emits
    /// DECSET 1000/1002/1006 to the client), so the wheel events a drag or a
    /// paging button sends land in its copy-mode instead of falling through to
    /// the shell as PageUp/PageDown — which zsh reads as history navigation, and
    /// which is what "the scroll buttons scroll my history" looked like.
    ///
    /// Deliberately not `-g`: this is the app's own session, and the user's
    /// other tmux sessions on the host are none of its business.
    static func mouseOption(tmuxSession: String) -> String {
        "tmux set-option -t \(optionTarget(tmuxSession)) mouse on >/dev/null 2>&1; "
    }

    /// tmux-wrapped generic terminal session: survives connection drops like a
    /// Claude session, with a runtime fallback to a plain (non-persistent)
    /// shell on hosts without tmux installed.
    static func persistentShellCommand(tmuxSession: String, launch: String,
                                       environment: [(name: String, value: String)] = []) -> String {
        let tmuxPath = tmuxLaunchLine(tmuxSession: tmuxSession, folder: "",
                                      client: launch, environment: environment)
        var fallback = shellCommand(launch: launch, environment: environment)
        if fallback.isEmpty { fallback = "exec \"$SHELL\" -l" }
        let inner = "if command -v tmux >/dev/null 2>&1; then \(tmuxPath); else \(fallback); fi"
        return loginShellCommand(inner)
    }

    /// Builds a generic (non-tmux) session command carrying non-secret
    /// `environment`. No env → `launch` unchanged (empty → a login shell).
    /// Otherwise the assignments prefix the command, or an exec'd login shell.
    static func shellCommand(launch: String,
                             environment: [(name: String, value: String)] = []) -> String {
        let assignments = environment
            .filter { !$0.name.isEmpty }
            .map { "\($0.name)=\(shellSingleQuote($0.value)) " }
            .joined()
        guard !assignments.isEmpty else { return launch }
        if launch.isEmpty { return "\(assignments)exec \"$SHELL\" -l" }
        return "\(assignments)\(launch)"
    }

    /// Shells exit only after this much inactivity while waiting at a prompt.
    /// `TMOUT` is inherited by the initial shell and stored in the tmux session
    /// environment for any panes created later.
    static var promptIdleTimeoutSeconds: Int { 12 * 60 * 60 }  // 12h

    /// How long an app-created tmux session may sit with no attached client and
    /// no activity before it's considered abandoned and reaped. Short disconnects
    /// (window close, network blip, reconnect) stay well under this, so the
    /// reconnect-to-a-running-agent behaviour is preserved; what it kills is the
    /// long tail of sessions nobody came back to. Reaping them also frees agents
    /// pinning a stale on-disk binary after a `claude` self-update (a running
    /// process keeps executing the old inode until it exits and relaunches).
    ///
    /// Deliberately **shorter than a full-scope Claude access token's ~8h life**
    /// (see `ClaudeOAuth`). A token is injected once, at launch, into the agent
    /// process's environment — a running process's env can't be rewritten, so
    /// re-attaching a session whose token has expired hands back an agent that
    /// can't authenticate and can only be fixed by restarting it. Reaping before
    /// that point means a stale session is always gone rather than broken.
    static var staleSessionTTLSeconds: Int { 6 * 60 * 60 }  // 6h

    /// How often the host-side watchdog re-checks. Cheap (one `tmux
    /// list-sessions` per tick), so this is set for responsiveness near the TTL
    /// boundary rather than to save cycles.
    static var reaperIntervalSeconds: Int { 15 * 60 }

    /// tmux session name for the host-side watchdog. Deliberately **not** tagged
    /// `@longwave`, which keeps it out of both the reap set (it must not kill
    /// itself) and session rediscovery (it isn't a session the user opened).
    static var reaperSessionName: String { "longwave-reaper" }

    /// Starts (or re-uses) a detached watchdog on the host that reaps stale
    /// sessions on an interval and exits once none remain.
    ///
    /// This exists because `reapStaleSessions` only runs when the app connects,
    /// which means nothing collects abandoned sessions while the headset is off —
    /// observed in practice as app-tagged sessions alive after 13h, 14h and 88h
    /// detached against a 12h TTL. A host-side timer is the only thing that closes
    /// them without the app present.
    ///
    /// `has-session ||` is the whole concurrency story: it can't produce a
    /// duplicate, and it transparently restarts a watchdog that died, so no
    /// lockfile or pidfile is needed and nothing is left on the host's disk. Two
    /// launches racing the guard is harmless — the loser's `new` fails with
    /// "duplicate session" onto discarded stderr. The script is base64'd because
    /// it has to survive three levels of shell quoting (`zsh -lic '…'` →
    /// `tmux new … sh -c "…"` → the loop itself); encoded, it carries no quotes
    /// or `$` for an outer layer to chew on.
    static func reaperWatchdogCommand(ttlSeconds: Int, intervalSeconds: Int) -> String {
        // `session_activity` is the idle signal: it advances on pane *output*, and
        // an agent waiting at its prompt is silent, so it stops climbing when the
        // session is genuinely abandoned (verified against real sessions).
        let script = """
        while :; do
        sleep \(intervalSeconds)
        now=$(date +%s)
        tmux list-sessions -F '#{session_attached}|#{session_activity}|#{@longwave}|#{session_name}' 2>/dev/null | while IFS='|' read -r att act mark name; do
        [ "$mark" = 1 ] && [ "$att" = 0 ] && [ $((now - act)) -gt \(ttlSeconds) ] && tmux kill-session -t "$name"
        done
        tmux list-sessions -F '#{@longwave}' 2>/dev/null | grep -q 1 || exit 0
        done
        """
        let encoded = Data(script.utf8).base64EncodedString()
        // `has-session ||` rather than `new -A -d` for the reason given in
        // `tmuxLaunchLine`, and here it was the visible bug: this line runs at
        // the end of every launch, so once a watchdog existed the next launch
        // attached the user's terminal to *it* instead of leaving it detached.
        // What you got was a bare shell under a `[longwave-reaper] 0:bash`
        // status bar — input worked, the project session was nowhere, and the
        // `exec tmux attach` below never ran because this line never returned.
        return "tmux has-session -t \(target(reaperSessionName)) 2>/dev/null || "
            + "tmux new -d -s \(reaperSessionName) "
            + "sh -c \"echo \(encoded)|base64 -d|sh\" >/dev/null 2>&1; "
    }

    /// Server-side reap pipeline: for every `@longwave`-tagged session with zero
    /// attached clients whose last activity is older than `ttlSeconds`, kill it.
    /// The host's own clock (`date +%s` vs tmux `#{session_activity}`, both host
    /// epoch) is used so device/host clock skew can't mis-fire. Untagged sessions
    /// (the user's own) and currently-attached ones (in use on this or another
    /// device) are never touched. POSIX-`sh`-safe so it runs under either login
    /// shell sshd hands us.
    static func staleSessionReapCommand(ttlSeconds: Int) -> String {
        "now=$(date +%s); tmux list-sessions "
            + "-F '#{session_attached}|#{session_activity}|#{@longwave}|#{session_name}' 2>/dev/null "
            + "| while IFS='|' read -r att act mark name; do "
            + "[ \"$mark\" = 1 ] && [ \"$att\" = 0 ] && [ $((now - act)) -gt \(ttlSeconds) ] "
            + "&& tmux kill-session -t \"$name\"; done"
    }

    static func parseLsEntries(_ output: String) -> [DirEntry] {
        output.split(separator: "\n").compactMap { raw -> DirEntry? in
            let s = String(raw)
            guard !s.isEmpty else { return nil }
            if s.hasSuffix("/") {
                return DirEntry(name: String(s.dropLast()), isDir: true)
            }
            return DirEntry(name: s, isDir: false)
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }

    /// `tmux list-sessions` in the tab-separated shape `parseDiscoveredSessions`
    /// reads. Run it through `loginShellCommand` (tmux needs the login PATH).
    static var discoverSessionsCommand: String {
        "tmux list-sessions -F '#{session_name}\t#{session_path}\t#{@longwave}' 2>/dev/null"
    }

    /// App-created agent sessions in `discoverSessionsCommand` output: the
    /// `@longwave` marker filters out the user's own tmux sessions, and shell
    /// sessions (`vnc-` prefix) are skipped. The title surfaces the agent suffix
    /// (`proj-copilot` → "proj (Copilot)") so two agents launched in the same
    /// folder are distinguishable. Banner lines from rc files never match (they
    /// lack three tab-separated fields with the marker last).
    static func parseDiscoveredSessions(_ output: String) -> [DiscoveredAgentSession] {
        var found: [DiscoveredAgentSession] = []
        for raw in output.split(separator: "\n") {
            // name \t path \t marker — marker is the last field; the middle is
            // rejoined so a (pathological) tab in the path can't shift it.
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let name = parts[0]
            guard !name.isEmpty, !name.hasPrefix("vnc-"), parts[parts.count - 1] == "1" else { continue }
            let folder = parts[1..<(parts.count - 1)].joined(separator: "\t")
            let base = folder.isEmpty ? name : folderName(folder)
            var title = base
            let baseSlug = slug(base)
            if name != baseSlug, name.hasPrefix(baseSlug + "-") {
                title = "\(base) (\(name.dropFirst(baseSlug.count + 1).capitalized))"
            }
            found.append(DiscoveredAgentSession(name: name, folder: folder, title: title))
        }
        return found
    }
}

/// One app-created tmux session found on a host.
struct DiscoveredAgentSession: Sendable, Equatable {
    let name: String
    let folder: String
    let title: String
}

/// A remote directory entry from the Projects folder browser.
struct DirEntry: Identifiable, Hashable, Sendable {
    let name: String
    let isDir: Bool
    var id: String { name }
}
