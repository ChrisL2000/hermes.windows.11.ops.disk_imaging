# requires -version 5.1
# probe_drive.ps1 — class-level storage probe for a Windows drive letter or UNC.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File probe_drive.ps1 -Target "E:"
#        powershell -NoProfile -ExecutionPolicy Bypass -File probe_drive.ps1 -Target "\\server\share"
# Read-only, safe to run un-elevated. PS 5.1 compatible (no -AsByteStream, no New-SmbMapping -Force).
param(
    [Parameter(Mandatory = $true)][string]$Target
)
$ErrorActionPreference = "SilentlyContinue"

$IsUnc = $Target -like "\\*"
$Letter = if (-not $IsUnc) { $Target.TrimEnd(":").TrimEnd("\") } else { $null }

Write-Host "=== PROBE TARGET: $Target ==="

if (-not $IsUnc) {
    Write-Host "=== DISKS ==="
    Get-Disk | Select-Object Number, FriendlyName, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
        BusType, IsBootDisk, IsSystemDisk, PartitionStyle, OperationalStatus | Format-Table -AutoSize

    Write-Host "=== PARTITION FOR ${Letter}: ==="
    $p = Get-Partition -DriveLetter $Letter
    if ($p) {
        $p | Select-Object DiskNumber, PartitionNumber,
            @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, Type, Offset | Format-List
        Write-Host ("Partition offset = {0} bytes; disk size = {1} bytes" -f $p.Offset, (Get-Disk $p.DiskNumber).Size)
        Write-Host ("Note: if partition size ~= disk size and offset < 16MiB, letter ~= whole disk; imaging 'the drive' = imaging disk {0}." -f $p.DiskNumber)
    } else {
        Write-Host "No partition for ${Letter}: - letter may not exist right now (drive letters are transient; re-probe before concluding)."
    }

    Write-Host "=== VOLUME ${Letter}: ==="
    $v = Get-Volume -DriveLetter $Letter
    if ($v) {
        $v | Select-Object DriveLetter, FileSystemLabel, FileSystem,
            @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
            @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}},
            HealthStatus | Format-List
    }
}

Write-Host "=== LOGICAL DISK ENTRIES (all letters, incl. network) ==="
Get-CimInstance Win32_LogicalDisk | Select-Object DeviceID, DriveType, VolumeName, ProviderName,
    @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
    @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,1)}} | Format-Table -AutoSize
Write-Host "=== MAPPED NETWORK DRIVES (net use) ==="
net use 2>&1

Write-Host "=== TARGET REACHABILITY ==="
$test = if ($IsUnc) { "$Target\" } else { "${Target}:" }
Write-Host "Test-Path '$test' = $(Test-Path $test)"
$items = Get-ChildItem $test -Force
Write-Host "Children listed: $(@($items).Count)"
$items | Select-Object -First 10 Name, @{n='SizeMB';e={[math]::Round($_.Length/1MB,2)}} | Format-Table -AutoSize

Write-Host "=== FREE SPACE ==="
if ($IsUnc) {
    # works over UNC in PS 5.1, no drive letter needed
    fsutil volume diskfree $Target 2>&1
} elseif ($v) {
    Write-Host ("Free {0:N1} GB of {1:N1} GB" -f ($v.SizeRemaining/1GB), ($v.Size/1GB))
}

if (-not $IsUnc) {
    Write-Host "=== WRITABILITY (read-back verified) ==="
    $stamp = (Get-Date).ToString("HHmmssfff")
    $tmp = "${Letter}:\._writetest_$PID_$stamp.tmp"
    try {
        $payload = "writetest-$stamp"
        [System.IO.File]::WriteAllText($tmp, $payload)
        Start-Sleep -Milliseconds 500
        $readBack = [System.IO.File]::ReadAllText($tmp)
        $item = Get-Item -LiteralPath $tmp -Force   # throws if not really there
        if ($readBack -eq $payload) {
            Write-Host "WRITABLE - round-trip OK (wrote+read back $payload, on-disk size=$($item.Length))"
        } else {
            Write-Host "WRITABLE? FAIL - content mismatch on read-back"
        }
    } catch {
        Write-Host "WRITE FAILED: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "=== PROBE DONE ==="
