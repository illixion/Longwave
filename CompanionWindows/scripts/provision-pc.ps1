<#
.SYNOPSIS
  Provision the VisionVNC Windows Companion on the RTX host (runs ON the PC).

.DESCRIPTION
  Invoked by scripts/deploy-windows-companion.sh after the source tree has been
  unpacked into -Root. Publishes the backend, stages the CloudXR SDK bits next to
  it, writes the interactive-session launch helpers, registers the scheduled tasks
  and (unless -NoUi) installs the Electron app's node_modules.

  Everything here is idempotent - re-run it on every iteration.

  Why scheduled tasks: NvStreamManager's RPC TLS key pair is DPAPI-protected, so it
  cannot start from a pubkey-auth SSH session (no unlocked DPAPI master key). The
  tasks run as the logged-on user in the interactive session, which does have one.
#>
[CmdletBinding()]
param(
  [string] $Root = 'C:\dev\VisionVNC-companion',
  # Sibling checkout of the closed-source PCVR host project - absent in a public-only checkout,
  # in which case the PCVR/game-library features simply stay uninstalled (the companion UI
  # already hides them when this pipe never comes up).
  [string] $PcvrHostRoot = 'C:\dev\VisionVNC-PCVR-Host',
  # CloudXR Stream Manager extraction (Server/ + SampleClient/NvStreamManagerClient.dll).
  [string] $StreamManager = 'C:\Users\Ixion\cloudxr-stream-manager_v6.1.0\extracted',
  # Prebuilt hello_xr, kept from the PoC tree - the fallback OpenXR content app.
  [string] $HelloXr = 'C:\dev\VisionVNC-bridge\OpenXRLayer\build-hxr\src\tests\hello_xr\Release\hello_xr.exe',
  # Half-Life 2: VR Mod install dir (OpenVR title, reached via OpenComposite).
  [string] $Hl2Vr = 'C:\Program Files (x86)\Steam\steamapps\common\Half-Life 2 VR',
  [switch] $NoUi,
  [switch] $NoBuild
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$tfm         = 'net8.0-windows10.0.22621.0'
$backend     = Join-Path $Root 'backend'
$publish     = Join-Path $backend "bin\Release\$tfm\publish"
$appDir      = Join-Path $Root 'app'
$toolsDir    = Join-Path $Root 'tools'
$logDir      = Join-Path $Root 'logs'
$exeName     = 'VisionVNCWindowsCompanionBackend.exe'
$pcvrHostHasSource = Test-Path (Join-Path $PcvrHostRoot 'Host.csproj')
$pcvrHostPublish   = Join-Path $PcvrHostRoot "bin\Release\$tfm\publish"
$pcvrHostExeName   = 'VisionVNCPCVRHost.exe'

function Say([string] $m) { Write-Host "[provision] $m" }

New-Item -ItemType Directory -Force -Path $toolsDir, $logDir | Out-Null

# ---------------------------------------------------------------- backend build
# The dotnet on PATH (C:\Program Files\dotnet) is runtime-only on this box - the SDK
# lives user-local. Pick the first candidate that actually reports an installed SDK.
function Resolve-DotnetSdk {
  $candidates = @(
    $env:VISIONVNC_DOTNET,
    (Join-Path $env:USERPROFILE 'dotnet-sdk\dotnet.exe'),
    (Get-Command dotnet -ErrorAction SilentlyContinue).Source,
    'C:\Program Files\dotnet\dotnet.exe'
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

  foreach ($c in $candidates) {
    $sdks = & $c --list-sdks 2>$null
    if ($LASTEXITCODE -eq 0 -and $sdks) { return [pscustomobject]@{ Exe = $c; Sdks = $sdks } }
  }
  throw "no dotnet SDK found (tried: $($candidates -join ', '))"
}

if (-not $NoBuild) {
  $sdk = Resolve-DotnetSdk
  $dotnet = $sdk.Exe
  Say "publishing backend with $dotnet ($($sdk.Sdks -join '; '))"
  # A user-local SDK needs DOTNET_ROOT so the host resolves its own frameworks.
  $env:DOTNET_ROOT = Split-Path $dotnet -Parent

  & $dotnet publish (Join-Path $backend 'Backend.csproj') `
      -c Release -r win-x64 --self-contained true --nologo -o $publish
  if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }

  if (-not (Test-Path (Join-Path $publish $exeName))) { throw "publish produced no $exeName" }
  Say "published -> $publish"

  if ($pcvrHostHasSource) {
    Say "publishing PCVR host with $dotnet"
    & $dotnet publish (Join-Path $PcvrHostRoot 'Host.csproj') `
        -c Release -r win-x64 --self-contained true --nologo -o $pcvrHostPublish
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish (PCVR host) failed ($LASTEXITCODE)" }
    if (-not (Test-Path (Join-Path $pcvrHostPublish $pcvrHostExeName))) {
      throw "publish produced no $pcvrHostExeName"
    }
    Say "published -> $pcvrHostPublish"
  } else {
    Say "$PcvrHostRoot has no Host.csproj - skipping (public-only checkout; PCVR/games stay uninstalled)"
  }
}

# ------------------------------------------------------- stage the CloudXR bits
# CloudXRController now lives in the PCVR host project, so that is where these bits belong -
# the public backend no longer probes for any of them. Falls back to $publish only when the
# host project isn't checked out at all, so an old-style single-exe layout still degrades
# gracefully rather than silently staging nothing.
$cloudXrTarget = if ($pcvrHostHasSource) { $pcvrHostPublish } else { $publish }
$smServer = Join-Path $StreamManager 'Server'
$smDll    = Join-Path $StreamManager 'SampleClient\NvStreamManagerClient.dll'

if (Test-Path $smServer) {
  Say "staging CloudXR Server/ from $smServer -> $cloudXrTarget"
  # /XO would skip newer-on-dest; plain mirror-without-purge keeps any local
  # cloudxr-runtime.yaml edits from being clobbered only if they are newer.
  robocopy $smServer (Join-Path $cloudXrTarget 'Server') /E /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy of Server/ failed ($LASTEXITCODE)" }
} else {
  Write-Warning "CloudXR Stream Manager not found at $smServer - PCVR host will run in degraded (no-CloudXR) mode"
}

if (Test-Path $smDll) {
  # A running host holds this DLL open, so re-staging it would fail a script-only deploy for
  # no reason. Skip when it is already identical, and downgrade a lock to a warning.
  $dest = Join-Path $cloudXrTarget 'NvStreamManagerClient.dll'
  $same = (Test-Path $dest) -and
          ((Get-FileHash $smDll).Hash -eq (Get-FileHash $dest).Hash)
  if ($same) {
    Say 'NvStreamManagerClient.dll already current'
  } else {
    try {
      Copy-Item $smDll $dest -Force -ErrorAction Stop
      Say 'staged NvStreamManagerClient.dll'
    } catch {
      Write-Warning ("could not stage NvStreamManagerClient.dll (in use?): " + $_.Exception.Message +
                     " - stop the PCVR host and re-run if it needs updating")
    }
  }
} else {
  Write-Warning "NvStreamManagerClient.dll not found at $smDll"
}

# Discover the runtime manifest we will point ActiveRuntime at.
$runtimeJson = Get-ChildItem (Join-Path $cloudXrTarget 'Server\releases') -Recurse -Filter 'openxr_cloudxr.json' `
                 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if ($runtimeJson) { Say "CloudXR OpenXR runtime: $runtimeJson" }
else { Write-Warning 'no openxr_cloudxr.json under Server/releases - set ActiveRuntime manually' }

# ----------------------------------------------------- OpenXR runtime selection
# THE MACHINE DEFAULT BELONGS TO GAMES, and the broker - the one process that must reach
# CloudXR - carries an explicit XR_RUNTIME_JSON of its own (app/src/supervisor.js, and
# start-broker.bat for the headless path).
#
# It used to be the other way round, with a machine-level XR_RUNTIME_JSON pointing games at
# VDXR and the registry naming CloudXR. That is broken by design and it bit on 2026-07-28: a
# machine environment variable only reaches a process whose parent already had it, and
# Explorer had been running for eight days before the variable was set. So anything launched
# from the desktop or from Steam inherited a stale environment, fell through to the registry,
# and landed on CloudXR - which already holds the broker's session and permits only one. The
# symptoms were hello_xr exiting immediately with code 1 and Alyx failing xrCreateSession
# with XR_ERROR_LIMIT_REACHED, neither of which points anywhere near an environment variable.
# The registry needs no inheritance and cannot go stale, which is why it is the right home
# for the value every app should get.
#
# But the value is NOT set here. ActiveRuntime is global, so holding it permanently would
# hijack SteamVR with another headset on this same PC. The companion app claims it when the
# PCVR stack starts and hands it back when the stack stops or the app quits. What provisioning
# does instead is grant this user SetValue on that one key, so claiming needs no elevation and
# therefore no consent prompt every session. A per-user HKCU override would have avoided even
# this, but the loader ignores it - measured 2026-07-28: with HKLM naming CloudXR and HKCU
# naming VDXR, hello_xr loaded CloudXR.
$envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
if ((Get-ItemProperty $envKey).PSObject.Properties.Name -contains 'XR_RUNTIME_JSON') {
  Remove-ItemProperty -Path $envKey -Name 'XR_RUNTIME_JSON' -ErrorAction SilentlyContinue
  Say 'removed the machine-wide XR_RUNTIME_JSON (the broker sets its own)'
}
try {
  # By SID, for the same reason the scheduled tasks use one: USERDOMAIN is "WORKGROUP" on
  # this box and has no SID mapping.
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
  $khronos = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
    'SOFTWARE\Khronos\OpenXR\1',
    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
    [System.Security.AccessControl.RegistryRights]::ChangePermissions)
  if ($khronos) {
    $acl = $khronos.GetAccessControl()
    # WriteKey, not SetValue: reg.exe opens the key with KEY_WRITE, which also demands
    # CreateSubKey. Granting SetValue alone looks sufficient and fails with a bare
    # "Command failed" from reg add. Measured 2026-07-28.
    $acl.SetAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
      $me, 'WriteKey', 'Allow')))
    $khronos.SetAccessControl($acl)
    $khronos.Close()
    Say 'granted this user WriteKey on HKLM\SOFTWARE\Khronos\OpenXR\1 (the app claims the runtime while hosting)'
  } else {
    Write-Warning 'HKLM\SOFTWARE\Khronos\OpenXR\1 is absent - install an OpenXR runtime first'
  }
} catch {
  Write-Warning ('could not grant runtime-key access: ' + $_.Exception.Message)
}

# ------------------------------------------------------------------ Electron UI
# On this box the electron postinstall downloads its 130 MB zip fine but its unzip dies
# partway through (dist/ ends up holding a single locales/*.pak) and still exits 0, so
# `npm start` fails with "Electron failed to install correctly". Re-extract the cached
# zip with tar.exe, which handles it reliably.
function Repair-ElectronDist([string] $appRoot) {
  $pkgDir = Join-Path $appRoot 'node_modules\electron'
  if (-not (Test-Path $pkgDir)) { return }

  $dist = Join-Path $pkgDir 'dist'
  if (Test-Path (Join-Path $dist 'electron.exe')) { Say 'electron dist OK'; return }

  $ver = (Get-Content (Join-Path $pkgDir 'package.json') -Raw | ConvertFrom-Json).version
  $zip = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'electron\Cache') -Recurse -File `
           -Filter "electron-v$ver-win32-x64.zip" -ErrorAction SilentlyContinue | Select-Object -First 1

  if (-not $zip) {
    # Nothing cached - let the postinstall fetch it, then extract ourselves.
    Say "electron $ver zip not cached; running install.js to download"
    Push-Location $pkgDir
    try { & node.exe install.js | Out-Null } finally { Pop-Location }
    $zip = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'electron\Cache') -Recurse -File `
             -Filter "electron-v$ver-win32-x64.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $zip) { throw "could not obtain electron-v$ver-win32-x64.zip" }
  }

  Say "re-extracting electron $ver from $($zip.Name)"
  Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $dist | Out-Null
  Push-Location $dist
  try {
    tar.exe -xf $zip.FullName
    if ($LASTEXITCODE -ne 0) { throw "tar extract of electron failed ($LASTEXITCODE)" }
  } finally { Pop-Location }

  if (-not (Test-Path (Join-Path $dist 'electron.exe'))) { throw 'electron.exe still missing after extract' }
  # index.js reads path.txt to locate the binary.
  Set-Content -Path (Join-Path $pkgDir 'path.txt') -Value 'electron.exe' -Encoding ASCII -NoNewline
  Say 'electron dist repaired'
}

if (-not $NoUi) {
  if (Test-Path (Join-Path $appDir 'package.json')) {
    Say 'npm install (Electron app)'
    Push-Location $appDir
    try {
      & npm.cmd install --no-audit --no-fund
      if ($LASTEXITCODE -ne 0) { throw "npm install failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
    Repair-ElectronDist $appDir
  } else {
    Write-Warning "no app/package.json under $appDir - skipping UI install"
  }
}

# ------------------------------------------------------------- launch helpers
# The UI runs elevated and spawns the backend itself (see app/src/main.js), so the
# normal path is one task. The headless bat stays for diagnostics.
$bats = @{
  'start-companion-ui.bat' = @"
@echo off
rem VisionVNC Windows Companion - Electron UI (spawns the backend itself).
cd /d "$appDir"
rem Windows redirect handles leak to every descendant of a run (Steam, launched
rem de-elevated by the backend, is the long-lived one), and cmd opens the log
rem without write sharing - so a previous run's leaked handle would fail THIS
rem redirect and the task would die with 'file in use'. Fall back to a fresh
rem name instead of refusing to start.
set "LOG=$logDir\companion-ui.log"
del "%LOG%" >nul 2>&1
if exist "%LOG%" set "LOG=$logDir\companion-ui-%RANDOM%.log"
npm.cmd start > "%LOG%" 2>&1
"@

  # Full host mode (no args): serves the public named pipe (hotspot, native screen streaming),
  # so it can be driven over SSH with no GUI at all.
  'start-backend.bat' = @"
@echo off
rem Backend in normal host mode - named pipe available, no Electron UI.
cd /d "$publish"
"$publish\$exeName" > "$logDir\backend.log" 2>&1
"@

  'start-cxr-service.bat' = @"
@echo off
rem Pre-start the CXR service before the backend grabs the RPC pipe.
cd /d "$StreamManager\SampleClient"
SampleNvStreamManagerClient.exe StartCxrService 6.2.1 > "$logDir\cxr-service.log" 2>&1
"@

  # Left on hello_xr's default AppSpace ("Local") on purpose: the layer now anchors bridge
  # poses to STAGE and asks the runtime for base_from_anchor, so it converts into whatever
  # space the app chose. Local is the interesting case (non-identity conversion) and what most
  # games use, so this doubles as the regression test for that path. An earlier `-s Stage`
  # here was papering over the layer anchoring to LOCAL while the sender reports floor-relative
  # ARKit poses - that combination put the hand cubes ~1 m above the user's head.
  'start-helloxr.bat' = @"
@echo off
rem Fallback native-OpenXR content app, rendered into whatever ActiveRuntime is.
set VISIONVNC_CB_LAYER_LOG=$logDir\cb_layer.log
"$HelloXr" -g D3D11 > "$logDir\helloxr.log" 2>&1
"@

  # Half-Life 2: VR Mod is OpenVR-only, so it reaches the CloudXR runtime via OpenComposite's
  # OpenVR->OpenXR translation (pcvr-session.ps1 points openvrpaths.vrpath at it).
  #
  # Launch the exe DIRECTLY rather than steam://rungameid/658920: Steam treats the app as a VR
  # title and runs SteamVR as a pre-launch step, and vrserver then prepends itself to
  # openvrpaths.vrpath - so the game resolves OpenVR to SteamVR, finds no headset, and dies with
  # "Hmd not found". The game's steam_appid.txt lets it init the Steam API without the launcher.
  # The entry point is the mod's own hlvr.bat (which runs `hl2.exe -game hlvr` with its DXVK and
  # resolution params) - hl2vr.exe on its own exits immediately.
  'start-hl2vr.bat' = @"
@echo off
cd /d "$Hl2Vr"
call hlvr.bat
"@
}

if ($pcvrHostHasSource) {
  # Full host mode (no args): serves the PCVR pipe (Foveated/Games), independent of the
  # public backend's pipe and process.
  $bats['start-pcvr-host.bat'] = @"
@echo off
rem PCVR host in normal mode - named pipe available, no companion UI.
cd /d "$pcvrHostPublish"
"$pcvrHostPublish\$pcvrHostExeName" > "$logDir\pcvr-host.log" 2>&1
"@

  $bats['start-foveated-headless.bat'] = @"
@echo off
rem Headless CLI mode: session-management host only. No pipe, no QR window.
cd /d "$pcvrHostPublish"
"$pcvrHostPublish\$pcvrHostExeName" --foveated > "$logDir\foveated-host.log" 2>&1
"@
}

foreach ($name in $bats.Keys) {
  $path = Join-Path $toolsDir $name
  Set-Content -Path $path -Value $bats[$name] -Encoding ASCII
  Say "wrote $name"
}

# --------------------------------------------------------------- schedule tasks
# Registered against the logged-on user so they land in the interactive session.
# Use the account SID, not "$env:USERDOMAIN\$env:USERNAME": on this workgroup box
# USERDOMAIN is literally "WORKGROUP", which has no SID mapping, and the task
# registration fails with "No mapping between account names and security IDs".
$who = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Say "registering tasks for $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) ($who)"

function Register-Helper([string] $taskName, [string] $bat, [string] $runLevel) {
  $action    = New-ScheduledTaskAction -Execute (Join-Path $toolsDir $bat) -WorkingDirectory $toolsDir
  $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel $runLevel
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
    -Settings $settings -ErrorAction Stop `
    -Description 'VisionVNC PCVR host helper (deployed by provision-pc.ps1)' -Force | Out-Null
  Say "task $taskName -> $bat ($runLevel)"
}

