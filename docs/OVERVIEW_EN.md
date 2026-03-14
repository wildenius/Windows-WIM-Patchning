# Windows WIM Patching (BuildWIM) – Overview (EN)

BuildWIM is a production-oriented, fully automated offline servicing pipeline for Windows 11 installation media.
It takes a Windows 11 **ISO**, **install.wim** or **install.esd**, extracts/converts as needed, keeps **only Windows 11 Pro**, injects offline update packages in a deterministic order, cleans up the image, and produces both a full WIM and a FAT32-friendly split SWM set.

## What it produces

After a successful run, you will get:

- **Full WIM**: `C:\BuildWIM\Output\install.wim`
- **Split SWM (FAT32)**: `C:\BuildWIM\Output\install.swm`, `install2.swm`, ...
- **HTML report**: `C:\BuildWIM\Reports\BuildWIM-<timestamp>.html`
- **Logs**:
  - `C:\BuildWIM\Logs\BuildWIM-<timestamp>.log`
  - `C:\BuildWIM\Logs\BuildWIM-<timestamp>.transcript.txt`

## High-level workflow

1. **Prerequisites & safety checks**
   - Requires Administrator privileges
   - Validates free disk space (configurable)
   - Runs `dism /Cleanup-Wim` to recover from stale mount states

2. **Input discovery** (`C:\BuildWIM\Input\`)
   - Supports:
     - `*.iso`
     - `*.wim` (commonly `install.wim`)
     - `*.esd` (commonly `install.esd`)

3. **ISO handling (if ISO input)**
   - Mounts the ISO
   - Locates `sources\install.wim` or `sources\install.esd`
   - Copies the file into the working area (`C:\BuildWIM\Temp\`)
   - Dismounts the ISO safely

4. **ESD conversion (if ESD input)**
   - Converts ESD to WIM via `DISM /Export-Image`

5. **Edition gating (mandatory)**
   - Reads all indexes from the source image via `DISM /Get-WimInfo`
   - Locates the **Windows 11 Pro** index
   - **Exports a Pro-only working WIM** BEFORE any servicing
   - Aborts if Windows 11 Pro cannot be found

6. **Update package discovery and ordering** (`C:\BuildWIM\Updates\`)
   - Supports `*.cab` and `*.msu`
   - MSU packages are expanded and serviced as CABs when possible
   - Packages are classified and applied in deterministic order:
     1) SSU
     2) LCU
     3) .NET cumulative update
     4) Other
   - The order is written to logs and to the HTML report

7. **Offline servicing**
   - Mounts the Pro-only working WIM
   - Adds packages via `DISM /Add-Package`
   - Runs offline cleanup:
     - `DISM /Cleanup-Image /StartComponentCleanup`

8. **Finalize outputs**
   - Exports final WIM to `Output\install.wim`
   - Splits WIM into SWM parts for FAT32 USB media
   - Computes SHA256 hashes (input + outputs)
   - Generates an HTML summary report (including executed DISM commands)

## Why the “Pro-only export before patching” matters

Windows install images often contain multiple editions. Servicing a multi-index image can cause:
- longer runtimes
- unnecessary bloat
- ambiguous or inconsistent servicing state

BuildWIM enforces a hard gate: **only the Pro index is kept** in a working WIM, and servicing is performed against that single-index working image.

## Determinism and repeatability

BuildWIM aims to be repeatable and automation-friendly:
- deterministic package ordering
- idempotent cleanup of stale mount states
- clear logs + transcript
- HTML report capturing the full run context

## Notes on ADK

BuildWIM primarily uses the OS-provided `DISM.exe` for offline servicing.
Windows ADK + WinPE are expected to exist in the environment (per deployment requirements), and the bootstrap script can install them when installers are available under `C:\tmp\`.

