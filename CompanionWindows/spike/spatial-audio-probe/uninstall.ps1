# Removes the probe from the game. Keeps the log unless -RemoveLog is given.
param([string]$Game = "D:\Games\Cyberpunk 2077", [switch]$RemoveLog)
$plugins = Join-Path $Game "bin\x64\plugins"
$dest = Join-Path $plugins "spatial_audio_probe.asi"
if (Test-Path "$dest.bak") { Move-Item "$dest.bak" $dest -Force; "restored previous $dest" }
elseif (Test-Path $dest) { Remove-Item $dest -Force; "removed $dest" }
else { "not installed" }
Remove-Item (Join-Path $plugins "spatial_audio_probe_uninstall.ps1") -Force -ErrorAction SilentlyContinue
if ($RemoveLog) { Remove-Item (Join-Path $plugins "spatial_audio_probe.log") -Force -ErrorAction SilentlyContinue; "removed log" }
