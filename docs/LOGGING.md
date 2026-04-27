# Logging and reports

BuildWIM v2 is designed to leave a trail you can actually use after a long DISM run.

```text
Console
  |
  +-- C:\BuildWimV2\Logs\BuildWIM-<timestamp>.log
  +-- C:\BuildWimV2\Logs\BuildWIM-<timestamp>.transcript.txt
  +-- C:\BuildWimV2\Reports\BuildWIM-<timestamp>.html
  +-- C:\BuildWimV2\Reports\BuildWIM-<timestamp>.md
  `-- C:\BuildWimV2\Reports\BuildWIM-<timestamp>.diff.md
```

## Log levels

- `INFO` - normal progress.
- `WARN` - non-fatal deviation; build may continue.
- `ERROR` - fatal failure; build stops.
- `DEBUG` - detailed diagnostic data, including DISM command lines.

## Report types

| Report | Purpose |
| --- | --- |
| HTML | Best human-readable build summary. Includes verdict, timings, packages, image info, warnings, and DISM commands. |
| Markdown | Terminal-friendly version of the summary. Good for tickets and changelogs. |
| Diff Markdown | Compares KB/package state with the previous build so you can see what changed. |
| Metadata JSON | Optional machine-readable output when `-EmitMetadataJson` is used. |

## DISM traceability

Every executed DISM command is recorded so failures can be reproduced.

When troubleshooting, check in this order:

1. Final verdict in the HTML report.
2. `WARN` and `ERROR` lines in the `.log` file.
3. DISM command section in the report.
4. Full PowerShell transcript if the normal log is not enough.

## Common failure pattern: stale mount

If DISM reports an invalid or stale mount, close any Explorer or terminal windows inside the mount path and run:

```powershell
dism /Unmount-Wim /MountDir:C:\BuildWimV2\Mount /Discard
dism /Cleanup-Wim
dism /Cleanup-Mountpoints
dism /Get-MountedWimInfo
```

If the stale mount remains, reboot the build host and run the cleanup commands again before starting the next production build.
