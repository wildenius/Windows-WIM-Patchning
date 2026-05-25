# Security review: supply-chain och nedladdningsintegritet

**Scope:** `Get-Windows11Iso.ps1`, `Get-LatestWindows11LCU.ps1`, relevanta delar av `Build-WIM.ps1`, `Config/buildwim.config.json`. Jag granskade även `Resolve-BuildWimMicrosoftEsd.ps1` där `Build-WIM.ps1` delegerar Microsoft ESD-hämtning.

**Verifiering:** Statisk granskning med `grep -n`/`nl -ba` för nätverk, URL-filter, hash, signatur, katalog/cache och DISM-injektionsflöden. PowerShell parser kunde inte köras i denna Linux/WSL-miljö eftersom `pwsh`/`powershell.exe` inte fanns tillgängliga; inga destruktiva scripts kördes.

## Sammanfattning

Det finns flera bra kontroller: HTTPS-krav i de flesta hämtare, Microsoft-domänfilter, Authenticode-kontroll av MSU/CAB innan DISM-injektion, SHA256-rapportering, samt ESD-hashkontroll när Microsoft-katalogen anger hash. De största kvarvarande riskerna är att **ISO/WIM-källan accepteras utan verifierad känd-good checksum/signaturkedja**, att **ESD-hasharnas rotförtroende är en nedladdad och cachad katalog utan separat verifiering**, samt att **lokala metadata-sidecars/cache kan påverka urval och downgrade/replay-beslut**.

## Findings Critical

Inga Critical findings hittades inom avgränsningen.

## Findings High

### HIGH-01 — ISO/lokal WIM/ESD-källa saknar stark integritetsankare och kan accepteras baserat på filnamn

- **Evidence:**
  - `Get-Windows11Iso.ps1:498-510` väljer befintlig ISO via namn/tokens (`Win11`, `x64`, språk) utan att jämföra mot en betrodd publicerad checksum.
  - `Get-Windows11Iso.ps1:554-576` skriver metadata och beräknar SHA256 för befintlig ISO, men hashen används som inventarie/rapport, inte som verifiering mot känt värde.
  - `Get-Windows11Iso.ps1:733-742` gör samma sak efter nedladdning: beräknar SHA256 och sparar den, men verifierar inte mot Microsoft-publicerad eller repo-pinnad checksum.
  - `Build-WIM.ps1:1403-1407` accepterar lokala `.iso`, `.wim`, `.esd` som inputkandidater.
  - `Build-WIM.ps1:4682-4683` hashar vald input men jämför inte mot allowlist/manifest.
- **Risk:** En felaktig, manipulerad eller återspelad ISO/WIM/ESD i `Input` kan bli basimage för hela offline-builden. TLS mot Microsoft minskar nätverks-MITM för auto-download, men skyddar inte lokal cache, felplacerad fil, insiderfel, komprometterad build-share eller framtida CDN/redirect-problem. För ISO är “hash after download” bara spårbarhet, inte integritetsvalidering.
- **Practical fix:** Inför ett obligatoriskt source-manifest för produktionsläge: `filename`, `size`, `sha256`, `source`, `retrievedAt`, `approvedBy`. Acceptera lokal ISO/WIM/ESD endast om SHA256 matchar manifest eller om operatören explicit godkänner ny hash i ett tvåstegsläge. För auto-ISO: hämta/verifiera mot en betrodd Microsoft-hash om tillgänglig, alternativt använd intern repo-pinning/attestation av första godkända ISO. Fail closed om flera eller okända källor finns. Logga verifieringsstatus som `verified`, inte bara `hashed`.
- **Release blocker:** **Ja** för produktionsbuildar som ska betraktas som betrodda installationsmedia.

### HIGH-02 — ESD-kedjan verifierar payload-hash, men katalogen som levererar hash är inte separat signerad/pinnad och cache återanvänds

