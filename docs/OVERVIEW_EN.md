# BuildWIM v2 - Overview

```text
  Source image      Pro-only WIM      Serviced WIM      USB-ready media
 ISO/WIM/ESD  -->  export index  -->  inject KBs  -->  WIM + split SWM
```

BuildWIM v2 is a repeatable Windows 11 offline servicing workflow built around the Windows inbox `DISM.exe`.

The pipeline is intentionally conservative: it selects Windows 11 Pro, services only that single-index working WIM, records what happened, and emits artifacts that are easy to copy to deployment media.

## End-to-end flow

```text
+-------------------+
| Input discovery   |  C:\BuildWIM\Input\*.iso/*.wim/*.esd
+---------+---------+
          |
          v
+-------------------+
| ISO/ESD handling  |  mount ISO or convert ESD when needed
+---------+---------+
          |
          v
+-------------------+
| Pro-only export   |  hard gate: Windows 11 Pro only
+---------+---------+
          |
          v
+-------------------+
| Package planning  |  SSU -> LCU -> .NET -> setup/security -> other
+---------+---------+
          |
          v
+-------------------+
| Offline servicing |  DISM /Mount-Wim + /Add-Package + cleanup
+---------+---------+
          |
          v
+-------------------+
| Finalize output   |  commit, export, split, hash, report
+-------------------+
```

## Inputs

Supported source media:

- Windows 11 ISO.
- `install.wim`.
- `install.esd`.

Rules:

- Put exactly one source image in `C:\BuildWIM\Input\`.
- Put optional `*.msu` or `*.cab` updates in `C:\BuildWIM\Updates\`.
- Run `-DryRun` after changing source media, update packages, or config.

## Outputs

```text
C:\BuildWIM\Output\<yyyy-MM-dd>\install.wim
C:\BuildWIM\Output\<yyyy-MM-dd>\install.swm
C:\BuildWIM\Output\<yyyy-MM-dd>\install2.swm
C:\BuildWIM\Reports\BuildWIM-<timestamp>.html
C:\BuildWIM\Reports\BuildWIM-<timestamp>.md
C:\BuildWIM\Reports\BuildWIM-<timestamp>.diff.md
C:\BuildWIM\Logs\BuildWIM-<timestamp>.log
C:\BuildWIM\Logs\BuildWIM-<timestamp>.transcript.txt
```

## Why Pro-only first

Windows install images often contain multiple editions. Servicing every index is slower, larger, and easier to get wrong.

BuildWIM v2 exports the Windows 11 Pro index before servicing. That gives:

- one target edition,
- smaller working set,
- clearer reports,
- less chance of silently patching the wrong index.

## ADK / WinPE

Windows ADK and the WinPE add-on are not required for offline WIM servicing. BuildWIM v2 uses the Windows 11 built-in `DISM.exe`.

Use ADK/WinPE only when your broader deployment workflow needs boot media or Windows Setup tooling.
