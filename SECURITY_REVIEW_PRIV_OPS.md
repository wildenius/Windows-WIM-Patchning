# SECURITY REVIEW - Privilege/Ops (Windows-WIM-Patchning)

Datum: 2026-05-23
Scope: `Build-WIM.ps1`, `Install-BuildWIM.ps1` samt relevant cleanup/mount/dismount/temp/output-logik i övriga scripts.

Verifiering utförd: statisk granskning med `grep`/`nl` och riktade läsningar. PowerShell-parser kördes inte eftersom `pwsh`/`powershell` inte fanns i Linux/WSL-miljön. Inga destruktiva scripts kördes.

## Critical

Inga Critical-fynd identifierade i denna privilege/ops-scope.

## High

### H-01 - Installer kör ADK-installers från `C:\tmp` som administratör utan signatur-/hash-/ACL-kontroll

- **Evidence:** `Install-BuildWIM.ps1:61-62` hårdkodar `C:\tmp\adksetup.exe` och `C:\tmp\adkwinpesetup.exe`; `Install-BuildWIM.ps1:91-96` kör dem med `Start-Process` och kontrollerar bara exit code.
- **Risk:** Om `C:\tmp` är skapad eller skrivbar av lågprivilegierad användare kan en angripare placera en trojaniserad exe som körs upphöjt när admin använder `-InstallAdk`. Detta är en klassisk local privilege escalation via osäker installer staging.
- **Practical fix:** Hämta ADK från officiell Microsoft-URL över TLS till en ACL-låst, ny per-run katalog under adminägd root; verifiera Authenticode-signatur, förväntad publisher och helst SHA256/pinned version innan körning. Alternativt kräv explicit parameter till installer-path och verifiera att path inte är reparse point samt att katalogen inte är world-writable.
- **Release blocker:** Ja, för `-InstallAdk`-funktionen. Default-install utan `-InstallAdk` påverkas inte direkt.

### H-02 - Reparse point/junction/symlink-risk i root/path-skydd och cleanup

- **Evidence:** `Build-WIM.ps1:662-671` gör endast textuell `GetFullPath`/prefix-kontroll; `Build-WIM.ps1:715-724` använder därefter `Remove-Item -Recurse -Force`; `Build-WIM.ps1:1367-1373` skapar/återanvänder root-underkataloger utan att avvisa reparse points. Installeraren gör motsvarande katalog-/copy-logik utan reparse/ACL-kontroll i `Install-BuildWIM.ps1:33-53` och `Install-BuildWIM.ps1:117-135`.
- **Risk:** På Windows kan en angripare, eller ett tidigare felaktigt körläge, ersätta en managed katalog/underkatalog med junction/symlink mot t.ex. annan volym eller system-/profilkatalog. Den textuella root-kontrollen ser fortfarande pathen som under `C:\BuildWimV2`, medan `Remove-Item`, `Copy-Item`, DISM output och temp-cleanup kan skriva eller radera utanför avsedd root med adminrättigheter.
- **Practical fix:** Inför en gemensam `Assert-SafeLocalDirectory`/`Resolve-SafePath` som använder `Get-Item -Force` och avvisar `Attributes -band [IO.FileAttributes]::ReparsePoint` på varje path-komponent under root. Skapa root med strikt ACL (Administrators/SYSTEM full, Users read/execute vid behov, inga Users modify). Använd leaf-only-validering för filnamn. För cleanup: ta bort endast objekt vars resolved final path ligger under en icke-reparse root och som skapats av aktuell körning eller manifest.
- **Release blocker:** Ja.

### H-03 - Ingen global körningslåsning; cleanup kan störa parallella BuildWIM/DISM-körningar

- **Evidence:** Preflight kör global DISM cleanup i `Build-WIM.ps1:1304-1308` och unmountar alla mountar under BuildWIM mount-root med `/Discard` i `Build-WIM.ps1:1312-1328`. Vid start körs ytterligare cleanup i `Build-WIM.ps1:4656-4675`. Mount-kataloger namnges med sekundprecision och raderas om de redan finns i `Build-WIM.ps1:1903-1918`. Mount väljs sedan i `Build-WIM.ps1:4883-4903`. `Test-BuildWimPatchState.ps1:382-385` kör också `/Cleanup-Wim` i finally.
- **Risk:** Två samtidiga körningar med samma root kan välja kolliderande kataloger, radera varandras temp/working WIM eller unmounta aktivt mountad image med `/Discard`. Resultatet kan bli korrupt output, förlorad service-state, låsta WIM:ar och svår rollback. Global `/Cleanup-Wim` kan även påverka andra DISM-operationer på samma host.
- **Practical fix:** Skapa ett exklusivt named mutex eller lockfil med `FileShare.None` under root tidigt i startup, innan preflight cleanup. Alla scripts som monterar/kör `/Cleanup-Wim` bör respektera samma lock. Använd GUID-baserade mount/temp-kataloger, inte enbart timestamp. Tracka mounts i ett run-manifest och cleanupa endast egna mount IDs/paths; gör global `/Cleanup-Wim` endast med explicit `-ForceCleanupWim` och varning.
- **Release blocker:** Ja.

