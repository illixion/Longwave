# Longwave KVM dongle

An ESP32 board that presents itself to an Apple Vision Pro as a **Bluetooth LE
HID keyboard + mouse + consumer-control device**, and relays input to it from a
Mac over USB serial.

It exists because visionOS accepts Bluetooth keyboards (visionOS 1+) and
Bluetooth mice (visionOS 2+) but gives apps no API to inject input. From the
headset's point of view this is an ordinary Bluetooth keyboard; from the Mac's
point of view it is a serial port that takes HID reports.

```
  macOS app  ──USB serial 460800──▶  ESP32  ──BLE HID over GATT──▶  Vision Pro
                (PROTOCOL.md)                (bonded, encrypted)
```

**Status: paired with a Vision Pro and relaying.** The Mac half ships in the
companion app's **KVM** tab (`CompanionMac/KVMBridgeController.swift` and
friends), which claims the port, shows what the headset is doing, and — on
⌃⌥⌘K — hands this Mac's keyboard, pointer and media keys over to the headset
until the same shortcut takes them back. `kvmctl.py` remains the reference
client and the way to drive the board without the app.

---

## 1. The board

Read off the attached hardware with `esptool`:

| | |
|---|---|
| Chip | **ESP32-D0WD-V3**, revision v3.1 — classic ESP32, dual core Xtensa LX6, 240 MHz |
| Radio | Wi-Fi + Bluetooth 4.2 (BR/EDR + BLE). BLE 4.2 is plenty for HOGP |
| Flash | 4 MB, manufacturer `0x5E`, device `0x4016`, 3.3 V set by strapping pin |
| Crystal | 40 MHz |
| eFuse MAC | `08:d1:f9:fd:98:e4` |
| BLE address | `08:d1:f9:fd:98:e6` (the BLE identity is the base MAC + 2) |
| USB | **UART bridge, not native USB** — WCH CH340 (VID `0x1A86`, PID `0x7523`), driven by macOS's built-in `AppleUSBCHCOM` DriverKit extension |
| Serial device | `/dev/cu.usbserial-*` |

Because the bridge is a CH340 rather than native USB, the serial device name
carries a unit number that **changes when the board is re-enumerated** — it has
appeared as both `/dev/cu.usbserial-2120` and `/dev/cu.usbserial-10` during
this bring-up. Do not hard-code it. `kvmctl.py` autodetects, and for `idf.py`
use:

```sh
PORT=$(ls /dev/cu.usbserial-* | head -1)
```

### Baud rate: 460800, not 921600

The firmware was written for 921600 and the ESP32 side handles it, but **this
CH340 cannot**: `esptool -b 921600` connects and then dies with *"Unable to
verify flash chip connection"*, and a 921600 read of the boot log is pure
noise, while 460800 is clean and `esptool -b 460800` works every time. 460800
gives ~340 command round trips per second, which is far beyond what an input
relay needs.

To change it, edit **both** `KVM_UART_BAUD` in `main/kvm_config.h` and
`CONFIG_ESP_CONSOLE_UART_BAUDRATE` in `sdkconfig.defaults` — the protocol and
the log console share UART0 and must agree.

---

## 2. Toolchain

**ESP-IDF v5.5.5 with the NimBLE host.** Chosen over arduino-cli because the
HID-over-GATT service here needs exact control of things the Arduino BLE-HID
libraries wrap up and hide: which attributes require an encrypted link, the
Report Reference descriptors, LE Secure Connections and bonding policy,
persisting bonds to NVS, and a report map with three collections in one
descriptor. It also installed cleanly first try on this machine (Apple Silicon,
macOS 27), so the "acceptable alternative" never became necessary. NimBLE
rather than Bluedroid because it is much smaller and is what Espressif's own
HID examples use.

The whole application is ~470 KB and fits in a 2.8 MB app partition with 84 %
to spare.

### Install (one time)

```sh
brew install cmake ninja dfu-util
mkdir -p ~/esp && cd ~/esp
git clone -b v5.5.5 --depth 1 --recursive --shallow-submodules \
    https://github.com/espressif/esp-idf.git esp-idf
cd esp-idf && ./install.sh esp32
```

