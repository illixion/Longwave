; Custom NSIS hooks for the Longwave Companion installer.
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
;   nsExec::Exec '"$SYSDIR\sc.exe" create LongwaveCompanion binPath= "$INSTDIR\resources\backend\LongwaveCompanionBackend.exe" start= auto'
;   nsExec::Exec '"$SYSDIR\sc.exe" start LongwaveCompanion'
; and set LONGWAVE_NO_SPAWN=1 for the app so it connects to the service instead of spawning.

!include nsDialogs.nsh
!include LogicLib.nsh

Var PcvrCheckbox
Var PcvrOptIn

; ---------------------------------------------------------------- the PCVR opt-in page
;
; PCVR / Foveated Streaming is the one part of this product that is not in the public source
; tree, and it is not in this installer either: it is a separate signed bundle the app fetches
; on demand (src/pcvr-installer.js). So this page cannot install anything — all it can do is
; record that the user wants it, which the app acts on the first time it runs.
;
; UNCHECKED BY DEFAULT, on purpose. Everything else in this installer is auditable open source
; built by public CI from a public commit; the PCVR bundle is a closed binary. Downloading one
; onto someone's machine is a choice they should make rather than one they should have to
; notice and undo. (To flip that, this is one BST_ constant below — but read that sentence
; again first.) The app's PCVR tab offers the same download at any time, so nothing is lost by
; declining here.
!macro customPageAfterChangeDir
  Page custom PcvrOptInPageCreate PcvrOptInPageLeave
!macroend

Function PcvrOptInPageCreate
  ; Skip the whole page on Windows-on-ARM. CloudXR is x64-only and the feature needs an NVIDIA
  ; RTX GPU, so there is nothing to offer — and offering it would hand the user a checkbox that
  ; leads to a download that cannot exist. The app hides the PCVR tabs on the same hosts
  ; (pcvr-installer.js's isSupportedHost), so the two halves agree.
  ;
  ; Read from the environment rather than from the installer's own bitness: this stub is 32-bit
  ; x86 whatever it was built for, and under ARM64 emulation PROCESSOR_ARCHITECTURE reports
  ; "x86" while PROCESSOR_ARCHITEW6432 reports "ARM64" — so the second variable is the one that
  ; answers "what is this machine", and checking only the first would never skip anything.
  ; Aborting a custom page's create function skips the page; $PcvrOptIn keeps its zero value,
  ; so customInstall records a clear opt-out.
  ReadEnvStr $0 "PROCESSOR_ARCHITEW6432"
  ${If} $0 == "ARM64"
    Abort
  ${EndIf}
  ReadEnvStr $0 "PROCESSOR_ARCHITECTURE"
  ${If} $0 == "ARM64"
    Abort
  ${EndIf}

  !insertmacro MUI_HEADER_TEXT "PCVR / Foveated Streaming" "Optional, and not part of this download"

  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 34u "Longwave can stream PC VR to Apple Vision Pro with gaze-driven foveated rendering. That component is closed source and is not included here — the app downloads it separately, verifies its signature, and installs it for you."
  Pop $0

  ${NSD_CreateCheckbox} 0 40u 100% 12u "Set up PCVR support on first launch (about 300 MB)"
  Pop $PcvrCheckbox
  ${NSD_SetState} $PcvrCheckbox ${BST_UNCHECKED}

  ${NSD_CreateLabel} 0 58u 100% 42u "Requires an NVIDIA RTX GPU and the paid PCVR feature in Longwave on the headset. Registering its OpenXR layer asks for administrator consent once, at that point. You can change your mind at any time from the app's PCVR tab — nothing here is permanent."
  Pop $0

  nsDialogs::Show
FunctionEnd

Function PcvrOptInPageLeave
  ${NSD_GetState} $PcvrCheckbox $PcvrOptIn
FunctionEnd

!macro customInstall
  ; SetRegView 64 is load-bearing, not boilerplate. The NSIS stub electron-builder produces is
  ; a 32-bit executable, so its default registry view is the WOW6432Node redirect — a plain
  ; WriteRegDWORD here would land somewhere the 64-bit (or arm64) app cannot see, and the app
  ; would read "no opt-in" from a machine where the box was ticked. Nothing about that failure
  ; points at a registry view: the checkbox works, the install succeeds, and the feature simply
  ; never appears. Restored to the default afterwards so nothing later in the script inherits it.
  SetRegView 64
  ${If} $PcvrOptIn == ${BST_CHECKED}
    WriteRegDWORD HKLM "Software\Longwave\Companion" "PcvrOptIn" 1
  ${Else}
    ; Written as 0 rather than left absent, so that unticking the box on a repair install or an
    ; update actually revokes an earlier opt-in instead of silently keeping it.
    WriteRegDWORD HKLM "Software\Longwave\Companion" "PcvrOptIn" 0
  ${EndIf}
  SetRegView lastused
!macroend

!macro customUnInstall
  ; Best-effort: stop a running backend so its files aren't locked during uninstall.
  nsExec::Exec 'taskkill /F /IM LongwaveCompanionBackend.exe'
  ; And the PCVR processes, which the app supervises rather than the installer — they hold the
  ; bundle's DLLs open, and the bundle lives in per-user AppData that this elevated uninstaller
  ; has no business walking. The app's own PCVR tab removes the bundle (and hands back
  ; LIBOVR_DLL_DIR, which is a per-user value); this only makes sure nothing is still running.
  nsExec::Exec 'taskkill /F /IM LongwavePCVRHost.exe'
  nsExec::Exec 'taskkill /F /IM LongwaveSessionBroker.exe'
  SetRegView 64
  DeleteRegKey HKLM "Software\Longwave\Companion"
  SetRegView lastused
!macroend