- **Evidence:**
  - `Build-WIM.ps1:1506-1529` delegerar ESD-flödet till `Resolve-BuildWimMicrosoftEsd.ps1`.
  - `Resolve-BuildWimMicrosoftEsd.ps1:115-130` laddar katalog-CAB/XML från Microsoft-URL och cachelagrar extraherad XML utan Authenticode/signatur-/hash-pinning av katalogen.
  - `Resolve-BuildWimMicrosoftEsd.ps1:117` återanvänder befintlig katalogcache när `-Force` inte anges.
  - `Resolve-BuildWimMicrosoftEsd.ps1:214-224` verifierar ESD mot SHA256/SHA1 från katalogen, men om katalogen är felaktig blir hashkontrollen transitivt felaktig.
  - `Resolve-BuildWimMicrosoftEsd.ps1:42-47` tillåter HTTP för vissa delivery-hosts, med antagandet att kataloghashen skyddar innehållet.
- **Risk:** ESD-payloadens integritet är bara lika stark som katalogens integritet. En cacheförgiftad, återspelad eller komprometterad katalog kan peka på äldre/fel ESD med matchande hash. HTTP för payload är acceptabelt endast om katalogen är starkt verifierad; här saknas ett separat ankare. Eftersom ESD är en primär media-provider kan detta påverka hela basimagen.
- **Practical fix:** Verifiera katalog-CAB/XML innan den används: Authenticode på CAB om möjligt, kända Microsoft-katalogsignaturer, eller pinna SHA256 för katalogversioner i repo/konfig. Lagra katalogmetadata med `sourceUrl`, `finalUrl`, `sha256`, `signatureStatus`, `expires/maxAge`. Kräv färsk katalog eller explicit `-AllowStaleCatalog`. Acceptera HTTP ESD endast när katalogen är verifierad och ESD har SHA256; undvik SHA1-only i produktionsläge.
- **Release blocker:** **Ja** om `MicrosoftEsd`/`AutoFallback` används för produktionsmedia.

## Findings Medium

### MEDIUM-01 — URL-allowlist är bred och fwlink/redirect-kedjor revalideras inte konsekvent mot slutlig URL

- **Evidence:**
  - `Get-LatestWindows11LCU.ps1:56-68` och `Build-WIM.ps1:745-758` litar på breda suffix som `microsoft.com`, `windowsupdate.com`, `go.microsoft.com`.
  - `Build-WIM.ps1:2287-2290` använder Defender `go.microsoft.com/fwlink`.
  - `Config/buildwim.config.json:23-27` sätter samma fwlink som default.
  - `Build-WIM.ps1:2344-2349` laddar Defender-kit med `curl --location` eller `Invoke-WebRequest` utan efterföljande final-URL allowlist-kontroll.
  - `Build-WIM.ps1:3700-3703` läser `FinalUrl` vid HEAD, men `Get-DefenderOfflineUpdatePackage` använder inte resultatet för trust-beslut (`Build-WIM.ps1:2325-2326`).
- **Risk:** Microsoft redirectors och breda suffix är praktiska men ökar blast radius. Om en fwlink ändras, om en Microsoft-tjänst får open redirect-beteende, eller om fel endpoint returnerar ett annat paket, upptäcks det först senare via signatur/CAB-struktur. För Defender ZIP verifieras inte ZIP:en i sig; endast extraherad CAB signaturkontrolleras.
- **Practical fix:** Revalidera slutlig `ResponseUri`/curl effective URL efter redirects mot en artefaktspecifik allowlist. Separera allowlist per artefakt: ISO (`software-download.microsoft.com`/Microsoft download CDN), Update Catalog (`catalog.update.microsoft.com`, `download.windowsupdate.com`), Defender (`download.microsoft.com` eller dokumenterad slut-host). Tillåt fwlink endast som resolversteg, inte som slutlig trust. Logga initial och final URL.
- **Release blocker:** Nej, men bör åtgärdas innan bred automatiserad utrullning.

### MEDIUM-02 — Microsoft Update Catalog skrapas via HTML/regex och nedladdad package identity binds inte hårt till vald KB/version/arkitektur

- **Evidence:**
  - `Get-LatestWindows11LCU.ps1:196-207` parsar Catalog-sökresultat med regex över HTML-tabeller.
  - `Get-LatestWindows11LCU.ps1:245-277` väljer “senaste” baserat på titel, datum och textfilter.
  - `Get-LatestWindows11LCU.ps1:307-335` extraherar första betrodda `.msu`/`.cab`-URL från DownloadDialog och föredrar URL som matchar KB-siffror.
  - `Get-LatestWindows11LCU.ps1:363-373` verifierar storlek och Authenticode, men jämför inte DISM package identity mot `KB`, `Build`, `WindowsVersion`, `Architecture` från katalograden innan metadata skrivs.
  - `Build-WIM.ps1:1996-2077` klassificerar senare paket via sidecar/DISM/filnamn, men sidecar kan dominera specialklassificering för .NET/SafeOS.
