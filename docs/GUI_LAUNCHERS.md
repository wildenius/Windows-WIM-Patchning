# BuildWIM GUI Launchers

BuildWIM includes several experimental Windows front-ends for the same production pipeline in `Build-WIM.ps1`.

The core automation remains scriptable and should still be considered the source of truth. The launchers are convenience wrappers for selecting input media, checking readiness, previewing the command, and starting a dry-run or production build.

## Launchers

| File | UI stack | Purpose |
| --- | --- | --- |
| `Start-BuildWIM-GUI.ps1` | WinForms | Simple launcher for selecting ISO/WIM/ESD input and update packages. |
| `Start-BuildWIM-MissionControl.ps1` | WinForms | Dark cockpit UI with readiness cards, command preview, redirected build output, timeline parsing, and report/output shortcuts. |
| `Start-BuildWIM-ProStudio.ps1` | WPF | Premium product-style prototype with readiness score and guided actions. |
| `Start-BuildWIM-ProStudio-Sexy.ps1` | WPF | Neon-styled Pro Studio variant with optional preview rendering support. |

## Prerequisites

Run on Windows with:

- Administrator PowerShell for real builds
- Built-in Windows `DISM.exe`
- A prepared BuildWIM root, normally `C:\BuildWIM`
- `Build-WIM.ps1` available in the BuildWIM root
- Optional updates in `C:\BuildWIM\Updates`

Windows ADK is not required for offline WIM servicing.

## Recommended first run

From the repository folder:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-BuildWIM.ps1
```

Then start a UI launcher, for example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-BuildWIM-MissionControl.ps1
```

Or, if the scripts have already been copied to `C:\BuildWIM`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWIM\Start-BuildWIM-MissionControl.ps1
```

## Dry-run before production

Always run a dry-run first when changing input media, update packages, or config:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWIM\Build-WIM.ps1 -DryRun
```

The GUI launchers expose dry-run/preview style actions where applicable.

## Production build

A normal scripted production build is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWIM\Build-WIM.ps1 `
  -SplitSizeMB 3800 `
  -EmitMetadataJson `
  -NotifyOnComplete
```

The output is written under:

- `C:\BuildWIM\Output\<yyyy-MM-dd>\install.wim`
- `C:\BuildWIM\Output\<yyyy-MM-dd>\install.swm`, `install2.swm`, ...
- `C:\BuildWIM\Reports\BuildWIM-<timestamp>.html`
- `C:\BuildWIM\Reports\BuildWIM-<timestamp>.md`
- `C:\BuildWIM\Logs\BuildWIM-<timestamp>.log`

## Configuration defaults

`Config/buildwim.config.json` currently enables:

- Pro-only export before servicing
- Direct MSU servicing
- FAT32 split size: `3800 MB`
- Component cleanup: `/StartComponentCleanup`
- ResetBase cleanup: enabled
- Minimum free space: `45 GB`

## Safety notes

- Keep the core pipeline in `Build-WIM.ps1`; GUI scripts should not duplicate servicing logic.
- Treat WPF/WinForms launchers as wrappers/prototypes unless they have been validated on a real Windows host.
- If DISM reports stale or invalid mounts, close open Explorer/terminal windows inside mount folders and run:

```powershell
dism /Cleanup-Wim
dism /Cleanup-Mountpoints
dism /Get-MountedWimInfo
```

If an invalid mount remains after cleanup, reboot the build host and run cleanup again before starting another production build.
