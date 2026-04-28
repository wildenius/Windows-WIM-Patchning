# BuildWIM v2 Production Runbook

```text
+------------------------------------------------------------------------------+
|                                                                              |
|   BBBBB   U   U  III  L      DDDD   W   W  III  M   M      V   V  22222      |
|   B    B  U   U   I   L      D   D  W   W   I   MM MM       V V      2      |
|   BBBBB   U   U   I   L      D   D  W W W   I   M M M        V      222     |
|   B    B  U   U   I   L      D   D  WW WW   I   M   M       V V    2        |
|   BBBBB    UUU   III  LLLLL  DDDD   W   W  III  M   M      V   V  22222     |
|                                                                              |
|        Offline Windows 11 Pro image servicing that leaves evidence.           |
|                                                                              |
+------------------------------------------------------------------------------+
```

BuildWIM v2 builds a patched Windows 11 Pro installation image from a clean source
ISO/WIM/ESD. It is designed to be boring, repeatable, auditable, and safe enough
that a future operator can understand exactly what happened from the logs and
reports.

This runbook documents the production flow, the latest-KB download logic, the
validation gates, and the known-good 2026-04-27 validation run.

## One-screen summary

```text
                  +-----------------------------+
                  |  C:\BuildWimV2\Input        |
                  |  ISO / install.wim / ESD    |
                  +--------------+--------------+
                                 |
                                 v
+----------------+     +---------+---------+     +-------------------------+
| Safety gates   | --> | Pro-only export   | --> | Smart latest LCU        |
| admin/disk/src |     | index 6 -> 1 WIM  |     | Catalog -> MSU/skip     |
+----------------+     +---------+---------+     +-----------+-------------+
                                 |                           |
                                 v                           v
                  +--------------+---------------------------+--------------+
                  |      Package planning and DISM servicing                |
                  |      SSU -> LCU -> .NET CU -> Security -> Other         |
                  +--------------+---------------------------+--------------+
                                 |
                                 v
                  +--------------+--------------+
                  | Cleanup + ResetBase         |
                  | Commit mount                |
                  | Export final install.wim    |
                  | Split install*.swm          |
                  +--------------+--------------+
                                 |
                                 v
                  +--------------+--------------+
                  | Reports, metadata, hashes   |
                  | final mounted-image check   |
                  +-----------------------------+
```

## Default production root

```text
C:\BuildWimV2
```

Expected layout:

```text
C:\BuildWimV2\
|-- Build-WIM.ps1
|-- Get-LatestWindows11LCU.ps1
|-- Install-BuildWIM.ps1
|-- Config\
|   `-- buildwim.config.json
|-- Input\
|   `-- Win11_25H2_EnglishInternational_x64.iso
|-- Updates\
|   `-- windows11.0-kb5083769-x64_... .msu
|-- Mount\
|-- Temp\
|-- Output\
|-- Reports\
`-- Logs\
```

## Recommended commands

Dry run first. This validates discovery, configuration, package classification,
and reporting without doing destructive DISM work:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -DryRun `
  -UpdateWindowsVersion 25H2 `
  -UpdateArchitecture x64 `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

Important dry-run behavior:

- `-DryRun` must not download a new MSU.
- Latest LCU auto-detection logs that download side effects are skipped in dry-run mode.
- Final mounted-image KB validation is skipped in dry-run mode because no final
  WIM exists.

Production run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -UpdateWindowsVersion 25H2 `
  -UpdateArchitecture x64 `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

Check latest LCU without a build:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -CheckLatestLCU `
  -UpdateWindowsVersion 25H2 `
  -UpdateArchitecture x64
```

Download the latest LCU only:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Get-LatestWindows11LCU.ps1 `
  -WindowsVersion 25H2 `
  -Architecture x64 `
  -OutputPath C:\BuildWimV2\Updates
```

## Pipeline details

### 1. Safety and preflight

BuildWIM checks the environment before touching the image.

Key gates:

- PowerShell is elevated.
- `DISM.exe` is available.
- The source folder exists.
- The configured BuildWIM folders exist or can be created.
- Free disk space is above the configured minimum.
- Stale WIM mount state is cleaned with DISM cleanup.

Recommended minimum free space is intentionally conservative. A current Windows
11 LCU can temporarily consume a lot of scratch and mount space during
`/Add-Package`, `/StartComponentCleanup`, and `/Unmount-Image /Commit`.

### 2. Source discovery

Supported source types:

```text
ISO -> mount ISO, locate sources\install.wim or sources\install.esd
WIM -> use directly
ESD -> convert/export to WIM before servicing
```

The script inspects image indexes and chooses Windows 11 Pro. The production
pipeline services one Pro-only image instead of every index in the source media.

Why this matters:

- Smaller working set.
- Faster servicing.
- Less chance of patching the wrong edition.
- Cleaner output for deployment media.

### 3. Pro-only working WIM

