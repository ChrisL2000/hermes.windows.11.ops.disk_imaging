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
rem  Auto-elevates to admin if needed (physical disk access).
rem  Safe to re-run: it continues from wherever the .img left off.
rem ===========================================================================
setlocal
cd /d "%USERPROFILE%"

rem --- already complete? (no admin needed to check the target file) ---
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$t='@@TARGET@@'; if (Test-Path -LiteralPath $t) { $len=(Get-Item -LiteralPath $t -Force).Length; $exp=@@EXPECTED@@; if ($len -ge $exp) { Write-Host '@@JOB@@ image already complete ({0} bytes). Nothing to do. Run @@JOB@@_verify.cmd for a read-back hash.' -f $len; exit 2 } }"
if %errorlevel% equ 2 exit /b 0

rem --- need admin to open the physical disk; self-elevate if missing ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Elevation required to read the physical disk. A UAC prompt will appear.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%COMSPEC%' -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

rem --- run the imager (it handles resume internally) ---
powershell -NoProfile -ExecutionPolicy Bypass -File "@@IMAGER@@" @@EXTRA@@

endlocal
'@
$startBody = $startBody.Replace("@@TARGET@@", $Target).Replace("@@EXPECTED@@", $ExpectedBytes).Replace("@@IMAGER@@", $imagerRef).Replace("@@JOB@@", $Job)
$extra = if ($WholeDisk) { "-WholeDisk" } else { "" }
$startBody = $startBody.Replace("@@EXTRA@@", $extra)
[System.IO.File]::WriteAllText($startCmd, $startBody.Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# --- STATUS ------------------------------------------------------------------
$statusBody = @'
@echo off
rem ===========================================================================
rem  @@JOB@@_status.cmd -- live progress (no admin needed)
rem  Run from your home dir:   @@JOB@@_status.cmd
rem  Shows current size on target + tail of the progress log, live.
rem ===========================================================================
setlocal
cd /d "%USERPROFILE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$t='@@TARGET@@'; $exp=@@EXPECTED@@;" ^
  "Write-Host ('Target: ' + $t);" ^
  "if (Test-Path -LiteralPath $t) { $len=(Get-Item -LiteralPath $t -Force).Length;" ^
  "  Write-Host ('Written : {0:N0} / {1:N0} bytes  ({2:0.2} %)  ~{3:N0} GB / {4:N0} GB' -f $len,$exp,(100.0*$len/$exp),($len/1GB),($exp/1GB));" ^
  "  if ($len -ge $exp) { Write-Host 'STATUS: COMPLETE (run @@JOB@@_verify.cmd for read-back hash)' } else { Write-Host 'STATUS: in progress' } }" ^
  "else { Write-Host 'STATUS: not started (no target file yet)' };" ^
  "if (Test-Path '@@LOG@@') { Write-Host ''; Write-Host '--- last 12 log lines (live, Ctrl+C to stop) ---'; Get-Content '@@LOG@@' -Tail 12 -Wait }"
endlocal
'@
$statusBody = $statusBody.Replace("@@TARGET@@", $Target).Replace("@@EXPECTED@@", $ExpectedBytes).Replace("@@LOG@@", $LogName).Replace("@@JOB@@", $Job)
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
