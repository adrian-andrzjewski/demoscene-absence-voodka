# verify_production.ps1 - release audit for the shipped assembly-only VOODKA.
# Run after build.ps1 on both the Windows 10 build host and a Windows 11 host.

[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Config = "Release",
    [switch]$RunTests,
    [switch]$FullRun,
    [int]$P4SmokeMs = 3000,
    [int]$FullRunTimeoutSec = 330
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$portRoot = Join-Path $repoRoot "port"
$binDir = Join-Path $portRoot "bin\$Config"
$buildDir = Join-Path $portRoot "build\$Config"
$exePath = Join-Path $binDir "VOODKA.exe"
$projectPath = Join-Path $buildDir "platform\VOODKA.vcxproj"

function Fail([string]$Message) {
    throw "Production verification failed: $Message"
}

function Find-Dumpbin {
    $command = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $vswhere = Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $vsPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
        if ($vsPath) {
            $candidate = Get-ChildItem -LiteralPath (Join-Path $vsPath "VC\Tools\MSVC") -Filter dumpbin.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($candidate) { return $candidate.FullName }
        }
    }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -Unique
    $candidate = Get-ChildItem -Path $roots -Filter dumpbin.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Invoke-ProductionRun(
    [string]$Name,
    [string[]]$Arguments,
    [int]$TimeoutSeconds
) {
    Write-Host "Running $Name..."
    $process = Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru
    Wait-Process -InputObject $process -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue | Out-Null
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Fail "$Name exceeded the $TimeoutSeconds second timeout"
    }
    if ($process.ExitCode -ne 0) {
        Fail "$Name exited with code $($process.ExitCode)"
    }
    Write-Host "${Name}: exit 0"
}

if (-not (Test-Path -LiteralPath $exePath)) {
    Fail "missing $exePath; run port/build.ps1 first"
}
if (-not (Test-Path -LiteralPath $projectPath)) {
    Fail "missing generated production project $projectPath; configure/build first"
}

$os = Get-ComputerInfo -Property WindowsProductName, WindowsVersion,
    OsBuildNumber, OsArchitecture
Write-Host ("Host: {0}, version {1}, build {2}, {3}" -f
    $os.WindowsProductName, $os.WindowsVersion, $os.OsBuildNumber,
    $os.OsArchitecture)

# Validate the PE contract without relying on a linker interpretation.
$bytes = [IO.File]::ReadAllBytes($exePath)
if ($bytes.Length -lt 0x100) { Fail "production PE is unexpectedly small" }
$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
if ($peOffset -lt 0 -or $peOffset + 0x70 -ge $bytes.Length) {
    Fail "invalid PE header offset"
}
if ([BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x00004550) {
    Fail "missing PE signature"
}
$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
$optional = $peOffset + 24
$optionalMagic = [BitConverter]::ToUInt16($bytes, $optional)
$subsystem = [BitConverter]::ToUInt16($bytes, $optional + 68)
$entryRva = [BitConverter]::ToUInt32($bytes, $optional + 16)
Write-Host ("PE: machine=0x{0:X4}, optional=0x{1:X4}, subsystem={2}, entry-RVA=0x{3:X}" -f
    $machine, $optionalMagic, $subsystem, $entryRva)
if ($machine -ne 0x8664) { Fail "production PE is not x64" }
if ($optionalMagic -ne 0x20b) { Fail "production PE is not PE32+" }
if ($subsystem -ne 2) { Fail "production PE is not a Windows GUI image" }

# Validate the generated shipped-target graph, not merely the final binary.
$projectText = Get-Content -LiteralPath $projectPath -Raw
if ($projectText -match '<ClCompile\s+Include=' -or
    $projectText -match '(?i)<ClCompile[^>]+Include="[^"]+\.(c|cc|cpp|cxx)"') {
    Fail "generated VOODKA project contains a C/C++ compile entry"
}
$nasmEntries = ([regex]::Matches($projectText, '<NASM\s')).Count
if ($nasmEntries -eq 0) { Fail "generated VOODKA project contains no NASM entries" }
Write-Host "Source graph: $nasmEntries NASM entries, 0 C/C++ compile entries"

# The reference/tool graph may contain libxmp; the shipped PE must not import
# it or any CRT/C++ runtime.
$dumpbinPath = Find-Dumpbin
if (-not $dumpbinPath) { Fail "dumpbin.exe not found" }
$dependents = & $dumpbinPath /dependents $exePath 2>&1 | Out-String
if ($dependents -match '(?im)ucrt|vcruntime|msvcp|libxmp|api-ms-win-crt') {
    Fail "forbidden CRT/C++/libxmp dependency detected`n$dependents"
}
foreach ($requiredDll in @("d3d11.dll", "ole32.dll", "KERNEL32.dll", "USER32.dll", "GDI32.dll")) {
    if ($dependents -notmatch "(?im)^\s*$([regex]::Escape($requiredDll))\s*$") {
        Fail "expected direct dependency $requiredDll is missing"
    }
}
Write-Host "Imports: expected Win32/D3D11/COM surface only; no CRT/C++/libxmp"

if ($RunTests) {
    $ctest = Get-Command ctest.exe -ErrorAction SilentlyContinue
    if (-not $ctest) { Fail "ctest.exe not found" }
    & $ctest.Source --test-dir $buildDir -C $Config --output-on-failure
    if ($LASTEXITCODE -ne 0) { Fail "CTest returned $LASTEXITCODE" }
}

Invoke-ProductionRun "P4 scene smoke" @(
    "--part", "4", "--auto-close-ms", $P4SmokeMs.ToString()
) 30

if ($FullRun) {
    $timeline = Join-Path -Path $buildDir -ChildPath ("production_verify_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
    Invoke-ProductionRun "full production playback" @(
        "--timeline", $timeline
    ) $FullRunTimeoutSec
    Write-Host "Timeline: $timeline"
} else {
    Write-Host "Full production playback not requested; use -FullRun for certification."
}

Write-Host "Production verification passed."
