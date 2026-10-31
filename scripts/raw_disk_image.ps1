# requires -version 5.1
# =============================================================================
#  raw_disk_image.ps1
#  Resumable sector-by-sector raw image of a Windows volume (or whole disk)
#  to a local path or UNC share, with retry, progress logging, SHA-256 and a
#  manifest. Designed for multi-TB images over SMB.
#
#  Parameters:
#    -SourceLetter <X>   Drive letter of the source volume (default E).
#                        The image covers the partition behind that letter,
#                        from its exact on-disk offset.
#    -Target <path>      Output image path (UNC or local), REQUIRED.
#                        e.g. \\nas\share\edrive2026.img  or D:\images\x.img
#    -WholeDisk          Image the ENTIRE physical disk of -SourceLetter
#                        (offset 0, full disk size) instead of just the
#                        partition. Use only when the user explicitly wants
#                        every byte incl. other partitions / GPT headers.
#    -Verify             After the copy completes (or immediately, if the
#                        image is already complete) re-read the whole target
#                        file over the network and compute an independent
#                        SHA-256. No admin needed for verify-only runs.
#    -LogDir <dir>       Where the progress log goes (default: user home).
#
#  Run (elevated PowerShell for copy; non-elevated OK for -Verify only):
#    powershell -NoProfile -ExecutionPolicy Bypass -File raw_disk_image.ps1 `
#        -SourceLetter E -Target "\\nas\share\edrive2026.img"
#
#  Resume: re-run the identical command after any interruption. The script
#  seeks both source and target to the target's current size and continues.
#  Note: the incremental SHA-256 is only valid for a fully-fresh run; after a
#  resumed run, use -Verify for a trustworthy hash.
#
#  Requires PowerShell 5.1+. No third-party modules. .NET File APIs only
#  (no Get-Content -AsByteStream, no New-SmbMapping).
# =============================================================================
param(
    [string]$SourceLetter = "E",
    [Parameter(Mandatory = $true)][string]$Target,
    [switch]$WholeDisk,
    [switch]$Verify,
    [string]$LogDir = $HOME
)

