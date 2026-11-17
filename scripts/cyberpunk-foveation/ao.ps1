param([int]$GamePid)
cd C:\lwvr\cpvr
$ini = "F:\Games\Cyberpunk 2077\red4ext\plugins\cyberpunkvrport\config\vrport.ini"
function SetKey($v) { (Get-Content $ini) -replace "^xr_vrs=.*", "xr_vrs=$v" | Set-Content $ini }
function Cap($label) { Start-Sleep 5; $r = & C:\lwvr\pm-capture.ps1 -Tag "ffr-a" -Seconds 15 | Select-String "swapchain" | select -Last 1; "$label  " + ($r.Line -replace "^.*frames","frames") }
python setx.py $GamePid CyberpunkVR_AsymAoPatchBuilt=0 CyberpunkVR_AsymAoPatchFailed=0 2>&1 | select -First 0
foreach ($v in 1,0,0,1) { python setx.py $GamePid "CyberpunkVR_AsymAoPatch=$v" | Out-Null; Cap "ao-twins=$v vrs=0" }
SetKey 2; Start-Sleep 3
foreach ($v in 1,0) { python setx.py $GamePid "CyberpunkVR_AsymAoPatch=$v" | Out-Null; Cap "ao-twins=$v vrs=2" }
python setx.py $GamePid CyberpunkVR_AsymAoPatch=1 | Out-Null
python prof.py $GamePid 3 | select -First 9
SetKey 0