### H-04 - Config-styrda output-filnamn saknar leaf/path-traversal-validering

- **Evidence:** Default config har `Output.InstallWimName` och `Output.SplitBaseName` i `Config/buildwim.config.json:29-33`. Dessa används direkt med `Join-Path` i `Build-WIM.ps1:4982-4988`, och DISM skriver till resulterande paths i `Build-WIM.ps1:2796-2809` och `Build-WIM.ps1:2812-2821`.
- **Risk:** Om config kan ändras (felaktiga ACL:er, custom root, pipeline-input) kan värden som innehåller `..`, rotad path, alternate separators eller konstiga device paths styra upphöjda writes/splits utanför avsedd output-katalog. Även om config normalt är adminägd är detta en robusthets- och hardening-brist för privilegierade scripts.
- **Practical fix:** Validera output-namn som rena filnamn: `Split-Path -Leaf` ska vara identiskt med värdet, inga directory separators, inga `..`, inga wildcards, inga ADS (`:`), förväntad extension (`.wim`/`.swm`). Efter `Join-Path`, kontrollera resolved parent under output-root innan DISM körs.
- **Release blocker:** Ja om config inte garanterat är admin-only med strikt ACL; annars Medium före publik release.

## Medium

### M-01 - DISM-wrapper bygger argument som en sträng utan robust quoting/escaping

- **Evidence:** `Build-WIM.ps1:1659-1673` gör `$argLine = ($Arguments -join ' ')` och sätter `ProcessStartInfo.Arguments = $argLine`; path-argument byggs t.ex. i `Build-WIM.ps1:1897-1898`, `Build-WIM.ps1:1932-1933` och `Build-WIM.ps1:2140-2141`.
- **Risk:** Paths med mellanslag eller specialtecken kan tolkas fel av DISM. Det är inte shell injection eftersom `UseShellExecute = false`, men det är en robusthetsrisk som kan ge felaktig mount/package/output och svårdiagnostiserade fail states.
- **Practical fix:** Använd `ProcessStartInfo.ArgumentList.Add()` när tillgängligt, eller quote/escape per argument med en testad helper som hanterar backslash/quote enligt Windows argv-regler. Lägg regressionstester för root/path med mellanslag.
- **Release blocker:** Nej, men bör åtgärdas innan breddad produktion.

### M-02 - DISM stdout/stderr-läsning kan deadlocka vid stor stderr

- **Evidence:** `Build-WIM.ps1:1673-1702` redirectar både stdout och stderr, läser stdout till slut först och läser stderr först efteråt.
- **Risk:** Om DISM skriver mycket stderr medan stdout-läsningen väntar kan stderr-pipen fyllas, child-processen blocka och BuildWIM hänga med mount låst. Detta försämrar incident- och rollback-läget.
- **Practical fix:** Läs stdout och stderr asynkront (`BeginOutputReadLine`/`BeginErrorReadLine`) eller starta två reader-tasks/runspaces innan `WaitForExit`. Inför timeout och on-timeout diagnostics + försök till kontrollerad discard/unmount av egna mounts.
- **Release blocker:** Nej.

### M-03 - Start-Transcript ligger utanför `try/finally`; transcript-fel stoppar körning utan normal cleanup/report

- **Evidence:** `Build-WIM.ps1:4598-4603` sätter log/transcript och kör `Start-Transcript` innan funktions-`try`; `Stop-Transcript` ligger i `finally` vid `Build-WIM.ps1:5296-5298`.
- **Risk:** Om transcript inte kan starta (policy, låst fil, ACL, konstig host) kastas fel innan `try/finally` aktiverats. Då fås sämre felrapport och eventuell tidigare state från outer flow hanteras inte lika tydligt.
- **Practical fix:** Flytta `Start-Transcript` in i `try`, fånga transcript-fel som warning och fortsätt med egen loggfil. Tracka `$transcriptStarted` och stoppa bara om true.
- **Release blocker:** Nej.

### M-04 - Disk-space preflight är för grov och täcker inte peak/andra volymer

- **Evidence:** `Build-WIM.ps1:1348-1360` kontrollerar endast PSDrive för given path; `Build-WIM.ps1:4613-4623` och `Build-WIM.ps1:5318-5319` använder root/min-GB från config. Default `MinFreeSpaceGB` är 45 GB i `Config/buildwim.config.json:41-43`.
- **Risk:** WIM export, ESD konvertering, split, Defender/temp och ISO-download kan kräva mer peak-space än statisk min-nivå. Om root/output/temp råkar ligga på olika volymer eller via junction blir kontrollen missvisande och builden kan fallera sent med mountar kvar.
- **Practical fix:** Beräkna expected peak: input image size + working WIM + final WIM + SWM + scratch + buffer. Kontrollera varje faktisk volym för `Input`, `Updates`, `Temp/Scratch`, `Mount`, `Output/OutputDated` efter reparse-resolving. Logga både required och free per volym.
- **Release blocker:** Nej, men viktigt för driftrobusthet.

