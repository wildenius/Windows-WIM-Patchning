# Security Review: Enterprise rollout, rapportering, loggning/privacy, governance och compliance-readiness

Datum: 2026-05-23  
Scope: `Build-WIM.ps1` rapport/manifest/logg/transcript, README/docs/config/install-flöde och test-/evidensdokumentation. Ingen destruktiv körning gjordes.

## Executive summary

**Enterprise go/no-go:** **NO-GO för bred enterprise rollout som produktionskedja eller klientnära verktyg i ett IT-säkerhetsbolag.**  
Lösningen är stark för labb/pilot och kontrollerad image-factory med kunnig operatör: den har Microsoft URL-allowlisting, Authenticode-kontroll av updatepaket, SHA256 på outputs, manifest, HTML/Markdown-rapporter, transcript/logg och final mounted-image verification. Men den saknar flera release-kedje- och governance-kontroller som behövs innan den kan betraktas som compliance-ready: signerade egna scripts, policy-gated source media, immutable/tamper-evident audit packet, sekretess-/retentionspolicy för loggar, robust ACL/reparse hardening, versionspinning, CI gates och App Control/CLM-rekommendationer.

**Kort bedömning:**

- **OK för:** kontrollerad pilot på dedikerad buildhost, manuellt godkänd input, separat artifact store, och kompensationskontroller.
- **Inte OK för:** bred körning på klienter, decentraliserad admin-körning, eller användning som ensam beviskedja för OS-image compliance.
- **Minsta release blockers:** Critical/High findings C-01, H-01, H-02 och H-03 måste åtgärdas eller kompenseras skriftligt innan enterprise rollout.

## Styrkor som bör behållas

- Updatepaket verifieras med Authenticode före DISM-injektion (`Build-WIM.ps1:763-784`, `Build-WIM.ps1:2143-2146`).
- Output får SHA256SUMS och build manifest (`Build-WIM.ps1:2703-2715`, `Build-WIM.ps1:5100-5110`).
- Rapportering täcker steg, paket, DISM-kommandon, output-hashar och final verification (`Build-WIM.ps1:2901-3159`, `Build-WIM.ps1:3166-3296`).
- Final artifact verification monterar final WIM och WinRE samt jämför paket/Defender-state (`Build-WIM.ps1:5014-5047`).
- Separat verifieringsscript finns för final SWM/WIM och bevis-JSON (`Test-BuildWimPatchState.ps1:281-369`, `docs/VALIDATED_BUILDS.md:5-43`).

---

## Findings — Critical

### C-01 — Releasekedjan är inte signerad eller policy-enforced; dokumentation och helper-körningar använder `ExecutionPolicy Bypass`

**Evidence:**

- Alla versionerade `.ps1` saknar Authenticode signature block enligt lokal grep: `Build-WIM.ps1`, `Install-BuildWIM.ps1`, `Get-LatestWindows11LCU.ps1`, `Get-Windows11Iso.ps1`, `Resolve-BuildWimMicrosoftEsd.ps1`, `Get-BuildWimIsoCooldownStats.ps1`, `Test-BuildWimPatchState.ps1`.
- README bootstrap instruerar `Set-ExecutionPolicy ... Bypass` och `powershell ... -ExecutionPolicy Bypass` (`README.md:28-35`, även unattended exempel `README.md:56-75`).
- `Build-WIM.ps1` startar egna helper-scripts med Bypass (`Build-WIM.ps1:1473-1483`, `Build-WIM.ps1:1519-1528`, `Build-WIM.ps1:5322-5326`).
- Manifestet registrerar scriptversion/path/git commit men inte script-hashar, signerad tagg, clean tree eller policy-resultat (`Build-WIM.ps1:2764-2768`).

**Risk:** En manipulerad helper, lokal scriptändring eller komprometterad buildhost kan påverka en image som sedan distribueras brett. Hashar på slutartefakter bevisar då bara den komprometterade outputen. `ExecutionPolicy Bypass` är inte i sig ett säkerhetskontrollbrott i labb, men är fel produktionsdefault utan egen signatur-/integritetsgate.

