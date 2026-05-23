<#
.SYNOPSIS
  Resolves Windows 11 install media from Microsoft ESD catalogs and exports Windows 11 Pro to install.wim.

.DESCRIPTION
  BuildWIM media-provider fallback. It refreshes Microsoft product catalogs, finds a matching
  Windows 11 ESD, downloads it to a cache folder, verifies catalog hashes when available,
  exports the requested edition to a single-index WIM, and leaves install.wim in the input folder.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$OutputDirectory = 'C:\BuildWimV2\Input',
  [string]$WindowsVersion = '25H2',
  [ValidateSet('x64','x86','arm64','amd64')]
  [string]$Architecture = 'x64',
  [string]$Language = 'English International',
  [ValidateSet('Retail','Volume')]
  [string]$License = 'Retail',
  [string]$EditionName = 'Windows 11 Pro',
  [switch]$Force,
  [switch]$PlanOnly,
  [switch]$RefreshCatalogOnly,
  [switch]$ListOnly,
  [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "[BuildWIM ESD] $Message" -ForegroundColor Cyan }

function Test-TrustedMicrosoftDownloadUrl {
  param([AllowNull()] [string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
  [uri]$uri = $null
  if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
  $hostName = $uri.Host.ToLowerInvariant()
  foreach ($suffix in @('microsoft.com','download.microsoft.com','fe3.delivery.mp.microsoft.com','windowsupdate.com')) {
    if (($uri.Scheme -eq 'https') -and ($hostName -eq $suffix -or $hostName.EndsWith(".$suffix", [StringComparison]::OrdinalIgnoreCase))) { return $true }
  }

  # Microsoft ESD FilePath entries in the official Media Creation Tool catalogs
  # are commonly http://dl.delivery.mp.microsoft.com/... URLs. Accept only those
  # tightly-scoped delivery hosts and rely on catalog SHA1/SHA256 verification
  # after download before the WIM export.
  foreach ($suffix in @('delivery.mp.microsoft.com','dl.delivery.mp.microsoft.com')) {
    if (($uri.Scheme -in @('http','https')) -and ($hostName -eq $suffix -or $hostName.EndsWith(".$suffix", [StringComparison]::OrdinalIgnoreCase))) { return $true }
  }
  return $false
}

function Convert-BuildWimArchitecture {
  param([string]$Value)
  switch -Regex ($Value) {
    '^(x64|amd64)$' { 'amd64'; break }
    '^arm64$' { 'arm64'; break }
    '^x86$' { 'x86'; break }
    default { $Value }
  }
}

function Resolve-LanguageTokens {
  param([string]$Value)
  $tokens = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrWhiteSpace($Value)) { $tokens.Add('en-gb') | Out-Null; return @($tokens.ToArray()) }
  $v = $Value.Trim().ToLowerInvariant()
  $tokens.Add($v) | Out-Null
  if ($v -match 'international') { $tokens.Add('en-gb') | Out-Null; $tokens.Add('english international') | Out-Null }
  elseif ($v -eq 'english') { $tokens.Add('en-us') | Out-Null }
  elseif ($v -match 'swedish|svenska') { $tokens.Add('sv-se') | Out-Null }
  return @($tokens.ToArray() | Select-Object -Unique)
}

function Get-Microsoft25H2CatalogUrl {
  $uri = 'https://fe3.delivery.mp.microsoft.com/UpdateMetadataService/updates/search/v1/bydeviceinfo'
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) BuildWIM/2.0 MediaResolver'
  $deviceAttributes = @(
    'MediaBranch=br_release','App=Setup360','LCUVersion=10.0.28000.1340',
    'OfflineAttributesOnly=0','MediaVersion=10.0.28000.1340','AppVer=10.0',
    'PreviewBuilds=1','CompositionEditionId=Enterprise','CurrentBranch=br_release',
    'OSArchitecture=AMD64','InstallationType=Client','FlightingBranchName=CanaryChannel',
    'DUInternal=0','FlightRing=External','BuildFlighting=1','HotPatchEligible=0',
    'OSSKUId=48','IsoCountryShortCode=US','OSVersion=10.0.26100.1',
    'AttrDataVer=338','EditionId=Professional','DUScan=1'
  ) -join ';'

  foreach ($targetVersion in @('26200.0.0.0','26100.0.0.0')) {
    try {
      $body = @{ Products = "PN=Windows.Products.Cab.amd64&V=$targetVersion"; DeviceAttributes = $deviceAttributes } | ConvertTo-Json -Compress
      $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -Headers @{ 'Content-Type'='application/json'; Accept='*/*'; 'User-Agent'=$ua } -TimeoutSec 60
      if ($response -is [array] -and $response.Count -gt 0 -and $response[0].FileLocations) { return [string]$response[0].FileLocations[0].Url }
      if ($response.FileLocations) { return [string]$response.FileLocations[0].Url }
      if ($response.Updates -and $response.Updates.Count -gt 0 -and $response.Updates[0].FileLocations) { return [string]$response.Updates[0].FileLocations[0].Url }
    } catch { }
  }
  throw 'Could not resolve Windows 11 25H2 catalog URL from Microsoft metadata service.'
}

