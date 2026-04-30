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

The installer copies only the supported v2 payload: core BuildWIM script, ISO downloader, latest-update downloader, config, README, and docs. The old GUI launcher scripts are no longer part of the v2 install payload.

Put one input image here:

```text
C:\BuildWimV2\Input\
```

If `C:\BuildWimV2\Input` is empty, BuildWIM automatically runs the official Windows 11 ISO downloader before source discovery. So a production run can be started directly and left to finish:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

You can also run the ISO downloader manually:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Get-Windows11Iso.ps1 `
  -OutputDirectory C:\BuildWimV2\Input
```

Default language is `English International`. To only resolve the temporary Microsoft URL without downloading the ISO:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Get-Windows11Iso.ps1 -LinkOnly
```

To disable automatic ISO download in BuildWIM, add `-SkipAutoDownloadWindows11Iso`.

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

Production run with smart update handling enabled by default:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -UpdateWindowsVersion 25H2 `
  -UpdateArchitecture x64 `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

BuildWIM now opens an update-selection center before the expensive export/mount/servicing work. It resolves the latest Catalog packages for:

- Windows LCU for the main image.
- .NET Framework cumulative update for the main image.
- Safe OS Dynamic Update for WinRE/SafeOS servicing.

For unattended runs, use one of these switches:

```powershell
# Use the recommended selection without prompting
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -AcceptRecommendedUpdates `
  -SplitSizeMB 3800 `
  -EmitMetadataJson

# Skip the prompt and use recommended defaults, useful for automation
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -SkipUpdateSelectionPrompt `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

The delta check is still OS-LCU aware: it compares the source image build revision with the latest LCU build revision. If the source image is already current and no selected .NET/SafeOS package requires a rebuild, the run stops cleanly and writes a report instead of rebuilding. Use `-ForceRebuild` to rebuild anyway. If a selected .NET CU or SafeOS package is present, BuildWIM continues even when the OS LCU is already current.

If the current Catalog package is already present, BuildWIM skips the download. If Microsoft has published a newer package, it downloads it using `Get-LatestWindows11LCU.ps1` and moves older BuildWIM-managed packages into `Updates\Superseded\` so only the latest selected packages are active for servicing. The old `-AutoDownloadLatestLCU` switch is still accepted for backward compatibility, but it is no longer required.

Check the latest LCU without building:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -CheckLatestLCU `
  -UpdateWindowsVersion 25H2 `
  -UpdateArchitecture x64
```

Or download only, without running the full build:

```powershell
# Latest Windows LCU
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Get-LatestWindows11LCU.ps1 `
  -WindowsVersion 25H2 `
  -Architecture x64 `
  -PackageType LCU `
  -OutputPath C:\BuildWimV2\Updates

# Latest .NET Framework CU
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Get-LatestWindows11LCU.ps1 `
  -WindowsVersion 25H2 `
  -Architecture x64 `
  -PackageType DotNet `
  -OutputPath C:\BuildWimV2\Updates

# Latest Safe OS Dynamic Update
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Get-LatestWindows11LCU.ps1 `
  -WindowsVersion 25H2 `
  -Architecture x64 `
  -PackageType SafeOS `
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
  Check disk + latest LCU delta
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
- Optional automatic latest Windows 11 LCU, .NET CU, and SafeOS DU download from Microsoft Update Catalog.
- Deterministic update ordering.
- DISM command traceability in logs and reports.
- HTML + Markdown reports for human review.
- Diff report to compare KBs between builds.
- OOB detection for selected LCU/.NET packages by comparing Catalog release date against that month's Patch Tuesday.





## Documentation

- `docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md` - detailed production runbook with the latest-KB download flow, DISM pipeline, validation checks, and the 2026-04-27 verified run.
- `docs/OVERVIEW_EN.md` - pipeline overview.
- `docs/VALIDATED_BUILDS.md` - known-good validation runs.
- `docs/LOGGING.md` - logs, transcripts, and DISM traceability.

## ADK / WinPE note

Windows ADK and the WinPE add-on are not required for this offline servicing pipeline. BuildWIM uses the OS-provided `DISM.exe` included with Windows 11.

ADK/WinPE can still be useful for broader deployment workflows, but it is not a dependency for patching the WIM.

## Contributing

See `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md`.
