param([string]$Target = "cyberpunkvrport_stereo")
$ErrorActionPreference = "Continue"
$log = "C:\lwvr\cpvr\build.log"
"start $(Get-Date -Format s)" | Out-File $log
cd C:\lwvr\cpvr\repo
if ($true) {
  cmake -S . -B build -G "Visual Studio 17 2022" -A x64 -DCVR_RED4EXT_SDK_DIR=C:/lwvr/cpvr/sdk *>> $log
  "configure exit $LASTEXITCODE" | Out-File $log -Append
}
cmake --build build --config Release --target $Target -- /m /v:m /clp:ErrorsOnly *>> $log
"BUILD-DONE exit $LASTEXITCODE $(Get-Date -Format s)" | Out-File $log -Append