function Get-CatalogSources {
  $sources = @(
    [pscustomobject]@{ Name='22631.2861-win11-23h2.xml'; Version='23H2'; Url='https://download.microsoft.com/download/6/2/b/62b47bc5-1b28-4bfa-9422-e7a098d326d4/products_win11_20231208.cab' },
    [pscustomobject]@{ Name='26100.4349-win11-24h2.xml'; Version='24H2'; Url='https://download.microsoft.com/download/8e0c23e7-ddc2-45c4-b7e1-85a808b408ee/Products-Win11-24H2-6B.cab' }
  )
  if ($WindowsVersion -match '25H2|26200') {
    $sources += [pscustomobject]@{ Name='26200-win11-25h2.xml'; Version='25H2'; Url=(Get-Microsoft25H2CatalogUrl) }
  }
  return @($sources | Where-Object { $_.Version -eq $WindowsVersion -or $WindowsVersion -match $_.Version -or $_.Name -match [regex]::Escape($WindowsVersion) })
}

function Update-BuildWimEsdCatalogs {
  param([Parameter(Mandatory)] [string]$CatalogPath)
  if (-not (Test-Path -LiteralPath $CatalogPath)) { New-Item -ItemType Directory -Path $CatalogPath -Force | Out-Null }
  $results = New-Object System.Collections.Generic.List[object]
  foreach ($source in @(Get-CatalogSources)) {
    if (-not (Test-TrustedMicrosoftDownloadUrl -Url $source.Url)) { throw "Refusing untrusted catalog URL: $($source.Url)" }
    $dest = Join-Path $CatalogPath $source.Name
    if ((Test-Path -LiteralPath $dest) -and -not $Force) { $results.Add([pscustomobject]@{ Name=$source.Name; Path=$dest; Source=$source.Url; Cached=$true }) | Out-Null; continue }
    if ($PlanOnly) { $results.Add([pscustomobject]@{ Name=$source.Name; Path=$dest; Source=$source.Url; Cached=$false; Planned=$true }) | Out-Null; continue }

    Write-Step "Refreshing catalog $($source.Name)"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
      $cab = Join-Path $tmp 'products.cab'
      Invoke-WebRequest -Uri $source.Url -OutFile $cab -UseBasicParsing -ErrorAction Stop
      & expand.exe -R $cab -F:* $tmp | Out-Null
      $xml = Get-ChildItem -LiteralPath $tmp -Filter '*.xml' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
      if (-not $xml) { throw "No XML extracted from $($source.Url)" }
      Copy-Item -LiteralPath $xml.FullName -Destination $dest -Force
      $results.Add([pscustomobject]@{ Name=$source.Name; Path=$dest; Source=$source.Url; Cached=$false }) | Out-Null
    } finally {
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  return @($results.ToArray())
}

function Get-NodeValue {
  param([Parameter(Mandatory)] [object]$Node, [Parameter(Mandatory)] [string[]]$Names)
  foreach ($name in $Names) {
    $prop = $Node.PSObject.Properties[$name]
    if ($prop -and $null -ne $prop.Value -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) { return [string]$prop.Value }
  }
  return $null
}

function Convert-OsBuildToVersion {
  param([string]$Build)
  switch ($Build) {
    '22631' { '23H2' }
    '26100' { '24H2' }
    '26200' { '25H2' }
    default { $null }
  }
}

function Get-EsdCatalogEntries {
  param([Parameter(Mandatory)] [string]$CatalogPath)
  $arch = Convert-BuildWimArchitecture -Value $Architecture
  $languageTokens = @(Resolve-LanguageTokens -Value $Language)
  $entries = New-Object System.Collections.Generic.List[object]

  foreach ($file in @(Get-ChildItem -LiteralPath $CatalogPath -Filter '*.xml' -File -ErrorAction SilentlyContinue)) {
    [xml]$xml = Get-Content -LiteralPath $file.FullName -Raw
    $nodes = @($xml.MCT.Catalogs.Catalog.PublishedMedia.Files.File)
    foreach ($node in $nodes) {
      $fileName = Get-NodeValue -Node $node -Names @('FileName','Filename')
      if ($fileName -notmatch '(?i)\.esd$') { continue }
      $build = try { $fileName.Substring(0,5) } catch { $null }
      $version = Convert-OsBuildToVersion -Build $build
      if (-not $version) { continue }
      if ($WindowsVersion -and $version -ne $WindowsVersion -and $build -ne $WindowsVersion) { continue }
      $nodeArchRaw = Get-NodeValue -Node $node -Names @('Architecture')
      $nodeArch = if ($nodeArchRaw -match '(?i)x64|amd64') { 'amd64' } elseif ($nodeArchRaw -match '(?i)arm64') { 'arm64' } elseif ($nodeArchRaw -match '(?i)x86') { 'x86' } else { '' }
      if ($nodeArch -ne $arch) { continue }
      $activation = if ($fileName -match '(?i)clientconsumer_ret') { 'Retail' } elseif ($fileName -match '(?i)clientbusiness_vol') { 'Volume' } else { '' }
      if ($activation -ne $License) { continue }
      $langCode = Get-NodeValue -Node $node -Names @('LanguageCode','Language')
      $langName = Get-NodeValue -Node $node -Names @('Language','LanguageCode')
      $langText = "$langCode $langName".ToLowerInvariant()
      $languageOk = $false
      foreach ($token in $languageTokens) { if ($langText -like "*$token*") { $languageOk = $true; break } }
      if (-not $languageOk) { continue }
      $url = Get-NodeValue -Node $node -Names @('FilePath','Url','URL')
      if (-not (Test-TrustedMicrosoftDownloadUrl -Url $url)) { continue }
      $entries.Add([pscustomobject]@{
        OperatingSystem = "Windows 11 $version"
        OSVersion = $version
        OSBuild = $build
        Architecture = $nodeArch
        LanguageCode = $langCode
        Language = $langName
        License = $activation
        Size = Get-NodeValue -Node $node -Names @('Size')
        Sha1 = Get-NodeValue -Node $node -Names @('Sha1','SHA1')
        Sha256 = Get-NodeValue -Node $node -Names @('Sha256','SHA256')
        FileName = $fileName
        Url = $url
        CatalogPath = $file.FullName
      }) | Out-Null
    }
  }
  $seen = @{}
  $unique = New-Object System.Collections.Generic.List[object]
  foreach ($entry in @($entries.ToArray() | Sort-Object OSBuild,FileName -Descending)) {
    $key = if ($entry.Url) { [string]$entry.Url } else { [string]$entry.FileName }
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $unique.Add($entry) | Out-Null
  }
  return @($unique.ToArray())
}

function Test-EsdHash {
  param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [object]$Entry)
  if ($Entry.Sha256) {
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($hash -ne ([string]$Entry.Sha256)) { throw "ESD SHA256 mismatch for $Path" }
    return
  }
  if ($Entry.Sha1) {
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash
    if ($hash -ne ([string]$Entry.Sha1)) { throw "ESD SHA1 mismatch for $Path" }
  }
}

