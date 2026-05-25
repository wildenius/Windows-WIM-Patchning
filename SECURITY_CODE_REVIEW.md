# SECURITY_CODE_REVIEW — Windows-WIM-Patchning / BuildWIM

**Datum:** 2026-05-23  
**Scope:** `Build-WIM.ps1`, `Install-BuildWIM.ps1`, `Get-LatestWindows11LCU.ps1`, `Get-Windows11Iso.ps1`, `Resolve-BuildWimMicrosoftEsd.ps1`, `Test-BuildWimPatchState.ps1`, `Config/buildwim.config.json`, README och runbooks.  
**Målmiljö:** IT-säkerhetsbolag som avser använda framställda Windows-klientartefakter brett på klienter.  
**Metod:** Statisk kodgranskning med `find`, `grep -RInE`, `nl -ba`, `sed`, `git status`, `git ls-files`. `rg` saknas i miljön. PowerShell finns inte tillgängligt i granskningsmiljön (`pwsh`, `powershell`, `powershell.exe` hittades inte), så PowerShell parse/syntax check kunde inte köras här.

## Executive verdict

**Slutsats: NO-GO för bred klientutrullning i ett IT-säkerhetsbolag tills releaseblockers nedan är åtgärdade.**

Lösningen är ambitiös och har flera bra byggstenar: DISM-wrapper, isolerade mount-kataloger, Pro-only export, SafeOS/WinRE-injektion, Authenticode-kontroll av uppdateringspaket, hashning av in- och utdata, rapporter, manifest och separat efterkontrollscript. Den är rimlig för labb/pilot med kontrollerad operatör.

För en säkerhetsorganisation som ska basera klienter på dessa artefakter är nuvarande kontrollnivå däremot inte tillräcklig. De största riskerna är:

1. **Basmedia är inte policygodkänt/pinnat.** Lokal ISO/WIM/ESD accepteras efter filnamn/edition och hash registreras, men jämförs inte mot en godkänd Microsoft- eller intern allowlist.
2. **Releasekedjan är inte signerad eller reproducerbart attesterad.** Scripts körs uttryckligen med `ExecutionPolicy Bypass`; manifest innehåller kort git commit men ingen signerad tagg, script-hash-policy eller dirty-tree-blockering.
3. **Valda säkerhetspaket kan hoppas över som “benign” och ändå endast bli warnings.** Final verifiering körs mot injicerade paket, inte alla valda/krävda paket. I produktion måste detta vara releaseblocker.
4. **Supply-chain-kontrollerna är breda och heuristiska.** Microsoft Update Catalog skrapas via HTML/regex, ESD-kataloger litar på kataloginnehåll och ibland SHA1, ISO saknar publicerad checksum-verifiering, URL-allowlists är breda och redirect-/slut-URL-validering är inkonsekvent.
5. **Drift-/releaseprocessen saknar hårda gates:** VM boot-test, first-boot Defender/WinRE/Windows Update-kontroll, signerade artefakter, rollback-policy och fail-on-warning saknas som tvingande mekanism.

Praktiskt kopplat till NIS2/NIS, CIS Controls och ISO 27001/27002: detta är främst brister i **supply-chain-säkerhet, ändringsstyrning, säker konfiguration, sårbarhetshantering, logg-/evidensintegritet och release governance**. Det går att göra lösningen produktionsduglig, men inte genom dokumentation ensam — kontrollerna behöver bli tekniskt tvingande.

## Positiva observationer

- Admin-krav och DISM-prereq finns (`Build-WIM.ps1:1376-1387`, `Install-BuildWIM.ps1:99-101`).
- Hanterade borttagningar skyddas mot uppenbart fel root via `Assert-BuildWimManagedPath` (`Build-WIM.ps1:662-703`).
- Updatepaket Authenticode-verifieras innan DISM `/Add-Package` (`Build-WIM.ps1:763-784`, `Build-WIM.ps1:2143-2146`).
- SafeOS injiceras i `winre.wim` och saknad WinRE är releaseblocker när SafeOS valts (`Build-WIM.ps1:4444-4478`).
- Final verifiering mountar både final WIM och WinRE och kontrollerar paketidentiteter (`Build-WIM.ps1:5013-5049`, `Build-WIM.ps1:2579-2700`).
- Manifest/SHA256SUMS skapas (`Build-WIM.ps1:2703-2715`, `Build-WIM.ps1:2742-2794`, `Build-WIM.ps1:5093-5110`).
- Separat efterkontrollscript finns (`Test-BuildWimPatchState.ps1:299-339`, `Test-BuildWimPatchState.ps1:369-385`).