# Limited throughout. Elevation used to be blanket, for one feature (Mobile Hotspot), and it
# cost more than it bought: the OpenXR loader ignores XR_RUNTIME_JSON in an elevated process, so
# an elevated broker could only be steered by the machine registry default - the very setting
# games want for themselves - and every game had to be de-elevated by hand on the way out.
# Tethering now elevates on demand (the backend spawns itself with --tether-host via "runas"), so
# nothing here needs to start elevated. Measured unelevated on the RTX host 2026-07-28:
# NvStreamManager, CloudXrService and the session broker all run at medium integrity, and the
# broker picked CloudXR up through XR_RUNTIME_JSON.
Register-Helper 'VisionVNC-CompanionUI'      'start-companion-ui.bat'      'Limited'
Register-Helper 'VisionVNC-Backend'          'start-backend.bat'           'Limited'
Register-Helper 'VisionVNC-CxrService'       'start-cxr-service.bat'       'Limited'
Register-Helper 'VisionVNC-HelloXR'          'start-helloxr.bat'           'Limited'
# Steam refuses to launch a game from an elevated process.
Register-Helper 'VisionVNC-HL2VR'            'start-hl2vr.bat'             'Limited'

if ($pcvrHostHasSource) {
  Register-Helper 'VisionVNC-PCVRHost'          'start-pcvr-host.bat'          'Limited'
  Register-Helper 'VisionVNC-FoveatedHeadless'  'start-foveated-headless.bat'  'Limited'
} else {
  foreach ($obsolete in @('VisionVNC-PCVRHost', 'VisionVNC-FoveatedHeadless')) {
    if (Get-ScheduledTask -TaskName $obsolete -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $obsolete -Confirm:$false -ErrorAction SilentlyContinue
      Say ("removed $obsolete task (no PCVR host source checked out)")
    }
  }
}