`esptool` itself came from Homebrew (`brew install esptool`, v5.3.1) and is
used for chip identification; `idf.py` bundles its own copy for flashing.

### Every shell

```sh
. ~/esp/esp-idf/export.sh
```

---

## 3. Build and flash

```sh
cd ~/Projects/Longwave/Firmware/kvm-dongle
. ~/esp/esp-idf/export.sh

idf.py set-target esp32          # once, or after deleting sdkconfig
idf.py build
idf.py -p /dev/cu.usbserial-10 -b 460800 flash
idf.py -p /dev/cu.usbserial-10 -b 460800 monitor    # ^] to quit
```

If a board has been used for something else before, erase it first — stale NVS
from a previous tenant makes NimBLE log `NVS data size mismatch for obj_type 1`
on every boot:

```sh
idf.py -p /dev/cu.usbserial-10 -b 460800 erase-flash
```

After editing `sdkconfig.defaults`, delete `sdkconfig` before rebuilding;
defaults are only consulted when `sdkconfig` does not exist.

> A Kconfig trap worth knowing: `CONFIG_ESP_CONSOLE_UART_BAUDRATE` only has a
> prompt under `ESP_CONSOLE_UART_CUSTOM`, and Kconfig silently ignores a
> promptless symbol set from `sdkconfig.defaults`. Setting the baud alongside
> `ESP_CONSOLE_UART_DEFAULT` appears to work and does nothing. That is why this
> project uses `ESP_CONSOLE_UART_CUSTOM` with UART0's stock pins spelled out.

---

## 4. Layout

```
kvm-dongle/
├── CMakeLists.txt
├── sdkconfig.defaults        console baud, NimBLE, security, partitions
├── partitions.csv            2.8 MB app slot; NimBLE does not fit the stock 1 MB
├── main/
│   ├── kvm_config.h          version, device name, UART, LED pin
│   ├── hid_report_map.h      THE HID DESCRIPTOR — do not edit, see §7
│   ├── ble_kvm.{c,h}         NimBLE HOGP peripheral, GATT table, bonding
│   ├── proto.{c,h}           frame encode / incremental parse / CRC8
│   ├── led.{c,h}             status LED patterns
│   └── main.c                UART loop, command dispatch
├── tools/kvmctl.py           host CLI and reference protocol implementation
├── PROTOCOL.md               the serial protocol, normative
└── README.md
```

---

## 5. The host tool

```sh
python3 -m venv .venv && ./.venv/bin/pip install pyserial
./.venv/bin/python tools/kvmctl.py status
```

or, without a venv:

```sh
uv run --with pyserial tools/kvmctl.py status
```

| command | effect |
|---|---|
| `status` | link state, bond count, subscriptions, BLE address, uptime |
| `ping` | round-trip check, prints the latency |
| `type "hello"` | types a string as keystrokes (US layout) |
| `key enter`, `key cmd+shift+4` | taps one key with modifiers |
| `move DX DY` | relative pointer move |
| `click [left\|right\|middle]` | press and release |
| `square` | traces a 200×200 square with the pointer |
| `consumer 0xCD` | a consumer usage (play/pause here) |
| `release` | releases everything |
| `forget` | erases the dongle's bonds |
| `monitor` | prints BLE events as they happen |

`--port` overrides autodetection, `--baud` the rate, `-v` prints firmware log
lines and BLE events alongside.

Everything before pairing returns `not connected to a host` and exits 2. That
is correct, not a fault.

---

## 6. Pairing with the Vision Pro

**This is the human step. Do it before anything else will work.**

1. Power the dongle from USB and check it is advertising:

   ```sh
   ./.venv/bin/python tools/kvmctl.py status
   ```

   `state` must read `advertising`. The status LED (GPIO 2) blinks slowly, one
   short flash per second.

2. On the headset: **Settings → Bluetooth**. Wait for **“Longwave KVM”** to
   appear under *Other Devices* — it advertises as a keyboard (appearance
   `0x03C1`), so visionOS lists it with a keyboard icon.

3. Tap it. Pairing is **Just Works**: there is no passkey to type and no
   confirmation code, because the dongle has no display or keypad. The headset
   may still show a "Pair?" confirmation — accept it.

