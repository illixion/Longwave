# Put the Cyberpunk VR port back as shipped (0.2.45): the DLL, the port's own AO twin, and no foveated twins.
# The game must be closed. Backups were made on 2026-11-17 under C:\lwvr\cpvr.
if (Get-Process Cyberpunk2077 -ErrorAction SilentlyContinue) { "close the game first"; return }
$p = "F:\Games\Cyberpunk 2077\red4ext\plugins\cyberpunkvrport"
Copy-Item C:\lwvr\cpvr\cyberpunkvrport-0.2.45-shipped.dll "$p\cyberpunkvrport.dll" -Force
Copy-Item C:\lwvr\cpvr\twins\33f28d9a0e7a8352.dxil "$p\shaders\asym_ao\33f28d9a0e7a8352.dxil" -Force
Remove-Item "$p\shaders\asym_ao\65e542c0719b464d.dxil", "$p\shaders\asym_ssr\bdf51af7acfab45e.dxil" -ErrorAction SilentlyContinue
(Get-Content "$p\config\vrport.ini") -replace "^xr_vrs=.*", "xr_vrs=0" | Set-Content "$p\config\vrport.ini"
"shipped port restored"
