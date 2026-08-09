# Third-Party Notices — Longwave Windows Companion

The Windows companion is a separate codebase from the visionOS app, with its own
dependencies, so it has its own notices. For the visionOS app see
[`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

Three groups, and the distinction matters legally, not just editorially:

1. **[Shipped in the installer](#1-shipped-in-the-installer)** — we redistribute these, so
   their notice requirements bind us.
2. **[Shipped in the PCVR bundle](#2-shipped-in-the-pcvr-bundle-separate-download)** — the
   optional closed-source download, which is a different artifact with different terms.
3. **[Installed on the host by the user](#3-installed-on-the-host-not-redistributed-by-us)** —
   we point at them, script their setup, and in one case publish a patch, but we never
   convey a copy. Listed anyway, because "we don't ship it" is a claim worth being able to
   check.

---

## 1. Shipped in the installer

### Electron — MIT

Copyright (c) Electron contributors · Copyright (c) 2013-2020 GitHub Inc.

The Electron runtime embeds Chromium and Node.js, which carry several hundred further
licenses of their own. Electron ships the complete set as `LICENSES.chromium.html`
(~15 MB) inside its distribution, and electron-builder copies it into the installed
application directory, so the full text is always present next to the binary that needs it.

### OpenPGP.js — LGPL-3.0-or-later

Copyright (c) the OpenPGP.js authors. <https://github.com/openpgpjs/openpgpjs>

Used by `src/pcvr-installer.js` to verify the detached GPG signature on the PCVR bundle
before installing it, rather than shelling out to `gpg.exe` — which end-user Windows
machines generally do not have.

**This is the only copyleft component in the companion, and the only one with obligations
beyond attribution.** They are met as follows:

- **Notice** (LGPL §4a) — this entry, reproduced in the app under *Licences*.
- **License text** (LGPL §4b) — `node_modules/openpgp/LICENSE` ships inside the
  application, unmodified.
- **Source** — OpenPGP.js is conveyed as its own unmodified JavaScript. We have not
  patched it.
- **Right to relink** (LGPL §4d) — the library is loaded with `require` at runtime from an
  `app.asar` archive, which `npx asar extract` unpacks and repacks. Beyond that, the complete
  corresponding source of *this* application is published under the MIT License at
  <https://github.com/illixion/Longwave>, so replacing OpenPGP.js with a modified version
  needs no permission and no reverse engineering — clone, swap, `npm run dist`.

**Rule this creates, worth stating plainly:** OpenPGP.js must stay in the open-source
Electron application and must never be linked into the closed-source PCVR bundle. The two
are separate downloads, separate processes, and separate licences, and that separation is
the whole reason the LGPL is comfortable here. `scripts/package-pcvr-bundle.sh` enforces
this mechanically — it refuses to build a bundle containing a copyleft artifact.

### .NET 8 runtime and libraries — MIT

The backend publishes self-contained, so the .NET runtime ships in the installer.
Copyright (c) .NET Foundation and Contributors.

| Package | License |
|---|---|
| `Microsoft.Extensions.Hosting` | MIT |
| `Microsoft.Extensions.Hosting.WindowsServices` | MIT |
| `Microsoft.Extensions.Logging.EventLog` | MIT |
| `System.ServiceProcess.ServiceController` | MIT |
| `System.Drawing.Common` | MIT |
| `BouncyCastle.Cryptography` | MIT |
| `Vortice.Direct3D11` | MIT |
| `Vortice.MediaFoundation` | MIT |
| `Makaretu.Dns.Multicast.New` | MIT |
| `QRCoder` | MIT |
| `ValveKeyValue` | MIT |

---

## 2. Shipped in the PCVR bundle (separate download)

The PCVR bundle is the optional closed-source component the companion offers to download
(`src/pcvr-installer.js`). It is not part of this installer and not covered by this
repository's MIT license.

### NVIDIA CloudXR SDK redistributable

Subject to the NVIDIA CloudXR SDK License Agreement. Redistribution is permitted for
applications providing material additional functionality (§1.1(c)); Longwave is such an
application. NVIDIA and CloudXR are trademarks of NVIDIA Corporation.

### `LibOVRRT64_1.dll` / `LibOVRRT32_1.dll` — our code, Oculus PC SDK headers

The shim is our own implementation. It is compiled against the Oculus PC SDK C API headers
(`OVR_CAPI.h` and friends, Copyright (c) Facebook Technologies, LLC and its affiliates),
obtained via <https://github.com/mbucchia/LibOVR>, and it exports the CAPI entry points
under the Oculus runtime's own filename because that filename is what the loader searches
for. No Oculus/Meta binary is redistributed — only headers are consumed, at build time.

Why this project touches the Oculus SDK at all, since it is not obvious from the visionOS
side: **the same controller-bridge protocol serves a Meta Quest**. `QuestControllerBridge`
is a real, shipped Quest application — the Quest's own controllers are tracked by the Quest
and handed to the host as emulated controllers, which is the origin of the whole bridge
design and remains a supported configuration, including its cleartext path for a Quest 2 on
a local network. Development for Meta hardware is exactly the use the Oculus PC SDK license
contemplates.

`OVR_CAPI.h` is a stable, published C interface. Nothing here is derived from Oculus
runtime binaries and nothing is reverse-engineered from them.

---

## 3. Installed on the host, not redistributed by us

### VirtualDesktop-OpenXR (VDXR) — MIT

Copyright (c) 2022-2024 Matthieu Bucchianeri.
<https://github.com/mbucchia/VirtualDesktop-OpenXR>

The OpenXR runtime games talk to on a PCVR host. Longwave builds against it unmodified
except for a single-line change published as `ci/patches/vdxr-longwave.patch`, which
disables Vulkan timestamp queries in 32-bit processes where the first timer submission
device-losts. There is no fork: the broker is reached through VDXR's ordinary
`LIBOVR_DLL_DIR` search path, with no patching of VDXR's shipped binaries.

*Virtual Desktop* is a trademark of Guy Godin. Longwave is not affiliated with, endorsed
by, or a product of Virtual Desktop or its author, and does not require Virtual Desktop
itself.

If a future release ever installs or bundles VDXR to reduce setup friction — the current
plan is that a clean Windows install should need no manual steps — this entry must be
accompanied by a verbatim copy of VDXR's `LICENSE`, and by the licenses of everything VDXR
itself bundles: OpenVR (BSD-3-Clause), OpenXR-SDK (Apache-2.0), fmt, FidelityFX CAS/FSR,
cJSON, and `Microsoft.GameInput`, whose redistribution terms need reading before that
happens rather than after.

### OpenComposite — GPL-3.0

<https://gitlab.com/znixian/OpenOVR>

Translates OpenVR calls into OpenXR so an OpenVR-only title can reach a CloudXR session.
`CompanionWindows/scripts/install-opencomposite.ps1` downloads it from upstream onto the
user's own machine; we publish a patch (`CompanionWindows/patches/opencomposite-longwave.patch`)
and a build script, and we convey no binary.

**This is a load-bearing boundary, not an accident.** OpenComposite is GPL-3.0. Bundling
its binaries into the closed-source PCVR bundle would make that bundle a GPL-3.0 combined
work and its source disclosable — which is incompatible with the reason the bundle is
closed at all. Convenience is not worth that, so OpenComposite is fetched, never shipped.
`scripts/package-pcvr-bundle.sh` fails the build if an OpenComposite artifact appears in
the staging tree.

---

*Corrections welcome. If you believe something here is wrong, or that a component is being
redistributed that this file says is not, please open an issue — that is a bug in the same
sense as any other.*