- **Risk:** HTML-formatändringar, regionala datum, flera liknande paket eller Catalog-resultat med oväntad ordning kan leda till fel men Microsoft-signerat paket. Signatur skyddar mot manipulerad kod, men inte mot “wrong signed thing”, fel arkitektur, preview/OOB-förväxling, äldre paket eller fel mål (main image kontra WinRE).
- **Practical fix:** Efter download: kör DISM `/Get-PackageInfo` och bind `Package Identity`, KB, arkitektur, target och build/revision mot Catalog-valet. Fail closed vid mismatch. Om möjligt använd Windows Update/Update Catalog API med strukturerad metadata i stället för HTML-regex. Spara och verifiera `UpdateId`, `FileName`, `SizeBytes`, `SHA256` och package identity i sidecar.
- **Release blocker:** Nej, förutsatt att slutverifieringen fortsätter vara strikt; ja för miljöer som kräver helt unattended patch compliance utan manuell granskning.

### MEDIUM-03 — Lokala sidecars och catalog-cache kan påverka “latest/current”-beslut och möjliggöra downgrade/replay

- **Evidence:**
  - `Build-WIM.ps1:283-311` läser befintliga LCU-sidecars och sorterar på `Build`/`LastUpdated` utan att först verifiera filens hash mot sidecar eller package identity.
  - `Build-WIM.ps1:3453-3478` gör liknande för .NET baserat på sidecar-title/date.
  - `Build-WIM.ps1:3542-3567` gör liknande för SafeOS.
  - `Get-LatestWindows11LCU.ps1:109-115` bevarar tidigare `Path`/`SHA256` i cache när ny metadata saknar dessa fält.
  - `Get-LatestWindows11LCU.ps1:438-445` skriver sidecar/cache som vanlig JSON utan integritetsskydd.
- **Risk:** En stale eller manipulerad sidecar kan få en äldre lokal MSU/CAB att framstå som nyare/korrekt, påverka download-beslut eller styra klassificering. Authenticode stoppar osignerat innehåll vid injektion, men inte replay av äldre signerade Microsoft-paket eller fel metadata för urvalslogik.
- **Practical fix:** Behandla sidecars som cache, inte auktoritet. Verifiera alltid filhash mot sidecar och package identity mot faktisk fil före “existing is current”. Sätt maxålder på cache, skriv atomärt, och signera/attestera cache om den ska återanvändas i CI. Låt färsk Catalog-metadata vinna över lokal sidecar; vid konflikt, ladda om eller fail closed.
- **Release blocker:** Nej för interaktiv drift; bör vara blockerande för CI/CD eller NIS2-kritiska basimage-pipelines.

### MEDIUM-04 — Authenticode-kontrollen är bra men för generell för Windows Update/Defender trust policy

- **Evidence:**
  - `Get-LatestWindows11LCU.ps1:73-87` kräver `Get-AuthenticodeSignature` status `Valid`, men accepterar certifikat där subject eller issuer matchar texten `Microsoft`.
  - `Build-WIM.ps1:763-783` har samma generella Microsoft-textkontroll.
  - `Build-WIM.ps1:2143-2145` anropar kontrollen före DISM-injektion.
  - `Build-WIM.ps1:2359-2363` verifierar Defender-CAB med samma helper.
- **Risk:** Lokal Windows trust store och generisk “Microsoft” i subject/issuer är bredare än en release-policy för Windows Update-paket. Det saknas explicit krav på rätt EKU, kedja, rot/intermediate, revocation/timestamp-policy och artefakttyp. Det minskar spårbarheten mot supply-chain-krav även om praktisk exploatering är svårare.
- **Practical fix:** Definiera en signer-policy: tillåtna signer subjects/issuers/thumbprints/intermediates för Windows Update/Defender, EKU för code signing/catalog signing, revocation check där miljön tillåter, samt loggad certkedja. Komplettera med DISM package identity-verifiering så “rätt signerad fil” också är “rätt paket”.
- **Release blocker:** Nej, men rekommenderad hardening för produktion.

