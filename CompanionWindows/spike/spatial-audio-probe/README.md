# spatial-audio-probe

A pass-through diagnostic DLL that logs how a game uses Windows Spatial Sound
(`ISpatialAudioClient`, "ISAC") and plain WASAPI. Built to answer one question about
Cyberpunk 2077 (Wwise): **does it render a 7.1.4 bed, dynamic audio objects, or both,
and how many objects are live at once?** That decides how the PCVR / Moonlight audio
path should carry game audio to the headset.

Nothing is wrapped or changed. MinHook detours each method in place, the original is
called with the caller's exact arguments, and its result is returned untouched.

## What it logs

Written to `spatial_audio_probe.log` next to the DLL. The file is appended to, with a
`====` header per process launch.

- **Every `IMMDevice::Activate`**: the IID (named when known: IAudioClient,
  ISpatialAudioClient, IAudioEndpointVolume, IDirectSound, …), the endpoint's friendly
  name and id, the HRESULT, and the caller as `module+offset`. The caller field tells
  the game apart from audioware, RED4ext and system DLLs. `ActivateAudioInterfaceAsync`
  calls are logged too.
- **ISAC capabilities**, dumped when an ISAC is activated: the native static mask,
  `GetMaxDynamicObjectCount`, stream availability, the supported object formats with
  max frame count, and `GetStaticObjectPosition` for each native channel. The game's own
  calls to `GetMaxDynamicObjectCount`, `IsAudioObjectFormatSupported` and
  `IsSpatialAudioStreamAvailable` are logged, capped at 200 lines.
- **`ActivateSpatialAudioStream`**: the requested interface (plain or `ForMetadata`) and
  the decoded activation blob: object format, `StaticObjectTypeMask` (with bit names and
  layout recognition, e.g. `0x1FFE (=7.1.4)`), min/max dynamic object count, category,
  the event handle, and the metadata or `Params2` options fields when present.
- **Per stream, once per second**: number of updates, frames per update, the
  available-dynamic-object range, static/dynamic activations (and failures, e.g.
  `NO_MORE_OBJECTS`), `SetEndOfStream` count, `SetPosition` calls, and two histograms:
  dynamic objects per update, and audible dynamic objects per update. Also the peak level
  (dBFS) per bed channel and for dynamic objects, plus the 8 loudest dynamic objects
  with position, distance, volume and peak. Buffers are measured in
  `EndUpdatingAudioObjects`, after the game has filled them. Nothing is logged per
  update.
- **`IAudioClient::Initialize`, `IAudioClient3::InitializeSharedAudioStream`,
  `IsFormatSupported`, `GetMixFormat`**: the full `WAVEFORMATEXTENSIBLE` (channels, rate,
  float or PCM, channel mask decoded). This covers the non-spatial fallback, and any other
  WASAPI user in the process such as audioware or video playback.

Coordinates are ISAC's: metres, x = right, y = up, **−z = in front of the listener**.
`AudioObjectType` bits: Dynamic = bit 0, FL…TBR = bits 1–12, so **7.1.4 = `0x1FFE`**
and **8.1.4.4 = `0x3FFFE`** (the full native mask on Windows 10).

## How it's loaded (Cyberpunk 2077)

The GOG install at `D:\Games\Cyberpunk 2077` already has two loaders:
- `bin\x64\version.dll`, Ultimate ASI Loader 6.0 (shipped with Cyber Engine Tweaks).
  `global.ini` sets `LoadFromScriptsOnly=1`, so it loads `*.asi` from
  `bin\x64\plugins\`, where `cyber_engine_tweaks.asi` lives.
- `bin\x64\winmm.dll`, the RED4ext loader.

So the probe is just `bin\x64\plugins\spatial_audio_probe.asi`. That adds one file and
replaces none, and the probe is one more ASI next to CET. The DLL does nothing inside
`REDEngineErrorReporter.exe`.

At load it hooks only `combase!CoCreateInstance(Ex)`. The first time
`MMDeviceEnumerator` is created, it reads `IMMDevice`'s vtable from the default endpoint
and hooks `Activate`. Everything further down is hooked lazily, the first time the game
hands back that kind of object. Hooks are queued and applied as a batch, because each
MinHook enable freezes every thread in the process (about 15 ms here), and object hooks
are installed on the audio thread. If a hook can't be installed, that is logged and the
probe carries on.

## Build (on the Windows PC)

Needs VS 2022 Build Tools (x64 C++) and git. Run:

```powershell
.\build.ps1        # clones MinHook v1.3.4 into third_party\, builds build\spatial_audio_probe.asi + build\probe_harness.exe
```

## Test without the game

```powershell
build\probe_harness.exe --list                                   # spatial state of each render endpoint (read-only)
build\probe_harness.exe "$PWD\build\spatial_audio_probe.asi"    # load the probe, drive the hooked paths
Get-Content build\spatial_audio_probe.log
```

The harness loads the probe the same way the ASI loader does. It then runs plain
WASAPI (mix format plus a shared `Initialize`) and ISAC: capabilities, then a 7.1.4 bed
plus up to 4 dynamic objects for about 2 s at −60 dBFS, with the dynamic objects
orbiting. `maxDynamicObjects=0` means no spatial format is enabled on that endpoint.

## Install / uninstall

```powershell
.\install.ps1      # [-Game "D:\Games\Cyberpunk 2077"]  copies the .asi into bin\x64\plugins (backs up an existing one)
.\uninstall.ps1    # removes it (restores a backup if there was one); add -RemoveLog to delete the log too
```

`install.ps1` also drops a copy of the uninstaller next to the DLL, as
`bin\x64\plugins\spatial_audio_probe_uninstall.ps1`.
