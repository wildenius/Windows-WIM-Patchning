<#
.SYNOPSIS
  Downloads the latest non-preview Windows 11 cumulative update from Microsoft Update Catalog.

.DESCRIPTION
  Searches Microsoft Update Catalog, selects the newest matching Windows 11 LCU for a target
  Windows version and architecture, extracts the real .msu download URL from DownloadDialog.aspx,
  and downloads it to the BuildWIM Updates folder.

  Default behavior intentionally excludes Preview updates and .NET cumulative updates.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$WindowsVersion = '25H2',

  [ValidateSet('x64','x86','arm64')]
  [string]$Architecture = 'x64',

  [string]$OutputPath = 'C:\BuildWimV2\Updates',

  [switch]$IncludePreview,

  [switch]$Force,

  [switch]$MetadataOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
  param([string]$Message)
  Write-Host "==> $Message" -ForegroundColor Cyan
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
    }) | Out-Null
  }

  return $rows.ToArray()
}

function Select-LatestLcu {
  param([object[]]$Rows)

  $archPattern = switch ($Architecture) {
    'x64' { 'x64-based Systems|x64' }
    'x86' { 'x86-based Systems|x86' }
    'arm64' { 'arm64-based Systems|arm64' }
  }

  $filtered = @($Rows | Where-Object {
    $_.Title -match 'Cumulative Update' -and
    $_.Title -match 'Windows 11' -and
    $_.Title -match "version $([regex]::Escape($WindowsVersion))" -and
    $_.Title -match $archPattern -and
    $_.Title -notmatch '\.NET Framework' -and
    $_.Title -notmatch 'Dynamic Cumulative Update' -and
    $_.Title -notmatch 'Safe OS Dynamic Update' -and
    ($IncludePreview -or $_.Title -notmatch 'Preview')
  })

  if ($filtered.Count -eq 0) {
    throw "No matching Windows 11 $WindowsVersion $Architecture cumulative update found. Try -IncludePreview or check the version."
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
    'downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*''([^'']+\.msu)''',
    'https?://[^"''\s]+\.msu'
  )

  $urls = New-Object System.Collections.Generic.List[string]
  foreach ($pattern in $patterns) {
    $matches = [regex]::Matches($response.Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $matches) {
      $url = if ($m.Groups.Count -gt 1) { $m.Groups[1].Value } else { $m.Value }
      $url = [System.Net.WebUtility]::HtmlDecode($url).Trim("'`"")
      if ($url -match '^https?://' -and $url -match '\.msu$' -and -not $urls.Contains($url)) {
        $urls.Add($url) | Out-Null
      }
    }
  }

  if ($urls.Count -eq 0) {
    throw "Could not extract .msu download URL for update ID $Guid."
  }

  if ($PreferredKB) {
    $kbDigits = $PreferredKB -replace '[^0-9]', ''
    $preferred = @($urls.ToArray() | Where-Object { $_ -match "kb$kbDigits" } | Select-Object -First 1)
    if ($preferred.Count -gt 0) { return $preferred[0] }
  }

  return $urls[0]
}

function Save-Download {
  param(
    [string]$Url,
    [string]$Destination
  )

  if ((Test-Path -LiteralPath $Destination) -and -not $Force) {
    $existing = Get-Item -LiteralPath $Destination
    if ($existing.Length -gt 10MB) {
      Write-Host "Already downloaded: $Destination" -ForegroundColor Green
      return $Destination
    }
  }

  if ($PSCmdlet.ShouldProcess($Destination, 'Download latest Windows 11 LCU')) {
    Write-Step "Downloading MSU"
    Write-Host "    File: $(Split-Path -Leaf $Destination)" -ForegroundColor DarkGray
    Write-Host "    URL : $Url" -ForegroundColor DarkGray

    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
      Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 7200
    } finally {
      $ProgressPreference = $oldProgress
    }

    $file = Get-Item -LiteralPath $Destination -ErrorAction Stop
    if ($file.Length -lt 10MB) {
      Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
      throw "Downloaded file is unexpectedly small: $($file.Length) bytes"
    }
  }

  return $Destination
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
  New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$query = "Windows 11 version $WindowsVersion $Architecture cumulative update"
$rows = Get-CatalogRows -Query $query -Session $session
$latest = Select-LatestLcu -Rows $rows

Write-Host ''
Write-Host '+----------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host '| Latest Windows 11 cumulative update                            |' -ForegroundColor Cyan
Write-Host '+----------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host "  KB             : $($latest.KB)" -ForegroundColor Green
Write-Host "  Title          : $($latest.Title)" -ForegroundColor Green
Write-Host "  Classification : $($latest.Classification)" -ForegroundColor Green
Write-Host "  Last updated   : $($latest.LastUpdatedText)" -ForegroundColor Green
Write-Host "  Build          : $($latest.Build)" -ForegroundColor Green
Write-Host "  Update ID      : $($latest.Guid)" -ForegroundColor DarkGray
Write-Host ''

$url = Get-DownloadUrl -Guid $latest.Guid -Session $session -PreferredKB $latest.KB
$filename = [System.IO.Path]::GetFileName(([uri]$url).AbsolutePath)
$destination = Join-Path $OutputPath $filename

if (-not $MetadataOnly) {
  $destination = Save-Download -Url $url -Destination $destination
}

$result = [pscustomobject]@{
  KB = $latest.KB
  Title = $latest.Title
  Classification = $latest.Classification
  LastUpdated = $latest.LastUpdatedText
  Build = $latest.Build
  UpdateId = $latest.Guid
  Url = $url
  Path = if ($MetadataOnly) { $null } else { $destination }
  FileName = $filename
}

if (-not $MetadataOnly) {
  $sidecarPath = "$destination.metadata.json"
  $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sidecarPath -Encoding UTF8
}

Write-Host ''
Write-Host 'Complete.' -ForegroundColor Green
if (-not $MetadataOnly) {
  Write-Host "Saved to: $destination" -ForegroundColor Green
  Write-Host "Metadata: $sidecarPath" -ForegroundColor Green
}

$result | ConvertTo-Json -Depth 4
