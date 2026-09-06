import XCTest
@testable import Longwave

/// Pure logic on `SSHTerminalManager`/`SSHSession`: the tmux launch-command
/// builders (Claude + persistent shell with tmux fallback) and the
/// auto-reconnect backoff helper.
@MainActor
final class SSHTerminalManagerTests: XCTestCase {

    // MARK: - claudeCommand

    func testClaudeCommandAttachesDetachingStaleClients() {
        let cmd = SSHTerminalManager.claudeCommand(tmuxSession: "proj", folder: "/Users/me/proj")
        XCTAssertTrue(cmd.hasPrefix("zsh -lic '"))
        // Created only if absent. `tmux new -A -d` cannot be used: `-A` turns an
        // existing session into an attach, and tmux then reads `-d` as
        // attach-session's own flag instead of "stay detached", so the create
        // line took over the terminal.
        XCTAssertTrue(cmd.contains("tmux has-session -t '\\''=proj'\\'' 2>/dev/null || "))
        XCTAssertTrue(cmd.contains("tmux new -d -s proj -c '\\''/Users/me/proj'\\'' claude"))
        // -d detaches stale clients from dropped connections so they can't
        // pin the tmux window at the old size.
        XCTAssertTrue(cmd.contains("exec tmux attach -d -t '\\''=proj'\\''"))
    }

    func testClaudeCommandInjectsEnvironmentInline() {
        let cmd = SSHTerminalManager.claudeCommand(
            tmuxSession: "p", folder: "/p",
            environment: [(name: "TOK", value: "secret")]
        )
        XCTAssertTrue(cmd.contains("tmux set -gqa update-environment '\\''TOK'\\''"))
        XCTAssertTrue(cmd.contains("TOK='\\''secret'\\'' tmux new"))
    }

    /// The managed Claude launch *unlocks* bypass mode rather than entering it:
    /// `--allow-dangerously-skip-permissions` adds it to the Shift+Tab cycle while
    /// the session still starts in Claude's normal default mode.
    /// `--dangerously-skip-permissions` would start every headset session with all
    /// checks off, so it must never reach the launch line.
    func testManagedClaudeLaunchUnlocksBypassWithoutEnablingIt() {
        let host = SavedConnection(hostname: "h", port: 22, connectionType: .ssh)
        let cmd = SSHTerminalManager.claudeCommand(
            tmuxSession: "proj", folder: "/p",
            clientCommand: host.effectiveCommand(for: .claude))
        XCTAssertTrue(cmd.contains("claude --allow-dangerously-skip-permissions"))
        XCTAssertFalse(cmd.contains(" --dangerously-skip-permissions"))
        // The mode is left to Claude's own default — no override is passed.
        XCTAssertFalse(cmd.contains("--permission-mode"))
    }

    func testAttachCommandReattachesWithoutCreatingOrToken() {
        let cmd = SSHTerminalManager.attachCommand(tmuxSession: "proj-copilot")
        XCTAssertTrue(cmd.hasPrefix("zsh -lic '"))
        // Rediscovered sessions only re-attach: the target session is never
        // (re)created, and no env/token is injected. The one `tmux new` allowed
        // here is the idle watchdog's own session, which re-attach also starts.
        XCTAssertFalse(cmd.contains("-s proj-copilot"))
        XCTAssertFalse(cmd.contains("secret"))
        XCTAssertTrue(cmd.contains("exec tmux attach -d -t '\\''=proj-copilot'\\''"))
    }

