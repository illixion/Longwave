# Builds the Longwave virtual gamepad spike and assembles build\kit\, a folder
# that can be copied to any x64 Windows 10 (19041+) / 11 PC and installed there
# with nothing but inbox Windows tools.
#
# Needs on THIS (build) machine:
#   * Visual Studio 2022 or its Build Tools, with the x64 C++ tools (MSVC)
#   * Windows SDK 10.0.26100 (vhf.h is in its "shared" folder, signtool too)
#   * Windows Driver Kit 10.0.26100 - for the UMDF2 headers/libs, VhfUm.lib,
#     Inf2Cat and InfVerif. `winget install Microsoft.WindowsWDK.10.0.26100`.
#     The WDK's Visual Studio extension is NOT needed: this script calls the
#     compiler directly instead of going through MSBuild driver projects.
#   * git is not needed; SDL3 (for lwpad-sdltest only) is downloaded once.
#
# Nothing here signs anything. Signing happens at install time, on the machine
# the driver is installed on, with a key that is then destroyed (install.ps1).
param(
    [string] $DriverVersion   # e.g. 0.1.0.5; default derives one from the clock
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$sdkVer = "10.0.26100.0"
$umdfVer = "2.15"     # UMDF 2.15 = Windows 10 1803+; matches the INF
$sdlVer = "3.4.18"

# --- toolchain ---------------------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "No Visual Studio with the x64 C++ tools found" }
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64 -winsdk=$sdkVer" | Out-Null

$kits = "${env:ProgramFiles(x86)}\Windows Kits\10"
$need = @{
    "vhf.h (SDK)"             = "$kits\Include\$sdkVer\shared\vhf.h"
    "UMDF headers (WDK)"      = "$kits\Include\wdf\umdf\$umdfVer\wdf.h"
    "WdfDriverStubUm (WDK)"   = "$kits\Lib\wdf\umdf\x64\$umdfVer\WdfDriverStubUm.lib"
    "VhfUm.lib (WDK)"         = "$kits\Lib\$sdkVer\um\x64\VhfUm.lib"
    "Inf2Cat (WDK)"           = "$kits\bin\$sdkVer\x86\Inf2Cat.exe"
    "InfVerif (WDK)"          = "$kits\Tools\$sdkVer\x64\infverif.exe"
}
foreach ($k in $need.Keys) { if (-not (Test-Path $need[$k])) { throw "Missing $k at $($need[$k]) - install the WDK 10.0.26100" } }

# --- SDL3 (test tool only) ----------------------------------------------------
$sdl = Join-Path $root "third_party\SDL3-$sdlVer"
if (-not (Test-Path "$sdl\include\SDL3\SDL.h")) {
    New-Item -ItemType Directory -Force (Join-Path $root "third_party") | Out-Null
    $zip = Join-Path $root "third_party\SDL3-devel-$sdlVer-VC.zip"
    Invoke-WebRequest "https://github.com/libsdl-org/SDL/releases/download/release-$sdlVer/SDL3-devel-$sdlVer-VC.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath (Join-Path $root "third_party") -Force
}

# --- compile -------------------------------------------------------------------
$out = Join-Path $root "build"
$obj = Join-Path $out "obj"
$kit = Join-Path $out "kit"
if (Test-Path $kit) { Remove-Item -Recurse -Force $kit }
New-Item -ItemType Directory -Force $obj, "$kit\driver", "$kit\bin" | Out-Null

$vendor = Join-Path $root "vendor\libvirtualgamepad"
$common = @("/nologo", "/O2", "/MT", "/EHsc", "/std:c++20", "/W4", "/WX", "/permissive-", "/Zc:__cplusplus", "/external:anglebrackets", "/external:W0",
            "/DUNICODE", "/D_UNICODE", "/I$root\include", "/I$vendor\include", "/I$vendor\src", "/Fo$obj\", "/Fd$obj\")

function Invoke-Cl([string[]] $arguments) {
    & cl.exe @arguments
    if ($LASTEXITCODE) { throw "cl failed ($LASTEXITCODE)" }
}

# The driver: a UMDF2 DLL. These defines and libraries are what the WDK's
# MSBuild props (WindowsDriver.UserMode*.props) would pass for a UMDF 2.15,
# Windows 10 (19041) target.
$driverDefines = @("/DUMDF_VERSION_MAJOR=2", "/DUMDF_VERSION_MINOR=15", "/D_WIN32_WINNT=0x0A00", "/DWINVER=0x0A00",
                   "/DWINNT=1", "/DNTDDI_VERSION=0x0A000008", "/DWIN32_LEAN_AND_MEAN=1")
Invoke-Cl ($common + $driverDefines + @(
    "/I$kits\Include\wdf\umdf\$umdfVer", "/Zi",
    "$root\driver\driver.cpp", "$vendor\src\xbox_series.cpp", "$vendor\src\dualsense.cpp",
    "$vendor\src\dualshock4.cpp", "$vendor\src\report_pump.cpp",
    "/LD", "/Fe$kit\driver\LongwaveVirtualGamepad.dll",
    "/link", "/DEBUG", "/OPT:REF", "/OPT:ICF", "/PDB:$out\LongwaveVirtualGamepad.pdb",
    "$kits\Lib\wdf\umdf\x64\$umdfVer\WdfDriverStubUm.lib", "VhfUm.lib", "cfgmgr32.lib", "ntdll.lib"))

# Tools.
Invoke-Cl ($common + @("$root\tools\lwpad-devnode.cpp", "/Fe$kit\bin\lwpad-devnode.exe"))
Invoke-Cl ($common + @("/bigobj", "$root\tools\lwpad-test.cpp", "/Fe$kit\bin\lwpad-test.exe"))
Invoke-Cl ($common + @("/I$sdl\include", "$root\tools\lwpad-sdltest.cpp", "/Fe$kit\bin\lwpad-sdltest.exe",
                       "/link", "$sdl\lib\x64\SDL3.lib"))
Copy-Item "$sdl\lib\x64\SDL3.dll" "$kit\bin\"
Remove-Item "$kit\driver\*.lib", "$kit\driver\*.exp", "$kit\bin\*.lib", "$kit\bin\*.exp" -ErrorAction SilentlyContinue

# --- driver package: INF with a fresh DriverVer, then the (unsigned) catalog ---
# DriverVer must increase between builds or PnP may keep an older package.
if (-not $DriverVersion) {
    $minutes = [int](((Get-Date) - [datetime]"2026-01-01").TotalMinutes) % 65535
    $DriverVersion = "0.1.0.$minutes"
}
$inf = Get-Content "$root\driver\LongwaveVirtualGamepad.inf" -Raw
$inf = $inf -replace "(?m)^DriverVer=.*$", ("DriverVer=" + (Get-Date).ToString("MM/dd/yyyy", [Globalization.CultureInfo]::InvariantCulture) + ",$DriverVersion")
[IO.File]::WriteAllText("$kit\driver\LongwaveVirtualGamepad.inf", $inf, [Text.Encoding]::Unicode)

& $need["InfVerif (WDK)"] /w /v "$kit\driver\LongwaveVirtualGamepad.inf"
if ($LASTEXITCODE) { throw "InfVerif failed ($LASTEXITCODE)" }

# The catalog (.cat) lists the hash of every file in the package. Windows checks
# the files against it at install time; the catalog's own signature is what the
# install script adds on the target machine. PE files are hashed without their
# signature block, so signing the DLL later doesn't invalidate the catalog.
& $need["Inf2Cat (WDK)"] "/driver:$kit\driver" "/os:10_VB_X64,10_CO_X64,10_NI_X64" /uselocaltime
if ($LASTEXITCODE) { throw "Inf2Cat failed ($LASTEXITCODE)" }

# --- scripts and docs ---------------------------------------------------------------
Copy-Item "$root\install.ps1", "$root\uninstall.ps1", "$root\run-gamepad-spike.ps1", "$root\run-sleep-test.ps1", "$root\README.md" $kit
New-Item -ItemType Directory -Force "$kit\licenses" | Out-Null
Copy-Item "$vendor\LICENSE" "$kit\licenses\libvirtualgamepad-LICENSE.txt"
Copy-Item "$sdl\LICENSE.txt" "$kit\licenses\SDL3-LICENSE.txt" -ErrorAction SilentlyContinue
"DriverVer $DriverVersion built $(Get-Date -Format s) on $env:COMPUTERNAME" | Set-Content "$kit\BUILD.txt"
Get-ChildItem -Recurse $kit -File | Select-Object @{n = "File"; e = { $_.FullName.Substring($kit.Length + 1) } }, Length
