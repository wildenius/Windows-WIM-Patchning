# Changelog

All notable changes to **Windows WIM Patching (BuildWIM)** will be documented in this file.

This project follows a simplified Keep a Changelog format and Semantic Versioning.

## [1.0.0] - 2026-03-14
### Added
- Bootstrap installer to `C:\BuildWIM\` via `Install-BuildWIM.ps1`
- Fully automated pipeline via `Build-WIM.ps1`:
  - Input: ISO/WIM/ESD
  - ISO mount/dismount + copy of `install.wim/esd`
  - ESD → WIM conversion
  - Mandatory export of **Windows 11 Pro-only** before any servicing
  - Offline package injection using DISM (CAB/MSU with MSU expansion)
  - Deterministic package ordering: SSU → LCU → .NET CU → Other
  - Offline cleanup (`/StartComponentCleanup`)
  - Output: `install.wim` + `install*.swm` (FAT32 split)
  - Transcript + log file + HTML report + SHA256

### Fixed
- Guard logging before `$script:LogFile` is initialized
- Robust index-count checks by enforcing array semantics
- Handling of an empty Updates folder (no-ops without crashing)