---

# Critical findings

## CRITICAL-01 — Basmedia saknar tvingande godkänd provenance/allowlist

**Risk:** En manipulerad eller felaktig ISO/WIM/ESD i `Input` kan patchas, rapporteras och distribueras. Hash beräknas, men används som evidens i efterhand — inte som grind före build. Updatepaketens Authenticode skyddar inte bas-OS.

**Evidence:**

- Lokal media väljs automatiskt om exakt en ISO/WIM/ESD finns (`Build-WIM.ps1:1400-1452`).
- Om lokal media finns väljs den före Microsoft-provider (`Build-WIM.ps1:1537-1542`).
- Input-SHA256 sparas men jämförs inte mot en godkänd lista (`Build-WIM.ps1:4682-4683`, `Build-WIM.ps1:2749-2775`).
- `Get-Windows11Iso.ps1` accepterar befintlig ISO utifrån namn/tokenmatchning (`Win11`, `x64`, språk) och skippar Microsoft-kontroller (`Get-Windows11Iso.ps1:486-511`, `Get-Windows11Iso.ps1:547-585`).
- ISO-download beräknar SHA256 men verifierar inte mot publicerad Microsoft-checksumma eller intern baseline (`Get-Windows11Iso.ps1:733-742`).

**Praktisk fix:**

- Inför `Config/approved-sources.json` med `sha256`, release, språk, arkitektur, edition, build, källa och godkännare.
- Lägg till `-ProductionRelease` som kräver match mot allowlist före all servicing.
- Blockera lokal ISO/WIM/ESD utan allowlist-match. Tillåt endast temporärt via explicit `-AllowUnapprovedSource` som sätter non-production verdict.
- Spara både ursprunglig källa och verifierad allowlist-post i manifestet.

**Release blocker:** Ja.

## CRITICAL-02 — Build-/releasekedjan är inte signerad, pinnad eller attesterad

**Risk:** En lokal ändring i scripts, config eller helper scripts kan påverka en image för alla klienter. Det räcker med en komprometterad buildhost eller en oavsiktlig lokal ändring. `ExecutionPolicy Bypass` används återkommande, vilket är rimligt i labb men fel default för en säkerhetsstyrd releasekedja utan kompensationskontroller.

**Evidence:**

- Rekommenderade kommandon använder `Set-ExecutionPolicy Bypass` och `powershell -ExecutionPolicy Bypass` (`README.md:28-35`, `README.md:56-64`, `docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md:163-187`).
- BuildWIM startar helper scripts med `-ExecutionPolicy Bypass` (`Build-WIM.ps1:1473-1483`, `Build-WIM.ps1:1519-1528`, `Build-WIM.ps1:3498-3506`, `Build-WIM.ps1:3582-3591`, `Build-WIM.ps1:5322-5326`).
- Manifestet registrerar bara script path och kort git commit (`Build-WIM.ps1:2764-2768`). Ingen signerad tagg, script SHA256-policy, clean-tree-check eller Authenticode-kontroll av egna scripts finns.
- Installeraren kopierar payload från `SourceDir` utan signatur-/hashvalidering (`Install-BuildWIM.ps1:120-141`).

**Praktisk fix:**

- Signera alla `.ps1` med intern code-signing-cert och kör production med `AllSigned` eller WDAC/App Control-policy.
- `-ProductionRelease` ska kräva clean git tree, signerad release tagg, kända script-hashar och signerad config.
- Manifest ska inkludera SHA256 för varje script/config som användes, signerad release tagg, signer/cert thumbprint och repo-status.
- Avråd från `ExecutionPolicy Bypass` i produktionsrunbooks; om det används i engångsbootstrap måste det vara tidsbegränsat och kompenseras av signaturkontroll.

