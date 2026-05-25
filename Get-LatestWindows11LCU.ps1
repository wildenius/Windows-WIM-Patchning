<#
.SYNOPSIS
  Downloads the latest non-preview Windows 11 cumulative update, .NET Framework cumulative update, or Safe OS Dynamic Update from Microsoft Update Catalog.

.DESCRIPTION
  Searches Microsoft Update Catalog, selects the newest matching Windows 11 LCU for a target
  Windows version and architecture, extracts the real .msu download URL from DownloadDialog.aspx,
  and downloads it to the BuildWIM Updates folder.

  Default LCU behavior intentionally excludes Preview updates and .NET cumulative updates. Use -PackageType DotNet for the latest .NET Framework cumulative update, or -PackageType SafeOS for the latest Safe OS Dynamic Update used to service WinRE.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$WindowsVersion = '25H2',

  [ValidateSet('x64','x86','arm64')]
  [string]$Architecture = 'x64',

  [string]$OutputPath = 'C:\BuildWimV2\Updates',

  [switch]$IncludePreview,

  [switch]$Force,

  [switch]$MetadataOnly,

  [ValidateSet('LCU','DotNet','SafeOS')]
  [string]$PackageType = 'LCU'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
  param([string]$Message)
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-FileSha256Safe {
  param([string]$Path)
  if ($Path -and (Test-Path -LiteralPath $Path)) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
  return $null
}


