<#
.SYNOPSIS
  Build Longwave's patched OpenComposite runtime.

.DESCRIPTION
  The upstream openxr binary aborts The Lab while loading its Valve Index bindings. Multiple dpad
  directions reuse one trackpad click action: the first creates a float action for Index force
  thresholds, while later directions forget that choice and query it as boolean. The bundled patch
  preserves the action type for every direction.

  The source revision is pinned because the patch and resulting runtime are part of the PCVR
  compatibility surface. This script builds one architecture and prints the resulting DLL path;
  pass it to install-opencomposite.ps1 -Payload with the same -Arch.
#>
[CmdletBinding()]
param(
  [ValidateSet('x64', 'x86')] [string] $Arch = 'x64',
  [string] $Source = 'C:\dev\OpenComposite-src',
  [string] $Commit = 'cff07db75c4823afe93ed7027b03d5f7bc86f164',
  [string] $Repository = 'https://gitlab.com/znixian/OpenOVR.git',
  [string] $Patch = (Join-Path $PSScriptRoot '..\patches\opencomposite-longwave.patch')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string] $message) { Write-Host "[opencomposite-build] $message" }

$Patch = [IO.Path]::GetFullPath($Patch)
if (-not (Test-Path $Patch)) { throw "Longwave patch not found: $Patch" }

if (-not (Test-Path (Join-Path $Source '.git'))) {
  Say "cloning pinned source into $Source"
  git clone --branch openxr --single-branch $Repository $Source
}

$dirty = @(git -C $Source status --porcelain --untracked-files=no)
$currentCommit = git -C $Source rev-parse HEAD
if ($dirty.Count -gt 0) {
  git -C $Source apply --reverse --check $Patch
  if ($LASTEXITCODE -ne 0 -or $currentCommit -ne $Commit) {
    throw "$Source has unrelated local changes; refusing to overwrite a developer checkout"
  }
  Say 'patch already applied'
} else {
  git -C $Source fetch origin openxr
  git -C $Source checkout --detach $Commit
  git -C $Source submodule update --init --recursive
  git -C $Source apply --check $Patch
  if ($LASTEXITCODE -ne 0) { throw "Longwave patch does not apply to OpenComposite $Commit" }
  git -C $Source apply $Patch
}

$vulkan = Join-Path $Source 'libs\vulkan'
if (-not (Test-Path (Join-Path $vulkan 'Lib\vulkan-1.lib'))) {
  $cache = Join-Path $env:TEMP 'Longwave-OpenComposite'
  New-Item -ItemType Directory -Force -Path $cache | Out-Null
  $archive = Join-Path $cache 'vulkan-minisdk.7z'
  $sevenZip = Join-Path $cache '7zr.exe'
  if (-not (Test-Path $archive)) {
    Invoke-WebRequest 'https://znix.xyz/random/vulkan-1.1.85.0-minisdk.7z' -OutFile $archive
  }
  if (-not (Test-Path $sevenZip)) {
    Invoke-WebRequest 'https://www.7-zip.org/a/7zr.exe' -OutFile $sevenZip
  }
  & $sevenZip x $archive "-o$(Join-Path $Source 'libs')" -y | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $vulkan 'Lib\vulkan-1.lib'))) {
    throw 'Could not stage the Vulkan mini SDK'
  }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = if (Test-Path $vswhere) {
  & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.ATL `
    -property installationPath
}
if (-not $installation) {
  throw 'Visual C++ ATL is required. Add Microsoft.VisualStudio.Component.VC.ATL to VS Build Tools.'
}

$platform = if ($Arch -eq 'x64') { 'x64' } else { 'Win32' }
$build = Join-Path $Source "build-$Arch"
cmake -S $Source -B $build -A $platform -DOC_VERSION="Longwave $Commit"
if ($LASTEXITCODE -ne 0) { throw 'OpenComposite configure failed' }
cmake --build $build --config Release --target OCOVR -- /nologo /verbosity:minimal
if ($LASTEXITCODE -ne 0) { throw 'OpenComposite build failed' }

$dll = if ($Arch -eq 'x64') { 'vrclient_x64.dll' } else { 'vrclient.dll' }
$output = Join-Path $build "bin\Release\$dll"
if (-not (Test-Path $output)) { throw "Build completed without $output" }
Say "built $output"
Write-Output $output
