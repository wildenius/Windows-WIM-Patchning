# Windows WIM Patchning

Minimal BuildWIM repository for creating a patched Windows 11 Pro `install.wim` or split `install.swm` files.

## What It Does

- Uses a Windows 11 ISO, WIM, or ESD as source.
- Exports Windows 11 Pro to a working WIM.
- Downloads and injects the latest Windows 11 LCU when enabled.
- Can auto-resolve Microsoft Windows 11 media if no local source exists.
- Produces WIM or USB-friendly split SWM output.

## Requirements

- Windows 11.
- Elevated PowerShell.
- Internet access for automatic Microsoft media/update download.
- At least 45 GB free disk space.

## Install

Run from this repo folder in elevated PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-BuildWIM.ps1
```

This installs the runtime files to:

```text
C:\BuildWimV2
```

## Basic Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1
```

Default flow is beginner-friendly:

- Newbie mode starts automatically.
- SWM output is default for USB/FAT32 compatibility.
- Press a key during startup if you want Expert options.

## Local Source

Put one official Windows 11 source file here:

```text
C:\BuildWimV2\Input
```

Supported source files:

- `.iso`
- `install.wim`
- `install.esd`

## Useful Examples

Create one WIM:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode WIM
```

Create USB-friendly split SWM:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -UiMode Newbie `
  -AcceptRecommendedUpdates `
  -OutputMode SWM
```

Preview plan without building:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -PlanOnly `
  -UiMode Newbie
```

## Output

Build output lands under:

```text
C:\BuildWimV2\Output
```

Logs and reports land under:

```text
C:\BuildWimV2\Logs
C:\BuildWimV2\Reports
```

## Runtime Files

The repo is intentionally small. These are the needed runtime files:

- `Build-WIM.ps1`
- `Install-BuildWIM.ps1`
- `Get-LatestWindows11LCU.ps1`
- `Get-Windows11Iso.ps1`
- `Resolve-BuildWimMicrosoftEsd.ps1`
- `Config/buildwim.config.json`
- `Config/approved-sources.json`
- `Config/approved-updates-policy.json`
