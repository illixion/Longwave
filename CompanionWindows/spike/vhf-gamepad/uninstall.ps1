# Removes everything install.ps1 added: the device node (and with it every
# virtual pad), the remembered-but-absent pad nodes, the driver package from
# the driver store, the driver DLL copy, and every copy of the certificate:
# LocalMachine\Root and \TrustedPublisher (added by install.ps1) and
# LocalMachine\CA, where Windows itself files a copy when it installs the
# signed catalog.
# Run from an elevated PowerShell. Safe to run more than once.
$ErrorActionPreference = "Stop"
$kit = $PSScriptRoot
$devnode = Join-Path $kit "bin\lwpad-devnode.exe"
$subjectPrefix = "CN=Longwave Virtual Gamepad local signer"
$problems = 0

function Step($text) { Write-Output "== $text" }

Step "removing the device node"
if (Test-Path $devnode) {
    & $devnode remove
    if ($LASTEXITCODE -eq 1) { $problems++ }
} else {
    # Fallback without the tool: pnputil can remove a node by instance ID.
    Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains "Root\LongwaveVirtualGamepad" } |
        ForEach-Object { pnputil.exe /remove-device $_.InstanceId }
}

# Each virtual pad was a device node too. Windows remembers absent ("phantom")
# nodes so a reconnected device keeps its settings; remove ours.
Step "removing remembered virtual pad nodes"
Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like "*LONGWAVEPAD*" } | ForEach-Object {
    Write-Output "   $($_.InstanceId)"
    pnputil.exe /remove-device $_.InstanceId | Out-Null
}

Step "deleting the driver package from the driver store"
$packages = Get-WindowsDriver -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.OriginalFileName -like "*\longwavevirtualgamepad.inf" }
foreach ($p in $packages) {
    $out = & pnputil.exe /delete-driver $p.Driver /uninstall /force 2>&1 | Out-String
    Write-Output $out.Trim()
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { $problems++ }
}
if (-not $packages) { Write-Output "   no package found" }

# The UMDF DLL is copied to System32\drivers\UMDF; PnP leaves it behind once no
# package references it.
$dll = Join-Path $env:SystemRoot "System32\drivers\UMDF\LongwaveVirtualGamepad.dll"
if (Test-Path $dll) {
    Step "deleting $dll"
    try { Remove-Item $dll -Force } catch { Write-Warning "could not delete $dll (in use?): $_"; $problems++ }
}

Step "removing the certificate from LocalMachine\Root, TrustedPublisher, CA, My"
foreach ($store in "Root", "TrustedPublisher", "CA", "My") {
    Get-ChildItem "Cert:\LocalMachine\$store" | Where-Object { $_.Subject -like "$subjectPrefix*" } | ForEach-Object {
        Write-Output "   $store\$($_.Thumbprint) $($_.Subject)"
        Remove-Item $_.PSPath -DeleteKey -ErrorAction SilentlyContinue
        if (Test-Path $_.PSPath) { Remove-Item $_.PSPath }
    }
}

# Verify.
$left = @()
if (Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains "Root\LongwaveVirtualGamepad" }) { $left += "device node" }
if (Get-WindowsDriver -Online -ErrorAction SilentlyContinue | Where-Object { $_.OriginalFileName -like "*\longwavevirtualgamepad.inf" }) { $left += "driver package" }
if (Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like "*LONGWAVEPAD*" }) { $left += "virtual pad nodes" }
if (Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher, Cert:\LocalMachine\CA, Cert:\LocalMachine\My | Where-Object { $_.Subject -like "$subjectPrefix*" }) { $left += "certificate" }
if (Test-Path $dll) { $left += "driver DLL" }
if ($left.Count) {
    Write-Warning ("still present: " + ($left -join ", "))
    exit 1
}
Step "clean: no device node, pad nodes, driver package, DLL or certificate left"
exit 0
