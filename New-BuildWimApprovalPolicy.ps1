<#
.SYNOPSIS
  Creates BuildWIM production approval policy files from already downloaded, reviewed media and update packages.

.DESCRIPTION
  This helper does not approve anything by itself. It records the SHA256/provenance of
  source media and update packages that an operator has already reviewed so
  Build-WIM.ps1 -ProductionRelease can fail closed on drift.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Root = 'C:\BuildWimV2',
  [string]$ApprovedBy = $env:USERNAME,
  [string]$ChangeTicket = 'CHANGE-REQUIRED',
  [string]$BaselineId = ("buildwim-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')),
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FirstPropertyValue {
  param(
    [AllowNull()] [object]$Object,
    [Parameter(Mandatory)] [string[]]$Names,
    [string]$Default = $null
  )
  if ($null -eq $Object) { return $Default }
  foreach ($name in $Names) {
    $prop = $Object.PSObject.Properties[$name]
    if ($null -ne $prop -and $null -ne $prop.Value -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
      return [string]$prop.Value
    }
  }
  return $Default
}

function Get-UpdateClassification {
  param([Parameter(Mandatory)] [string]$Path, [AllowNull()] [object]$Metadata)
  $title = Get-FirstPropertyValue -Object $Metadata -Names @('Title','Description') -Default ''
  $packageType = Get-FirstPropertyValue -Object $Metadata -Names @('PackageType','Classification') -Default ''
  $name = [IO.Path]::GetFileName($Path)
  if ($packageType -match '(?i)SafeOS' -or $title -match '(?i)Safe OS|WinRE|Dynamic Update') { return 'SafeOSDU' }
  if ($title -match '(?i)\.NET') { return 'DotNetCU' }
  if ($title -match '(?i)Cumulative Update' -or $name -match '(?i)cumulative') { return 'LCU' }
  return 'Other'
}

$inputDir = Join-Path $Root 'Input'
$updatesDir = Join-Path $Root 'Updates'
$configDir = Join-Path $Root 'Config'
if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

$sources = @(Get-ChildItem -LiteralPath $inputDir -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in @('.iso','.wim','.esd') } |
  Sort-Object Name)
if ($sources.Count -eq 0) { throw "No ISO/WIM/ESD source media found in $inputDir." }

$sourceEntries = @($sources | ForEach-Object {
  $type = switch -Regex ($_.Extension) {
    '(?i)^\.iso$' { 'ISO'; break }
    '(?i)^\.wim$' { 'WIM'; break }
    '(?i)^\.esd$' { 'ESD'; break }
    default { 'Unknown' }
  }
  [ordered]@{
    BaselineId = $BaselineId
    FileName = $_.Name
    Type = $type
    SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    SizeBytes = $_.Length
    WindowsVersion = '25H2'
    Architecture = 'x64'
    Language = 'English International'
    Edition = 'Windows 11 Pro'
    ApprovedBy = $ApprovedBy
    ChangeTicket = $ChangeTicket
    Status = 'Approved'
  }
})

$updateEntries = @()
$updateFiles = @(Get-ChildItem -LiteralPath $updatesDir -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in @('.msu','.cab') } |
  Sort-Object Name)
foreach ($file in $updateFiles) {
  $meta = $null
  $sidecar = "$($file.FullName).metadata.json"
  if (Test-Path -LiteralPath $sidecar) {
    try { $meta = Get-Content -LiteralPath $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $meta = $null }
  }
  $kb = Get-FirstPropertyValue -Object $meta -Names @('KB','KBNumber') -Default ([regex]::Match($file.Name, '(?i)kb\d+').Value.ToUpperInvariant())
  $updateEntries += [ordered]@{
    KB = $kb
    Classification = (Get-UpdateClassification -Path $file.FullName -Metadata $meta)
    Required = $true
    FileName = $file.Name
    SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    UpdateId = Get-FirstPropertyValue -Object $meta -Names @('UpdateId') -Default $null
    Title = Get-FirstPropertyValue -Object $meta -Names @('Title') -Default $null
    LastUpdated = Get-FirstPropertyValue -Object $meta -Names @('LastUpdated') -Default $null
    ApprovedBy = $ApprovedBy
    ChangeTicket = $ChangeTicket
    Status = 'Approved'
  }
}
if ($updateEntries.Count -eq 0) { throw "No MSU/CAB update packages found in $updatesDir." }

$sourcePolicy = [ordered]@{
  Schema = 'buildwim.approved-sources.v1'
  Updated = (Get-Date).ToString('yyyy-MM-dd')
  ApprovedSources = $sourceEntries
}
$updatesPolicy = [ordered]@{
  Schema = 'buildwim.approved-updates.v1'
  Updated = (Get-Date).ToString('yyyy-MM-dd')
  ApprovedUpdates = $updateEntries
}

$sourcePath = Join-Path $configDir 'approved-sources.json'
$updatesPath = Join-Path $configDir 'approved-updates-policy.json'
foreach ($path in @($sourcePath,$updatesPath)) {
  if ((Test-Path -LiteralPath $path) -and -not $Force) {
    throw "Policy already exists: $path. Use -Force to replace after approval."
  }
}

if ($PSCmdlet.ShouldProcess($configDir, 'Write BuildWIM approval policies')) {
  $sourcePolicy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sourcePath -Encoding UTF8
  $updatesPolicy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $updatesPath -Encoding UTF8
}

Write-Host "SOURCE_POLICY=$sourcePath"
Write-Host "UPDATES_POLICY=$updatesPath"
