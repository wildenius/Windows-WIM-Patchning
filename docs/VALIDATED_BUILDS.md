# Validated Builds

This file records known-good BuildWIM/WIM-Build validation runs and the artifacts they produced.

## 2026-04-28 - BuildWIM v2 production run with hardened verification

**Host:** `Windows test VM` / `lab host`
**Root:** `C:\BuildWimV2`
**Source ISO:** `C:\BuildWimV2\Input\Win11_25H2_EnglishInternational_x64.iso`
**Source ISO SHA256:** `BAAEB6C90DD51648154B64C40C9E0C14D93A427F611A1BB49C8077FA2FF73364`
**Command shape:** `Build-WIM.ps1 -AutoDownloadLatestLCU -UpdateWindowsVersion 25H2 -UpdateArchitecture x64 -SplitSizeMB 3800 -EmitMetadataJson`
**Verdict:** `SUCCESS`
**Duration:** `01:28:00`
**Report:** `C:\BuildWimV2\Reports\BuildWIM-20260428-024740.html`
**Markdown report:** `C:\BuildWimV2\Reports\BuildWIM-20260428-024740.md`
**Diff report:** `C:\BuildWimV2\Reports\BuildWIM-20260428-024740.diff.md`
**Manifest:** `C:\BuildWimV2\Output\2026-04-28\build-manifest.json`
**Checksums:** `C:\BuildWimV2\Output\2026-04-28\SHA256SUMS.txt`

### Integrated update

- **KB:** `KB5083769`
- **Title:** `2026-04 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5083769) (26200.8246)`
- **Classification:** `Security Updates`
- **Last updated:** `4/14/2026`
- **Build:** `26200.8246`
- **Update ID:** `9edcb571-68d8-45cf-879e-0fe2cc45ecc0`
- **MSU:** `C:\BuildWimV2\Updates\windows11.0-kb5083769-x64_57f4bd47d73842dd239f2c18b8ce48c8bf1c1d5d.msu`
- **MSU SHA256:** `D5BD7005C9F45927337ECE31A047AE9C82F6B953DBB5B8A9FE7F7D15E792B1C5`
- **MSU signature:** `Valid`
- **Cache:** `C:\BuildWimV2\Updates\catalog-cache.json`
- **Sidecar:** `C:\BuildWimV2\Updates\windows11.0-kb5083769-x64_57f4bd47d73842dd239f2c18b8ce48c8bf1c1d5d.msu.metadata.json`

### Output artifacts

| Artifact | Path | Size | SHA256 |
| --- | --- | ---: | --- |
| Manifest | `C:\BuildWimV2\Output\2026-04-28\build-manifest.json` | `12,747 bytes` | `EF563A500B01A926CBFD1AF8ED7A74D1C08188B80596B527129DB8B208AEAFAC` |
| Final WIM | `C:\BuildWimV2\Output\2026-04-28\install.wim` | `7,137,107,233 bytes` | `660958F902F3097AD2F480256B05D7446639AACBEF589593781DDCB946C97F2C` |
| Split SWM part 1 | `C:\BuildWimV2\Output\2026-04-28\install.swm` | `3,933,488,997 bytes` | `AD324E115A4EF8E264BD6473FF278ADB374ECA5D3467A3226A312D8F18B1CFDA` |
| Split SWM part 2 | `C:\BuildWimV2\Output\2026-04-28\install2.swm` | `3,203,607,512 bytes` | `399E356C5F0D6A7B3530EEC0F55EAF88FF94E5018AD335FD7CDBFF2D5ED1F5BC` |

### Final WIM verification

The final WIM was mounted after the build and verified by the script:

```text
Version           : 10.0.26200
Image name        : Windows 11 Pro
Architecture      : x64
ServicePack Build : 8246
DisplayVersion    : 25H2
CurrentBuild      : 26200
UBR               : 8246
LCU identity      : Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8246.1.23
Verification      : Package=True; ServicePack=True; UBR=True
Mount status      : No mounted images found
```

This run validates the hardened verifier: it accepts the Microsoft Update Catalog
build revision from the downloaded MSU sidecar and confirms the final WIM through
package identity, DISM image build, and offline registry UBR.

## 2026-04-27 - BuildWIM v2 production run with automatic April 2026 LCU

**Host:** `Windows test VM` / `lab host`
**Root:** `C:\BuildWimV2`
**Source ISO:** `C:\BuildWimV2\Input\Win11_25H2_EnglishInternational_x64.iso`
**Command shape:** `Build-WIM.ps1 -AutoDownloadLatestLCU -UpdateWindowsVersion 25H2 -UpdateArchitecture x64 -SplitSizeMB 3800 -EmitMetadataJson`
**Verdict:** `SUCCESS WITH WARNINGS`
**Duration:** `01:19:10`
**Report:** `C:\BuildWimV2\Reports\BuildWIM-20260427-233307.html`
**Metadata:** `C:\BuildWimV2\Output\BuildWIM-20260427-233307.metadata.json`

### Integrated update

- **KB:** `KB5083769`
- **Title:** `2026-04 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5083769) (26200.8246)`
- **Classification:** `Security Updates`
- **Last updated:** `4/14/2026`
- **Build:** `26200.8246`
- **Update ID:** `9edcb571-68d8-45cf-879e-0fe2cc45ecc0`
- **MSU:** `C:\BuildWimV2\Updates\windows11.0-kb5083769-x64_57f4bd47d73842dd239f2c18b8ce48c8bf1c1d5d.msu`
- **MSU SHA256:** `D5BD7005C9F45927337ECE31A047AE9C82F6B953DBB5B8A9FE7F7D15E792B1C5`
- **MSU signature:** `Valid`

### Output artifacts

| Artifact | Path | Size | SHA256 |
| --- | --- | ---: | --- |
| Final WIM | `C:\BuildWimV2\Output\2026-04-27\install.wim` | `7,137,151,541 bytes` | `4A2DF8D450F3B1F6EB5FE197E20D272B1E9538B7AACCDFA36EF0199FE9AD89A3` |
| Split SWM part 1 | `C:\BuildWimV2\Output\2026-04-27\install.swm` | `3,933,535,843 bytes` | `69E01F46808CC689C44CE47339F963CDFD76481E9DC6E781D2A90478E64F87DE` |
| Split SWM part 2 | `C:\BuildWimV2\Output\2026-04-27\install2.swm` | `3,203,604,974 bytes` | `5B44525F6533426587A30F5719DE63D7E8E622D4A35CFFF2E0159E61F4D0FFAE` |

### Final WIM verification

The final WIM was mounted after the build and verified independently:

```text
Version           : 10.0.26200
ServicePack Build : 8246
DisplayVersion    : 25H2
UBR               : 0x2036
LCU identity      : Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8246.1.23
Mount status      : No mounted images found
```

The `SUCCESS WITH WARNINGS` verdict was caused by old verifier logic that searched
for the public KB string (`KB5083769`) in offline package identities. Windows LCUs
normally appear as `Package_for_RollupFix` with the build revision instead. The
verifier has been updated to accept the Microsoft Update Catalog build revision
from the sidecar metadata.

## 2026-04-27 - WIM-Buildv2 Johan preset with April 2026 LCU

**Host:** `lab host`
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

**Host:** `lab host`
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