function Save-EsdDownload {
  param([Parameter(Mandatory)] [object]$Entry, [Parameter(Mandatory)] [string]$Destination)
  if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
  $cacheName = "BuildWIM-{0}-{1}-{2}-{3}.esd" -f $Entry.OSBuild,$Entry.LanguageCode,$Entry.License,$Entry.Architecture
  $cacheName = ($cacheName -replace '[^A-Za-z0-9._-]', '_')
  $path = Join-Path $Destination $cacheName
  if ((Test-Path -LiteralPath $path) -and -not $Force) {
    $existing = Get-Item -LiteralPath $path
    [int64]$expectedSize = 0
    if ([int64]::TryParse([string]$Entry.Size, [ref]$expectedSize) -and $expectedSize -gt 0 -and $existing.Length -ne $expectedSize) {
      Write-Step "Cached ESD size differs from catalog; re-downloading $($Entry.FileName)"
      Remove-Item -LiteralPath $path -Force
    } else {
      Test-EsdHash -Path $path -Entry $Entry
      Write-Step "Using cached verified ESD $($Entry.FileName)"
      return $path
    }
  }
  if ($PlanOnly) { return $path }
  Write-Step "Downloading ESD $($Entry.FileName)"
  $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  try {
    if ($bits) { Start-BitsTransfer -Source ([string]$Entry.Url) -Destination $path -ErrorAction Stop }
    elseif ($curl) { & $curl.Source --fail --location --retry 3 --output $path ([string]$Entry.Url); if ($LASTEXITCODE -ne 0) { throw "curl.exe failed with exit code $LASTEXITCODE" } }
    else { Invoke-WebRequest -Uri ([string]$Entry.Url) -OutFile $path -UseBasicParsing -TimeoutSec 7200 }
  } catch {
    if ($curl) {
      Write-Step "BITS download failed; falling back to curl.exe: $($_.Exception.Message)"
      & $curl.Source --fail --location --retry 3 --output $path ([string]$Entry.Url)
      if ($LASTEXITCODE -ne 0) { throw "curl.exe failed with exit code $LASTEXITCODE" }
    } else {
      if (-not $bits) { throw }
      Write-Step "BITS download failed; falling back to Invoke-WebRequest: $($_.Exception.Message)"
      Invoke-WebRequest -Uri ([string]$Entry.Url) -OutFile $path -UseBasicParsing -TimeoutSec 7200
    }
  }
  Test-EsdHash -Path $path -Entry $Entry
  return $path
}

