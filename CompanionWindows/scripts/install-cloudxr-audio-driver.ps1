<#
.SYNOPSIS
  Installs (or reports on / removes) the NVIDIA CloudXR Virtual Audio Driver.

.DESCRIPTION
  CloudXR's runtime delivers the headset microphone to Windows through its own kernel
  audio driver, nvcloudxrvad. The driver creates one "NVIDIA CloudXR" sound controller
  with a Speakers pin (isolated downstream audio) and a Microphone pin (the headset mic).
  Without it the runtime still logs "Microphone streaming enabled" and then reports
  "total bytes captured: 0" at teardown — the stream exists and has nowhere to go.

  The driver is a root-enumerated virtual device, so `pnputil /add-driver` alone only
  stages the package: nothing ever asks for it. NVIDIA's documented installer path is
  to create a device node with hardware ID USB\VID_0959&PID_9004 and then call
  UpdateDriverForPlugAndPlayDevices on the INF. That is what this script does (the same
  sequence as `devcon install`), via SetupAPI/newdev P/Invoke so nothing extra needs to
  ship. Run elevated.

.PARAMETER DriverDir
  Folder holding nvcloudxrvad.inf / .cat / .sys — the CloudXRVirtualAudioDriver directory
  inside the staged CloudXR runtime (Server\releases\<version>\CloudXRVirtualAudioDriver).
  Required for -Install.

.PARAMETER Status
  Print a JSON object { installed, present, hardwareId, instanceIds, service } and exit 0.
  Never needs elevation.

.PARAMETER Uninstall
  Remove every device node carrying the hardware ID, then delete the staged driver
  package. Elevated.

.EXAMPLE
  .\install-cloudxr-audio-driver.ps1 -DriverDir 'C:\...\Server\releases\6.2.1\CloudXRVirtualAudioDriver'
  .\install-cloudxr-audio-driver.ps1 -Status
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
  [Parameter(ParameterSetName = 'Install', Mandatory = $true)]
  [string]$DriverDir,
  [Parameter(ParameterSetName = 'Status')]
  [switch]$Status,
  [Parameter(ParameterSetName = 'Uninstall')]
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# From nvcloudxrvad.inf: [NVIDIA.NTamd64] ... USB\VID_0959&PID_9004, Class=MEDIA.
$HardwareId = 'USB\VID_0959&PID_9004'
$MediaClassGuid = [Guid]'4d36e96c-e325-11ce-bfc1-08002be10318'
$ServiceName = 'nvcloudxrvad_WaveExtensible'
$InfName = 'nvcloudxrvad.inf'

function Get-CloudXRAudioDevices {
  # Get-PnpDevice returns a HardwareID array per device; -like on the array matches any element.
  Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue |
    Where-Object { $_.HardwareID -contains $HardwareId }
}

function Get-DriverStatus {
  $devices = @(Get-CloudXRAudioDevices)
  $present = @($devices | Where-Object { $_.Present })
  $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  [ordered]@{
    installed   = ($present.Count -gt 0 -and $present[0].Status -eq 'OK')
    present     = ($present.Count -gt 0)
    status      = if ($present.Count -gt 0) { [string]$present[0].Status } else { $null }
    hardwareId  = $HardwareId
    instanceIds = @($devices | ForEach-Object { $_.InstanceId })
    service     = if ($service) { [string]$service.Status } else { $null }
  }
}

function Assert-Elevated {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]$id
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Installing a kernel audio driver needs an elevated PowerShell.'
  }
}

