# package_release.ps1 - build the self-contained playable VOODKA release.
#
# The production executable has exactly two repository-owned runtime inputs:
# data\vodka.dat and music\amnezja2.mod. This script stages those inputs next
# to VOODKA.exe, adds the main README, validates the staged tree in isolation,
# and creates a versioned ZIP archive.

[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Config = "Release",
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^voodka-port-v[0-9]+\.[0-9]+\.[0-9]+$")]
    [string]$Version,
    [string]$OutputDirectory,
    [switch]$SkipHardwareSmoke
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    throw "Release packaging failed: $Message"
}

function Get-RelativeEntry([string]$BasePath, [string]$Path) {
    $base = [IO.Path]::GetFullPath($BasePath).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Fail "path '$full' is outside package root '$base'"
    }
    return $full.Substring($base.Length + 1).Replace('\', '/')
}

function Assert-FileSet([string]$Root, [string[]]$Expected) {
    $actual = @(
        Get-ChildItem -LiteralPath $Root -File -Recurse |
            ForEach-Object { Get-RelativeEntry $Root $_.FullName } |
            Sort-Object
    )
    $expectedSorted = @($Expected | Sort-Object)
    $differences = @(Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actual)
    if ($differences.Count -ne 0) {
        $detail = ($differences | ForEach-Object {
            "$($_.SideIndicator) $($_.InputObject)"
        }) -join "; "
        Fail "package file set differs from the declared release layout: $detail"
    }
}

function Assert-DirectorySet([string]$Root, [string[]]$Expected) {
    $actual = @(
        Get-ChildItem -LiteralPath $Root -Directory -Recurse |
            ForEach-Object { Get-RelativeEntry $Root $_.FullName } |
            Sort-Object
    )
    $expectedSorted = @($Expected | Sort-Object)
    $differences = @(Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actual)
    if ($differences.Count -ne 0) {
        $detail = ($differences | ForEach-Object {
            "$($_.SideIndicator) $($_.InputObject)"
        }) -join "; "
        Fail "package directory set differs from the declared release layout: $detail"
    }
}

function Invoke-IsolatedSmoke([string]$Executable, [string]$WorkingDirectory) {
    Write-Host "Running packaged P4 smoke from: $WorkingDirectory"
    $process = Start-Process -FilePath $Executable `
        -ArgumentList @("--part", "4", "--auto-close-ms", "3000") `
        -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
    Wait-Process -InputObject $process -Timeout 45 -ErrorAction SilentlyContinue | Out-Null
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Fail "packaged P4 smoke exceeded the 45 second timeout"
    }
    if ($process.ExitCode -ne 0) {
        Fail "packaged P4 smoke exited with code $($process.ExitCode)"
    }
}

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$portRoot = Join-Path $repoRoot "port"
$binRoot = Join-Path $portRoot "bin\$Config"
$sourceExe = Join-Path $binRoot "VOODKA.exe"
$sourceData = Join-Path $binRoot "data\vodka.dat"
$sourceMusic = Join-Path $binRoot "music\amnezja2.mod"
$sourceReadme = Join-Path $repoRoot "README.md"

foreach ($requiredSource in @($sourceExe, $sourceData, $sourceMusic, $sourceReadme)) {
    if (-not (Test-Path -LiteralPath $requiredSource)) {
        Fail "missing required build or documentation input: $requiredSource"
    }
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $portRoot "release"
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$packageName = "VOODKA-$Version"
$packageRoot = Join-Path $outputRoot $packageName
$archivePath = Join-Path $outputRoot "$packageName.zip"

# Only remove the exact generated package and archive. Never remove the output
# directory itself, which may be a caller-owned temporary directory.
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
if (Test-Path -LiteralPath $packageRoot) {
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}

New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot "data") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot "music") | Out-Null

Copy-Item -LiteralPath $sourceExe -Destination (Join-Path $packageRoot "VOODKA.exe")
Copy-Item -LiteralPath $sourceData -Destination (Join-Path $packageRoot "data\vodka.dat")
Copy-Item -LiteralPath $sourceMusic -Destination (Join-Path $packageRoot "music\amnezja2.mod")
Copy-Item -LiteralPath $sourceReadme -Destination (Join-Path $packageRoot "README.md")

$expectedFiles = @(
    "VOODKA.exe",
    "data/vodka.dat",
    "music/amnezja2.mod",
    "README.md"
)
$expectedDirectories = @("data", "music")

Assert-FileSet $packageRoot $expectedFiles
Assert-DirectorySet $packageRoot $expectedDirectories
foreach ($runtimeFile in @("VOODKA.exe", "data/vodka.dat", "music/amnezja2.mod")) {
    $runtimePath = Join-Path $packageRoot ($runtimeFile.Replace('/', '\'))
    if ((Get-Item -LiteralPath $runtimePath).Length -le 0) {
        Fail "runtime file is empty: $runtimeFile"
    }
}

if ($SkipHardwareSmoke) {
    Write-Host "Skipping packaged P4 runtime smoke (hardware/session capability not guaranteed)"
} else {
    Invoke-IsolatedSmoke (Join-Path $packageRoot "VOODKA.exe") $packageRoot
}

# The executable writes diagnostics beside itself during a run. They are
# useful during validation but are not release inputs and must never enter the
# deterministic archive.
foreach ($generatedDiagnostic in @("voodka.log", "voodka-crash.log")) {
    $diagnosticPath = Join-Path $packageRoot $generatedDiagnostic
    if (Test-Path -LiteralPath $diagnosticPath) {
        Remove-Item -LiteralPath $diagnosticPath -Force
    }
}
Assert-FileSet $packageRoot $expectedFiles
Assert-DirectorySet $packageRoot $expectedDirectories

Compress-Archive -LiteralPath $packageRoot -DestinationPath $archivePath -CompressionLevel Optimal
if (-not (Test-Path -LiteralPath $archivePath)) {
    Fail "ZIP archive was not created: $archivePath"
}

# Expand the archive into a private sibling directory and validate its exact
# file set. This catches accidental files omitted by ZIP creation as well as
# path/layout changes that a directory-only check would miss.
$verifyRoot = Join-Path $outputRoot (".{0}.zip-check" -f $packageName)
if (Test-Path -LiteralPath $verifyRoot) {
    Remove-Item -LiteralPath $verifyRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $verifyRoot | Out-Null
try {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $verifyRoot
    $expandedPackage = Join-Path $verifyRoot $packageName
    if (-not (Test-Path -LiteralPath $expandedPackage)) {
        Fail "ZIP archive does not contain the expected root directory $packageName"
    }
    Assert-FileSet $expandedPackage $expectedFiles
    Assert-DirectorySet $expandedPackage $expectedDirectories
} finally {
    if (Test-Path -LiteralPath $verifyRoot) {
        Remove-Item -LiteralPath $verifyRoot -Recurse -Force
    }
}

Write-Host "Release package: $archivePath"
Write-Host ("Package size: {0:N0} bytes; files: {1}" -f
    (Get-Item -LiteralPath $archivePath).Length, $expectedFiles.Count)
