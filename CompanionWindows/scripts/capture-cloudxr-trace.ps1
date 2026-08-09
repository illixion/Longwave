<#
.SYNOPSIS
  Capture a focused CloudXR CPU and GPU performance trace (runs ON the PC).

.DESCRIPTION
  Records WPR CPU sampling, thread scheduling, and DxgKrnl GPU activity while also
  sampling NVIDIA utilization. The default light profiles include sampled stacks
  without the very high event volume of GPU.Verbose.

.EXAMPLE
  capture-cloudxr-trace.ps1 -DurationSeconds 30
#>
[CmdletBinding()]
param(
  [ValidateRange(5, 120)] [int] $DurationSeconds = 30,
  [string] $OutputDirectory = 'C:\Temp\VisionVNC-Traces',
  [switch] $VerboseGpu
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$wpt = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit'
$wpr = Join-Path $wpt 'wpr.exe'
if (-not (Test-Path $wpr)) {
  throw "Windows Performance Toolkit is not installed at $wpt"
}

$principal = New-Object Security.Principal.WindowsPrincipal(
  [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this script from an elevated shell.'
}

$required = @('CloudXrService', 'VisionVNCSessionBroker', 'hlvr')
$processes = foreach ($name in $required) {
  $process = Get-Process $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $process) { throw "$name is not running; start PCVR and Alyx before tracing." }
  $process
}

New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$base = Join-Path $OutputDirectory "cloudxr-$stamp"
$tracePath = "$base.etl"
$gpuPath = "$base-gpu.csv"
$metadataPath = "$base-metadata.json"
$brokerPath = "$base-broker.log"

$metadata = [ordered]@{
  capturedAt = (Get-Date).ToString('o')
  durationSeconds = $DurationSeconds
  profiles = if ($VerboseGpu) { @('CPU.verbose', 'GPU.verbose') } else { @('CPU.light', 'GPU.light') }
  processes = @($processes | ForEach-Object {
    [ordered]@{
      name = $_.ProcessName
      pid = $_.Id
      startTime = $_.StartTime.ToString('o')
      path = $_.Path
    }
  })
  gpu = (& nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null)
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $metadataPath

$brokerLog = 'C:\dev\VisionVNC-companion\logs\broker.log'

$cpuProfile = if ($VerboseGpu) { 'CPU.verbose' } else { 'CPU.light' }
$gpuProfile = if ($VerboseGpu) { 'GPU.verbose' } else { 'GPU.light' }

& $wpr -cancel 2>$null
& $wpr -start $cpuProfile -start $gpuProfile
if ($LASTEXITCODE -ne 0) { throw "WPR failed to start (exit $LASTEXITCODE)." }

'timestamp,gpu_percent,encoder_percent,memory_mib,power_watts' |
  Set-Content -Encoding ASCII $gpuPath

$completed = $false
try {
  $deadline = [datetime]::UtcNow.AddSeconds($DurationSeconds)
  while ([datetime]::UtcNow -lt $deadline) {
    $sample = & nvidia-smi `
      --query-gpu=utilization.gpu,utilization.encoder,memory.used,power.draw `
      --format=csv,noheader,nounits
    "$(Get-Date -Format o),$sample" | Add-Content -Encoding ASCII $gpuPath
    Start-Sleep -Milliseconds 500
  }
  $completed = $true
} finally {
  if ($completed) {
    & $wpr -stop $tracePath 'VisionVNC CloudXR Alyx performance capture'
  } else {
    & $wpr -cancel
  }
}

if (-not (Test-Path $tracePath)) { throw 'WPR stopped without producing an ETL file.' }
if (Test-Path $brokerLog) {
  Copy-Item $brokerLog $brokerPath
}

$trace = Get-Item $tracePath
Write-Host "[cloudxr-trace] trace=$($trace.FullName)"
Write-Host "[cloudxr-trace] size=$([math]::Round($trace.Length / 1MB, 1)) MiB"
Write-Host "[cloudxr-trace] metadata=$metadataPath"
Write-Host "[cloudxr-trace] gpu=$gpuPath"
