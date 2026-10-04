# Builds, tests or packages LongwaveStream on Windows x64.
#
#   scripts\windows.ps1 -Action Build|Test|Package [-Strip] [-StaticStdlib] [-Out <dir>]
#
# -Strip builds without debug info. SwiftPM's release configuration embeds
# DWARF in the .exe on Windows (measured: 15.5 MB of a 19.3 MB exe); a shipping
# build should strip it, or move it to a separate PDB for crash symbolication.
# -StaticStdlib is accepted by SwiftPM but has no effect with the 6.2.4 Windows
# SDK, which ships no static Swift runtime (no usr\lib\swift_static).
#
# Package builds release and copies longwave-host-spike.exe plus every DLL it
# needs from the Swift toolchain's runtime folder into one self-contained
# directory (default: .build\dist), walking the import tables with dumpbin.
# DLLs that ship with Windows (kernel32, d3d11, api-ms-win-*, ...) are left out.
#
# The environment set-up follows Oneiros' scripts\engine-windows.ps1: an SSH
# session can predate the Swift installer, so reload PATH/SDKROOT from the
# registry, then enter the Visual Studio x64 developer shell for link.exe,
# the Windows SDK libraries and dumpbin.
param(
    [ValidateSet('Build', 'Test', 'Package')]
    [string]$Action = 'Build',
    [switch]$StaticStdlib,
    [switch]$Strip,
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$package = Resolve-Path (Join-Path $PSScriptRoot '..')

$env:Path += ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine') +
    ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $env:SDKROOT) {
    $env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
    if (-not $env:SDKROOT) { $env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT', 'Machine') }
}
if (-not $env:SDKROOT -or -not (Test-Path $env:SDKROOT)) { throw 'Install the Swift Windows SDK first.' }

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'No Visual Studio installation with the x64 C++ toolchain was found.' }
Import-Module (Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null

& swift --version
$buildArgs = @('--package-path', $package)
if ($StaticStdlib) { $buildArgs += '--static-swift-stdlib' }
if ($Strip) {
    $buildArgs += @('--scratch-path', (Join-Path $package '.build-strip'),
                    '-Xswiftc', '-gnone', '-Xcc', '-g0', '-Xcxx', '-g0')
}

switch ($Action) {
    'Build' { & swift build @buildArgs; exit $LASTEXITCODE }
    'Test' { & swift test @buildArgs; exit $LASTEXITCODE }
}

# ---- Package ----
& swift build -c release @buildArgs --product longwave-host-spike
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$binPath = (& swift build -c release @buildArgs --show-bin-path).Trim()
$exe = Join-Path $binPath 'longwave-host-spike.exe'
if (-not $Out) { $Out = Join-Path $package '.build\dist' }
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force $Out | Out-Null
Copy-Item $exe $Out

# Where redistributable DLLs come from: the Swift runtime folder on PATH
# (it also carries the matching MSVC runtime, vcruntime140/msvcp140).
$runtimeDir = Split-Path (Get-Command swiftCore.dll -ErrorAction Stop).Source
Write-Output "Swift runtime: $runtimeDir"

$queue = [System.Collections.Generic.Queue[string]]::new()
$queue.Enqueue($exe)
$seen = @{}
while ($queue.Count -gt 0) {
    $binary = $queue.Dequeue()
    $deps = & dumpbin /nologo /dependents $binary | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim() }
    foreach ($dep in $deps) {
        $key = $dep.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $candidate = Join-Path $runtimeDir $dep
        if (Test-Path $candidate) {
            Copy-Item $candidate $Out
            $queue.Enqueue($candidate)
        }
    }
}

$files = Get-ChildItem $Out | Sort-Object Length -Descending
$files | Format-Table Name, @{ n = 'KB'; e = { [math]::Round($_.Length / 1KB) } } -AutoSize | Out-String -Width 120
$total = ($files | Measure-Object Length -Sum).Sum
Write-Output ("{0} files, {1:N1} MB total" -f $files.Count, ($total / 1MB))
$systemDeps = $seen.Keys | Where-Object { -not (Test-Path (Join-Path $Out $_)) } | Sort-Object
Write-Output ("left to Windows: " + ($systemDeps -join ', '))
