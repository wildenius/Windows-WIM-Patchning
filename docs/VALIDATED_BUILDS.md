# Validated Builds

This file records known-good BuildWIM/WIM-Build validation runs and the artifacts they produced.

## 2026-05-04 01:11 - Final SWM SafeOS/WinRE proof

- **Host:** `DESKTOP-8P73FNP` / `.226`
- **Root:** `C:\BuildWimV2`
- **Final artifact source:** `C:\BuildWimV2\Output\2026-05-02\install*.swm`
- **Proof JSON:** `C:\BuildWimV2\Temp\VerifySafeOS-20260504-011140\safeos-winre-proof.json`
- **Verdict:** `SAFEOS_WINRE_VERIFICATION=OK`
- **Mount state after proof:** clean / `No mounted images found.`

### Validation focus

This proof validates the final delivered split-SWM artifact, not only the build logs.
The SWM set was exported back to WIM, the main image was mounted, nested
`Windows\System32\Recovery\winre.wim` was mounted, and WinRE packages were
enumerated with DISM.

### Proven SafeOS/WinRE state

```text
Expected KB              : KB5084812
Expected SafeOS version  : 26100.8309
Matched WinRE identity   : Package_for_SafeOSDU~31bf3856ad364e35~amd64~~26100.8309.1.7
WinRE package count      : 56
SafeOS CAB SHA256        : 7FAA579303B9D7A441EADD465CF9634808499E48DD38074D60E3BA216C20ED0F
install.swm SHA256       : 20C2FB12A90045B357F4BE695191215CB3CE7B078535F291E7C9CF733AAF39DC
install2.swm SHA256      : CB088C3E2340EC63D6BB056AFB8898A2D25AE6EEF1AE9D7242090396DE96042A
```

Note: `WinRE Image Version` can remain `10.0.26100.5074`; the production proof is
the installed SafeOSDU package identity/version inside mounted final `winre.wim`.

## 2026-05-01 21:11 - BuildWIM v2 full clean validation with Defender offline update

**Host:** `DESKTOP-8P73FNP` / `.226`  
**Root:** `C:\BuildWimV2`  
**Source ISO:** `C:\BuildWimV2\Input\Win11_25H2_EnglishInternational_x64_v2.iso`  
**Source ISO SHA256:** `66B7B4B71763ED6F9B2CE29326ED9284544DA6F5283D00329921540C01AAAEEA`  
**Command shape:** `Build-WIM.ps1 -AddDefenderSignatures -AcceptRecommendedUpdates -ForceRebuild -UpdateWindowsVersion 25H2 -UpdateArchitecture x64 -SplitSizeMB 3800 -EmitMetadataJson`  
**Verdict:** `SUCCESS`  
**Duration:** `01:58:00`  
**Report:** `C:\BuildWimV2\Reports\BuildWIM-20260501-211129.html`  
**Markdown report:** `C:\BuildWimV2\Reports\BuildWIM-20260501-211129.md`  
**Diff report:** `C:\BuildWimV2\Reports\BuildWIM-20260501-211129.diff.md`  
**Metadata:** `C:\BuildWimV2\Output\BuildWIM-20260501-211129.metadata.json`  
**Manifest:** `C:\BuildWimV2\Output\2026-05-01\build-manifest.json`  
**Checksums:** `C:\BuildWimV2\Output\2026-05-01\SHA256SUMS.txt`  
**Mount state after run:** clean / no BuildWIM process left mounted

### Validation focus

This run validates the complete clean-room path after deleting old BuildWIM artifacts:

- automatic official Windows 11 ISO download,
- smart update selection in unattended mode,
- latest Windows LCU download and injection,
- latest .NET Framework CU download and injection,
- latest Safe OS Dynamic Update download and WinRE servicing,
- latest Microsoft Defender offline update kit download,
- Defender definitions/platform staging into the mounted WIM without direct `DISM /Add-Package`,
- offline cleanup and commit,
- final WIM verification,
- SWM split, manifest, report, metadata, and SHA256 output.

### Integrated updates

- `KB5083769` - Windows 11 LCU, build `26200.8246`.
- `KB5082417` - .NET Framework cumulative update.
- `KB5084812` - Safe OS Dynamic Update for WinRE/SafeOS.
- Microsoft Defender offline update kit:
  - ZIP: `C:\BuildWimV2\Defender\defender-update-kit-x64.zip`
  - CAB: `C:\BuildWimV2\Defender\defender-update-kit-x64\defender-dism-x64.cab`
  - Platform observed in payload: `4.18.26030.3011-0`
  - Log evidence: `Microsoft Defender offline update injected successfully.`

### Output artifacts

| Artifact | Path | Size | SHA256 |
| --- | --- | ---: | --- |
| Manifest | `C:\BuildWimV2\Output\2026-05-01\build-manifest.json` | `22,896 bytes` | `6EA2E87ABC49881AE538766F6B4869DB77BAF1A4E8C6AF21B7503947D9855BFB` |
| Final WIM | `C:\BuildWimV2\Output\2026-05-01\install.wim` | `7,560,219,204 bytes` | `538A20C0554EB3593C274EECE54E35B89CC42297F31DD3913C89231EDA14AC70` |
| Split SWM part 1 | `C:\BuildWimV2\Output\2026-05-01\install.swm` | `3,945,943,907 bytes` | `851BE67F6D9603A7BBF288967036BA74FD86CCA2C56C74A97892B5C3E602FFCE` |
| Split SWM part 2 | `C:\BuildWimV2\Output\2026-05-01\install2.swm` | `3,614,263,773 bytes` | `B373A8DFF1D74EE1034D485C511A568CFB084255255E885A870DD5534516CBB6` |