The selected Windows 11 Pro index is exported into a temporary single-index WIM.
That WIM becomes the only servicing target.

Typical shape:

```text
Input ISO multi-index install.wim
        |
        v
Temp\install-pro-only-<timestamp>.wim
        |
        v
Mount\Mount-<timestamp>
```

### 4. Latest KB download / skip check

`Build-WIM.ps1` checks Microsoft Update Catalog before package discovery by default and compares the Catalog result with BuildWIM-managed LCU metadata already present in `C:\BuildWimV2\Updates`. The legacy `-AutoDownloadLatestLCU` switch is still accepted, but no longer required.

Behavior:

- no matching LCU in `Updates` -> download the latest Catalog LCU
- existing LCU build is current -> skip the download
- Catalog build is newer -> download the newer LCU
- older BuildWIM-managed LCU sidecars/packages remain as evidence but are moved out of the active servicing folder into `Updates\Superseded\<timestamp>` so DISM does not inject multiple LCUs

The downloader does this:

```text
+-----------------------------+
| Build query                 |
| Windows 11 version 25H2 x64 |
| cumulative update           |
+-------------+---------------+
              |
              v
+-------------+---------------+
| Microsoft Update Catalog    |
| Search.aspx?q=...           |
+-------------+---------------+
              |
              v
+-------------+---------------+
| Parse result table          |
| title/classification/date   |
| KB/build/update GUID        |
+-------------+---------------+
              |
              v
+-------------+---------------+
| Filter candidates           |
| - Windows 11                |
| - requested version         |
| - requested architecture    |
| - Cumulative Update         |
| - not .NET                  |
| - not Dynamic Update        |
| - not Safe OS Dynamic       |
| - not Preview by default    |
+-------------+---------------+
              |
              v
+-------------+---------------+
| Pick newest by date/title   |
+-------------+---------------+
              |
              v
+-------------+---------------+
| DownloadDialog.aspx POST    |
| extract real .msu URL       |
+-------------+---------------+
              |
              v
+-------------+---------------+
| Save MSU to Updates folder  |
| write metadata sidecar      |
+-----------------------------+
```

The sidecar file is critical:

```text
<downloaded-msu>.metadata.json
```

The downloader also maintains a small cache index:

```text
C:\BuildWimV2\Updates\catalog-cache.json
```

The cache records the latest Catalog result per Windows version and architecture,
including KB, build, URL, local path, SHA256, and check time. It is evidence and a
fast operator reference; production still validates the selected package and final
WIM instead of blindly trusting the cache.

Example metadata fields:

```json
{
  "KB": "KB5083769",
  "Title": "2026-04 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5083769) (26200.8246)",
  "Classification": "Security Updates",
  "LastUpdated": "4/14/2026",
  "Build": "26200.8246",
  "UpdateId": "9edcb571-68d8-45cf-879e-0fe2cc45ecc0",
  "Url": "https://catalog.sf.dl.delivery.mp.microsoft.com/.../windows11.0-kb5083769-x64_....msu",
  "Path": "C:\\BuildWimV2\\Updates\\windows11.0-kb5083769-x64_....msu"
}
```

BuildWIM uses this sidecar to classify a loose MSU correctly as `LCU`. This is
more reliable than asking DISM for package info on a standalone MSU, because DISM
is not always useful before the package is expanded.

### 5. Package classification and order

Packages are discovered from `C:\BuildWimV2\Updates` and sorted before injection.

Order:

```text
0  SSU
10 LCU
20 DotNetCU
30 Security
40 Hotfix
50 Setup
90 Other
```

LCU detection preference:

1. Metadata sidecar title says Windows 11 cumulative update.
2. DISM package info, when available.
3. Filename fallback.

### 6. Offline servicing

Servicing is done against the mounted Pro-only WIM:

```text
dism.exe /English /Mount-Image /ImageFile:<working.wim> /Index:1 /MountDir:<mount>
dism.exe /English /Image:<mount> /Add-Package /PackagePath:<package.msu>
dism.exe /English /Image:<mount> /Cleanup-Image /StartComponentCleanup /ResetBase
dism.exe /English /Unmount-Image /MountDir:<mount> /Commit
```

Important operational notes:

- The script uses isolated per-run mount directories.
- Mounted-image readiness is checked before servicing.
- If a mount reports `Needs Remount`, the script remounts and retries.
- DISM stdout/stderr is written into the BuildWIM log for auditability.

### 7. Final WIM export and SWM split

After the servicing mount is committed, the script exports a clean final WIM:

```text
Temp\install-pro-only-<timestamp>.wim
        |
        v
Output\<yyyy-MM-dd>\install.wim
```

Then it creates FAT32-friendly split files:

```text
Output\<yyyy-MM-dd>\install.swm
Output\<yyyy-MM-dd>\install2.swm
...
```

Default split size for USB media:

```text
3800 MB
```

### 8. Final validation

BuildWIM validates the final WIM by mounting it again read-only/verification style
and checking image metadata and installed packages.

