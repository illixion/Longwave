# One-shot test of the Longwave virtual gamepad driver on this PC: records the
# security baseline, installs the driver with a locally generated and then
# destroyed certificate, proves the install was silent and the driver loads,
# checks the pads from XInput / Windows.Gaming.Input / SDL3, kills a feeder,
# creates and destroys pads many times, then uninstalls. Everything goes to
# results\<computer>-<time>.log in this folder.
#
# Run from an ELEVATED PowerShell in the kit folder:
#   powershell -ExecutionPolicy Bypass -File .\run-gamepad-spike.ps1
# Reboot check (recommended on the Windows 11 VM):
#   ... -File .\run-gamepad-spike.ps1 -KeepInstalled   then reboot, then
#   ... -File .\run-gamepad-spike.ps1 -AfterReboot     (checks it came back, tests, uninstalls)
param(
    [switch] $KeepInstalled,   # leave the driver installed at the end
    [switch] $AfterReboot,     # driver was installed by an earlier -KeepInstalled run
    [int] $Cycles = 250
)
$ErrorActionPreference = "Continue"
$kit = $PSScriptRoot
$bin = Join-Path $kit "bin"
$started = Get-Date
New-Item -ItemType Directory -Force (Join-Path $kit "results") | Out-Null
$phase = if ($AfterReboot) { "afterreboot" } else { "run" }
$log = Join-Path $kit ("results\{0}-{1}-{2}.log" -f $env:COMPUTERNAME, $phase, $started.ToString("yyyyMMdd-HHmmss"))

function Log([string] $text) {
    Add-Content -Path $log -Value $text -Encoding UTF8
    Write-Host $text
}
function Section([string] $title) { Log ""; Log ("=" * 78); Log "== $title"; Log ("=" * 78) }
function Capture([scriptblock] $block) {
    $text = (& $block 2>&1 | Out-String -Width 250).TrimEnd()
    if ($text) { Log $text }
}
function Fact([string] $name, $value) { Log ("{0,-38} {1}" -f $name, $value) }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run this from an elevated (Run as administrator) PowerShell."
    exit 1
}
Get-ChildItem -Recurse $kit -File | Unblock-File

# ----------------------------------------------------------------------------
Section "1. Baseline ($phase, $($started.ToString('s')))"
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$cs = Get-CimInstance Win32_ComputerSystem
Fact "OS" "$($os.Caption) $($cv.DisplayVersion) build $($os.BuildNumber).$($cv.UBR)"
Fact "Computer" "$env:COMPUTERNAME  $($cs.Manufacturer) / $($cs.Model)  hypervisor-present=$($cs.HypervisorPresent)"
Fact "Session" "id $((Get-Process -Id $PID).SessionId) (0 = service session, e.g. SSH; games run in >= 1)"
Fact "Kit" ((Get-Content (Join-Path $kit "BUILD.txt") -ErrorAction SilentlyContinue) -join " ")
try { $sb = Confirm-SecureBootUEFI } catch { $sb = "unavailable ($($_.Exception.Message))" }
Fact "Secure Boot" $sb
$bcd = (bcdedit /enum "{current}" 2>&1 | Out-String)
$ts = [regex]::Match($bcd, "(?im)^testsigning\s+(\S+)").Groups[1].Value
$nic = [regex]::Match($bcd, "(?im)^nointegritychecks\s+(\S+)").Groups[1].Value
Fact "Test signing (bcdedit)" ($(if ($ts) { $ts } else { "not set (off)" }))
Fact "nointegritychecks (bcdedit)" ($(if ($nic) { $nic } else { "not set (off)" }))
$dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
if ($dg) {
    $vbs = @("off", "enabled, not running", "running")[[int]$dg.VirtualizationBasedSecurityStatus]
    $hvci = if ($dg.SecurityServicesRunning -contains 2) { "RUNNING" } else { "not running" }
    Fact "Virtualization-based security" $vbs
    Fact "Memory Integrity (HVCI)" "$hvci (services running: $($dg.SecurityServicesRunning -join ','))"
}
$ci = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -ErrorAction SilentlyContinue
$sacValue = $ci.VerifiedAndReputablePolicyState
$sacText = switch ($sacValue) { 0 { "OFF" } 1 { "ON (enforcing)" } 2 { "EVALUATION" } $null { "not present (Windows 10 / no SAC)" } default { "unknown ($sacValue)" } }
Fact "Smart App Control (CI\Policy)" "$sacText  [VerifiedAndReputablePolicyState=$sacValue]"
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if ($mp.PSObject.Properties.Name -contains "SmartAppControlState") { Fact "Smart App Control (Defender)" $mp.SmartAppControlState }
    Fact "Defender" "mode=$($mp.AMRunningMode) realtime=$($mp.RealTimeProtectionEnabled)"
} catch { Fact "Defender" "Get-MpComputerStatus unavailable" }
$lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($lic) { Fact "Windows activation" (@("unlicensed", "licensed", "OOB grace", "OOT grace", "non-genuine grace", "notification", "extended grace")[[int]$lic.LicenseStatus]) }
foreach ($f in "System32\drivers\vhf.sys", "System32\VhfUm.dll", "System32\WUDFHost.exe", "System32\drivers\WUDFRd.sys") {
    $p = Join-Path $env:SystemRoot $f
    $v = if (Test-Path $p) { (Get-Item $p).VersionInfo.FileVersion } else { "MISSING" }
    Fact "Inbox $f" ($(if ($v) { $v } else { "present (no version resource)" }))
}
foreach ($inf in "hidvhf.inf", "xinputhid.inf", "WUDFRD.inf") {
    $note = if ($inf -eq "WUDFRD.inf") { " (Windows 11 only; Windows 10 uses the INF's own reflector section)" } else { "" }
    Fact "Inbox $inf" ($(if (Test-Path (Join-Path $env:SystemRoot "INF\$inf")) { "present" } else { "MISSING$note" }))
}
Fact "ViGEmBus present" ([bool](Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object FriendlyName -like "*Virtual Gamepad Emulation Bus*"))
Fact "XInput slots in use before" ((& "$bin\lwpad-test.exe" probe | Select-String "connected" | Where-Object { $_ -notmatch "not connected" }).Count)

