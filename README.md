# BuildWIM – Offline patchning av Windows 11-installationsimage (WIM/ESD/ISO)

Det här projektet bygger en **produktionsnära, helautomatiserad och återkörbar** pipeline för att:

- Ta en Windows 11 **ISO**, **install.wim** eller **install.esd**
- Identifiera **Windows 11 Pro**-index
- Exportera en **Pro-only working WIM** (obligatoriskt före patchning)
- Injecta offline-uppdateringar (CAB/MSU) i **deterministisk ordning**
- Köra offline cleanup-steg där det är rimligt
- Leverera:
  - `install.wim` (full)
  - `install.swm`, `install2.swm`, ... (FAT32 split)
  - HTML-rapport + loggar + valfri metadata

## Förutsättningar

- Windows 11
- PowerShell 5.1+ eller PowerShell 7
- Kör som **Administrator**
- Tillräckligt med diskutrymme (rekommenderat 40–80+ GB beroende på ISO/patchar)
- Windows ADK + Windows ADK WinPE Add-on:
  - Du lägger installationsfilerna i `C:\tmp\` enligt:
    - `C:\tmp\adksetup.exe`
    - `C:\tmp\adkwinpesetup.exe`
  - Installationsskriptet installerar tyst (om de finns där)

> Obs: Build-WIM.ps1 använder främst **DISM.exe** som motor. ADK Deployment Tools behövs normalt inte för just offline-servicing av WIM, men vi detekterar ADK ändå enligt krav och loggar tydligt.

## Mappstruktur (root = `C:\BuildWIM\`)

Efter installation:

```
C:\BuildWIM\
  Input\
  Updates\
  Mount\
  Output\
  Logs\
  Temp\
  Tools\
  Config\
  Reports\
```

### Vad lägger man var?

- `C:\BuildWIM\Input\`
  - Lägg **EN** av följande:
    - Windows 11 ISO (`*.iso`)
    - `install.wim`
    - `install.esd`
- `C:\BuildWIM\Updates\`
  - Lägg uppdateringar:
    - `*.msu` och/eller `*.cab`
  - Tom mapp är OK (då görs bara Pro-export + output)

## Snabbstart

### 1) Installera/bootstrappa strukturen

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-BuildWIM.ps1
```

### 2) Bygg + patcha image (one-liner)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWIM\Build-WIM.ps1
```

### Vanliga parametrar

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWIM\Build-WIM.ps1 `
  -ConfigPath C:\BuildWIM\Config\buildwim.config.json `
  -SplitSizeMB 3800 `
  -EmitMetadataJson
```

### DryRun / WhatIf

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\BuildWIM\Build-WIM.ps1 -DryRun
```

## Output

- Full WIM:
  - `C:\BuildWIM\Output\install.wim`
- Split SWM:
  - `C:\BuildWIM\Output\install.swm`, `install2.swm`, ...
- Rapporter:
  - `C:\BuildWIM\Reports\BuildWIM-<timestamp>.html`
- Loggar:
  - `C:\BuildWIM\Logs\BuildWIM-<timestamp>.log`
  - Transcript: `C:\BuildWIM\Logs\BuildWIM-<timestamp>.transcript.txt`

## Offline cleanup – vad är rimligt?

- `dism /Image:<mount> /Cleanup-Image /StartComponentCleanup` fungerar offline och används.
- `RestoreHealth` offline mot en WIM kräver en känd reparationskälla (`/Source:`) och är inte alltid meningsfullt i en generell pipeline. I den här lösningen kör vi **inte** `RestoreHealth` som default, men vi loggar detta och lämnar plats för att lägga till en valfri `RepairSource` i config i v2.

## Loggstrategi

- Konsol + loggfil med nivåer: INFO/WARN/ERROR/DEBUG
- `Start-Transcript` för komplett PowerShell-output
- Alla DISM-kommandon loggas (exakta args)
- Felhantering via `try/catch`, exit codes, och avmontering med discard vid fel

## Versionshantering

- Skripten har versionsheader.
- HTML-rapport inkluderar versionsnummer, start/slut och duration.

## Support / felsök

Om en mount blir kvar:

```powershell
dism /Cleanup-Wim
```

Skriptet försöker också rensa stale mounts automatiskt via `Clear-StaleMounts`.
