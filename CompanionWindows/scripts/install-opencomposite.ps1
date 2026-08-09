<#
.SYNOPSIS
  Install OpenComposite (OpenVR -> OpenXR translation) on the RTX host (runs ON the PC).

.DESCRIPTION
  CloudXR 6.2 dropped its SteamVR/OpenVR integration - it is a standalone OpenXR
  runtime. So an OpenVR-only title (Half-Life 2 VR) cannot reach a CloudXR session
  through SteamVR; it needs OpenComposite, which impersonates the OpenVR runtime and
  translates the game's OpenVR calls into OpenXR against whatever ActiveRuntime is.

  Installs BOTH architectures, because the bitness that matters is the *game's*, not the OS's:
  OpenVR loads `bin\win64\vrclient_x64.dll` for a 64-bit title and `bin\win32\vrclient.dll` for a
  32-bit one. Half-Life 2: VR Mod is 32-bit Source (machine 0x014C), and with only the x64 DLL
  present it fails at init with "vrclient Shared Lib Not Found (102)"
  (VRInitError_Init_VRClientDLLNotFound).

  The upstream mirror serves the payload two different ways depending on branch, so this sniffs
  the magic bytes rather than assuming:
    - "MZ" -> the raw vrclient DLL (what download.php currently returns)
    - "PK" -> a zip containing the bin\<arch>\ layout

  Either way the result is the layout OpenVR's runtime lookup expects:
    <Dest>\bin\win64\vrclient_x64.dll
    <Dest>\bin\win32\vrclient.dll

  This only unpacks the runtime. Pointing openvrpaths.vrpath at it is pcvr-session.ps1's
  job, so the switch stays reversible in one place.
#>
[CmdletBinding()]
param(
  [string] $Dest = 'C:\dev\OpenComposite',
  [string] $UrlTemplate = 'https://znix.xyz/OpenComposite/download.php?arch={0}&branch=openxr',
  # Restrict to one architecture (default: install both).
  [ValidateSet('x64', 'x86', 'both')] [string] $Arch = 'both',
  # Pre-downloaded dll or zip, if the mirror is unreachable. Implies a single -Arch.
  [string] $Payload
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string] $m) { Write-Host "[opencomposite] $m" }

# arch -> the relative paths to install the client DLL at.
#
# SteamVR's own runtime - the authoritative example of what openvr_api looks for - keeps
# BOTH DLLs directly in bin\ (bin\vrclient.dll, bin\vrclient_x64.dll), not in
# bin\win32\ / bin\win64\. Installing only the bin\<arch>\ layout produced
# "vrclient Shared Lib Not Found (102)" (VRInitError_Init_VRClientDLLNotFound). Different
# openvr_api versions probe different paths, so write both and let the loader pick.
$layout = @{
  'x64' = @{ Dll = 'vrclient_x64.dll'; Dirs = @('bin', 'bin\win64') }
  'x86' = @{ Dll = 'vrclient.dll';     Dirs = @('bin', 'bin\win32') }
}

$targets = if ($Arch -eq 'both') { @('x64', 'x86') } else { @($Arch) }
if ($Payload -and $targets.Count -gt 1) {
  throw '-Payload installs a single architecture; pass -Arch x64 or -Arch x86 with it.'
}

$tmp = Join-Path $env:TEMP 'opencomposite'
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Test-IsDll([string] $path) {
  # Verify a raw PE really is a DLL before installing it as one - a truncated download or an
  # HTML error page would otherwise be laid down as the runtime.
  $fs = [System.IO.File]::OpenRead($path)
  try {
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Position = 0x3C
    $fs.Position = $br.ReadUInt32() + 4 + 18   # PE sig (4) + COFF header up to Characteristics
    return [bool] ($br.ReadUInt16() -band 0x2000)
  } finally { $fs.Close() }
}

foreach ($arch in $targets) {
  $dll = $layout[$arch].Dll
  $dirs = $layout[$arch].Dirs | ForEach-Object { Join-Path $Dest $_ }
  foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

  $file = $Payload
  if (-not $file) {
    $url = [string]::Format($UrlTemplate, $arch)
    $file = Join-Path $tmp "download-$arch.bin"
    Say "downloading $arch from $url"
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -MaximumRedirection 5
  }

  $magic = -join ([System.IO.File]::ReadAllBytes($file)[0..1] | ForEach-Object { [char] $_ })
  Say ("{0}: {1:N1} MB, magic {2}" -f $arch, ((Get-Item $file).Length / 1MB), $magic)

  switch ($magic) {
    'MZ' {
      if (-not (Test-IsDll $file)) { throw "$arch payload is not a DLL - wrong download?" }
      foreach ($d in $dirs) { Copy-Item $file (Join-Path $d $dll) -Force }
      Say "installed $dll -> $($layout[$arch].Dirs -join ', ')"
    }
    'PK' {
      $stage = Join-Path $tmp "stage-$arch"
      Expand-Archive -Path $file -DestinationPath $stage -Force
      $found = Get-ChildItem $stage -Recurse -Filter $dll | Select-Object -First 1
      if (-not $found) { throw "no $dll in the $arch archive - wrong download?" }
      foreach ($d in $dirs) { Copy-Item $found.FullName (Join-Path $d $dll) -Force }
      Say "installed $dll -> $($layout[$arch].Dirs -join ', ') (from archive)"
    }
    default { throw "unrecognised $arch payload (magic '$magic') - the mirror probably served an error page" }
  }
}

foreach ($arch in $targets) {
  foreach ($d in $layout[$arch].Dirs) {
    $path = Join-Path (Join-Path $Dest $d) $layout[$arch].Dll
    if (-not (Test-Path $path)) { throw "install incomplete: $path missing" }
  }
}

Say "installed -> $Dest"
Get-ChildItem $Dest -Recurse -File | Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize
Say 'now run: pcvr-session.ps1 -Mode start   (points openvrpaths.vrpath here)'
