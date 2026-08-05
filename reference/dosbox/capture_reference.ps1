# capture_reference.ps1 - run the original VOODKA.EXE under DOSBox and take
# timed screenshots (CTRL-F5) for the whole run, plus a ZMBV video recording
# (CTRL-ALT-F5) as a continuous reference. Screenshots land in
# reference/captures/raw (configured via dosbox_voodka.conf [dosbox] captures);
# this script logs the wall-clock time of each shot to raw/shots.csv so scene
# transitions can be bracketed and mapped to module positions.
#
# Usage:
#   .\capture_reference.ps1 [-IntervalSec 2.0] [-MaxMinutes 12] [-NoVideo]
#
# DOSBox 0.74-3 must be installed (default path below). The demo runs in
# real time (retrace/ModPos synced), so a capture takes as long as the demo.

param(
    [double]$IntervalSec = 2.0,
    [int]$MaxMinutes = 12,
    [switch]$NoVideo
)

$ErrorActionPreference = "Stop"
$dosbox = "C:\Program Files (x86)\DOSBox-0.74-3\DOSBox.exe"
if (-not (Test-Path $dosbox)) { throw "DOSBox not found at $dosbox" }

$here   = $PSScriptRoot
$conf   = Join-Path $here "dosbox_voodka.conf"
$rawDir = "D:\Project\voodka2\reference\captures\raw"

if (Test-Path $rawDir) { Remove-Item "$rawDir\*" -Force -Recurse }
else { New-Item -ItemType Directory -Force $rawDir | Out-Null }

Write-Host "Launching DOSBox with $conf ..."
$proc = Start-Process -FilePath $dosbox -ArgumentList "-conf `"$conf`"" -PassThru
$shell = New-Object -ComObject WScript.Shell
$start = Get-Date

# Let DOSBox boot and the demo reach mode 13h before recording.
Start-Sleep -Seconds 8

if (-not $NoVideo) {
    if ($shell.AppActivate($proc.Id)) {
        $shell.SendKeys("^%{F5}")   # CTRL-ALT-F5: start ZMBV video recording
        Write-Host ("{0,8:N1}s  video recording started" -f ((Get-Date)-$start).TotalSeconds)
    } else {
        Write-Warning "could not focus DOSBox window; video not started"
    }
}

$shots = @()
while (-not $proc.HasExited -and ((Get-Date)-$start).TotalMinutes -lt $MaxMinutes) {
    Start-Sleep -Milliseconds ([int]($IntervalSec * 1000))
    $t = ((Get-Date)-$start).TotalSeconds
    if ($shell.AppActivate($proc.Id)) {
        $shell.SendKeys("^{F5}")    # CTRL-F5: screenshot
        $shots += [pscustomobject]@{ t_seconds = [math]::Round($t, 2) }
        Write-Host ("{0,8:N1}s  shot #{1}" -f $t, $shots.Count)
    } else {
        Write-Warning ("{0,8:N1}s  window focus failed; shot skipped" -f $t)
    }
}

if (-not $proc.HasExited) {
    Write-Host "MaxMinutes reached; stopping DOSBox."
    $proc.Kill()
}
$proc.WaitForExit()
$shots | Export-Csv (Join-Path $rawDir "shots.csv") -NoTypeInformation
Write-Host ("DOSBox exited after {0:N1}s; {1} shots -> {2}" -f ((Get-Date)-$start).TotalSeconds, $shots.Count, $rawDir)
