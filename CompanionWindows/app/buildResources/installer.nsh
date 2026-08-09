; Custom NSIS hooks for the VisionVNC Windows Companion installer.
;
; Deployment model (decided by the Step-1 spike): the backend runs as an INTERACTIVE-SESSION
; HELPER that the Electron app spawns on launch — NOT a Session-0 Windows Service. The spike
; could not confirm that Mobile Hotspot tethering (NetworkOperatorTetheringManager.
; StartTetheringAsync) works under SYSTEM/Session 0, and Microsoft's samples run it from an
; interactive desktop session. So the installer only lays down files + shortcuts; the backend is
; bundled under resources\backend and launched by the app.
;
; Since 2026-07-28 neither the app nor the backend is elevated (both asInvoker). Tethering
; elevates on demand: the backend re-launches itself as --tether-host via ShellExecute "runas"
; when the user turns the hotspot on. Nothing the installer does needs to change for that — but
; note the install itself is still perMachine, so installing asks for elevation once even though
; running does not.
;
; To switch to the service model later (once Session-0 tethering is validated on capable
; hardware), register the bundled exe here, e.g.:
;   nsExec::Exec '"$SYSDIR\sc.exe" create VisionVNCWindowsCompanion binPath= "$INSTDIR\resources\backend\VisionVNCWindowsCompanionBackend.exe" start= auto'
;   nsExec::Exec '"$SYSDIR\sc.exe" start VisionVNCWindowsCompanion'
; and set VISIONVNC_NO_SPAWN=1 for the app so it connects to the service instead of spawning.

!macro customInstall
!macroend

!macro customUnInstall
  ; Best-effort: stop a running backend so its files aren't locked during uninstall.
  nsExec::Exec 'taskkill /F /IM VisionVNCWindowsCompanionBackend.exe'
!macroend