### Final WIM verification

```text
Version           : 10.0.26200
Image name        : Windows 11 Pro
Architecture      : x64
ServicePack Build : 8246
DisplayVersion    : 25H2
CurrentBuild      : 26200
UBR               : 8246
LCU identity      : Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8246.1.23
.NET identity     : Package_for_DotNetRollup_481~31bf3856ad364e35~amd64~~10.0.9333.2
Verification      : LCU=True; DotNetCU=True; ServicePack=True; UBR=True
```

This is the current reference validation for BuildWIM v2 with Defender offline signatures enabled.

## 2026-04-30 10:25 - BuildWIM v2 .NET CU delta validation

**Host:** `DESKTOP-8P73FNP` / `.226`
**Root:** `C:\BuildWimV2`
**Verdict:** `SUCCESS`
**Duration:** `01:19:06`
**Report:** `C:\BuildWimV2\Reports\BuildWIM-20260430-102538.html`
**Output folder:** `C:\BuildWimV2\Output\2026-04-30`
**Mount state after run:** clean / no mounted images found

### Validation focus

This run validates the .NET CU delta fix: latest .NET CU lookup and selected package inclusion happen before the OS-LCU delta-skip decision. A source image that is already current for the Windows LCU no longer suppresses a rebuild when a selected .NET CU package exists.

### Integrated updates

- `KB5083769` - Windows 11 LCU.
- `KB5082417` - .NET Framework cumulative update.

### Output artifacts

| Artifact | Path | SHA256 |
| --- | --- | --- |
| Final WIM | `C:\BuildWimV2\Output\2026-04-30\install.wim` | `01FC460916D69E63A2FECEFB026DFBD585F1AA3EC1E6ABE0E45F274445349922` |
| Split SWM part 1 | `C:\BuildWimV2\Output\2026-04-30\install.swm` | `6EC1147ADDC9FB9FDA1965E895CB82166F6C8F4D28BAE67E027BD635C65B0B69` |
| Split SWM part 2 | `C:\BuildWimV2\Output\2026-04-30\install2.swm` | `A61603450B15F9914574889E67A4FA75CF23CFF90980EE2700DE3139FBD85B62` |

### Additional fix confirmed

Package sorting now returns flat package objects, avoiding report/log classification artifacts like `[LCU DotNetCU]` and `[System.Object[]]`.

## 2026-04-28 21:50 - BuildWIM v2 production rerun after cleanup

**Host:** `DESKTOP-8P73FNP` / `.226`
**Root:** `C:\BuildWimV2`
**Source ISO:** `C:\BuildWimV2\Input\Win11_25H2_EnglishInternational_x64.iso`
**Source ISO SHA256:** `BAAEB6C90DD51648154B64C40C9E0C14D93A427F611A1BB49C8077FA2FF73364`
**Command shape:** `Build-WIM.ps1 -AutoDownloadLatestLCU -UpdateWindowsVersion 25H2 -UpdateArchitecture x64 -SplitSizeMB 3800 -EmitMetadataJson -NotifyOnComplete`
**Verdict:** `SUCCESS`
**Duration:** `01:26:38`
**Report:** `C:\BuildWimV2\Reports\BuildWIM-20260428-215019.html`
**Markdown report:** `C:\BuildWimV2\Reports\BuildWIM-20260428-215019.md`
**Diff report:** `C:\BuildWimV2\Reports\BuildWIM-20260428-215019.diff.md`
**Metadata:** `C:\BuildWimV2\Output\BuildWIM-20260428-215019.metadata.json`
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

### Output artifacts

| Artifact | Path | Size | SHA256 |
| --- | --- | ---: | --- |
| Manifest | `C:\BuildWimV2\Output\2026-04-28\build-manifest.json` | `12,750 bytes` | `C9B109DB8A23CFF894BB9217A68AE8032DDDC8DF42F25F7A2A71DF139F4618EC` |
| Final WIM | `C:\BuildWimV2\Output\2026-04-28\install.wim` | `7,137,080,597 bytes` | `54292CCF24A14C8463DE18AC24D9B54ADE29C3D8CFD0D3C4F0AF317DB7BF93C2` |
| Split SWM part 1 | `C:\BuildWimV2\Output\2026-04-28\install.swm` | `3,912,477,963 bytes` | `B1DF8974C723E23308A8D91F1B6463C456B343D3E34DEBD328BAFA98ECB8FB2E` |
| Split SWM part 2 | `C:\BuildWimV2\Output\2026-04-28\install2.swm` | `3,224,591,910 bytes` | `4DC6860C5342516739B5D479C332CD53A56A58B76E8CEF792BAB057310969847` |

### Final WIM verification

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

This run confirms the production chain after disk cleanup: latest LCU download,
offline injection, final WIM verification, SWM split, manifest, reports, checksums,
and clean mount state.

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