**Practical fix:**

1. Signera alla `.ps1` med intern code-signing cert + timestamp.
2. Produktionsrunbooks ska använda `AllSigned`/`RemoteSigned` utan Bypass, eller en WDAC/App Control-policy som endast tillåter signerad BuildWIM-release.
3. Vid start: verifiera egna script- och config-hashar mot signerad release manifest; fail closed på dirty tree, okänd commit eller ändrad payload.
4. Manifestet ska inkludera release-id, signerad git tagg, script SHA256, config SHA256 och signeringsstatus.

**Release blocker:** **Ja**.

---

## Findings — High

### H-01 — Source media och update policy är inte enterprise-gated eller reproducerbart pinnad

**Evidence:**

- Local input väljs om exakt en ISO/WIM/ESD finns; ingen approved-hash allowlist eller signerad source-baseline krävs (`Build-WIM.ps1:1435-1452`, `Build-WIM.ps1:1537-1542`).
- `-RequireLocalMedia` finns men kräver bara lokal närvaro, inte att mediat är godkänt (`Build-WIM.ps1:1544-1549`, docs rekommenderar lokalt läge vid policykrav `docs/ONE_CLICK_PATCHED_WIM.md:106-115`).
- ISO-flödet sparar SHA256 efter download/användning, men jämför inte mot Microsoft publicerad hash eller enterprise allowlist (`Get-Windows11Iso.ps1:733-742`).
- ESD-flödet har bättre hashkontroll via katalog (`Resolve-BuildWimMicrosoftEsd.ps1:214-225`, `Resolve-BuildWimMicrosoftEsd.ps1:320-334`), men default AutoFallback kan fortfarande använda lokalt media först (`README.md:90-97`).
- Updateval är “latest” från Microsoft Catalog, inte en release-pinnad baseline (`Get-LatestWindows11LCU.ps1:383-390`, `Get-LatestWindows11LCU.ps1:410-445`).

**Risk:** En felaktig, manipulerad eller ännu inte godkänd Windows-baseline kan bli patchad och få legitima rapporter/hashar. Auto-latest updates kan skapa icke-reproducerbara builds mellan dagar/timmar och försvåra change approval, rollback och incidentutredning.

**Practical fix:**

1. Inför `ApprovedMedia`/`ApprovedUpdates` i config: filnamn, SHA256, Windows version/build, språk, edition, KB, UpdateId, signer/advisory och change ticket.
2. Production mode ska faila om source media eller updatepaket inte matchar godkänd baseline.
3. Skilj `LatestDiscovery` från `ApprovedRelease`: discovery kan föreslå, men bara approved manifest får bygga.
4. Skriv godkänd baseline-id och change ticket i manifest/rapport.

**Release blocker:** **Ja**.

### H-02 — Audit packet är inte tamper-evident eller immutable; outputs kan skrivas över per datum

**Evidence:**

- Output-katalog baseras på datum, inte unik release/build-id (`Build-WIM.ps1:4592-4596`).
- Existing final WIM tas bort vid ny export (`Build-WIM.ps1:2802-2805`).
- SWM-filer samlas från `install*.swm` i dagens outputfolder (`Build-WIM.ps1:5071-5079`); `SHA256SUMS.txt` hashar alla filer i katalogen (`Build-WIM.ps1:2707-2715`).
- Manifest och SHA256SUMS skrivs lokalt men signeras inte (`Build-WIM.ps1:5100-5110`).
- Runbook säger “keep reports/metadata/SHA256SUMS together as audit packet”, men beskriver inte immutable retention, signerad publicering eller append-only lagring (`docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md:72-78`, `docs/BUILDWIM_V2_PRODUCTION_RUNBOOK.md:503-532`).

**Risk:** Flera körningar samma dag kan ersätta eller blanda artefakter. SHA256 ger integritet först efter att man litar på filen som innehåller hasharna; utan signatur/append-only store kan både artifact och bevis ändras. Detta räcker inte för enterprise audit trail eller forensisk kedja.

**Practical fix:**

