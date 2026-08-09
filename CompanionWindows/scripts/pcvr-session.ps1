<#
.SYNOPSIS
  Flip the RTX host between "normal desktop" and "PCVR streaming host" (runs ON the PC).

.DESCRIPTION
  A foveated CloudXR session needs three global bits of machine state changed, and
  every one of them has to be put back afterwards:

    1. HKLM\SOFTWARE\Khronos\OpenXR\1\ActiveRuntime -> openxr_cloudxr.json.
       The OpenXR loader ignores XR_RUNTIME_JSON under elevation, so the env var is
       not an option - it must be the registry key.
    2. %LOCALAPPDATA%\openvr\openvrpaths.vrpath "runtime" -> OpenComposite.
       CloudXR 6.2 ships no OpenVR/SteamVR driver, so an OpenVR title (Half-Life 2 VR)
       reaches the CloudXR runtime only through OpenComposite's OpenVR->OpenXR
       translation. SteamVR/vrserver stays out of the picture entirely.
    3. SunshineService stopped. Sunshine holds an NVENC session and the RTX 3080 caps
       concurrent sessions; CloudXR's four foveated streams + Sunshine exhaust it and
       the session dies ~3 s in with NVST_R_BUSY (Enqueued:4 Encoded:0).

  `-Mode start` records the previous values under HKCU\Software\Longwave\PcvrSession
  before changing anything; `-Mode stop` restores from that record (and falls back to
  the well-known SteamVR paths if the record is missing).

.EXAMPLE
  pcvr-session.ps1 -Mode start
  pcvr-session.ps1 -Mode status
  pcvr-session.ps1 -Mode stop
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('start', 'stop', 'status')] [string] $Mode,
  [string] $Root = 'C:\dev\Longwave-companion',
  # Sibling checkout of the closed-source PCVR host - where CloudXR is staged now
  # (CloudXRController moved there with the rest of Foveated/).
  [string] $PcvrHostRoot = 'C:\dev\Longwave-PCVR-Host',
  [string] $OpenComposite = 'C:\dev\OpenComposite',
  [string] $SteamVr = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR',
  # Leave OpenVR pointed at SteamVR (native-OpenXR content only, e.g. hello_xr).
  [switch] $NoOpenComposite,
  # Leave Sunshine running (only safe if nothing else is encoding).
  [switch] $KeepSunshine
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$xrKey    = 'HKLM:\SOFTWARE\Khronos\OpenXR\1'
$stateKey = 'HKCU:\Software\Longwave\PcvrSession'
$vrPath   = Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'

function Say([string] $m) { Write-Host "[pcvr] $m" }

function Get-ActiveRuntime {
  try { (Get-ItemProperty $xrKey -Name ActiveRuntime -ErrorAction Stop).ActiveRuntime } catch { $null }
}

function Set-ActiveRuntime([string] $json) {
  if (-not (Test-Path $xrKey)) { New-Item -Path $xrKey -Force | Out-Null }
  Set-ItemProperty -Path $xrKey -Name ActiveRuntime -Value $json -Type String
}

function Get-VrRuntimePath {
  if (-not (Test-Path $vrPath)) { return $null }
  try { (Get-Content $vrPath -Raw | ConvertFrom-Json).runtime | Select-Object -First 1 } catch { $null }
}

function Set-VrRuntimePath([string] $dir, [bool] $lock = $false) {
  # openvrpaths.vrpath is how every OpenVR app finds its runtime; rewrite just the
  # "runtime" array and leave config/log/external_drivers alone.
  #
  # The array is ORDERED and an OpenVR app takes the first entry that resolves. SteamVR's
  # vrpathreg *prepends* SteamVR to this list every time vrserver starts, which silently
  # demotes OpenComposite - the observed symptom is the game reporting "Hmd not found",
  # because it reached SteamVR (which has no headset) instead of the CloudXR runtime. So
  # write a single entry, and optionally mark the file read-only so SteamVR cannot re-add
  # itself behind our back.
  if (Test-Path $vrPath) {
    Set-ItemProperty $vrPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    $doc = Get-Content $vrPath -Raw | ConvertFrom-Json
  } else {
    New-Item -ItemType Directory -Force -Path (Split-Path $vrPath) | Out-Null
    $doc = [pscustomobject]@{
      config = @("C:\Program Files (x86)\Steam\config"); external_drivers = $null
      jsonid = 'vrpathreg'; log = @("C:\Program Files (x86)\Steam\logs")
      runtime = @(); version = 1
    }
  }
  $doc.runtime = @($dir)
  $doc | ConvertTo-Json -Depth 6 | Set-Content -Path $vrPath -Encoding UTF8
  if ($lock) {
    Set-ItemProperty $vrPath -Name IsReadOnly -Value $true
    Say 'openvrpaths.vrpath locked read-only (stops SteamVR re-registering itself)'
  }
}

