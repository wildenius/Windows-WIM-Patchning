# BuildWIM v2

```text
  BuildWIM v2
  One click patched Windows 11 Pro WIM/SWM
```

BuildWIM v2 builds patched Windows 11 Pro installation media without the usual manual DISM work.

The normal operator flow is deliberately small:

1. Install BuildWIM.
2. Start one build command.
3. Do nothing and BuildWIM starts **Newbie mode** automatically.
4. Do nothing for USB-ready `SWM`, or press a key to choose single `WIM`, `Both`, or `Expert`.
5. Wait for the patched image, report, hashes, and manifest.

If no local Windows media exists, BuildWIM can resolve official Microsoft media automatically. The preferred non-local path is:

```text
Microsoft ESD catalog -> hash verified ESD -> Windows 11 Pro install.wim
```

That path is the default before the ISO fallback because it is catalog-driven, hash-verifiable, works better in SSH/non-interactive environments, and exports directly to the single Pro WIM BuildWIM services.

## One Click Patched WIM

Run this from an elevated PowerShell session on Windows 11:

```powershell
powershell -NoProfile -File .\Install-BuildWIM.ps1

powershell -NoProfile -File C:\BuildWimV2\Build-WIM.ps1
```

At startup, choose:

```text
No key = Newbie mode
No key = SWM default
Press any key during the short timeout to choose WIM, Both, or Expert
```

Newbie mode uses the recommended secure defaults:

- Windows 11 `25H2`, `x64`, `Retail`, **English International** media
- latest Windows LCU from Microsoft Update Catalog
- latest .NET Framework cumulative update
- latest Safe OS / WinRE Dynamic Update
- latest Microsoft Defender offline definitions/platform
- component cleanup + ResetBase
- Windows 11 Pro only
- final verification, logs, report, metadata, manifest, and SHA256 hashes

For a fully unattended one-command run:

```powershell
powershell -NoProfile -File C:\BuildWimV2\Build-WIM.ps1 `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode WIM `
  -EmitMetadataJson
```

For USB media, use the default split SWM output:

```powershell
powershell -NoProfile -File C:\BuildWimV2\Build-WIM.ps1 `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode SWM `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

## Few Choices

Most runs only need these choices:

| Choice | Default | When to change |
| --- | --- | --- |
| Mode | `Newbie` | Press a key at startup for `Expert` only when selecting version, language, exact KBs, or cleanup settings. |
| Output | `SWM` | Press a key at the output timeout for `WIM`, `Both`, or `Expert`. |
| Media language | `English International` | Use `Expert` or `-MediaLanguage` for another language. |
| Windows version | `25H2` | Use `Expert` or `-UpdateWindowsVersion` for another release. |
| Media | `AutoFallback` | Use `Local` when you require pre-staged ISO/WIM/ESD only. |
| Updates | Recommended | Turn off only for lab comparison or troubleshooting. |

Recommended model:

```text
Local ISO/WIM/ESD -> MicrosoftEsd -> MicrosoftIso
```

Local media wins when present. If `C:\BuildWimV2\Input` is empty, BuildWIM tries Microsoft ESD first and ISO only as fallback.

## Expert Version Selection

Newbie mode does not ask for media details. It defaults to:

```text
Windows 11 25H2 x64 Retail English International
```

Choose `Expert` at startup when you need to change:

- Windows version: `25H2`, `24H2`, `23H2`
- language: `English International`, `English`, `sv-se`, or a catalog language value
- license: `Retail` or `Volume`
- architecture: `x64`, `arm64`, `x86`

For unattended runs, set the same values as parameters:

```powershell
powershell -NoProfile -File C:\BuildWimV2\Build-WIM.ps1 `
  -UiMode Newbie `
  -MediaLanguage "English International" `
  -UpdateWindowsVersion 25H2 `
  -UpdateArchitecture x64 `
  -MediaLicense Retail `
  -AcceptRecommendedUpdates `
  -OutputMode WIM
```

## Plan Before Building

Use plan-only mode to see the media/update plan without downloads, mounts, DISM servicing, or output changes:

```powershell
powershell -NoProfile -File C:\BuildWimV2\Build-WIM.ps1 `
  -PlanOnly `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode WIM
```

Plan-only writes JSON and HTML under `C:\BuildWimV2\Reports`.

## Production Release Mode

Use production mode only after source media and update packages have been reviewed and approved:

```powershell
powershell -NoProfile -File C:\BuildWimV2\New-BuildWimApprovalPolicy.ps1 `
  -ApprovedBy "Security CAB" `
  -ChangeTicket "CHANGE-12345" `
  -Force

powershell -NoProfile -File C:\BuildWimV2\Build-WIM.ps1 `
  -ProductionRelease `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode SWM `
  -EmitMetadataJson
```

`-ProductionRelease` fails closed when source media or update packages do not match policy, when warnings or skipped packages appear, when output would be overwritten, or when the BuildWIM root is a reparse/junction path.

## Folder Layout

```text
C:\BuildWimV2\
|-- Input\        # Optional local ISO/WIM/ESD source
|-- Updates\      # Microsoft Catalog packages and optional local CAB/MSU files
|-- Defender\     # Defender offline update cache
|-- Mount\        # Temporary DISM mount area
|-- Output\       # Final WIM/SWM output
|-- Reports\      # HTML, Markdown, diff, plan reports
|-- Logs\         # Logs and transcripts
|-- Temp\         # Working files
|-- Config\       # buildwim.config.json
`-- docs\         # Operator and technical docs
```

## Output

A successful run creates the selected image artifacts plus evidence:

```text
C:\BuildWimV2\Output\<yyyy-MM-dd>\install.wim
C:\BuildWimV2\Output\<yyyy-MM-dd>\install.swm
C:\BuildWimV2\Output\<yyyy-MM-dd>\install2.swm
C:\BuildWimV2\Output\<yyyy-MM-dd>\build-manifest.json
C:\BuildWimV2\Output\<yyyy-MM-dd>\SHA256SUMS.txt
C:\BuildWimV2\Reports\BuildWIM-<timestamp>.html
C:\BuildWimV2\Reports\BuildWIM-<timestamp>.md
C:\BuildWimV2\Reports\BuildWIM-<timestamp>.diff.md
C:\BuildWimV2\Logs\BuildWIM-<timestamp>.log
```

Production releases use a unique per-run output directory:

```text
C:\BuildWimV2\Output\<yyyy-MM-dd>\<yyyyMMdd-HHmmss>\
```

## Documentation

- `docs/ONE_CLICK_PATCHED_WIM.md` - short operator guide for the "one click patched WIM/SWM" workflow.
- `docs/FEATURE_MATRIX.md` - feature index and validation evidence.
- `docs/PATCH_STATE_MODEL.md` - how BuildWIM proves LCU/.NET/SafeOS/Defender state.
- `docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md` - detailed production runbook.
- `docs/VALIDATED_BUILDS.md` - known-good validation runs.
- `docs/LOGGING.md` - logs, transcripts, and DISM traceability.

## What BuildWIM Does Not Do

- It is not a full deployment platform.
- It does not patch every edition in a multi-index ISO.
- It does not need Windows ADK or WinPE for offline WIM servicing.
- It does not inject Office/Microsoft 365 Apps with DISM.

BuildWIM creates a patched, verified Windows 11 Pro image. Use Intune, MDT, ConfigMgr, Autopilot, or your deployment task sequence for the rest.
