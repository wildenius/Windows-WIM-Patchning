# BuildWIM v2

```text
  BuildWIM v2
  One click patched Windows 11 Pro WIM/SWM
```

BuildWIM v2 builds patched Windows 11 Pro installation media without the usual manual DISM work.

The normal operator flow is deliberately small:

1. Install BuildWIM.
2. Start one build command.
3. Press **Enter** for Newbie mode.
4. Pick output: USB-ready `SWM`, single `WIM`, or `Both`.
5. Wait for the patched image, report, hashes, and manifest.

If no local Windows media exists, BuildWIM can resolve official Microsoft media automatically. The preferred non-local path is:

```text
Microsoft ESD catalog -> hash verified ESD -> Windows 11 Pro install.wim
```

That path is the default before the ISO fallback because it is catalog-driven, hash-verifiable, works better in SSH/non-interactive environments, and exports directly to the single Pro WIM BuildWIM services.

## One Click Patched WIM

Run this from an elevated PowerShell session on Windows 11:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-BuildWIM.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1
```

At startup, choose:

```text
[Enter] Newbie
[Enter] SWM default, or O2/WIM for a single install.wim, or O3/Both
```

Newbie mode uses the recommended secure defaults:

- latest Windows LCU from Microsoft Update Catalog
- latest .NET Framework cumulative update
- latest Safe OS / WinRE Dynamic Update
- latest Microsoft Defender offline definitions/platform
- component cleanup + ResetBase
- Windows 11 Pro only
- final verification, logs, report, metadata, manifest, and SHA256 hashes

For a fully unattended one-command run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode WIM `
  -EmitMetadataJson
```

For USB media, use the default split SWM output:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
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
| Mode | `Newbie` | Use `Expert` only when selecting exact KBs or cleanup settings. |
| Output | `SWM` | Choose `WIM` for a single file, `Both` when you want both artifact types. |
| Media | `AutoFallback` | Use `Local` when you require pre-staged ISO/WIM/ESD only. |
| Updates | Recommended | Turn off only for lab comparison or troubleshooting. |

Recommended model:

```text
Local ISO/WIM/ESD -> MicrosoftEsd -> MicrosoftIso
```

Local media wins when present. If `C:\BuildWimV2\Input` is empty, BuildWIM tries Microsoft ESD first and ISO only as fallback.

## Plan Before Building

Use plan-only mode to see the media/update plan without downloads, mounts, DISM servicing, or output changes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -PlanOnly `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode WIM
```

Plan-only writes JSON and HTML under `C:\BuildWimV2\Reports`.

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