function Stop-SteamVr {
  # vrserver must not be running: it re-registers itself as the OpenVR runtime, and an
  # OpenVR title that reaches it finds no HMD. Nothing in the CloudXR path needs SteamVR.
  $procs = Get-Process vrmonitor, vrserver, vrcompositor, vrdashboard, vrwebhelper, vrserverhelper `
             -ErrorAction SilentlyContinue
  if (-not $procs) { return }
  # vrmonitor first - it restarts vrserver if killed in the other order.
  foreach ($name in 'vrmonitor', 'vrdashboard', 'vrcompositor', 'vrwebhelper', 'vrserverhelper', 'vrserver') {
    Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 2
  Say "stopped SteamVR ($($procs.Count) processes)"
}

function Find-CloudXrRuntime {
  $roots = @(
    (Join-Path $PcvrHostRoot 'bin\Release\net8.0-windows10.0.22621.0\publish\Server\releases'),
    # Old single-exe layout, kept as a fallback for a not-yet-redeployed host.
    (Join-Path $Root 'backend\bin\Release\net8.0-windows10.0.22621.0\publish\Server\releases'),
    'C:\Users\Ixion\cloudxr-stream-manager_v6.1.0\extracted\Server\releases'
  )
  foreach ($r in $roots) {
    $hit = Get-ChildItem $r -Recurse -Filter 'openxr_cloudxr.json' -ErrorAction SilentlyContinue |
             Sort-Object FullName -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $null
}

switch ($Mode) {

  'status' {
    [pscustomobject]@{
      ActiveRuntime    = Get-ActiveRuntime
      OpenVrRuntime    = Get-VrRuntimePath
      SunshineService  = (Get-Service SunshineService -ErrorAction SilentlyContinue).Status
      Tailscale        = (Get-Service Tailscale -ErrorAction SilentlyContinue).Status
      CloudXrRuntime   = Find-CloudXrRuntime
      OpenCompositeDll = Test-Path (Join-Path $OpenComposite 'bin\win64\vrclient_x64.dll')
      Saved            = if (Test-Path $stateKey) { Get-ItemProperty $stateKey } else { 'none' }
      Backend          = @(Get-Process LongwaveCompanionBackend, LongwavePCVRHost, NvStreamManager, electron -ErrorAction SilentlyContinue |
                            Select-Object -ExpandProperty ProcessName)
    } | Format-List
  }

  'start' {
    $cloudxr = Find-CloudXrRuntime
    if (-not $cloudxr) { throw 'no openxr_cloudxr.json found - is the Stream Manager staged?' }

    # Snapshot first, and never overwrite an existing snapshot (a second `start`
    # would otherwise record the CloudXR values as the "previous" ones).
    if (-not (Test-Path $stateKey)) { New-Item -Path $stateKey -Force | Out-Null }
    if (-not (Get-ItemProperty $stateKey -Name PrevActiveRuntime -ErrorAction SilentlyContinue)) {
      Set-ItemProperty $stateKey -Name PrevActiveRuntime -Value ([string](Get-ActiveRuntime))
      Set-ItemProperty $stateKey -Name PrevOpenVrRuntime -Value ([string](Get-VrRuntimePath))
      Set-ItemProperty $stateKey -Name PrevSunshine -Value ([string](Get-Service SunshineService -ErrorAction SilentlyContinue).Status)
      Say 'snapshotted previous state'
    } else {
      Say 'snapshot already present (session was already started) - leaving it'
    }

    Set-ActiveRuntime $cloudxr
    Say "ActiveRuntime -> $cloudxr"

    Stop-SteamVr

    if (-not $NoOpenComposite) {
      $dll = Join-Path $OpenComposite 'bin\win64\vrclient_x64.dll'
      if (Test-Path $dll) {
        Set-VrRuntimePath $OpenComposite $true
        Say "OpenVR runtime -> $OpenComposite (OpenComposite)"
      } else {
        Write-Warning "OpenComposite not found at $dll - OpenVR titles will still go to SteamVR. Run install-opencomposite.ps1."
      }
    }

    if (-not $KeepSunshine) {
      $svc = Get-Service SunshineService -ErrorAction SilentlyContinue
      if ($svc -and $svc.Status -eq 'Running') {
        Stop-Service SunshineService -Force
        Say 'SunshineService stopped (frees the NVENC session)'
      }
      # The tray app keeps its own encoder handle alive.
      Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Say 'ready - start the companion UI task, then the content app, then connect the headset.'
  }

  'stop' {
    $saved = if (Test-Path $stateKey) { Get-ItemProperty $stateKey } else { $null }

    $prevXr = $saved.PrevActiveRuntime
    if (-not $prevXr) { $prevXr = Join-Path $SteamVr 'steamxr_win64.json' }
    Set-ActiveRuntime $prevXr
    Say "ActiveRuntime -> $prevXr"

    $prevVr = $saved.PrevOpenVrRuntime
    if (-not $prevVr) { $prevVr = $SteamVr }
    Set-VrRuntimePath $prevVr $false   # also clears the read-only lock
    Say "OpenVR runtime -> $prevVr (unlocked)"

    if ($saved.PrevSunshine -ne 'Stopped') {
      $svc = Get-Service SunshineService -ErrorAction SilentlyContinue
      if ($svc -and $svc.Status -ne 'Running') { Start-Service SunshineService; Say 'SunshineService started' }
    }

    # TailscaleGuard downs Tailscale for the host lifetime and restores it on a clean
    # stop; a hard kill skips that, so make sure it is up again.
    if ((Get-Service Tailscale -ErrorAction SilentlyContinue).Status -eq 'Running') {
      $ts = 'C:\Program Files\Tailscale\tailscale.exe'
      if (Test-Path $ts) { & $ts up 2>&1 | Out-Null; Say 'tailscale up' }
    }

    if ($saved) { Remove-Item $stateKey -Recurse -Force; Say 'cleared snapshot' }
    Say 'restored.'
  }
}
