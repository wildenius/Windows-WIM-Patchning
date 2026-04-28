# BuildWIM v2

```text
  ____        _ _     _ __        _____ __  __
 | __ ) _   _(_) | __| |\ \      / /_ _|  \/  |
 |  _ \| | | | | |/ _` | \ \ /\ / / | || |\/| |
 | |_) | |_| | | | (_| |  \ V  V /  | || |  | |
 |____/ \__,_|_|_|\__,_|   \_/\_/  |___|_|  |_|

        Windows image servicing. Boringly repeatable.
```

BuildWIM v2 is an offline servicing pipeline for Windows 11 installation media.

It takes one Windows 11 `ISO`, `install.wim`, or `install.esd`, exports a clean Windows 11 Pro-only working image, optionally injects update packages, performs offline cleanup, and produces both a full `install.wim` and FAT32-friendly split `install.swm` files.

## What it is for

- Building patched Windows 11 Pro installation media.
- Keeping the servicing process repeatable and auditable.
- Avoiding the usual DISM mess: stale mounts, wrong edition indexes, unclear package order, and missing reports.
- Producing USB-ready SWM output without manually babysitting DISM.

## What it is not

- It is not a full deployment platform.
- It does not require Windows ADK or WinPE for offline WIM servicing.
- It does not patch every edition in a multi-index image. It deliberately keeps Windows 11 Pro only.

## Quick start

Run from an elevated PowerShell session on Windows 11:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-BuildWIM.ps1
```

Put one input image here:

```text
C:\BuildWimV2\Input\
```

Optional update packages go here:

```text
C:\BuildWimV2\Updates\
```

Then run a dry run first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 -DryRun
```

Production run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -SplitSizeMB 3800 `
  -EmitMetadataJson `
  -NotifyOnComplete
```

Production run with smart latest LCU handling:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -AutoDownloadLatestLCU `
  -UpdateWindowsVersion 25H2 `
  -UpdateArchitecture x64 `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

With `-AutoDownloadLatestLCU`, BuildWIM checks `C:\BuildWimV2\Updates` first. If the current Catalog LCU is already present, it skips the download. If Microsoft has published a newer LCU, it downloads it using `Get-LatestWindows11LCU.ps1` and moves older BuildWIM-managed LCUs into `Updates\Superseded\` so only the latest one is active for servicing.

Check the latest LCU without building:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -CheckLatestLCU `
  -UpdateWindowsVersion 25H2 `
  -UpdateArchitecture x64
```

Or download only, without running the full build:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Get-LatestWindows11LCU.ps1 `
  -WindowsVersion 25H2 `
  -Architecture x64 `
  -OutputPath C:\BuildWimV2\Updates
```

## Folder layout

```text
C:\BuildWimV2\
|-- Input\        # One ISO/WIM/ESD source image
|-- Updates\      # Optional CAB/MSU packages
|-- Mount\        # Temporary DISM mount area
|-- Output\       # Final WIM + split SWM output
|-- Reports\      # HTML, Markdown, diff reports
|-- Logs\         # Log + transcript files
|-- Temp\         # Working files
|-- Config\       # buildwim.config.json
`-- Tools\        # Optional helper tools
```

## Output

A successful run creates:

- `C:\BuildWimV2\Output\<yyyy-MM-dd>\install.wim`
- `C:\BuildWimV2\Output\<yyyy-MM-dd>\install.swm`, `install2.swm`, ...
- `C:\BuildWimV2\Reports\BuildWIM-<timestamp>.html`
- `C:\BuildWimV2\Reports\BuildWIM-<timestamp>.md`
- `C:\BuildWimV2\Reports\BuildWIM-<timestamp>.diff.md`
- `C:\BuildWimV2\Logs\BuildWIM-<timestamp>.log`
- `C:\BuildWimV2\Logs\BuildWIM-<timestamp>.transcript.txt`
- Optional metadata: `C:\BuildWimV2\Output\BuildWIM-<timestamp>.metadata.json`
- Manifest: `C:\BuildWimV2\Output\<yyyy-MM-dd>\build-manifest.json`
- Checksums: `C:\BuildWimV2\Output\<yyyy-MM-dd>\SHA256SUMS.txt`

## Pipeline

```text
  Input ISO/WIM/ESD
         |
         v
  Discover source image
         |
         v
  Convert ESD if needed
         |
         v
  Export Windows 11 Pro only
         |
         v
  Sort packages: SSU -> LCU -> .NET -> other
         |
         v
  Mount + service offline image
         |
         v
  Component cleanup + optional ResetBase
         |
         v
  Commit, export, split SWM
         |
         v
  Reports, logs, hashes, metadata
```

## Safety defaults

- Administrator check before real builds.
- Minimum free disk check.
- Pro-only edition gate before servicing.
- Stale mount cleanup before starting.
- Optional automatic latest Windows 11 LCU download from Microsoft Update Catalog.
- Deterministic update ordering.
- DISM command traceability in logs and reports.
- HTML + Markdown reports for human review.
- Diff report to compare KBs between builds.

## GUI launchers

The repo includes optional Windows GUI wrappers around the same core pipeline:

- `Start-BuildWIM-GUI.ps1` - simple WinForms launcher.
- `Start-BuildWIM-MissionControl.ps1` - cockpit-style launcher with readiness checks.
- `Start-BuildWIM-ProStudio.ps1` - WPF product-style prototype.
- `Start-BuildWIM-ProStudio-Sexy.ps1` - neon WPF variant.

The source of truth remains `Build-WIM.ps1`. The GUI scripts should launch it, not reimplement servicing logic.

## Documentation

- `docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md` - detailed production runbook with the latest-KB download flow, DISM pipeline, validation checks, and the 2026-04-27 verified run.
- `docs/OVERVIEW_EN.md` - pipeline overview.
- `docs/GUI_LAUNCHERS.md` - GUI launcher notes.
- `docs/VALIDATED_BUILDS.md` - known-good validation runs.
- `docs/LOGGING.md` - logs, transcripts, and DISM traceability.

## ADK / WinPE note

Windows ADK and the WinPE add-on are not required for this offline servicing pipeline. BuildWIM uses the OS-provided `DISM.exe` included with Windows 11.

ADK/WinPE can still be useful for broader deployment workflows, but it is not a dependency for patching the WIM.

## Contributing

See `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md`.
