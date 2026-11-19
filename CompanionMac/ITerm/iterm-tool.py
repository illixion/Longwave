#!/usr/bin/env python3
"""iterm-tool: inspect, watch and manage iTerm2 windows/tabs/sessions via the Python API.

  iterm-tool list [--json]                  windows/tabs/sessions: name, job, cwd
                                            (--json: one object per session, with
                                            session_id, tab_id, title, size, flags)
  iterm-tool screen [TARGET...] [-n N] [--history]
                                            last N non-empty lines per session
                                            (--history includes scrollback)
  iterm-tool view TARGET [--read-only] [--no-status]
                                            mirror one session live in this terminal,
                                            in colour, following its cursor; what you
                                            type goes to that session (unless
                                            --read-only). Ctrl-] detaches. Works over
                                            SSH: the mirror redraws on every change and
                                            on resize
  iterm-tool focus TARGET                   bring a window (and its tab) forward
  iterm-tool new-tab [TARGET] [--profile P] [--command CMD] [--background]
                                            open a tab in TARGET's window (default: the
                                            frontmost window, or a new one); prints the
                                            new session as JSON
  iterm-tool new-window [--profile P] [--command CMD]
                                            open a window; prints the new session as JSON
  iterm-tool close TARGET [--tab] [--force] close one session (--tab: its whole tab);
                                            --force skips iTerm2's "running job" prompt
  iterm-tool rename TARGET NAME             set the tab title of TARGET's tab
                                            (empty NAME restores the automatic title)
  iterm-tool setup                          create the private venv and exit (no iTerm2
                                            connection; used by installers)
  iterm-tool tile [--screen N] [--gap PX] [--margin PX] [--order x|number]
                  [--skip TARGET...] [--include-hotkey] [--dry-run]
                                            lay all windows out as equal-width columns
                                            filling the screen's usable area
  iterm-tool send TARGET TEXT [--submit] [--allow-shell]
                                            type TEXT into one session (TEXT `-` = stdin)
  iterm-tool mcp-reload [ARGS...] [--dry-run] [--skip-busy] [--force] [--include-self]
                                            type `/mcp reconnect ARGS` + Enter into every
                                            Claude Code session (except the caller's own,
                                            unless --include-self) whose prompt is empty;
                                            sessions with a draft or an unrecognised screen
                                            are skipped. Into the caller's own session the
                                            text is queued by Claude Code until its turn ends,
                                            so the reconnect runs once the agent stops

`tile` uses the screen holding most of the windows (override with --screen,
numbered as in the dry-run output), its visible area (menu bar and Dock
excluded), and keeps the current left-to-right order (ties: window number).
Minimized windows are always left alone, so they stay in the Dock.
Hotkey (drop-down) windows are left alone unless --include-hotkey. Window sizes may snap to the terminal's character grid, so widths can differ by
a few points; `--dry-run` prints the plan without moving anything.

TARGET is one of: `W5` / `5` (window number as printed by `list`), `W9T2`
(window + tab), a window id (`pty-...`), a session id (the UUID, or
`w0t0p0:UUID` as in $ITERM_SESSION_ID), or a case-insensitive substring of the
tab name or cwd (must match exactly one session for `focus`, `view`, `close`,
`rename`).

Read-only except `focus` (window focus), `send` and `view` (type into a
session), and `new-tab`/`new-window`/`close`/`rename` (manage tabs). `view` and
`close` refuse the session they are run from.
`send` guardrails: exactly one target must match; it refuses the session it is
being run from ($ITERM_SESSION_ID); it only types the text unless --submit adds
Enter; and it refuses plain shells (zsh/bash/fish/...) unless --allow-shell,
because typing into a shell runs commands. Typing into a session that already
has a draft in its prompt appends to that draft, so `screen` it first or pass
--only-if-empty (Claude Code prompts only; refuses on a draft or unknown screen).

Requires iTerm2 > Settings > General > Magic > "Enable Python API". The first run creates a private venv with the `iterm2` package in
~/.agents/state/iterm-venv, or $ITERM_TOOL_VENV when set (no system-wide install).
Run from outside iTerm2 (over SSH, from another app), the iterm2 package asks
iTerm2 for an API cookie through AppleScript, so macOS asks once whether the
calling process may control iTerm2.

Longwave Companion bundles this file and installs it as
~/Library/Application Support/Longwave/iterm/iterm-tool, which Longwave's
iTerm2 tab runs over SSH. Keep the two copies identical.
"""
import argparse
import asyncio
import codecs
import json
import os
import re
import signal
import subprocess
import sys
import unicodedata

