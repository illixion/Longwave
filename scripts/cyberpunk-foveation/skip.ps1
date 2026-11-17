param([int]$GamePid)
cd C:\lwvr\cpvr
function Cap($label) { Start-Sleep 5; $r = & C:\lwvr\pm-capture.ps1 -Tag "ffr-s" -Seconds 15 | Select-String "swapchain" | select -Last 1; "$label  " + ($r.Line -replace "^.*frames","frames") }
python setx.py $GamePid CyberpunkVR_FfrSkipNode=0 | Out-Null; Cap "none            "
foreach ($n in @(@("DrawConeAO      ","0x777514"),@("SSR             ","0x77a100"),@("LightBuffers    ","0x411b94"),@("VolumetricFog   ","0xddb6b8"),@("CAS             ","0x3fda34"))) {
  python setx.py $GamePid "CyberpunkVR_FfrSkipNode=$($n[1])" | Out-Null; Cap $n[0]
}
python setx.py $GamePid CyberpunkVR_FfrSkipNode=0 | Out-Null; Cap "none            "
python census.py $GamePid
