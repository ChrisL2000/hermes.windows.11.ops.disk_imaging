# requires -version 5.1
# =============================================================================
#  make_launchers.ps1
#  Generate the three user-facing .cmd launchers (start / status / verify) for
#  a raw-disk-image job, plus print the exact command names. Run from the user's
#  home directory. The .ps1 imager must already be copied next to the launchers
#  (copy scripts/raw_disk_image.ps1 -> <home>\image_<job>.ps1 first, or set
#  -ImagerPath).
#
#  Usage (from C:\Users\<user>):
#    powershell -NoProfile -ExecutionPolicy Bypass -File make_launchers.ps1 `
#        -Job edrive -SourceLetter E `
#        -Target "\\nas\share\edrive2026.img" `
#        -ExpectedBytes 8001545043968
#
#  Produces in the current directory (user home):
#    <job>_start.cmd   start OR resume (auto-elevates)
#    <job>_status.cmd  live progress, no admin
#    <job>_verify.cmd  full read-back hash, no admin
#
#  The UNC in -Target must be passed with its normal two-lead-backslash form;
#  the generator writes exactly two literal backslashes into the .cmd files
#  (cmd.exe does not process backslash escapes), which is what PowerShell needs.
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$Job,
    [string]$SourceLetter = "E",
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][int64]$ExpectedBytes,
    [string]$ImagerPath = "",      # default: <cwd>\image_<job>.ps1
    [string]$LogName = "raw_disk_image.log",
    [switch]$WholeDisk
)
$ErrorActionPreference = "Stop"
if (-not $ImagerPath) { $ImagerPath = Join-Path (Get-Location) "image_$Job.ps1" }
# store imager as an absolute path; the .cmd will reference it via a temp var
$imagerAbs = (Resolve-Path -ErrorAction SilentlyContinue $ImagerPath)
$imagerRef = $ImagerPath   # if not resolvable, use as-is
if ($imagerAbs) { $imagerRef = $imagerAbs.ProviderPath }

$outDir = (Get-Location).Path
$startCmd  = Join-Path $outDir "$Job`_start.cmd"
$statusCmd = Join-Path $outDir "$Job`_status.cmd"
$verifyCmd = Join-Path $outDir "$Job`_verify.cmd"

# --- START -------------------------------------------------------------------
# Single-quoted here-string: everything literal, no expansion. Tokens replaced below.
$startBody = @'
@echo off
rem ===========================================================================
rem  @@JOB@@_start.cmd -- start or resume the @@JOB@@ raw disk image
rem  Run from your home dir:   @@JOB@@_start.cmd
rem  Launches DETACHED (hidden console): closing any window CANNOT kill it.
rem  Auto-elevates to admin if needed (physical disk access).
rem  Safe to re-run: it continues from wherever the .img left off.
rem ===========================================================================
setlocal
cd /d "%USERPROFILE%"

rem --- already complete? (no admin needed to check the target file) ---
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$t='@@TARGET@@'; if (Test-Path -LiteralPath $t) { $len=(Get-Item -LiteralPath $t -Force).Length; $exp=@@EXPECTED@@; if ($len -ge $exp) { Write-Host '@@JOB@@ image already complete ({0} bytes). Nothing to do. Run @@JOB@@_verify.cmd for a read-back hash.' -f $len; exit 2 } }"
if %errorlevel% equ 2 exit /b 0

