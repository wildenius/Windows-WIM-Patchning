# Changelog

Alla notable changes för **Windows WIM Patchning (BuildWIM)** dokumenteras här.

Format: Keep a Changelog (förenklad) + SemVer.

## [1.0.0] - 2026-03-14
### Added
- Bootstrap-installation till `C:\BuildWIM\` via `Install-BuildWIM.ps1`
- Helautomatiserad pipeline via `Build-WIM.ps1`:
  - Input: ISO/WIM/ESD
  - ISO mount/dismount + kopiering av `install.wim/esd`
  - ESD → WIM konvertering
  - Obligatorisk export av **Windows 11 Pro-only** innan patchning
  - Offline package injection med DISM (CAB/MSU med MSU-expansion)
  - Deterministisk package ordering: SSU → LCU → .NET CU → Other
  - Offline cleanup (`/StartComponentCleanup`)
  - Output: `install.wim` + `install*.swm` (FAT32 split)
  - Transcript + loggfil + HTML-rapport + SHA256

### Fixed
- Stabiliserad loggning före `$script:LogFile` init (Write-Log guard)
- Robust index-count check (array wrapping)
- Hantering av tom Updates-mapp (Sort-PackagesByServicingOrder returnerar tom array)
