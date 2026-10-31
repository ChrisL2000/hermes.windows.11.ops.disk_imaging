# hermes.windows.11.ops.disk_imaging

A reusable **Hermes Agent skill** for making **sector-by-sector raw disk images** on
Windows 11 — probe the volume, benchmark both transfer ends, then run a **resumable**
image of a drive (or whole disk) onto a NAS/SMB share or local disk, with SHA-256
verification and a three-command user launcher.

Distilled from a real job on 2026-10-31: imaging a 7.45 TB `E:` (TOSHIBA HDWR180,
partition 2 of Disk 1) to `\\198.19.7.20\edrive\edrive10312026.img`, measured at
235 MB/s disk-read and 103 MB/s SMB-write → ~20.5 h, resumable across interruptions.

## What you get
| File | Purpose |
|------|---------|
| `scripts/raw_disk_image.ps1` | The imager. Parameterized (`-SourceLetter`, `-Target`, `-WholeDisk`, `-Verify`). Resumable, retry-with-backoff, 15 s progress log, incremental SHA-256 + `.sha256`/`.manifest.txt` sidecars. PowerShell 5.1, .NET File APIs, no dependencies. |
| `scripts/probe_drive.ps1` | Read-only storage probe: disks, partitions, volumes, all logical disks, `net use`, reachability, free space, **writability by read-back**. |
| `scripts/bench_throughput.ps1` | Benchmarks disk read AND target write (~2 GiB each), names the bottleneck, computes a real ETA. Randomized chunks defeat NAS dedupe. |
| `scripts/make_launchers.ps1` | Generates the three user `.cmd` launchers (start/resume, status, verify) for any job and prints the command names. Handles the cmd→PowerShell quoting correctly. |
| `references/edrive-image-2026-10-31.md` | The real case study: geometry, target, measured rates, pitfalls actually hit. |
| `SKILL.md` | The procedure (in order) + PowerShell-from-bash golden rules + pitfalls. |

## Quick start (Windows 11, run from the user's home dir)
```powershell
# 1. Probe source + target (read-only)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe_drive.ps1 -Target "E:"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe_drive.ps1 -Target "\\nas\share"

# 2. Benchmark both ends -> real ETA (elevated for the read half)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bench_throughput.ps1 `
    -SourceLetter E -Target "\\nas\share\edrive2026.img" -BytesGB 2

# 3. Build the user job (creates 3 .cmd launchers)
copy scripts\raw_disk_image.ps1  C:\Users\<user>\image_edrive.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make_launchers.ps1 `
    -Job edrive -SourceLetter E -Target "\\nas\share\edrive2026.img" -ExpectedBytes 8001545043968
```
The user then runs, from their home dir:
- `edrive_start.cmd` — start or **resume** (auto-elevates; safe to re-run after any interruption)
- `edrive_status.cmd` — live progress, no admin
- `edrive_verify.cmd` — full read-back SHA-256 when the copy finishes, no admin

## Requirements
- Windows 10/11, PowerShell 5.1+ (default `powershell.exe`), no third-party modules.
- Administrator for the copy (opens `\\.\PhysicalDriveN`); no admin for status/verify.

## Notes
- Raw size includes free space: a multi-TB image of a mostly-full drive is still the
  full region size. Confirm partition-only vs whole-disk scope with the user
  (`-WholeDisk`).
- After a resumed run the incremental hash is partial — run `-Verify` for the
  trustworthy whole-file hash.

## License
MIT. See `SKILL.md`.