# ----------------------------------------------------------------------------
$ciStart = Get-Date
if (-not $AfterReboot) {
    Section "2. Install (no paid certificate, no test signing)"
    $setupLog = Join-Path $env:SystemRoot "INF\setupapi.dev.log"
    $setupLines = (Get-Content $setupLog -ErrorAction SilentlyContinue).Count
    $t = Get-Date
    Capture { powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit "install.ps1") }
    $installExit = $LASTEXITCODE
    Fact "install.ps1 exit code" "$installExit  ($([int]((Get-Date) - $t).TotalSeconds) s)"
    Log "-- setupapi.dev.log (Windows' own install log), signature-related lines:"
    $new = Get-Content $setupLog | Select-Object -Skip $setupLines
    Capture { $new | Select-String "^>>>|<<<|sig:.*(Signer|trusted|publisher|Error|Success|valid)|!!!|ui :|Driver Version|Starting device" | ForEach-Object { $_.Line } }
    if ($installExit -ne 0) { Log "FAIL install install.ps1 exited $installExit"; }
    else { Log "PASS install silent, non-interactive install succeeded" }
} else {
    Section "2. After reboot: did the driver come back on its own?"
}

Section "3. Driver state"
$node = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains "Root\LongwaveVirtualGamepad" }
Capture { $node | Format-List Status, Problem, Class, FriendlyName, InstanceId }
Capture { Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceID -like "ROOT\LONGWAVE*" | Format-List DeviceName, DriverVersion, InfName, IsSigned, Signer }
$hostProc = Get-Process WUDFHost -ErrorAction SilentlyContinue | Where-Object { try { $_.Modules.ModuleName -contains "LongwaveVirtualGamepad.dll" } catch { $false } }
if ($node -and $node.Status -eq "OK" -and $hostProc) { Log "PASS driver-loaded device OK, hosted by WUDFHost pid $($hostProc.Id)" }
else { Log "FAIL driver-loaded device=$($node.Status) host=$([bool]$hostProc)" }
Log "-- certificates (public halves only should exist; HasPrivateKey must be False):"
Capture { Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher, Cert:\LocalMachine\CA, Cert:\LocalMachine\My |
          Where-Object Subject -like "CN=Longwave Virtual Gamepad local signer*" | Format-Table @{n = "Store"; e = { $_.PSParentPath.Split("\")[-1] } }, Thumbprint, HasPrivateKey, NotAfter -AutoSize }
if (Get-ChildItem -Recurse Cert:\LocalMachine | Where-Object { $_.Subject -like "CN=Longwave Virtual Gamepad local signer*" -and $_.HasPrivateKey }) {
    Log "FAIL private-key a Longwave signer certificate with a private key exists"
} else { Log "PASS private-key no Longwave signer certificate with a private key exists" }
Log "-- signatures of the kit's files (Valid = signed by the now key-less local cert):"
Capture { Get-AuthenticodeSignature (Join-Path $kit "driver\*.cat"), (Join-Path $kit "driver\*.dll"), (Join-Path $bin "lwpad-*.exe") |
          Format-Table @{n = "File"; e = { Split-Path $_.Path -Leaf } }, Status, @{n = "Signer"; e = { $_.SignerCertificate.Subject } } -AutoSize }

# ----------------------------------------------------------------------------
Section "4. Function"
Capture { & "$bin\lwpad-test.exe" info }
Log "-- XInput (what most PC games use):"
Capture { & "$bin\lwpad-test.exe" xinput }
Log "-- Windows.Gaming.Input (needs this session's desktop; opens a small window briefly):"
Capture { & "$bin\lwpad-test.exe" wgi }
Log "-- SDL3 (Steam and many games), Xbox profile:"
Capture { & "$bin\lwpad-sdltest.exe" xbox }
Log "-- SDL3, DualSense profile (gyro, rumble, lightbar):"
Capture { & "$bin\lwpad-sdltest.exe" dualsense }

Log "-- Feeder killed mid-session (the pad must not outlive its feeder):"
$holdOut = Join-Path $env:TEMP "lwpad-hold-$PID.txt"
$p = Start-Process (Join-Path $bin "lwpad-test.exe") -ArgumentList "hold", "60" -PassThru -NoNewWindow -RedirectStandardOutput $holdOut
$deadline = (Get-Date).AddSeconds(10)
while (-not (Select-String -Path $holdOut -Pattern "READY" -Quiet -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
$ready = Get-Content $holdOut -ErrorAction SilentlyContinue
Log "   feeder: $ready"
$slot = [regex]::Match("$ready", "slot=(\d)").Groups[1].Value
$alive = & "$bin\lwpad-test.exe" probe | Select-String "SLOT $slot connected"
Log "   while alive: $alive"
Start-Sleep -Milliseconds 500
$t = Get-Date
Stop-Process -Id $p.Id -Force
$gone = $false
for ($i = 0; $i -lt 100 -and -not $gone; $i++) {
    if (& "$bin\lwpad-test.exe" probe | Select-String "SLOT $slot not connected") { $gone = $true } else { Start-Sleep -Milliseconds 20 }
}
$ms = [int]((Get-Date) - $t).TotalMilliseconds
if ($slot -ne "" -and $alive -and $gone) { Log "PASS kill-feeder pad in slot $slot disappeared within $ms ms of killing its feeder" }
else { Log "FAIL kill-feeder slot='$slot' alive='$alive' gone=$gone after $ms ms" }
Remove-Item $holdOut -ErrorAction SilentlyContinue

Log "-- Create/destroy $Cycles times:"
Capture { & "$bin\lwpad-test.exe" cycle $Cycles | Where-Object { $_ -notmatch "^INFO cycle " } }

# ----------------------------------------------------------------------------
Section "5. Code Integrity / Smart App Control events since the install"
# 3076 = would have been blocked (audit, e.g. SAC evaluation), 3077 = blocked,
# 3033/3034/3089 = signature problems on a loaded image.
$events = Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -ErrorAction SilentlyContinue |
    Where-Object { $_.TimeCreated -ge $ciStart }
Fact "CodeIntegrity events" @($events).Count
Capture { $events | Select-Object -First 30 | Format-List TimeCreated, Id, @{n = "Message"; e = { ($_.Message -split "`n")[0..2] -join " " } } }
$ours = @($events | Where-Object { $_.Message -match "lwpad|Longwave|SDL3" })
if ($ours.Count) { Log "INFO ci-events $($ours.Count) Code Integrity events mention our files (see above)" }
else { Log "PASS ci-events no Code Integrity event mentions our files" }
$ci2 = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
Fact "Smart App Control state now" $ci2

# ----------------------------------------------------------------------------
if ($KeepInstalled) {
    Section "6. Left installed (-KeepInstalled). Reboot, then run with -AfterReboot."
} else {
    Section "6. Uninstall"
    Capture { powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit "uninstall.ps1") }
    if ($LASTEXITCODE -eq 0) { Log "PASS uninstall nothing left behind" } else { Log "FAIL uninstall exit $LASTEXITCODE" }
}

Section "Summary"
$lines = Get-Content $log
$passes = @($lines | Where-Object { $_ -match "^PASS " }).Count
$fails = @($lines | Where-Object { $_ -match "^FAIL " })
$skips = @($lines | Where-Object { $_ -match "^SKIP " })
Log "PASS $passes  FAIL $($fails.Count)  SKIP $($skips.Count)   ($([int]((Get-Date) - $started).TotalSeconds) s)"
$fails + $skips | ForEach-Object { Log "   $_" }
Log "Log: $log"
