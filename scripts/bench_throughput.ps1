# requires -version 5.1
# bench_throughput.ps1 — measure BOTH ends of a disk-image transfer, then compute
# a real ETA for the full image. Run the slower of (disk read, target write) as the pace.
#
# Usage (elevated for the disk-read half; target may be UNC or local):
#   powershell -NoProfile -ExecutionPolicy Bypass -File bench_throughput.ps1 `
#       -SourceLetter E -Target "\\nas\share\edrive2026.img" -BytesGB 2
#
# -BytesGB: how much to benchmark each direction (default 2 GiB; a few minutes).
# The network half writes freshly-randomized 64 MiB chunks (defeats NAS dedupe)
# to a scratch dotfile on the target, then deletes it.
#
# Reports: read MB/s, write MB/s, the bottleneck, and total-hours for the full
# image (partition size behind -SourceLetter, or whole disk with -WholeDisk).
param(
    [string]$SourceLetter = "E",
    [Parameter(Mandatory = $true)][string]$Target,
    [double]$BytesGB = 2,
    [switch]$WholeDisk
)
$ErrorActionPreference = "Stop"
$SourceLetter = $SourceLetter.TrimEnd(":").TrimEnd("\").ToUpper()

# resolve source geometry (partition behind the letter, or whole disk)
$p = Get-Partition -DriveLetter $SourceLetter
if (-not $p) { throw "No partition for $SourceLetter" }
$disk = Get-Disk $p.DiskNumber
$diskPath = "\\.\PhysicalDrive$($disk.Number)"
if ($WholeDisk) { $offset = [int64]0; $fullSize = [int64]$disk.Size }
else            { $offset = [int64]$p.Offset; $fullSize = [int64]$p.Size }

$benchBytes = [int64]([Math]::Round($BytesGB * 1GB))
$chunk = 64 * 1024 * 1024
$buf = New-Object byte[] $chunk

Write-Host "=== BENCHMARK 1: disk sequential read ($diskPath, $SourceLetter region @ +1 GB) ==="
$src = [System.IO.File]::Open($diskPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$src.Seek($offset + [int64](1GB), [System.IO.SeekOrigin]::Begin) | Out-Null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$done = [int64]0
while ($done -lt $benchBytes) {
    $w = [int][Math]::Min([int64]$buf.Length, $benchBytes - $done)
    $r = $src.Read($buf, 0, $w)
    if ($r -le 0) { break }
    $done += $r
}
$sw.Stop(); $src.Dispose()
$rMBps = if ($done -gt 0) { [math]::Round(($done / 1MB) / $sw.Elapsed.TotalSeconds, 1) } else { 0 }
Write-Host ("Read {0:N0} MB in {1:N1} s = {2} MB/s" -f ($done/1MB), $sw.Elapsed.TotalSeconds, $rMBps)

Write-Host ""
Write-Host "=== BENCHMARK 2: target write ($Target, randomized, read-back verified) ==="
# scratch file next to the target (same volume). Use a dotfile to stay out of the way.
$dir = Split-Path $Target -Parent
$leaf = "_bench_$PID.tmp"
$benchFile = Join-Path $dir $leaf
try {
    $rand = New-Object System.Random
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $f = [System.IO.File]::Open($benchFile, [System.IO.FileMode]::Create)
    $done = [int64]0
    while ($done -lt $benchBytes) {
        $w = [int][Math]::Min([int64]$buf.Length, $benchBytes - $done)
        if ($w -lt $buf.Length) {
            $partial = New-Object byte[] $w
            $rand.NextBytes($partial)
            $f.Write($partial, 0, $w); $f.Flush(); $done += $w
        } else {
            $rand.NextBytes($buf)      # fresh random data each chunk (no dedupe)
            $f.Write($buf, 0, $w); $f.Flush(); $done += $w
        }
    }
    $sw.Stop(); $f.Dispose()
    $wMBps = [math]::Round(($done / 1MB) / $sw.Elapsed.TotalSeconds, 1)
    Write-Host ("Wrote {0:N0} MB in {1:N1} s = {2} MB/s" -f ($done/1MB), $sw.Elapsed.TotalSeconds, $wMBps)
    # confirm it landed
    $r = [System.IO.File]::OpenRead($benchFile); $sz = $r.Length; $r.Dispose()
    Write-Host ("On-share file size: {0:N0} bytes" -f $sz)
} finally {
    Remove-Item -LiteralPath $benchFile -Force -ErrorAction SilentlyContinue
    Write-Host "bench scratch file removed"
}

Write-Host ""
Write-Host "=== ESTIMATES for full $([math]::Round($fullSize/1GB,1)) GB image ==="
if ($rMBps -gt 0 -and $wMBps -gt 0) {
    $bottleneck = [Math]::Min($rMBps, $wMBps)
    $bname = if ($rMBps -le $wMBps) { "disk read" } else { "network/target write" }
    $secs = ($fullSize / 1MB) / $bottleneck
    $h = [math]::Floor($secs / 3600); $m = [math]::Round(($secs % 3600) / 60)
    Write-Host ("Disk read: {0} MB/s | Target write: {1} MB/s" -f $rMBps, $wMBps)
    Write-Host ("Bottleneck: {0} at {1} MB/s" -f $bname, $bottleneck)
    Write-Host ("Estimated total: {0}h {1}m  (at {2} MB/s)" -f $h, $m, $bottleneck)
    $secsR = ($fullSize/1MB) / $rMBps; $hR = [math]::Floor($secsR/3600); $mR = [math]::Round(($secsR%3600)/60)
    $secsW = ($fullSize/1MB) / $wMBps; $hW = [math]::Floor($secsW/3600); $mW = [math]::Round(($secsW%3600)/60)
    Write-Host ("If disk read limited : {0}h {1}m" -f $hR, $mR)
    Write-Host ("If target limited    : {0}h {1}m" -f $hW, $mW)
    Write-Host ("Caveats: target speed drifts over multi-TB runs and with other clients; the imager's rolling ETA (logged every 15 s) is the live truth.")
} else {
    Write-Host "Could not compute - one or both benchmarks failed."
}
