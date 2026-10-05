# vhf-gamepad: a Windows virtual gamepad with no paid certificate

Spike for NATIVE_V3_PROTOCOL.md §7.2 ("Virtual gamepads on Windows") and §9 risk 8.
Question: can Longwave ship its own virtual gamepad driver for Windows without
buying a code-signing certificate and without test-signing mode, and do games
see the pad? **Answer on Windows 10 22H2 (Secure Boot on): yes.** **On Windows
11 26H2 (Secure Boot on, fresh install): yes while Smart App Control is in
evaluation or off; with Smart App Control on, not reliably** — Windows ignores
the local certificate there and judges each file by Microsoft's cloud
reputation, which blocked our feeder tool in one of two fresh builds. **On Windows
11 bare metal with Memory Integrity (HVCI) on, built on the machine itself: yes,
HVCI changes nothing.** Sleep needed a fix: the first driver blue-screened the PC
(0x9F in Microsoft's `vhf.sys`) whenever it went to sleep with a pad present.
The driver now deletes its pads before `vhf.sys` powers down, and the feeder
recreates them after resume (see "Sleep and power"). Results are at the end.

## What it is, in plain Windows terms

- **A user-mode driver (UMDF2).** It's a DLL that Windows loads into
  `WUDFHost.exe`, an ordinary process. If it crashes, that process restarts; our
  code can't blue-screen the PC. (The kernel stack it drives can, and did, when
  the PC slept with a pad present: see "Sleep and power".) Only *kernel* drivers need
  Microsoft's signature, so a user-mode driver is what makes "no paid
  certificate" possible at all.
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
driver/driver.cpp                 the UMDF2/VHF driver (~1,000 lines; Xbox Series + DualSense)
driver/LongwaveVirtualGamepad.inf the package description (Win10 and Win11 sections)
include/lwpad.h                   our interface GUID, hardware ID, stats IOCTL
tools/lwpad-devnode.cpp           create/remove/status of the root device node
tools/lwpad_client.h              feeder-side client (what lw_gamepad_* would wrap)
tools/lwpad-test.cpp              XInput / Windows.Gaming.Input / kill / cycle / sleep tests
tools/lwpad-sdltest.cpp           SDL3 tests (Xbox; DualSense gyro, rumble, lightbar)
vendor/libvirtualgamepad/         MIT, unchanged: wire protocol + report encoders
build.ps1                         build everything, assemble build\kit
install.ps1 / uninstall.ps1       see above (inbox PowerShell only)
run-gamepad-spike.ps1             baseline + install + tests + uninstall -> results\*.log
run-sleep-test.ps1                one real sleep (S3) with pads idle/churning, wake timer, checks -> results\*.log
vm/New-Win11TestVM.ps1            Hyper-V host: stock Windows 11 VM, unattended (+ autounattend.template.xml)
vm/Run-KitInVM.ps1                Hyper-V host: run the kit in that VM's desktop, reboot, run again, fetch logs
evidence/                         result logs worth keeping (Windows 10 PC, Windows 11 VM and bare metal)
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

**Sleep test** (the PC really sleeps, ~1.5 minutes per run): with the driver
installed (`-KeepInstalled`), run
`powershell -ExecutionPolicy Bypass -File .\run-sleep-test.ps1 -Mode idle` (or
`none`, `churn`, `aware`). It needs S3 and wake timers enabled (both checked),
and a timer wakes the PC after 45 s. After the wake the session is locked until
someone signs in, and XInput reads zeros while it is, so those checks report
SKIP. To keep the sleep from cutting off an SSH session, start it from a
scheduled task.

