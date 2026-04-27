# Validated Builds

This file records known-good BuildWIM/WIM-Build validation runs and the artifacts they produced.

## 2026-04-27 - WIM-Buildv2 Johan preset with April 2026 LCU

**Host:** `10.82.80.226`
**Root:** `C:\WIM-Buildv2`
**Source ISO:** `C:\BuildWimV2\Input\Win11_25H2_EnglishInternational_x64.iso`
**Preset/profile:** `johan`
**Updates integrated:** yes
**Report:** `C:\WIM-Buildv2\reports\WIM-Buildv2-report-20260427-011649.json` / `.html`

### Integrated update

- **KB:** `KB5083769`
- **Title:** `2026-04 Cumulative Update for Windows 11, version 25H2 for x64-based Systems`
- **Build:** `26200.8246`
- **MSU:** `C:\WIM-Buildv2\updates\windows11.0-kb5083769-x64_57f4bd47d73842dd239f2c18b8ce48c8bf1c1d5d.msu`
- **MSU size:** `4,830,778,941 bytes`

### Output artifacts

| Artifact | Path | Size |
| --- | --- | ---: |
| Working WIM | `C:\WIM-Buildv2\output\install-v2.wim` | `9,807,651,440 bytes` |
| Optimized WIM | `C:\WIM-Buildv2\output\install-v2-optimized.wim` | `6,878,867,943 bytes` |
| Split SWM part 1 | `C:\WIM-Buildv2\swm\install.swm` | `3,983,862,688 bytes` |
| Split SWM part 2 | `C:\WIM-Buildv2\swm\install2.swm` | `2,895,008,175 bytes` |

### Build log verdict

The final build log ended with:

```text
[2026-04-27 01:16:49] [OK] WIM-Buildv2 completed successfully.
```

### Post-build note

The WIM/SWM artifacts were produced successfully, but DISM still listed an invalid read-only verification mount at:

```text
C:\WIM-Buildv2\verify-mount
```

`dism /Cleanup-Wim` and `dism /Cleanup-Mountpoints` completed but did not remove the stale entry. Recommended cleanup before the next production run:

```powershell
dism /Unmount-Wim /MountDir:C:\WIM-Buildv2\verify-mount /Discard
dism /Cleanup-Wim
dism /Cleanup-Mountpoints
dism /Get-MountedWimInfo
```

If the invalid mount remains, reboot the build host and run the cleanup commands again before starting a new build.

## 2026-04-26 - WIM-Buildv2 Johan preset without KB

**Host:** `10.82.80.226`
**Root:** `C:\WIM-Buildv2`
**Preset/profile:** `johan`
**Updates integrated:** no

Validation outcome:

- ISO index 6 export succeeded
- Debloat completed
- Consumer features were disabled
- Component cleanup and ResetBase completed
- Optimized WIM export completed
- FAT32 SWM split completed
- No mounted images remained after that run

Artifacts from that run:

- `C:\WIM-Buildv2\output\install-v2.wim`
- `C:\WIM-Buildv2\output\install-v2-optimized.wim`
- `C:\WIM-Buildv2\swm\install.swm`
- `C:\WIM-Buildv2\swm\install2.swm`
