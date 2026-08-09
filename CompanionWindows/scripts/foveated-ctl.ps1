<#
.SYNOPSIS
  Drive the companion backend's foveated host over its named pipe (runs ON the PC).

.DESCRIPTION
  The Electron UI is the normal way to press Start PCVR / read the pairing QR, but the PCVR
  host's RPC is just newline-delimited JSON on \\.\pipe\visionvnc-pcvr-host (a separate
  process and pipe from the public backend) and the pipe accepts multiple clients - so the
  host can be started and polled headlessly (from SSH) while the UI stays up and renders the QR.

  -Action status also prints the raw QR payload, which is enough to tell whether the
  headset has reached the pairing step without seeing the screen.

.EXAMPLE
  foveated-ctl.ps1 -Action start
  foveated-ctl.ps1 -Action status -WaitSeconds 60
  foveated-ctl.ps1 -Action launch -GameId steam:546560
  foveated-ctl.ps1 -Action restart-launch -GameId steam:546560
  foveated-ctl.ps1 -Action stop
#>
[CmdletBinding()]
param(
  # runtime = bring the CloudXR runtime service up now, so a content app (game / hello_xr) can be
  # launched BEFORE the headset connects. Without it an OpenXR app gets XR_ERROR_RUNTIME_UNAVAILABLE.
  [Parameter(Mandatory)]
  [ValidateSet('start', 'stop', 'restart', 'status', 'ping', 'runtime', 'launch', 'restart-launch',
    'host-start', 'host-stop')]
  [string] $Action,
  [string] $BundleId = 'com.illixion.VisionVNC',
  [int] $Port = 55000,
  # Advertise/bind a specific IPv4. Empty = the backend picks the first non-loopback
  # address (LAN mode; it also downs Tailscale). A 100.64/10 address = tailnet mode.
  [string] $IpAddress = '',
  [switch] $ForceQrCode,
  # Library id accepted by GamesLaunch. Steam titles use steam:<appid>.
  [string] $GameId = 'steam:546560',
  # restart-launch waits this long for the headset to report CONNECTED before launching.
  [ValidateRange(1, 600)] [int] $ConnectTimeoutSeconds = 120,
  # Poll status for this long, printing each change (0 = single snapshot).
  [int] $WaitSeconds = 0
)

$ErrorActionPreference = 'Stop'

$pipeName = 'visionvnc-pcvr-host'
$controlPipeName = 'visionvnc-companion-control'

$enc    = New-Object System.Text.UTF8Encoding $false
$pipe = $null
$reader = $null
$writer = $null

$script:id = 0

function Connect-BackendPipe {
  if ($pipe -and $pipe.IsConnected) { return }
  $script:pipe = New-Object System.IO.Pipes.NamedPipeClientStream '.', $pipeName, ([System.IO.Pipes.PipeDirection]::InOut)
  try {
    $script:pipe.Connect(5000)
  } catch {
    $script:pipe.Dispose()
    $script:pipe = $null
    throw "cannot connect to \\.\pipe\$pipeName - is the backend running? ($($_.Exception.Message))"
  }
  $script:reader = New-Object System.IO.StreamReader($script:pipe, $enc)
  $script:writer = New-Object System.IO.StreamWriter($script:pipe, $enc)
  $script:writer.NewLine = "`n"
  $script:writer.AutoFlush = $true
}