## Findings Low

### LOW-01 — Content-Type, magic bytes och filformat kontrolleras ojämnt före cache/expand

- **Evidence:**
  - `Get-Windows11Iso.ps1:607-612` laddar ISO direkt till destination utan HEAD/content-type/magic/size-validering före accept; efteråt sparas hash i metadata (`Get-Windows11Iso.ps1:733-742`).
  - `Get-LatestWindows11LCU.ps1:363-373` har storleksgolv och signatur men ingen Content-Type/final filename-kontroll.
  - `Build-WIM.ps1:2344-2357` laddar Defender ZIP och kör `Expand-Archive`; först därefter söks och signaturverifieras CAB (`Build-WIM.ps1:2359-2363`).
- **Risk:** Fel serverrespons, HTML-felsida, throttling-svar eller oväntad zip kan cachelagras tills senare steg misslyckas. Det är mest robusthets-/DoS-risk eftersom MSU/CAB signaturkontroll stoppar injektion.
- **Practical fix:** Ladda till temporär `.partial`, kontrollera HTTP-status, Content-Length, rimlig storlek, content-type där pålitligt, magic bytes (`MZ`/CAB/ZIP/UDF/ISO), och byt atomärt till slutnamn efter verifiering. Radera partials vid fel.
- **Release blocker:** Nej.

### LOW-02 — SHA256SUMS/build-manifest skapas men signeras/attesteras inte

- **Evidence:**
  - `Build-WIM.ps1:5060-5062` hashar final WIM.
  - `Build-WIM.ps1:5071-5079` hashar SWM-filer.
  - `Build-WIM.ps1:5093-5110` skriver `SHA256SUMS.txt` och `build-manifest.json`, men det finns ingen signering eller extern attestering.
- **Risk:** Hashfiler är bra för detektion efter build, men om output-katalogen eller distributionskanalen manipuleras kan både artefakt och hashfil ändras samtidigt.
- **Practical fix:** Signera manifest/SHA256SUMS med organisationsnyckel eller publicera i ett append-only release-/artifact-system. Inkludera source-manifest, signer chain, update metadata och build host identity i manifestet.
- **Release blocker:** Nej.

## Praktisk relevans mot NIS2, CIS Controls och ISO 27001/27002

- **NIS2:** Findings HIGH-01/HIGH-02 och MEDIUM-03 träffar praktiskt krav på riskhantering, incidentförebyggande, säkra uppdateringar och supply-chain-styrning. För en installation-image pipeline bör källmedia och patchar vara verifierbara, reproducerbara och spårbara.
- **CIS Controls v8:** Relevanta kontroller är främst 2 (Software Assets), 4 (Secure Configuration), 7 (Continuous Vulnerability Management), 8 (Audit Log Management), 16 (Application Software Security) och 17 (Incident Response). Största gapet är verifierad provenance för källartefakter och cache/manifest-integritet.
- **ISO 27001/27002:2022:** Praktiskt mappat till 5.8/5.9 (information och tillgångar), 5.21/5.22 (leverantör/supply chain), 8.8 (technical vulnerabilities), 8.9 (configuration management), 8.15/8.16 (logging/monitoring), 8.19/8.20/8.24 (programvara, nätverkssäkerhet, kryptografi). Nuvarande implementation har god spårbarhet, men behöver starkare verifieringsankare och förändringskontroll av cache/metadata.

## Kort verdict för supply-chain

**Verdict:** Bra grundkontroller finns, särskilt Authenticode före MSU/CAB-injektion och hashrapportering, men pipeline är inte ännu “production-grade trusted” för supply-chain. De två viktigaste blockerarna är att basmedia (ISO/WIM/ESD) saknar starkt verifierat provenance-ankare och att ESD-katalogens trust root inte verifieras separat. Efter införande av signerade/pinnade source- och catalog-manifest, final-URL-kontroll och hårdare package identity-binding bör lösningen kunna nå en rimlig NIS2/CIS/ISO-praktisk nivå.
