# Quick named-pipe RPC smoke test for the Longwave hotspot backend.
# Connects, then exercises Ping / GetStatus / ListUpstreamProfiles / StartHotspot / StopHotspot.
$ErrorActionPreference = 'Stop'
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'longwave-hotspot',
    [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
$pipe.Connect(5000)
$enc = New-Object System.Text.UTF8Encoding($false)
$reader = New-Object System.IO.StreamReader($pipe, $enc)
$writer = New-Object System.IO.StreamWriter($pipe, $enc)
$writer.NewLine = "`n"
$writer.AutoFlush = $true

function Send-Rpc($id, $method, $params) {
    $msg = @{ id = $id; method = $method }
    if ($params) { $msg.params = $params }
    $json = $msg | ConvertTo-Json -Compress -Depth 6
    $writer.WriteLine($json)
    # Read lines until we get the response for $id (skip pushed events, which have no id).
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { Write-Host "  <pipe closed>"; return $null }
        $obj = $line | ConvertFrom-Json
        if ($obj.PSObject.Properties.Name -contains 'event') {
            Write-Host ("  [event:{0}] state={1} clients={2}/{3} canHostAp={4}" -f $obj.event, $obj.data.state, $obj.data.clientCount, $obj.data.maxClientCount, $obj.data.canHostAp)
            continue
        }
        if ($obj.id -eq $id) { return $obj }
    }
}

Write-Host "== Ping =="
(Send-Rpc 1 'Ping' $null) | ConvertTo-Json -Compress

Write-Host "`n== ListUpstreamProfiles =="
(Send-Rpc 2 'ListUpstreamProfiles' $null).result | ForEach-Object { "  $($_.name) [$($_.kind)] internet=$($_.hasInternet) default=$($_.isDefault) cap=$($_.tetheringCapability)" }

Write-Host "`n== GetStatus =="
(Send-Rpc 3 'GetStatus' $null).result | ConvertTo-Json -Compress

Write-Host "`n== StartHotspot (ssid=Longwave-Test, auto pass) =="
$start = Send-Rpc 4 'StartHotspot' @{ ssid = 'Longwave-Test'; band = 'auto' }
$start.result | ConvertTo-Json -Compress

Write-Host "`n== StopHotspot =="
(Send-Rpc 5 'StopHotspot' $null).result | ConvertTo-Json -Compress

$writer.Dispose(); $reader.Dispose(); $pipe.Dispose()
Write-Host "`nDone."
