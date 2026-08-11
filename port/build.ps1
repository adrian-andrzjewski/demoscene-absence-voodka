# build.ps1 - reproducible VS2022 x64 build for the VOODKA Windows port.
#
# Locates a Visual Studio installation (2022 preferred, 2026 accepted),
# imports its x64 dev environment via VsDevCmd.bat, then configures and
# builds with CMake using the vendored NASM. The C++ compiler is needed only
# for host tools and the non-shipped reference oracle; VOODKA.exe itself is
# assembly-only. No external package manager or DOS toolchain is required.
#
# Usage:
#   .\build.ps1                # configure + build Debug
#   .\build.ps1 -Config Release
#   .\build.ps1 -Clean
#   .\build.ps1 -Test          # run CTest after building

param(
    [ValidateSet("Debug", "Release")]
    [string]$Config = "Debug",
    [switch]$Clean,
    [switch]$Test
)

$ErrorActionPreference = "Stop"
# Repo root derived from this script's location (port/build.ps1 -> repo root);
# keeps the build relocatable across machines/checkouts.
$root = Split-Path -Parent $PSScriptRoot
$port = Join-Path $root "port"
$buildDir = Join-Path $port "build"
$EXE_PATH = $env:COMSPEC

# ---- locate VS instance via vswhere ----------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found - Visual Studio Build Tools / Community required (2022 or 2026)."
}
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    throw "No Visual Studio with the VC++ x64 toolset detected."
}
Write-Host "Using Visual Studio at: $vsPath"

# Prefer VS2022 over VS2026 when both are present (task targets VS2022).
$vs2022 = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -version "[17,18)" -property installationPath
if ($vs2022) {
    $vsPath = ($vs2022 | Select-Object -First 1)
    Write-Host "Preferring VS2022: $vsPath"
}

$devcmd = Join-Path $vsPath "Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path $devcmd)) {
    throw "VsDevCmd.bat not found at $devcmd"
}

# ---- import VS x64 environment into this process & children ---------------
$importFile = Join-Path $port "build_vs_env.cmd"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$inner = @"
@echo off
call "$devcmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b 1
"@
$inner | Set-Content -LiteralPath $importFile -Encoding Ascii

if ($Clean -and (Test-Path $buildDir)) {
    Remove-Item -LiteralPath $buildDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

# ---- configure + build via cmd so VsDevCmd env propagates ------------------
$cmakeD = Join-Path $buildDir $Config
New-Item -ItemType Directory -Force -Path $cmakeD | Out-Null

$nasmpath = Join-Path $root "modules\nasm\nasm.exe"

$scriptLines = @(
    "call `"$importFile`""
    'if errorlevel 1 exit /b 1'
    "set `"NASM=$nasmpath`""
    "cmake -S `"$port`" -B `"$cmakeD`" -G `"Visual Studio 17 2022`" -A x64 `"-DCMAKE_ASM_NASM_COMPILER=$nasmpath`""
    'if errorlevel 1 exit /b 1'
    "cmake --build `"$cmakeD`" --config $Config --parallel"
)
if ($Test) {
    $scriptLines += "ctest --test-dir `"$cmakeD`" -C $Config --output-on-failure"
    $scriptLines += 'if errorlevel 1 exit /b 1'
}
$driver = Join-Path $buildDir "run_build.cmd"
$scriptLines | Set-Content -LiteralPath $driver -Encoding Ascii
& $EXE_PATH /d /c $driver
exit $LASTEXITCODE
