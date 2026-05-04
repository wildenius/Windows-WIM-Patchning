[CmdletBinding()]
param(
  [string]$OutputDir = 'C:\BuildWimV2\Output\2026-05-04',
  [string]$UpdatesDir = 'C:\BuildWimV2\Updates',
  [string]$DefenderDir = 'C:\BuildWimV2\Defender',
  [string]$ExpectedSafeOsKb = 'KB5084812',
  [string]$ExpectedSafeOsVersion = '26100.8309',
  [string]$ReportPath,
  [switch]$FailIfMissing
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-DismChecked {
  param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Capture)
  if ($Capture) {
    $out = & dism.exe @Arguments 2>&1
    $text = ($out | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "DISM failed ($LASTEXITCODE): dism.exe $($Arguments -join ' ')`n$text" }
    return $text
  }
  & dism.exe @Arguments
  if ($LASTEXITCODE -ne 0) { throw "DISM failed ($LASTEXITCODE): dism.exe $($Arguments -join ' ')" }
}

function Get-PackageIdentitiesFromMountedImage {
  param([Parameter(Mandatory)][string]$MountDir,[Parameter(Mandatory)][string]$ScratchDir)
  $out = Invoke-DismChecked @('/English',"/Image:$MountDir",'/Get-Packages',"/ScratchDir:$ScratchDir") -Capture
  return @($out -split "`r?`n" | ForEach-Object {
    if ($_ -match '^Package Identity\s*:\s*(.+)$') { $matches[1].Trim() }
  } | Where-Object { $_ })
}

function Get-WimInfoValue {
  param([string]$WimFile,[string]$Name)
  $out = Invoke-DismChecked @('/English','/Get-WimInfo',"/WimFile:$WimFile",'/Index:1') -Capture
  $pattern = ("(?m)^{0}\s*:\s*(.+)$" -f [regex]::Escape($Name))
  $all = @([regex]::Matches($out, $pattern) | ForEach-Object { $_.Groups[1].Value.Trim() })
  if ($all.Count -gt 0) { return $all[-1] }
  return $null
}

function Get-WinReImageVersion {
  param([Parameter(Mandatory)][string]$WimFile)
  $major = Get-WimInfoValue -WimFile $WimFile -Name 'Version'
  $spBuild = Get-WimInfoValue -WimFile $WimFile -Name 'ServicePack Build'
  if ($major -and $spBuild) { return "$major.$spBuild" }
  return $major
}

function Get-OfflineRegistryValues {
  param([Parameter(Mandatory)][string]$MountDir)
  $hiveName = 'BWSTATE_' + ([guid]::NewGuid().ToString('N'))
  $hiveRoot = "HKLM\$hiveName"
  $softwareHive = Join-Path $MountDir 'Windows\System32\config\SOFTWARE'
  $result = [ordered]@{}
  if (-not (Test-Path -LiteralPath $softwareHive)) { return [pscustomobject]$result }
  try {
    & reg.exe load $hiveRoot $softwareHive | Out-Null
    $key = "Registry::$hiveRoot\Microsoft\Windows NT\CurrentVersion"
    $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    foreach ($name in @('ProductName','CurrentBuild','CurrentBuildNumber','DisplayVersion','ReleaseId','UBR')) {
      if ($null -ne $props.$name) { $result[$name] = $props.$name }
    }
  } finally {
    try { & reg.exe unload $hiveRoot | Out-Null } catch { }
  }
  return [pscustomobject]$result
}

