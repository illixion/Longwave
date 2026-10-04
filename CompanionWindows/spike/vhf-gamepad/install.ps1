# Installs the Longwave virtual gamepad driver WITHOUT any purchased
# certificate and WITHOUT test-signing mode. Run from an elevated (admin)
# PowerShell, in the kit folder that build.ps1 produced.
#
# What happens, and why:
#
#  1. Windows will only install a driver package whose catalog (.cat) is signed
#     by a certificate the machine trusts. For KERNEL drivers that has to be
#     Microsoft; for a USER-MODE (UMDF) driver like this one, any certificate in
#     the machine's trusted stores is enough. So we make one, here, now:
#     a self-signed code-signing certificate in the machine's personal store.
#  2. Sign the catalog (plus the driver DLL and the kit's tools) with it.
#  3. Trust it: put the PUBLIC certificate in LocalMachine\Root ("this is a
#     trusted root") and LocalMachine\TrustedPublisher ("install software from
#     this publisher without asking").
#  4. Destroy the PRIVATE key, then prove it's gone. From here on nothing on
#     earth can sign anything with this certificate - not us, not malware on
#     this PC - so trusting it only ever vouches for the files signed in step 2.
#  5. pnputil stages the package in the driver store (the signature check
#     happens here), then lwpad-devnode creates the device node the driver
#     loads on. Both run non-interactively: if Windows wanted to show "Windows
#     can't verify the publisher of this driver software", they fail instead.
#
# Uninstall (uninstall.ps1) removes the device, the package and the certificate.
param(
    [double] $ValidityDays = 3650,   # see README: what expiry does and does not affect
    [switch] $KeepKey                # debugging only: do NOT destroy the private key
)
$ErrorActionPreference = "Stop"
$kit = $PSScriptRoot
$driverDir = Join-Path $kit "driver"
$devnode = Join-Path $kit "bin\lwpad-devnode.exe"
$subjectPrefix = "CN=Longwave Virtual Gamepad local signer"

function Step($text) { Write-Output "== $text" }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated (Run as administrator) PowerShell."
}
foreach ($f in "LongwaveVirtualGamepad.inf", "LongwaveVirtualGamepad.dll", "LongwaveVirtualGamepad.cat") {
    if (-not (Test-Path (Join-Path $driverDir $f))) { throw "Kit incomplete: driver\$f missing" }
}

# Files copied from another machine or downloaded carry "Mark of the Web";
# clear it so SmartScreen doesn't treat our own tools as internet downloads.
Get-ChildItem -Recurse $kit -File | Unblock-File

# Refuse to stack certificates: an earlier install must be removed first.
$old = @(Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher, Cert:\LocalMachine\My |
         Where-Object { $_.Subject -like "$subjectPrefix*" })
if ($old.Count) { throw "A Longwave gamepad signer is already installed; run uninstall.ps1 first." }

# --- 1. the certificate ---------------------------------------------------------
Step "creating a one-off code-signing certificate (key is non-exportable)"
$subject = "$subjectPrefix, OU=$env:COMPUTERNAME $(Get-Date -Format yyyy-MM-ddTHH.mm.ss)"
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
    -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy NonExportable `
    -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyUsage DigitalSignature `
    -Provider "Microsoft Software Key Storage Provider" `
    -TextExtension @("2.5.29.19={critical}{text}ca=false") `
    -NotAfter (Get-Date).AddDays($ValidityDays)
$thumb = $cert.Thumbprint
# Where the private key lives on disk, so we can prove it's deleted later.
$keyName = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert).Key.UniqueName
$keyFile = Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$keyName"
Write-Output "   subject   : $subject"
Write-Output "   thumbprint: $thumb  valid until $($cert.NotAfter)"
Write-Output "   key file  : $keyFile (exists: $(Test-Path $keyFile))"