1. Skriv till `Output/<yyyy-MM-dd>/<timestamp-or-release-id>/` och faila om katalogen finns, om inte explicit `-ForceOverwriteOutput` med change ticket.
2. Signera `build-manifest.json`, `SHA256SUMS.txt`, rapporter och metadata med org-cert eller Sigstore/cosign-liknande process.
3. Publicera audit packet till WORM/immutable storage med retention policy.
4. Lägg manifest-hash och event-id i rapporten samt rapporthash i manifestet, eller använd signerad envelope som binder allt.

**Release blocker:** **Ja**.

### H-03 — Build root saknar ACL-/owner-/reparse-point-hardening trots admin-körning och filradering

**Evidence:**

- Installer och build skapar kataloger men sätter/verifierar inte ACL/owner (`Install-BuildWIM.ps1:113-118`, `Build-WIM.ps1:1363-1374`).
- Managed delete kontrollerar prefix under BuildWIM-roots men inte owner, ACL, junction/symlink/reparse points (`Build-WIM.ps1:662-725`).
- Temp/output/logs/reports ligger under samma root som kan förberedas utanför scriptet (`Config/buildwim.config.json:3`, `README.md:140-153`).

**Risk:** Scriptet körs som Administrator (`Build-WIM.ps1:1376-1381`, `Install-BuildWIM.ps1:99-101`). Om en lokal användare eller tidigare process kan skriva i `C:\BuildWimV2`, byta ut filer, skapa junctions eller manipulera sidecars kan builden konsumera fel input, radera fel data eller producera komprometterade artefakter.

**Practical fix:**

1. Installer ska sätta ACL: `SYSTEM` och `Administrators` full control; vanliga users högst read/execute där behövs; ingen write i build root.
2. Preflight ska verifiera owner/ACL på root och kritiska underkataloger.
3. Blockera reparse points/junctions i managed roots före delete/copy/hash.
4. Kör på dedikerad ephemeral buildhost eller VM med separat artifact export.

**Release blocker:** **Ja**.

### H-04 — ADK/WinPE-installationsflödet saknar integritetskontroll före exekvering

**Evidence:**

- `Install-BuildWIM.ps1` kör `C:\tmp\adksetup.exe` och `C:\tmp\adkwinpesetup.exe` om `-InstallAdk` anges (`Install-BuildWIM.ps1:56-97`).
- Scriptet verifierar att filerna finns men inte Authenticode, hashallowlist eller download provenance (`Install-BuildWIM.ps1:61-69`, `Install-BuildWIM.ps1:90-96`).

**Risk:** I enterprise bootstrap kan en manipulerad installer köras som admin. Även om ADK är optional blir detta en supply-chain svaghet i installationsflödet.

**Practical fix:** Verifiera Microsoft Authenticode chain, revocation/timestamp där möjligt och org-godkända SHA256 före `Start-Process`; dokumentera approved ADK-versioner och installation source.

**Release blocker:** **Ja om `-InstallAdk` ingår i rollout; annars Nej men måste dokumenteras som unsupported production path tills fixad.**

---

## Findings — Medium

### M-01 — Loggning/transcript saknar dataminimering, log level enforcement och retention/privacy-policy

**Evidence:**

- `Start-Transcript` körs automatiskt vid icke-DryRun (`Build-WIM.ps1:4598-4604`) och stoppas i finally (`Build-WIM.ps1:5296-5299`).
- `Write-Log` skriver alla nivåer till host och logg utan att läsa `Config.Logging.LogLevel` (`Build-WIM.ps1:590-610`, config `Config/buildwim.config.json:42-45`).
- DISM stdout/stderr appendas alltid till logg (`Build-WIM.ps1:1701-1706`).
- Manifest inkluderar hostname och username (`Build-WIM.ps1:2758-2761`), input/output paths (`Build-WIM.ps1:2769-2788`) och rapporter exponerar fulla paths (`Build-WIM.ps1:2920-2927`, `Build-WIM.ps1:2980-2982`).
- Docs säger att transcript/loggar ska användas men saknar redaction/retention/access guidance (`docs/LOGGING.md:31-40`).

