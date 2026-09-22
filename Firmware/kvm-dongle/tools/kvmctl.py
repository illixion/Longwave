#!/usr/bin/env python3
"""
kvmctl — command-line client for the Longwave KVM dongle.

Speaks the binary framing described in PROTOCOL.md over the dongle's USB
serial link. Useful on its own for bring-up, and as the reference the Swift
implementation in the macOS app is written against.

    ./tools/kvmctl.py status
    ./tools/kvmctl.py ping
    ./tools/kvmctl.py type "hello world"
    ./tools/kvmctl.py key enter
    ./tools/kvmctl.py move 100 0
    ./tools/kvmctl.py click
    ./tools/kvmctl.py square
    ./tools/kvmctl.py forget
"""

from __future__ import annotations

import argparse
import glob
import sys
import time

try:
    import serial  # type: ignore
except ImportError:  # pragma: no cover
    sys.exit(
        "pyserial is missing. Either:\n"
        "  python3 -m venv .venv && ./.venv/bin/pip install pyserial\n"
        "  ./.venv/bin/python tools/kvmctl.py status\n"
        "or:\n"
        "  uv run --with pyserial tools/kvmctl.py status"
    )

DEFAULT_BAUD = 460800

SOF = 0xA5
MAX_PAYLOAD = 64

CMD_PING = 0x01
CMD_GET_STATUS = 0x02
CMD_KEY_REPORT = 0x03
CMD_MOUSE_MOVE = 0x04
CMD_MOUSE_BUTTONS = 0x05
CMD_CONSUMER = 0x06
CMD_RELEASE_ALL = 0x07
CMD_FORGET_BONDS = 0x08

RSP_ACK = 0x81
RSP_NACK = 0x82
RSP_STATUS = 0x83
RSP_EVENT = 0x85

ERRORS = {
    0x01: "bad checksum",
    0x02: "wrong payload length",
    0x03: "unknown command",
    0x04: "not connected to a host",
    0x05: "host has not subscribed to that report",
    0x06: "BLE transmit failed",
    0x07: "bad payload",
}

STATES = {0: "idle", 1: "advertising", 2: "connected", 3: "ready"}

EVENTS = {
    0x01: "boot",
    0x02: "advertising",
    0x03: "connected",
    0x04: "encrypted",
    0x05: "disconnected",
    0x06: "led-state",
    0x07: "subscribed",
}

# HID usage IDs (Usage Page 0x07). Only what the CLI needs.
KEYS = {
    "a": 0x04, "b": 0x05, "c": 0x06, "d": 0x07, "e": 0x08, "f": 0x09,
    "g": 0x0A, "h": 0x0B, "i": 0x0C, "j": 0x0D, "k": 0x0E, "l": 0x0F,
    "m": 0x10, "n": 0x11, "o": 0x12, "p": 0x13, "q": 0x14, "r": 0x15,
    "s": 0x16, "t": 0x17, "u": 0x18, "v": 0x19, "w": 0x1A, "x": 0x1B,
    "y": 0x1C, "z": 0x1D,
    "1": 0x1E, "2": 0x1F, "3": 0x20, "4": 0x21, "5": 0x22,
    "6": 0x23, "7": 0x24, "8": 0x25, "9": 0x26, "0": 0x27,
    "enter": 0x28, "return": 0x28, "esc": 0x29, "escape": 0x29,
    "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
    "minus": 0x2D, "equal": 0x2E, "leftbracket": 0x2F, "rightbracket": 0x30,
    "backslash": 0x31, "semicolon": 0x33, "quote": 0x34, "grave": 0x35,
    "comma": 0x36, "period": 0x37, "slash": 0x38, "capslock": 0x39,
    "f1": 0x3A, "f2": 0x3B, "f3": 0x3C, "f4": 0x3D, "f5": 0x3E, "f6": 0x3F,
    "f7": 0x40, "f8": 0x41, "f9": 0x42, "f10": 0x43, "f11": 0x44, "f12": 0x45,
    "home": 0x4A, "pageup": 0x4B, "delete": 0x4C, "end": 0x4D,
    "pagedown": 0x4E, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
}