    /// tmux is a full-screen program, so it lives in the alternate screen where
    /// the emulator keeps no scrollback — without tmux's own mouse handling there
    /// is nothing for a drag or a paging button to scroll, and they fall through
    /// to the shell as PageUp/PageDown (which zsh reads as history navigation).
    func testEverySessionTurnsOnTmuxMouseHandling() {
        let launched = SSHTerminalManager.claudeCommand(tmuxSession: "proj", folder: "/p")
        XCTAssertTrue(launched.contains("tmux set-option -t '\\''proj'\\'' mouse on"))

        // Sessions rediscovered after an app restart were created before this
        // ran, so re-attaching has to set it too.
        let reattached = SSHTerminalManager.attachCommand(tmuxSession: "proj")
        XCTAssertTrue(reattached.contains("tmux set-option -t '\\''proj'\\'' mouse on"))
        XCTAssertTrue(reattached.contains("exec tmux attach -d -t '\\''=proj'\\''"))

        // Scoped to this session — the user's own tmux sessions are none of the
        // app's business, so never `-g`.
        XCTAssertFalse(launched.contains("set -g mouse"))
        XCTAssertFalse(launched.contains("set-option -g mouse"))
    }

    func testEverySessionInstallsPromptIdleTimeout() {
        let launched = SSHTerminalManager.claudeCommand(tmuxSession: "proj", folder: "/p")
        XCTAssertTrue(launched.contains("TMOUT=43200 tmux new"))
        XCTAssertTrue(launched.contains("tmux set-environment -t '\\''=proj'\\'' TMOUT 43200"))

        // Existing sessions receive the session environment update on attach,
        // so newly opened panes inherit it after an app upgrade.
        let reattached = SSHTerminalManager.attachCommand(tmuxSession: "proj")
        XCTAssertTrue(reattached.contains("tmux set-environment -t '\\''=proj'\\'' TMOUT 43200"))
    }

    // MARK: - persistentShellCommand

    func testPersistentShellCommandFallsBackWithoutTmux() {
        let cmd = SSHTerminalManager.persistentShellCommand(tmuxSession: "vnc-mac", launch: "")
        XCTAssertTrue(cmd.hasPrefix("zsh -lic '"))
        XCTAssertTrue(cmd.contains("if command -v tmux >/dev/null 2>&1; then"))
        // Empty launch: tmux runs its default shell (no trailing command word
        // before the `;`), the fallback execs a login shell.
        XCTAssertTrue(cmd.contains("tmux new -d -s vnc-mac; "))
        XCTAssertTrue(cmd.contains("else exec \"$SHELL\" -l; fi"))
        XCTAssertTrue(cmd.contains("exec tmux attach -d -t '\\''=vnc-mac'\\''"))
    }

    func testPersistentShellCommandCarriesLaunchCommandToBothPaths() {
        let cmd = SSHTerminalManager.persistentShellCommand(tmuxSession: "vnc-x", launch: "htop")
        XCTAssertTrue(cmd.contains("tmux new -d -s vnc-x htop"))
        XCTAssertTrue(cmd.contains("else htop; fi"))
    }

    func testPersistentShellCommandEnvReachesFallback() {
        let cmd = SSHTerminalManager.persistentShellCommand(
            tmuxSession: "vnc-x", launch: "",
            environment: [(name: "FOO", value: "bar")]
        )
        XCTAssertTrue(cmd.contains("FOO='\\''bar'\\'' tmux new"))
        XCTAssertTrue(cmd.contains("else FOO='\\''bar'\\'' exec \"$SHELL\" -l; fi"))
    }

    /// Regression: `tmux new -A -d` attaches when the session already exists.
    /// The man page maps new-session's `-D` — not `-d` — onto attach-session's
    /// detach-others flag, so with `-A` the `-d` here means nothing and tmux
    /// hands the client the existing session. The reaper line at the end of
    /// every launch hit this: a second launch landed the user in the watchdog's
    /// `[longwave-reaper] 0:bash` shell and the real `exec tmux attach` after it
    /// never ran. No generated command may use the idiom.
    func testNoGeneratedCommandUsesAttachOrCreate() {
        let commands = [
            SSHTerminalManager.claudeCommand(tmuxSession: "proj", folder: "/p"),
            SSHTerminalManager.attachCommand(tmuxSession: "proj"),
            SSHTerminalManager.persistentShellCommand(tmuxSession: "vnc-x", launch: "htop"),
            SSHTerminalManager.reaperWatchdogCommand(ttlSeconds: 60, intervalSeconds: 10),
        ]
        for cmd in commands {
            XCTAssertFalse(cmd.contains("new -A"), "attach-or-create attaches: \(cmd)")
        }
    }