VERSION = 2
VENV = os.environ.get("ITERM_TOOL_VENV") or os.path.expanduser("~/.agents/state/iterm-venv")
VENV_PY = os.path.join(VENV, "bin", "python")


def bootstrap():
    try:
        import iterm2  # noqa: F401
        return
    except ImportError:
        pass
    if os.environ.get("ITERM_TOOL_REEXEC"):
        sys.exit("iterm-tool: iterm2 module still missing after bootstrap")
    if not os.path.exists(VENV_PY) or not os.path.exists(os.path.join(VENV, ".iterm2-installed")):
        print("iterm-tool: creating venv with iterm2 package...", file=sys.stderr)
        os.makedirs(os.path.dirname(VENV), exist_ok=True)
        subprocess.check_call([sys.executable, "-m", "venv", VENV])
        # stdout to stderr: callers parse this tool's stdout as JSON
        subprocess.check_call([os.path.join(VENV, "bin", "pip"), "install", "-q", "iterm2"],
                              stdout=sys.stderr)
        open(os.path.join(VENV, ".iterm2-installed"), "w").close()
    os.environ["ITERM_TOOL_REEXEC"] = "1"
    os.execv(VENV_PY, [VENV_PY, os.path.abspath(__file__)] + sys.argv[1:])


bootstrap()
import iterm2  # noqa: E402


async def collect(app):
    """Flat list of dicts, one per session, numbered like `list` prints them."""
    rows = []
    front = app.current_terminal_window
    for wi, w in enumerate(app.terminal_windows, 1):
        for ti, t in enumerate(w.tabs, 1):
            for s in t.sessions:
                size = s.grid_size
                rows.append({
                    "w": wi, "t": ti, "window": w, "tab": t, "session": s,
                    "window_id": w.window_id,
                    "tab_id": t.tab_id,
                    "session_id": s.session_id,
                    "name": await s.async_get_variable("name"),
                    "title": await t.async_get_variable("title"),
                    "job": await s.async_get_variable("jobName"),
                    "cwd": await s.async_get_variable("path"),
                    "cols": size.width, "rows": size.height,
                    "current_tab": w.current_tab is not None and w.current_tab.tab_id == t.tab_id,
                    "current_session": t.current_session is not None and t.current_session.session_id == s.session_id,
                    "front_window": front is not None and front.window_id == w.window_id,
                })
    return rows


JSON_KEYS = ("w", "t", "window_id", "tab_id", "session_id", "name", "title", "job", "cwd",
             "cols", "rows", "current_tab", "current_session", "front_window")


def as_json(r):
    return {k: r[k] for k in JSON_KEYS}


def select(rows, targets):
    if not targets:
        return rows
    out = []
    for tg in targets:
        m = re.fullmatch(r"[Ww]?(\d+)(?:[Tt](\d+))?", tg)
        if m:
            w, t = int(m.group(1)), m.group(2)
            hit = [r for r in rows if r["w"] == w and (t is None or r["t"] == int(t))]
        elif tg.startswith("pty-"):
            hit = [r for r in rows if r["window_id"] == tg]
        elif re.fullmatch(r"(?:w\d+t\d+p\d+:)?[0-9A-Fa-f-]{36}", tg):
            sid = tg.split(":")[-1].upper()
            hit = [r for r in rows if r["session_id"].upper() == sid]
        else:
            low = tg.lower()
            hit = [r for r in rows if low in (r["name"] or "").lower() or low in (r["cwd"] or "").lower()]
        out += [r for r in hit if r not in out]
    return out