**The Windows 11 VM, end to end from the Hyper-V host** (elevated Windows
PowerShell on the host; nothing on the host changes beyond the VM's files):
```powershell
.\vm\New-Win11TestVM.ps1 -IsoPath C:\...\Win11_x64.iso        # ~10 min unattended
.\vm\Run-KitInVM.ps1 -KitZip C:\...\lwpad-kit.zip           # both runs + reboot, ~4 min
```
`New-Win11TestVM.ps1` builds a Generation 2 VM (4 vCPU, 4-6 GB, 64 GB disk,
Secure Boot with the Microsoft Windows template, vTPM, Default Switch) and
installs Windows 11 Pro with an answer file that skips the account/EULA pages
but relaxes nothing: no Secure Boot/TPM bypass, Defender and Smart App Control
as shipped. A local admin `lwtest` signs in automatically (its random password
is in `lwtest-password.txt` next to the VM). `Run-KitInVM.ps1` drives the guest
over PowerShell Direct and runs the kit through a scheduled task in the
signed-in desktop session, so the WGI check has a foreground window. Three
things it does on purpose, each learned the hard way:
- **Updates Defender first.** The ISO's Defender was a year old and its cloud
  refused it (`ValidateMapsConnection` → HTTP 426). Smart App Control then
  allowed every unknown file, which made the first SAC results meaningless.
  Don't pause Windows Update before Defender has updated once.
- **Reboots from inside the guest.** `Restart-VM` is a hard reset; one took a
  device node installed two minutes earlier with it, along with other
  unflushed registry writes.
- **Never runs a kit binary before `install.ps1` has signed it** (see the SAC
  results).

**Over SSH instead:** Windows 11 includes OpenSSH Server as an optional feature
(`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`, then
`Start-Service sshd`). Everything except the WGI check works over SSH as an
administrator.

### What the Windows 11 run had to answer

The log's baseline section records these (answers in the results below).

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
  that PC), so survival across a reboot was left to the Windows 11 VM (below:
it survives).

## Results: Windows 11 26H2 (Hyper-V VM on gaming-pc), 2026-10-04

Logs: `evidence/win11-hyperv-vm-2026-10-04-*.log` (numbered in the order run)
and `-8-sac-controls.txt` (the control experiments, with raw event data).