    /// Every `-t` carries tmux's `=` exact-match prefix. Without it `-t` falls
    /// back to prefix matching, and `kill-session -t longwave` would take out
    /// `longwave-reaper` along with it.
    func testSessionTargetsAreExactMatches() {
        XCTAssertEqual(SSHTerminalManager.target("proj"), "'=proj'")
        // set-option's -t is a pane target and rejects `=` outright ("no such
        // session: =proj"), into a discarded stderr — so it is quoted but bare.
        XCTAssertEqual(SSHTerminalManager.optionTarget("proj"), "'proj'")
        let cmd = SSHTerminalManager.claudeCommand(tmuxSession: "longwave", folder: "/p")
        XCTAssertFalse(cmd.contains("-t longwave"), "unanchored target can prefix-match a sibling")
    }

    // MARK: - Per-agent session slugs

    func testAgentSessionKeysKeepClaudeBareAndSuffixOthers() {
        // Claude stays bare so tmux sessions / SSHSessionIDs created before
        // multi-agent support keep working; others are suffixed.
        XCTAssertEqual(SSHAgent.claude.sessionKey, "")
        XCTAssertEqual(SSHAgent.copilot.sessionKey, "copilot")
        XCTAssertEqual(SSHAgent.custom.sessionKey, "custom")
    }

    func testAgentKeyYieldsDistinctSlugsPerAgent() {
        let base = SSHTerminalManager.slug("my-project")
        // Mirror newClaudeSession's composition: empty key → bare slug, else suffixed.
        func slug(_ key: String) -> String {
            key.isEmpty ? base : SSHTerminalManager.slug("\(base)-\(key)")
        }
        let claude = slug(SSHAgent.claude.sessionKey)
        let copilot = slug(SSHAgent.copilot.sessionKey)
        let custom = slug(SSHAgent.custom.sessionKey)
        XCTAssertEqual(claude, "my-project")
        XCTAssertEqual(copilot, "my-project-copilot")
        XCTAssertEqual(custom, "my-project-custom")
        // Distinct slugs are what stop the manager re-attaching the wrong agent's session.
        XCTAssertEqual(Set([claude, copilot, custom]).count, 3)
    }

    // MARK: - Stale-session reap

    func testReapCommandOnlyKillsTaggedUnattachedIdleSessions() {
        let cmd = SSHTerminalManager.staleSessionReapCommand(ttlSeconds: 43200)
        // Host clock, not device clock, so skew can't mis-fire.
        XCTAssertTrue(cmd.contains("now=$(date +%s)"))
        // Lists attached-count, activity, the @longwave marker, and name.
        XCTAssertTrue(cmd.contains("'#{session_attached}|#{session_activity}|#{@longwave}|#{session_name}'"))
        // Guards: tagged (mark=1), zero attached clients (att=0), idle past TTL.
        XCTAssertTrue(cmd.contains("[ \"$mark\" = 1 ]"))
        XCTAssertTrue(cmd.contains("[ \"$att\" = 0 ]"))
        XCTAssertTrue(cmd.contains("[ $((now - act)) -gt 43200 ]"))
        XCTAssertTrue(cmd.contains("tmux kill-session -t \"$name\""))
    }

    /// The two timeouts used to be the same 12h value. They're now independent:
    /// `TMOUT` only ever closes an idle **shell** (an agent session's pane process
    /// is the agent itself, so it can't apply there), while the reap TTL has to
    /// stay under a Claude access token's ~8h life — a session that outlives its
    /// token can't be handed a new one, since the token was injected into the
    /// agent process's environment at launch.
    func testReapTTLIsDecoupledFromThePromptTimeout() {
        XCTAssertEqual(SSHTerminalManager.promptIdleTimeoutSeconds, 12 * 60 * 60)
        XCTAssertEqual(SSHTerminalManager.staleSessionTTLSeconds, 6 * 60 * 60)
        XCTAssertLessThan(SSHTerminalManager.staleSessionTTLSeconds, 8 * 60 * 60)
    }

