# Creates a stock Windows 11 Hyper-V VM for the vhf-gamepad spike and starts an
# unattended install. Run on the Hyper-V host from an ELEVATED Windows
# PowerShell 5.1 (the IMAPI2 COM interop below is simplest there):
#
#   powershell -ExecutionPolicy Bypass -File .\New-Win11TestVM.ps1 -IsoPath C:\path\Win11_x64.iso
#
# What it builds (nothing security-related is relaxed; the point is a stock
# fresh install with Smart App Control in its out-of-box evaluation state):
#   Generation 2, 4 vCPU, 4 GB startup / dynamic up to 6 GB, 64 GB dynamic VHDX,
#   Secure Boot ON with the MicrosoftWindows template, vTPM ON (local key
#   protector), Default Switch, Guest Service Interface on, no GPU partition.
#   Windows 11 Pro from the ISO's own install.wim, local admin account with
#   auto-logon (the kit's Windows.Gaming.Input check needs a desktop session),
#   OpenSSH Server added at first logon.
#
# The account password is generated here and written to <VmRoot>\<user>-password.txt
# (never printed). The answer file (which contains it) lives only on the
# small unattend ISO next to the VM.
#
# The Windows ISO boots through cdboot.efi, which waits for "Press any key to
# boot from CD or DVD". Instead of remastering 9 GB, the script presses Space
# on the VM's synthetic keyboard (Msvm_Keyboard.TypeKey) for the first ~25 s.
# Later reboots get no key, time out and fall through to the hard disk.
#
# Control channel afterwards: PowerShell Direct, e.g.
#   $c = New-Object PSCredential('lwtest', (ConvertTo-SecureString (Get-Content <pwfile>) -AsPlainText -Force))
#   Invoke-Command -VMName LongwaveWin11Test -Credential $c { hostname }
# Delete everything again:
#   Stop-VM LongwaveWin11Test -TurnOff; Remove-VM LongwaveWin11Test -Force; Remove-Item -Recurse <VmRoot>\LongwaveWin11Test
param(
    [Parameter(Mandatory)] [string] $IsoPath,
    [string] $VmRoot = (Split-Path -Parent $IsoPath),
    [string] $Name = "LongwaveWin11Test",
    [string] $ComputerName = "LWWIN11TEST",
    [string] $User = "lwtest",
    [int] $ImageIndex = 6,                                  # Windows 11 Pro in the multi-edition ISO
    [string] $ProductKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T", # Microsoft's generic Pro *installation* key (no activation)
    [string] $Switch = "Default Switch",
    [switch] $NoStart
)
$ErrorActionPreference = "Stop"
$vmDir = Join-Path $VmRoot $Name
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "VM $Name already exists" }
New-Item -ItemType Directory -Force $vmDir | Out-Null

# --- password ---------------------------------------------------------------
$pwFile = Join-Path $VmRoot "$User-password.txt"
if (Test-Path $pwFile) { $password = (Get-Content $pwFile -Raw).Trim() }
else {
    $alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    $bytes = New-Object byte[] 20
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $password = "Lw-" + (-join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] }))
    Set-Content -Path $pwFile -Value $password -NoNewline
}

# --- answer file on a small ISO ---------------------------------------------
$template = Join-Path $PSScriptRoot "autounattend.template.xml"
$xml = (Get-Content $template -Raw).
    Replace("__USER__", $User).Replace("__PASSWORD__", [Security.SecurityElement]::Escape($password)).
    Replace("__COMPUTER__", $ComputerName).Replace("__IMAGEINDEX__", "$ImageIndex").Replace("__PRODUCTKEY__", $ProductKey)
$stage = Join-Path $vmDir "unattend-src"
New-Item -ItemType Directory -Force $stage | Out-Null
[IO.File]::WriteAllText((Join-Path $stage "autounattend.xml"), $xml, (New-Object Text.UTF8Encoding($false)))
$unattendIso = Join-Path $vmDir "unattend.iso"

if (-not ("LwIsoWriter" -as [type])) {
    Add-Type -TypeDefinition @"
using System; using System.IO; using System.Runtime.InteropServices.ComTypes;
public static class LwIsoWriter {
    public static void Write(string path, object stream, int blockSize, int totalBlocks) {
        IStream s = (IStream)stream;
        byte[] buf = new byte[blockSize];
        using (FileStream fs = File.Create(path)) {
            for (int i = 0; i < totalBlocks; i++) { s.Read(buf, blockSize, IntPtr.Zero); fs.Write(buf, 0, blockSize); }
        }
    }
}
"@
}
$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.ChooseImageDefaultsForMediaType(13)   # IMAPI_MEDIA_TYPE_DISK
$fsi.FileSystemsToCreate = 3                # ISO9660 + Joliet
$fsi.VolumeName = "UNATTEND"
$fsi.Root.AddTree($stage, $false)
$img = $fsi.CreateResultImage()
[LwIsoWriter]::Write($unattendIso, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)
Remove-Item -Recurse -Force $stage

# --- VM ----------------------------------------------------------------------
$vhd = Join-Path $vmDir "$Name.vhdx"
New-VM -Name $Name -Generation 2 -Path $VmRoot -MemoryStartupBytes 4GB -NewVHDPath $vhd -NewVHDSizeBytes 64GB -SwitchName $Switch | Out-Null
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -StartupBytes 4GB -MinimumBytes 4GB -MaximumBytes 6GB
Set-VMProcessor -VMName $Name -Count 4
Set-VM -Name $Name -AutomaticCheckpointsEnabled $false -CheckpointType Standard
Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
Enable-VMTPM -VMName $Name
Enable-VMIntegrationService -VMName $Name -Name "Guest Service Interface"
$dvdWin = Add-VMDvdDrive -VMName $Name -Path $IsoPath -Passthru
Add-VMDvdDrive -VMName $Name -Path $unattendIso
Set-VMFirmware -VMName $Name -BootOrder $dvdWin, (Get-VMHardDiskDrive -VMName $Name), (Get-VMNetworkAdapter -VMName $Name)

Get-VM $Name | Format-List Name, Generation, ProcessorCount, MemoryStartup, DynamicMemoryEnabled, Path
Get-VMFirmware $Name | Format-List SecureBoot, SecureBootTemplate
Get-VMSecurity $Name | Format-List TpmEnabled
if ($NoStart) { return }

# --- start and get past "Press any key to boot from CD or DVD" --------------
Start-VM -Name $Name
$cs = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$Name'"
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    $kb = Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_Keyboard -ErrorAction SilentlyContinue
    if ($kb) { Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = [uint32]0x20 } -ErrorAction SilentlyContinue | Out-Null }
    Start-Sleep -Milliseconds 500
}
"Started $Name; unattended setup running. Password file: $pwFile"