rem --- already running? (exclude this check's own process) ---
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$m = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { ($_.Name -eq 'powershell.exe') -and ($_.CommandLine -like '*@@IMAGER_LEAF@@*') -and ($_.CommandLine -notlike '*Win32_Process*') };" ^
  "if ($m) { Write-Host ('@@JOB@@ imager already running (PID ' + ($m | Select-Object -First 1).ProcessId + '). Leave it alone; watch with @@JOB@@_status.cmd.'); exit 3 }"
if %errorlevel% equ 3 exit /b 0

rem --- need admin to open the physical disk; self-elevate if missing ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Elevation required to read the physical disk. A UAC prompt will appear; accept it.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%COMSPEC%' -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

rem --- launch DETACHED (hidden console): survives any window close ---
echo Starting @@JOB@@ imager (detached, hidden console).
echo It keeps running even if you close this window or any other.
echo Watch progress with:  @@JOB@@_status.cmd
echo Log file:  %USERPROFILE%\@@LOG@@
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"@@IMAGER@@\"' @@EXTRA@@ -WindowStyle Hidden"
if %errorlevel% neq 0 (
    echo FAILED to launch the imager. Run manually: powershell -NoProfile -ExecutionPolicy Bypass -File "@@IMAGER@@" @@EXTRA@@
    exit /b 1
)
echo Launched. Verify within a minute with:  @@JOB@@_status.cmd
exit /b 0

endlocal
'@
$startBody = $startBody.Replace("@@TARGET@@", $Target).Replace("@@EXPECTED@@", $ExpectedBytes).Replace("@@IMAGER@@", $imagerRef).Replace("@@JOB@@", $Job)
$startBody = $startBody.Replace("@@IMAGER_LEAF@@", (Split-Path $imagerRef -Leaf))
$extra = if ($WholeDisk) { "-WholeDisk " } else { "" }
$startBody = $startBody.Replace("@@EXTRA@@", $extra)
$startBody = $startBody.Replace("@@LOG@@", $LogName)
[System.IO.File]::WriteAllText($startCmd, $startBody.Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# --- STATUS ------------------------------------------------------------------
$statusBody = @'
@echo off
rem ===========================================================================
rem  @@JOB@@_status.cmd -- HONEST status: process liveness + file growth
rem  (no admin needed)
rem  Run from your home dir:   @@JOB@@_status.cmd
rem ===========================================================================
setlocal
cd /d "%USERPROFILE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$t='@@TARGET@@'; $exp=@@EXPECTED@@;" ^
  "$m = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { ($_.Name -eq 'powershell.exe') -and ($_.CommandLine -like '*@@IMAGER_LEAF@@*') -and ($_.CommandLine -notlike '*Win32_Process*') -and ($_.CommandLine -notlike '*Start-Process*') };" ^
  "if ($m) { $pid1 = ($m | Select-Object -First 1).ProcessId } else { $pid1 = $null };" ^
  "Write-Host ('Target : ' + $t);" ^
  "Write-Host ('Process: ' + $(if ($pid1) { 'RUNNING (PID ' + $pid1 + ')' } else { 'NOT RUNNING' }));" ^
  "if (Test-Path -LiteralPath $t) { $a=(Get-Item -LiteralPath $t -Force).Length;" ^
  "  Start-Sleep 5;" ^
  "  $b=(Get-Item -LiteralPath $t -Force).Length;" ^
  "  Write-Host ('Size   : {0:N0} / {1:N0} bytes  ({2:0.2} %%)  ~{3:N0} GB / {4:N0} GB' -f $b,$exp,(100.0*$b/$exp),($b/1GB),($exp/1GB));" ^
  "  if ($b -ge $exp) { Write-Host 'STATUS: COMPLETE (run @@JOB@@_verify.cmd for read-back hash)'; }" ^
  "  elseif ($b -gt $a) { Write-Host ('STATUS: RUNNING and writing (+' + ($b-$a).ToString('N0') + ' bytes in 5 s)'); }" ^
  "  elseif ($pid1) { Write-Host 'STATUS: PROCESS ALIVE BUT FILE NOT GROWING in 5 s - possibly stalled/retrying; check the log below.'; }" ^
  "  else { Write-Host 'STATUS: STOPPED (process gone, image incomplete). Resume with: @@JOB@@_start.cmd'; } }" ^
  "else { Write-Host 'STATUS: NOT STARTED (no target file yet). Start with: @@JOB@@_start.cmd'; }" ^
  "if (Test-Path '@@LOG@@') { Write-Host ''; Write-Host '--- last 12 log lines (live, Ctrl+C to stop watching) ---'; Get-Content '@@LOG@@' -Tail 12 -Wait }"
endlocal
'@
$statusBody = $statusBody.Replace("@@TARGET@@", $Target).Replace("@@EXPECTED@@", $ExpectedBytes).Replace("@@LOG@@", $LogName).Replace("@@JOB@@", $Job)
$statusBody = $statusBody.Replace("@@IMAGER_LEAF@@", (Split-Path $imagerRef -Leaf))
[System.IO.File]::WriteAllText($statusCmd, $statusBody.Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# --- VERIFY ------------------------------------------------------------------
$verifyBody = @'
@echo off
rem ===========================================================================
rem  @@JOB@@_verify.cmd -- full read-back SHA-256 of the finished image
rem  Run from your home dir:   @@JOB@@_verify.cmd
rem  No admin needed. Reads the whole image over the network and computes an
rem  independent hash (takes about as long as the copy). Updates the .sha256
rem  sidecar and the manifest sha256 line.
rem ===========================================================================
setlocal
cd /d "%USERPROFILE%"
powershell -NoProfile -ExecutionPolicy Bypass -File "@@IMAGER@@" -Verify @@EXTRA@@
endlocal
'@
$verifyBody = $verifyBody.Replace("@@IMAGER@@", $imagerRef).Replace("@@EXTRA@@", $extra).Replace("@@JOB@@", $Job)
[System.IO.File]::WriteAllText($verifyCmd, $verifyBody.Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "Created launchers in: $outDir"
Write-Host "  $startCmd"
Write-Host "  $statusCmd"
Write-Host "  $verifyCmd"
Write-Host ""
Write-Host "Imager referenced by the launchers: $imagerRef"
if (-not (Test-Path -LiteralPath $imagerRef)) {
    Write-Host "WARNING: imager not found at that path. Copy it there first:"
    Write-Host "  copy <this-skill>\scripts\raw_disk_image.ps1  $imagerRef"
}
Write-Host ""
Write-Host "Commands (run from your home dir):"
Write-Host "  Start / resume :  ${Job}_start.cmd"
Write-Host "  Watch progress :  ${Job}_status.cmd"
Write-Host "  Verify image   :  ${Job}_verify.cmd"