# The broker and the sidecar are the companion app's own children now (app/src/supervisor.js),
# so their tasks are removed rather than left as a second way to start the same thing. Two
# mechanisms is not a fallback, it is a trap: a task-started broker holds logs\broker.log open,
# so the app's attempt to start its own fails on the log, exits, gets restarted, and the restart
# counter climbs while a perfectly good session carries on running behind it. Observed 2026-07-28.
foreach ($obsolete in @('VisionVNC-Broker', 'VisionVNC-Sidecar')) {
  if (Get-ScheduledTask -TaskName $obsolete -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $obsolete -Confirm:$false -ErrorAction SilentlyContinue
    Say ("removed obsolete task " + $obsolete + " (the companion app supervises this now)")
  }
}

# ------------------------------------------------------------------- firewall
# WSS signaling + media, plus the Apple session-management port.
foreach ($rule in @(
  @{ Name = 'VisionVNC session management (TCP 55000)'; Proto = 'TCP'; Port = 55000 },
  @{ Name = 'CloudXR signaling (TCP 48322)';            Proto = 'TCP'; Port = 48322 },
  @{ Name = 'CloudXR media (UDP 47998)';                Proto = 'UDP'; Port = 47998 },
  # Controller bridge: the OpenXR API layer's UDP receiver. Without this the headset's
  # cb_input_state_t packets are dropped at the firewall and the layer never goes active -
  # the local feeder works regardless, which makes it an easy blocker to miss. The haptic
  # return path (UDP 9521 back to the sender) is outbound and needs no rule.
  @{ Name = 'VisionVNC controller bridge (UDP 9520)';   Proto = 'UDP'; Port = 9520 },
  # Game library RPC. The CloudXR message channel only carries the rendezvous (the host's
  # addresses plus a session token) because a channel connection lasts about twelve seconds;
  # the library itself runs here. Blocked, the headset gets the token, probes every announced
  # address, and reports the PC unreachable - with the session and video working fine.
  @{ Name = 'VisionVNC game library (UDP 9522)';        Proto = 'UDP'; Port = 9522 },
  # The control stream: everything on the bridge except the poses (game library, perf feed,
  # telemetry, haptics, tuning). This one is inbound TCP, which no earlier rule covered, and
  # the failure it causes is quiet and misleading - the session, the video and the wrist HUD
  # all keep working (the HUD falls back to the UDP return path) while the Games tab simply
  # never loads and the broker logs a listener with nobody connected. Observed 2026-07-29,
  # within an hour of the port existing.
  @{ Name = 'VisionVNC bridge control (TCP 9523)';      Proto = 'TCP'; Port = 9523 }
)) {
  if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow `
      -Protocol $rule.Proto -LocalPort $rule.Port -Profile Any | Out-Null
    Say ("firewall + " + $rule.Name)
  }
}

# -------------------------------------------------- diagnostic env vars OFF
# NV_CXR_ENABLE_FOVEATION_VISUALIZATION draws CloudXR's foveal inset as a yellow
# rectangle over everything, which makes judging image quality by eye impossible. It
# was useful once for proving the fovea tracks gaze; the broker now logs the pivot
# numerically, so it is pure noise. Asserted off rather than merely "not set": it was
# turned on by hand during bring-up and left on for days, and nothing about the
# symptom (a box on screen) points at an environment variable. Read at process start,
# so clearing it takes effect on the next broker start.
$envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
foreach ($name in @('NV_CXR_ENABLE_FOVEATION_VISUALIZATION')) {
  if ((Get-ItemProperty $envKey).PSObject.Properties.Name -contains $name) {
    Remove-ItemProperty -Path $envKey -Name $name -ErrorAction SilentlyContinue
    Say ("cleared diagnostic env var " + $name)
  }
}

# A desktop shortcut, since launching the companion by hand is the normal way in: the app
# supervises the PCVR services itself, so starting it is the whole bring-up.
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'VisionVNC Companion.lnk'
$electron = Join-Path $Root 'app\node_modules\electron\dist\electron.exe'
if ((Test-Path $electron) -and -not (Test-Path $desktopLink)) {
  try {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($desktopLink)
    $link.TargetPath = $electron
    $link.Arguments = '.'
    $link.WorkingDirectory = Join-Path $Root 'app'
    $link.Description = 'VisionVNC Windows Companion'
    $link.Save()
    Say 'created the desktop shortcut'
  } catch {
    Say ('could not create the desktop shortcut: ' + $_.Exception.Message)
  }
}

# Any desktop shortcut to the companion must NOT be marked "Run as administrator".
# This cost an hour on 2026-07-28. The flag was a leftover from when the backend needed
# admin; with it set, Explorer elevates the UI, the UI's backend inherits that, and so do
# NvStreamManager and CloudXrService — which then create \\.\pipe\...\ipc_cloudxr with an
# Administrators DACL that the unelevated broker cannot open. CloudXR's runtime (which is
# Monado-derived) then reports "please make sure that the service process is running" and
# xrCreateInstance returns -51, so every symptom points at a missing runtime rather than at
# a shortcut. The flag lives in bit 0x20 of byte 21 of the .lnk and there is no COM property
# for it, hence the byte edit.
foreach ($desktop in @([Environment]::GetFolderPath('Desktop'), 'C:\Users\Public\Desktop')) {
  if (-not (Test-Path $desktop)) { continue }
  foreach ($link in (Get-ChildItem $desktop -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
    try {
      $bytes = [System.IO.File]::ReadAllBytes($link.FullName)
      if ($bytes.Length -lt 22 -or -not ($bytes[21] -band 0x20)) { continue }
      $shell = New-Object -ComObject WScript.Shell
      $target = $shell.CreateShortcut($link.FullName).TargetPath
      if ($target -notmatch 'VisionVNC|electron') { continue }
      $bytes[21] = $bytes[21] -band (-bnot 0x20)
      [System.IO.File]::WriteAllBytes($link.FullName, $bytes)
      Say ("cleared the run-as-administrator flag on " + $link.Name)
    } catch {
      Say ("could not check " + $link.Name + ": " + $_.Exception.Message)
    }
  }
}

Say 'done.'
[pscustomobject]@{
  Root         = $Root
  Publish      = $publish
  BackendExe   = Join-Path $publish $exeName
  PcvrHostExe  = if ($pcvrHostHasSource) { Join-Path $pcvrHostPublish $pcvrHostExeName } else { '(not installed)' }
  RuntimeJson  = $runtimeJson
  Tools        = $toolsDir
  Logs         = $logDir
} | Format-List | Out-String | Write-Host
