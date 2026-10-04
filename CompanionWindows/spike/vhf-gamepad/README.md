# vhf-gamepad: a Windows virtual gamepad with no paid certificate

Spike for NATIVE_V3_PROTOCOL.md §7.2 ("Virtual gamepads on Windows") and §9 risk 8.
Question: can Longwave ship its own virtual gamepad driver for Windows without
buying a code-signing certificate and without test-signing mode, and do games
see the pad? **Answer on Windows 10 22H2 (Secure Boot on): yes.** Results are
at the end; the Windows 11 run is pending (see "Running the test").

## What it is, in plain Windows terms

- **A user-mode driver (UMDF2).** It's a DLL that Windows loads into
  `WUDFHost.exe`, an ordinary process. If it crashes, that process restarts; the
  PC can't blue-screen. Only *kernel* drivers need Microsoft's signature, so a
  user-mode driver is what makes "no paid certificate" possible at all.
- **On the inbox Virtual HID Framework (VHF).** `vhf.sys` and `VhfUm.dll` ship
  with Windows 10 1709 and later. Our driver asks VHF to create a HID device
  (the USB-less version of what a real controller is), with the report
  descriptor of an Xbox Series pad or a DualSense. Every input API then sees an
  ordinary controller.
- **XInput comes free.** Windows' own `xinputhid.sys` attaches to any HID device
  whose hardware ID is on its list (`HID\VID_045E&PID_0B12&IG_00` for the Xbox
  Series pad). That is what puts our pad into `XInputGetState`. A true Xbox 360
  pad isn't possible this way (that needs a USB bus driver); games don't care.
- **One device node, many pads.** Windows loads drivers onto *device nodes*. A
  virtual driver has no hardware to trigger that, so `lwpad-devnode.exe` creates
  one "root-enumerated" node, `Root\LongwaveVirtualGamepad` (what devcon or
  nefconc do, here in 150 lines of inbox SetupAPI). Pads are then created and
  destroyed at runtime with no further installs.
