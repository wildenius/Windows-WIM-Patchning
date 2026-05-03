# Security review — BuildWIM v2

Date: 2026-05-03
Scope: `Build-WIM.ps1`, `Get-LatestWindows11LCU.ps1`, `Get-Windows11Iso.ps1`, `Install-BuildWIM.ps1`, config and docs.
Target: Windows 11 Pro WIM/SWM intended for broad deployment (~3000 clients).

## Executive verdict

Current state is good for lab/pilot and has several strong controls: Microsoft URL allowlisting, Authenticode checks for update packages, isolated mount dirs, Pro-only export, DISM cleanup, reports, SHA256 output hashes, Defender metadata, and final mounted-image verification.

It is **not yet bulletproof enough for direct 3000-client production** without additional release gates. Biggest gaps:

1. Source ISO/WIM authenticity is hashed but not verified against an approved baseline.
2. Final verification warnings do not fail production builds.
3. SafeOS/WinRE validation was too weak; this review's immediate fix makes selected SafeOS/WinRE absence or failed proof a release blocker.
4. Download/update selection relies on Catalog HTML scraping and broad Microsoft URL/signature trust; acceptable with extra validation, not enough alone.
5. No enforced signed-build provenance for the scripts/manifests used to produce the image.
6. No mandatory boot-test / first-boot security validation stage before release.

## Fix status from this review

Implemented immediately in `Build-WIM.ps1`:

- Safe OS Dynamic Update selected + missing `Windows\System32\Recovery\winre.wim` now throws a release blocker instead of warning.
- Final verification checks SafeOS against mounted final `winre.wim` package identities (`FinalWinRePackageIdentities`), not main-image `ServicePackBuild`/`UBR`.
- SafeOS proof now extracts package identity/version hints from the selected `.cab`/`.msu` and matches those against WinRE DISM package identities.
- If SafeOS proof cannot be established, final verification throws `Release blocker: ...`.
- Verification details now include target (`WinRE` vs `Main image`), SafeOS hint matches, WinRE package count and `winReOk`.

Still open for true 3000-client production hardening: approved source allowlist, fail-on-warning production mode, signed provenance/release manifests, and mandatory boot/first-boot validation.

## Findings

### CRITICAL-01 — Source media authenticity is not enforced

**Where:** `Build-WIM.ps1` around input hashing and source discovery; manifest records SHA256 but no allowlist/known-good comparison.

**Risk:** If `C:\BuildWimV2\Input` contains a tampered ISO/WIM/ESD, the pipeline will faithfully patch and distribute it. Authenticode checks on updates do not protect the base OS image.

**Recommendation:**
- Add `Config\approved-sources.json` with allowed SHA256 hashes, edition, language, architecture, build, release name.
- Fail build unless source hash matches approved source or an explicit `-AllowUnapprovedSource` is provided.
- Store source hash in final manifest/report and require release sign-off.

**Verification:**
- Build should fail with unknown ISO.
- Build should pass with known approved Microsoft ISO SHA256.

---

### CRITICAL-02 — Production build can finish with warnings

**Where:** `Test-FinalImageVerification`, warning handling, final verdict logic. Example warning: `Slutverifiering: kunde inte bevisa KB5084812 fullt ut...`.

**Risk:** For 3000 clients, `SUCCESS WITH WARNINGS` is not a deployable state unless each warning is explicitly classified as non-blocking. A SafeOS/WinRE warning could mean recovery environment is not patched.

**Recommendation:**
- Add strict production mode, e.g. `-ProductionRelease` or config `Safety.FailOnWarnings = true`.
- In production mode, any warning becomes exit code 1 unless present in an allowlist with reason and expiry.
- Separate warning severities: `Info`, `Warn`, `ReleaseBlocker`.

**Verification:**
- Current KB5084812 proof warning must fail production mode.
- A documented benign warning can pass only with allowlist entry in manifest.

---

### CRITICAL-03 — No mandatory post-build VM boot validation

**Where:** Pipeline ends after offline WIM/SWM validation and hashes.

**Risk:** Offline DISM success does not guarantee OOBE, setup, WinRE, Defender, Windows Update, Autopilot/Intune enrollment, TPM/BitLocker readiness, or baseline policy compatibility. For 3000 clients this is a hard release gate.

**Recommendation:** Add a release pipeline stage that deploys the WIM to a disposable VM and runs:
- first boot / OOBE or unattended setup,
- `winver`/build/UBR check,
- Defender health/signatures/platform,
- Windows Update scan,
- `reagentc /info`,
- BitLocker readiness / Secure Boot / TPM checks,
- event log checks for setup/CBS/Defender errors,
- Intune enrollment smoke test if applicable.