**Release blocker:** Ja.

## CRITICAL-03 — Valda säkerhetspaket kan hoppas över som “benign” utan hård releaseblockering

**Risk:** Om ett valt LCU/.NET-/hotfixpaket inte appliceras på grund av fel arkitektur, version, edition eller metadatafel kan det klassas som benign, hamna i warnings/skipped och inte ingå i final verifiering. För en bred klientrelease är “säkerhetspaket ej applicerat men build fortsätter” inte acceptabelt.

**Evidence:**

- `not applicable`, `already installed`, `superseded`, `parent package` m.m. returnerar benign (`Build-WIM.ps1:810-838`).
- Vid benign fel läggs paketet i `Skipped` och loopen fortsätter (`Build-WIM.ps1:2155-2170`).
- Final verifiering anropas med `InjectedPackages`, inte alla valda/krävda paket (`Build-WIM.ps1:5039`).
- `Get-BuildVerdict` returnerar `SUCCESS WITH WARNINGS` när warnings finns, inte failure (`Build-WIM.ps1:2827-2832`).
- Runbookens checklista accepterar “SUCCESS or understood SUCCESS WITH WARNINGS” (`docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md:645-655`).

**Praktisk fix:**

- I `-ProductionRelease`: alla valda rekommenderade uppdateringar ska vara `Applied` eller explicit `NotRequired` med maskinläsbar orsak.
- Skipped selected package ska vara releaseblocker som default.
- Final verifiering ska inkludera `selectedPackages`, `downloadedPackages`, `injectedPackages`, `skippedPackages` och ge fail om valt paket saknar bevis.
- Ersätt generell benign-logik med typ-/målstyrd policy: “already installed” kan vara OK bara om final image bevisar motsvarande build/paket; “not applicable” är blocker om paketet var valt för aktuell målplattform.

**Release blocker:** Ja.

## CRITICAL-04 — Ingen tvingande produktionsgate med boot/first-boot-validering och signerad artefaktrelease

**Risk:** Offline DISM-success garanterar inte att klienter bootar korrekt, att Defender konsumerar offlineuppdateringen, att WinRE fungerar, att Windows Update fungerar eller att Intune/Autopilot/baselines fungerar. För ett säkerhetsbolag blir detta en change-management- och incidentrisk.

**Evidence:**

- Pipeline avslutas med rapporter, hashes och cleanup; ingen tvingande VM boot-stage finns (`Build-WIM.ps1:4977-5155`, `Build-WIM.ps1:5161-5298`).
- Dokumentation nämner efterkontroller men de är operatörschecklistor, inte tekniska gates (`docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md:202-212`, `docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md:640-655`).
- `SHA256SUMS.txt` och manifest skapas men signeras inte (`Build-WIM.ps1:2703-2715`, `Build-WIM.ps1:5100-5110`).

**Praktisk fix:**

- Produktionsrelease ska skapa en release bundle: WIM/SWM + manifest + rapporter + `SHA256SUMS` + VM validation JSON, signerad med intern cert/GPG/SignTool.
- Lägg till obligatorisk VM smoke test: boot, build/UBR, `reagentc /info`, WinRE status, Defender `Get-MpComputerStatus`, Windows Update scan, eventlog setup/CBS/Defender, BitLocker/TPM/Secure Boot-readiness och MDM/Intune om relevant.
- Release ska faila om VM validation saknas eller inte är signerad.

**Release blocker:** Ja.

---

# High findings

## HIGH-01 — Microsoft Update Catalog-flödet är HTML/regex-baserat och trustpolicyn är för bred

**Risk:** Microsoft Catalog ändrar HTML, flera liknande paket finns, regex matchar fel URL, eller fel Microsoft-signerat paket väljs. En giltig Microsoft-signatur betyder inte att paketet är rätt paket för vald release.

**Evidence:**