$setupApi = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CloudXRAudioSetup
{
    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA
    {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    const uint DICD_GENERATE_ID = 0x00000001;
    const uint SPDRP_HARDWAREID = 0x00000001;
    const uint DIF_REGISTERDEVICE = 0x00000019;
    const uint INSTALLFLAG_FORCE = 0x00000001;

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid classGuid, IntPtr hwndParent);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiCreateDeviceInfoW(IntPtr deviceInfoSet, string deviceName, ref Guid classGuid,
        string deviceDescription, IntPtr hwndParent, uint creationFlags, ref SP_DEVINFO_DATA deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr deviceInfoSet, ref SP_DEVINFO_DATA deviceInfoData,
        uint property, byte[] propertyBuffer, uint propertyBufferSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiCallClassInstaller(uint installFunction, IntPtr deviceInfoSet, ref SP_DEVINFO_DATA deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwndParent, string hardwareId, string fullInfPath,
        uint installFlags, out bool rebootRequired);

    static void Fail(string step)
    {
        int err = Marshal.GetLastWin32Error();
        throw new System.ComponentModel.Win32Exception(err, step + " failed (Win32 error " + err + ")");
    }

    /// Creates a root-enumerated device node of the given class carrying hardwareId — the
    /// step `pnputil /add-driver` never performs for a virtual device. Equivalent to the
    /// first half of `devcon install`.
    public static void CreateDeviceNode(Guid classGuid, string className, string hardwareId)
    {
        IntPtr set = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        if (set == new IntPtr(-1)) Fail("SetupDiCreateDeviceInfoList");
        try
        {
            var data = new SP_DEVINFO_DATA();
            data.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            if (!SetupDiCreateDeviceInfoW(set, className, ref classGuid, null, IntPtr.Zero, DICD_GENERATE_ID, ref data))
                Fail("SetupDiCreateDeviceInfo");

            // REG_MULTI_SZ: each string NUL-terminated, list NUL-terminated.
            byte[] multiSz = Encoding.Unicode.GetBytes(hardwareId + "\0\0");
            if (!SetupDiSetDeviceRegistryPropertyW(set, ref data, SPDRP_HARDWAREID, multiSz, (uint)multiSz.Length))
                Fail("SetupDiSetDeviceRegistryProperty(HARDWAREID)");

            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, ref data))
                Fail("SetupDiCallClassInstaller(DIF_REGISTERDEVICE)");
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(set);
        }
    }

    /// Second half of `devcon install`: bind the INF to every present device with hardwareId.
    /// Returns whether Windows asked for a reboot.
    public static bool InstallDriver(string hardwareId, string infPath)
    {
        bool reboot;
        if (!UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hardwareId, infPath, INSTALLFLAG_FORCE, out reboot))
            Fail("UpdateDriverForPlugAndPlayDevices");
        return reboot;
    }
}
'@

if ($Status) {
  Get-DriverStatus | ConvertTo-Json -Compress
  exit 0
}

Assert-Elevated

if ($Uninstall) {
  $devices = @(Get-CloudXRAudioDevices)
  foreach ($d in $devices) {
    Write-Host "Removing $($d.InstanceId)"
    & pnputil.exe /remove-device "$($d.InstanceId)" | Out-Null
  }
  $pkgs = (& pnputil.exe /enum-drivers) -join "`n"
  # Published names look like oemNN.inf; find the block whose Original Name is ours.
  foreach ($m in [regex]::Matches($pkgs, '(?ms)Published Name:\s+(oem\d+\.inf)\s*\r?\nOriginal Name:\s+nvcloudxrvad\.inf')) {
    Write-Host "Deleting driver package $($m.Groups[1].Value)"
    & pnputil.exe /delete-driver $m.Groups[1].Value /uninstall /force | Out-Null
  }
  Get-DriverStatus | ConvertTo-Json -Compress
  exit 0
}

# ---- Install ----
$inf = Join-Path $DriverDir $InfName
if (-not (Test-Path $inf)) { throw "No $InfName in $DriverDir" }
foreach ($required in 'nvcloudxrvad.cat', 'nvcloudxrvad64v.sys') {
  if (-not (Test-Path (Join-Path $DriverDir $required))) { throw "$required is missing from $DriverDir" }
}
$inf = (Resolve-Path $inf).Path

$before = Get-DriverStatus
if ($before.installed) {
  Write-Host "NVIDIA CloudXR audio device already installed ($($before.instanceIds -join ', '))."
  $before | ConvertTo-Json -Compress
  exit 0
}

if (-not ('CloudXRAudioSetup' -as [type])) {
  Add-Type -TypeDefinition $setupApi -Language CSharp
}

if (-not $before.present) {
  Write-Host "Creating root-enumerated device node for $HardwareId"
  [CloudXRAudioSetup]::CreateDeviceNode($MediaClassGuid, 'MEDIA', $HardwareId)
} else {
  Write-Host "Device node exists but has no working driver (status $($before.status)); binding the INF."
}

Write-Host "Installing $inf"
$reboot = [CloudXRAudioSetup]::InstallDriver($HardwareId, $inf)

# The class installer can take a moment to publish the audio endpoints.
$deadline = (Get-Date).AddSeconds(15)
do {
  Start-Sleep -Milliseconds 500
  $after = Get-DriverStatus
} until ($after.installed -or (Get-Date) -gt $deadline)

if (-not $after.installed) {
  $after | ConvertTo-Json -Compress
  throw "Driver install finished but the device is not reporting OK (status: $($after.status))."
}
if ($reboot) { Write-Warning 'Windows requested a reboot to finish the driver install.' }
Write-Host "NVIDIA CloudXR audio device installed ($($after.instanceIds -join ', '))."
$after | ConvertTo-Json -Compress
