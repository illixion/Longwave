# Runs the vhf-gamepad kit inside the test VM from the Hyper-V HOST, the way the
# 2026-10-04 Windows 11 run did it: no network, no RDP, no clicking.
#
#   powershell -ExecutionPolicy Bypass -File .\Run-KitInVM.ps1 -KitZip C:\path\lwpad-kit.zip
#
# 1. PowerShell Direct (Invoke-Command -VMName) as the VM's local admin; the
#    password file is the one New-Win11TestVM.ps1 wrote.
# 2. Brings Defender's signatures up to date first. A fresh install's Defender
#    can be too old for its cloud (MAPS answers HTTP 426), and Smart App Control
#    then lets unknown files through that it would otherwise block, so a test
#    run before the first update says nothing about SAC.
# 3. Copies the kit in and runs run-gamepad-spike.ps1 -KeepInstalled in the
#    signed-in user's DESKTOP session (a scheduled task with an Interactive
#    principal, elevated): PowerShell Direct itself is session 0, where
#    Windows.Gaming.Input has no foreground window.
# 4. Reboots the guest gracefully (shutdown /r inside it; Restart-VM is a hard
#    reset that can lose a just-installed device node with the unflushed
#    registry) and runs -AfterReboot.
# 5. Copies results\*.log back to -OutDir.
param(
    [Parameter(Mandatory)] [string] $KitZip,
    [string] $Name = "LongwaveWin11Test",
    [string] $User = "lwtest",
    [string] $PasswordFile = (Join-Path (Split-Path -Parent (Get-VM $Name).Path) "$User-password.txt"),
    [string] $OutDir = (Join-Path $PSScriptRoot "results"),
    [string] $GuestKit = "C:\lwpad-kit",
    [switch] $NoReboot
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$cred = New-Object PSCredential($User, (ConvertTo-SecureString (Get-Content $PasswordFile -Raw).Trim() -AsPlainText -Force))

function Wait-Desktop {
    $t0 = Get-Date
    do {
        Start-Sleep 5
        $n = Invoke-Command -VMName $Name -Credential $cred -ErrorAction SilentlyContinue { @(Get-Process explorer -ErrorAction SilentlyContinue).Count }
    } while (-not $n -and ((Get-Date) - $t0).TotalSeconds -lt 600)
    if (-not $n) { throw "no desktop session in $Name after 10 minutes" }
    Start-Sleep 20   # let the shell and services settle
}

function Invoke-KitInDesktop([string] $KitArgs) {
    Invoke-Command -VMName $Name -Credential $cred -ArgumentList $GuestKit, $KitArgs, $User {
        param($kit, $kitArgs, $user)
        $task = "lwpad-kit-run"
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -WorkingDirectory $kit `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$kit\run-gamepad-spike.ps1`" $kitArgs"
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal `
            -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)) | Out-Null
        Start-ScheduledTask -TaskName $task
        $t0 = Get-Date
        Start-Sleep 3
        while ((Get-ScheduledTask -TaskName $task).State -eq "Running" -and ((Get-Date) - $t0).TotalMinutes -lt 30) { Start-Sleep 3 }
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
        $log = Get-ChildItem "$kit\results\*.log" | Sort-Object LastWriteTime | Select-Object -Last 1
        "{0}: {1}" -f $log.Name, ((Get-Content $log.FullName | Select-String "^PASS \d+ ").Line)
    }
}

"== waiting for the desktop session"
Wait-Desktop
"== Defender signatures and cloud"
Invoke-Command -VMName $Name -Credential $cred {
    # Defender's WMI provider can be briefly unavailable ("Provider load
    # failure") right after a boot or update; none of this is fatal.
    for ($i = 0; $i -lt 6; $i++) {
        try {
            Update-MpSignature -UpdateSource MicrosoftUpdateServer -ErrorAction Stop
            $s = Get-MpComputerStatus -ErrorAction Stop
            "signatures $($s.AntivirusSignatureVersion) ($($s.AntivirusSignatureAge) days), SAC $($s.SmartAppControlState)"
            break
        } catch { Start-Sleep 10 }
    }
    (& "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -ValidateMapsConnection 2>&1 | Select-String "establish").Line
}

"== copying the kit"
$session = New-PSSession -VMName $Name -Credential $cred
Copy-Item -ToSession $session -Path $KitZip -Destination "C:\lwpad-kit.zip" -Force
Invoke-Command -Session $session -ArgumentList $GuestKit {
    param($kit)
    Remove-Item -Recurse -Force $kit -ErrorAction SilentlyContinue
    Expand-Archive C:\lwpad-kit.zip $kit
}
Remove-PSSession $session

"== run 1: install, test, keep installed"
Invoke-KitInDesktop "-KeepInstalled"
if (-not $NoReboot) {
    "== graceful reboot"
    $before = (Get-VM $Name).Uptime
    Invoke-Command -VMName $Name -Credential $cred { shutdown.exe /r /t 0 /d p:4:1 /c "lwpad reboot check" }
    $t0 = Get-Date
    do { Start-Sleep 3 } while ((Get-VM $Name).Uptime -ge $before -and ((Get-Date) - $t0).TotalSeconds -lt 300)
    Wait-Desktop
    "== run 2: after reboot, test, uninstall"
    Invoke-KitInDesktop "-AfterReboot"
}

"== copying logs to $OutDir"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$session = New-PSSession -VMName $Name -Credential $cred
Copy-Item -FromSession $session -Path "$GuestKit\results\*" -Destination $OutDir -Force
Remove-PSSession $session
Get-ChildItem $OutDir -Filter *.log | ForEach-Object { "   $($_.Name)" }