- Catalog-search skrapas som HTML med regex på `<tr>` och celler (`Get-LatestWindows11LCU.ps1:180-233`).
- Paket väljs med titelregex för Windows-version/arkitektur/Preview (`Get-LatestWindows11LCU.ps1:236-277`).
- DownloadDialog skrapas med regex för `.msu`/`.cab` URL (`Get-LatestWindows11LCU.ps1:280-335`).
- Allowlist accepterar breda suffix som `microsoft.com`, `go.microsoft.com`, `delivery.mp.microsoft.com`, `windowsupdate.com` (`Get-LatestWindows11LCU.ps1:47-71`, `Build-WIM.ps1:736-760`).
- Signaturkontroll kräver bara `Status=Valid` och att subject eller issuer innehåller “Microsoft” (`Get-LatestWindows11LCU.ps1:73-87`, `Build-WIM.ps1:763-784`).

**Praktisk fix:**

- Efter download: kontrollera KB, produkt, arkitektur, package identity, expected build/revision och filstorlek mot metadata.
- Logga och verifiera final redirected URL; revalidera slut-URL mot allowlist.
- Begränsa allowlist per pakettyp och undvik generellt `*.microsoft.com` där möjligt.
- Validera Authenticode-kedja mer strikt: EKU/code signing, timestamp, revocation där möjligt, och cert chain mot Microsoft root/intermediate-policy.
- Lås metadata i signed release manifest.

## HIGH-02 — ESD-katalogkedjan litar på katalogdata utan separat katalogsignatur-/baselinekontroll

**Risk:** ESD-flödet är bättre än ISO-flödet eftersom det har kataloghashar, men katalogerna själva hämtas dynamiskt och verifieras inte mot signerad Microsoft-catalog/baseline. Dessutom accepteras SHA1 när SHA256 saknas och HTTP för vissa delivery-hosts.

**Evidence:**

- 25H2-katalog hämtas dynamiskt från metadata service (`Resolve-BuildWimMicrosoftEsd.ps1:74-96`).
- 23H2/24H2-katalog-CAB laddas från fasta URL:er men utan hash/signaturkontroll av CAB/XML (`Resolve-BuildWimMicrosoftEsd.ps1:99-132`).
- `http://dl.delivery.mp.microsoft.com/...` tillåts för ESD FilePath om host matchar delivery-host (`Resolve-BuildWimMicrosoftEsd.ps1:42-48`).
- ESD verifieras med SHA256 om finns, annars SHA1 (`Resolve-BuildWimMicrosoftEsd.ps1:214-224`).
- Vald ESD blir första entry efter sortering (`Resolve-BuildWimMicrosoftEsd.ps1:203-211`, `Resolve-BuildWimMicrosoftEsd.ps1:310-322`).

**Praktisk fix:**

- Kräv SHA256 för ESD i production; SHA1 får endast vara legacy/pilot med explicit override.
- Verifiera katalog-CAB/XML med Microsoft-signatur eller intern signerad katalogbaseline.
- Tillåt inte HTTP i production även för Microsoft delivery; om Microsoft kräver HTTP måste stark SHA256 från signerad katalog krävas och final release markeras med risknotering.
- Spara katalogens hash, källa, fetch time och verifieringsstatus i manifestet.

## HIGH-03 — ISO-flödet saknar stark integritetskontroll och använder icke-stabil web/API-handshake

**Risk:** ISO-download via Microsofts software-download-connector är praktiskt men inte en stark releasekälla utan publicerad checksumma. Befintlig ISO kan dessutom återanvändas utan Microsoft-kontakt.

**Evidence:**

- ISO API/session bygger på web-handshake mot `vlscppe.microsoft.com` och `ov-df.microsoft.com` (`Get-Windows11Iso.ps1:333-365`).
- Tillfälliga länkar cachas och återanvänds om ej utgångna (`Get-Windows11Iso.ps1:514-544`, `Get-Windows11Iso.ps1:678-685`).
- Befintlig ISO skippar Microsoft-kontroller (`Get-Windows11Iso.ps1:547-585`).
- Download kontrollerar URL-host och beräknar SHA256, men jämför inte mot känd godkänd checksumma (`Get-Windows11Iso.ps1:587-615`, `Get-Windows11Iso.ps1:733-742`).

**Praktisk fix:** använd ISO endast som fallback i production och kräv intern allowlist för SHA256/release. Föredra ESD-katalogflöde med signerad katalogbaseline eller staged enterprise media från VLSC/Visual Studio/Volume Licensing med dokumenterad checksumma.