**Risk:** Loggar och rapporter kan läcka hostnamn, användarnamn, interna sökvägar, Microsoft Catalog URLs, package paths och driftmönster. För ett IT-säkerhetsbolag är detta ofta intern metadata med skyddsvärde. Utan retention/klassning kan bevis antingen raderas för tidigt eller sparas längre än nödvändigt.

**Practical fix:**

1. Implementera `Logging.LogLevel`, `IncludeDebugDismOutput`, `RedactPaths`, `RedactUserHost`, `TranscriptMode` och `RetentionDays`.
2. Dela rapportering i två paket: intern full-fidelity audit och redacted/shareable summary.
3. Sätt ACL på `Logs`/`Reports`; publicera till centralt SIEM/artifact store med retention.
4. Dokumentera dataklassning och exakt vilka fält som innehåller person-/hostmetadata.

**Release blocker:** **Nej för pilot; Ja för bred rollout utan kompensationskontroll.**

### M-02 — Plan-only HTML saknar HTML-encoding för dynamisk data

**Evidence:**

- Plan HTML byggs med interpolerade update/media/path/title-värden utan `HtmlEncode` (`Build-WIM.ps1:4565-4580`).
- Huvudrapporten använder däremot konsekvent `HtmlEncode` (`Build-WIM.ps1:2907-2940`, `Build-WIM.ps1:2980-2995`).

**Risk:** En lokal fil/path eller metadata/title som innehåller HTML kan injiceras i planrapporten. Detta är typiskt local/report XSS, men i enterprise kan rapporter delas i tickets, mail eller portals.

**Practical fix:** Återanvänd `New-HtmlRows`/`HtmlEncode` för planrapporten eller generera plan HTML från en templating-funktion som default-encodar alla fält.

**Release blocker:** **Nej**, men bör fixas före central rapportpublicering.

### M-03 — Sidecar metadata påverkar klassning/rapportering utan signerad bindning till paketet

**Evidence:**

- Klassning föredrar `$Path.metadata.json` för KB/title/package type innan DISM-/filnamnsheuristik (`Build-WIM.ps1:2004-2018`).
- Rapport/manifest hämtar update metadata från sidecar (`Build-WIM.ps1:2511-2535`, `Build-WIM.ps1:2776-2779`).
- Downloader skriver sidecar med URL/SHA256 men ingen signatur (`Get-LatestWindows11LCU.ps1:438-445`).

**Risk:** Authenticode på CAB/MSU skyddar payloaden, men sidecaren kan påverka target/klassning och audit-förväntningar. Felaktig sidecar kan ge missvisande bevis, särskilt för SafeOS/WinRE och .NET där klassning är viktig.

**Practical fix:** Bind sidecar till payload via package SHA256 och signerad metadata; verifiera att sidecar SHA256 matchar faktisk fil innan den används; markera metadata source (`catalog`, `local`, `unsigned`) i manifest och rapport.

**Release blocker:** **Nej**, men viktigt för audit kvalitet.

### M-04 — App Control/Constrained Language Mode rekommenderas inte och runtime policy saknas

**Evidence:**

- Inga docs nämner WDAC/App Control/Constrained Language Mode enligt grep.
- Scripts kräver admin och använder .NET, `Start-Process`, DISM, registry load, archive expansion och external exe; produktionskrav finns inte dokumenterat som policyprofil (`Build-WIM.ps1:59-60`, `Build-WIM.ps1:1376-1388`, `Test-BuildWimPatchState.ps1:52-68`).

**Risk:** Enterprise-operatörer vet inte om verktyget ska köras i FullLanguage på dedikerad signerad buildhost, under WDAC allowlist eller med undantag från CLM. Utan policyprofil blir rollout inkonsekvent och svår att godkänna.

**Practical fix:** Dokumentera supported execution policy: dedikerad buildhost, signerade scripts, WDAC allowlist för signerade BuildWIM scripts + Microsoft binaries (`dism.exe`, `expand.exe`, `reg.exe`, PowerShell), och tydlig notering om CLM-stöd/icke-stöd. Lägg preflight som rapporterar policy state.

