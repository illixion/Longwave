param([int]$GamePid)
cd C:\lwvr\cpvr
$ini = "F:\Games\Cyberpunk 2077\red4ext\plugins\cyberpunkvrport\config\vrport.ini"
function SetKey($v) { (Get-Content $ini) -replace "^xr_vrs=.*", "xr_vrs=$v" | Set-Content $ini }
function Cap($label) { Start-Sleep 5; $r = & C:\lwvr\pm-capture.ps1 -Tag "ffr-all" -Seconds 15 | Select-String "swapchain" | select -Last 1; "$label  " + ($r.Line -replace "^.*frames","frames") }
function Twins($ao, $ssr) { python setx.py $GamePid "CyberpunkVR_AsymAoPatch=$ao" "CyberpunkVR_AsymSsrPatch=$ssr" | Out-Null }
SetKey 0
Twins 0 0; Cap "off            "
Twins 1 0; Cap "ao             "
Twins 0 1; Cap "ssr            "
Twins 1 1; Cap "ao+ssr         "
SetKey 2; Start-Sleep 3; Cap "ao+ssr+vrs     "
SetKey 0; Twins 0 0; Start-Sleep 3; Cap "off            "
Twins 1 1; SetKey 2; Start-Sleep 5
python prof.py $GamePid 3 | select -First 10
