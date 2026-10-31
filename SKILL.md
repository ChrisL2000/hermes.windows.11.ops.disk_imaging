---
name: hermes.windows.11.ops.disk_imaging
description: Sector-by-sector raw disk imaging on Windows 11 — probe a volume, benchmark both transfer ends, then run a resumable raw image of a drive to a NAS share or local disk with SHA-256 verification and a 3-command user launcher (start/resume, status, verify). Use when a user asks to back up, clone, migrate, or "image" a Windows disk/volume, or to build a resumable long-running copy job on Windows.
version: 1.0.0
author: ChrisL2000 / Hermes Agent
license: MIT
platforms: [windows]
metadata:
  hermes:
    tags: [windows, windows-11, powershell, disk-imaging, nas, smb, backup, resumable]
---

# Windows 11 Disk Imaging Ops

A complete, proven workflow for making **sector-by-sector raw images** of a Windows
volume (or whole disk) onto a network share or local disk — including the preflight
probes, a real throughput benchmark, a resumable imager, and a three-command user
launcher. Built from a real 7.45 TB E: → NAS job (2026-10-31) on a Windows 11 host
operated by Hermes Agent (git-bash terminal, PowerShell 5.1).

## When to use
- "Back up / clone / image / migrate this drive" on a Windows machine
- Sector-by-sector or raw copy of a volume, partition, or whole physical disk
- Long-running (hours) copy to a NAS/SMB share that must survive interruptions
- Producing a user-runnable job where the user just types three short command names

## Repo layout
```
SKILL.md                              this file: procedure + pitfalls
scripts/raw_disk_image.ps1            THE imager (parameterized, resumable, PS 5.1)
scripts/probe_drive.ps1               read-only storage probe (disks/partitions/volumes/UNC)
scripts/bench_throughput.ps1          benchmark both ends -> real ETA
scripts/make_launchers.ps1            generates the 3 .cmd launchers for any job
references/edrive-image-2026-10-31.md real case study: geometry, target, measured rates
README.md                             repo overview + quick start
```

## The procedure (in order — do not skip steps)