$ErrorActionPreference = "Stop"
$SourceLetter = $SourceLetter.TrimEnd(":").TrimEnd("\").ToUpper()

$chunkBytes  = 64 * 1024 * 1024          # 64 MiB buffer
$progressSec = 15
$maxRetries  = 30                        # per read/write op
$logFile     = Join-Path $LogDir "raw_disk_image.log"

function Log($msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    Write-Host $line
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
}
function Fail($msg) { Log "FATAL: $msg"; exit 1 }

# --- validate target path ----------------------------------------------------
if (-not [System.IO.Path]::IsPathRooted($Target)) { Fail "Target must be an absolute path (UNC or local): $Target" }
$shaFile  = $Target + ".sha256"
$manifest = $Target + ".manifest.txt"

# Independent full read-back hash of the target (~ copy-duration; patient).
function Invoke-FullVerify {
    Log "=== VERIFY PASS: re-reading target and hashing (takes about as long as the copy) ==="
    $vsw  = [System.Diagnostics.Stopwatch]::StartNew()
    $vsha = [System.Security.Cryptography.SHA256]::Create()
    $vEmpty = New-Object byte[] 0   # PS 5.1 cannot bind [byte[]]::Empty as a method arg
    $f    = [System.IO.File]::OpenRead($Target)
    $vbuf = New-Object byte[] $chunkBytes
    $vdone = [int64]0; $vlast = 0.0
    try {
        while (($r = $f.Read($vbuf, 0, $chunkBytes)) -gt 0) {
            $vsha.TransformBlock($vbuf, 0, $r, $null, 0) | Out-Null
            $vdone += $r
            $t = $vsw.Elapsed.TotalSeconds
            if ($t - $vlast -ge $progressSec) {
                Log ("  verify {0,7:N2} GB  {1,6:N0} MB/s" -f @(($vdone/1GB), (($vdone/1MB)/$t)))
                $vlast = $t
            }
        }
        $vsha.TransformFinalBlock($vEmpty, 0, 0) | Out-Null
    } finally { $f.Dispose() }
    $vhex = [System.BitConverter]::ToString($vsha.Hash).Replace("-", "").ToLower()
    $null = [System.IO.File]::WriteAllText($shaFile, "$vhex  $(Split-Path $Target -Leaf)`n")
    Log "Full-file SHA-256: $vhex (sidecar updated)"
    if (Test-Path -LiteralPath $manifest) {
        $m  = [System.IO.File]::ReadAllText($manifest)
        $m2 = [regex]::Replace($m, '(?m)^sha256\s+:.*$', ("sha256  : $vhex (full read-back verify)"))
        [System.IO.File]::WriteAllText($manifest, $m2)
        Log "Manifest sha256 line updated."
        # compare against the write-time hash if one was recorded at copy time
        $mm = [regex]::Match($m2, '(?m)^sha256\s+:\s+([0-9a-f]{64})\s*\(write-time incremental\)')
        if ($mm.Success) {
            if ($vhex -eq $mm.Groups[1].Value) { Log "VERIFY OK: read-back hash matches write-time hash. Image is trustworthy." }
            else { Log "!! VERIFY MISMATCH: read-back=$vhex write-time=$($mm.Groups[1].Value) - transfer corrupted. Delete target and re-run fresh." }
        }
    }
    Log "=== VERIFY DONE ==="
}

# --- preflight ----------------------------------------------------------------
Log "=== raw disk image job starting ==="
if ($WholeDisk) { $scopeTxt = 'WHOLE DISK' } else { $scopeTxt = 'partition' }
Log "Source : drive letter $SourceLetter ($scopeTxt)"
Log "Target : $Target"

# elevation (only needed when we will actually open the physical disk)
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# verify-only fast path: target exists and user only wants -Verify -> no admin
if ($Verify -and (Test-Path -LiteralPath $Target)) {
    $cur = (Get-Item -LiteralPath $Target -Force).Length
    if ($cur -gt 0) {
        Log "-Verify requested and target exists ($cur bytes) - verify-only run (no admin required)."
        Invoke-FullVerify
        exit 0
    }
}
if (-not $isAdmin) {
    Fail "Not running elevated. Open an ELEVATED terminal (Run as administrator) and re-run."
}

# --- resolve geometry ----------------------------------------------------------
try {
    $p = Get-Partition -DriveLetter $SourceLetter
    if (-not $p) { Fail "No partition found for drive letter $SourceLetter" }
    $disk = Get-Disk $p.DiskNumber
    Log ("Disk {0} : {1}  serial={2}  size={3}B  status={4}" -f $disk.Number, $disk.FriendlyName, $disk.SerialNumber, $disk.Size, $disk.OperationalStatus)
    if ($disk.OperationalStatus -ne "Online") { Fail "Disk $($disk.Number) not Online" }
    $diskNumber = $disk.Number
    $diskPath   = "\\.\PhysicalDrive$($disk.Number)"
    if ($WholeDisk) {
        $partOffset = [int64]0
        $partSize   = [int64]$disk.Size
        $regionDesc = "whole physical disk $diskNumber (offset 0, full size)"
    } else {
        $partOffset = [int64]$p.Offset
        $partSize   = [int64]$p.Size
        $regionDesc = "partition $($p.PartitionNumber) of disk $diskNumber (offset $partOffset bytes)"
    }
    Log ("Region : {0}, size {1} bytes (~{2} GB)" -f $regionDesc, $partSize, [math]::Round($partSize/1GB,2))
} catch { Fail "Could not resolve source geometry: $($_.Exception.Message)" }

# --- verify target has enough space (best effort) -------------------------------
try {
    if ($Target -like "\\*") {
        # fsutil prints: "   14,000,000,000  free" on the free-space line
        $out = & fsutil volume diskfree $Target
        $freeLine = @($out) | Where-Object { $_ -match '^\s*\d' } | Select-Object -First 1
        if ($freeLine) {
            $free = [int64]((($freeLine -replace '\D','') | ForEach-Object { $_ })[0] -replace '^0+','')
            if ($free -ge $partSize) {
                Log ("Preflight OK: target share has ~{0} GB free" -f [math]::Round($free/1GB,1))
            } else {
                Fail "Target share free space (~$([math]::Round($free/1GB,1)) GB) < image size (~$([math]::Round($partSize/1GB,1)) GB)"
            }
        } else {
            Log "WARN: could not parse fsutil free-space output; continuing"
        }
    }
} catch { Log "WARN: could not check target free space: $($_.Exception.Message)" }

# --- open source ----------------------------------------------------------------
$src = $null
try {
    $src = [System.IO.File]::Open($diskPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    Log "Opened $diskPath for reading"
} catch {
    Fail "Cannot open $diskPath (run elevated?): $($_.Exception.Message)"
}

# --- open/create target (resume-aware) ------------------------------------------
$resumed = $false
$done = [int64]0
try {
    if (Test-Path -LiteralPath $Target) {
        $done = (Get-Item -LiteralPath $Target -Force).Length
        if ($done -ge $partSize) {
            if ($done -gt $partSize) { Fail "Target larger than expected ($done > $partSize). Aborting - inspect manually." }
            Log "Target already complete ($done bytes). Nothing to copy."
            if ($Verify) { Invoke-FullVerify }
            else         { Log "Tip: re-run with -Verify for an independent read-back hash." }
            $src.Dispose(); exit 0
        }
        if ($done -gt 0) {
            $resumed = $true
            Log "Resuming: existing file has $done bytes (~$([math]::Round($done/1GB,2)) GB). Continuing from there."
        }
        $dst = [System.IO.File]::Open($Target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    } else {
        Log "No existing target file - creating fresh image."
        $dst = [System.IO.File]::Open($Target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    }
} catch {
    $src.Dispose()
    Fail "Cannot open target for writing: $($_.Exception.Message)"
}

# NOTE: on resume the incremental hash only covers THIS run's bytes; a
# trustworthy checksum requires -Verify (full read-back) afterwards.
$sha = [System.Security.Cryptography.SHA256]::Create()
$empty = New-Object byte[] 0   # PS 5.1 cannot bind [byte[]]::Empty as a method arg
$shaValid = -not $resumed

# --- stream ----------------------------------------------------------------------
$src.Seek($partOffset + $done, [System.IO.SeekOrigin]::Begin) | Out-Null
$dst.Seek($done, [System.IO.SeekOrigin]::Begin) | Out-Null

$buf = New-Object byte[] $chunkBytes
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastReport = [System.Diagnostics.Stopwatch]::StartNew()
$startDone = $done; $lastBytes = $done; $lastTime = 0.0

Log "Streaming started. (Ctrl+C / killing the process is safe - re-run to resume.)"

try {
    while ($done -lt $partSize) {
        # int64-safe chunk sizing (avoids Int32 overflow past 2 GiB remaining)
        $want = [int][Math]::Min([int64]$chunkBytes, $partSize - $done)
        # --- read with retry ---
        $got = 0; $readDone = $false; $attempt = 0
        while (-not $readDone) {
            try {
                $got = $src.Read($buf, 0, $want)
                if ($got -le 0) { Fail "Unexpected EOF from source at offset $([math]::Round(($partOffset + $done)/1GB,2)) GB" }
                $readDone = $true
            } catch {
                $attempt++
                if ($attempt -gt $maxRetries) { Fail "Source read failed after $maxRetries retries at offset $([math]::Round(($partOffset + $done)/1GB,2)) GB: $($_.Exception.Message)" }
                Log "  read error (attempt $attempt/$maxRetries): $($_.Exception.Message) - retrying in $attempt s"
                Start-Sleep -Seconds $attempt
            }
        }
        # --- write with retry ---
        $wDone = $false; $attempt = 0
        while (-not $wDone) {
            try {
                $dst.Write($buf, 0, $got)
                $dst.Flush()
                $wDone = $true
            } catch {
                $attempt++
                if ($attempt -gt $maxRetries) { Fail "Target write failed after $maxRetries retries at offset $([math]::Round(($partOffset + $done)/1GB,2)) GB: $($_.Exception.Message)" }
                Log "  write error (attempt $attempt/$maxRetries): $($_.Exception.Message) - retrying in $attempt s"
                Start-Sleep -Seconds $attempt
            }
        }
        if ($shaValid) { $sha.TransformBlock($buf, 0, $got, $null, 0) | Out-Null }
        $done += $got

        # --- progress (to LOCAL log file, never the network share) ---
        if ($lastReport.Elapsed.TotalSeconds -ge $progressSec) {
            $now = $sw.Elapsed.TotalSeconds
            $dBytes = $done - $lastBytes
            $dTime  = $now - $lastTime
            if ($dTime -gt 0) {
                $mbps   = [math]::Round(($dBytes / 1MB) / $dTime, 1)
                $etaSec = if (($dBytes / $dTime) -gt 0) { [math]::Round(($partSize - $done) / ($dBytes / $dTime)) } else { 0 }
                $etaH = [math]::Floor($etaSec / 3600); $etaM = [math]::Floor(($etaSec % 3600) / 60)
                Log ("{0,7:N2} GB / {1:N2} GB  ({2,5:0.00} %)   {3,7} MB/s   ETA {4}h {5}m" -f @(($done/1GB), ($partSize/1GB), ((100.0*$done)/$partSize), $mbps, $etaH, $etaM))
            }
            $lastBytes = $done; $lastTime = $now
            $lastReport = [System.Diagnostics.Stopwatch]::StartNew()
        }
    }
    if ($shaValid) { $sha.TransformFinalBlock($empty, 0, 0) | Out-Null }
} finally {
    try { $dst.Flush() } catch { }
    $dst.Dispose()
    $src.Dispose()
}

$elapsedMin = [math]::Round($sw.Elapsed.TotalMinutes, 1)
$avgMBps = [math]::Round(($done - $startDone) / 1MB / [Math]::Max(1, $sw.Elapsed.TotalSeconds), 1)
Log "=== COPY COMPLETE: $done bytes (~$([math]::Round($done/1GB,2)) GB) in $elapsedMin min (avg $avgMBps MB/s this run) ==="

# --- finalize --------------------------------------------------------------------
$finalLen = (Get-Item -LiteralPath $Target -Force).Length
if ($finalLen -ne $partSize) {
    Log "!! SIZE MISMATCH: file=$finalLen expected=$partSize - do NOT trust this image; delete it and re-run fresh, then verify"
} else {
    Log "Size verified: $finalLen bytes = expected"
}

if ($shaValid) {
    $hashHex = [System.BitConverter]::ToString($sha.Hash).Replace("-", "").ToLower()
    $null = [System.IO.File]::WriteAllText($shaFile, "$hashHex  $(Split-Path $Target -Leaf)`n")
    Log "SHA-256 (incremental, this run only): $hashHex"
    Log "Wrote $shaFile"
} else {
    Log "Resumed run: incremental SHA-256 NOT valid (only covered new bytes). Re-run with -Verify for a trustworthy hash."
}

# manifest
$manifestLines = @(
    "$(Split-Path $Target -Leaf) - raw sector image manifest",
    "created : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))",
    "source  : disk $diskNumber $($disk.FriendlyName) serial=$($disk.SerialNumber) ($diskPath)",
    "region  : $regionDesc",
    "sectors : 512-byte sectors, count=$([math]::Floor($partSize/512))",
    "file    : $Target ($finalLen bytes)"
)
if ($shaValid) { $manifestLines += "sha256  : $hashHex (write-time incremental)" }
else           { $manifestLines += "sha256  : (resumed run - re-run with -Verify)" }
$null = [System.IO.File]::WriteAllText($manifest, ($manifestLines -join "`n") + "`n")
Log "Wrote $manifest"

if ($Verify) {
    Invoke-FullVerify
} else {
    Log "Tip: re-run with -Verify for an independent read-back hash when convenient."
}

Log "=== JOB DONE ==="
exit 0