function Test-TrustedMicrosoftDownloadUrl {
  param([AllowNull()] [string]$Url)

  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
  [uri]$uri = $null
  if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
  if ($uri.Scheme -ne 'https') { return $false }

  $uriHost = $uri.Host.ToLowerInvariant()
  $trustedSuffixes = @(
    'microsoft.com',
    'catalog.update.microsoft.com',
    'download.microsoft.com',
    'go.microsoft.com',
    'delivery.mp.microsoft.com',
    'dl.delivery.mp.microsoft.com',
    'catalog.sf.dl.delivery.mp.microsoft.com',
    'download.windowsupdate.com',
    'windowsupdate.com'
  )
  foreach ($suffix in $trustedSuffixes) {
    if ($uriHost -eq $suffix -or $uriHost.EndsWith(".$suffix", [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Get-PackageMagic {
  param([Parameter(Mandatory)] [string]$Path)

  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    if ($stream.Length -lt 4) { return $false }
    $buffer = New-Object byte[] 4
    [void]$stream.Read($buffer, 0, 4)
    $magic = [System.Text.Encoding]::ASCII.GetString($buffer)
    return $magic
  } finally {
    $stream.Dispose()
  }
}

function Test-MicrosoftPackageContainer {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Magic,
    [string]$Context = 'downloaded package'
  )

  if ($Magic -eq 'MSCF') {
    $temp = Join-Path $env:TEMP ("BuildWIM-MSU-validate-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
      $expandExe = Join-Path $env:SystemRoot 'System32\expand.exe'
      if (-not (Test-Path -LiteralPath $expandExe)) { $expandExe = 'expand.exe' }

      $output = & $expandExe -f:* $Path $temp 2>&1
      if ($LASTEXITCODE -ne 0) {
        throw "expand.exe failed with exit code $LASTEXITCODE. $($output -join ' ')"
      }

      $expandedFiles = @(Get-ChildItem -LiteralPath $temp -File -Recurse -ErrorAction SilentlyContinue)
      if ($expandedFiles.Count -eq 0) { throw "expand.exe produced no files" }

      $leaf = Split-Path -Leaf $Path
      if ($leaf -match '(?i)\.msu$') {
        $hasCab = @($expandedFiles | Where-Object { $_.Extension -match '(?i)^\.cab$' }).Count -gt 0
        $hasXml = @($expandedFiles | Where-Object { $_.Extension -match '(?i)^\.xml$' }).Count -gt 0
        if (-not $hasCab) { throw "$Context expanded, but did not contain an inner CAB" }
        if (-not $hasXml) { Write-Host "Warning: $Context expanded without an XML manifest: $Path" -ForegroundColor Yellow }
      }

      return $true
    } catch {
      Write-Host "Warning: $Context failed MSU/CAB expand validation: $($_.Exception.Message)" -ForegroundColor Yellow
      return $false
    } finally {
      Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  if ($Magic -eq 'MSWI') {
    try {
      $dismExe = Join-Path $env:SystemRoot 'System32\dism.exe'
      if (-not (Test-Path -LiteralPath $dismExe)) { $dismExe = 'dism.exe' }
      $output = & $dismExe /English /Get-WimInfo /WimFile:$Path 2>&1
      if ($LASTEXITCODE -ne 0) { throw "dism.exe failed with exit code $LASTEXITCODE. $($output -join ' ')" }
      if (($output -join "`n") -notmatch '(?i)The operation completed successfully') { throw "DISM did not report success" }
      return $true
    } catch {
      Write-Host "Warning: $Context failed WIM-container validation: $($_.Exception.Message)" -ForegroundColor Yellow
      return $false
    }
  }

  return $false
}

function Assert-TrustedMicrosoftFileSignature {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [string]$Context = 'downloaded package',
    [Int64]$ExpectedSizeBytes = 0
  )

  if (-not (Test-Path -LiteralPath $Path)) { throw "Cannot verify missing ${Context}: $Path" }

  $file = Get-Item -LiteralPath $Path -ErrorAction Stop
  if ($file.Length -lt 10MB) { throw "$Context is unexpectedly small: $Path ($($file.Length) bytes)" }

  if ($ExpectedSizeBytes -gt 0) {
    # Microsoft Update Catalog size text is sometimes imprecise for modern WIM-backed MSU payloads.
    # Treat only a severe shortfall as corruption; container validation below catches truncated files.
    $minimumExpected = [double]$ExpectedSizeBytes * 0.50
    if ([double]$file.Length -lt $minimumExpected) {
      throw "$Context is far smaller than Microsoft Catalog metadata: $Path (actual: $($file.Length) bytes; catalog approx: $ExpectedSizeBytes bytes)"
    }
  }

  $magic = Get-PackageMagic -Path $Path
  if ($magic -ne 'MSCF' -and $magic -ne 'MSWI') {
    throw "$Context is not a Microsoft cabinet/MSU/WIM-backed package (bad file header '$magic'): $Path"
  }

  try { Unblock-File -LiteralPath $Path -ErrorAction SilentlyContinue } catch { }

  $lastSig = $null
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $lastSig = $sig

    if ($sig.Status -eq 'Valid') {
      $subject = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
      $issuer = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Issuer } else { '' }
      if (($subject -notmatch '(?i)Microsoft') -and ($issuer -notmatch '(?i)Microsoft')) {
        throw "$Context is signed, but not by Microsoft: $Path (subject: $subject; issuer: $issuer)"
      }
      return [pscustomobject]@{ Status = 'AuthenticodeValid'; SignatureStatus = [string]$sig.Status; Fallback = $false }
    }

    Start-Sleep -Seconds 2
  }

  $status = if ($lastSig) { [string]$lastSig.Status } else { 'Unavailable' }
  $statusMessage = if ($lastSig) { [string]$lastSig.StatusMessage } else { '' }

  # Windows can return UnknownError for very large Windows 11 LCU MSU packages even when the file is structurally valid.
  # Do not accept hard signature failures, but allow an UnknownError fallback after header, size and container validation.
  if ($status -eq 'UnknownError' -and (Test-MicrosoftPackageContainer -Path $Path -Magic $magic -Context $Context)) {
    Write-Host "Warning: $Context Authenticode returned UnknownError; accepted after header and container validation: $Path" -ForegroundColor Yellow
    return [pscustomobject]@{ Status = 'ContainerValidatedAfterAuthenticodeUnknownError'; SignatureStatus = $status; Fallback = $true; Container = $magic }
  }

  throw "$Context is not Authenticode-valid: $Path (status: $status; message: $statusMessage)"
}

function Update-CatalogCache {
  param(
    [Parameter(Mandatory)] [string]$CachePath,
    [Parameter(Mandatory)] [string]$Key,
    [Parameter(Mandatory)] [object]$Result
  )

  $cache = [ordered]@{}
  if (Test-Path -LiteralPath $CachePath) {
    try {
      $loaded = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($prop in $loaded.PSObject.Properties) { $cache[$prop.Name] = $prop.Value }
    } catch {
      Write-Host "Warning: could not read existing catalog cache: $($_.Exception.Message)" -ForegroundColor Yellow
    }
  }

  $entry = [ordered]@{}
  foreach ($prop in $Result.PSObject.Properties) { $entry[$prop.Name] = $prop.Value }

  if ($cache.Contains($Key)) {
    $existing = $cache[$Key]
    foreach ($name in @('Path','SHA256')) {
      if (-not $entry[$name] -and $existing.PSObject.Properties[$name] -and $existing.$name) {
        $entry[$name] = $existing.$name
      }
    }
  }

  $cache[$Key] = [pscustomobject]$entry
  $dir = Split-Path -Parent $CachePath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $cache | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $CachePath -Encoding UTF8
}

function Remove-HtmlTags {
  param([AllowNull()] [string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $text = [regex]::Replace($Value, '<[^>]+>', ' ')
  $text = [System.Net.WebUtility]::HtmlDecode($text)
  $text = [regex]::Replace($text, '\s+', ' ').Trim()
  return $text
}

function Convert-CatalogDate {
  param([string]$Value)
  $culture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
  $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
  $dt = [datetime]::MinValue
  if ([datetime]::TryParse($Value, $culture, $styles, [ref]$dt)) { return $dt }
  return [datetime]::MinValue
}

function Convert-CatalogSizeToBytes {
  param([AllowNull()] [string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $clean = ([regex]::Replace($Value, '\s+', ' ')).Trim()
  $sizeMatch = [regex]::Match($clean, '^(?<n>[0-9][0-9,\.]*?)\s*(?<u>B|KB|MB|GB|TB)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $sizeMatch.Success) { return $null }

  $numberText = $sizeMatch.Groups['n'].Value
  if ($numberText -match '\.' -and $numberText -match ',') { $numberText = $numberText -replace ',', '' }
  elseif ($numberText -match ',' -and $numberText -notmatch '\.') { $numberText = $numberText -replace ',', '.' }

  $culture = [System.Globalization.CultureInfo]::InvariantCulture
  $number = [double]0
  if (-not [double]::TryParse($numberText, [System.Globalization.NumberStyles]::Float, $culture, [ref]$number)) { return $null }

  $multiplier = switch ($sizeMatch.Groups['u'].Value.ToUpperInvariant()) {
    'TB' { 1TB }
    'GB' { 1GB }
    'MB' { 1MB }
    'KB' { 1KB }
    default { 1 }
  }

  return [int64]($number * $multiplier)
}

function Get-CatalogSizeText {
  param([string[]]$Cells)

  foreach ($cell in $Cells) {
    if ([string]::IsNullOrWhiteSpace($cell)) { continue }
    $match = [regex]::Match([string]$cell, '(?<size>[0-9][0-9,\.]*\s*(?:B|KB|MB|GB|TB))', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) { return $match.Groups['size'].Value.Trim() }
  }
  return $null
}

function Get-CatalogRows {
  param(
    [string]$Query,
    [Microsoft.PowerShell.Commands.WebRequestSession]$Session
  )

  $encoded = [System.Uri]::EscapeDataString($Query)
  $url = "https://www.catalog.update.microsoft.com/Search.aspx?q=$encoded"
  Write-Step "Searching Microsoft Update Catalog"
  Write-Host "    Query: $Query" -ForegroundColor DarkGray

  $headers = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) BuildWIM/2.0'
    'Accept' = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
  }

  $response = Invoke-WebRequest -Uri $url -WebSession $Session -Headers $headers -UseBasicParsing -TimeoutSec 60
  $rowMatches = [regex]::Matches($response.Content, '<tr[^>]*>.*?</tr>', [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($rowMatch in $rowMatches) {
    $rowHtml = $rowMatch.Value
    $guidMatch = [regex]::Match($rowHtml, 'goToDetails\(["'']([a-f0-9\-]{36})["'']\)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $guidMatch.Success) { continue }

    $cells = @([regex]::Matches($rowHtml, '<td[^>]*>(.*?)</td>', [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { Remove-HtmlTags $_.Groups[1].Value })
    if ($cells.Count -lt 5) { continue }

    $title = $cells[1]
    $classification = $cells[3]
    $lastUpdated = $cells[4]
    $sizeText = Get-CatalogSizeText -Cells $cells
    $sizeBytes = Convert-CatalogSizeToBytes -Value $sizeText

    $kb = $null
    if ($title -match 'KB(\d+)') { $kb = "KB$($matches[1])" }
    $build = $null
    if ($title -match '\((\d+\.\d+)\)\s*$') { $build = $matches[1] }

    $rows.Add([pscustomobject]@{
      Guid = $guidMatch.Groups[1].Value
      KB = $kb
      Title = $title
      Classification = $classification
      LastUpdatedText = $lastUpdated
      LastUpdated = Convert-CatalogDate $lastUpdated
      Build = $build
      SizeText = $sizeText
      SizeBytes = $sizeBytes
    }) | Out-Null
  }

  return $rows.ToArray()
}

function Select-LatestPackage {
  param([object[]]$Rows)

  $archPattern = switch ($Architecture) {
    'x64' { 'x64-based Systems|x64' }
    'x86' { 'x86-based Systems|x86' }
    'arm64' { 'arm64-based Systems|arm64' }
  }

  $filtered = @($Rows | Where-Object {
    $titleMatchesTarget = (
      $_.Title -match 'Windows 11' -and
      $_.Title -match "version $([regex]::Escape($WindowsVersion))" -and
      $_.Title -match $archPattern -and
      ($IncludePreview -or $_.Title -notmatch 'Preview')
    )
    if (-not $titleMatchesTarget) { return $false }

    if ($PackageType -eq 'SafeOS') {
      return ($_.Title -match '(?i)Safe OS Dynamic Update')
    }

    $commonCumulative = (
      $_.Title -match 'Cumulative Update' -and
      $_.Title -notmatch 'Dynamic Cumulative Update' -and
      $_.Title -notmatch 'Safe OS Dynamic Update'
    )
    if (-not $commonCumulative) { return $false }

    if ($PackageType -eq 'DotNet') {
      return ($_.Title -match '\.NET Framework')
    }

    return ($_.Title -notmatch '\.NET Framework')
  })

  if ($filtered.Count -eq 0) {
    $kind = if ($PackageType -eq 'SafeOS') { 'Safe OS Dynamic Update' } else { "$PackageType cumulative update" }
    throw "No matching Windows 11 $WindowsVersion $Architecture $kind found. Try -IncludePreview or check the version."
  }

  return ($filtered | Sort-Object LastUpdated, Title -Descending | Select-Object -First 1)
}

function Get-DownloadUrl {
  param(
    [string]$Guid,
    [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
    [string]$PreferredKB
  )

  Write-Step "Resolving Microsoft download URL"
  Write-Host "    Update ID: $Guid" -ForegroundColor DarkGray

  $headers = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) BuildWIM/2.0'
    'Accept' = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
  }

  $postData = "[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$Guid`",`"updateID`":`"$Guid`"}]"
  $body = "updateIDs=$([System.Uri]::EscapeDataString($postData))"

  $response = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
    -Method POST `
    -WebSession $Session `
    -Headers $headers `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body $body `
    -UseBasicParsing `
    -TimeoutSec 60

  $patterns = @(
    'downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*''([^'']+\.(?:msu|cab))''',
    'https?://[^"''\s]+\.(?:msu|cab)'
  )

  $urls = New-Object System.Collections.Generic.List[string]
  foreach ($pattern in $patterns) {
    $matches = [regex]::Matches($response.Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $matches) {
      $url = if ($m.Groups.Count -gt 1) { $m.Groups[1].Value } else { $m.Value }
      $url = [System.Net.WebUtility]::HtmlDecode($url).Trim("'`"")
      if ($url -match '^https?://' -and $url -match '\.(?:msu|cab)$' -and -not $urls.Contains($url)) {
        $urls.Add($url) | Out-Null
      }
    }
  }

  $trustedUrls = @($urls.ToArray() | Where-Object { Test-TrustedMicrosoftDownloadUrl -Url $_ })
  if ($trustedUrls.Count -eq 0) {
    throw "Could not extract a trusted Microsoft .msu/.cab download URL for update ID $Guid."
  }

  if ($PreferredKB) {
    $kbDigits = $PreferredKB -replace '[^0-9]', ''
    $preferred = @($trustedUrls | Where-Object { $_ -match "kb$kbDigits" } | Select-Object -First 1)
    if ($preferred.Count -gt 0) { return $preferred[0] }
  }

  return $trustedUrls[0]
}

function Save-Download {
  param(
    [string]$Url,
    [string]$Destination,
    [Int64]$ExpectedSizeBytes = 0
  )

  if ((Test-Path -LiteralPath $Destination) -and -not $Force) {
    $existing = Get-Item -LiteralPath $Destination
    if ($existing.Length -gt 10MB) {
      try {
        [void](Assert-TrustedMicrosoftFileSignature -Path $Destination -Context "Existing Windows 11 $PackageType package" -ExpectedSizeBytes $ExpectedSizeBytes)
        Write-Host "Already downloaded and package validation passed: $Destination" -ForegroundColor Green
        return $Destination
      } catch {
        Write-Host "Warning: existing Windows 11 $PackageType package failed validation and will be re-downloaded: $($_.Exception.Message)" -ForegroundColor Yellow
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
      }
    } else {
      Write-Host "Warning: existing Windows 11 $PackageType package is too small and will be re-downloaded: $Destination ($($existing.Length) bytes)" -ForegroundColor Yellow
      Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }
  }

  if (-not (Test-TrustedMicrosoftDownloadUrl -Url $Url)) { throw "Refusing untrusted package URL: $Url" }

  if ($PSCmdlet.ShouldProcess($Destination, "Download latest Windows 11 $PackageType package")) {
    $downloadSucceeded = $false
    $lastError = $null

    for ($attempt = 1; $attempt -le 3 -and -not $downloadSucceeded; $attempt++) {
      Write-Step "Downloading MSU"
      Write-Host "    Attempt: $attempt/3" -ForegroundColor DarkGray
      Write-Host "    File   : $(Split-Path -Leaf $Destination)" -ForegroundColor DarkGray
      Write-Host "    URL    : $Url" -ForegroundColor DarkGray

      $partial = "{0}.download.{1}.{2}" -f $Destination, $PID, $attempt
      Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue

      $oldProgress = $ProgressPreference
      $ProgressPreference = 'SilentlyContinue'
      try {
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -TimeoutSec 7200
        Move-Item -LiteralPath $partial -Destination $Destination -Force

        $file = Get-Item -LiteralPath $Destination -ErrorAction Stop
        if ($file.Length -lt 10MB) { throw "Downloaded file is unexpectedly small: $($file.Length) bytes" }

        [void](Assert-TrustedMicrosoftFileSignature -Path $Destination -Context "Windows 11 $PackageType package" -ExpectedSizeBytes $ExpectedSizeBytes)
        $downloadSucceeded = $true
      } catch {
        $lastError = $_
        Write-Host "Warning: download/validation attempt $attempt failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        if ($attempt -lt 3) { Start-Sleep -Seconds ([math]::Min(30, 5 * $attempt)) }
      } finally {
        $ProgressPreference = $oldProgress
      }
    }

    if (-not $downloadSucceeded) {
      throw "Failed to download a valid Windows 11 $PackageType package after 3 attempts. Last error: $($lastError.Exception.Message)"
    }
  }

  return $Destination
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
  New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$query = switch ($PackageType) {
  'DotNet' { "Windows 11 version $WindowsVersion $Architecture .NET Framework cumulative update" }
  'SafeOS' { "Windows 11 version $WindowsVersion $Architecture Safe OS Dynamic Update" }
  default { "Windows 11 version $WindowsVersion $Architecture cumulative update" }
}
$rows = Get-CatalogRows -Query $query -Session $session
$latest = Select-LatestPackage -Rows $rows

Write-Host ''
Write-Host '+----------------------------------------------------------------+' -ForegroundColor Cyan
$heading = switch ($PackageType) {
  'DotNet' { 'Latest Windows 11 .NET Framework cumulative update' }
  'SafeOS' { 'Latest Windows 11 Safe OS Dynamic Update' }
  default { 'Latest Windows 11 cumulative update' }
}
Write-Host ('| {0,-62} |' -f $heading) -ForegroundColor Cyan
Write-Host '+----------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host "  KB             : $($latest.KB)" -ForegroundColor Green
Write-Host "  Title          : $($latest.Title)" -ForegroundColor Green
Write-Host "  Classification : $($latest.Classification)" -ForegroundColor Green
Write-Host "  Last updated   : $($latest.LastUpdatedText)" -ForegroundColor Green
Write-Host "  Size           : $($latest.SizeText)" -ForegroundColor Green
Write-Host "  Build          : $($latest.Build)" -ForegroundColor Green
Write-Host "  Update ID      : $($latest.Guid)" -ForegroundColor DarkGray
Write-Host ''

$url = Get-DownloadUrl -Guid $latest.Guid -Session $session -PreferredKB $latest.KB
$filename = [System.IO.Path]::GetFileName(([uri]$url).AbsolutePath)
$destination = Join-Path $OutputPath $filename

if (-not $MetadataOnly) {
  $destination = Save-Download -Url $url -Destination $destination -ExpectedSizeBytes $latest.SizeBytes
}

$sha256 = if ($MetadataOnly) { $null } else { Get-FileSha256Safe -Path $destination }
$result = [pscustomobject]@{
  KB = $latest.KB
  Title = $latest.Title
  Classification = $latest.Classification
  LastUpdated = $latest.LastUpdatedText
  Build = $latest.Build
  SizeText = $latest.SizeText
  SizeBytes = $latest.SizeBytes
  UpdateId = $latest.Guid
  Url = $url
  Path = if ($MetadataOnly) { $null } else { $destination }
  FileName = $filename
  SHA256 = $sha256
  CheckedAt = (Get-Date).ToString('o')
  WindowsVersion = $WindowsVersion
  Architecture = $Architecture
  PackageType = $PackageType
}

if (-not $MetadataOnly) {
  $sidecarPath = "$destination.metadata.json"
  $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sidecarPath -Encoding UTF8
}

$cachePath = Join-Path $OutputPath 'catalog-cache.json'
$cacheKey = "Windows11-$WindowsVersion-$Architecture-$PackageType"
Update-CatalogCache -CachePath $cachePath -Key $cacheKey -Result $result

Write-Host ''
Write-Host 'Complete.' -ForegroundColor Green
if (-not $MetadataOnly) {
  Write-Host "Saved to: $destination" -ForegroundColor Green
  Write-Host "Metadata: $sidecarPath" -ForegroundColor Green
  if ($sha256) { Write-Host "SHA256  : $sha256" -ForegroundColor Green }
}
Write-Host "Cache   : $cachePath" -ForegroundColor Green

$result | ConvertTo-Json -Depth 4