def label(r):
    return f"W{r['w']}T{r['t']} {r['name']!r} job={r['job']} cwd={r['cwd']}"


async def get_lines(session, n, history):
    if history:
        info = await session.async_get_line_info()
        total = info.overflow + info.scrollback_buffer_height + info.mutable_area_height
        first = max(0, total - max(n * 4, 200))
        lines = await session.async_get_contents(first, total - first)
        texts = [l.string.rstrip() for l in lines]
    else:
        c = await session.async_get_screen_contents()
        texts = [c.line(i).string.rstrip() for i in range(c.number_of_lines)]
    return [t for t in texts if t.strip()][-n:]


def screens():
    """[(frame, visible)] as (x, y, w, h) in global bottom-left coordinates."""
    js = ('ObjC.import("AppKit");var s=$.NSScreen.screens,o=[];'
          'for(var i=0;i<s.count;i++){var c=s.objectAtIndex(i),f=c.frame,v=c.visibleFrame;'
          'o.push({name:ObjC.unwrap(c.localizedName),'
          'f:[f.origin.x,f.origin.y,f.size.width,f.size.height],'
          'v:[v.origin.x,v.origin.y,v.size.width,v.size.height]})}JSON.stringify(o)')
    out = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", js],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def minimized_sessions():
    """UUIDs of the current session of every minimized window.

    The Python API doesn't expose minimized state, but iTerm2's AppleScript does;
    the current session's unique id is the same UUID as the API's session_id suffix.
    """
    script = ('tell application "iTerm2"\nset o to ""\nrepeat with w in windows\n'
              'if miniaturized of w then set o to o & (unique id of current session of w) & linefeed\n'
              'end repeat\nreturn o\nend tell')
    r = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True)
    if r.returncode:
        print("iterm-tool: could not read minimized state, tiling minimized windows too: "
              + r.stderr.strip(), file=sys.stderr)
        return set()
    return set(r.stdout.split())


async def tile(app, rows, args):
    scr = screens()
    mini = minimized_sessions()
    wins = []
    for w in app.terminal_windows:
        if not args.include_hotkey and await w.async_get_variable("isHotkeyWindow"):
            print(f"  skipping hotkey window {w.window_id}")
            continue
        if w.current_tab.current_session.session_id.split(":")[-1] in mini:
            print(f"  skipping minimized window {w.window_id}")
            continue
        f = await w.async_get_frame()
        # Copy the numbers out now: iterm2's Frame objects share one mutable
        # default Point, so a later read overwrites every earlier frame's x/y.
        wins.append((w, (f.origin.x, f.origin.y, f.size.width, f.size.height)))
    skip = {r["window_id"] for r in select(rows, args.skip)} if args.skip else set()
    nums = {r["window_id"]: r["w"] for r in rows}
    wins = [(w, f) for w, f in wins if w.window_id not in skip]
    if not wins:
        sys.exit("iterm-tool: no windows to tile")
    if args.screen is None:
        def holds(i):
            x, y, ww, hh = scr[i]["f"]
            return sum(1 for _, (fx, fy, fw, fh) in wins
                       if x <= fx + fw / 2 < x + ww and y <= fy + fh / 2 < y + hh)
        idx = max(range(len(scr)), key=holds)
    else:
        idx = args.screen
    x0, y0, W, H = scr[idx]["v"]
    m, g, n = args.margin, args.gap, len(wins)
    if args.order == "x":
        wins.sort(key=lambda t: (t[1][0], nums[t[0].window_id]))
    else:
        wins.sort(key=lambda t: nums[t[0].window_id])
    usable = W - 2 * m - g * (n - 1)
    base, extra = divmod(int(usable), n)
    print(f"screen {idx} {scr[idx]['name']!r}: usable {W:.0f}x{H:.0f} -> {n} columns of ~{base}pt, gap {g}, margin {m}")
    x = x0 + m
    for i, (w, _) in enumerate(wins):
        cw = base + (1 if i < extra else 0)
        frame = iterm2.util.Frame(iterm2.util.Point(x, y0 + m), iterm2.util.Size(cw, H - 2 * m))
        print(f"  W{nums[w.window_id]}: x={x:.0f} w={cw}")
        if not args.dry_run:
            await w.async_set_frame(frame)
        x += cw + g
    if not args.dry_run:
        for w, _ in wins:
            f = await w.async_get_frame()
            print(f"  result W{nums[w.window_id]}: x={f.origin.x:.0f} y={f.origin.y:.0f} w={f.size.width:.0f} h={f.size.height:.0f}")


