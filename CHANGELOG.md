# Changelog

All notable changes to **Windows WIM Patching (BuildWIM)** will be documented in this file.

This project follows a simplified Keep a Changelog format and Semantic Versioning.

## [Unreleased]
### Added
- Added `Get-LatestWindows11LCU.ps1` to discover and download the latest non-preview Windows 11 LCU/MSU from Microsoft Update Catalog.
- Added `Get-Windows11Iso.ps1` to resolve and download the official Windows 11 x64 multi-edition ISO from Microsoft's software download service.
- BuildWIM now automatically runs `Get-Windows11Iso.ps1` before source discovery when the `Input` folder has no ISO/WIM/ESD; `-SkipAutoDownloadWindows11Iso` disables this.
- Added latest LCU integration before package discovery. BuildWIM now checks/downloads the latest Windows 11 LCU by default; `-AutoDownloadLatestLCU` remains accepted for backward compatibility.
- Installer now copies the ISO and LCU downloaders into the BuildWIM root.
- Reworked README for BuildWIM v2 with a clean ASCII banner, quick start, pipeline diagram, and clearer safety notes.
- Replaced the startup banner in `Build-WIM.ps1` with a cleaner ASCII console header and bumped script metadata to `2.0.0`.
- Refreshed `docs/OVERVIEW_EN.md` and `docs/LOGGING.md` with v2-focused flow diagrams and troubleshooting guidance.
- Validated build notes in `docs/VALIDATED_BUILDS.md`, including the 2026-04-27 KB5083769 run.
- Detailed production runbook in `docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md`, including ASCII diagrams, latest-KB download internals, DISM servicing steps, validation checks, and troubleshooting.
- Build manifest output at `Output\<yyyy-MM-dd>\build-manifest.json` with source, package, output, environment, and final verification evidence.
- `SHA256SUMS.txt` output beside final WIM/SWM artifacts.
- `Get-LatestWindows11LCU.ps1` now writes `Updates\catalog-cache.json` and records downloaded MSU SHA256.
- `Build-WIM.ps1 -CheckLatestLCU` for checking the latest Catalog LCU without running a full build.
- USB/SWM compatibility validation for FAT32-safe split output.
- Isolated per-run WIM mount directories to reduce stale DISM mount state conflicts.
- Mounted-image readiness checks before servicing and final verification.
- Automatic DISM remount retry when a mounted image is not ready for servicing.
- Detailed WIM index inspection so source, working, and final image metadata includes version and architecture.
- Update-selection center for LCU, .NET Framework CU, and Safe OS Dynamic Update package streams.
- `-ForceRebuild`, `-SkipUpdateSelectionPrompt`, and `-AcceptRecommendedUpdates` switches for controlled automation.
- SafeOS/WinRE package classification and exclusion from main-image package injection.

### Changed
- Package servicing sort now handles all current classifications explicitly: SSU, LCU, .NET CU, Security, Hotfix, Setup, Other.
- Documentation now reflects dated output folders and direct MSU servicing behavior.
- Latest-update discovery now uses explicit package type cache keys: LCU, DotNet, and SafeOS.

### Fixed
- Reduced risk of `Needs Remount` / stale WIMMount failures during package injection and final WIM verification.
- `-WhatIf` now maps to the script's dry-run path instead of allowing side effects.
- ISO dry-run now continues through the whole pipeline using a synthetic image path instead of failing on `$null`.
- Dry-run export verification no longer attempts to inspect non-created WIM files.
- Missing packages are no longer incorrectly treated as safe/idempotent DISM skip conditions.
- Final LCU validation now accepts `Package_for_RollupFix` identities that match the Microsoft Update Catalog build revision from the metadata sidecar, avoiding false warnings when the public KB number is not present in offline package identities.
- Final image verification now also records image build, offline registry values such as `DisplayVersion` and `UBR`, and structured per-update verification checks.
- Latest LCU handling now checks the existing `Updates` folder first, skips download when the current LCU is already present, downloads only when Catalog has a newer LCU, and archives superseded BuildWIM-managed LCUs out of the active Updates folder. This behavior is now default for production builds.
- Builds with an empty `Updates` folder no longer crash when package validation receives an empty package list.
- Latest .NET CU lookup/download now happens before the OS-LCU delta-skip decision, so a current source image still rebuilds when a selected .NET CU is available.
- Package sorting no longer emits nested arrays that caused report/log classifications such as `[LCU DotNetCU]` or `[System.Object[]]`.
- Installer payload no longer references removed GUI launcher scripts, fixing install failures after the CLI-focused v2 cleanup.

## [1.0.2] - 2026-03-20
### Added
- ETA v2 groundwork: startup estimate, live ETA log updates per major step, progress ETA suffix, and persisted build history in `Reports\build-history.json`

## [1.0.1] - 2026-03-20
### Added
- Expanded HTML reporting with build verdict, before/after image details, step timings, output file sizes + SHA256 hashes, and skipped-package reasons
- Richer metadata JSON including outputs, warnings/errors, and per-step execution details

### Fixed
- Captured mount path before stale-mount cleanup to avoid referencing `$mountDir` before initialization

## [1.0.0] - 2026-03-14
### Added
- Bootstrap installer to `C:\BuildWimV2\` via `Install-BuildWIM.ps1`
- Fully automated pipeline via `Build-WIM.ps1`:
  - Input: ISO/WIM/ESD
  - ISO mount/dismount + copy of `install.wim/esd`
  - ESD -> WIM conversion
  - Mandatory export of **Windows 11 Pro-only** before any servicing
  - Offline package injection using DISM (CAB/MSU with MSU expansion)
  - Deterministic package ordering: SSU -> LCU -> .NET CU -> Other
  - Offline cleanup (`/StartComponentCleanup`)
  - Output: `install.wim` + `install*.swm` (FAT32 split)
  - Transcript + log file + HTML report + SHA256

### Fixed
- Guard logging before `$script:LogFile` is initialized
- Robust index-count checks by enforcing array semantics
- Handling of an empty Updates folder (no-ops without crashing)