MODIFIERS = {
    "ctrl": 0x01, "control": 0x01,
    "shift": 0x02,
    "alt": 0x04, "option": 0x04,
    "cmd": 0x08, "command": 0x08, "gui": 0x08, "meta": 0x08,
    "rctrl": 0x10, "rshift": 0x20, "ralt": 0x40, "rcmd": 0x80,
}

# character -> (modifier, usage) for US layout.
_SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    "{": "leftbracket", "}": "rightbracket", "|": "backslash",
    ":": "semicolon", '"': "quote", "~": "grave", "<": "comma",
    ">": "period", "?": "slash",
}
_PLAIN = {
    "-": "minus", "=": "equal", "[": "leftbracket", "]": "rightbracket",
    "\\": "backslash", ";": "semicolon", "'": "quote", "`": "grave",
    ",": "comma", ".": "period", "/": "slash", " ": "space",
    "\n": "enter", "\t": "tab",
}


def crc8(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def encode(cmd: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("payload too long")
    body = bytes([cmd, len(payload)]) + payload
    return bytes([SOF]) + body + bytes([crc8(body)])


class Nack(Exception):
    def __init__(self, cmd: int, err: int):
        self.cmd = cmd
        self.err = err
        super().__init__(
            f"dongle refused command 0x{cmd:02x}: "
            f"{ERRORS.get(err, f'error 0x{err:02x}')}"
        )


class Dongle:
    """Framing client. Unsolicited EVENT frames are queued, not confused for
    the answer to a command."""

    def __init__(self, port: str, baud: int = DEFAULT_BAUD, verbose: bool = False):
        self.ser = serial.Serial(port, baud, timeout=0.05)
        self.verbose = verbose
        self.events: list[tuple[int, bytes]] = []
        self._buf = bytearray()
        self._text = bytearray()

    def close(self) -> None:
        self.ser.close()

    # -- framing ---------------------------------------------------------

    def _pump(self) -> list[tuple[int, bytes]]:
        """Read whatever is available and return complete frames. Bytes that
        are not part of a frame are firmware log output; they are printed in
        verbose mode and otherwise dropped."""
        # read(n) waits for n bytes OR the timeout, so read(4096) always burns
        # the whole timeout. Block on one byte, then take what is queued.
        waiting = self.ser.in_waiting
        chunk = self.ser.read(waiting if waiting else 1)
        if chunk:
            extra = self.ser.in_waiting
            if extra:
                chunk += self.ser.read(extra)
        if chunk:
            self._buf.extend(chunk)

        frames: list[tuple[int, bytes]] = []
        while True:
            start = self._buf.find(SOF)
            if start < 0:
                self._drain_text(bytes(self._buf))
                self._buf.clear()
                break
            if start:
                self._drain_text(bytes(self._buf[:start]))
                del self._buf[:start]
            if len(self._buf) < 3:
                break
            length = self._buf[2]
            if length > MAX_PAYLOAD:
                # Not a frame after all: that 0xA5 was noise.
                self._drain_text(bytes(self._buf[:1]))
                del self._buf[:1]
                continue
            total = 4 + length
            if len(self._buf) < total:
                break
            frame = bytes(self._buf[:total])
            del self._buf[:total]
            if crc8(frame[1:-1]) != frame[-1]:
                if self.verbose:
                    print(f"[bad crc] {frame.hex(' ')}", file=sys.stderr)
                continue
            frames.append((frame[1], frame[3:-1]))
        return frames

    def _drain_text(self, data: bytes) -> None:
        if not self.verbose or not data:
            return
        self._text.extend(data)
        while b"\n" in self._text:
            line, _, rest = bytes(self._text).partition(b"\n")
            self._text = bytearray(rest)
            print("[fw] " + line.decode("utf-8", "replace").rstrip(),
                  file=sys.stderr)

    def command(self, cmd: int, payload: bytes = b"",
                timeout: float = 1.0) -> bytes:
        """Send a command and return the payload of its ACK / STATUS reply."""
        self.ser.write(encode(cmd, payload))
        self.ser.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            for ftype, fpayload in self._pump():
                if ftype == RSP_EVENT:
                    self.events.append((fpayload[0], fpayload[1:]))
                    if self.verbose:
                        name = EVENTS.get(fpayload[0], f"0x{fpayload[0]:02x}")
                        print(f"[event] {name} {fpayload[1:].hex(' ')}",
                              file=sys.stderr)
                    continue
                if ftype == RSP_NACK:
                    raise Nack(fpayload[0], fpayload[1])
                if ftype == RSP_ACK:
                    if fpayload and fpayload[0] != cmd:
                        continue
                    return fpayload[1:]
                if ftype == RSP_STATUS:
                    return fpayload
        raise TimeoutError(
            f"no reply to command 0x{cmd:02x} within {timeout:.1f}s"
        )

    # -- commands --------------------------------------------------------

    def ping(self, payload: bytes = b"\xde\xad") -> bytes:
        echo = self.command(CMD_PING, payload)
        if echo != payload:
            raise RuntimeError(f"ping echo mismatch: {echo.hex()} != {payload.hex()}")
        return echo

    def status(self) -> dict:
        p = self.command(CMD_GET_STATUS)
        if len(p) != 16:
            raise RuntimeError(f"status payload is {len(p)} bytes, expected 16")
        flags = p[5]
        return {
            "protocol": p[0],
            "firmware": f"{p[1]}.{p[2]}.{p[3]}",
            "state": STATES.get(p[4], f"0x{p[4]:02x}"),
            "connected": bool(flags & 0x01),
            "encrypted": bool(flags & 0x02),
            "advertising": bool(flags & 0x04),
            "bonded": bool(flags & 0x08),
            "sub_keyboard": bool(flags & 0x10),
            "sub_mouse": bool(flags & 0x20),
            "sub_consumer": bool(flags & 0x40),
            "bond_count": p[6],
            "host_leds": p[7],
            "address": ":".join(f"{b:02x}" for b in reversed(p[8:14])),
            "uptime_s": p[14] | (p[15] << 8),
        }

    def key_report(self, modifiers: int, keys: list[int]) -> None:
        rpt = bytearray(8)
        rpt[0] = modifiers & 0xFF
        for i, k in enumerate(keys[:6]):
            rpt[2 + i] = k
        self.command(CMD_KEY_REPORT, bytes(rpt))

    def tap(self, modifiers: int, usage: int, hold: float = 0.008) -> None:
        self.key_report(modifiers, [usage])
        time.sleep(hold)
        self.key_report(0, [])

    def move(self, dx: int, dy: int, buttons: int = 0, wheel: int = 0,
             pan: int = 0) -> None:
        payload = (
            int(dx).to_bytes(2, "little", signed=True)
            + int(dy).to_bytes(2, "little", signed=True)
            + bytes([buttons & 0x1F, wheel & 0xFF, pan & 0xFF])
        )
        self.command(CMD_MOUSE_MOVE, payload)

    def buttons(self, mask: int) -> None:
        self.command(CMD_MOUSE_BUTTONS, bytes([mask & 0x1F]))

    def consumer(self, usage: int, pressed: bool) -> None:
        self.command(
            CMD_CONSUMER,
            usage.to_bytes(2, "little") + bytes([1 if pressed else 0]),
        )

    def release_all(self) -> None:
        self.command(CMD_RELEASE_ALL)

    def forget(self) -> None:
        self.command(CMD_FORGET_BONDS, timeout=2.0)


# -------------------------------------------------------------- text typing

def char_to_hid(ch: str) -> tuple[int, int] | None:
    """Map one character to (modifier byte, usage id)."""
    if ch in _PLAIN:
        return 0, KEYS[_PLAIN[ch]]
    if ch in _SHIFTED:
        return MODIFIERS["shift"], KEYS[_SHIFTED[ch]]
    low = ch.lower()
    if low in KEYS and len(low) == 1:
        mod = MODIFIERS["shift"] if ch.isupper() else 0
        return mod, KEYS[low]
    return None


def parse_key_spec(spec: str) -> tuple[int, int]:
    """'cmd+shift+a' -> (0x0a, 0x04)."""
    parts = spec.lower().split("+")
    mods = 0
    usage = None
    for part in parts:
        if part in MODIFIERS:
            mods |= MODIFIERS[part]
        elif part in KEYS:
            usage = KEYS[part]
        else:
            raise SystemExit(f"unknown key name: {part!r}")
    if usage is None:
        raise SystemExit(f"no non-modifier key in {spec!r}")
    return mods, usage


# ------------------------------------------------------------------- port

def autodetect_port() -> str:
    candidates = sorted(
        glob.glob("/dev/cu.usbserial*")
        + glob.glob("/dev/cu.usbmodem*")
        + glob.glob("/dev/cu.SLAB_USBtoUART*")
        + glob.glob("/dev/cu.wchusbserial*")
    )
    if not candidates:
        raise SystemExit(
            "no USB serial device found. Plug the dongle in, or pass --port."
        )
    if len(candidates) > 1:
        print(f"note: several ports found, using {candidates[0]} "
              f"(others: {', '.join(candidates[1:])})", file=sys.stderr)
    return candidates[0]


# ------------------------------------------------------------------- main

def cmd_status(d: Dongle, args) -> int:
    st = d.status()
    width = max(len(k) for k in st)
    for k, v in st.items():
        print(f"{k:>{width}} : {v}")
    sys.stdout.flush()
    if not st["connected"]:
        print("\nNot connected. Pair \"Longwave KVM\" from the headset's "
              "Settings > Bluetooth.", file=sys.stderr)
    elif not st["sub_keyboard"]:
        print("\nConnected but the host has not subscribed to the keyboard "
              "report yet; input will be refused.", file=sys.stderr)
    return 0


def cmd_ping(d: Dongle, args) -> int:
    t0 = time.perf_counter()
    d.ping()
    print(f"pong in {(time.perf_counter() - t0) * 1000:.1f} ms")
    return 0


def cmd_type(d: Dongle, args) -> int:
    text = " ".join(args.text)
    sent = 0
    for ch in text:
        mapped = char_to_hid(ch)
        if mapped is None:
            print(f"skipping unmappable character {ch!r}", file=sys.stderr)
            continue
        mods, usage = mapped
        d.tap(mods, usage, hold=args.hold)
        time.sleep(args.delay)
        sent += 1
    print(f"typed {sent} character(s)")
    return 0


def cmd_key(d: Dongle, args) -> int:
    mods, usage = parse_key_spec(args.name)
    d.tap(mods, usage, hold=args.hold)
    print(f"tapped {args.name}")
    return 0


def cmd_move(d: Dongle, args) -> int:
    d.move(args.dx, args.dy, wheel=args.wheel, pan=args.pan)
    print(f"moved ({args.dx}, {args.dy})")
    return 0


def cmd_click(d: Dongle, args) -> int:
    mask = {"left": 0x01, "right": 0x02, "middle": 0x04}[args.button]
    d.buttons(mask)
    time.sleep(0.04)
    d.buttons(0)
    print(f"{args.button} click")
    return 0


def cmd_square(d: Dongle, args) -> int:
    side = args.side
    step = max(1, args.step)
    legs = [(step, 0), (0, step), (-step, 0), (0, -step)]
    for dx, dy in legs:
        for _ in range(side // step):
            d.move(dx, dy)
            time.sleep(args.interval)
    print(f"traced a {side}x{side} square in steps of {step}")
    return 0


def cmd_consumer(d: Dongle, args) -> int:
    usage = int(args.usage, 0)
    d.consumer(usage, True)
    time.sleep(0.05)
    d.consumer(0, False)
    print(f"consumer usage 0x{usage:04x}")
    return 0


def cmd_release(d: Dongle, args) -> int:
    d.release_all()
    print("released everything")
    return 0


def cmd_forget(d: Dongle, args) -> int:
    d.forget()
    print("bonds cleared; the dongle is advertising for a fresh pairing.")
    print("Remember to 'Forget This Device' on the headset too, or it will "
          "try to reconnect with a key the dongle no longer has.")
    return 0


def cmd_monitor(d: Dongle, args) -> int:
    print("watching for events, ^C to stop", file=sys.stderr)
    try:
        while True:
            for ftype, payload in d._pump():
                if ftype == RSP_EVENT:
                    name = EVENTS.get(payload[0], f"0x{payload[0]:02x}")
                    print(f"{time.strftime('%H:%M:%S')} {name} "
                          f"{payload[1:].hex(' ')}")
            time.sleep(0.02)
    except KeyboardInterrupt:
        return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="serial device (default: autodetect)")
    ap.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print firmware log lines and BLE events")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status").set_defaults(fn=cmd_status)
    sub.add_parser("ping").set_defaults(fn=cmd_ping)

    p = sub.add_parser("type", help="type a string as keystrokes")
    p.add_argument("text", nargs="+")
    p.add_argument("--delay", type=float, default=0.012,
                   help="pause between characters (s)")
    p.add_argument("--hold", type=float, default=0.008,
                   help="key hold time (s)")
    p.set_defaults(fn=cmd_type)

    p = sub.add_parser("key", help="tap one key, e.g. enter or cmd+shift+4")
    p.add_argument("name")
    p.add_argument("--hold", type=float, default=0.008)
    p.set_defaults(fn=cmd_key)

    p = sub.add_parser("move", help="move the pointer by a relative delta")
    p.add_argument("dx", type=int)
    p.add_argument("dy", type=int)
    p.add_argument("--wheel", type=int, default=0)
    p.add_argument("--pan", type=int, default=0)
    p.set_defaults(fn=cmd_move)

    p = sub.add_parser("click")
    p.add_argument("button", nargs="?", default="left",
                   choices=["left", "right", "middle"])
    p.set_defaults(fn=cmd_click)

    p = sub.add_parser("square", help="trace a square with the pointer")
    p.add_argument("--side", type=int, default=200)
    p.add_argument("--step", type=int, default=10)
    p.add_argument("--interval", type=float, default=0.012)
    p.set_defaults(fn=cmd_square)

    p = sub.add_parser("consumer", help="send a consumer-control usage")
    p.add_argument("usage", help="e.g. 0xCD for play/pause, 0xE9 volume up")
    p.set_defaults(fn=cmd_consumer)

    sub.add_parser("release", help="release all keys and buttons").set_defaults(
        fn=cmd_release)
    sub.add_parser("forget", help="erase the dongle's bonds").set_defaults(
        fn=cmd_forget)
    sub.add_parser("monitor", help="print BLE events as they happen").set_defaults(
        fn=cmd_monitor)

    args = ap.parse_args()
    port = args.port or autodetect_port()

    try:
        d = Dongle(port, args.baud, verbose=args.verbose)
    except serial.SerialException as exc:
        raise SystemExit(f"cannot open {port}: {exc}")

    try:
        return args.fn(d, args)
    except Nack as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except TimeoutError as exc:
        print(f"error: {exc}\nIs the firmware running at {args.baud} baud?",
              file=sys.stderr)
        return 3
    finally:
        d.close()


if __name__ == "__main__":
    sys.exit(main())
