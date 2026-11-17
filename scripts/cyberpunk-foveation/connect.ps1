# Headset session: v3 stack (broker + PCVR host), then Cyberpunk, then load the last save. Run with ssh-exec -G.
$log = "C:\lwvr\cpvr\connect.log"; "start $(Get-Date -Format HH:mm:ss)" | Out-File $log
if (Get-Process Cyberpunk2077, LongwaveSessionBroker, longwave-pcvr-host, frame-source-spike -ErrorAction SilentlyContinue) { "something is already running" | Add-Content $log; return }
$broker = (Get-ChildItem C:\dev, C:\Users\Ixion\Developer -Recurse -Depth 6 -Filter LongwaveSessionBroker.exe -ErrorAction SilentlyContinue | ? { $_.FullName -match "build-vive\\Release" } | sort LastWriteTime -Descending | select -First 1).FullName
"broker $broker" | Add-Content $log
$env:LONGWAVE_BROKER_GAME_DEPTH = "1"
& C:\lwvr\v3-test.ps1 -Start -Broker $broker -PcvrHost "C:\Users\Ixion\Developer\longwave-motion\LongwaveStream\.build\x86_64-unknown-windows-msvc\release\longwave-pcvr-host.exe" -EyeSize 2536x2040 -HostArgs "--foveation on --foveation-centre 0.5 --foveation-ratio 2 --motion off --hud-mask off" *>> $log
Start-Sleep 3
Start-Process "F:\Games\Cyberpunk 2077\bin\x64\Cyberpunk2077.exe" -WorkingDirectory "F:\Games\Cyberpunk 2077\bin\x64"
for ($i = 0; $i -lt 40; $i++) { Start-Sleep 5; $p = Get-Process Cyberpunk2077 -ErrorAction SilentlyContinue; if ($p -and $p.MainWindowTitle -and ((Get-Date) - $p.StartTime).TotalSeconds -gt 40) { break } }
if (-not $p) { "game never started" | Add-Content $log; return }
Start-Sleep 25
& C:\lwvr\game-keys.ps1 -Keys "up,up,f,f" -GapMs 700 *>> $log
"CONNECT-DONE $(Get-Date -Format HH:mm:ss) game $($p.Id)" | Add-Content $log
