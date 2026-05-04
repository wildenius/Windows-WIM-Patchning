# BuildWIM patch state model

This document explains how BuildWIM decides whether a Windows image needs servicing and how the final artifact proves each update class.

## Core rule

BuildWIM should never assume an image is current just because the source ISO/WIM is new. It compares the image state against the selected/latest approved update metadata per update class, then verifies the finished artifact offline.

There are two separate decisions:

1. **Rebuild decision** - should BuildWIM service this source image now?
2. **Final proof** - after servicing, can the finished WIM/SWM prove the selected updates are present?

A green build requires the second decision to be proven from the mounted final artifact, not only from download logs.

## Update classes

| Update class | Scope | Need-update signal | Final proof source |
| --- | --- | --- | --- |
| Windows LCU / SSU | Main OS image | Source image build/UBR is below latest approved LCU build, or selected package is not present | `DISM /Image:<mount> /Get-Packages` package identity such as `Package_for_RollupFix...`, plus offline registry build/UBR where relevant |
| .NET CU | Main OS image | Latest/selected .NET package metadata differs from active package cache, or package cannot be proven in the image | `DISM /Image:<mount> /Get-Packages` package identities matching .NET/NDP/DotNet package hints |
| Safe OS Dynamic Update | WinRE/SafeOS, not the main OS | Latest/selected SafeOS package exists and must be applied to `Windows\System32\Recovery\winre.wim` | Mount final `winre.wim`, then verify `DISM /Image:<winreMount> /Get-Packages` contains the exact SafeOS package identity/name + version hints |
| Microsoft Defender offline kit | Main OS filesystem staging | Defender offline update is enabled and the latest kit metadata differs, or staged files/XML cannot be proven | Mounted final image filesystem: Defender `package-defender.xml`, definition update files, platform directory, signature/engine/platform versions |

## SafeOS/WinRE is special

SafeOS is **not** proven by the main image `UBR`, `ServicePackBuild`, or LCU package state. Those values describe the main OS image. SafeOS proof must come from the nested recovery image:

1. Mount final WIM/SWM output.
2. Locate `Windows\System32\Recovery\winre.wim` inside the mounted main image.
3. Mount that `winre.wim` separately.
4. Read WinRE package identities with DISM.
5. Match the selected SafeOS package using extracted identity hints, for example:
   - name: `Package_for_SafeOSDU`
   - version: `26100.8309.1.7`

If SafeOS was selected and `winre.wim` is missing or the SafeOS package identity cannot be matched, that is a release blocker for production output.

## Defender is also special

The Microsoft Defender offline update kit is not a normal `DISM /Add-Package` package. BuildWIM stages the kit contents into the mounted image using Microsoft's offline layout. Because of that, Defender cannot be proven by `/Get-Packages`.

Proof must use mounted filesystem evidence:

- `Windows\Temp\package-defender.xml` or staged Defender update XML.
- Defender definition update payload under `ProgramData\Microsoft\Windows Defender\Definition Updates\Updates`.
- Platform payload under `ProgramData\Microsoft\Windows Defender\Platform`.
- Signature, engine, and platform versions parsed from `package-defender.xml`.

## What “needs update” means

An image needs servicing when any selected/required update class is newer than, different from, or not provable in the source/final image:

- **LCU/SSU:** source build revision is lower than latest approved LCU revision, or expected package identity is absent.
- **.NET:** selected/latest .NET CU package cannot be matched in the main image package identities.
- **SafeOS/WinRE:** selected/latest SafeOSDU cannot be matched inside mounted final `winre.wim`.
- **Defender:** enabled Defender offline kit metadata/files cannot be matched in the mounted final image.

The LCU delta check can skip a rebuild only when the OS image is already current **and** no selected .NET or SafeOS package requires rebuild. Defender-enabled production runs still need final Defender proof if Defender staging is part of the selected build policy.

## Practical verification command

For an existing final artifact, run the standalone verifier on the Windows build host:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWimV2\Test-BuildWimPatchState.ps1 `
  -OutputDir C:\BuildWimV2\Output\2026-05-02 `
  -UpdatesDir C:\BuildWimV2\Updates `
  -DefenderDir C:\BuildWimV2\Defender `
  -FailIfMissing
```

Expected production result:

```text
BUILDWIM_PATCH_STATE=OK
```

The JSON report path printed as `REPORT_JSON=...` is the audit evidence. It should include main image package checks, WinRE package checks, Defender metadata, hashes, and timestamps.