## HIGH-04 — ADK/WinPE-installation från `C:\tmp` saknar signatur-/hashkontroll

**Risk:** Om `-InstallAdk` används kan en lokal tamperad `C:\tmp\adksetup.exe` eller `adkwinpesetup.exe` köras som admin. Det är optional men farligt i en bootstrap för säkerhetsmiljö.

**Evidence:**

- ADK och WinPE hämtas från fasta lokala sökvägar (`Install-BuildWIM.ps1:56-69`).
- Installers körs med `Start-Process` utan Authenticode/hashes (`Install-BuildWIM.ps1:90-96`).

**Praktisk fix:**

- Verifiera Authenticode och förväntad Microsoft signer chain före körning.
- Tillåt endast ADK-versioner/hashes från intern allowlist.
- Dokumentera/offra `-InstallAdk` från standardflödet; kör ADK-installation via separat pakethanterad, signerad endpoint-management-process.

## HIGH-05 — Build root och arbetskataloger saknar ACL-/reparse point-hardening

**Risk:** Scripts körs som admin och skriver/tar bort filer i `C:\BuildWimV2`. Om root eller underkataloger är pre-skapade med fel ACL, junctions/symlinks eller manipuleras av lokal angripare kan builden använda eller radera fel data, eller konsumera manipulerade paket.

**Evidence:**

- Root och underkataloger skapas om de saknas, men ACL kontrolleras/härdas inte (`Build-WIM.ps1:1363-1374`, `Install-BuildWIM.ps1:113-118`).
- Managed delete validerar path-prefix men inte NTFS owner/ACL/reparse points (`Build-WIM.ps1:662-725`).
- Temp- och scratch-kataloger används för expansion och Defender/Package hints (`Build-WIM.ps1:938-963`, `Build-WIM.ps1:2410-2451`).

**Praktisk fix:**

- Preflight: blockera om `Root`, `Input`, `Updates`, `Temp`, `Mount`, `Output`, `Defender` är reparse points eller skrivbara av icke-admin.
- Sätt ACL: Administrators/SYSTEM full control, Users read/execute där lämpligt, ingen write för standard users.
- Kräv dedikerad buildhost eller ephemeral VM.

## HIGH-06 — Defender offline-injektion behöver starkare produktionsbevis

**Risk:** Koden laddar ner Defender kit, verifierar CAB-signatur och kopierar filer till mounted image. Det är praktiskt, men första boot kan fortfarande misslyckas med att konsumera definitions-/platform-filerna. Final verifiering kontrollerar förekomst/signaturversion i offline image, inte runtime health.

**Evidence:**

- Defender-kit URL kan komma från config eller fwlink (`Build-WIM.ps1:2284-2292`, `Build-WIM.ps1:2319-2325`).
- Zip laddas med curl/IWR; den extraherade CAB:en signaturverifieras (`Build-WIM.ps1:2338-2363`).
- Filer kopieras manuellt till Defender-mappar och `package-defender.xml` (`Build-WIM.ps1:2384-2451`).
- Final check tittar på offline-filer och signaturmatch (`Build-WIM.ps1:2237-2282`).

**Praktisk fix:**

- Behåll offline-checken men gör first-boot VM-test obligatoriskt: `Get-MpComputerStatus`, engine/platform/signature version, Defender service health och eventlog.
- Kräv att Defender-kitet är från förväntad URL/final URL och att CAB-hash sparas i signerad manifest.

---

# Medium findings

## MEDIUM-01 — `ResetBase` är default i Newbie/rekommenderat flöde och försvårar rollback

**Evidence:** Config har `CleanupResetBase: true` (`Config/buildwim.config.json:35-40`), Newbie sätter `CleanupResetBase = true` (`Build-WIM.ps1:4412-4416`), cleanup kör `/ResetBase` när satt (`Build-WIM.ps1:2454-2472`). README anger component cleanup + ResetBase som default (`README.md:45-54`).

**Risk/fix:** Bra för storlek men gör rollback av komponenter svårare. Kör pilot utan ResetBase; aktivera ResetBase endast efter VM-/pilotgodkännande.