**Verification:** No production release without attached VM validation report.

---

### HIGH-01 — SafeOS/WinRE verification is not strong enough

**Where:** `Add-SafeOsDynamicUpdateToWinRe`; `Test-FinalImageVerification`. SafeOS currently sets `servicePackOk=$true` and `ubrOk=$true`, so proof depends mostly on package identity in WinRE.

**Risk:** If `winre.wim` is missing or the package identity cannot be matched, the run can still complete with warnings. WinRE is security-sensitive because it is used for recovery and offline operations.

**Recommendation:**
- If SafeOS is selected, absence of `Windows\System32\Recovery\winre.wim` must be release-blocking.
- Mount final `winre.wim` and record package list, build, architecture, and scratch status.
- Improve SafeOS identity matching using `Package_for_SafeOSDU`, package version/build, not only KB literal.
- Add report section: `SafeOS selected`, `WinRE found`, `WinRE mounted`, `SafeOS package matched`, `WinRE package identities`.

---

### HIGH-02 — KB5084812 warning meaning

The warning:

```text
Slutverifiering: kunde inte bevisa KB5084812 fullt ut i final WIM (package=False, servicePack=True, ubr=True)
```

means:

- `package=False`: verifieringen hittade inte KB5084812 i DISM package identities.
- `servicePack=True`: image build/service pack revision ser korrekt ut.
- `ubr=True`: registry UBR ser korrekt ut.

For SafeOS/WinRE this message is suspicious because SafeOS should be verified against mounted `winre.wim`, not main-image build/UBR. Treat as **verification gap** until fixed. Do not deploy to 3000 clients with this warning unclassified.

---

### HIGH-03 — Update Catalog selection needs second-source validation

**Where:** `Get-LatestWindows11LCU.ps1`, HTML parsing of `Search.aspx` and `DownloadDialog.aspx`.

**Risk:** Catalog HTML scraping can select the wrong package if Microsoft changes layout/titles or multiple similar packages exist. Current filtering is good but still heuristic.

**Recommendation:** After download, inspect package metadata and assert:
- KB equals selected KB,
- architecture matches x64,
- product/version matches Windows 11 25H2,
- package type matches LCU/.NET/SafeOS,
- not Preview unless explicitly allowed,
- file hash and size match metadata captured at selection time.

---

### HIGH-04 — Trust policy is broad

**Where:** `Test-TrustedMicrosoftDownloadUrl`, `Assert-TrustedMicrosoftFileSignature`.

**Current good:** HTTPS required; Microsoft-host suffix allowlist; Authenticode valid; subject/issuer contains Microsoft.

**Risk:** For production release, “any valid Microsoft-signed package from broad Microsoft domains” is too broad. It protects against random MITM, but not wrong Microsoft package selection.

**Recommendation:**
- Narrow URL allowlist by package type.
- Record final redirected URL.
- Pin expected file extension and expected KB in filename/metadata.
- Validate signer chain EKU for code signing and timestamp status where possible.
- Require downloaded hash to be stable in manifest and reviewed before deployment.

---

### HIGH-05 — Build scripts are not signed or pinned at release

**Where:** Runbook uses `ExecutionPolicy Bypass`; manifest records git commit but no script signature/release tag enforcement.

**Risk:** A local script modification on the build host can silently affect a 3000-client image.

**Recommendation:**
- Sign PowerShell scripts with an internal code-signing cert.
- Require clean git state and signed release tag for `-ProductionRelease`.
- Record script SHA256 and git commit in manifest.
- Fail if repo dirty unless `-AllowDirtyBuild`.

---

### HIGH-06 — Defender offline injection is file-copy based; final validation should be stricter

**Where:** `Add-DefenderOfflineUpdate`, `Test-FinalDefenderVerification`.

**Current good:** CAB signature is checked; required directories checked; metadata is parsed; final mount verification exists.

**Risk:** File-copy staging may be Microsoft-supported pattern, but if layout changes, the script may copy files and report success while Defender first boot does not consume them correctly.

**Recommendation:**
- Keep this feature, but make final validation require exact signature/platform/engine version match.
- Add first-boot VM validation: `Get-MpComputerStatus`, `Get-MpPreference`, signature version and engine version after boot.
- If Defender enabled but verification is not `OK`, production build must fail.

---

### MEDIUM-01 — `ResetBase` reduces rollback capability