    // MARK: - Modifier encoding

    func testQuickKeyUnmodifiedReturnsBaseBytes() {
        let up = TerminalQuickKey.catalog.first { $0.id == "up" }!
        XCTAssertEqual(TerminalKeyEncoder.encodeQuickKey(up, modifiers: []), [0x1B, 0x5B, 0x41])
    }

    func testAltArrowUsesCSIModifierForm() {
        let left = TerminalQuickKey.catalog.first { $0.id == "left" }!
        // ⌥← → ESC [ 1 ; 3 D  (param = 1 + alt(2))
        XCTAssertEqual(TerminalKeyEncoder.encodeQuickKey(left, modifiers: .alt),
                       [0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x44])
    }

    func testCtrlShiftArrowCombinesModifierParam() {
        let up = TerminalQuickKey.catalog.first { $0.id == "up" }!
        // ⌃⇧↑ → param = 1 + shift(1) + ctrl(4) = 6 → ESC [ 1 ; 6 A
        XCTAssertEqual(TerminalKeyEncoder.encodeQuickKey(up, modifiers: [.ctrl, .shift]),
                       [0x1B, 0x5B, 0x31, 0x3B, 0x36, 0x41])
    }

    func testShiftTabViaTabModifiable() {
        let tab = TerminalQuickKey.catalog.first { $0.id == "tab" }!
        XCTAssertEqual(TerminalKeyEncoder.encodeQuickKey(tab, modifiers: .shift), [0x1B, 0x5B, 0x5A])
    }

    func testPageUpModifierUsesTildeForm() {
        let pgUp = TerminalQuickKey.catalog.first { $0.id == "page-up" }!
        // ⌃PgUp → ESC [ 5 ; 5 ~
        XCTAssertEqual(TerminalKeyEncoder.encodeQuickKey(pgUp, modifiers: .ctrl),
                       [0x1B, 0x5B, 0x35, 0x3B, 0x35, 0x7E])
    }

    func testControlKeysIgnoreModifiers() {
        // ⌃C is already a control combo with no modifiable identity — latches
        // don't corrupt it.
        let ctrlC = TerminalQuickKey.catalog.first { $0.id == "ctrl-c" }!
        XCTAssertEqual(TerminalKeyEncoder.encodeQuickKey(ctrlC, modifiers: [.alt, .shift]), [0x03])
    }

    func testComposerCtrlProducesControlByte() {
        XCTAssertEqual(TerminalKeyEncoder.encodeComposerKey("b", modifiers: .ctrl), [0x02])
    }

    func testComposerAltPrefixesEscape() {
        // ⌥f → ESC f (readline word-forward)
        XCTAssertEqual(TerminalKeyEncoder.encodeComposerKey("f", modifiers: .alt), [0x1B, 0x66])
    }

    func testComposerCtrlAltCombines() {
        XCTAssertEqual(TerminalKeyEncoder.encodeComposerKey("b", modifiers: [.ctrl, .alt]), [0x1B, 0x02])
    }

    func testComposerShiftUppercasesLetter() {
        XCTAssertEqual(TerminalKeyEncoder.encodeComposerKey("a", modifiers: .shift), [0x41])
    }

    func testComposerMultiCharYieldsNil() {
        // Not a single keypress — caller sends it as ordinary text instead.
        XCTAssertNil(TerminalKeyEncoder.encodeComposerKey("ls", modifiers: .ctrl))
    }

    // MARK: - Retry backoff

    func testNextRetryDelayDoublesAndCaps() {
        XCTAssertEqual(SSHSession.nextRetryDelay(2), 4)
        XCTAssertEqual(SSHSession.nextRetryDelay(4), 8)
        XCTAssertEqual(SSHSession.nextRetryDelay(16), 30)  // capped
        XCTAssertEqual(SSHSession.nextRetryDelay(30), 30)
    }
}