### 1. Scope with the user FIRST
"Image drive E:" is ambiguous. Confirm:
- **Partition only** (from the volume's on-disk offset) vs **whole physical disk**
  (offset 0, includes other partitions, GPT headers, free space). Sizes differ; the
  imager does both via `-WholeDisk`.
- Output name and location (UNC or local). Raw size = the region size, INCLUDING
  free space (an 88%-full 7.45 TB drive still produces a ~7.45 TB image).

### 2. Probe the source and target (read-only)
```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe_drive.ps1 -Target "E:"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe_drive.ps1 -Target "\\nas\share"
```
Capture: disk number/FriendlyName/serial, partition offset+size, sector size (assume
512 unless told otherwise), filesystem, free space on the target, reachability.
Rules learned the hard way (see Pitfalls):
- **Trust `net use` over a user-typed IP** (one job's target was 198.19.7.20, not the
  user's typed 192.19.7.20 — probing the typed address "wasted" a session).
- A mapped drive letter can be **stale** (`net use` shows it, `dir L:\` fails).
  Stream to the **UNC path**, never the letter, for the real job.
- **Writability must be proven by read-back** (write a file, read it back, compare),
  never by a return code or a print outside a catch block.

### 3. Benchmark BOTH ends before promising an ETA
```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bench_throughput.ps1 `
  -SourceLetter E -Target "\\nas\share\edrive2026.img" -BytesGB 2
```
- Disk read and target write, ~2 GiB each (~1 minute). The SLOWER sets the pace.
- Network half uses freshly-randomized 64 MB chunks (NAS dedupe otherwise inflates
  the benchmark).
- Report: both rates, the named bottleneck, `full_bytes / min(read,write)` in hours,
  plus the caveat that multi-TB rates drift and the imager's 15 s rolling ETA is live truth.
- Reference numbers from the case study: HDWR180 SATA read 235 MB/s; SMB NAS write
  103 MB/s (~gigabit ceiling) → 7,452 GB ≈ 20.5 h.

### 4. Region signature preflight (before any multi-TB job)
Read the region's first sector and verify it makes sense:
- NTFS boot sector: bytes 0-2 = `EB 52 90`, bytes 52-59 = "NTFS    "
- GPT disks: protective MBR at offset 0, GPT header at 1 MiB
- All zeros at the region start = region math is wrong. Stop.
(the imager re-checks partition geometry on every run and aborts on mismatch)

### 5. Build the user job
From the user's home dir (`C:\Users\<user>`):
```
copy scripts\raw_disk_image.ps1  C:\Users\<user>\image_<job>.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make_launchers.ps1 `
  -Job <job> -SourceLetter <X> -Target "<unc>" -ExpectedBytes <exact byte count>
```
`make_launchers.ps1` writes three files (CRLF, UTF-8 no BOM) and prints the command
names:
- `<job>_start.cmd` — start **or** resume. No-admin "already complete" precheck →
  `net session` elevation probe → UAC self-re-run if needed → runs the imager.
  Re-running after ANY interruption continues from the existing file size.
- `<job>_status.cmd` — no admin: target size/%, `STATUS:` line, live tail of the local log.
- `<job>_verify.cmd` — no admin: full read-back SHA-256 of the finished image
  (~copy duration). The imager's `-Verify` works even when the image is already
  complete (verify-only fast path, no elevation needed).

Deliverables next to the image: `<name>.img`, `<name>.img.sha256`,
`<name>.img.manifest.txt` (disk serial, region, sector count, timestamps, hash).

### 6. Test the trio WITHOUT launching the job
- Parse-check the imager (`[System.Management.Automation.Language.Parser]::ParseFile`)
- Run `<job>_status.cmd` (harmless; expect "not started")
- For `<job>_start.cmd`, test its inline precheck line via a temp .cmd
  (`cmd //c _test_inline.cmd`) — **running start.cmd for real in an already-elevated
  Hermes context kicks off the job.**
- Leave the actual launch to the user (their console, `Get-Content <log> -Wait`),
  or launch it in a monitored background process if they ask.

## PowerShell-from-git-bash golden rules (Hermes on Windows)
1. **Never pass PowerShell inline through the bash `terminal` tool.** MSYS expands
   `$_`, `$(...)`, `$env:FOO` first. Fingerprint: Windows paths inside PowerShell
   parse errors. Write a `.ps1` with write_file, run
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <path>`.
2. **PowerShell 5.1 is the default**, not 7: no `Get-Content -AsByteStream`, no
   `New-SmbMapping -Force`. For byte-level work use .NET
   (`[System.IO.File]::Open/Read/Write`, `[BitConverter]`) — version-stable.
3. **Large decimal literals can arrive corrupted in transit** (e.g. `1073741824`
   becoming `107****1824`). Prefer `[int64](1GB)`-style expressions for byte math;
   re-read the written file if a parse error lands on a numeric literal.
4. **A `$var:` inside a double-quoted string is a parse error in PS 5.1** —
   `"PARTITION FOR $Letter:"` is read as a variable named `Letter:`. Delimit:
   `"PARTITION FOR ${Letter}:"`. (Classic PS gotcha; the parser error is
   "Variable reference is not valid. ':' was not followed by a valid variable name character.")
5. **int64 overflow in loops**: `[Math]::Min([int]$a, [int]$bigInt64)` throws when the
   remainder > 2 GiB. Compute as Int64 first, then cast:
   `[int][Math]::Min([int64]$buf.Length, $big - $done)`.
6. **Embedding PowerShell in .cmd launchers** (three quoting layers: bash/cmd/PowerShell):
   - UNC paths in a .cmd need **exactly two literal backslashes** (`'\\nas\share\x'`).
     cmd.exe does not process backslash escapes.
   - PowerShell single-quoted strings do NOT expand `$vars` — use double quotes or
     concatenation in any message containing a variable.
   - cmd expands `%var%`, not `$var` — `$t` reaches PowerShell intact. If you test the
     line from bash, bash expands `$t` first and you get errors that never reproduce in
     the .cmd. Test via a temp .cmd + `cmd //c`, never by pasting into bash.

## Pitfalls
- **False-positive writability** — print success only after a verified read-back
  (a swallowed exception + print outside the guard made one probe claim "WRITABLE"
  for a drive that didn't exist).
- **Single-probe trust** — drive letters are transient; re-confirm existence checks
  (positive AND negative) with a second probe before reporting state.
- **Scope assumption** — partition size ≠ disk size; print both, confirm with user.
- **Resume + incremental hash** — an incremental SHA-256 is only valid for a fresh
  run; after resume, the trustworthy hash comes from `-Verify` (full read-back).
  Mark the sidecar/manifest accordingly, never present a partial hash as the hash.
- **Log to the LOCAL disk**, never per-tick to the network share (write amplification
  on the same connection you're saturating).
- **FileShare::ReadWrite** is required when opening `\\.\PhysicalDriveN` (the OS
  holds the disk open); Read-only sharing will fail.
- **`[byte[]]::Empty` fails as a method argument in PS 5.1** — calling
  `TransformFinalBlock([byte[]]::Empty, 0, 0)` throws "Cannot find an overload"
  (the static property is mis-bound as a PSMethod; the 0-arg form doesn't exist on
  `SHA256Managed`). Hold it in a variable: `$empty = New-Object byte[] 0` then
  `TransformFinalBlock($empty, 0, 0)`. This bug sits at the very END of the job
  (after the copy is done), so it hides in review and only surfaces at finalize.
- **NAS free-space parsing**: `fsutil volume diskfree \\nas\share` prints formatted
  numbers; strip non-digits before comparing (the imager does this best-effort).

## Verification
- Imager parse check + the 2026-10-31 job's full preflight (geometry, NTFS boot
  signature, GPT MBR, writability read-back, 1 MB round-trip, share space) all passed.
- Measured rates in `references/edrive-image-2026-10-31.md` are real 2 GiB benchmarks,
  not guesses.
- The launcher trio was generated and parse-tested; the start command was validated
  without launching the job.