**Where:** config default and Newbie mode set `CleanupResetBase = true`.

**Risk:** Smaller cleaner image, but superseded component rollback is removed. For a gold image released to thousands of clients, this is acceptable only after validation. During pilot, avoid ResetBase.

**Recommendation:**
- Use two profiles: `Pilot = ComponentCleanup only`, `Release = ComponentCleanup + ResetBase`.
- Document that ResetBase is irreversible inside the image.

---

### MEDIUM-02 — Disk space minimum is low for production

**Where:** config `Safety.MinFreeSpaceGB = 45`.

**Risk:** Large LCUs and scratch operations can fail mid-run, leaving stale mount state or partial outputs.

**Recommendation:** Production gate should require at least 100 GB free, preferably 150 GB on fast local SSD.

---

### MEDIUM-03 — Output artifact signing/attestation missing

**Where:** `SHA256SUMS.txt` and metadata are generated but not signed.

**Risk:** Hashes help only if protected. An attacker or accident can alter output plus hashes.

**Recommendation:**
- Sign manifest/SHA256SUMS with internal code-signing/GPG/cert.
- Publish release bundle: WIM/SWM + SHA256SUMS + manifest + reports + signed approval.

---

### MEDIUM-04 — Reports may expose local paths/user/host info

**Where:** HTML/Markdown/manifest include host/user/path/log details.

**Risk:** Good for audit, but if reports are shared broadly they expose infrastructure paths and usernames.

**Recommendation:** Keep full internal report, and generate sanitized release summary for broad distribution.

---

### MEDIUM-05 — No explicit output overwrite safety for release folder

**Where:** output uses date folder and fixed `install.wim` / `install.swm` names.

**Risk:** Same-day builds can overwrite prior artifacts unless run separation is enforced.

**Recommendation:** Include timestamp or build ID in output folder for production releases, or fail if target output exists unless `-ForceOverwriteOutput`.

---

## Recommended production gates before 3000-client rollout

1. Approved source ISO/WIM hash matched.
2. Clean signed git tag / signed scripts / no dirty tree.
3. Latest LCU/.NET/SafeOS downloaded and validated by metadata + signature.
4. Defender package signature + metadata + final offline verification OK.
5. SafeOS selected implies WinRE exists and SafeOS proof OK.
6. Final mounted-image verification status must be OK; no unapproved warnings.
7. Output hashes generated and signed.
8. Disposable VM deployment boot-test passed.
9. Pilot deployment: 10 devices → 100 devices → 500 devices → 3000.
10. Rollback plan: previous known-good media and Intune/Autopilot fallback.

## DISM/WIM hardening ideas

Safe offline hardening candidates:

- Disable consumer experience via policy registry.
- Disable suggested apps / cloud content / preinstalled consumer apps where business-approved.
- Remove unnecessary provisioned Appx packages only from an approved allow/remove list.
- Disable optional features not used: SMB1, XPS, WorkFolders, legacy components.
- Enable .NET 3.5 only if required; otherwise leave disabled.
- Ensure WinRE is present, patched, enabled after deployment.
- Pre-stage Defender platform/signatures but keep normal update channels enabled.
- Do not disable Defender, SmartScreen, firewall, UAC, Windows Update, or security center in the WIM.

Validation commands for mounted image:

```powershell
dism /Image:C:\Mount /Get-Packages /Format:Table
dism /Image:C:\Mount /Get-Features /Format:Table
dism /Image:C:\Mount /Cleanup-Image /CheckHealth
reg load HKLM\OFFSOFT C:\Mount\Windows\System32\config\SOFTWARE
reg query "HKLM\OFFSOFT\Microsoft\Windows NT\CurrentVersion" /v UBR
reg unload HKLM\OFFSOFT
```

Post-deploy VM validation:

```powershell
Get-ComputerInfo | select WindowsProductName,WindowsVersion,OsBuildNumber,OsHardwareAbstractionLayer
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | select DisplayVersion,CurrentBuild,UBR
Get-MpComputerStatus | select AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,AntispywareSignatureVersion,AMEngineVersion
reagentc /info
Get-WindowsUpdateLog # if needed
Get-EventLog -LogName System -EntryType Error -After (Get-Date).AddHours(-2)
```

## Final recommendation

Use current BuildWIM for pilot/validation, but add production-release gates before broad rollout. The most urgent fixes are: approved source hash enforcement, fail-on-warning production mode, stronger SafeOS/WinRE proof, signed release manifest, and VM boot validation.