- **The feeder owns its pads.** A program (Longwave's host; here `lwpad-test`)
  opens the driver and sends small fixed-size requests (IOCTLs): create pad,
  submit input, poll feedback (rumble, lightbar), destroy pad. When its handle
  closes, including when the process is killed, the driver deletes its pads.

## Signing without buying a certificate

Windows installs a driver package only if its catalog file (`.cat`, a signed
list of the package's file hashes) is signed by a certificate the machine
trusts. `install.ps1` does this on the machine itself:

1. Creates a self-signed code-signing certificate in `LocalMachine\My` with a
   non-exportable key (`New-SelfSignedCertificate`, RSA-3072, CA=false).
2. Signs the catalog, the driver DLL and the kit's tools (`Set-AuthenticodeSignature`,
   inbox, so the target needs no SDK).
3. Adds the **public** certificate to `LocalMachine\Root` (trusted root) and
   `LocalMachine\TrustedPublisher` (install without asking).
4. **Deletes the private key** and proves it: no certificate with a key in any
   store, the key file under `%ProgramData%\Microsoft\Crypto\Keys` gone, and the
   key storage provider can't open it. From then on nobody, including malware on
   that PC, can sign anything with the trusted certificate; it vouches only for
   the files signed in step 2.
5. Stages the package (`pnputil /add-driver`, where Windows checks the
   signature) and creates the device node. Both run non-interactively, so if
   Windows wanted to show "Windows can't verify the publisher", they would fail
   rather than prompt. That's how the test proves the install is silent.

Test-signing mode is never used. `uninstall.ps1` removes the device node, the
remembered pad nodes, the driver package, the DLL copy and every copy of the
certificate. That includes `LocalMachine\CA`, where Windows itself files one
when it installs the catalog.

**Expiry.** The certificate is valid for 10 years by default (`-ValidityDays`).
With the key destroyed, a long life costs nothing. Measured on Windows 10: once a
package is in the driver store, it keeps loading after the certificate expires.
The signature is checked only at import. So expiry only matters for installing
a package onto a machine for the first time.

## Layout

```
driver/driver.cpp                 the UMDF2/VHF driver (~600 lines; Xbox Series + DualSense)
driver/LongwaveVirtualGamepad.inf the package description (Win10 and Win11 sections)
include/lwpad.h                   our interface GUID, hardware ID, stats IOCTL
tools/lwpad-devnode.cpp           create/remove/status of the root device node
tools/lwpad_client.h              feeder-side client (what lw_gamepad_* would wrap)
tools/lwpad-test.cpp              XInput / Windows.Gaming.Input / kill / cycle tests
tools/lwpad-sdltest.cpp           SDL3 tests (Xbox; DualSense gyro, rumble, lightbar)
vendor/libvirtualgamepad/         MIT, unchanged: wire protocol + report encoders
build.ps1                         build everything, assemble build\kit
install.ps1 / uninstall.ps1       see above (inbox PowerShell only)
run-gamepad-spike.ps1             baseline + install + tests + uninstall -> results\*.log
evidence/                         result logs worth keeping (Windows 10 run)
```

`spike/` is gitignored in this repo; files here are force-added.

## Building (on a machine with the toolchain)

Needs Visual Studio 2022 or its Build Tools (x64 C++), Windows SDK 10.0.26100
and the WDK 10.0.26100 (`winget install Microsoft.WindowsWDK.10.0.26100`; only
its headers, libraries, Inf2Cat and InfVerif are used, and the Visual Studio
WDK extension is not needed).

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

`build\kit\` is then self-contained: driver package (unsigned catalog), tools,
SDL3.dll, scripts. Copy that folder to the machine under test.

## Running the test (Windows 10 PC, Windows 11 VM)

The machine under test needs **nothing installed**: no SDK, WDK or Visual Studio.
It needs x64 Windows 10 2004+ or Windows 11, and an administrator account. No GPU
or controller is needed: the driver and every check are pure software and work
the same in a Hyper-V VM (see "VM caveats").

1. Copy `build\kit` to the machine as `C:\lwpad-kit`. (On gaming-pc a zip of
   the 2026-10-04 build is at
   `C:\Users\Ixion\Developer\longwave-gamepad-spike\lwpad-kit.zip`.) Into a
   Hyper-V VM, from an admin PowerShell on the **host**:
   ```powershell
   Enable-VMIntegrationService -VMName <vm> -Name "Guest Service Interface"
   Copy-VMFile -Name <vm> -SourcePath C:\Users\Ixion\Developer\longwave-gamepad-spike\lwpad-kit.zip `
       -DestinationPath C:\lwpad-kit.zip -CreateFullPath -FileSource Host
   ```
   then in the VM: `Expand-Archive C:\lwpad-kit.zip C:\lwpad-kit`. (A shared
   folder or an ISO works too; `install.ps1` clears the "downloaded from the
   internet" mark itself.)
2. Sign in to the desktop. Open **PowerShell as administrator** (Start, type
   *PowerShell*, then *Run as administrator*). Use the desktop session rather
   than SSH: the Windows.Gaming.Input check needs a foreground window, which an
   SSH session doesn't have (it reports SKIP there).
3. Run:
   ```powershell
   cd C:\lwpad-kit
   powershell -ExecutionPolicy Bypass -File .\run-gamepad-spike.ps1 -KeepInstalled
   ```
   A small "WGI test" window flashes for a few seconds. Leave it alone.
4. Reboot, sign in again, admin PowerShell, then:
   ```powershell
   cd C:\lwpad-kit
   powershell -ExecutionPolicy Bypass -File .\run-gamepad-spike.ps1 -AfterReboot
   ```
   This checks that the driver came back by itself after the reboot, reruns the
   tests and uninstalls.
5. Bring back `results\*.log` (two files). The summary at the bottom lists
   every FAIL/SKIP.

To test without the reboot step, run once without switches: it installs, tests
and uninstalls. To remove everything by hand: `.\uninstall.ps1`.

**Over SSH instead:** Windows 11 includes OpenSSH Server as an optional feature
(`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`, then
`Start-Service sshd`). Everything except the WGI check works over SSH as an
administrator.

### What the Windows 11 run must answer

The log's baseline section records these; they are the open questions.

- **Smart App Control** (`HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy`,
  `VerifiedAndReputablePolicyState`: 0 off, 1 on, 2 evaluation; plus
  `Get-MpComputerStatus`'s `SmartAppControlState` where present). A fresh
  install starts in **evaluation**. Section 5 of the log lists Code Integrity
  events since the install: event **3076** means "SAC would have blocked this"
  (audit), **3077** means "blocked". Whether our locally signed DLL and tools
  draw 3076s in evaluation mode is the key result, because that predicts what
  happens when SAC turns itself on.
- **Memory Integrity (HVCI)**, on by default on new Windows 11 installs. It
  governs kernel code, and this driver adds none (VHF and the reflector are
  Microsoft's), so it shouldn't matter. The log records it.
- **Secure Boot** on, **test signing** off: recorded as on Windows 10.
- That the Windows 11 INF section (inbox `WUDFRD.inf` filter) installs.

### VM caveats

Nothing in the driver or the tests uses real hardware: VHF, HID, XInput,
Windows.Gaming.Input and SDL are all software paths, and rumble is checked at
the driver (the output report arriving) rather than by feeling a motor. No GPU
is needed (SDL is initialised for gamepads only). What a VM does not cover is
real games, anti-cheat, Steam Input, and the physical-controller mix of a
gaming PC (a real Xbox pad taking XInput slot 0 is handled; the tests use
whichever slot appears).

## Results: Windows 10 22H2 (gaming-pc), 2026-10-04

Baseline: Windows 10 Pro 22H2 build 19045, **Secure Boot ON**, **test signing
off** (not set in bcdedit), VBS running but Memory Integrity not running, no
Smart App Control on Windows 10. Inbox `vhf.sys`, `VhfUm.dll`, `hidvhf.inf` and
`xinputhid.inf` present. ViGEmBus 1.22 installed; untouched.

Signing:
- **Unsigned catalog: refused**, `0xE0000247` "Driver package catalog file does
  not contain a signature, and Code Integrity is enforced."
- **Signed, certificate in Root only: refused** non-interactively, `0xE0000242`
  "Driver package signer is unknown, and failed to inform user… Cannot display
  UI to non-interactive caller". This is the "Would you like to install this
  device software?" prompt.
- **Signed, Root + TrustedPublisher, key destroyed: installed silently in 3 s.**
  setupapi.dev.log shows "The INF was signed with an Authenticode(tm) catalog
  from a trusted publisher", `Signer Score = 0x0F000000 (Authenticode)`.
  Device status OK, hosted by `WUDFHost.exe`, no Code Integrity events.
  `Win32_PnPSignedDriver.IsSigned` reads False, because that field means
  "signed by Microsoft (WHQL)". It's cosmetic.
- After the certificate expired: device restart, a new device node and
  re-staging all still worked; `Get-AuthenticodeSignature` reports the expiry.

Function (Xbox Series profile unless noted):
- XInput: slot appears ~100 ms after create (~6 ms when warm). All 16 button
  cases, both sticks at full scale both ways, triggers full/partial: exact
  values, visible within 0.2 ms of the IOCTL. `XInputSetState` rumble reaches
  the driver exactly (32768/65535 in, 32767/65535 out). Removal within 2 ms of
  destroy.
- Windows.Gaming.Input: `GamepadAdded` fires ~15 ms after create (VID 045E
  PID 0B12); input and vibration including **impulse triggers** reach the
  driver, 10 of 10 runs. WGI serves only the process that owns the foreground
  window (its rule, not ours): over SSH it reads zeros, which the test reports
  as SKIP.
- Those 10 WGI runs were **unelevated**: the INF's access rule lets the
  signed-in user create and drive pads without admin, as the Longwave host
  will.
- SDL 3.4.18: Xbox pad = "Xbox Series X Controller", type XBOXONE (via XInput);
  input and rumble round-trip. **DualSense** = "DualSense Wireless Controller",
  type PS5 (SDL's own HID driver), buttons/sticks/triggers, **gyro exact (90°/s
  → 1.571 rad/s on each axis, axes distinct)**, accelerometer at rest 9.81,
  rumble and lightbar colour reach the driver.
- Feeder killed with `Stop-Process -Force`: pad gone within ~15 ms.
- 2,000 create/use/destroy cycles in 15 s: no failures, same WUDFHost process,
  handle count unchanged, private memory +156 KB (not growing per cycle), no
  leaked device nodes.
- The one-shot `run-gamepad-spike.ps1` (elevated, desktop session, 500
  cycles): **57 PASS, 0 FAIL, 0 SKIP** in 33 s, then a clean uninstall. The
  log is `evidence/win10-gaming-pc-2026-10-04.log`. The `-KeepInstalled` /
  `-AfterReboot` pair was exercised without the reboot itself (not allowed on
  that PC), so **survival across a reboot is untested** and is the VM run's job.

## Licences

`vendor/libvirtualgamepad` is MIT, Copyright (c) 2026 Chase Payne
(https://github.com/Nonary/libvirtualgamepad, commit 4b56fb9). It is vendored
unchanged (`protocol.h`, `ds4_usb.h`, `ds5_usb.h`, `xbox_series.*`,
`dualsense.*`, `dualshock4.*`, `report_pump.*`); its LICENSE is alongside.
`driver.cpp` and the INF are reduced rewrites of its driver and INF and say so.
SDL3 (zlib licence) is downloaded at build time for the test tool only.