**Release blocker:** **Nej för pilot; Ja för enterprise hardening-baseline.**

### M-05 — CI/testbarhet är otillräcklig för enterprise release gates

**Evidence:**

- Versionerade filer saknar `.github/workflows`, Pester-testfiler och PSScriptAnalyzer settings enligt `git ls-files`/`find`.
- Det finns ett kraftfullt manuellt verifieringsscript (`Test-BuildWimPatchState.ps1:1-10`, `Test-BuildWimPatchState.ps1:341-369`) och dokumenterad evidence (`docs/VALIDATED_BUILDS.md:5-43`), men ingen automatiserad parse/lint/unit/regression gate.
- `CONTRIBUTING.md` nämner PSScriptAnalyzer som riktlinje men inte enforcement (`CONTRIBUTING.md:26`).

**Risk:** Ändringar i parser, klassning, manifestschema, logging/redaction och URL allowlisting kan regressa utan att upptäckas innan release. Manuell validation är bra men räcker inte som enterprise release control.

**Practical fix:** Lägg CI med PowerShell parser check för alla `.ps1`, PSScriptAnalyzer, Pester-tester för URL allowlists, package classification, sidecar binding, manifest schema, report encoding och mockade download-/DISM-flöden. Publicera testresultat i release packet.

**Release blocker:** **Nej för pilot; Ja för formell enterprise release.**

### M-06 — Manifest och metadata är nyttiga men inte fullständiga för change traceability

**Evidence:**

- Manifest inkluderar script version/path/gitCommit (`Build-WIM.ps1:2764-2768`) och steps/warnings/errors (`Build-WIM.ps1:2789-2792`).
- Metadata JSON inkluderar input, packages, outputs, verification och steps (`Build-WIM.ps1:5116-5146`).
- Inget fält finns för change ticket, approver, release owner, environment, config hash, source allowlist-id eller operator role.

**Risk:** Det går att se vad som hände, men inte säkert varför det var godkänt, vem som godkände det, vilken policybaseline som gällde eller om rätt config användes.

**Practical fix:** Inför obligatoriska production-parametrar/configfält: `ReleaseId`, `ChangeTicket`, `ApprovedBy`, `PolicyBaselineId`, `ConfigSHA256`, `BuildHostId`, `ArtifactRetentionClass`. Faila i `-Production` om de saknas.

**Release blocker:** **Nej**, men central för NIS2/ISO audit readiness.

---

## Findings — Low

### L-01 — Config har logging knobs som inte verkar vara implementerade

**Evidence:** `Config/buildwim.config.json` definierar `Logging.LogLevel` och `IncludeDebugDismOutput` (`Config/buildwim.config.json:42-45`), men grep hittar ingen användning i `Build-WIM.ps1`.

**Risk:** Operatörer kan tro att loggnivån styrs av config när den inte gör det. Det skapar falsk trygghet runt privacy och loggvolym.

**Practical fix:** Implementera eller ta bort configfälten tills de fungerar; rapportera aktiv loggpolicy i manifest.

**Release blocker:** **Nej**.

### L-02 — ETA/diff history är begränsad och inte en audit trail

**Evidence:** `build-history.json` sparas under Reports och trunkeras till senaste 20 körningarna (`Build-WIM.ps1:1163-1165`, `Build-WIM.ps1:1262-1287`). Diff-rapport bygger på denna lokala historik (`Build-WIM.ps1:3299-3373`).

**Risk:** Bra operatörsstöd men kan förväxlas med revisionshistorik. Den är lokal, mutable och kortlivad.

**Practical fix:** Märk den som convenience-only och använd separat immutable release registry för faktisk audit/history.

**Release blocker:** **Nej**.

### L-03 — Produktversion/schema är statiska och saknar migrations-/compat policy

**Evidence:** Scriptversion är `2.0.0` (`Build-WIM.ps1:23`, `Build-WIM.ps1:75`), configversion `1.0.0` (`Config/buildwim.config.json:2`) och manifestschema `buildwim.v2.manifest` (`Build-WIM.ps1:2755`). Ingen schema-validering eller migrationspolicy hittades.