SHELLS = {"zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "login", "-zsh", "-bash"}


def is_claude(r):
    """Claude Code sessions: tab title ends in "(claude)" or the job is its version number."""
    return (r["name"] or "").endswith("(claude)") or bool(re.fullmatch(r"\d+\.\d+\.\d+", r["job"] or ""))


def is_rule(line):
    t = line.strip()
    return len(t) >= 20 and set(t) == {"\u2500"}


BUSY_RE = re.compile(r"^\s*\S\s+\S+\u2026\s*\(")  # "✻ Pouncing… (8s · ..."


async def prompt_state(session):
    """Inspect a Claude Code screen: (state, busy).

    state: "empty" | "draft" | "unknown" (no recognisable prompt box, e.g. a dialog or menu).
    busy: a spinner line ("✻ Verb… (8s · ...)") sits above the prompt box.
    """
    c = await session.async_get_screen_contents()
    # iTerm reports blank cells as NUL; fold them to spaces so regexes see normal text
    lines = [c.line(i).string.replace("\x00", " ").rstrip() for i in range(c.number_of_lines)]
    rules = [i for i, l in enumerate(lines) if is_rule(l)]
    if len(rules) < 2:
        return "unknown", False
    top, bot = rules[-2], rules[-1]
    box = lines[top + 1:bot]
    if not box or not box[0].lstrip().startswith("\u276f"):
        return "unknown", False
    box[0] = box[0].lstrip()[1:]
    state = "draft" if any(l.strip() for l in box) else "empty"
    above = [l for l in lines[:top] if l.strip()][-4:]
    return state, any(BUSY_RE.match(l) for l in above)


def own_session_id():
    return os.environ.get("ITERM_SESSION_ID", "").split(":")[-1]


def one(rows, target):
    hit = select(rows, [target])
    if len(hit) != 1:
        sys.exit(f"iterm-tool: {len(hit)} sessions match {target!r}"
                 + "".join("\n  " + label(r) for r in hit))
    return hit[0]


# MARK: live view

def _sgr_color(color, base, bright, ext):
    """SGR parameters for one CellStyle.Color (None/alternate = terminal default)."""
    if color is None:
        return []
    try:
        if color.is_rgb:
            c = color.rgb
            return [str(ext), "2", str(c.red), str(c.green), str(c.blue)]
        if color.is_standard:
            n = color.standard
            if n < 8:
                return [str(base + n)]
            if n < 16:
                return [str(bright + n - 8)]
            return [str(ext), "5", str(n)]
    except Exception:  # an unset oneof: treat as default
        pass
    return []


def sgr(style):
    if style is None:
        return "\x1b[0m"
    p = ["0"]
    for on, code in ((style.bold, "1"), (style.faint, "2"), (style.italic, "3"),
                     (style.underline, "4"), (style.blink, "5"), (style.inverse, "7"),
                     (style.invisible, "8"), (style.strikethrough, "9")):
        if on:
            p.append(code)
    p += _sgr_color(style.fg_color, 30, 90, 38)
    p += _sgr_color(style.bg_color, 40, 100, 48)
    return "\x1b[" + ";".join(p) + "m"


def cell_count(line):
    offsets = getattr(line, "_LineContents__offset_of_cell", None)
    return len(offsets) - 1 if offsets else len(line.string)


class Renderer:
    """Turns iTerm2 screen contents into ANSI for a viewer of a given size.

    Shows the source's top-left, scrolled just enough to keep the cursor in
    view when the viewer is smaller, and redraws only rows that changed since
    the last frame (a full redraw after `invalidate`)."""

    def __init__(self, status=True):
        self.status = status
        self.prev = {}
        self.full = True

    def invalidate(self):
        self.full = True

    @staticmethod
    def render_line(line, left, width):
        out, cur, x, n = [], None, 0, cell_count(line)
        col = left
        while x < width and col < n:
            text = line.string_at(col)
            style = sgr(line.style_at(col))
            if style != cur:
                out.append(style)
                cur = style
            if text == "":
                # the right half of a wide character the previous cell drew
                col += 1
                x += 1
                continue
            text = text.replace("\x00", " ")
            if ord(text[0]) < 0x20 or text[0] == "\x7f":  # never pass control bytes through
                text = " "
            out.append(text)
            wide = unicodedata.east_asian_width(text[0]) in ("W", "F") if text else False
            if wide and x + 1 >= width:
                out[-1] = " "  # a wide char that would straddle the edge
            col += 1
            x += 1
        out.append("\x1b[0m\x1b[K")
        return "".join(out)

    def frame(self, contents, line_info, cols, rows, title=""):
        height = max(1, rows - (1 if self.status else 0))
        src_rows = contents.number_of_lines
        cursor = contents.cursor_coord
        cy = cursor.y - line_info.overflow - line_info.scrollback_buffer_height
        if not 0 <= cy < max(src_rows, 1):
            cy = min(max(cursor.y, 0), max(src_rows - 1, 0))
        cx = cursor.x
        top = max(0, min(cy - height + 1, src_rows - height)) if src_rows > height else 0
        left = max(0, cx - cols + 1)
        out = ["\x1b[?25l"]
        if self.full:
            out.append("\x1b[0m\x1b[2J")
            self.prev = {}
        for y in range(height):
            src = top + y
            text = self.render_line(contents.line(src), left, cols) if src < src_rows else "\x1b[0m\x1b[K"
            if self.prev.get(y) != text:
                out.append(f"\x1b[{y + 1};1H{text}")
                self.prev[y] = text
        if self.status:
            size = f"{src_cols(contents)}x{src_rows}"
            bar = f" iTerm2 · {title} · {size} · Ctrl-] detach "[:cols].ljust(cols)
            if self.prev.get("status") != bar:
                out.append(f"\x1b[{height + 1};1H\x1b[0;7m{bar}\x1b[0m")
                self.prev["status"] = bar
        self.full = False
        vy, vx = cy - top, cx - left
        if 0 <= vy < height and 0 <= vx < cols:
            out.append(f"\x1b[{vy + 1};{vx + 1}H\x1b[?25h")
        return "".join(out)


def src_cols(contents):
    return max((cell_count(contents.line(i)) for i in range(contents.number_of_lines)), default=0)


def terminal_size():
    try:
        sz = os.get_terminal_size(sys.stdout.fileno())
        return max(sz.columns, 1), max(sz.lines, 2)
    except OSError:
        return 80, 24


async def view(connection, r, args):
    import termios
    import tty
    session = r["session"]
    sid = session.session_id
    fd_in, fd_out = sys.stdin.fileno(), sys.stdout.fileno()
    is_tty = os.isatty(fd_in)
    saved = termios.tcgetattr(fd_in) if is_tty else None
    loop = asyncio.get_running_loop()
    renderer = Renderer(status=not args.no_status)
    dirty = asyncio.Event()
    done = asyncio.Event()
    reason = [None]
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    pending = []

    def write(s):
        data = s.encode("utf-8", "replace")
        while data:
            try:
                n = os.write(fd_out, data)
            except BlockingIOError:
                continue
            except OSError:  # the viewer went away (SSH channel closed)
                done.set()
                return
            data = data[n:]

    def on_input():
        try:
            data = os.read(fd_in, 4096)
        except OSError:
            data = b""
        if not data:
            done.set()
            return
        if b"\x1d" in data:  # Ctrl-]
            data = data.split(b"\x1d", 1)[0]
            done.set()
        if data and not args.read_only:
            text = decoder.decode(data)
            if text:
                pending.append(text)
                loop.create_task(flush_input())

    async def flush_input():
        while pending:
            text = pending.pop(0)
            try:
                await session.async_send_text(text)
            except Exception as e:  # noqa: BLE001
                reason[0] = f"could not type into the session: {e}"
                done.set()
                return

    def on_resize():
        renderer.invalidate()
        dirty.set()

    async def watch_updates():
        try:
            async with session.get_screen_streamer(want_contents=False) as streamer:
                while not done.is_set():
                    await streamer.async_get()
                    dirty.set()
        except Exception as e:  # noqa: BLE001
            reason[0] = f"screen updates stopped: {e}"
            done.set()

    async def watch_termination():
        async with iterm2.SessionTerminationMonitor(connection) as mon:
            while True:
                ended = await mon.async_get()
                if ended == sid:
                    reason[0] = "the session ended"
                    done.set()
                    return

    async def render_loop():
        title = r["title"] or r["name"] or sid
        while not done.is_set():
            try:
                await asyncio.wait_for(dirty.wait(), timeout=2)
            except asyncio.TimeoutError:
                pass
            dirty.clear()
            try:
                contents = await session.async_get_screen_contents()
                info = await session.async_get_line_info()
            except Exception as e:  # noqa: BLE001
                reason[0] = f"the session is gone ({e})"
                done.set()
                return
            cols, rows = terminal_size()
            write(renderer.frame(contents, info, cols, rows, title))
            await asyncio.sleep(1 / 30)  # coalesce bursts; ~30 redraws a second at most

    if is_tty:
        tty.setraw(fd_in)
    write("\x1b[?1049h\x1b[H\x1b[2J")
    loop.add_reader(fd_in, on_input)
    loop.add_signal_handler(signal.SIGWINCH, on_resize)
    loop.add_signal_handler(signal.SIGHUP, done.set)
    loop.add_signal_handler(signal.SIGTERM, done.set)
    tasks = [loop.create_task(c()) for c in (watch_updates, watch_termination, render_loop)]
    dirty.set()
    try:
        await done.wait()
    finally:
        for t in tasks:
            t.cancel()
        loop.remove_reader(fd_in)
        write("\x1b[0m\x1b[?25h\x1b[?1049l")
        if saved is not None:
            termios.tcsetattr(fd_in, termios.TCSADRAIN, saved)
    print(f"iterm-tool: detached from {label(r)}" + (f": {reason[0]}" if reason[0] else ""))


async def session_row(app, session):
    """The `list --json` row for a session just created."""
    await asyncio.sleep(0.2)  # let the new session publish its variables
    await app.async_refresh()
    for r in await collect(app):
        if r["session_id"] == session.session_id:
            return as_json(r)
    return {"session_id": session.session_id}


def make_main(args):
    async def main(connection):
        app = await iterm2.async_get_app(connection)
        rows = await collect(app)
        if args.cmd == "list":
            if args.json:
                print(json.dumps([as_json(r) for r in rows], indent=None if args.compact else 2))
                return
            last = None
            for r in rows:
                if r["w"] != last:
                    print(f"Window {r['w']} ({r['window_id']})")
                    last = r["w"]
                titled = f" title={r['title']!r}" if r["title"] and r["title"] != r["name"] else ""
                print(f"  tab {r['t']}: {r['name']!r}{titled} job={r['job']} cwd={r['cwd']}")
        elif args.cmd == "screen":
            for r in select(rows, args.targets):
                print(f"\n===== {label(r)}")
                for l in await get_lines(r["session"], args.n, args.history):
                    print("  | " + l[:args.width])
        elif args.cmd == "focus":
            hit = select(rows, [args.target])
            if len(hit) != 1:
                sys.exit(f"iterm-tool: {len(hit)} sessions match {args.target!r}"
                         + "".join("\n  " + label(r) for r in hit))
            r = hit[0]
            await app.async_activate()
            await r["window"].async_activate()
            await r["tab"].async_select()
            print("focused " + label(r))
        elif args.cmd == "tile":
            await tile(app, rows, args)
        elif args.cmd == "view":
            r = one(rows, args.target)
            if own_session_id() and r["session"].session_id == own_session_id():
                sys.exit("iterm-tool: refusing to view the calling session (it would mirror itself)")
            await view(connection, r, args)
        elif args.cmd in ("new-tab", "new-window"):
            window = None
            if args.cmd == "new-tab":
                if args.target:
                    window = one(rows, args.target)["window"]
                else:
                    window = app.current_terminal_window or (app.terminal_windows[0] if app.terminal_windows else None)
            if window is None:
                window = await iterm2.Window.async_create(connection, profile=args.profile, command=args.command)
                if window is None:
                    sys.exit("iterm-tool: iTerm2 did not create a window")
                session = window.current_tab.current_session
            else:
                tab = await window.async_create_tab(profile=args.profile, command=args.command,
                                                    select=not getattr(args, "background", False))
                if tab is None:
                    sys.exit("iterm-tool: iTerm2 did not create a tab")
                session = tab.current_session
            print(json.dumps(await session_row(app, session)))
        elif args.cmd == "close":
            r = one(rows, args.target)
            if own_session_id() and r["session"].session_id == own_session_id():
                sys.exit("iterm-tool: refusing to close the calling session")
            if args.tab:
                await r["tab"].async_close(force=args.force)
            else:
                await r["session"].async_close(force=args.force)
            print("closed " + ("tab of " if args.tab else "") + label(r))
        elif args.cmd == "rename":
            r = one(rows, args.target)
            # An empty title hands the tab back to its automatic (session) title.
            await r["tab"].async_set_title(args.name)
            print(f"renamed tab of {label(r)} to {args.name!r}")
        elif args.cmd == "mcp-reload":
            text = " ".join(["/mcp", "reconnect"] + args.args)
            me = own_session_id()

            async def reload_one(r):
                if me and r["session"].session_id == me and not args.include_self:
                    return "skipped (calling session; --include-self reloads it too) " + label(r)
                state, busy = await prompt_state(r["session"])
                if not args.force:
                    if state != "empty":
                        return f"skipped ({state} prompt) " + label(r)
                    if busy and args.skip_busy:
                        return "skipped (busy) " + label(r)
                if args.dry_run:
                    return f"would send {text!r} to " + label(r) + (" [busy]" if busy else "")
                await r["session"].async_send_text(text)
                await asyncio.sleep(0.3)  # let the TUI take the text before Enter
                await r["session"].async_send_text("\r")
                return f"sent {text!r} + Enter to " + label(r)

            # all sessions at once; results print in window order
            for line in await asyncio.gather(*(reload_one(r) for r in rows if is_claude(r))):
                print(line)
        elif args.cmd == "send":
            hit = select(rows, [args.target])
            if len(hit) != 1:
                sys.exit(f"iterm-tool: {len(hit)} sessions match {args.target!r}"
                         + "".join("\n  " + label(r) for r in hit))
            r = hit[0]
            if own_session_id() and r["session"].session_id == own_session_id():
                sys.exit("iterm-tool: refusing to send to the calling session")
            if (r["job"] or "").lstrip("-") in SHELLS and not args.allow_shell:
                sys.exit(f"iterm-tool: {label(r)} is a plain shell; typing runs commands. "
                         "Pass --allow-shell if that is intended.")
            if args.only_if_empty:
                state, _ = await prompt_state(r["session"])
                if state != "empty":
                    sys.exit(f"iterm-tool: {label(r)} prompt is {state}; not sending (--only-if-empty)")
            text = sys.stdin.read() if args.text == "-" else args.text
            await r["session"].async_send_text(text)
            if args.submit:
                await asyncio.sleep(0.3)  # let the TUI take the text before Enter
                await r["session"].async_send_text("\r")
            print(f"sent {len(text)} chars{' + Enter' if args.submit else ''} to " + label(r))
    return main


def parse():
    p = argparse.ArgumentParser(prog="iterm-tool", description="iTerm2 Python API helper")
    sub = p.add_subparsers(dest="cmd", required=True)
    l = sub.add_parser("list")
    l.add_argument("--json", action="store_true")
    l.add_argument("--compact", action="store_true", help="with --json: one line")
    v = sub.add_parser("view", help="mirror one session live; typing goes to it")
    v.add_argument("target")
    v.add_argument("--read-only", action="store_true", help="watch only, never type into the session")
    v.add_argument("--no-status", action="store_true", help="no status line at the bottom")
    for name in ("new-tab", "new-window"):
        n = sub.add_parser(name)
        if name == "new-tab":
            n.add_argument("target", nargs="?", help="a session in the window to add the tab to")
            n.add_argument("--background", action="store_true", help="don't select it or raise the window")
        n.add_argument("--profile", help="profile name (default profile when omitted)")
        n.add_argument("--command", help="command to run instead of the profile's")
    c = sub.add_parser("close")
    c.add_argument("target")
    c.add_argument("--tab", action="store_true", help="close the whole tab")
    c.add_argument("--force", action="store_true", help="don't let iTerm2 ask about running jobs")
    rn = sub.add_parser("rename")
    rn.add_argument("target")
    rn.add_argument("name")
    sub.add_parser("setup", help="create the venv and exit")
    sub.add_parser("version", help="print the tool's protocol version")
    s = sub.add_parser("screen")
    s.add_argument("targets", nargs="*")
    s.add_argument("-n", type=int, default=14, help="lines per session (default 14)")
    s.add_argument("--width", type=int, default=160)
    s.add_argument("--history", action="store_true", help="include scrollback")
    f = sub.add_parser("focus")
    f.add_argument("target")
    t = sub.add_parser("tile")
    t.add_argument("--screen", type=int, help="screen index (default: the one holding most windows)")
    t.add_argument("--gap", type=int, default=0, help="points between columns")
    t.add_argument("--margin", type=int, default=0, help="points around the whole layout")
    t.add_argument("--order", choices=["x", "number"], default="x")
    t.add_argument("--skip", nargs="*", default=[], metavar="TARGET", help="windows to leave alone")
    t.add_argument("--include-hotkey", action="store_true",
                   help="also tile hotkey (drop-down) windows; skipped by default")
    t.add_argument("--dry-run", action="store_true")
    d = sub.add_parser("send")
    d.add_argument("target")
    d.add_argument("text", help="text to type, or - for stdin")
    d.add_argument("--submit", action="store_true", help="press Enter after the text")
    d.add_argument("--only-if-empty", action="store_true",
                   help="refuse unless the Claude Code prompt box is empty")
    d.add_argument("--allow-shell", action="store_true", help="allow typing into a plain shell")
    m = sub.add_parser("mcp-reload", help="send `/mcp reconnect ARGS` to every Claude Code session")
    m.add_argument("args", nargs="*", help="server name(s) passed to /mcp reconnect")
    m.add_argument("--dry-run", action="store_true")
    m.add_argument("--skip-busy", action="store_true", help="also skip sessions mid-turn")
    m.add_argument("--force", action="store_true", help="send even if the prompt has a draft or is unrecognised")
    m.add_argument("--include-self", action="store_true",
                   help="also reload the session this runs from (its text queues until the turn ends)")
    return p.parse_args()


if __name__ == "__main__":
    parsed = parse()
    if parsed.cmd in ("setup", "version"):
        # bootstrap() already ran at import; nothing here needs iTerm2.
        print(f"iterm-tool {VERSION}" + (f" ready ({VENV})" if parsed.cmd == "setup" else ""))
        sys.exit(0)
    iterm2.run_until_complete(make_main(parsed))
