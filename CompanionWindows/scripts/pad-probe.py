"""Read the virtual controllers games see on this PC, as JSON.

The far end of the gamepad test harness. On the headset, the debug build's
`gamepadVirtualSet` endpoint (Longwave/Gamepad/GamepadDebugEndpoints.swift)
drives a pad through a Moonlight stream or a PCVR session; this reads what came
out: Sunshine's ViGEm DualShock 4 or Xbox 360 pad, or the PCVR broker's Xbox 360
pad. With a real pad in hand, `watch` records which axes moved, which is how a
gyro's axis order and signs get checked without a game.

  py pad-probe.py list                  connected pads
  py pad-probe.py read                  one reading of every pad
  py pad-probe.py watch --seconds 8     per-field min/max and every button seen

Two sources, both readable from an SSH session (no desktop needed):
  * XInput slots 0-3 through xinput1_4.dll (ordinal 100 for the Guide button).
  * DualShock 4 pads through raw HID reports (`py -m pip install --user hidapi`).
    The motion fields are decoded back into what Sunshine was sent: gyro in
    deg/s and acceleration in m/s^2, in SDL's axes, by undoing Sunshine's DS4
    scaling and its inverse of ViGEmBus's calibration
    (src/platform/windows/input.cpp, ds4_update_motion).

Button names match the headset endpoint's: a/b/x/y are the Xbox positions
(DS4 cross/circle/square/triangle), menu is Start/Options, options is
Back/Share, home is Guide/PS.
"""

import argparse
import ctypes
import json
import sys
import time

# ---------------------------------------------------------------- XInput

class _XInputGamepad(ctypes.Structure):
    _fields_ = [("wButtons", ctypes.c_ushort), ("bLeftTrigger", ctypes.c_ubyte),
                ("bRightTrigger", ctypes.c_ubyte), ("sThumbLX", ctypes.c_short),
                ("sThumbLY", ctypes.c_short), ("sThumbRX", ctypes.c_short),
                ("sThumbRY", ctypes.c_short)]


class _XInputState(ctypes.Structure):
    _fields_ = [("dwPacketNumber", ctypes.c_uint), ("Gamepad", _XInputGamepad)]


_XINPUT_BUTTONS = [
    (0x0001, "dpadUp"), (0x0002, "dpadDown"), (0x0004, "dpadLeft"), (0x0008, "dpadRight"),
    (0x0010, "menu"), (0x0020, "options"), (0x0040, "leftStick"), (0x0080, "rightStick"),
    (0x0100, "leftShoulder"), (0x0200, "rightShoulder"), (0x0400, "home"),
    (0x1000, "a"), (0x2000, "b"), (0x4000, "x"), (0x8000, "y"),
]


def _xinput_get_state():
    """XInputGetStateEx (ordinal 100, which also reports Guide) when present."""
    try:
        dll = ctypes.WinDLL("xinput1_4")
    except OSError:
        return None
    try:
        fn = dll[100]
    except (AttributeError, OSError):
        fn = dll.XInputGetState
    fn.argtypes = [ctypes.c_uint, ctypes.POINTER(_XInputState)]
    fn.restype = ctypes.c_uint
    return fn


def _axis(value):
    return round(max(-1.0, value / 32767.0), 4)


def read_xinput():
    get_state = _xinput_get_state()
    if get_state is None:
        return []
    pads = []
    for index in range(4):
        state = _XInputState()
        if get_state(index, ctypes.byref(state)) != 0:  # ERROR_DEVICE_NOT_CONNECTED
            continue
        g = state.Gamepad
        pads.append({
            "kind": "xinput", "index": index, "packet": state.dwPacketNumber,
            "buttons": [name for bit, name in _XINPUT_BUTTONS if g.wButtons & bit],
            "leftStick": [_axis(g.sThumbLX), _axis(g.sThumbLY)],
            "rightStick": [_axis(g.sThumbRX), _axis(g.sThumbRY)],
            "leftTrigger": round(g.bLeftTrigger / 255.0, 4),
            "rightTrigger": round(g.bRightTrigger / 255.0, 4),
        })
    return pads

# ------------------------------------------------------------ DualShock 4

DS4_VENDOR, DS4_PRODUCT = 0x054C, 0x05C4
_DS4_DPAD = {0: ["dpadUp"], 1: ["dpadUp", "dpadRight"], 2: ["dpadRight"],
             3: ["dpadDown", "dpadRight"], 4: ["dpadDown"], 5: ["dpadDown", "dpadLeft"],
             6: ["dpadLeft"], 7: ["dpadUp", "dpadLeft"]}
_DS4_BUTTONS = [
    (0x0010, "x"), (0x0020, "a"), (0x0040, "b"), (0x0080, "y"),
    (0x0100, "leftShoulder"), (0x0200, "rightShoulder"),
    (0x0400, "leftTrigger"), (0x0800, "rightTrigger"),
    (0x1000, "options"), (0x2000, "menu"), (0x4000, "leftStick"), (0x8000, "rightStick"),
]
_DS4_SPECIAL = [(0x01, "home"), (0x02, "touchpad")]
# Sunshine's inverse calibration (bias, scale) per axis; undone here.
_GYRO_CAL = [(1, 0.977596), (0, 0.972370), (0, 0.971550)]
_ACCEL_CAL = [(-297, 1.010796), (-42, 1.014614), (-512, 1.024768)]
EARTH_G = 9.80665


