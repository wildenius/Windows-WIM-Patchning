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

It takes one Windows 11 `ISO`, `install.wim`, or `install.esd`, exports a clean Windows 11 Pro-only working image, optionally downloads and applies the latest Windows LCU, .NET CU, Safe OS Dynamic Update, and Microsoft Defender offline update kit, performs offline cleanup, verifies the final image, and produces both a full `install.wim` and FAT32-friendly split `install.swm` files.

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

BuildWIM starts with one **Startup Selection Center** before any Windows ISO download. If `C:\BuildWimV2\Input` is empty, it first shows the selected LCU/.NET/SafeOS package plan, output format choice, patch sizes, and the expected Windows ISO payload size; only after that selection does it run the official Windows 11 ISO downloader. So a production run can be started directly and still gives the operator one clean decision point before 8+ GB downloads begin:

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

Full production run with current Microsoft updates plus latest Microsoft Defender offline definitions/platform:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -AddDefenderSignatures `
  -AcceptRecommendedUpdates `
  -ForceRebuild `
  -UpdateWindowsVersion 25H2 `
  -UpdateArchitecture x64 `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

BuildWIM opens one premium startup-selection center as the first operator-facing step, before ISO download, source discovery, export, mount, or servicing. The same menu contains both output format and update package choices. It resolves the latest Catalog packages for:

- Windows LCU for the main image.
- .NET Framework cumulative update for the main image.
- Safe OS Dynamic Update for WinRE/SafeOS servicing.

The selector shows output format options plus an **Injectable patches** section with KB, target, release date, package size from Microsoft Update Catalog, local/newer status, recommended selection, and an ISO payload preview. Existing local ISO files show their exact size; missing ISO files show an estimated Windows 11 x64 payload (`~8.0-8.5 GB`) until Microsoft's temporary link is resolved after selection.

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


### Update Selection UX flow

Recommended operator flow:

1. Start BuildWIM.
2. Review the single startup menu: output format, LCU, .NET CU, SafeOS DU, patch sizes, ISO size preview, and total recommended payload.
3. Press **Enter** for recommended updates, `N` for no Microsoft Catalog updates, or choose exact package numbers such as `1,3`.
4. Choose output format in the same menu: **SWM only** (default), **WIM only**, or **Both**.
5. Let BuildWIM download only the selected updates and only then download/mount the Windows ISO if needed.
6. Review the final HTML/Markdown report and `SHA256SUMS.txt`.

Further UX ideas that fit the roadmap:

- Add a `-PlanOnly` mode that writes the update/ISO payload plan as JSON/HTML without downloading anything.
- Add a “download budget” warning, for example prompt again if total payload exceeds 10 GB.
- Show a compact before/after build card: source UBR -> target UBR, selected KBs, expected output type.
- Cache successful `HEAD` size checks in `catalog-cache.json` so repeat runs are instant even when Microsoft blocks HEAD.
- Add a `--profile` concept (`fast`, `secure`, `lab`) for different default selections.

### Output format selection

BuildWIM asks what output should remain after servicing inside the single startup menu:

- **SWM only** — default. Produces `install.swm`, `install2.swm`, etc. for FAT32/USB media and removes the intermediate `install.wim` before hashes/manifests are written.
- **WIM only** — produces a single `install.wim` and skips SWM splitting.
- **Both** — keeps `install.wim` and also produces split `install*.swm` files.

For automation, skip the prompt with:

```powershell
# Default-style USB output
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 -OutputMode SWM

# Single WIM only
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 -OutputMode WIM

# Keep both artifact families
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 -OutputMode Both
```

The delta check is still OS-LCU aware: it compares the source image build revision with the latest LCU build revision. If the source image is already current and no selected .NET/SafeOS package requires a rebuild, the run stops cleanly and writes a report instead of rebuilding. Use `-ForceRebuild` to rebuild anyway. If a selected .NET CU or SafeOS package is present, BuildWIM continues even when the OS LCU is already current.

If the current Catalog package is already present, BuildWIM skips the download. If Microsoft has published a newer package, it downloads it using `Get-LatestWindows11LCU.ps1` and moves older BuildWIM-managed packages into `Updates\Superseded\` so only the latest selected packages are active for servicing. The old `-AutoDownloadLatestLCU` switch is still accepted for backward compatibility, but it is no longer required.

Optional Microsoft Defender offline update injection:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -AddDefenderSignatures `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

This downloads Microsoft's latest Defender OS installation image update kit (`defender-update-kit-x64.zip`) and applies it to the mounted WIM before cleanup/commit. Important detail: the kit contains `defender-dism-x64.cab`, but current Defender kits are not normal `DISM /Add-Package` packages. BuildWIM expands the CAB and stages the Defender definitions, platform files, and `package-defender.xml` into the mounted image using the same supported layout as Microsoft's Defender offline servicing script. You can also enable it permanently in `Config\buildwim.config.json` with `Defender.InjectLatestOfflineUpdate = true`. Use `-SkipDefenderSignatures` to force-disable it for a run.

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
|-- Updates\      # Optional and BuildWIM-managed CAB/MSU packages
|-- Defender\     # Defender offline update kit/cache when enabled
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
  Download Defender offline kit when enabled
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
- Optional latest Microsoft Defender offline update kit injection into the mounted image.
- Deterministic update ordering.
- DISM command traceability in logs and reports.
- HTML + Markdown reports for human review.
- Diff report to compare KBs between builds.
- OOB detection for selected LCU/.NET packages by comparing Catalog release date against that month's Patch Tuesday.





## Documentation

- `docs/FEATURE_MATRIX.md` - operator-facing feature index, golden path, Defender design notes, and latest clean validation evidence.
- `docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md` - detailed production runbook with the latest-KB download flow, DISM pipeline, validation checks, and verified production runs.
- `docs/OVERVIEW_EN.md` - pipeline overview.
- `docs/VALIDATED_BUILDS.md` - known-good validation runs.
- `docs/LOGGING.md` - logs, transcripts, and DISM traceability.

## ADK / WinPE note

Windows ADK and the WinPE add-on are not required for this offline servicing pipeline. BuildWIM uses the OS-provided `DISM.exe` included with Windows 11.

ADK/WinPE can still be useful for broader deployment workflows, but it is not a dependency for patching the WIM.

## Contributing

See `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md`.
