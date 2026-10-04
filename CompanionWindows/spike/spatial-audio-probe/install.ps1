# Installs the probe as an ASI plugin next to Cyber Engine Tweaks.
# CET already ships Ultimate ASI Loader as bin\x64\version.dll with LoadFromScriptsOnly=1,
# which loads every *.asi in bin\x64\plugins\ — so this only ADDS one file; nothing is replaced.
param([string]$Game = "D:\Games\Cyberpunk 2077")
$ErrorActionPreference = "Stop"
$asi = Join-Path $PSScriptRoot "build\spatial_audio_probe.asi"
$plugins = Join-Path $Game "bin\x64\plugins"
if (-not (Test-Path $asi)) { throw "Build first: $asi missing" }
if (-not (Test-Path (Join-Path $Game "bin\x64\version.dll"))) {
    throw "No ASI loader (bin\x64\version.dll) in $Game - install Ultimate ASI Loader or CET first"
}
New-Item -ItemType Directory -Force $plugins | Out-Null
$dest = Join-Path $plugins "spatial_audio_probe.asi"
if ((Test-Path $dest) -and -not (Test-Path "$dest.bak")) { Copy-Item $dest "$dest.bak" }
Copy-Item $asi $dest -Force
Copy-Item (Join-Path $PSScriptRoot "uninstall.ps1") (Join-Path $plugins "spatial_audio_probe_uninstall.ps1") -Force
"installed $dest"
"log will be written to $(Join-Path $plugins 'spatial_audio_probe.log')"