**Risk:** Rapporter/manifest kan ändras utan tydlig schema governance, vilket påverkar SIEM/parser/inventory-integrationer.

**Practical fix:** Versionera manifest/config schema, publicera JSON Schema och testa bakåtkompatibilitet i CI.

**Release blocker:** **Nej**.

---

## Praktisk compliance-mappning

### NIS2 — konkreta gaps

- **Risk management / supply chain:** C-01 och H-01 blockerar. Signerad releasekedja, approved media/update baseline och change approval behövs.
- **Incident handling / evidence:** H-02 blockerar om audit packet inte är immutable och signerad.
- **Security in acquisition/development/maintenance:** M-05/M-06 kräver CI gates, release metadata och policy traceability.
- **Access control / asset protection:** H-03 och M-01 kräver ACL, host isolation och loggsekretess.

### CIS Controls v8 — praktisk mappning

- **CIS 2 Software Inventory / CIS 4 Secure Configuration:** signed scripts, WDAC policy och approved toolchain saknas (C-01, M-04).
- **CIS 5/6 Account & Access Control:** build root ACL och admin-körning behöver hardening (H-03).
- **CIS 7 Continuous Vulnerability Management:** update discovery finns, men production pinning/approval saknas (H-01).
- **CIS 8 Audit Log Management:** loggar finns, men retention, redaction, centralisering och immutable storage saknas (M-01, H-02).
- **CIS 16 Application Software Security:** CI/Pester/PSScriptAnalyzer gates saknas (M-05).

### ISO 27001/27002 — praktisk mappning

- **Change management / configuration management:** H-01, M-06. Behöver release-id, change ticket, approver och config hash.
- **Information transfer / logging / monitoring:** M-01, H-02. Behöver dataklassning, retention och skydd av rapporter/loggar.
- **Secure development lifecycle:** C-01, M-05. Signering, CI, testbarhet och release attestation.
- **Access control / privileged utilities:** H-03, M-04. Dedikerad buildhost, ACL, WDAC/App Control och dokumenterad runtime policy.
- **Supplier/service assurance:** H-01/H-04. Microsoft media/update/ADK provenance måste bindas till approved baseline.

## Rekommenderad minsta enterprise hardening före rollout

1. Inför `-Production` som fail-closed aktiverar: signed script verification, approved media/update manifest, config hash, release metadata och unique output folder.
2. Signera egna scripts och audit packet; kör utan `ExecutionPolicy Bypass` i production.
3. Bygg endast från approved baseline manifest; auto-latest får bara skapa förslag/plan.
4. Skriv artefakter till unik immutable release bundle och publicera till WORM/artifact store.
5. Hårda ACL/reparse kontroller på `C:\BuildWimV2` eller använd ephemeral build VM.
6. Implementera logging privacy controls: redaction, retention, central log sink och restricted ACL.
7. Lägg CI: parser, PSScriptAnalyzer, Pester, manifest schema, report HTML-encoding och URL/metadata tests.
8. Dokumentera WDAC/App Control/CLM stance och kör preflight som rapporterar policy state.

## Verifiering utförd

- Statisk filgenomgång med `find`, `git ls-files`, `grep -RIn` och line-numbered `nl/sed`.
- Kontrollerade förekomst av Authenticode signature blocks i versionerade `.ps1`: inga hittades.
- Kontrollerade avsaknad av `.github/workflows`, Pester-testfiler och PSScriptAnalyzer settings i repo.
- PowerShell parser kördes inte: `pwsh`/`powershell` fanns inte tillgängligt i denna Linux/WSL-miljö. Inga destruktiva scripts kördes.

## Slutligt go/no-go

**NO-GO för bred enterprise rollout.**  
**GO med begränsning** endast för kontrollerad pilot/image-factory där följande kompensationskontroller finns redan utanför verktyget: dedikerad låst buildhost, manuellt approved source media/updatepaket med hash, separat signerad artifact retention, begränsad loggåtkomst och manuell change approval.
