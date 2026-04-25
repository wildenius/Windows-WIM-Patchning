# Windows WIM Patching (BuildWIM)

BuildWIM is a production-oriented, automation-friendly offline servicing pipeline for Windows 11 installation media.

It takes a Windows 11 **ISO**, **install.wim** or **install.esd**, extracts/converts as needed, keeps **only Windows 11 Pro**, optionally injects offline update packages in a deterministic order, performs offline cleanup, and produces both a full WIM and a FAT32-friendly split SWM set — plus logs and an HTML report.

## Important note about ADK / WinPE

**Windows ADK and the WinPE add-on are NOT required to patch a WIM offline.**

BuildWIM uses the Windows built-in `DISM.exe` as the primary servicing engine. On Windows 11, `DISM.exe` is present by default.

ADK/WinPE may still be useful in broader deployment workflows (WinPE boot media creation, Windows Setup tooling, etc.), but this repository’s offline servicing pipeline does not depend on them.

## Outputs

After a successful run, you get:

- **Full WIM**: `C:\BuildWIM\Output\<yyyy-MM-dd>\install.wim`
- **Split SWM (FAT32)**: `C:\BuildWIM\Output\<yyyy-MM-dd>\install.swm`, `install2.swm`, ...
- **HTML report**: `C:\BuildWIM\Reports\BuildWIM-<timestamp>.html`
  - Includes build verdict, selected edition details, before/after image version info, step timings, injected/skipped packages, and output hashes
- **Markdown report**: `C:\BuildWIM\Reports\BuildWIM-<timestamp>.md`
  - Same data as HTML but in readable Markdown format (terminal-friendly)
- **Diff report**: `C:\BuildWIM\Reports\BuildWIM-<timestamp>.diff.md`
  - Shows new, removed, and unchanged KBs compared to the previous build
- **Logs**:
  - `C:\BuildWIM\Logs\BuildWIM-<timestamp>.log`
  - `C:\BuildWIM\Logs\BuildWIM-<timestamp>.transcript.txt`
- **Metadata JSON** (optional): `C:\BuildWIM\Output\BuildWIM-<timestamp>.metadata.json`

## Folder layout (root = `C:\BuildWIM\`)

```
C:\BuildWIM\
  Input\
  Updates\
  Mount\
  Output\
  Logs\
  Temp\
  Tools\
  Config\
  Reports\
```

- Put **one** input (ISO/WIM/ESD) into `C:\BuildWIM\Input\`
- Put update packages (`*.cab`, `*.msu`) into `C:\BuildWIM\Updates\` (optional)

## Quick start

### 1) Install/bootstrap the structure

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-BuildWIM.ps1
```

This installs to `C:\BuildWIM\`.

### 2) Run the pipeline (one command)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWIM\Build-WIM.ps1
```

Common options:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWIM\Build-WIM.ps1 `
  -SplitSizeMB 3800 `
  -EmitMetadataJson `
  -NotifyOnComplete
```

Dry run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWIM\Build-WIM.ps1 -DryRun
```

## Design highlights

- **Hard edition gate**: the workflow always exports a **Windows 11 Pro-only** working WIM before any servicing.
- **Deterministic package order**: SSU → LCU → .NET CU → Security/Hotfix/Setup → Other.
- **Idempotent servicing**: uses isolated mount directories, mounted-image readiness checks, remount retry, and `dism /Cleanup-Wim`.
- **Traceability**: logs + transcript + HTML report include executed DISM commands.
- **ASCII banner**: version, date, input type, and mode shown at startup.
- **Color-coded summary**: green/yellow/red based on build verdict.
- **Diff reports**: compare KBs between builds to see what changed.
- **Markdown reports**: terminal-friendly alternative to HTML.
- **Toast notifications**: optional `-NotifyOnComplete` flag for desktop notification when done.

## Bidra

Om du vill hjälpa till, läs [CONTRIBUTING.md](CONTRIBUTING.md) och följ anvisningarna där. Titta även på vår [Code of Conduct](CODE_OF_CONDUCT.md) för förväntat uppförande.

## Documentation

- English overview: `docs/OVERVIEW_EN.md`
- Logging strategy: `docs/LOGGING.md`

