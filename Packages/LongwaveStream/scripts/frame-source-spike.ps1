# SPIKE ONLY: runs frame-source-spike scenarios on Windows (open question 18,
# NATIVE_V3_PROTOCOL.md). Each scenario starts the processes it needs, waits,
# prints their output and stops only the processes it started (by PID).
#
#   scripts\frame-source-spike.ps1 -Scenario <name> [-Seconds 70] [-Exe <path>] [-Out <dir>]
#
# Scenarios
#   baseline        in-process: draw, local fence, encode (no handoff)
#   cross           consume + produce in two processes
#   baseline-load   baseline with a gpu-load process at 70% (game-like clocks and contention)
#   cross-load      cross with the same gpu-load process
#   verify          cross with --verify and an aux (depth) texture: every frame read back and checked
#   stall           cross with the host holding every frame for 2 s at frame 300
#   producer-crash  the producer exits abruptly at frame 300; a new producer attaches 2 s later
#   host-restart    the host is stopped mid-stream and started again; the producer reattaches
#   host-crash      the host is killed mid-stream and a new one started at once
#   adapter         a producer on the WARP adapter: the host must refuse it
#
# Run it in the interactive session (ssh-exec --gui) so both processes share
# the session's Local\ namespace, as a game and the host would.
param(
    [Parameter(Mandatory)] [string]$Scenario,
    [double]$Seconds = 70,
    [int]$Width = 2560,
    [int]$Height = 1440,
    [string]$Exe = '',
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$package = Resolve-Path (Join-Path $PSScriptRoot '..')
if (-not $Exe) { $Exe = Join-Path $package '.build\x86_64-unknown-windows-msvc\release\frame-source-spike.exe' }
if (-not $Out) { $Out = Join-Path $package '.build\frame-source-runs' }
New-Item -ItemType Directory -Force $Out | Out-Null
# The Swift runtime DLLs the exe needs.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')

$stamp = Get-Date -Format 'HHmmss'
$started = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$channel = "spike.$PID"

function Start-Spike([string]$name, [string[]]$arguments) {
    $log = Join-Path $Out "$stamp-$Scenario-$name.txt"
    $p = Start-Process -FilePath $Exe -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $started.Add($p)
    Write-Output "started $name pid $($p.Id): $($arguments -join ' ')"
    return [pscustomobject]@{ Name = $name; Process = $p; Log = $log }
}

function Wait-Spike($spike, [double]$timeoutSeconds) {
    if (-not $spike.Process.WaitForExit([int]($timeoutSeconds * 1000))) {
        Write-Output "$($spike.Name) (pid $($spike.Process.Id)) overran; stopping it"
        Stop-Process -Id $spike.Process.Id -Force
    }
}

function Show-Spike($spike) {
    Write-Output "----- $($spike.Name) (exit $($spike.Process.ExitCode)) -----"
    Get-Content $spike.Log
    if ((Test-Path "$($spike.Log).err") -and (Get-Item "$($spike.Log).err").Length -gt 0) { Get-Content "$($spike.Log).err" }
}

$size = @('--width', $Width, '--height', $Height)
$common = @('--channel', $channel, '--fps', 90)
try {
    switch ($Scenario) {
        'baseline' {
            $b = Start-Spike 'baseline' (@('inprocess', '--seconds', $Seconds, '--fps', 90, '--csv', (Join-Path $Out "$stamp-baseline.csv")) + $size)
            Wait-Spike $b ($Seconds + 30); Show-Spike $b
        }
        'baseline-load' {
            $l = Start-Spike 'gpu-load' @('gpu-load', '--percent', 70, '--seconds', ($Seconds + 8))
            Start-Sleep 3
            $b = Start-Spike 'baseline' (@('inprocess', '--seconds', $Seconds, '--fps', 90, '--csv', (Join-Path $Out "$stamp-baseline-load.csv")) + $size)
            Wait-Spike $b ($Seconds + 30); Wait-Spike $l 20; Show-Spike $l; Show-Spike $b
        }
        { $_ -in 'cross', 'cross-load', 'verify' } {
            $l = $null
            if ($Scenario -eq 'cross-load') {
                $l = Start-Spike 'gpu-load' @('gpu-load', '--percent', 70, '--seconds', ($Seconds + 10))
                Start-Sleep 3
            }
            $extraHost = @(); $extraProducer = @()
            if ($Scenario -eq 'verify') { $extraHost = @('--verify'); $extraProducer = @('--aux') }
            $h = Start-Spike 'host' (@('consume', '--seconds', ($Seconds + 4), '--csv', (Join-Path $Out "$stamp-$Scenario.csv")) + $common + $extraHost)
            Start-Sleep 1
            $p = Start-Spike 'producer' (@('produce', '--seconds', $Seconds) + $common + $size + $extraProducer)
            Wait-Spike $p ($Seconds + 30); Wait-Spike $h 30
            if ($l) { Wait-Spike $l 20; Show-Spike $l }
            Show-Spike $p; Show-Spike $h
        }
        'stall' {
            $h = Start-Spike 'host' (@('consume', '--seconds', ($Seconds + 4), '--stall-at', 300, '--stall-ms', 2000) + $common)
            Start-Sleep 1
            $p = Start-Spike 'producer' (@('produce', '--seconds', $Seconds) + $common + $size)
            Wait-Spike $p ($Seconds + 30); Wait-Spike $h 30; Show-Spike $p; Show-Spike $h
        }
        'producer-crash' {
            $h = Start-Spike 'host' (@('consume', '--seconds', ($Seconds + 4)) + $common)
            Start-Sleep 1
            $p1 = Start-Spike 'producer-1' (@('produce', '--seconds', $Seconds, '--crash-after', 300) + $common + $size)
            Wait-Spike $p1 ($Seconds + 30)
            Start-Sleep 2
            $p2 = Start-Spike 'producer-2' (@('produce', '--seconds', ($Seconds / 2)) + $common + $size)
            Wait-Spike $p2 ($Seconds + 30); Wait-Spike $h ($Seconds + 30)
            Show-Spike $p1; Show-Spike $p2; Show-Spike $h
        }
        'host-restart' {
            $h1 = Start-Spike 'host-1' (@('consume', '--seconds', ($Seconds / 3)) + $common)
            Start-Sleep 1
            $p = Start-Spike 'producer' (@('produce', '--seconds', $Seconds, '--wait', 30) + $common + $size)
            Wait-Spike $h1 ($Seconds + 30)
            Start-Sleep 2
            $h2 = Start-Spike 'host-2' (@('consume', '--seconds', ($Seconds / 2)) + $common)
            Wait-Spike $h2 ($Seconds + 30); Wait-Spike $p ($Seconds + 30)
            Show-Spike $h1; Show-Spike $h2; Show-Spike $p
        }
        'host-crash' {
            $h1 = Start-Spike 'host-1' (@('consume', '--seconds', $Seconds) + $common)
            Start-Sleep 1
            $p = Start-Spike 'producer' (@('produce', '--seconds', $Seconds, '--wait', 30) + $common + $size)
            Start-Sleep ($Seconds / 3)
            Write-Output "killing host-1 (pid $($h1.Process.Id))"
            Stop-Process -Id $h1.Process.Id -Force
            $h2 = Start-Spike 'host-2' (@('consume', '--seconds', ($Seconds / 2)) + $common)
            Wait-Spike $h2 ($Seconds + 30); Wait-Spike $p ($Seconds + 30)
            Show-Spike $h2; Show-Spike $p
        }
        'adapter' {
            $h = Start-Spike 'host' (@('consume', '--seconds', 8) + $common)
            Start-Sleep 1
            $p = Start-Spike 'producer' (@('produce', '--seconds', 3, '--warp') + $common + @('--width', 1280, '--height', 720))
            Wait-Spike $p 30; Wait-Spike $h 30; Show-Spike $p; Show-Spike $h
        }
        default { throw "unknown scenario $Scenario" }
    }
} finally {
    foreach ($p in $started) {
        if (-not $p.HasExited) {
            Write-Output "cleanup: stopping pid $($p.Id)"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