### M-05 - Fristående ESD-resolver har svagare managed-path/cleanup-skydd än huvudscriptet

- **Evidence:** `Resolve-BuildWimMicrosoftEsd.ps1:291-294` bygger output/cache paths från användarstyrt `OutputDirectory`; `Resolve-BuildWimMicrosoftEsd.ps1:282-288` tar bort befintlig `install.wim` och skriver ny via DISM utan managed-root/reparse-skydd.
- **Risk:** När scriptet körs fristående som admin kan felaktigt `-OutputDirectory`, junctions eller path-manipulation leda till radering/skrivning utanför avsedd BuildWIM-root. När det körs via huvudscriptet är risken lägre, men skydden är inkonsekventa.
- **Practical fix:** Återanvänd samma säkra path/reparse/ACL-validering som huvudscriptet. Kräv explicit `-AllowExternalOutputDirectory` för paths utanför BuildWIM-root och validera parent-kataloger.
- **Release blocker:** Nej för normal huvudflöde; ja om resolver marknadsförs som fristående adminverktyg.

## Low

### L-01 - Adminkrav finns som runtime-check men inte som deklarativt `#Requires -RunAsAdministrator`

- **Evidence:** `Build-WIM.ps1:1376-1381` och `Install-BuildWIM.ps1:99-100` kontrollerar admin i runtime; `grep` hittade inget `#Requires` i granskade scripts.
- **Risk:** Användaren får senare fail i stället för tidig PowerShell-gating. Automations- och dokumentationsverktyg kan missa att scriptet kräver elevation.
- **Practical fix:** Lägg `#Requires -RunAsAdministrator` högst upp i scripts som kräver elevation, och behåll runtime-checken för tydligt felmeddelande.
- **Release blocker:** Nej.

### L-02 - ExecutionPolicy Bypass används i barnprocesser och dokumentation utan lokal integrity-gate för scriptfilerna

- **Evidence:** `Build-WIM.ps1:325`, `Build-WIM.ps1:434`, `Build-WIM.ps1:1476`, `Build-WIM.ps1:1520`, `Build-WIM.ps1:3499` m.fl. startar barnscripts med `-ExecutionPolicy Bypass`; installeraren skriver motsvarande körkommando i `Install-BuildWIM.ps1:148`.
- **Risk:** Bypass är praktiskt för drift, men i en privileged pipeline bör det kombineras med att installerade scripts/config ligger i ACL-låst katalog och gärna hash/signaturkontrolleras vid installation/uppdatering. Annars kan lokal script-tampering bli upphöjd execution när admin kör BuildWIM.
- **Practical fix:** Vid installation: sätt strikt ACL på root, skriv manifest med SHA256 för scripts/config och verifiera manifest före run. Överväg signering eller AllSigned-dokumenterad driftprofil för reglerade miljöer.
- **Release blocker:** Nej, om ACL-fixen i H-02 införs.

### L-03 - Test-/verifieringsscript använder global `/Cleanup-Wim` och timestamp-temp utan GUID/run-lock

- **Evidence:** `Test-BuildWimPatchState.ps1:270-276` skapar arbetskatalog baserad på timestamp; `Test-BuildWimPatchState.ps1:382-385` unmountar och kör global `/Cleanup-Wim`.
- **Risk:** Parallella verifieringar samma sekund kan kollidera, och global cleanup kan störa annan DISM-aktivitet. Lägre risk än huvudflödet men samma driftmönster.
- **Practical fix:** Lägg GUID i `$work`, använd gemensamt BuildWIM-lås eller explicit `-NoGlobalCleanupWim`, och cleanupa endast egna mountar.
- **Release blocker:** Nej.

## Praktisk relevans mot NIS2, CIS Controls och ISO 27001/27002

- **NIS2:** Fynden berör säker drift, change control och incidentresiliens. Särskilt H-01/H-02 kan ge privileged execution eller otillåten filpåverkan; H-03/M-04 påverkar kontinuitet och återställbarhet.
- **CIS Controls:** Relevans främst CIS Control 2/4/8/10/12/16: säker konfiguration, kontrollerad administrativ behörighet, audit logging, malware-/trusted publisher-kontroller och säker mjukvaruhantering.
- **ISO 27001/27002:** Relevans främst åtkomststyrning, secure configuration, change management, logging/monitoring och skydd mot malware/tampering. Praktiskt bör BuildWIM-root betraktas som en privileged build asset med strikt ACL, manifest och kontrollerad körningslåsning.

## Kort verdict för privilege/ops

Privilege/ops-designen är funktionellt nära produktionsbar: admin-check, Microsoft-signaturkontroll av update packages, DISM exit-code-hantering, offline-verifiering och grundläggande disk/logging finns. Däremot är release-hardening inte klar. De viktigaste blockers är osäker ADK-staging från `C:\tmp`, avsaknad av reparse point/ACL-skydd för admin-writes/deletes, ingen concurrent-run lockning och path-traversal-risk i config-styrda outputnamn. Åtgärda H-01 till H-04 innan produktion i reglerad/NIS2-nära miljö.