try {
    # --- 2. sign -------------------------------------------------------------------
    # No timestamp: that would need a network round trip to a third party. The
    # catalog signature only matters at install time (see README).
    Step "signing the catalog, the driver DLL and the kit's tools"
    $toSign = @(Get-Item (Join-Path $driverDir "LongwaveVirtualGamepad.cat"), (Join-Path $driverDir "LongwaveVirtualGamepad.dll")) +
              @(Get-ChildItem (Join-Path $kit "bin") -Filter "lwpad-*.exe")
    foreach ($file in $toSign) {
        $sig = Set-AuthenticodeSignature -FilePath $file.FullName -Certificate $cert -HashAlgorithm SHA256
        if ($sig.Status -ne "Valid" -and $sig.Status -ne "UnknownError") {
            throw "Signing $($file.Name) failed: $($sig.Status) $($sig.StatusMessage)"
        }
        Write-Output "   signed $($file.Name)"
    }

    # --- 3. trust (public half only) -------------------------------------------------
    Step "trusting the public certificate (LocalMachine\Root + LocalMachine\TrustedPublisher)"
    $public = New-Object Security.Cryptography.X509Certificates.X509Certificate2(, $cert.Export("Cert"))
    foreach ($storeName in "Root", "TrustedPublisher") {
        $store = New-Object Security.Cryptography.X509Certificates.X509Store($storeName, "LocalMachine")
        $store.Open("ReadWrite")
        $store.Add($public)
        $store.Close()
    }
    foreach ($file in $toSign) {
        $check = Get-AuthenticodeSignature $file.FullName
        if ($check.Status -ne "Valid") { throw "$($file.Name) signature not valid after trusting: $($check.Status) $($check.StatusMessage)" }
    }
    Write-Output "   all signatures verify as Valid"
}
finally {
    # --- 4. destroy the private key -------------------------------------------------
    if ($KeepKey) {
        Write-Warning "KeepKey: private key left in LocalMachine\My\$thumb - NOT the supported configuration"
    } else {
        Step "destroying the private key"
        Remove-Item "Cert:\LocalMachine\My\$thumb" -DeleteKey
    }
}

if (-not $KeepKey) {
    $leftovers = @(Get-ChildItem -Recurse Cert:\LocalMachine, Cert:\CurrentUser -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $thumb -and $_.HasPrivateKey })
    if ($leftovers.Count -or (Test-Path $keyFile)) {
        throw "Private key still present (store copies with key: $($leftovers.Count), key file exists: $(Test-Path $keyFile))"
    }
    # Belt and braces: ask the key storage provider for the key by name.
    $stillOpenable = $true
    try { [Security.Cryptography.CngKey]::Open($keyName, [Security.Cryptography.CngProvider]::MicrosoftSoftwareKeyStorageProvider, [Security.Cryptography.CngKeyOpenOptions]::MachineKey) | Out-Null }
    catch { $stillOpenable = $false }
    if ($stillOpenable) { throw "Key $keyName can still be opened from the key storage provider" }
    Write-Output "   verified: no certificate with a private key, key file gone, key cannot be opened"
}

# --- 5. install ----------------------------------------------------------------------
Step "staging the driver package (pnputil /add-driver)"
$inf = Join-Path $driverDir "LongwaveVirtualGamepad.inf"
$pnp = & pnputil.exe /add-driver $inf 2>&1 | Out-String
Write-Output $pnp.Trim()
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { throw "pnputil /add-driver failed ($LASTEXITCODE)" }
$oem = [regex]::Match($pnp, "oem\d+\.inf").Value
if ($oem) { Write-Output "   published as $oem" }

Step "creating the device node and installing the driver on it"
& $devnode create $inf
$rc = $LASTEXITCODE
if ($rc -ne 0 -and $rc -ne 3010) { throw "lwpad-devnode create failed ($rc)" }
if ($rc -eq 3010) { Write-Warning "Windows asked for a reboot to finish (unexpected for this driver)" }

# Wait for the driver's control interface to show up (the driver is running).
$deadline = (Get-Date).AddSeconds(15)
do {
    Start-Sleep -Milliseconds 300
    & (Join-Path $kit "bin\lwpad-test.exe") info *> $null
} while ($LASTEXITCODE -ne 0 -and (Get-Date) -lt $deadline)
if ($LASTEXITCODE -ne 0) { throw "Driver installed but its interface did not appear within 15 s" }
Step "installed; driver is running"
& $devnode status