def _hid():
    try:
        import hid  # hidapi
    except ImportError:
        return None
    return hid


def _int16(data, i):
    return int.from_bytes(bytes(data[i:i + 2]), "little", signed=True)


def _uncalibrate(raw, bias, scale):
    return raw * scale - bias


def decode_ds4(data):
    # Report 0x01 over USB; hidapi on Windows keeps the report ID as byte 0.
    o = 1 if data and data[0] == 0x01 else 0
    if len(data) < o + 24:
        return None
    buttons_word = data[o + 4] | (data[o + 5] << 8)
    buttons = list(_DS4_DPAD.get(buttons_word & 0x0F, []))
    buttons += [name for bit, name in _DS4_BUTTONS if buttons_word & bit]
    buttons += [name for bit, name in _DS4_SPECIAL if data[o + 6] & bit]
    gyro_raw = [_int16(data, o + 12 + 2 * k) for k in range(3)]
    accel_raw = [_int16(data, o + 18 + 2 * k) for k in range(3)]
    return {
        "buttons": buttons,
        # DS4 sticks are 0..255 with +Y down; report +Y up like the headset.
        "leftStick": [round((data[o] - 128) / 127.5, 4), round((128 - data[o + 1]) / 127.5, 4)],
        "rightStick": [round((data[o + 2] - 128) / 127.5, 4), round((128 - data[o + 3]) / 127.5, 4)],
        "leftTrigger": round(data[o + 7] / 255.0, 4),
        "rightTrigger": round(data[o + 8] / 255.0, 4),
        "gyroDps": [round(_uncalibrate(r, *c) / 16.0, 2) for r, c in zip(gyro_raw, _GYRO_CAL)],
        "accelMps2": [round(_uncalibrate(r, *c) / 8192.0 * EARTH_G, 3) for r, c in zip(accel_raw, _ACCEL_CAL)],
        "gyroRaw": gyro_raw, "accelRaw": accel_raw,
    }


class DS4Readers:
    """Open DS4 HID devices, each read to its newest report on every poll."""

    def __init__(self):
        self.devices = []
        self.last = {}
        hid = _hid()
        if hid is None:
            self.error = "hidapi not installed: py -m pip install --user hidapi"
            return
        self.error = None
        for info in hid.enumerate(DS4_VENDOR, DS4_PRODUCT):
            device = hid.device()
            try:
                device.open_path(info["path"])
                device.set_nonblocking(1)
            except OSError as e:
                self.error = f"could not open a DS4: {e}"
                continue
            self.devices.append((info["path"].decode(errors="replace"), device))

    def poll(self):
        pads = []
        for path, device in self.devices:
            while True:
                data = device.read(64)
                if not data:
                    break
                decoded = decode_ds4(data)
                if decoded:
                    self.last[path] = decoded
            if path in self.last:
                pads.append({"kind": "ds4", "path": path, **self.last[path]})
        return pads

    def close(self):
        for _, device in self.devices:
            device.close()

# ------------------------------------------------------------------ CLI


def read_all(ds4, settle=0.15):
    # A first poll only drains; give a fresh report time to arrive.
    ds4.poll()
    time.sleep(settle)
    return read_xinput() + ds4.poll()


def watch(ds4, seconds, interval):
    summary = {}
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for pad in read_xinput() + ds4.poll():
            key = f"{pad['kind']}:{pad.get('index', pad.get('path'))}"
            s = summary.setdefault(key, {"kind": pad["kind"], "buttonsSeen": [], "ranges": {}})
            for name in pad["buttons"]:
                if name not in s["buttonsSeen"]:
                    s["buttonsSeen"].append(name)
            for field in ("leftStick", "rightStick", "gyroDps", "accelMps2"):
                for axis, value in zip("xyz", pad.get(field, [])):
                    r = s["ranges"].setdefault(f"{field}.{axis}", [value, value])
                    r[0], r[1] = min(r[0], value), max(r[1], value)
            for field in ("leftTrigger", "rightTrigger"):
                r = s["ranges"].setdefault(field, [pad[field], pad[field]])
                r[0], r[1] = min(r[0], pad[field]), max(r[1], pad[field])
        time.sleep(interval)
    return list(summary.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("mode", choices=["list", "read", "watch"])
    parser.add_argument("--seconds", type=float, default=8.0, help="watch duration")
    parser.add_argument("--interval", type=float, default=0.01, help="watch poll interval, s")
    args = parser.parse_args()
    if sys.platform != "win32":
        sys.exit("pad-probe.py reads Windows controllers; run it on the streaming PC")

    ds4 = DS4Readers()
    try:
        if args.mode == "list":
            out = {"xinput": [p["index"] for p in read_xinput()],
                   "ds4": [path for path, _ in ds4.devices]}
        elif args.mode == "read":
            out = {"pads": read_all(ds4)}
        else:
            out = {"seconds": args.seconds, "pads": watch(ds4, args.seconds, args.interval)}
        if ds4.error:
            out["ds4Error"] = ds4.error
        print(json.dumps(out, indent=1))
    finally:
        ds4.close()


if __name__ == "__main__":
    main()
