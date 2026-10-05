# Sleep test for the Longwave virtual gamepad driver: puts this PC to sleep (S3)
# with pads in a chosen state, lets a wake timer bring it back, then checks the
# pads, the device and the event log. The driver must already be installed
# (install.ps1, or run-gamepad-spike.ps1 -KeepInstalled). Results go to
# results\<computer>-sleep-<mode>-<time>.log.
#
# Run from an ELEVATED PowerShell in the kit folder (over SSH works too):
#   powershell -ExecutionPolicy Bypass -File .\run-sleep-test.ps1 -Mode idle
# Modes (see lwpad-test.cpp): none, idle, churn, aware.
#
# The PC really sleeps. It needs S3 ("Standby (S3)" in `powercfg /a`) and wake
# timers allowed in the power plan (both are checked). With a driver that has the
# sleep bug, the PC never finishes going to sleep and blue-screens ~5 minutes
# later (0x9F); the log file keeps everything up to that point.
param(
    [ValidateSet("none", "idle", "churn", "aware")] [string] $Mode = "idle",
    [int] $WakeSeconds = 45
)
$ErrorActionPreference = "Continue"
$kit = $PSScriptRoot
$bin = Join-Path $kit "bin"
$started = Get-Date
New-Item -ItemType Directory -Force (Join-Path $kit "results") | Out-Null
$log = Join-Path $kit ("results\{0}-sleep-{1}-{2}.log" -f $env:COMPUTERNAME, $Mode, $started.ToString("yyyyMMdd-HHmmss"))

function Log([string] $text) { Add-Content -Path $log -Value $text -Encoding UTF8; Write-Host $text }
function Section([string] $title) { Log ""; Log "== $title" }
function Capture([scriptblock] $block) { $t = (& $block 2>&1 | Out-String -Width 250).TrimEnd(); if ($t) { Log $t } }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run this from an elevated (Run as administrator) PowerShell."
    exit 1
}

Section "Sleep test, mode $Mode, wake after $WakeSeconds s ($($started.ToString('s')))"
$os = Get-CimInstance Win32_OperatingSystem
Log "OS: $($os.Caption) build $($os.BuildNumber); kit: $((Get-Content (Join-Path $kit 'BUILD.txt') -ErrorAction SilentlyContinue) -join ' ')"
Capture { powercfg /a }
$rtc = powercfg /q SCHEME_CURRENT SUB_SLEEP RTCWAKE | Select-String "Current AC Power Setting Index"
Log "Allow wake timers (AC): $rtc   (0 = disabled, 1 = enabled, 2 = important only)"
if ("$rtc" -match "0x00000000$") { Log "FAIL wake-timers wake timers are disabled in the power plan; the PC would not wake by itself"; exit 1 }
$node = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains "Root\LongwaveVirtualGamepad" }
Log "Device before: $($node.InstanceId) status=$($node.Status)"
$hostBefore = Get-Process WUDFHost -ErrorAction SilentlyContinue | Where-Object { try { $_.Modules.ModuleName -contains "LongwaveVirtualGamepad.dll" } catch { $false } }
Log "Driver host before: WUDFHost pid $($hostBefore.Id)"
# Event records are filtered by record number, not time: a clock correction
# after resume can make older events look newer than the start.
$firstRecord = (Get-WinEvent -LogName System -MaxEvents 1).RecordId
$dumpsBefore = @(Get-ChildItem C:\Windows\LiveKernelReports, C:\Windows\Minidump -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object FullName)

Section "lwpad-test sleep $Mode $WakeSeconds"
# lwpad-test writes its own lines straight to the log as it goes (written
# through to disk), so a crash still leaves them; its stdout is discarded here
# so nothing is logged twice.
& "$bin\lwpad-test.exe" sleep $Mode $WakeSeconds $log | Out-Null
$testExit = $LASTEXITCODE

Section "After resume"
$node = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains "Root\LongwaveVirtualGamepad" }
Log "Device after: $($node.InstanceId) status=$($node.Status) problem=$($node.Problem)"
$hostAfter = Get-Process WUDFHost -ErrorAction SilentlyContinue | Where-Object { try { $_.Modules.ModuleName -contains "LongwaveVirtualGamepad.dll" } catch { $false } }
if ($hostAfter.Id -eq $hostBefore.Id) { Log "PASS sleep-host same WUDFHost pid $($hostAfter.Id) (driver host did not restart)" }
else { Log "FAIL sleep-host WUDFHost pid $($hostBefore.Id) -> $($hostAfter.Id)" }
if ($node.Status -eq "OK") { Log "PASS sleep-device device node OK after resume" } else { Log "FAIL sleep-device device node status '$($node.Status)'" }
Log "-- our HID pad nodes now (present ones should be none, the test destroyed its pads):"
Capture { Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object InstanceId -like "*LONGWAVEPAD*" | Format-Table Status, Class, InstanceId -AutoSize }

Log "-- System log since the test started (Kernel-Power, Power-Troubleshooter, PnP, bugcheck, WUDF):"
$events = Get-WinEvent -FilterHashtable @{ LogName = "System"; StartTime = $started.AddMinutes(-5) } -ErrorAction SilentlyContinue |
    Where-Object { $_.RecordId -gt $firstRecord -and $_.ProviderName -match "Kernel-Power|Power-Troubleshooter|Kernel-PnP|BugCheck|DriverFrameworks|WUDF|UserPnp" } |
    Sort-Object TimeCreated
foreach ($e in $events) {
    $msg = ($e.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join " | "
    Log ("[{0:HH:mm:ss.fff}] {1} {2}: {3}" -f $e.TimeCreated, $e.ProviderName.Replace("Microsoft-Windows-", ""), $e.Id, $msg.Substring(0, [Math]::Min(220, $msg.Length)))
}
$sleepEvent = $events | Where-Object { $_.ProviderName -like "*Kernel-Power" -and $_.Id -eq 42 }
$wakeEvent = $events | Where-Object { $_.ProviderName -like "*Power-Troubleshooter" -and $_.Id -eq 1 }
if ($sleepEvent -and $wakeEvent) { Log "PASS sleep-events entered sleep (Kernel-Power 42) and woke (Power-Troubleshooter 1)" }
else { Log "FAIL sleep-events sleep=$([bool]$sleepEvent) wake=$([bool]$wakeEvent)" }
$newDumps = @(Get-ChildItem C:\Windows\LiveKernelReports, C:\Windows\Minidump -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $dumpsBefore -notcontains $_.FullName })
if ($newDumps.Count) { Log "FAIL sleep-dumps new kernel dumps: $($newDumps.FullName -join ', ')" } else { Log "PASS sleep-dumps no new live kernel dump or minidump" }

Section "Summary"
$lines = Get-Content $log
$passes = @($lines | Where-Object { $_ -match "^PASS " }).Count
$fails = @($lines | Where-Object { $_ -match "^FAIL " })
$skips = @($lines | Where-Object { $_ -match "^SKIP " })
Log "PASS $passes  FAIL $($fails.Count)  SKIP $($skips.Count)   (lwpad-test exit $testExit, $([int]((Get-Date) - $started).TotalSeconds) s)"
$fails + $skips | ForEach-Object { Log "   $_" }
Log "Log: $log"