Baseline: Windows 11 Pro 26H2 build 26300.9457, fresh unattended install from
Microsoft's ISO, not activated. **Secure Boot ON**, **test signing off**, vTPM
ready. **Smart App Control: Evaluation** (`VerifiedAndReputablePolicyState=2`,
Defender `SmartAppControlState=Eval`, evaluation ends 2026-11-18). **Memory
Integrity not running, VBS off**: Windows didn't turn them on in this VM. The VM
has no nested virtualization (an AMD host on Windows 10 can't offer it), which
VBS in a guest needs. HVCI governs kernel code and this driver adds none.
Inbox `vhf.sys`, `VhfUm.dll`, `hidvhf.inf`, `xinputhid.inf`, `WUDFRD.inf`
present.

### Facts

- **Evaluation mode (the out-of-box state): works, survives a reboot.** The
  same zip as Windows 10: silent install through the Windows 11 INF section, 56
  PASS 0 FAIL, then a graceful reboot. The device came back by itself
  (`-AfterReboot`: 56 PASS 0 FAIL, then a clean uninstall). Logs 1 and 2.
- **Evaluation mode logs nothing useful.** No 3076 ("would have blocked")
  events for any kit file, including the build that SAC-on later blocked.
  The diagnostic 3090 events say every kit file passed the evaluation policy
  (`PassesSmartlocker=true`). Evaluation gives no early warning.
- **Installed during evaluation, then SAC on: keeps working.** SAC switched to
  On (Windows Security, one UAC prompt, no reboot needed), graceful reboot:
  the driver loaded at boot and every tool ran, 56 PASS. Files that had already
  run were not checked again (log 3).
- **SAC on, fresh build of the same source: our signature counts for nothing.**
  Blocked files are logged with `Validated Signing Level=1` (unsigned) even
  though they carry a valid signature from a certificate in Root and
  TrustedPublisher. What decides is the cloud's verdict on the file. In two
  fresh builds made three minutes apart:
  - build 0.1.0.7777 (log 5): `lwpad-test.exe` **blocked** ("An Application
    Control policy has blocked this file", 3077, policy
    `VerifiedAndReputableDesktop`), before and after signing, and a copy of it
    too. In the same run, `lwpad-devnode.exe`, `lwpad-sdltest.exe`, SDL3.dll and
    the driver DLL in `WUDFHost.exe` were allowed. The install succeeded and
    the device was OK.
  - build 0.1.0.8888, which had never run unsigned (log 6): **everything
    allowed**, 57 PASS 0 FAIL.
  - Controls (file 8): one unsigned copy of a build was blocked while copies
    of the same bytes, signed by a trusted or an untrusted self-signed
    certificate, were allowed. Minutes later, unsigned copies of the next build
    (random bytes appended) were allowed too.
- **The driver DLL was never blocked** in any run, under any SAC state.
- **SAC off: works.** The build whose tool SAC had blocked: 57 PASS 0 FAIL (log
  7). On this build, Windows Security left "On" selectable after Off. Turning it
  back on wasn't tried.
- **SAC with a stale Defender allows everything.** Before Defender's first
  update, its cloud refused the old client (MAPS HTTP 426) and SAC "On" let
  unsigned, never-seen binaries run (`DefenderTrust=-1`). File 8, section A.
  It explains why the first attempt saw no blocks at all; it isn't a mitigation.
- **Windows.Gaming.Input vibration from an elevated process doesn't reach the
  driver on this Windows 11 build** (input does). Unelevated it passes every
  time, as on Windows 10. Games aren't elevated, and neither is the Longwave
  host. The kit now runs the counted WGI check unelevated and logs the
  elevated one as INFO.
- XInput, SDL3 (Xbox + DualSense with gyro, rumble, lightbar), kill-the-feeder
  (~30 ms) and 250-cycle create/destroy all behave as on Windows 10.

### Inference (not measured)

- What a user with **SAC on** would see: a "Part of this app has been blocked"
  style notification, and Longwave's gamepad feature failing because its
  feeder (the host exe, or a helper like `lwpad-devnode`) can't start. Whether
  that happens varies with each build and over time. Signing locally neither
  helps nor hurts that verdict; signing is still needed for the driver
  package itself.
- Users who installed while SAC was in evaluation probably keep working when
  SAC later turns itself on, until a rebuild or update replaces the files.
- No free fix makes SAC trust a local build. SAC has no per-app exception, and
  a self-made certificate isn't a "valid signature" to it. The options are SAC
  off (which this build lets the user undo), or binaries with cloud reputation
  (in practice a publicly trusted signature, i.e. the paid certificate this
  design avoids). Microsoft's file submission portal is per binary, so
  per-user builds can't use it.
- The kernel half is unaffected by SAC: VHF, `WUDFRd` and `xinputhid` are
  Microsoft's, and the UMDF DLL loaded in every run.

## Results: Windows 11 bare metal (HVCI on), 2026-10-05

Log: `evidence/win11-baremetal-2026-10-05.log`.

Baseline: Windows 11 Pro 26H2 build 26300.9457 installed on gaming-pc's own
hardware (Ryzen 5 5600X, RTX 3080). **Memory Integrity (HVCI) running** with VBS,
the first run with it on. **Smart App Control: Evaluation**, Secure Boot on, test
signing off, firewall on, Defender signatures from the same day. Nothing for
development was installed beforehand. The kit was built on that PC from a plain
copy of this folder, the way a user would build it, then installed and tested
there.

### Building it yourself

- **Prerequisites, all non-interactive through winget, ~3 minutes, no reboot:**
  ```powershell
  winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
  winget install --id Microsoft.WindowsWDK.10.0.26100 --exact
  ```
  Build Tools 17.14 took 141 s and the WDK (10.0.26100.6584) 48 s. Together they
  use 6.2 GB. The recommended C++ components already include Windows SDK
  10.0.26100.7705, so `winget install Microsoft.WindowsSDK.10.0.26100` only
  answers "No available upgrade found" (0x8A15002B). That's harmless, but it
  reads like an error. From an elevated shell nothing prompts; from a normal one
  each installer asks UAC once.
- **Installing developer tools did not change Smart App Control.** It stayed in
  evaluation through the installs, the build and every run, and was still there
  at the end.
- `build.ps1` in a **normal, unelevated** PowerShell: ~30 s, clean under
  `/W4 /WX`, InfVerif valid, Inf2Cat fine. (MSVC's `vctip.exe` telemetry helper
  lingers after the build. That only matters to a wrapper that waits for the
  whole process tree.)

### Facts

- **HVCI changes nothing.** The install is silent (6 s, "signed with an
  Authenticode catalog from a trusted publisher") and `WUDFHost.exe` loads the
  driver DLL. No CodeIntegrity 3033/3034/3076/3077 appeared for any kit file in
  any run. The day's only 3004 was for Defender's own `DefenderSessionHelper.exe`.
- **Works and survives a reboot:** the second `-KeepInstalled` run gave 54 PASS
  0 FAIL 2 SKIP. After a graceful reboot, `-AfterReboot` gave 56 PASS 0 FAIL
  0 SKIP, with the device back by itself, then a clean uninstall. That uninstall
  left no node, pad nodes, package, DriverStore folder, DLL, certificate in any
  store, CNG key or task. Early in that boot Kernel-PnP logged event 219 once
  ("`\Driver\WUDFRd` failed to load", 0xC0000365) for our node, which then
  started normally.
- **Sleep with a pad present blue-screened the PC (first driver; fixed since).**
  On the first attempt, someone at the PC chose Sleep from the Start menu (System
  log: `winlogon.exe` called `SetSuspendState`) while the 250-cycle
  create/destroy test was running. Five minutes later the power watchdog
  bugchecked: **0x9F, subcode 3** (`0x9F_3_POWER_DOWN_IMAGE_ntkrnlmp`), with
  Microsoft's `vhf.sys` (10.0.26100.8972) holding the D3 IRP of
  `ROOT\LONGWAVEVIRTUALGAMEPAD\0000`. After the crash the device node and the DLL
  copy were gone, as in the VM's hard reset, but the package and the certificate
  remained, and `uninstall.ps1` removed them cleanly. The cause, the fix and the
  sleep tests are in "Sleep and power" below: any pad that exists when the PC
  sleeps is enough, churn or not.
- First attempt only: **XInput input read zeros** (26 FAIL, and SDL's Xbox input
  too) while the slot appeared and rumble arrived. **Explained since:** Windows
  gives XInput all-zero readings while the console session is **locked**
  (lock screen up), for every process, while slots and rumble keep working.
  The display had timed out and the session locked; the System log shows the
  user waking the display (Kernel-Power 566 `UserDisplayBurst`) a minute before
  choosing Sleep. Reproduced on purpose after a wake from sleep (the session
  locks then): zeros while locked, exact values before. The zeros are also why
  the cycle test was still running a minute later (each cycle's input check
  timed out after 1 s), so it was mid-run when Sleep was chosen.
- **Windows.Gaming.Input unelevated passes whenever its window gets the
  foreground:** input, vibration and impulse triggers, 3 of 3 standalone, 4 of 4
  nested under an elevated parent as the kit does it, and the counted run after
  the reboot. In the second `-KeepInstalled` run the window didn't get the
  foreground, so it was a SKIP. Elevated, vibration still fails as in the VM,
  and input failed once too. The parent calling
  `AllowSetForegroundWindow(ASFW_ANY)` first made it worse (SKIP 4 of 4), so the
  kit is unchanged.
- XInput slot 23-244 ms after create (cycles: mean 8-9 ms), input within
  0.3 ms. Kill-the-feeder 16-48 ms. 250 cycles in 2.8 s with no handle growth
  and +28-116 KB private memory. SDL3 Xbox and DualSense (gyro exact, rumble,
  lightbar) pass as on Windows 10 and in the VM.

### Differences from the VM, and what is still open

- New here: HVCI on (no effect), a real S3 sleep (the VM never slept), and the
  elevated WGI input failure. Same as the VM: SAC evaluation logs nothing for
  our files.
- **Sleep: fixed**, see below.

## Sleep and power (Windows 11 bare metal, 2026-10-05)

Log: `evidence/win11-baremetal-sleep-2026-10-05.log` (dump analysis, every run).
gaming-pc has S3 sleep only (no Modern Standby), so "sleep" here is S3.

### What went wrong

**Any pad that exists when the PC goes to sleep hangs the sleep, and five minutes
later the PC blue-screens** (0x9F, subcode 3, `vhf.sys`). Creating or destroying
pads has nothing to do with it; two idle pads are enough. The live kernel dump
of the first crash shows the chain:

1. For each pad, Microsoft's `VhfUm.dll` (the user-mode side of VHF, loaded in
   our `WUDFHost.exe`) keeps one IOCTL waiting in `vhf.sys`: a "pull request
   notify", the channel for rumble and feature requests coming from games.
2. `vhf.sys` (a KMDF driver, and the power policy owner of our device) receives
   it through a power-managed queue and holds it until a game sends an output
   report. It never releases it on power-down, and that queue has no
   `EvtIoStop`.
3. WDF won't take a device out of D0 while a request from a power-managed queue
   is still outstanding. So `vhf.sys` never finishes its D3, and the power
   manager's watchdog bugchecks the PC.

Our driver didn't hold anything up: it had already passed the power IRP down.
It just let pads exist when `vhf.sys` powered down. libvirtualgamepad and
Vibeshine, where the design came from, have the same exposure: no power
handling, and the same power-managed filter queue.

### The design now

- **No pad outlives D0.** The driver's `EvtDeviceD0Exit` deletes every pad.
  Windows calls it on every way out of the working state (sleep, hibernate,
  shutdown, disable, removal), and it runs *before* the power IRP reaches
  `vhf.sys`. That frees the waiting request: `VhfDelete` cancels it, and
  `vhf.sys` handles the delete directly instead of through its stopped queue.
  Nothing in it waits for PnP, which is frozen during a power transition (both
  from the disassembly, see the log). The HID children are removed when PnP
  runs again, after resume.
- **The feeder can tell, and recreates.** A pad deleted this way keeps its
  owner. That feeder's next request for it fails with **`ERROR_DEVICE_REMOVED`
  (1617)**. It then sends destroy (which succeeds and releases the slot) and
  create again. While the device is out of D0, every create or input request
  fails at once with `ERROR_NOT_READY` (21) instead of waiting out the sleep.
  The stats IOCTL counts these deletions (`pads_lost_to_power`).
- **The driver's queue is no longer power-managed.** WDF's docs say a driver
  above the power policy owner must not use one. Power is handled explicitly
  instead: D0Exit and every VHF call take the same lock, so a create in flight
  finishes before D0Exit deletes it.
- **Create waits for the old child to go.** `VhfDelete` returns once `vhf.sys`
  has marked the child missing, and PnP removes it moments later, or only after
  resume if the delete happened during a sleep. Before creating a pad, the
  driver waits (at most 2 s, then `ERROR_BUSY`) until no HID device ending in
  `&LongwavePad<n>` is present. That way two children with the same instance ID
  never coexist. This is a precaution; it was never observed to break.
- **Host side, as a second line of defence:** a host can register
  `PowerRegisterSuspendResumeNotification`, destroy its pads on
  `PBT_APMSUSPEND` and recreate them on `PBT_APMRESUMEAUTOMATIC`
  (`lwpad-test sleep aware` does exactly this). That makes the driver's deletion
  a no-op. Windows only allows about 2 s for the notification, and it isn't
  guaranteed in every path, so the driver can't rely on it. Recreating on
  `ERROR_DEVICE_REMOVED` is what the host *must* do.

### Results

`run-sleep-test.ps1 -Mode <m>`: real S3 sleep, woken by a 45 s timer. Rows are
in the order run. "Before" is the driver up to commit 8cb1120; "after" is this
version.

| mode | pads during the sleep | before fix | after fix |
|---|---|---|---|
| none | none, driver installed | OK | OK |
| idle | Xbox + DualSense, left alone | **hang, 0x9F_3 after 5 min** | OK, twice. Both pads `ERROR_DEVICE_REMOVED`, recreated 2-8 ms after resume |
| churn | idle pads + a 3rd pad created/destroyed ~70 times/s | not run (idle already hangs) | OK, twice (204 and 217 cycles across the sleep) |
| aware | churn, plus the feeder's own suspend handling | not run | OK, twice. Pads destroyed in 0.7-16 ms before the sleep; the driver had none left to delete |

After every fixed run: no dump, the device node OK, the same `WUDFHost.exe`
process (the driver host never restarted), and new pads appear in XInput within
6-14 ms.

The standard `run-gamepad-spike.ps1` suite on the fixed driver, in the
desktop session: **57 PASS 0 FAIL 0 SKIP**, then a clean uninstall. The 250
create/destroy cycles still average 9 ms (worst 12 ms), so waiting for the old
child costs nothing measurable. The log is section F of the evidence file.

Two things learned along the way:

- **XInput reads all zeros while the console session is locked**, for every
  process. Slots appear and rumble works, but input is blanked. After a wake
  the session is locked (sign-in on wake), so the sleep test reports its XInput
  checks as SKIP then, with the driver's report counter as evidence that the
  HID stack keeps reading. This also explains the first bare-metal run's
  XInput FAILs. For Longwave it means a pad is useless in a locked session
  regardless of the driver, as it is for a physical pad.
- **The second deliberate crash didn't restart by itself** (the first did, in
  ~40 s). The PC stayed off the network, Wake-on-LAN didn't reach it, and
  someone had to power it on. `CrashControl\AutoReboot` was 1. A crash during
  a half-finished S3 is a bad state to recover from: one more reason the hang
  had to go.

Not tested: hibernate (S4), Fast Startup shutdown, Modern Standby (S0ix)
machines. The deletion happens on every D0Exit, so S4 and shutdown go through
the same path. On Modern Standby a plain "sleep" doesn't power the device down
at all, so the pads simply stay up. That is inferred, not measured.

## Licences

`vendor/libvirtualgamepad` is MIT, Copyright (c) 2026 Chase Payne
(https://github.com/Nonary/libvirtualgamepad, commit 4b56fb9). It is vendored
unchanged (`protocol.h`, `ds4_usb.h`, `ds5_usb.h`, `xbox_series.*`,
`dualsense.*`, `dualshock4.*`, `report_pump.*`); its LICENSE is alongside.
`driver.cpp` and the INF are reduced rewrites of its driver and INF and say so.
SDL3 (zlib licence) is downloaded at build time for the test tool only.