## MEDIUM-02 — Diskkrav är lågt för robust produktion

**Evidence:** `MinFreeSpaceGB` är 45 GB (`Config/buildwim.config.json:46-49`), och preflight använder samma gräns (`Build-WIM.ps1:1348-1360`, `Build-WIM.ps1:4610-4624`).

**Risk/fix:** LCU/ESD/ISO/SWM och mount/scratch kan kräva betydligt mer. Sätt production minimum 100–150 GB på snabb lokal disk och blockera nätverks-/synkmappar.

## MEDIUM-03 — Rapporter/loggar läcker lokala sökvägar, host/user och temporära URL:er

**Evidence:** Transcript aktiveras (`Build-WIM.ps1:4598-4604`), DISM-kommandon loggas (`Build-WIM.ps1:1659-1664`), manifest innehåller computerName/userName/path (`Build-WIM.ps1:2758-2772`), output docs listar logs/transcripts (`README.md:156-170`, `docs/LOGGING.md:5-13`). ISO metadata kan innehålla temporary URI/session (`Get-Windows11Iso.ps1:631-642`, `Get-Windows11Iso.ps1:741-742`).

**Risk/fix:** Bra för audit men känsligt vid delning. Klassificera rapportpaket som intern konfidentiell information; redigera/partitionera publicerbar rapport; undvik att sprida temporary URLs och host/user.

## MEDIUM-04 — Manifest/SHA256SUMS saknar integritetsskydd

**Evidence:** SHA256SUMS och manifest skrivs lokalt (`Build-WIM.ps1:2703-2715`, `Build-WIM.ps1:5100-5110`), men ingen signering finns.

**Risk/fix:** Hashar skyddar inte om angripare kan ändra både artefakt och hashfil. Signera manifest och checksums med intern releasecertifikat och lagra immutabelt.

## MEDIUM-05 — Update metadata sidecars/cache är manipulerbara lokala filer

**Evidence:** Sidecar JSON läses för klassning och rapportmetadata (`Build-WIM.ps1:2004-2019`, `Build-WIM.ps1:2511-2533`); catalog-cache används för latest metadata (`Build-WIM.ps1:3570-3608`, `Get-LatestWindows11LCU.ps1:438-445`).

**Risk/fix:** Authenticode på MSU/CAB fångar mycket, men sidecar kan påverka klassning/urval/verifieringsförväntningar. I production: sidecar ska vara genererad i samma run eller signerad; verifiera sidecar mot faktisk paketmetadata.

## MEDIUM-06 — Expert/Newbie ändrar säkerhetskritiska val interaktivt utan policygrind

**Evidence:** Expert kan ändra patch plan, cleanup, Defender och output (`Build-WIM.ps1:4234-4290`). Newbie sätter Defender och ResetBase (`Build-WIM.ps1:4377-4416`). Patchplan kan sättas till none/custom (`Build-WIM.ps1:4060-4079`, `Build-WIM.ps1:4268-4270`).

**Risk/fix:** Interaktiv frihet är bra i labb, men production måste styras av policy. `-ProductionRelease` bör ignorera/minimera interaktivitet och kräva policyfil för exakt paketplan.

## MEDIUM-07 — CI/testbarhet saknas i repo

**Evidence:** Inga `.github`, `tests/`, Pester-tester eller CI-workflow hittades med `git ls-files`/`find`. PowerShell syntaxkontroll kunde inte köras i denna miljö.

**Risk/fix:** Lägg till Pester-tester för parser/syntax, URL allowlist, package classification, manifest schema, production-gates och mockade downloadflöden. Kör PSScriptAnalyzer och parse check i CI.

## MEDIUM-08 — Output overwrite/idempotens behöver tydligare release-semantik

**Evidence:** Output hamnar i datumkatalog (`Build-WIM.ps1:4592-4597`), final WIM path är fast `install.wim` i datumkatalog (`Build-WIM.ps1:4981-4983`), befintlig WIM tas bort vid export (`Build-WIM.ps1:2796-2809`). SWM-only tar bort intermediate WIM (`Build-WIM.ps1:5052-5056`).