For modern Windows LCUs, one detail matters:

```text
Public name:       KB5083769
Offline identity:  Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8246.1.23
```

That means final validation must not only search for the public KB string. The
correct verifier also accepts the LCU build revision from the Microsoft Update
Catalog metadata sidecar. For `26200.8246`, the revision is `8246`, so
`Package_for_RollupFix~...~26100.8246.1.23` confirms the LCU is installed.

### 9. Reports and evidence

A successful run creates:

```text
Reports\BuildWIM-<timestamp>.html
Reports\BuildWIM-<timestamp>.md
Reports\BuildWIM-<timestamp>.diff.md
Logs\BuildWIM-<timestamp>.log
Logs\BuildWIM-<timestamp>.transcript.txt
Output\BuildWIM-<timestamp>.metadata.json
Output\<yyyy-MM-dd>\build-manifest.json
Output\<yyyy-MM-dd>\SHA256SUMS.txt
Output\<yyyy-MM-dd>\install.wim
Output\<yyyy-MM-dd>\install*.swm
```

The metadata JSON and manifest include:

- input path and SHA256,
- selected edition and Pro index,
- selected/downloaded KB metadata,
- Catalog URL and MSU SHA256,
- source/final image version,
- final WIM/SWM paths and SHA256,
- DISM version, hostname, script version, and git commit when available,
- final image verification results,
- USB/SWM compatibility checks,
- warnings/errors,
- per-step timings.

## Known-good validation: 2026-04-27 on .226

Host:

```text
Windows test VM / lab host
```

Command shape:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Build-WIM.ps1 `
  -UpdateWindowsVersion 25H2 `
  -UpdateArchitecture x64 `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

Selected update:

```text
KB:             KB5083769
Title:          2026-04 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5083769) (26200.8246)
Classification: Security Updates
Last updated:   4/14/2026
Build:          26200.8246
Update ID:      9edcb571-68d8-45cf-879e-0fe2cc45ecc0
MSU SHA256:     D5BD7005C9F45927337ECE31A047AE9C82F6B953DBB5B8A9FE7F7D15E792B1C5
Signature:      Valid
```

Build result:

```text
Verdict:   SUCCESS WITH WARNINGS
Duration:  01:19:10
Report:    C:\BuildWimV2\Reports\BuildWIM-20260427-233307.html
Metadata:  C:\BuildWimV2\Output\BuildWIM-20260427-233307.metadata.json
```

The warning was a false-positive final verifier warning from the old logic. The
final WIM was manually verified as patched:

```text
Version:           10.0.26200
ServicePack Build: 8246
DisplayVersion:    25H2
UBR:               0x2036
LCU identity:      Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8246.1.23
Mount status:      No mounted images found
```

Artifacts:

```text
C:\BuildWimV2\Output\2026-04-27\install.wim
C:\BuildWimV2\Output\2026-04-27\install.swm
C:\BuildWimV2\Output\2026-04-27\install2.swm
```

Hashes:

```text
install.wim   4A2DF8D450F3B1F6EB5FE197E20D272B1E9538B7AACCDFA36EF0199FE9AD89A3
install.swm   69E01F46808CC689C44CE47339F963CDFD76481E9DC6E781D2A90478E64F87DE
install2.swm  5B44525F6533426587A30F5719DE63D7E8E622D4A35CFFF2E0159E61F4D0FFAE
```

## Troubleshooting quick map

```text
+-------------------------------+----------------------------------------------+
| Symptom                       | First check                                  |
+-------------------------------+----------------------------------------------+
| Not enough disk               | Free C: space, Temp/Mount cleanup            |
| DISM mount stuck              | dism /Get-MountedWimInfo, then Cleanup-Wim   |
| KB not detected in final WIM  | Look for Package_for_RollupFix build number  |
| Wrong update downloaded       | Catalog title/version/architecture filters   |
| Preview selected              | Ensure -IncludePreview was not used          |
| Dry-run downloaded package    | Bug: dry-run must skip download side effects |
| SWM too large for FAT32       | Lower -SplitSizeMB, usually 3800 is safe     |
+-------------------------------+----------------------------------------------+
```

## Operator checklist

Before production:

```text
[ ] Source ISO/WIM/ESD is in C:\BuildWimV2\Input
[ ] Enough disk space is available
[ ] No stale mounted WIMs remain
[ ] Dry-run completed without unexpected warnings
[ ] Latest LCU metadata sidecar exists if auto-download was used
```

After production:

```text
[ ] Build verdict is SUCCESS or understood SUCCESS WITH WARNINGS
[ ] install.wim exists
[ ] install.swm and install2.swm exist when splitting is enabled
[ ] SHA256 hashes are present in metadata/report
[ ] Final WIM reports expected build revision
[ ] Package_for_RollupFix revision matches selected LCU build
[ ] dism /Get-MountedWimInfo reports no mounted images
[ ] Temp and Mount folders are clean
```
