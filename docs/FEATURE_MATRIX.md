# BuildWIM v2 Feature Matrix

BuildWIM v2 is a production-grade Windows 11 Pro image servicing pipeline. This document is the operator-facing feature index: what the tool does, why it exists, how to run it, and where to find evidence after a build.

## Golden path

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

This command performs the full production path:

1. Verifies admin rights, disk space, DISM availability, and folder layout.
2. Opens the Update Selection Center immediately: resolves current Microsoft Update Catalog packages, shows KBs, release dates, statuses, patch sizes, and Windows ISO payload size/estimate.
3. Downloads the official Windows 11 ISO if `Input` is empty, after the update decision.
4. Selects Windows 11 Pro from the source media.
5. Exports a clean single-index Pro working WIM.
6. Downloads selected LCU, .NET CU, and Safe OS Dynamic Update packages.
7. Mounts the WIM into an isolated per-run mount directory.
8. Injects main-image updates.
9. Services WinRE/SafeOS with the Safe OS Dynamic Update.
10. Downloads and injects the latest Microsoft Defender offline update kit.
11. Runs offline component cleanup.
12. Commits the WIM.
13. Produces full `install.wim` and FAT32-safe `install*.swm` files.
14. Verifies the final image and writes reports, metadata, manifest, and hashes.

## Feature overview

| Area | Feature | Status | Evidence |
| --- | --- | --- | --- |
| Source handling | ISO/WIM/ESD input support | Production | `Build-WIM.ps1`, report input section |
| Source handling | Automatic official Windows 11 ISO download when `Input` is empty | Production | `Get-Windows11Iso.ps1`, log step `Windows 11 ISO auto-download completed` |
| Edition control | Windows 11 Pro-only export | Production | `Export-ProEditionOnly`, final WIM index 1 |
| Update intelligence | Latest Windows LCU lookup/download | Production | `Get-LatestWindows11LCU.ps1 -PackageType LCU` |
| Update intelligence | Latest .NET Framework CU lookup/download | Production | `Get-LatestWindows11LCU.ps1 -PackageType DotNet` |
| Update intelligence | Latest Safe OS Dynamic Update lookup/download | Production | `Get-LatestWindows11LCU.ps1 -PackageType SafeOS` |
| Update governance | First-screen Update Selection Center before ISO download | Production | Interactive prompt or unattended recommended defaults |
| Update governance | Patch-size and ISO payload preview | Production | selector columns `Size`, ISO payload header |
| UX | Premium console selector layout | Production | BuildWIM Update Selection Center card |
| Automation | `-AcceptRecommendedUpdates` | Production | Non-interactive runs select recommended packages |
| Automation | `-SkipUpdateSelectionPrompt` | Production | Uses recommended defaults without prompt |
| Automation | `-ForceRebuild` | Production | Forces rebuild even when LCU delta would skip |
| Defender | Latest Microsoft Defender offline update kit download | Production | `Defender\defender-update-kit-x64.zip` |
| Defender | Offline Defender definitions/platform injection | Production | log line `Microsoft Defender offline update injected successfully` |
| WinRE | SafeOS DU routed to mounted `winre.wim` instead of main image | Production | step `Inject Safe OS DU into WinRE` |
| DISM safety | Pre-flight stale mount cleanup | Production | log `Rensar gamla mount-punkter` / `Cleanup-Wim` |
| DISM safety | Isolated per-run mount directories | Production | `Mount\Mount-<timestamp>` |
| DISM safety | Mounted-image readiness checks | Production | `Ensure-MountedImageReady` |
| DISM safety | Remount retry support | Production | readiness/remount handling in logs when needed |
| Output | Full `install.wim` | Production | `Output\<date>\install.wim` |
| Output | Split `install*.swm` for FAT32 USB media | Production | `Output\<date>\install.swm`, `install2.swm` |
| Evidence | HTML report | Production | `Reports\BuildWIM-<timestamp>.html` |
| Evidence | Markdown report | Production | `Reports\BuildWIM-<timestamp>.md` |
| Evidence | Diff report | Production | `Reports\BuildWIM-<timestamp>.diff.md` |
| Evidence | Structured metadata JSON | Production | `Output\BuildWIM-<timestamp>.metadata.json` |
| Evidence | Build manifest | Production | `Output\<date>\build-manifest.json` |
| Evidence | SHA256SUMS | Production | `Output\<date>\SHA256SUMS.txt` |
| Verification | Final WIM mount verification | Production | metadata `verification.status = OK` |
| Verification | LCU verification via RollupFix + build revision + UBR | Production | expected update checks |
| Verification | .NET CU verification via DotNetRollup package identity | Production | expected update checks |
| UX | ETA/progress logging | Production | console + log timestamps |
| Compatibility | Legacy `-AutoDownloadLatestLCU` accepted | Compatibility | backward-compatible switch |

## Defender offline update design

Microsoft's Defender OS installation image update kit is not a normal Windows update package, even though the payload is named `defender-dism-*.cab`. Direct `DISM /Add-Package` fails against current kits. BuildWIM therefore uses the supported servicing model:

1. Download latest kit from Microsoft's redirect URL.
2. Extract `defender-dism-x64.cab`.
3. Expand the CAB into scratch space.
4. Copy `Definition Updates\Updates` into the mounted image under:
   `ProgramData\Microsoft\Windows Defender\Definition Updates\Updates`
5. Copy `Platform` into:
   `ProgramData\Microsoft\Windows Defender\Platform`
6. Copy `package-defender.xml` into:
   `Windows\Temp`
7. Commit the mounted image as part of the normal BuildWIM flow.

This keeps the WIM current at build time without relying on first-boot network access.

## What BuildWIM intentionally does not do

| Request | Recommendation |
| --- | --- |
| Inject Microsoft 365 Apps/Office with DISM | Do not use DISM. Office Click-to-Run is not an offline DISM package. Stage Office Deployment Tool and install at first boot, Intune, MDT, ConfigMgr, or deployment task sequence. |
| Patch every edition in a multi-index ISO | Not a v2 goal. BuildWIM exports and services Windows 11 Pro only for repeatability. |
| Replace a full deployment platform | BuildWIM produces patched media. Use Intune/MDT/ConfigMgr/Autopilot/task sequence for full deployment orchestration. |

## Evidence from latest full clean validation

Latest full clean validation on `.226` / `DESKTOP-8P73FNP`:

- Start: `2026-05-01T21:11:28+02:00`
- End: `2026-05-01T23:09:29+02:00`
- Verdict: `SUCCESS`
- Duration: `01:58:00`
- Source ISO: `Win11_25H2_EnglishInternational_x64_v2.iso`
- Source SHA256: `66B7B4B71763ED6F9B2CE29326ED9284544DA6F5283D00329921540C01AAAEEA`
- Output WIM SHA256: `538A20C0554EB3593C274EECE54E35B89CC42297F31DD3913C89231EDA14AC70`
- Defender log evidence: `Microsoft Defender offline update injected successfully.`
- Final verification: `OK`

See `docs/VALIDATED_BUILDS.md` for the full artifact list.