**Risk/fix:** Flera runs samma dag kan skriva över releaseartefakter. Lägg timestamp/build-id i outputkatalog eller blockera overwrite i production; behåll immutable release bundles.

---

# Low findings

## LOW-01 — Språk/licens-default kan ge fel standardimage om organisationen inte uttryckligen godkänt den

**Evidence:** Defaults är `English International`, `Retail`, `25H2`, `x64` (`Build-WIM.ps1:47-52`, `Resolve-BuildWimMicrosoftEsd.ps1:12-19`, `Get-Windows11Iso.ps1:28-34`).

**Fix:** Flytta till policyfil och kräv explicit production approval för språk/licens/edition.

## LOW-02 — `NotifyOnComplete` använder lokal toast; ingen central release-notifiering

**Evidence:** Notifiering är BurntToast/NotifyIcon fallback (`Build-WIM.ps1:3403-3440`).

**Fix:** För produktion ska release-status skickas till central CI/CD eller ärendehantering med signerad artefaktreferens, inte bara lokal toast.

## LOW-03 — Dokumentationen blandar pilot- och produktionsspråk

**Evidence:** README presenterar “One Click Patched WIM” och unattended commands med Bypass (`README.md:26-64`). Runbook har bättre kontroller men accepterar förstådda warnings (`docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md:645-655`).

**Fix:** Dela upp “lab/pilot” och “production release” tydligt. Production docs ska endast visa `-ProductionRelease` och signerad pipeline.

---

# Relevans mot NIS2/NIS, CIS Controls och ISO 27001/27002

Det här bör inte behandlas som compliance-teater; det handlar om praktiska kontroller:

- **NIS2/NIS supply-chain och riskhantering:** kräver styrning av leverantörs-/programvarukedjan. Här behövs godkänd Microsoft-källa, signerad intern release och spårbar ändringskontroll.
- **CIS Controls v8:**
  - Control 2/4: inventory och secure configuration — kräver exakt känd image, edition, språk, build och policy.
  - Control 7: vulnerability management — valda säkerhetsuppdateringar får inte kunna hoppas över som warnings.
  - Control 8: audit log management — loggar finns, men integritet/signering och dataminimering saknas.
  - Control 10: malware defenses — Defender offline injection finns, men runtime-verifiering krävs.
  - Control 16: application software security — CI, signering, kodgranskning och release gates saknas.
- **ISO 27001/27002-liknande kontroller:**
  - Change management/configuration management: signerad release, clean tree, approval och immutable artefakter.
  - Cryptographic controls: signerade manifests/checksums, signerade scripts.
  - Logging/monitoring: audit trail med integritetsskydd.
  - Secure system engineering: testade, automatiserade gates före produktion.

---

# Quick wins

1. Inför `-ProductionRelease` som:
   - failar på alla warnings/skips,
   - kräver approved source hash,
   - kräver clean/signed git release,
   - kräver signerad config,
   - kräver successful `Test-BuildWimPatchState.ps1 -FailIfMissing`.
2. Lägg `Config/approved-sources.json` och `Config/approved-updates-policy.json`.
3. Sätt production diskkrav till minst 100 GB, helst 150 GB.
4. Signera `SHA256SUMS.txt`, `build-manifest.json` och metadata JSON.
5. Blockera preflight om BuildWIM-root är reparse point eller skrivbar av icke-admin.
6. Dokumentera att `ExecutionPolicy Bypass` endast är bootstrap/labb, inte production.
7. Lägg Pester/PSScriptAnalyzer CI med parse check för alla `.ps1`.
8. Ändra outputkatalog till `Output/<yyyy-MM-dd>/<timestamp-or-build-id>/` i production.

# Release blockers före bred klientutrullning

- [ ] Approved source allowlist enforced for ISO/WIM/ESD.
- [ ] Scripts/config signerade och verifierade före körning.
- [ ] Production mode failar på warnings, skipped selected packages och verifieringsgap.
- [ ] Update/ESD/ISO supply-chain policy skärpt: final URL, SHA256, signer chain, katalogbaseline.
- [ ] ADK/WinPE installer signatur/hashes verifieras eller hanteras separat.
- [ ] Build root ACL/reparse point hardening finns.
- [ ] Signerad release bundle skapas och arkiveras immutabelt.
- [ ] VM boot/first-boot validation är obligatorisk och signerad.
- [ ] CI/Pester/PSScriptAnalyzer parse/syntax gate finns.
- [ ] Runbooks separerar labb från produktion och tar bort “SUCCESS WITH WARNINGS” som produktionsacceptans.

