# Builds build\spatial_audio_probe.asi and build\probe_harness.exe with MSVC x64.
# Fetches MinHook (v1.3.4) into third_party\ on first run. No other dependencies.
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$mh = Join-Path $root "third_party\minhook"
if (-not (Test-Path "$mh\include\MinHook.h")) {
    git clone --depth 1 --branch v1.3.4 https://github.com/TsudaKageyu/minhook $mh
    if ($LASTEXITCODE) { throw "git clone minhook failed" }
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "No Visual Studio with the x64 C++ tools found" }
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64" | Out-Null

$out = Join-Path $root "build"
New-Item -ItemType Directory -Force "$out\obj" | Out-Null
Push-Location $out
try {
    $mhSrc = "$mh\src\buffer.c", "$mh\src\hook.c", "$mh\src\trampoline.c", "$mh\src\hde\hde64.c"
    cl /nologo /c /O2 /MT /W3 /Foobj\ $mhSrc
    if ($LASTEXITCODE) { throw "minhook compile failed" }
    cl /nologo /O2 /MT /EHsc /std:c++17 /W3 /Zi /I"$mh\include" /Foobj\ /Fdobj\ "$root\src\probe.cpp" obj\buffer.obj obj\hook.obj obj\trampoline.obj obj\hde64.obj `
        /LD /Fe:spatial_audio_probe.asi /link /DEBUG /OPT:REF /PDB:spatial_audio_probe.pdb ole32.lib
    if ($LASTEXITCODE) { throw "probe build failed" }
    cl /nologo /O2 /MT /EHsc /std:c++17 /W3 /Foobj\ "$root\harness\harness.cpp" /Fe:probe_harness.exe /link ole32.lib
    if ($LASTEXITCODE) { throw "harness build failed" }
} finally { Pop-Location }
Get-Item "$out\spatial_audio_probe.asi", "$out\probe_harness.exe" | Select-Object Name, Length, LastWriteTime
