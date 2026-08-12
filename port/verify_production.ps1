# verify_production.ps1 - release audit for the shipped assembly-only VOODKA.
# Run after build.ps1 on both the Windows 10 build host and a Windows 11 host.

[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Config = "Release",
    [switch]$RunTests,
    [ValidateSet("Unit", "Integration", "All")]
    [string]$TestSuite = "Unit",
    [switch]$FullRun,
    [switch]$PackageRun,
    [switch]$SkipHardwareRuns,
    [ValidateRange(1, 20)]
    [int]$PackageRepeats = 3,
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
$runExePath = $exePath
$runWorkingDirectory = $repoRoot
$timelineRoot = $buildDir
$packageRoot = $null

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
    [int]$TimeoutSeconds,
    [string]$ExecutablePath,
    [string]$WorkingDirectory
) {
    Write-Host "Running $Name..."
    $process = Start-Process -FilePath $ExecutablePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
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

function Assert-ProductionTimeline([string]$TimelinePath) {
    if (-not (Test-Path -LiteralPath $TimelinePath)) {
        Fail "full playback did not produce the requested timeline $TimelinePath"
    }

    $lines = @(Get-Content -LiteralPath $TimelinePath)
    $header = "# frame qpc_us modpos audio_elapsed_us"
    if ($lines.Count -lt 17001) {
        Fail "production timeline contains only $($lines.Count - 1) frames; expected at least 17000"
    }
    if ($lines[0] -ne $header) {
        Fail "production timeline header does not match the A/V contract"
    }

    [UInt64]$previousFrame = 0
    [UInt32]$previousModPos = 0
    [UInt64]$previousAudioUs = 0
    for ($lineIndex = 1; $lineIndex -lt $lines.Count; ++$lineIndex) {
        $fields = $lines[$lineIndex] -split '\s+'
        if ($fields.Count -ne 4) {
            Fail "malformed production timeline row $lineIndex"
        }
        try {
            [UInt64]$frame = [UInt64]::Parse($fields[0], [Globalization.CultureInfo]::InvariantCulture)
            [UInt32]$modpos = [UInt32]::Parse($fields[2], [Globalization.CultureInfo]::InvariantCulture)
            [UInt64]$audioUs = [UInt64]::Parse($fields[3], [Globalization.CultureInfo]::InvariantCulture)
        } catch {
            Fail "malformed numeric value in production timeline row $lineIndex"
        }
        if ($frame -ne [UInt64]$lineIndex) {
            Fail "production timeline frame sequence breaks at row $lineIndex"
        }
        if ($lineIndex -gt 1 -and $modpos -lt $previousModPos) {
            Fail "production ModPos regressed at frame $frame"
        }
        if ($lineIndex -gt 1 -and $audioUs -lt $previousAudioUs) {
            Fail "production audio clock regressed at frame $frame"
        }
        $previousFrame = $frame
        $previousModPos = $modpos
        $previousAudioUs = $audioUs
    }

    if ($previousModPos -ne 0x2803) {
        Fail ("production playback ended at ModPos 0x{0:X}; expected 0x2803" -f $previousModPos)
    }
    if ($previousAudioUs -lt 200000000) {
        Fail "production audio timeline ended before 200 seconds"
    }
    Write-Host ("Timeline: {0} frames, terminal ModPos 0x{1:X}, audio {2} ms ({3})" -f
        $previousFrame, $previousModPos, [Math]::Round($previousAudioUs / 1000.0), $TimelinePath)
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
$dllCharacteristics = [BitConverter]::ToUInt16($bytes, $optional + 70)
$entryRva = [BitConverter]::ToUInt32($bytes, $optional + 16)
Write-Host ("PE: machine=0x{0:X4}, optional=0x{1:X4}, subsystem={2}, entry-RVA=0x{3:X}, DLL-characteristics=0x{4:X4}" -f
    $machine, $optionalMagic, $subsystem, $entryRva, $dllCharacteristics)
if ($machine -ne 0x8664) { Fail "production PE is not x64" }
if ($optionalMagic -ne 0x20b) { Fail "production PE is not PE32+" }
if ($subsystem -ne 2) { Fail "production PE is not a Windows GUI image" }
if (($dllCharacteristics -band 0x20) -eq 0) { Fail "production PE lacks high-entropy VA support" }
if (($dllCharacteristics -band 0x40) -eq 0) { Fail "production PE lacks ASLR/DynamicBase" }
if (($dllCharacteristics -band 0x100) -eq 0) { Fail "production PE lacks NX compatibility" }
Write-Host "Image contract: high-entropy VA, ASLR, and NX compatible"

# Validate the generated shipped-target graph, not merely the final binary.
$projectText = Get-Content -LiteralPath $projectPath -Raw
if ($projectText -match '<ClCompile\s+Include=' -or
    $projectText -match '(?i)<ClCompile[^>]+Include="[^"]+\.(c|cc|cpp|cxx)"') {
    Fail "generated VOODKA project contains a C/C++ compile entry"
}
$nasmEntries = ([regex]::Matches($projectText, '<NASM\s')).Count
if ($nasmEntries -eq 0) { Fail "generated VOODKA project contains no NASM entries" }
Write-Host "Source graph: $nasmEntries NASM entries, 0 C/C++ compile entries"
if ($projectText -notmatch '<EntryPointSymbol>asm_voodka_process_entry</EntryPointSymbol>') {
    Fail "generated VOODKA project does not use the native NASM process entry"
}
if ($projectText -notmatch '<IgnoreAllDefaultLibraries>true</IgnoreAllDefaultLibraries>') {
    Fail "generated VOODKA project does not disable default CRT libraries"
}
if ($projectText -notmatch '<SubSystem>Windows</SubSystem>') {
    Fail "generated VOODKA project is not configured as a Windows GUI image"
}
Write-Host "Link contract: native NASM entry, /NODEFAULTLIB, Windows subsystem"

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
    $ctestArgs = @("--test-dir", $buildDir, "-C", $Config, "--output-on-failure")
    if ($SkipHardwareRuns -and $TestSuite -ne "Unit") {
        Fail "-SkipHardwareRuns is only compatible with -TestSuite Unit"
    }
    if ($SkipHardwareRuns -or $TestSuite -eq "Unit") {
        $ctestArgs += @("--label-regex", "^unit$")
    } elseif ($TestSuite -eq "Integration") {
        $ctestArgs += @("--label-regex", "^integration$")
    }
    & $ctest.Source @ctestArgs
    if ($LASTEXITCODE -ne 0) { Fail "CTest returned $LASTEXITCODE" }
}

if ($SkipHardwareRuns -and ($FullRun -or $PackageRun)) {
    Fail "-SkipHardwareRuns cannot be combined with -FullRun or -PackageRun"
}

try {
    if ($SkipHardwareRuns) {
        Write-Host "Hosted-runner-safe verification: skipping real D3D11/WASAPI/window playback"
    } elseif ($PackageRun) {
        $archivePath = Join-Path $binDir "data\vodka.dat"
        $musicPath = Join-Path $binDir "music\amnezja2.mod"
        foreach ($requiredPackageFile in @($archivePath, $musicPath)) {
            if (-not (Test-Path -LiteralPath $requiredPackageFile)) {
                Fail "missing staged package file $requiredPackageFile"
            }
        }

        $packageRoot = Join-Path $buildDir ("production_package_{0:yyyyMMdd_HHmmssfff}" -f (Get-Date))
        $resolvedBuildDir = [IO.Path]::GetFullPath($buildDir).TrimEnd('\')
        $resolvedPackageRoot = [IO.Path]::GetFullPath($packageRoot)
        if (-not $resolvedPackageRoot.StartsWith($resolvedBuildDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Fail "refusing to create package outside the release build directory"
        }
        New-Item -ItemType Directory -Path (Join-Path $packageRoot "data") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $packageRoot "music") | Out-Null
        Copy-Item -LiteralPath $exePath -Destination (Join-Path $packageRoot "VOODKA.exe")
        Copy-Item -LiteralPath $archivePath -Destination (Join-Path $packageRoot "data\vodka.dat")
        Copy-Item -LiteralPath $musicPath -Destination (Join-Path $packageRoot "music\amnezja2.mod")
        $runExePath = Join-Path $packageRoot "VOODKA.exe"
        $runWorkingDirectory = $packageRoot
        $timelineRoot = $packageRoot
        Write-Host "Package: isolated VOODKA.exe + data\vodka.dat + music\amnezja2.mod"
    }

    if (-not $SkipHardwareRuns) {
        $packageSmokeRepeats = if ($PackageRun) { $PackageRepeats } else { 1 }
        for ($packageSmokeIndex = 1; $packageSmokeIndex -le $packageSmokeRepeats; ++$packageSmokeIndex) {
            $smokeName = "P4 scene smoke"
            if ($packageSmokeRepeats -gt 1) {
                $smokeName = "P4 scene smoke ($packageSmokeIndex/$packageSmokeRepeats)"
            }
            Invoke-ProductionRun $smokeName @(
                "--part", "4", "--auto-close-ms", $P4SmokeMs.ToString()
            ) 30 $runExePath $runWorkingDirectory
        }

        if ($FullRun) {
            $timeline = Join-Path -Path $timelineRoot -ChildPath ("production_verify_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
            Invoke-ProductionRun "full production playback" @(
                "--timeline", $timeline
            ) $FullRunTimeoutSec $runExePath $runWorkingDirectory
            Assert-ProductionTimeline $timeline
        } else {
            Write-Host "Full production playback not requested; use -FullRun for certification."
        }
    }
} finally {
    if ($packageRoot -and (Test-Path -LiteralPath $packageRoot)) {
        Remove-Item -LiteralPath $packageRoot -Recurse -Force
    }
}

Write-Host "Production verification passed."