4. Confirm from the Mac:

   ```sh
   ./.venv/bin/python tools/kvmctl.py status
   ```

   `state` should be `ready`, with `connected`, `encrypted`, `bonded` and
   `sub_keyboard` all `True`. The LED goes solid.

5. Test. Focus a text field on the headset (Safari's address bar is easy), then:

   ```sh
   ./.venv/bin/python tools/kvmctl.py type hello
   ./.venv/bin/python tools/kvmctl.py square
   ```

   `type hello` should put "hello" in the field. `square` should walk the
   pointer around a square — note that on visionOS the pointer only appears
   once a Bluetooth pointing device is connected, and it needs **visionOS 2 or
   later**.

### If visionOS refuses to pair

* **It does not appear in the list at all.** Check `status` says `advertising`.
  `idle` means the radio is up but nothing is discoverable; since 0.1.1 a
  watchdog re-arms advertising within five seconds of that, so an `idle` that
  persists is a real failure — read the log with `idf.py monitor`. If it says
  `connected`, something else grabbed it; run `kvmctl.py forget` and
  power-cycle.
* **It appears, but pairing fails or it drops straight back to the list.** The
  usual cause is a stale half-bond: the headset kept a key the dongle no longer
  has, or vice versa. Clear **both** sides — `kvmctl.py forget` on the dongle,
  and *Forget This Device* on the headset — then pair again. Clearing only one
  side reproduces the failure.
* **It pairs but nothing types.** Read `status`. `connected: True,
  encrypted: True, sub_keyboard: False` means the headset has not subscribed to
  the report yet; give it a second, or toggle Bluetooth on the headset. Input
  is deliberately refused until the host subscribes, rather than silently
  dropped.
* **It pairs, types once, then stops.** Look for `EVENT/DISCONNECTED` with
  `kvmctl.py monitor`. A reason of `0x08` is a supervision timeout — usually
  range or a USB supply too weak for the radio. Use a decent cable and a
  powered port.
* **Everything looks right but reports are misinterpreted** (wrong characters,
  pointer jumping). That is the cached-descriptor problem in §7: unpair on the
  headset and pair again.
* Do **not** pair the dongle to the Mac as a Bluetooth device. It only needs
  the USB serial link; a Mac bond just consumes one of the four bond slots.

---

## 7. The report descriptor is frozen

visionOS — like iOS and macOS — reads the HID report map **once, at pairing
time**, and uses the cached copy for the life of the bond. If
`main/hid_report_map.h` changes and the bond does not, the headset keeps
decoding new reports with the old layout, silently and with no error anywhere.

So the descriptor was settled once, up front:

| report ID | direction | bytes | contents |
|---|---|---|---|
| 1 | input | 8 | modifiers, reserved, 6 keycodes (boot-protocol layout) |
| 1 | output | 1 | 5 keyboard LED bits + 3 padding |
| 2 | input | 7 | 5 buttons + 3 pad, X `int16`, Y `int16`, wheel `int8`, AC Pan `int8` |
| 3 | input | 2 | one 16-bit Consumer usage (≤ `0x03FF`) |

173 bytes total. It has been parsed item-by-item to confirm the collections
balance and every report is byte-aligned at exactly those sizes.

**If it ever must change**, bump `KVM_REPORT_MAP_REVISION` in the same file and
treat it as a breaking change: every paired headset must *Forget This Device*
and pair again.

---

## 8. Security model

* **LE Secure Connections, bonded, Just Works.** Apple hosts refuse HID over an
  unencrypted link, so every report attribute is marked `READ_ENC` and the
  dongle sends a Security Request the moment a host connects.
* **No MITM protection.** The dongle has no display and no keypad, so it
  advertises `NoInputNoOutput`. A fixed passkey compiled into open firmware
  protects nothing while making pairing fussier, so it is not used. The
  practical exposure is an attacker within BLE range at the moment of pairing.
* **Bonds persist in NVS** across reboots and reflashes of the app (the NVS
  partition is separate), up to four. `erase-flash` destroys them.
* **Repeat pairing is allowed**: if a host that already has a bond asks to pair
  again, the old bond is dropped and pairing proceeds. Without this a headset
  that was reset could never come back.

---

## 9. Status LED

GPIO 2, the on-board LED on ESP32 DevKitC / NodeMCU-32S boards. Set
`KVM_LED_GPIO` to `-1` in `main/kvm_config.h` if the board has none.

| pattern | meaning |
|---|---|
| fast blink, 100 ms on / 100 ms off | booting, radio not up |
| one short flash per second | advertising, waiting to be paired |
| two quick blips per second | connected but not yet encrypted |
| solid | ready — encrypted, reports will be relayed |
| solid with brief drop-outs | relaying input |

---

## 10. Known limitations

* **Mouse, not trackpad.** The device reports as a pointing device with five
  buttons, a wheel and AC Pan. visionOS gets no trackpad gestures — no pinch,
  no two-finger swipe, no Magic Trackpad force click — because HID mouse
  reports cannot express them. Scroll comes through as wheel and pan only.
* **The pointer needs visionOS 2+.** Keyboard input works from visionOS 1, but
  Bluetooth pointing devices were only added in visionOS 2. On visionOS 1 the
  mouse reports are accepted and ignored.
* **No absolute pointer positioning.** Reports are relative deltas; there is no
  way to say "put the cursor at (x, y)". A Mac app that wants to mirror its own
  cursor has to track the difference itself and accept drift.
* **US keyboard layout only in `kvmctl.py`.** The firmware relays raw HID
  usages and is layout-agnostic; only the CLI's `type` mapping assumes US.
* **One host at a time.** A single BLE connection, up to four stored bonds.
  Switching hosts means disconnecting the first.
* **Classic ESP32 is BLE 4.2**, so no LE 2M PHY and no extended advertising.
  Irrelevant for HID bandwidth, but it caps connection interval choices.
* **921600 baud is unreachable** through this CH340, see §1.
* **The serial link is unauthenticated.** Anything that can open the port can
  type on the headset. Same trust boundary as plugging in a USB keyboard.
* **The boot log shares the protocol UART.** Harmless — log output is ASCII and
  the framer resynchronises on `0xA5` — but a client must discard non-frame
  bytes rather than error on them. The first ~1 KB after a reset is the mask-ROM
  bootloader talking at a fixed 115200 and will look like garbage.
* **The headset subscribes to reports on its own schedule.** Seen on visionOS:
  connected, encrypted and bonded, with none of the three report
  characteristics subscribed, so every report came back `NOT_SUBSCRIBED`. A
  client should treat the subscription bits — not the connection — as the
  question of whether input will arrive, and should not assume all three switch
  on together.

---

## 11. What was verified on hardware

Done on the attached board:

* chip and flash identification (`esptool chip-id`, `flash-id`)
* clean build, flash, and boot — full boot log captured, no errors
* `Longwave KVM` advertising confirmed **over the air** from the Mac with a
  CoreBluetooth scan: service `0x1812`, connectable, RSSI −53 dBm. The Mac was
  not paired to it.
* 500/500 `ping` round trips, median 2.8 ms, p95 3.0 ms; ~340 round trips/s
* `status` returning a correct, live status block
* every `NACK` path — bad checksum, wrong length, unknown command, not
  connected — and resynchronisation after injected junk bytes
* `forget` clearing bonds while leaving the dongle advertising
* pairing, bonding and encryption against a real Vision Pro, and typing and
  pointer movement arriving on it (`kvmctl.py type` and `square`)
* the Swift client in the companion — port discovery, open, status, 50 pings at
  2.86 ms average (matching `kvmctl.py`), 20 key frames back to back at 3.0 ms
  each in order, `NACK` decoding, clean close
* **opening the serial port does *not* reset this board.** The README used to
  say it did, on the usual DTR/RTS reasoning; two consecutive opens through
  `AppleUSBCHCOM` left the uptime counter running (1062 s → 1065 s) with no
  `BOOT` event. Clients should still tolerate a reset — another bridge will do
  it — but must not count on one to resynchronise.

**Not verified**, because it needs a headset or eyes on the board:

* pairing, bonding, and encryption against visionOS
* whether the headset actually types what it is sent, and whether the pointer
  moves — the descriptor is validated structurally but has never been consumed
  by a real host
* reconnect after the headset sleeps or goes out of range
* the status LED patterns (GPIO 2 is driven, but nobody has looked at it)