# Final go/no-go recommendation

**NO-GO för bred användning på samtliga klienter just nu.**

**GO för kontrollerad pilot/labb** om:

- buildhosten är dedikerad och isolerad,
- source media är manuellt verifierad och hash sparad,
- alla warnings granskas manuellt,
- output används inte som generell klientbaseline,
- efterkontroll med `Test-BuildWimPatchState.ps1 -FailIfMissing` körs,
- minst en VM boot/first-boot valideras innan någon verklig klient använder imagen.

**GO för produktion** först när releaseblockers ovan är stängda och en signerad release bundle med godkänd VM-validering finns.

# Föreslagna kodändringar, exakt men ej implementerade här

1. `Build-WIM.ps1`
   - Lägg till switchar: `-ProductionRelease`, `-AllowUnapprovedSource`, `-AllowWarnings`, `-AllowDirtyBuild`.
   - Lägg till funktioner:
     - `Test-ApprovedSourceMedia -Path $script:Run.Input.Path -PolicyPath Config\approved-sources.json`.
     - `Test-BuildWimRootSecurity -Root $Root` som kontrollerar ACL, owner och reparse points.
     - `Test-ReleaseProvenance` som kräver clean tree, signerad tagg och script/config SHA256.
     - `Assert-ProductionVerdict` som failar på warnings, skipped selected packages, Defender WARN, verification WARN och saknad efterkontroll.
   - Ändra `Test-PackageFailureIsBenign` så att `not applicable` inte är benign i production för valt paket utan final proof.
   - Ändra final verifiering från endast `InjectedPackages` till en modell med `SelectedPackages`, `DownloadedPackages`, `InjectedPackages`, `SkippedPackages` och `RequiredPackages`.
   - Skriv output i timestampad production-katalog och blockera overwrite.

2. `Get-LatestWindows11LCU.ps1`
   - Spara final redirected URL och Content-Length efter download.
   - Verifiera att faktiskt paket matchar `KB`, arkitektur, produkt, package type och expected build.
   - Skärp `Assert-TrustedMicrosoftFileSignature` med chain/EKU/timestamp/revocation där Windowsmiljön tillåter.
   - Gör URL-allowlist per pakettyp och ta bort generellt `microsoft.com` om möjligt.

3. `Get-Windows11Iso.ps1`
   - Kräv `approved-sources.json` för befintlig ISO i production.
   - Skriv varning/non-production verdict om checksum inte kan verifieras mot godkänd baseline.
   - Undvik återanvändning av cached temporary URL i production utan revalidering.

4. `Resolve-BuildWimMicrosoftEsd.ps1`
   - Kräv SHA256 i production; blockera SHA1-only.
   - Verifiera katalog-CAB/XML mot signerad baseline eller Microsoft-signatur.
   - Blockera HTTP i production om inte stark signerad kataloghash finns.

5. `Install-BuildWIM.ps1`
   - Verifiera ADK/WinPE installers med Authenticode och hashallowlist innan `Start-Process`.
   - Sätt/härda ACL på `C:\BuildWimV2` vid installation.

6. CI/repo
   - Lägg till Pester-tester, PSScriptAnalyzer och PowerShell parser gate.
   - Lägg till signerad release workflow eller motsvarande intern pipeline.

# Verifiering utförd i denna granskning

- Filinventering med `find` och `git ls-files`.
- Statisk grep på säkerhetsrelevanta mönster: download, URL, Authenticode, SHA, DISM, transcripts, Remove-Item, ExecutionPolicy.
- Manuell linjebaserad inspektion av huvudflöden i samtliga relevanta scripts.
- `git status --short` visade bara OpenClaw-arbetsfiler som untracked, inga kodändringar gjordes utöver denna rapport.
- PowerShell parse/syntax check kunde inte köras eftersom PowerShell saknas i granskningsmiljön.