function Get-WimImageIndex {
  param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Name)
  $out = & dism.exe /English /Get-WimInfo /WimFile:$Path 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "DISM /Get-WimInfo failed for $Path`n$out" }
  $current = $null
  foreach ($line in ($out -split "`r?`n")) {
    if ($line -match '^Index\s*:\s*(\d+)') { $current = [int]$matches[1]; continue }
    if ($current -and $line -match '^Name\s*:\s*(.+)$') {
      if ($matches[1].Trim() -eq $Name -or $matches[1].Trim() -like "*$Name*") { return $current }
    }
  }
  throw "Edition '$Name' was not found in $Path."
}

function Export-EsdToWim {
  param([Parameter(Mandatory)] [string]$EsdPath, [Parameter(Mandatory)] [string]$WimPath, [Parameter(Mandatory)] [int]$Index)
  if ($PlanOnly) { return }
  if (Test-Path -LiteralPath $WimPath) { Remove-Item -LiteralPath $WimPath -Force }
  Write-Step "Exporting $EditionName index $Index to $WimPath"
  & dism.exe /English /Export-Image /SourceImageFile:$EsdPath /SourceIndex:$Index /DestinationImageFile:$WimPath /Compress:Max /CheckIntegrity | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "DISM /Export-Image failed with exit code $LASTEXITCODE" }
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
$catalogPath = Join-Path $OutputDirectory 'Catalogs'
$cachePath = Join-Path $OutputDirectory 'MediaCache'
$wimPath = Join-Path $OutputDirectory 'install.wim'

$catalogs = @(Update-BuildWimEsdCatalogs -CatalogPath $catalogPath)
if ($RefreshCatalogOnly) {
  if ($AsJson) { $catalogs | ConvertTo-Json -Depth 5 } else { $catalogs | Format-Table Name,Path,Cached,Planned -AutoSize }
  exit 0
}

$entries = @(Get-EsdCatalogEntries -CatalogPath $catalogPath)
if ($entries.Count -eq 0) { throw "No matching Windows 11 ESD found for Version=$WindowsVersion Architecture=$Architecture Language=$Language License=$License" }
if ($ListOnly) {
  if ($AsJson) { $entries | ConvertTo-Json -Depth 5 }
  else { $entries | Select-Object OperatingSystem,OSBuild,Architecture,LanguageCode,License,Size,FileName,Url | Format-Table -AutoSize }
  exit 0
}

$selected = $entries[0]
Write-Step "Selected $($selected.OperatingSystem) $($selected.Architecture) $($selected.LanguageCode) $($selected.License): $($selected.FileName)"

if ($PlanOnly) {
  $plannedCacheName = ("BuildWIM-{0}-{1}-{2}-{3}.esd" -f $selected.OSBuild,$selected.LanguageCode,$selected.License,$selected.Architecture) -replace '[^A-Za-z0-9._-]', '_'
  $plan = [pscustomobject]@{ Selected=$selected; PlannedEsdPath=(Join-Path $cachePath $plannedCacheName); PlannedWimPath=$wimPath; PreferredReason='Microsoft ESD catalog is the preferred non-local source: catalog-filtered, hash-verified, BITS-resumable, and exported directly to the single Windows 11 Pro WIM BuildWIM needs.' }
  if ($AsJson) { $plan | ConvertTo-Json -Depth 5 } else { $plan | Format-List }
  exit 0
}

$esdPath = Save-EsdDownload -Entry $selected -Destination $cachePath
$index = Get-WimImageIndex -Path $esdPath -Name $EditionName
Export-EsdToWim -EsdPath $esdPath -WimPath $wimPath -Index $index

$metadata = [ordered]@{
  Provider = 'MicrosoftEsd'
  CreatedAt = (Get-Date).ToString('o')
  SourceEsd = $esdPath
  WimPath = $wimPath
  EditionName = $EditionName
  SourceIndex = $index
  Selected = $selected
  WimSHA256 = (Get-FileHash -LiteralPath $wimPath -Algorithm SHA256).Hash
}
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$wimPath.media.json" -Encoding UTF8
Write-Host "BUILDWIM_MEDIA_WIM=$wimPath" -ForegroundColor Green