# The server pushes unsolicited "state"/"foveated" event frames (no id) as soon as a
# client connects and whenever things change, so a reply has to be matched by id
# rather than just reading the next line.
function Invoke-Rpc([string] $method, $params, [int] $timeoutSec = 20) {
  Connect-BackendPipe
  $script:id++
  $req = @{ id = $script:id; method = $method }
  if ($null -ne $params) { $req.params = $params }
  $writer.WriteLine(($req | ConvertTo-Json -Compress -Depth 6))

  $deadline = [datetime]::UtcNow.AddSeconds($timeoutSec)
  while ([datetime]::UtcNow -lt $deadline) {
    # Bounded read: a plain ReadLine() blocks forever if the server never answers, which makes
    # the deadline above meaningless and hangs the caller (and any SSH session driving it).
    $task = $reader.ReadLineAsync()
    $remaining = [int][Math]::Max(1000, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
    if (-not $task.Wait($remaining)) { throw "$method timed out after ${timeoutSec}s" }
    $line = $task.Result
    if (-not $line) { throw 'pipe closed while awaiting a reply' }
    $msg = $line | ConvertFrom-Json
    if ($msg.PSObject.Properties.Name -contains 'id' -and $msg.id -eq $script:id) {
      if ($msg.error) { throw "$method failed: $($msg.error.code) $($msg.error.message)" }
      return $msg.result
    }
    # else: an event frame for the UI - ignore.
  }
  throw "$method timed out"
}

function Invoke-CompanionRpc([string] $method, $params, [int] $timeoutSec = 240) {
  $control = New-Object System.IO.Pipes.NamedPipeClientStream '.', $controlPipeName, ([System.IO.Pipes.PipeDirection]::InOut)
  $controlReader = $null
  $controlWriter = $null
  try {
    $control.Connect(5000)
  } catch {
    throw "cannot use \\.\pipe\$controlPipeName - start the desktop companion from its shortcut. $($_.Exception.Message)"
  }
  try {
    $controlReader = New-Object System.IO.StreamReader($control, $enc)
    $controlWriter = New-Object System.IO.StreamWriter($control, $enc)
    $controlWriter.NewLine = "`n"
    $controlWriter.AutoFlush = $true
    $script:id++
    $req = @{ id = $script:id; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $controlWriter.WriteLine(($req | ConvertTo-Json -Compress -Depth 6))

    $task = $controlReader.ReadLineAsync()
    if (-not $task.Wait($timeoutSec * 1000)) { throw "$method timed out after ${timeoutSec}s" }
    $line = $task.Result
    if (-not $line) { throw 'companion control pipe closed without a reply' }
    $msg = $line | ConvertFrom-Json
    if ($msg.error) { throw "$method failed: $($msg.error.code) $($msg.error.message)" }
    return $msg.result
  } finally {
    if ($controlWriter) { $controlWriter.Dispose() }
    if ($controlReader) { $controlReader.Dispose() }
    $control.Dispose()
  }
}

function Show-Status($s) {
  if (-not $s) { Write-Host 'no status'; return }
  [pscustomobject]@{
    State         = $s.state
    Advertising   = $s.advertising
    Endpoint      = "$($s.ipAddress):$($s.port)"
    BundleId      = $s.bundleId
    CloudXR       = if ($s.cloudXrAvailable) { 'available' } else { "UNAVAILABLE - $($s.cloudXrDetail)" }
    Client        = if ($s.clientConnected) { $s.clientAddress } else { '(none)' }
    SessionStatus = $s.sessionStatus
    Pairing       = if ($s.pairingRequired) { "REQUIRED - payload: $($s.qrPayload)" } else { 'not requested' }
    Detail        = $s.detail
  } | Format-List
}

function Start-Foveated {
  $p = @{ bundleId = $BundleId; port = $Port; forceQrCode = [bool] $ForceQrCode }
  if ($IpAddress) { $p.ipAddress = $IpAddress }
  $r = Invoke-Rpc 'FoveatedStart' $p
  Write-Host "[foveated-ctl] start ok=$($r.ok) status=$($r.status) $($r.detail)"
  Show-Status $r.snapshot
  if (-not $r.ok) { throw "FoveatedStart failed: $($r.status) $($r.detail)" }
  return $r
}

function Stop-Foveated {
  $r = Invoke-Rpc 'FoveatedStop' $null
  Write-Host "[foveated-ctl] stop ok=$($r.ok) status=$($r.status) $($r.detail)"
  if (-not $r.ok) { throw "FoveatedStop failed: $($r.status) $($r.detail)" }
  return $r
}

function Companion-HostParams {
  $p = @{ bundleId = $BundleId; port = $Port; forceQrCode = [bool] $ForceQrCode }
  if ($IpAddress) { $p.ipAddress = $IpAddress }
  return $p
}

function Show-StackResult($result) {
  foreach ($step in @($result.steps)) {
    $state = if ($step.ok) { 'ok' } else { 'FAILED' }
    Write-Host ("[foveated-ctl] {0}: {1} {2}" -f $step.step, $state, $step.detail)
  }
  if (-not $result.ok) { throw 'PCVR stack operation failed.' }
}

try {
  switch ($Action) {

    'ping' { Invoke-Rpc 'Ping' $null }

    'start' {
      Show-StackResult (Invoke-CompanionRpc 'PcvrStart' @{ hostParams = (Companion-HostParams) })
    }

    'runtime' {
      # The RPC blocks until the runtime reports itself running, which takes seconds.
      $r = Invoke-Rpc 'FoveatedStartRuntime' $null 120
      Write-Host "[foveated-ctl] runtime service ok=$($r.ok) status=$($r.status) $($r.detail)"
      Show-Status $r.snapshot
    }

    'stop' {
      $r = Invoke-CompanionRpc 'PcvrStop' $null
      Write-Host "[foveated-ctl] full PCVR stack stopped through desktop companion"
    }

    'restart' {
      Show-StackResult (Invoke-CompanionRpc 'PcvrRestart' @{ hostParams = (Companion-HostParams) })
    }

    'launch' {
      $r = Invoke-CompanionRpc 'PcvrLaunch' @{
        gameId = $GameId
        connectTimeoutSeconds = $ConnectTimeoutSeconds
      }
      Write-Host "[foveated-ctl] launch requested through desktop companion: $($r.gameId)"
    }

    'restart-launch' {
      $r = Invoke-CompanionRpc 'PcvrRestartLaunch' @{
        hostParams = (Companion-HostParams)
        gameId = $GameId
        connectTimeoutSeconds = $ConnectTimeoutSeconds
      } $($ConnectTimeoutSeconds + 120)
      Show-StackResult $r
      Write-Host "[foveated-ctl] headset connected; launch requested through desktop companion: $($r.gameId)"
    }

    'host-start' { Start-Foveated | Out-Null }

    'host-stop' { Stop-Foveated | Out-Null }

    'status' {
      if ($WaitSeconds -le 0) { Show-Status (Invoke-Rpc 'FoveatedStatus' $null); break }

      # Poll and print only on change, so a long watch stays readable.
      $deadline = [datetime]::UtcNow.AddSeconds($WaitSeconds)
      $last = ''
      while ([datetime]::UtcNow -lt $deadline) {
        $s = Invoke-Rpc 'FoveatedStatus' $null
        # qrPngDataUri is a huge base64 blob - exclude it from the change key and output.
        $key = "$($s.state)|$($s.advertising)|$($s.clientConnected)|$($s.clientAddress)|$($s.sessionStatus)|$($s.pairingRequired)|$($s.qrPayload)"
        if ($key -ne $last) {
          Write-Host ("--- {0:HH:mm:ss} ---" -f [datetime]::Now)
          Show-Status $s
          $last = $key
        }
        Start-Sleep -Seconds 2
      }
    }
  }
} finally {
  if ($writer) { $writer.Dispose() }
  if ($reader) { $reader.Dispose() }
  if ($pipe) { $pipe.Dispose() }
}