function Expand-UpdateMetadata {
  param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Destination,[int]$Depth = 0)
  if ($Depth -gt 3) { return }
  $leaf = Split-Path -Leaf $Path
  $target = Join-Path $Destination (([io.path]::GetFileNameWithoutExtension($leaf)) + '-' + ([guid]::NewGuid().ToString('N')))
  New-Item -ItemType Directory -Force -Path $target | Out-Null

  if ($Path -match '(?i)\.msu$') {
    & expand.exe $Path -F:*.cab $target 2>&1 | Out-Null
    & expand.exe $Path -F:*.xml $target 2>&1 | Out-Null
  } else {
    & expand.exe $Path -F:*.mum $target 2>&1 | Out-Null
  }

  foreach ($cab in Get-ChildItem -LiteralPath $target -Recurse -Filter '*.cab' -File -ErrorAction SilentlyContinue) {
    Expand-UpdateMetadata -Path $cab.FullName -Destination $Destination -Depth ($Depth + 1)
  }
}

function Get-CabOrMsuHints {
  param([Parameter(Mandatory)][string]$Path,[string]$Kb)
  $tmp = Join-Path $env:TEMP ("buildwim-pkg-hints-{0}" -f ([guid]::NewGuid().ToString('N')))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    Expand-UpdateMetadata -Path $Path -Destination $tmp
    $items = foreach ($mum in Get-ChildItem -LiteralPath $tmp -Recurse -Filter '*.mum' -File -ErrorAction SilentlyContinue) {
      try { [xml]$xml = Get-Content -LiteralPath $mum.FullName -Raw -ErrorAction Stop } catch { continue }
      $pkg = $xml.assembly.package
      $id = $xml.assembly.assemblyIdentity
      if (-not $id) { continue }
      $identityName = [string]$id.name
      if ($identityName -notmatch '^(Package_for_|Package_|Microsoft-Windows-)') { continue }
      if ($identityName -match '^Language-') { continue }
      if ($Kb -and $pkg -and $pkg.identifier -and ([string]$pkg.identifier -ne [string]$Kb)) { continue }
      [pscustomobject]@{
        Mum = $mum.Name
        PackageIdentifier = if ($pkg -and $pkg.identifier) { [string]$pkg.identifier } else { $null }
        IdentityName = $identityName
        IdentityVersion = [string]$id.version
      }
    }
    return @($items | Sort-Object IdentityName,IdentityVersion -Unique)
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Get-UpdateSidecarMetadata {
  param([Parameter(Mandatory)][string]$Path)
  $metadataPath = "$Path.metadata.json"
  if (-not (Test-Path -LiteralPath $metadataPath)) { return $null }
  try { return (Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-ExpectedUpdatePackages {
  param([string]$UpdatesDir,[string]$ExpectedSafeOsKb,[string]$ExpectedSafeOsVersion)
  if (-not (Test-Path -LiteralPath $UpdatesDir)) { return @() }
  $files = @(Get-ChildItem -LiteralPath $UpdatesDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^(?i)\.(cab|msu)$' })
  foreach ($file in $files) {
    $name = $file.Name
    $metadata = Get-UpdateSidecarMetadata -Path $file.FullName
    $kb = ([regex]::Match($name,'(?i)kb\d+')).Value.ToUpperInvariant()
    if (-not $kb -and $metadata -and $metadata.KB) { $kb = ([string]$metadata.KB).ToUpperInvariant() }
    $classification = 'Security'
    $packageType = if ($metadata -and $metadata.PackageType) { [string]$metadata.PackageType } else { $null }
    if ($name -match '(?i)safeos|safe-os|winre' -or ($kb -eq $ExpectedSafeOsKb) -or $packageType -match '(?i)SafeOS') { $classification = 'SafeOSDU' }
    elseif ($name -match '(?i)ndp|dotnet|\.net' -or $packageType -match '(?i)DotNet') { $classification = 'DotNetCU' }
    elseif ($name -match '(?i)servicingstack|ssu' -or $packageType -match '(?i)SSU') { $classification = 'SSU' }
    elseif ($name -match '(?i)cumulative|rollup|lcu' -or $name -match '(?i)windows11\.0-kb' -or $packageType -match '(?i)LCU') { $classification = 'LCU' }
    $build = if ($metadata -and $metadata.Build) { [string]$metadata.Build } else { $null }
    $hints = @()
    try { $hints = @(Get-CabOrMsuHints -Path $file.FullName -Kb $kb) } catch { }
    if ($classification -eq 'SafeOSDU' -and $hints.Count -eq 0) {
      $hints = @([pscustomobject]@{ Mum='expected'; PackageIdentifier=$ExpectedSafeOsKb; IdentityName='Package_for_SafeOSDU'; IdentityVersion=($ExpectedSafeOsVersion + '.1.7') })
    }
    if ($classification -eq 'LCU' -and $hints.Count -eq 0 -and $build) {
      $parts = $build -split '\.'
      $rollupVersion = if ($parts.Count -ge 2) { "26100.$($parts[-1])" } else { $build }
      $hints = @([pscustomobject]@{ Mum='metadata'; PackageIdentifier=$kb; IdentityName='Package_for_RollupFix'; IdentityVersion=$rollupVersion })
    }
    [pscustomobject]@{
      FileName = $file.Name
      Path = $file.FullName
      Bytes = $file.Length
      SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
      KB = $kb
      Classification = $classification
      Build = $build
      Metadata = $metadata
      Hints = $hints
    }
  }
}

function Test-PackagePresent {
  param([string[]]$PackageIdentities,[object]$Expected)
  $foundIdentities = New-Object 'System.Collections.Generic.List[string]'
  foreach ($identity in @($PackageIdentities)) {
    $id = [string]$identity
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $hit = $false
    if ($Expected.KB -and $id.IndexOf([string]$Expected.KB,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true }
    foreach ($hint in @($Expected.Hints)) {
      $hasName = -not [string]::IsNullOrWhiteSpace([string]$hint.IdentityName)
      $hasVersion = -not [string]::IsNullOrWhiteSpace([string]$hint.IdentityVersion)
      $nameHit = $hasName -and $id.IndexOf([string]$hint.IdentityName,[StringComparison]::OrdinalIgnoreCase) -ge 0
      $versionHit = $hasVersion -and $id.IndexOf([string]$hint.IdentityVersion,[StringComparison]::OrdinalIgnoreCase) -ge 0
      if (($hasName -and $hasVersion -and $nameHit -and $versionHit) -or ($hasName -and -not $hasVersion -and $nameHit) -or ($hasVersion -and -not $hasName -and $versionHit)) { $hit = $true }
    }
    if ($Expected.Classification -eq 'SafeOSDU' -and $id -match 'Package_for_SafeOSDU' -and $id -match [regex]::Escape($ExpectedSafeOsVersion)) { $hit = $true }
    if ($Expected.Classification -eq 'LCU' -and $Expected.Build) {
      $parts = ([string]$Expected.Build) -split '\.'
      $rollupVersion = if ($parts.Count -ge 2) { "26100.$($parts[-1])" } else { [string]$Expected.Build }
      if ($id -match 'Package_for_RollupFix' -and $id -match [regex]::Escape($rollupVersion)) { $hit = $true }
    }
    if ($Expected.Classification -eq 'DotNetCU' -and $id -match '(?i)DotNetRollup|NetFx|NDP') { $hit = $true }
    if ($hit -and (-not $foundIdentities.Contains($id))) { $foundIdentities.Add($id) | Out-Null }
  }
  return @($foundIdentities.ToArray())
}

function Read-DefenderPackageXmlState {
  param([Parameter(Mandatory)][string]$PackageXmlPath,[string]$Source)
  $result = [ordered]@{
    Source = $Source
    PackageXml = $PackageXmlPath
    SignatureVersion = $null
    EngineVersion = $null
    PlatformVersion = $null
  }
  try {
    [xml]$xml = Get-Content -LiteralPath $PackageXmlPath -Raw
    if ($xml.packageinfo.versions.signatures) { $result.SignatureVersion = [string]$xml.packageinfo.versions.signatures }
    if ($xml.packageinfo.versions.engine) { $result.EngineVersion = [string]$xml.packageinfo.versions.engine }
    if ($xml.packageinfo.versions.platform) { $result.PlatformVersion = [string]$xml.packageinfo.versions.platform }
  } catch { }
  return [pscustomobject]$result
}

function Get-ExpectedDefenderState {
  param([string]$DefenderDir,[Parameter(Mandatory)][string]$ScratchRoot)
  if (-not $DefenderDir -or -not (Test-Path -LiteralPath $DefenderDir)) { return $null }

  $xml = @(Get-ChildItem -LiteralPath $DefenderDir -Recurse -Filter 'package-defender.xml' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
  if ($xml.Count -gt 0) { return Read-DefenderPackageXmlState -PackageXmlPath $xml[0].FullName -Source 'DefenderDir package-defender.xml' }

  $cab = @(Get-ChildItem -LiteralPath $DefenderDir -Recurse -Filter 'defender-dism*.cab' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
  if ($cab.Count -eq 0) { return $null }

  $extractDir = Join-Path $ScratchRoot ('ExpectedDefender-' + ([guid]::NewGuid().ToString('N')))
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  & expand.exe $cab[0].FullName -F:package-defender.xml $extractDir 2>&1 | Out-Null
  $expandedXml = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'package-defender.xml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $expandedXml) { return $null }
  $state = Read-DefenderPackageXmlState -PackageXmlPath $expandedXml.FullName -Source $cab[0].FullName
  $state | Add-Member -NotePropertyName CabSHA256 -NotePropertyValue ((Get-FileHash -LiteralPath $cab[0].FullName -Algorithm SHA256).Hash) -Force
  return $state
}

function Get-DefenderState {
  param([Parameter(Mandatory)][string]$MountDir)
  $candidates = @(
    (Join-Path $MountDir 'Windows\Temp\package-defender.xml'),
    (Join-Path $MountDir 'ProgramData\Microsoft\Windows Defender\Definition Updates\Updates\package-defender.xml')
  )
  $xmlPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  $platformDir = Join-Path $MountDir 'ProgramData\Microsoft\Windows Defender\Platform'
  $updatesDir = Join-Path $MountDir 'ProgramData\Microsoft\Windows Defender\Definition Updates\Updates'
  $result = [ordered]@{
    Source = 'Mounted image'
    PackageXml = $xmlPath
    UpdatesDirExists = [bool](Test-Path -LiteralPath $updatesDir)
    PlatformDirExists = [bool](Test-Path -LiteralPath $platformDir)
    SignatureVersion = $null
    EngineVersion = $null
    PlatformVersion = $null
  }
  if ($xmlPath) {
    $parsed = Read-DefenderPackageXmlState -PackageXmlPath $xmlPath -Source 'Mounted image'
    $result.SignatureVersion = $parsed.SignatureVersion
    $result.EngineVersion = $parsed.EngineVersion
    $result.PlatformVersion = $parsed.PlatformVersion
  }
  return [pscustomobject]$result
}

function Test-DefenderStateMatchesExpected {
  param([Parameter(Mandatory)]$Actual,$Expected)
  if (-not ($Actual.PackageXml -and $Actual.UpdatesDirExists -and $Actual.PlatformDirExists)) { return $false }
  if (-not $Expected) { return $true }
  foreach ($property in @('SignatureVersion','EngineVersion','PlatformVersion')) {
    $expectedValue = [string]$Expected.$property
    if (-not [string]::IsNullOrWhiteSpace($expectedValue) -and ([string]$Actual.$property -ne $expectedValue)) { return $false }
  }
  return $true
}

$stamp = Get-Date -Format yyyyMMdd-HHmmss
$work = Join-Path $env:TEMP "BuildWimPatchState-$stamp"
$wim = Join-Path $work 'install-exported-from-swm.wim'
$imageMount = Join-Path $work 'image'
$winreMount = Join-Path $work 'winre'
$scratch = Join-Path $work 'scratch'
New-Item -ItemType Directory -Force -Path $work,$imageMount,$winreMount,$scratch | Out-Null
if (-not $ReportPath) { $ReportPath = Join-Path $work 'buildwim-patch-state.json' }

$mountedImage = $false
$mountedWinre = $false
try {
  $swm = Join-Path $OutputDir 'install.swm'
  $finalWim = Join-Path $OutputDir 'install.wim'
  if (Test-Path -LiteralPath $swm) {
    $sourceKind = 'SWM'
    $sourceImage = $swm
    $swmPattern = Join-Path $OutputDir 'install*.swm'
    Write-Host "EXPORT_FINAL_SWM_TO_WIM=$wim"
    Invoke-DismChecked @('/English','/Export-Image',"/SourceImageFile:$swm",("/SWMFile:{0}" -f $swmPattern),'/SourceIndex:1',"/DestinationImageFile:$wim",'/Compress:Max','/CheckIntegrity')
  } elseif (Test-Path -LiteralPath $finalWim) {
    $sourceKind = 'WIM'
    $sourceImage = $finalWim
    $wim = $finalWim
  } else {
    throw "No final install.swm or install.wim found in: $OutputDir"
  }

  New-Item -ItemType Directory -Force -Path $imageMount,$winreMount,$scratch | Out-Null
  Write-Host "MOUNT_FINAL_IMAGE=$imageMount"
  Invoke-DismChecked @('/English','/Mount-Wim',"/WimFile:$wim",'/Index:1',"/MountDir:$imageMount",'/ReadOnly',"/ScratchDir:$scratch")
  $mountedImage = $true

  $mainPackages = @(Get-PackageIdentitiesFromMountedImage -MountDir $imageMount -ScratchDir $scratch)
  $registry = Get-OfflineRegistryValues -MountDir $imageMount
  $winrePath = Join-Path $imageMount 'Windows\System32\Recovery\winre.wim'
  $winrePackages = @()
  $winreVersion = $null
  if (Test-Path -LiteralPath $winrePath) {
    $winreVersion = Get-WinReImageVersion -WimFile $winrePath
    New-Item -ItemType Directory -Force -Path $winreMount,$scratch | Out-Null
    Write-Host "MOUNT_FINAL_WINRE=$winreMount"
    Invoke-DismChecked @('/English','/Mount-Wim',"/WimFile:$winrePath",'/Index:1',"/MountDir:$winreMount",'/ReadOnly',"/ScratchDir:$scratch")
    $mountedWinre = $true
    $winrePackages = @(Get-PackageIdentitiesFromMountedImage -MountDir $winreMount -ScratchDir $scratch)
  }

  $expected = @(Get-ExpectedUpdatePackages -UpdatesDir $UpdatesDir -ExpectedSafeOsKb $ExpectedSafeOsKb -ExpectedSafeOsVersion $ExpectedSafeOsVersion)
  $checks = foreach ($pkg in $expected) {
    $target = if ($pkg.Classification -eq 'SafeOSDU') { 'WinRE' } else { 'Main image' }
    $idents = if ($pkg.Classification -eq 'SafeOSDU') { $winrePackages } else { $mainPackages }
    $matches = @(Test-PackagePresent -PackageIdentities $idents -Expected $pkg)
    [pscustomobject]@{
      KB = $pkg.KB
      Classification = $pkg.Classification
      FileName = $pkg.FileName
      Target = $target
      Status = if ($matches.Count -gt 0) { 'INSTALLED' } else { 'NEEDS_UPDATE_OR_NOT_PROVEN' }
      MatchedIdentities = $matches
      ExpectedHintNames = @($pkg.Hints | ForEach-Object { $_.IdentityName } | Where-Object { $_ } | Sort-Object -Unique)
      ExpectedHintVersions = @($pkg.Hints | ForEach-Object { $_.IdentityVersion } | Where-Object { $_ } | Sort-Object -Unique)
      ExpectedBuild = $pkg.Build
      SHA256 = $pkg.SHA256
    }
  }

  $expectedDefenderState = Get-ExpectedDefenderState -DefenderDir $DefenderDir -ScratchRoot $scratch
  $defenderState = Get-DefenderState -MountDir $imageMount
  $defenderStatus = if (Test-DefenderStateMatchesExpected -Actual $defenderState -Expected $expectedDefenderState) { 'INSTALLED' } else { 'NEEDS_UPDATE_OR_NOT_PROVEN' }

  $verdict = if ((@($checks | Where-Object { $_.Status -ne 'INSTALLED' }).Count -eq 0) -and $defenderStatus -eq 'INSTALLED' -and (Test-Path -LiteralPath $winrePath)) { 'OK' } else { 'ACTION_NEEDED_OR_NOT_PROVEN' }

  $report = [pscustomobject]@{
    Verdict = $verdict
    SourceKind = $sourceKind
    SourceImage = $sourceImage
    OutputDir = $OutputDir
    ExportedWim = $wim
    ImageRegistry = $registry
    MainPackageCount = $mainPackages.Count
    WinRePath = if (Test-Path -LiteralPath $winrePath) { $winrePath } else { $null }
    WinReImageVersion = $winreVersion
    WinRePackageCount = $winrePackages.Count
    Defender = [pscustomobject]@{
      Status = $defenderStatus
      KB = 'KB2267602'
      SignatureVersion = $defenderState.SignatureVersion
      EngineVersion = $defenderState.EngineVersion
      PlatformVersion = $defenderState.PlatformVersion
      PackageXml = $defenderState.PackageXml
      UpdatesDirExists = $defenderState.UpdatesDirExists
      PlatformDirExists = $defenderState.PlatformDirExists
      Expected = $expectedDefenderState
      MatchesExpected = (Test-DefenderStateMatchesExpected -Actual $defenderState -Expected $expectedDefenderState)
    }
    Checks = @($checks)
    ReportPath = $ReportPath
    TestedAt = (Get-Date).ToString('o')
  }

  $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

  Write-Host "BUILDWIM_PATCH_STATE=$verdict"
  Write-Host "REPORT_JSON=$ReportPath"
  Write-Host "WINRE_IMAGE_VERSION=$winreVersion"
  Write-Host "DEFENDER_STATUS=$defenderStatus SIGNATURE=$($defenderState.SignatureVersion) ENGINE=$($defenderState.EngineVersion) PLATFORM=$($defenderState.PlatformVersion)"
  if ($expectedDefenderState) { Write-Host "DEFENDER_EXPECTED SIGNATURE=$($expectedDefenderState.SignatureVersion) ENGINE=$($expectedDefenderState.EngineVersion) PLATFORM=$($expectedDefenderState.PlatformVersion) SOURCE=$($expectedDefenderState.Source)" }
  foreach ($check in $checks) {
    Write-Host ("{0} {1} {2} => {3}" -f $check.Target,$check.Classification,$check.KB,$check.Status)
    foreach ($match in @($check.MatchedIdentities)) { Write-Host "  MATCH=$match" }
  }

  if ($FailIfMissing -and $verdict -ne 'OK') { exit 2 }
} finally {
  if ($mountedWinre) { try { Invoke-DismChecked @('/English','/Unmount-Wim',"/MountDir:$winreMount",'/Discard') } catch { Write-Warning $_ } }
  if ($mountedImage) { try { Invoke-DismChecked @('/English','/Unmount-Wim',"/MountDir:$imageMount",'/Discard') } catch { Write-Warning $_ } }
  try { Invoke-DismChecked @('/English','/Cleanup-Wim') } catch { Write-Warning $_ }
}
