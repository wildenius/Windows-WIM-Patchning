# One Click Patched WIM

This is the normal BuildWIM v2 operator path.

Goal: produce a patched Windows 11 Pro image with as few choices as possible.

## What You Get

BuildWIM produces a Windows 11 Pro image with:

- latest Windows LCU
- latest .NET Framework cumulative update
- latest Safe OS / WinRE Dynamic Update
- latest Microsoft Defender offline definitions/platform
- component cleanup + ResetBase
- final verification
- HTML/Markdown report
- manifest and SHA256 hashes

You can output:

- `SWM` for FAT32/USB media
- `WIM` for one single `install.wim`
- `Both` when you want both

## The Simple Run

Open PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-BuildWIM.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1
```

When prompted:

```text
BuildWIM mode:
  Press Enter for Newbie

Newbie output:
  Press Enter for SWM
  Type O2 or WIM for a single install.wim
  Type O3 or Both to keep both WIM and SWM
```

That is the intended daily workflow.

## Recommended Fully Unattended Commands

Single patched `install.wim`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode WIM `
  -EmitMetadataJson
```

USB-ready split `install*.swm`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode SWM `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

Keep both WIM and SWM:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode Both `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

## Media Choice

Default media resolution:

```text
Local media -> Microsoft ESD -> Microsoft ISO
```

This means:

1. If `C:\BuildWimV2\Input` contains an ISO/WIM/ESD, BuildWIM uses it.
2. If input is empty, BuildWIM downloads from the Microsoft ESD catalog and exports Windows 11 Pro to `install.wim`.
3. If ESD resolution fails, BuildWIM falls back to the official Microsoft ISO connector.

Recommended default:

```powershell
-MediaProvider AutoFallback
```

Use local-only mode when production policy requires pre-approved source media:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -MediaProvider Local `
  -RequireLocalMedia `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode WIM
```

## The Few Choices That Matter

| Choice | Recommended | Why |
| --- | --- | --- |
| Mode | `Newbie` | Uses secure defaults and keeps the prompt small. |
| Output | `SWM` for USB, `WIM` for imaging workflows | Avoids producing artifacts you do not need. |
| Media provider | `AutoFallback` | Uses local media first, then Microsoft ESD, then ISO fallback. |
| Updates | Recommended | Pulls current Microsoft Catalog packages and verifies them after servicing. |
| Defender | Enabled in Newbie | Avoids starting from stale offline definitions. |

## Plan-Only Preview

Use this when you want to see what BuildWIM would do before a full build:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -PlanOnly `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode WIM
```

Plan-only creates a JSON and HTML plan under:

```text
C:\BuildWimV2\Reports\
```

It does not download Windows media, mount images, run DISM servicing, or change output artifacts.

## Where The Finished Files Land

```text
C:\BuildWimV2\Output\<yyyy-MM-dd>\install.wim
C:\BuildWimV2\Output\<yyyy-MM-dd>\install.swm
C:\BuildWimV2\Output\<yyyy-MM-dd>\install2.swm
C:\BuildWimV2\Output\<yyyy-MM-dd>\build-manifest.json
C:\BuildWimV2\Output\<yyyy-MM-dd>\SHA256SUMS.txt
```

Reports and logs:

```text
C:\BuildWimV2\Reports\BuildWIM-<timestamp>.html
C:\BuildWimV2\Reports\BuildWIM-<timestamp>.md
C:\BuildWimV2\Reports\BuildWIM-<timestamp>.diff.md
C:\BuildWimV2\Logs\BuildWIM-<timestamp>.log
C:\BuildWimV2\Logs\BuildWIM-<timestamp>.transcript.txt
```

## Operator Notes

- Run as Administrator.
- Keep at least 45 GB free for production builds.
- Use `SWM` for FAT32 USB media.
- Use `WIM` when your deployment system expects a single `install.wim`.
- Use `PlanOnly` on cramped validation hosts or before long production runs.
- Use `Expert` only when you need exact package selection, cleanup changes, or troubleshooting.

## What Success Looks Like

The final report should show:

```text
Verdict: SUCCESS
Final verification: OK
Output mode: WIM, SWM, or Both
Selected updates: LCU, .NET CU, SafeOS DU
Defender verification: OK or matched expected staged kit
SHA256 hashes written
```
