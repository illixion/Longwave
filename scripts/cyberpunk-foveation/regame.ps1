# Restart the PCVR host at a bitrate cap, then Cyberpunk at a DLSS mode, and load the last save. Run with ssh-exec -G.
# The game must be closed (the host is never restarted while the game holds the GPU's memory).
param([string]$Dlss = "Quality", [int]$Mbps = 120)
$log = "C:\lwvr\cpvr\regame.log"; "start $(Get-Date -Format HH:mm:ss) dlss $Dlss mbps $Mbps" | Out-File $log
if (Get-Process Cyberpunk2077 -ErrorAction SilentlyContinue) { "game still running" | Add-Content $log; return }
$us = "$env:LOCALAPPDATA\CD Projekt Red\Cyberpunk 2077\UserSettings.json"
$enc = New-Object Text.UTF8Encoding($false); $t = [IO.File]::ReadAllText($us)
$m = [regex]::Match($t, '"name": "DLSS",[^}]*?"value": "([^"]*)"')
if ($m.Success) { $new = $m.Value.Substring(0, $m.Value.Length - $m.Groups[1].Length - 1) + $Dlss + '"'; $t = $t.Substring(0, $m.Index) + $new + $t.Substring($m.Index + $m.Length); [IO.File]::WriteAllText($us, $t, $enc); "DLSS $($m.Groups[1].Value) -> $Dlss" | Add-Content $log }
(Get-Content C:\lwvr\hostrestart3.ps1) -replace "\.build-cxr2\\x86_64", ".build\x86_64" -replace "longwave-v3\\LongwaveStream", "longwave-motion\LongwaveStream" -replace "--max-mbps 150", "--max-mbps $Mbps" | Set-Content C:\lwvr\cpvr\hostrestart-cap.ps1
& C:\lwvr\cpvr\hostrestart-cap.ps1 -HostArgs "--foveation on --foveation-centre 0.5 --foveation-ratio 2 --motion off --hud-mask off" *>> $log
Start-Sleep 3
Start-Process "F:\Games\Cyberpunk 2077\bin\x64\Cyberpunk2077.exe" -WorkingDirectory "F:\Games\Cyberpunk 2077\bin\x64"
for ($i = 0; $i -lt 40; $i++) { Start-Sleep 5; $p = Get-Process Cyberpunk2077 -ErrorAction SilentlyContinue; if ($p -and $p.MainWindowTitle -and ((Get-Date) - $p.StartTime).TotalSeconds -gt 40) { break } }
if (-not $p) { "game never started" | Add-Content $log; return }
Start-Sleep 25
& C:\lwvr\game-keys.ps1 -Keys "up,up,f,f" -GapMs 700 *>> $log
"REGAME-DONE $(Get-Date -Format HH:mm:ss) game $($p.Id)" | Add-Content $log
