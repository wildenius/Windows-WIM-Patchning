<#
.SYNOPSIS
  BuildWIM - Offline servicing pipeline for Windows 11 installation images.

.DESCRIPTION
  Supports input: ISO, install.wim, install.esd.
  Enforces workflow:
    1) Determine input type
    2) (If ISO) mount and copy install.(wim|esd)
    3) (If ESD) convert to WIM
    4) Identify Windows 11 Pro index
    5) Export Pro-only working WIM (mandatory)
    6) Mount working WIM
    7) Classify + sort packages (SSU, LCU, .NET, other)
    8) Inject packages offline
    9) Optionally download and inject latest Microsoft Defender offline update package
   10) Offline cleanup
   11) Commit image
   12) Export selected output: SWM by default, WIM only, or both
   13) Generate HTML report + hashes

.NOTES
  Version: 2.0.0
  Author: BuildWIM
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Root = 'C:\BuildWimV2',
  [string]$ConfigPath = 'C:\BuildWimV2\Config\buildwim.config.json',
  [int]$SplitSizeMB,
  [switch]$DryRun,
  [switch]$EmitMetadataJson,
  [switch]$NotifyOnComplete,
  [switch]$AutoDownloadLatestLCU,
  [switch]$CheckLatestLCU,
  [switch]$ForceRebuild,
  [switch]$SkipAutoDownloadWindows11Iso,
  [switch]$SkipUpdateSelectionPrompt,
  [switch]$AcceptRecommendedUpdates,
  [switch]$AddDefenderSignatures,
  [switch]$SkipDefenderSignatures,
  [string]$UpdateWindowsVersion = '25H2',
  [ValidateSet('x64','x86','arm64')]
  [string]$UpdateArchitecture = 'x64',
  [ValidateSet('Prompt','WIM','SWM','Both')]
  [string]$OutputMode = 'Prompt',
  [ValidateSet('Prompt','Newbie','Expert')]
  [string]$UiMode = 'Prompt'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($WhatIfPreference -and -not $DryRun) {
  $DryRun = $true
}

# ----------------------------
# Logging
# ----------------------------
$script:Run = [ordered]@{
  Version = '2.0.0'
  StartTime = (Get-Date)
  EndTime = $null
  Duration = $null
  Warnings = New-Object System.Collections.Generic.List[string]
  Errors = New-Object System.Collections.Generic.List[string]
  DismCommands = New-Object System.Collections.Generic.List[string]
  Input = [ordered]@{}
  Image = [ordered]@{
    ExistingPackages = @()
    EnabledFeatures = @()
    AllEditions = @()
    ProIndex = $null
    SelectedEditionName = $null
    SourceSelectedEditionName = $null
    SourceSelectedEditionVersion = $null
    SourceSelectedEditionArchitecture = $null
    SourceSelectedEditionServicePackBuild = $null
    WorkingWim = $null
    WorkingEditionName = $null
    WorkingEditionVersion = $null
    WorkingEditionArchitecture = $null
    FinalEditionName = $null
    FinalEditionVersion = $null
    FinalEditionArchitecture = $null
    FinalEditionServicePackBuild = $null
    FinalPackageIdentities = @()
  }
  Packages = [ordered]@{
    Found = @()
    Sorted = @()
    Injected = @()
    Skipped = @()
    UpdateSelection = @()
    SelectedUpdateFileNames = @()
    ExcludedBySelection = @()
  }
  Defender = [ordered]@{
    Enabled = $false
    Applied = $false
    Architecture = $null
    UpdateKitUrl = $null
    KitPath = $null
    CabPath = $null
    CabSHA256 = $null
    Details = $null
  }
  Steps = New-Object System.Collections.Generic.List[object]
  Summary = [ordered]@{
    SkippedBecauseCurrent = $false
    SourceBuildRevision = $null
    TargetBuildRevision = $null
    LatestLcuKB = $null
    LatestLcuBuild = $null
    LatestLcuLastUpdated = $null
    LatestLcuReleaseType = $null
    LatestLcuIsOob = $false
    LatestLcuPatchTuesday = $null
    LatestDotNetKB = $null
    LatestDotNetTitle = $null
    LatestDotNetLastUpdated = $null
    LatestDotNetReleaseType = $null
    LatestDotNetIsOob = $false
    LatestSafeOsKB = $null
    LatestSafeOsTitle = $null
    LatestSafeOsLastUpdated = $null
    LatestSafeOsUpdateId = $null
    LatestSafeOsFileName = $null
    NextPatchTuesday = $null
    DaysUntilPatchTuesday = $null
    DiskFreeGBAtStart = $null
  }
  ETA = [ordered]@{
    HistoryPath = $null
    History = @()
    Current = [ordered]@{}
  }
  Output = [ordered]@{
    Mode = 'SWM'
    FinalWim = $null
    IntermediateWim = $null
    FinalWimHash = $null
    FinalWimSizeBytes = $null
    SwmBase = $null
    SwmFiles = @()
    BuildManifest = $null
    Sha256Sums = $null
    MetadataJson = $null
  }
  Verification = [ordered]@{}
}


$script:Paths = [ordered]@{}
$script:IsoMount = [ordered]@{ Mounted = $false; DriveLetter = $null; ImagePath = $null }

function Show-Banner {
  param(
    [string]$InputType = '?',
    [string]$InputFile = '?'
  )

  function Format-BannerValue {
    param(
      [AllowNull()] [string]$Value,
      [int]$Width = 58
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = '?' }
    if ($Value.Length -gt $Width) { return $Value.Substring(0, $Width - 3) + '...' }
    return $Value.PadRight($Width)
  }

  $date = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  $ver = $script:Run.Version
  $mode = if ($DryRun) { 'DRY RUN' } else { 'PRODUCTION' }
  $inputLabel = "{0} ({1})" -f $InputType, $InputFile

  Write-Host ""
  Write-Host '  +----------------------------------------------------------------+' -ForegroundColor Cyan
  Write-Host '  |  ____        _ _     _ __        _____ __  __                  |' -ForegroundColor Cyan
  Write-Host '  | | __ ) _   _(_) | __| |\ \      / /_ _|  \/  |                 |' -ForegroundColor Cyan
  Write-Host '  | |  _ \| | | | | |/ _` | \ \ /\ / / | || |\/| |                 |' -ForegroundColor Cyan
  Write-Host '  | | |_) | |_| | | | (_| |  \ V  V /  | || |  | |                 |' -ForegroundColor Cyan
  Write-Host '  | |____/ \__,_|_|_|\__,_|   \_/\_/  |___|_|  |_|                 |' -ForegroundColor Cyan
  Write-Host '  |                                                                |' -ForegroundColor Cyan
  Write-Host '  |        Windows image servicing. Boringly repeatable.           |' -ForegroundColor DarkCyan
  Write-Host '  +----------------------------------------------------------------+' -ForegroundColor Cyan
  Write-Host ("  | Version : {0} |" -f (Format-BannerValue $ver)) -ForegroundColor DarkCyan
  Write-Host ("  | Date    : {0} |" -f (Format-BannerValue $date)) -ForegroundColor DarkCyan
  Write-Host ("  | Input   : {0} |" -f (Format-BannerValue $inputLabel)) -ForegroundColor DarkCyan
  Write-Host ("  | Mode    : {0} |" -f (Format-BannerValue $mode)) -ForegroundColor DarkCyan
  Write-Host '  +----------------------------------------------------------------+' -ForegroundColor Cyan
  Write-Host ""
}


function ConvertTo-BuildVersion {
  param([AllowNull()] [string]$Build)

  if ([string]::IsNullOrWhiteSpace($Build)) { return $null }
  $clean = $Build.Trim()
  [version]$parsed = $null
  if ([version]::TryParse($clean, [ref]$parsed)) { return $parsed }
  return $null
}

function Test-LcuMetadataMatchesTarget {
  param(
    [Parameter(Mandatory)] [object]$Metadata,
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64'
  )

  $title = if ($Metadata.PSObject.Properties['Title']) { [string]$Metadata.Title } else { '' }
  if ($title -notmatch '(?i)Cumulative Update' -or $title -notmatch '(?i)Windows 11') { return $false }
  if ($title -match '(?i)\.NET Framework|Dynamic Cumulative Update|Safe OS Dynamic Update|Preview') { return $false }
  if ($WindowsVersion -and $title -notmatch "version $([regex]::Escape($WindowsVersion))") { return $false }

  $archPattern = switch ($Architecture) {
    'x64' { 'x64-based Systems|x64' }
    'x86' { 'x86-based Systems|x86' }
    'arm64' { 'arm64-based Systems|arm64' }
    default { [regex]::Escape($Architecture) }
  }
  return ($title -match $archPattern)
}

function Get-ExistingLatestLcuPackage {
  param(
    [Parameter(Mandatory)] [string]$Destination,
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64'
  )

  $items = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $Destination)) { return $null }

  foreach ($sidecar in @(Get-ChildItem -LiteralPath $Destination -File -Filter '*.msu.metadata.json' -ErrorAction SilentlyContinue)) {
    try {
      $meta = Get-Content -LiteralPath $sidecar.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      if (-not (Test-LcuMetadataMatchesTarget -Metadata $meta -WindowsVersion $WindowsVersion -Architecture $Architecture)) { continue }

      $fileName = if ($meta.FileName) { [string]$meta.FileName } else { [IO.Path]::GetFileNameWithoutExtension($sidecar.Name) }
      $packagePath = Join-Path $Destination $fileName
      if (-not (Test-Path -LiteralPath $packagePath)) {
        if ($meta.Path -and (Test-Path -LiteralPath ([string]$meta.Path))) { $packagePath = [string]$meta.Path }
      }

      $items.Add([pscustomobject]@{
        KB = [string]$meta.KB
        Title = [string]$meta.Title
        Build = [string]$meta.Build
        BuildVersion = ConvertTo-BuildVersion -Build ([string]$meta.Build)
        LastUpdated = [string]$meta.LastUpdated
        UpdateId = [string]$meta.UpdateId
        FileName = $fileName
        Path = $packagePath
        SidecarPath = $sidecar.FullName
      }) | Out-Null
    } catch {
      Write-Log "Could not read existing LCU metadata: $($sidecar.FullName) ($($_.Exception.Message))" WARN
    }
  }

  if ($items.Count -eq 0) { return $null }
  return @($items.ToArray() | Sort-Object @{ Expression = { $_.BuildVersion }; Descending = $true }, @{ Expression = { $_.LastUpdated }; Descending = $true } | Select-Object -First 1)[0]
}

function Get-LatestLcuCatalogMetadata {
  param(
    [Parameter(Mandatory)] [string]$Downloader,
    [Parameter(Mandatory)] [string]$Destination,
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64'
  )

  Write-Log "Checking Microsoft Update Catalog for latest Windows 11 $WindowsVersion $Architecture LCU" INFO
  $args = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $Downloader,
    '-WindowsVersion', $WindowsVersion,
    '-Architecture', $Architecture,
    '-OutputPath', $Destination,
    '-MetadataOnly',
    '-PackageType', 'LCU'
  )

  $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
  if ($proc.ExitCode -ne 0) {
    throw "Latest LCU metadata check failed with exit code $($proc.ExitCode)."
  }

  $cachePath = Join-Path $Destination 'catalog-cache.json'
  if (-not (Test-Path -LiteralPath $cachePath)) { throw "Latest LCU metadata check did not create cache: $cachePath" }

  $cache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $entry = $null
  foreach ($cacheKey in @("Windows11-$WindowsVersion-$Architecture-LCU", "Windows11-$WindowsVersion-$Architecture")) {
    $entry = $cache.PSObject.Properties[$cacheKey]
    if ($entry -and $entry.Value) { break }
  }
  if (-not $entry -or -not $entry.Value) { throw "Latest LCU cache entry missing for Windows11-$WindowsVersion-$Architecture-LCU" }
  $latest = $entry.Value
  $latest | Add-Member -NotePropertyName BuildVersion -NotePropertyValue (ConvertTo-BuildVersion -Build ([string]$latest.Build)) -Force
  return $latest
}

function Move-SupersededLcuPackages {
  param(
    [Parameter(Mandatory)] [string]$Destination,
    [Parameter(Mandatory)] [object]$Latest,
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64'
  )

  if (-not (Test-Path -LiteralPath $Destination)) { return }
  $latestFileName = if ($Latest.FileName) { [string]$Latest.FileName } else { '' }
  $archiveRoot = Join-Path $Destination 'Superseded'
  $archiveDir = Join-Path $archiveRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
  $moved = 0

  foreach ($sidecar in @(Get-ChildItem -LiteralPath $Destination -File -Filter '*.msu.metadata.json' -ErrorAction SilentlyContinue)) {
    try {
      $meta = Get-Content -LiteralPath $sidecar.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      if (-not (Test-LcuMetadataMatchesTarget -Metadata $meta -WindowsVersion $WindowsVersion -Architecture $Architecture)) { continue }
      $fileName = if ($meta.FileName) { [string]$meta.FileName } else { [IO.Path]::GetFileNameWithoutExtension($sidecar.Name) }
      if ($latestFileName -and ($fileName -ieq $latestFileName)) { continue }

      if (-not (Test-Path -LiteralPath $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
      $packagePath = Join-Path $Destination $fileName
      if (Test-Path -LiteralPath $packagePath) {
        Move-Item -LiteralPath $packagePath -Destination (Join-Path $archiveDir $fileName) -Force
        $moved++
      }
      Move-Item -LiteralPath $sidecar.FullName -Destination (Join-Path $archiveDir $sidecar.Name) -Force
      Write-Log "Archived superseded LCU package: $fileName" INFO
    } catch {
      Write-Log "Could not archive superseded LCU metadata/package $($sidecar.FullName): $($_.Exception.Message)" WARN
    }
  }

  if ($moved -gt 0) { Write-Log "Archived $moved superseded LCU package(s) to $archiveDir" INFO }
}

function Invoke-LatestLcuDownload {
  param(
    [Parameter(Mandatory)] [string]$Destination,
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64'
  )

  $downloader = Join-Path $PSScriptRoot 'Get-LatestWindows11LCU.ps1'
  if (-not (Test-Path -LiteralPath $downloader)) {
    throw "Auto-download requested but downloader script is missing: $downloader"
  }

  if ($DryRun) {
    Write-Log "Latest LCU auto-detection is enabled, but DryRun is active. Skipping download side effects." WARN
    return
  }

  if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

  $latest = Get-LatestLcuCatalogMetadata -Downloader $downloader -Destination $Destination -WindowsVersion $WindowsVersion -Architecture $Architecture
  $existing = Get-ExistingLatestLcuPackage -Destination $Destination -WindowsVersion $WindowsVersion -Architecture $Architecture

  $latestVersion = ConvertTo-BuildVersion -Build ([string]$latest.Build)
  $existingVersion = if ($existing) { $existing.BuildVersion } else { $null }
  $shouldDownload = $false

  if (-not $existing) {
    Write-Log "No existing Windows 11 $WindowsVersion $Architecture LCU found in $Destination. Downloading $($latest.KB) ($($latest.Build))." INFO
    $shouldDownload = $true
  } elseif ($latestVersion -and $existingVersion -and ($latestVersion -gt $existingVersion)) {
    Write-Log "Newer Windows 11 LCU available: $($latest.KB) build $($latest.Build) > existing $($existing.KB) build $($existing.Build)." INFO
    $shouldDownload = $true
  } elseif ($latest.UpdateId -and $existing.UpdateId -and ([string]$latest.UpdateId -ne [string]$existing.UpdateId) -and (-not $latestVersion -or -not $existingVersion)) {
    Write-Log "Catalog LCU differs from existing update and build comparison is unavailable. Downloading catalog result $($latest.KB)." WARN
    $shouldDownload = $true
  } else {
    Write-Log "Existing Windows 11 LCU is current: $($existing.KB) build $($existing.Build). No download needed." INFO
  }

  if ($shouldDownload) {
    Write-Log "Downloading latest Windows 11 $WindowsVersion $Architecture LCU to $Destination" INFO
    $args = @(
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', $downloader,
      '-WindowsVersion', $WindowsVersion,
      '-Architecture', $Architecture,
      '-OutputPath', $Destination
    )

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
      throw "Latest LCU downloader failed with exit code $($proc.ExitCode)."
    }
  }

  $current = Get-ExistingLatestLcuPackage -Destination $Destination -WindowsVersion $WindowsVersion -Architecture $Architecture
  if ($current) { Move-SupersededLcuPackages -Destination $Destination -Latest $current -WindowsVersion $WindowsVersion -Architecture $Architecture }
}

function Show-InlineProgress {
  param(
    [string]$Step,
    [int]$Percent,
    [string]$ETA = ''
  )

  $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
  $width = 30
  $filled = [int][Math]::Floor(($Percent / 100) * $width)
  if ($Percent -ge 100) {
    $bar = '=' * $width
  } elseif ($filled -le 0) {
    $bar = ('>' + ('-' * ($width - 1)))
  } else {
    $bar = (('=' * ($filled - 1)) + '>' + ('-' * ($width - $filled)))
  }

  $elapsedText = ''
  try {
    if ($script:Run -and $script:Run.StartTime) {
      $elapsedText = ' | Elapsed {0}' -f (Format-DurationHuman ((New-TimeSpan -Start $script:Run.StartTime -End (Get-Date)).TotalSeconds))
    }
  } catch { }

  $etaText = if ([string]::IsNullOrWhiteSpace($ETA)) { '' } else { " | ETA $ETA" }
  $label = if ([string]::IsNullOrWhiteSpace($Step)) { 'Working' } else { $Step }
  $stepNo = [Math]::Min(9, [Math]::Max(1, [int][Math]::Ceiling($Percent / 12.0)))
  if ($Percent -ge 100) { $stepNo = 9 }
  $label = "Step $stepNo/9: $label"
  if ($label.Length -gt 46) { $label = $label.Substring(0, 43) + '...' }
  $line = "`r[{0}] {1,3}%  {2}{3}{4}   " -f $bar, $Percent, $label, $elapsedText, $etaText
  Write-Host $line -NoNewline -ForegroundColor Cyan
}

function Complete-InlineProgress {
  Write-Host ''
}

function Get-NextPatchTuesday {
  param([datetime]$From = (Get-Date))

  $first = Get-Date -Year $From.Year -Month $From.Month -Day 1 -Hour 10 -Minute 0 -Second 0
  $offset = ([int][DayOfWeek]::Tuesday - [int]$first.DayOfWeek + 7) % 7
  $secondTuesday = $first.AddDays($offset + 7)
  if ($secondTuesday -lt $From) {
    $nextMonth = $first.AddMonths(1)
    $offset = ([int][DayOfWeek]::Tuesday - [int]$nextMonth.DayOfWeek + 7) % 7
    $secondTuesday = $nextMonth.AddDays($offset + 7)
  }
  return $secondTuesday
}

function Get-PatchTuesdayForMonth {
  param([Parameter(Mandatory)] [datetime]$Date)

  $first = Get-Date -Year $Date.Year -Month $Date.Month -Day 1 -Hour 10 -Minute 0 -Second 0
  $offset = ([int][DayOfWeek]::Tuesday - [int]$first.DayOfWeek + 7) % 7
  return $first.AddDays($offset + 7).Date
}

function Get-LcuReleaseClassification {
  param(
    [AllowNull()] [string]$Title,
    [AllowNull()] [string]$LastUpdated
  )

  $isPreview = ($Title -match '(?i)Preview')
  $releaseDate = [datetime]::MinValue
  $hasDate = [datetime]::TryParse($LastUpdated, [ref]$releaseDate)
  $patchTuesday = if ($hasDate) { Get-PatchTuesdayForMonth -Date $releaseDate } else { $null }

  $type = 'Unknown'
  $isOob = $false
  if ($isPreview) {
    $type = 'Preview'
  } elseif ($hasDate -and $patchTuesday) {
    # Monthly security LCUs normally publish on Patch Tuesday. Anything else is treated as OOB.
    if ($releaseDate.Date -eq $patchTuesday.Date) { $type = 'Monthly' }
    else { $type = 'OOB'; $isOob = $true }
  }

  return [pscustomobject]@{
    Type = $type
    IsOob = $isOob
    LastUpdated = if ($hasDate) { $releaseDate } else { $null }
    PatchTuesday = $patchTuesday
  }
}

function Get-BuildRevision {
  param([AllowNull()] [string]$Version)

  if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
  $m = [regex]::Match($Version, '(\d+)\.(\d+)$')
  if ($Version -match '^\d+\.\d+\.\d+\.(\d+)$') { return [int]$matches[1] }
  return $null
}

function Get-LcuBuildRevision {
  param([AllowNull()] [string]$Build)

  if ([string]::IsNullOrWhiteSpace($Build)) { return $null }
  $m = [regex]::Match($Build, '^(\d+)\.(\d+)$')
  if ($m.Success) { return [int]$m.Groups[2].Value }
  return $null
}

function Write-Log {
  param(
    [Parameter(Mandatory)] [string]$Message,
    [ValidateSet('INFO','WARN','ERROR','DEBUG')] [string]$Level = 'INFO'
  )

  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $line = "[$ts][$Level] $Message"

  switch ($Level) {
    'ERROR' { Write-Host $line -ForegroundColor Red }
    'WARN'  { Write-Host $line -ForegroundColor Yellow }
    'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
    default { Write-Host $line -ForegroundColor Gray }
  }

  if (Get-Variable -Name LogFile -Scope Script -ErrorAction SilentlyContinue) {
    if ($script:LogFile) {
      Add-Content -LiteralPath $script:LogFile -Value $line
    }
  }
}


function Test-PathUnderRoot {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Root
  )

  try {
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return ($pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase))
  } catch {
    return $false
  }
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

function Assert-TrustedMicrosoftFileSignature {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [string]$Context = 'downloaded package'
  )

  if ($DryRun) { return }
  if (-not (Test-Path -LiteralPath $Path)) { throw "Cannot verify missing ${Context}: $Path" }

  $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
  if ($sig.Status -ne 'Valid') {
    throw "$Context is not Authenticode-valid: $Path (status: $($sig.Status))"
  }

  $subject = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
  $issuer = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Issuer } else { '' }
  if (($subject -notmatch '(?i)Microsoft') -and ($issuer -notmatch '(?i)Microsoft')) {
    throw "$Context is signed, but not by Microsoft: $Path (subject: $subject; issuer: $issuer)"
  }

  Write-Log "$Context signature verified: $([IO.Path]::GetFileName($Path))" DEBUG
}

function Show-Progress {
  param(
    [string]$Activity,
    [string]$Status,
    [int]$Percent
  )

  $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
  Write-Progress -Activity $Activity -Status $Status -PercentComplete $Percent
  Show-InlineProgress -Step $Status -Percent $Percent
}

function Add-Warn {
  param([string]$Message)
  $script:Run.Warnings.Add($Message) | Out-Null
  Write-Log -Level WARN -Message $Message
}

function Add-Err {
  param([string]$Message)
  $script:Run.Errors.Add($Message) | Out-Null
  Write-Log -Level ERROR -Message $Message
}

function Test-PackageFailureIsBenign {
  param(
    [int]$ExitCode,
    [string]$ErrorMessage,
    [string]$PackagePath
  )

  $msg = $ErrorMessage.ToLowerInvariant()
  $path = $PackagePath.ToLowerInvariant()

  # Superseded packages are never fatal
  if ($msg -match 'superseded') { return $true }
  if ($msg -match 'already installed') { return $true }
  if ($msg -match 'package is already present') { return $true }

  # Not applicable is benign (wrong edition/architecture)
  if ($msg -match 'not applicable') { return $true }
  if ($msg -match 'cbs_e_not_applicable') { return $true }
  if ($msg -match '0x800f081e') { return $true }
  if ($msg -match 'does not apply') { return $true }

  # Exit code 50 = operation not supported / not applicable
  if ($ExitCode -eq 50 -and ($msg -match 'not applicable' -or $msg -match 'not support')) { return $true }

  # Some packages are architecture-neutral or require specific parent packages.
  # Missing files/packages are intentionally not treated as benign; those should fail loudly.
  if ($msg -match 'parent package') { return $true }

  return $false
}

function Resolve-DismFailureHint {
  param(
    [int]$ExitCode,
    [string]$Command,
    [string]$StdOut,
    [string]$StdErr
  )

  $combined = ((@($StdOut,$StdErr) -join "`n").Trim())
  switch ($ExitCode) {
    87 { return 'Invalid parameter. Vanlig orsak: flera paket i samma /PackagePath eller felaktigt byggda DISM-argument.' }
    2 { return 'Filen eller s  kv  gen hittades inte, eller source/destination kolliderar.' }
    3 { return 'Ogiltig s  kv  g. Kontrollera MountDir, ScratchDir och PackagePath.' }
    5 { return '  tkomst nekad. Kontrollera l  sning, r  ttigheter eller antivirus.' }
    32 { return 'Filen anv  nds redan av en annan process. Kontrollera stale mounts eller l  st WIM.' }
    50 { return 'Operationen st  ds inte f  r den h  r imagen eller pakettypen.' }
    default {
      if ($combined -match 'needs to be remounted') { return 'Imagen beh  ver remountas f  re servicing.' }
      if ($combined -match 'not applicable') { return 'Paketet   r inte applicerbart p   imagen. Ofta benign om fel KB/arkitektur/edition anv  nds.' }
      if ($combined -match 'superseded') { return 'Paketet   r ersatt av nyare paket. Ofta benign.' }
      if ($combined -match '0x800f081e') { return 'Paketet   r inte applicerbart p   imagen (CBS_E_NOT_APPLICABLE).' }
      if ($combined -match '0xc1510114') { return 'Imagen beh  ver remountas innan servicing.' }
      return 'Se DISM/CBS-logg f  r exakt rotorsak.'
    }
  }
}

function Test-UpdatePackageSet {
  param([Parameter(Mandatory=$false)] [AllowEmptyCollection()] [object[]]$Packages = @())

  $warnings = New-Object System.Collections.Generic.List[string]
  $items = @($Packages)
  if ($items.Count -eq 0) { return @($warnings) }

  $dupes = $items | Group-Object FileName | Where-Object { $_.Count -gt 1 }
  foreach ($dup in $dupes) {
    $warnings.Add("Dublett i Updates: $($dup.Name) ($($dup.Count) st)") | Out-Null
  }

  $lcu = @($items | Where-Object { $_.Classification -eq 'LCU' })
  if ($lcu.Count -gt 1) {
    $warnings.Add(("Flera LCU uppt  ckta: {0}" -f (($lcu | ForEach-Object FileName) -join ', '))) | Out-Null
  }

  $dotnet = @($items | Where-Object { $_.Classification -eq 'DotNetCU' })
  if ($dotnet.Count -gt 1) {
    $warnings.Add(("Flera .NET cumulative packages uppt  ckta: {0}" -f (($dotnet | ForEach-Object FileName) -join ', '))) | Out-Null
  }

  $safeOs = @($items | Where-Object { $_.Classification -eq 'SafeOSDU' })
  if ($safeOs.Count -gt 1) {
    $warnings.Add(("Flera Safe OS Dynamic Update-paket uppt  ckta: {0}" -f (($safeOs | ForEach-Object FileName) -join ', '))) | Out-Null
  }

  return @($warnings)
}

function Get-InstalledPackageIdentities {
  param([Parameter(Mandatory)] [string]$MountDir)

  $out = Invoke-Dism -Arguments @('/English',"/Image:$MountDir",'/Get-Packages')
  $idents = @()
  foreach ($ln in ($out.StdOut -split "`r?`n")) {
    if ($ln -match '^Package Identity\s*:\s*(.+)$') {
      $idents += $matches[1].Trim()
    }
  }
  return @($idents)
}

function Add-StepResult {
  param(
    [Parameter(Mandatory)] [string]$Name,
    [datetime]$StartTime,
    [datetime]$EndTime,
    [string]$Status = 'OK',
    [string]$Details = ''
  )

  if (-not $StartTime) { $StartTime = Get-Date }
  if (-not $EndTime) { $EndTime = Get-Date }

  $duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalSeconds, 2)
  $script:Run.Steps.Add([pscustomobject]@{
    Name = $Name
    StartTime = $StartTime
    EndTime = $EndTime
    DurationSeconds = $duration
    Status = $Status
    Details = $Details
  }) | Out-Null
}

function Format-DurationHuman {
  param([double]$Seconds)

  if ($Seconds -lt 0) { $Seconds = 0 }
  $ts = [timespan]::FromSeconds([math]::Round($Seconds))
  if ($ts.TotalHours -ge 1) { return $ts.ToString('hh\:mm\:ss') }
  return $ts.ToString('mm\:ss')
}

function Get-BuildHistoryPath {
  return Join-Path $script:Paths['Reports'] 'build-history.json'
}

function Get-OutputTotalSizeBytes {
  param([pscustomobject]$Config)

  $bytes = 0L
  $finalWim = Join-Path $script:Paths['Output'] $Config.Output.InstallWimName
  if (Test-Path -LiteralPath $finalWim) { $bytes += (Get-Item -LiteralPath $finalWim).Length }
  $swmBase = Join-Path $script:Paths['Output'] $Config.Output.SplitBaseName
  $swmPattern = ('{0}*.swm' -f [IO.Path]::GetFileNameWithoutExtension($swmBase))
  $swmDir = Split-Path -Parent $swmBase
  $swmFiles = Get-ChildItem -LiteralPath $swmDir -Filter $swmPattern -File -ErrorAction SilentlyContinue
  foreach ($file in $swmFiles) { $bytes += $file.Length }
  return $bytes
}

function Initialize-EtaState {
  param([pscustomobject]$Config)

  $historyPath = Get-BuildHistoryPath
  $script:Run.ETA.HistoryPath = $historyPath
  $history = @()
  if ((-not $DryRun) -and (Test-Path -LiteralPath $historyPath)) {
    try {
      $raw = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8
      if ($raw.Trim()) {
        $loaded = $raw | ConvertFrom-Json
        if ($loaded -is [System.Array]) { $history = @($loaded) }
        elseif ($loaded) { $history = @($loaded) }
      }
    } catch {
      Add-Warn "Failed to load ETA history: $($_.Exception.Message)"
    }
  }
  $script:Run.ETA.History = @($history)

  $inputBytes = 0L
  if ($script:Run.Input.Path -and (Test-Path -LiteralPath $script:Run.Input.Path)) {
    $inputBytes = (Get-Item -LiteralPath $script:Run.Input.Path).Length
  }
  $updateFiles = Get-ChildItem -LiteralPath $script:Paths['Updates'] -File -ErrorAction SilentlyContinue
  $measureResult = $updateFiles | Measure-Object Length -Sum
  $updateBytes = if ($null -ne $measureResult -and $null -ne $measureResult.Sum) { [long]$measureResult.Sum } else { 0L }

  $historyCount = @($history).Count
  if ($historyCount -gt 0) {
    $measureAvg = $history | Measure-Object EstimatedSeconds -Average -ErrorAction SilentlyContinue
    $avg = if ($null -ne $measureAvg -and $null -ne $measureAvg.Average) { $measureAvg.Average } else { $null }
    if ($null -eq $avg) {
      $measureAvg2 = $history | Measure-Object DurationSeconds -Average -ErrorAction SilentlyContinue
      $avg = if ($null -ne $measureAvg2 -and $null -ne $measureAvg2.Average) { $measureAvg2.Average } else { $null }
    }
    if ($null -eq $avg) { $avg = 3600 }
    $estimatedSeconds = [math]::Round([double]$avg)
  } else {
    $estimatedSeconds = 900
    if ($script:Run.Input.Type -eq 'ISO') { $estimatedSeconds += 300 }
    elseif ($script:Run.Input.Type -eq 'ESD') { $estimatedSeconds += 420 }
    $estimatedSeconds += [math]::Round($inputBytes / 1GB * 120)
    $estimatedSeconds += [math]::Round($updateBytes / 1GB * 240)
    $estimatedSeconds += 120
  }

  $script:Run.ETA.Current = [ordered]@{
    StartedAt = Get-Date
    HistoryCount = $historyCount
    InputBytes = $inputBytes
    UpdateBytes = $updateBytes
    EstimatedSeconds = [double]$estimatedSeconds
    EstimatedMin = [math]::Round($estimatedSeconds / 60.0, 1)
    EstimatedMax = [math]::Round(($estimatedSeconds * 1.35) / 60.0, 1)
    RemainingSeconds = [double]$estimatedSeconds
    FinishAt = (Get-Date).AddSeconds($estimatedSeconds)
  }

  Write-Log ("ETA estimate: {0}-{1} min (history runs: {2})" -f $script:Run.ETA.Current.EstimatedMin, $script:Run.ETA.Current.EstimatedMax, $historyCount) INFO
  Write-Log ("ETA finish estimate: {0}" -f $script:Run.ETA.Current.FinishAt.ToString('yyyy-MM-dd HH:mm:ss')) INFO
}

function Update-EtaProgress {
  param(
    [string]$CurrentStep,
    [double]$PercentComplete = -1
  )

  $elapsed = (New-TimeSpan -Start $script:Run.StartTime -End (Get-Date)).TotalSeconds
  $remaining = [math]::Max(0, [double]$script:Run.ETA.Current.EstimatedSeconds - $elapsed)
  $script:Run.ETA.Current.RemainingSeconds = $remaining
  $script:Run.ETA.Current.FinishAt = (Get-Date).AddSeconds($remaining)

  if ($CurrentStep) {
    $remainingText = Format-DurationHuman $remaining
    Write-Log ("ETA [{0}] elapsed={1} remaining~={2} finish~={3}" -f $CurrentStep, (Format-DurationHuman $elapsed), $remainingText, $script:Run.ETA.Current.FinishAt.ToString('HH:mm:ss')) INFO
    if ($PercentComplete -ge 0) { Show-InlineProgress -Step $CurrentStep -Percent ([int]$PercentComplete) -ETA $remainingText }
  }
}

function Save-EtaHistory {
  param([pscustomobject]$Config)

  if ($DryRun) { return }
  $historyPath = $script:Run.ETA.HistoryPath
  if (-not $historyPath) { $historyPath = Get-BuildHistoryPath }

  $entry = [ordered]@{
    Timestamp = (Get-Date).ToString('s')
    DurationSeconds = [math]::Round(($script:Run.EndTime - $script:Run.StartTime).TotalSeconds, 2)
    EstimatedSeconds = [math]::Round([double]$script:Run.ETA.Current.EstimatedSeconds, 2)
    InputType = $script:Run.Input.Type
    InputBytes = $script:Run.ETA.Current.InputBytes
    UpdateBytes = $script:Run.ETA.Current.UpdateBytes
    PackageCount = @($script:Run.Packages.Sorted).Count
    OutputBytes = (Get-OutputTotalSizeBytes -Config $Config)
    StepDurations = @($script:Run.Steps.ToArray() | ForEach-Object { [ordered]@{ Name = $_.Name; DurationSeconds = $_.DurationSeconds } })
    PackageNames = @($script:Run.Packages.Injected | ForEach-Object { $_.FileName })
  }

  $history = @($script:Run.ETA.History) + @($entry)
  if (@($history).Count -gt 20) {
    $history = @($history | Select-Object -Last 20)
  }

  $history | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $historyPath -Encoding UTF8
}

function New-HtmlRows {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Items,
    [Parameter(Mandatory)] [scriptblock]$Renderer,
    [string]$EmptyMessage = 'None'
  )

  if (-not $Items -or $Items.Count -eq 0) {
    return "<tr><td colspan='99'><i>$EmptyMessage</i></td></tr>"
  }

  return (($Items | ForEach-Object $Renderer) -join "`n")
}

function Invoke-PreflightCleanup {
  Write-Log -Message 'Rensar BuildWIM mount-punkter (pre-flight cleanup)' -Level 'INFO'
  try {
    & dism.exe /English /Cleanup-Wim 2>&1 | Out-Null
  } catch {
    Write-Log -Message "Fel vid pre-flight dism /Cleanup-Wim: $_" -Level 'WARN'
  }

  $ownedMountRoot = if ($script:Paths.Contains('Mount')) { [string]$script:Paths['Mount'] } else { Join-Path $Root 'Mount' }
  try {
    $dismInfo = & dism.exe /English /Get-MountedWimInfo 2>&1
    if ($dismInfo) {
      $mountMatches = $dismInfo | Select-String 'Mount Dir'
      foreach ($m in $mountMatches) {
        $parts = $m.Line.Split(':',2)
        if ($parts.Count -lt 2) { continue }
        $mount = $parts[1].Trim()
        if (-not $mount) { continue }
        if (-not (Test-PathUnderRoot -Path $mount -Root $ownedMountRoot)) {
          Write-Log -Message "Skippar extern WIM-mount utanför BuildWIM root: $mount" -Level 'WARN'
          continue
        }
        Write-Log -Message "Avmonterar BuildWIM-mount: $mount" -Level 'INFO'
        try {
          & dism.exe /English /Unmount-Wim /MountDir:$mount /Discard 2>&1 | Out-Null
        } catch {
          Write-Log -Message "Misslyckades med att avmontera ${mount}: $_" -Level 'WARN'
        }
      }
    }
  } catch {
    Write-Log -Message "Fel vid Get-MountedWimInfo: $_" -Level 'WARN'
  }
}

# ----------------------------
# Validation helpers
# ----------------------------
function Test-IsAdministrator {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-FreeDiskSpace {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [int]$MinGB
  )

  $root = (Get-Item -LiteralPath $Path).PSDrive.Root
  $drive = Get-PSDrive -Name ($root.TrimEnd('\\').TrimEnd(':'))
  $freeGB = [math]::Round($drive.Free/1GB, 2)
  Write-Log "Free disk space on $($drive.Name): $freeGB GB (min required: $MinGB GB)" INFO
  if ($freeGB -lt $MinGB) {
    throw "Insufficient disk space on drive $($drive.Name). Free: $freeGB GB, required: $MinGB GB"
  }
}

function Initialize-BuildFolders {
  param([string]$Root)
  $folders = @('Input','Updates','Mount','Output','Logs','Temp','Tools','Config','Reports','Defender')
  foreach ($f in $folders) {
    $p = Join-Path $Root $f
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
    $script:Paths[$f] = $p
  }

  $script:Paths['Scratch'] = Join-Path $script:Paths['Temp'] 'Scratch'
  if (-not (Test-Path -LiteralPath $script:Paths['Scratch'])) { New-Item -ItemType Directory -Path $script:Paths['Scratch'] | Out-Null }
}

function Test-Prerequisites {
  param([pscustomobject]$Config)

  if (-not (Test-IsAdministrator)) {
    throw 'Script must be run as Administrator.'
  }

  # DISM
  $dism = Join-Path $env:windir 'System32\dism.exe'
  if (-not (Test-Path -LiteralPath $dism)) {
    throw "DISM not found: $dism"
  }

  # Basic folders
  foreach ($k in @('Input','Updates','Mount','Output','Logs','Temp','Reports','Config')) {
    if (-not (Test-Path -LiteralPath $script:Paths[$k])) {
      throw "Missing required folder: $($script:Paths[$k])"
    }
  }
}

# ----------------------------
# Input discovery
# ----------------------------
function Test-InputImageExists {
  param([Parameter(Mandatory)] [string]$InputFolder)

  $images = @(Get-ChildItem -LiteralPath $InputFolder -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @('.iso','.wim','.esd') -or $_.Name -in @('install.wim','install.esd') })

  return ($images.Count -gt 0)
}

function Invoke-Windows11IsoAutoDownload {
  param([Parameter(Mandatory)] [string]$Destination)

  if ($SkipAutoDownloadWindows11Iso) {
    Write-Log "Windows 11 ISO auto-download is disabled by -SkipAutoDownloadWindows11Iso." INFO
    return
  }

  if (Test-InputImageExists -InputFolder $Destination) { return }

  $downloader = Join-Path $PSScriptRoot 'Get-Windows11Iso.ps1'
  if (-not (Test-Path -LiteralPath $downloader)) {
    throw "No input image found in $Destination and Windows 11 ISO downloader is missing: $downloader"
  }

  if ($DryRun) {
    Write-Log "No input image found in $Destination. Windows 11 ISO auto-download would run, but DryRun is active." WARN
    return
  }

  Write-Log "No ISO/WIM/ESD found in $Destination. Downloading official Windows 11 ISO..." INFO
  $args = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $downloader,
    '-OutputDirectory', $Destination
  )

  $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
  if ($proc.ExitCode -ne 0) {
    throw "Windows 11 ISO downloader failed with exit code $($proc.ExitCode)."
  }

  if (-not (Test-InputImageExists -InputFolder $Destination)) {
    throw "Windows 11 ISO downloader completed, but no ISO/WIM/ESD was found in $Destination."
  }

  Write-Log "Windows 11 ISO auto-download completed." INFO
}

function Get-InputSourceType {
  param(
    [string]$InputFolder,
    [string]$TempFolder
  )

  $candidates = @(Get-ChildItem -LiteralPath $InputFolder -File -ErrorAction SilentlyContinue)

  $iso = $candidates | Where-Object { $_.Extension -ieq '.iso' } | Select-Object -First 1
  if ($iso) { return [pscustomobject]@{ Type='ISO'; Path=$iso.FullName } }

  $wim = $candidates | Where-Object { $_.Name -ieq 'install.wim' -or $_.Extension -ieq '.wim' } | Select-Object -First 1
  if ($wim) { return [pscustomobject]@{ Type='WIM'; Path=$wim.FullName } }

  $esd = $candidates | Where-Object { $_.Name -ieq 'install.esd' -or $_.Extension -ieq '.esd' } | Select-Object -First 1
  if ($esd) { return [pscustomobject]@{ Type='ESD'; Path=$esd.FullName } }

  if ($TempFolder) {
    $tempInstallWim = Join-Path $TempFolder 'install.wim'
    if (Test-Path -LiteralPath $tempInstallWim) {
      Write-Log "No input file in $InputFolder, reusing existing temp WIM: $tempInstallWim" INFO
      return [pscustomobject]@{ Type='WIM'; Path=$tempInstallWim }
    }

    $tempInstallEsd = Join-Path $TempFolder 'install.esd'
    if (Test-Path -LiteralPath $tempInstallEsd) {
      Write-Log "No input file in $InputFolder, reusing existing temp ESD: $tempInstallEsd" INFO
      return [pscustomobject]@{ Type='ESD'; Path=$tempInstallEsd }
    }

    $anyWim = @(Get-ChildItem -LiteralPath $TempFolder -Filter '*.wim' -ErrorAction SilentlyContinue)
    if ($anyWim) {
      Write-Log "No input file in $InputFolder, reusing existing WIM in Temp: $($anyWim[0].FullName)" INFO
      return [pscustomobject]@{ Type='WIM'; Path=$anyWim[0].FullName }
    }
  }

  throw "No input files found in $InputFolder and no .wim/.esd found in $TempFolder"
}

function Mount-IsoIfNeeded {
  param(
    [Parameter(Mandatory)] [string]$IsoPath,
    [string[]]$SearchRelativePaths
  )

  if ($DryRun) {
    Write-Log "[DryRun] Would mount ISO: $IsoPath" INFO
    $rel = @($SearchRelativePaths | Where-Object { $_ }) | Select-Object -First 1
    if (-not $rel) { $rel = 'sources\install.wim' }
    return ("DRYRUN:\{0}" -f $rel)
  }

  Write-Log "Mounting ISO: $IsoPath" INFO
  $img = Mount-DiskImage -ImagePath $IsoPath -PassThru
  Start-Sleep -Seconds 2
  $vol = ($img | Get-Volume | Select-Object -First 1)
  if (-not $vol -or -not $vol.DriveLetter) { throw 'Failed to get drive letter for mounted ISO.' }

  $drive = "$($vol.DriveLetter):\\"
  $script:IsoMount.Mounted = $true
  $script:IsoMount.DriveLetter = $drive
  $script:IsoMount.ImagePath = $IsoPath

  Write-Log "ISO mounted at $drive" INFO

  foreach ($rel in $SearchRelativePaths) {
    $p = Join-Path $drive $rel
    if (Test-Path -LiteralPath $p) { return $p }
  }

  throw "Could not find install.wim/esd in ISO. Searched: $($SearchRelativePaths -join ', ')"
}

function Dismount-IsoIfNeeded {
  if (-not $script:IsoMount.Mounted) { return }
  if ($DryRun) {
    Write-Log "[DryRun] Would dismount ISO: $($script:IsoMount.ImagePath)" INFO
    return
  }
  Write-Log "Dismounting ISO: $($script:IsoMount.ImagePath)" INFO
  Dismount-DiskImage -ImagePath $script:IsoMount.ImagePath
  $script:IsoMount.Mounted = $false
}

# ----------------------------
# DISM wrappers
# ----------------------------
function Invoke-Dism {
  param(
    [Parameter(Mandatory)] [string[]]$Arguments,
    [switch]$AllowNonZero
  )

  $dismExe = Join-Path $env:windir 'System32\dism.exe'
  $argLine = ($Arguments -join ' ')
  $cmd = "dism.exe $argLine"

  $script:Run.DismCommands.Add($cmd) | Out-Null
  Write-Log "DISM> $cmd" DEBUG

  if ($DryRun) {
    Write-Log "[DryRun] Skipping DISM execution." INFO
    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $dismExe
  $psi.Arguments = $argLine
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()

  # Read stdout line-by-line for real-time DISM progress parsing
  $stdoutLines = New-Object System.Collections.Generic.List[string]
  $lastDismPercent = -1
  while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
    $stdoutLines.Add($line) | Out-Null
    # DISM outputs progress as "[==== 10.0% ====]" or "[ 5.0%]" etc.
    if ($line -match '(\d+(?:\.\d+)?)\s*%') {
      $dismPercent = [int][math]::Floor([double]$matches[1])
      if ($dismPercent -ne $lastDismPercent) {
        $lastDismPercent = $dismPercent
        Show-InlineProgress -Step ("DISM {0}%" -f $dismPercent) -Percent $dismPercent
      }
    }
  }
  if ($lastDismPercent -ge 0) {
    Complete-InlineProgress
  }

  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  $stdout = ($stdoutLines -join "`r`n")
  if ($stdout) { Add-Content -LiteralPath $script:LogFile -Value $stdout }
  if ($stderr) { Add-Content -LiteralPath $script:LogFile -Value $stderr }

  if (($p.ExitCode -ne 0) -and (-not $AllowNonZero)) {
    $hint = Resolve-DismFailureHint -ExitCode $p.ExitCode -Command $cmd -StdOut $stdout -StdErr $stderr
    throw "DISM failed (exit $($p.ExitCode)). Command: $cmd. Hint: $hint"
  }

  return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

# ----------------------------
# Image processing
# ----------------------------
function Get-ImageInfo {
  param([Parameter(Mandatory)] [string]$ImagePath)

  if ($DryRun) {
    Write-Log "[DryRun] Would inspect image info: $ImagePath" INFO
    return @([pscustomobject]@{
      Index = 1
      Name = 'Windows 11 Pro'
      Description = 'Windows 11 Pro'
      Architecture = 'x64'
      Version = 'DryRun'
      ServicePackBuild = ''
    })
  }

  $r = Invoke-Dism -Arguments @('/English','/Get-WimInfo',"/WimFile:$ImagePath")

  # Parse indices and names from DISM output (robust-ish for English output)
  $lines = ($r.StdOut -split "`r?`n")
  $items = @()
  $current = $null

  foreach ($ln in $lines) {
    if ($ln -match '^Index\s*:\s*(\d+)') {
      if ($current) { $items += [pscustomobject]$current }
      $current = [ordered]@{ Index = [int]$matches[1]; Name=''; Description=''; Architecture=''; Version=''; ServicePackBuild=''; }
    }
    elseif ($current -and $ln -match '^Name\s*:\s*(.+)$') { $current.Name = $matches[1].Trim() }
    elseif ($current -and $ln -match '^Description\s*:\s*(.+)$') { $current.Description = $matches[1].Trim() }
    elseif ($current -and $ln -match '^Architecture\s*:\s*(.+)$') { $current.Architecture = $matches[1].Trim() }
    elseif ($current -and $ln -match '^Version\s*:\s*(.+)$') { $current.Version = $matches[1].Trim() }
    elseif ($current -and $ln -match '^ServicePack Build\s*:\s*(.+)$') { $current.ServicePackBuild = $matches[1].Trim() }
  }
  if ($current) { $items += [pscustomobject]$current }

  if (-not $items) {
    throw "Failed to parse WIM info from DISM output for: $ImagePath"
  }

  foreach ($item in @($items)) {
    try {
      $detail = Invoke-Dism -Arguments @('/English','/Get-WimInfo',"/WimFile:$ImagePath","/Index:$($item.Index)")
      foreach ($ln in ($detail.StdOut -split "`r?`n")) {
        if ($ln -match '^Name\s*:\s*(.+)$') { $item.Name = $matches[1].Trim() }
        elseif ($ln -match '^Description\s*:\s*(.+)$') { $item.Description = $matches[1].Trim() }
        elseif ($ln -match '^Architecture\s*:\s*(.+)$') { $item.Architecture = $matches[1].Trim() }
        elseif ($ln -match '^Version\s*:\s*(.+)$') { $item.Version = $matches[1].Trim() }
        elseif ($ln -match '^ServicePack Build\s*:\s*(.+)$') { $item.ServicePackBuild = $matches[1].Trim() }
      }
    } catch {
      Add-Warn "Could not read detailed WIM info for index $($item.Index): $($_.Exception.Message)"
    }
  }

  return $items
}

function Get-Windows11ProIndex {
  param(
    [Parameter(Mandatory)] [object[]]$ImageInfo,
    [Parameter(Mandatory)] [string]$EditionNameMatch
  )

  $match = $ImageInfo | Where-Object { $_.Name -eq $EditionNameMatch -or $_.Name -like "*$EditionNameMatch*" } | Select-Object -First 1
  if (-not $match) {
    $names = ($ImageInfo | ForEach-Object { "Index $($_.Index): $($_.Name)" }) -join '; '
    throw "Windows 11 Pro not found. Expected match: '$EditionNameMatch'. Found: $names"
  }
  return [int]$match.Index
}

function Convert-EsdToWim {
  param(
    [Parameter(Mandatory)] [string]$EsdPath,
    [Parameter(Mandatory)] [string]$WimOutPath,
    [int]$Index = 0
  )

  # If Index=0, export all indices (temporary), we'll later export Pro-only.
  $args = @('/English','/Export-Image',"/SourceImageFile:$EsdPath", "/DestinationImageFile:$WimOutPath",'/Compress:Max','/CheckIntegrity')
  if ($Index -gt 0) { $args += "/SourceIndex:$Index" }

  Write-Log "Converting ESD to WIM: $EsdPath -> $WimOutPath" INFO
  Invoke-Dism -Arguments $args | Out-Null
  return $WimOutPath
}

function Export-ProEditionOnly {
  param(
    [Parameter(Mandatory)] [string]$SourceWim,
    [Parameter(Mandatory)] [int]$ProIndex,
    [Parameter(Mandatory)] [string]$DestWim
  )

  if (Test-Path -LiteralPath $DestWim) {
    Write-Log "Removing existing working WIM: $DestWim" INFO
    if (-not $DryRun) {
      try {
        Remove-Item -LiteralPath $DestWim -Force -ErrorAction Stop
      } catch {
        Write-Log "Warning: Could not remove $DestWim. Trying to clean mounts first..." WARN
        Clear-StaleMounts
        Start-Sleep -Seconds 2
        try {
          Remove-Item -LiteralPath $DestWim -Force -ErrorAction Stop
        } catch {
          Write-Log "Warning: File still locked. Trying to rename instead..." WARN
          $renamed = $DestWim + ".old-" + (Get-Date).ToString('HHmmss')
          Rename-Item -LiteralPath $DestWim -NewName (Split-Path $renamed -Leaf) -Force -ErrorAction SilentlyContinue
        }
      }
    }
  }

  Write-Log "Exporting Pro-only WIM (Index $ProIndex): $SourceWim -> $DestWim" INFO

  # Retry logic for locked files (exit code 32)
  $maxRetries = 3
  $retryCount = 0
  $success = $false

  while (-not $success -and $retryCount -lt $maxRetries) {
    try {
      Invoke-Dism -Arguments @('/English','/Export-Image',"/SourceImageFile:$SourceWim","/SourceIndex:$ProIndex","/DestinationImageFile:$DestWim",'/Compress:Max','/CheckIntegrity') | Out-Null

      if ($DryRun) {
        Write-Log "[DryRun] Would verify exported WIM: $DestWim" INFO
        $success = $true
        continue
      }

      # Verify exported WIM before proceeding
      Start-Sleep -Seconds 2
      if (-not (Test-Path -LiteralPath $DestWim)) {
        throw "Export completed but WIM file not found: $DestWim"
      }
      $exportedSize = (Get-Item -LiteralPath $DestWim).Length
      if ($exportedSize -lt 1MB) {
        throw "Export completed but WIM file is too small ($([math]::Round($exportedSize/1MB, 2)) MB): $DestWim"
      }
      Write-Log "Exported WIM verified: $([math]::Round($exportedSize/1MB, 2)) MB" INFO

      $success = $true
    } catch {
      $retryCount++
      if ($retryCount -lt $maxRetries) {
        Write-Log "Warning: DISM failed (possibly locked). Retrying ($retryCount/$maxRetries) after cleaning mounts..." WARN
        Clear-StaleMounts
        Start-Sleep -Seconds 3
      } else {
        throw
      }
    }
  }

  return $DestWim
}

function Mount-InstallImage {
  param(
    [Parameter(Mandatory)] [string]$WimPath,
    [Parameter(Mandatory)] [string]$MountDir,
    [int]$Index = 1,
    [string]$ScratchDir
  )

  if (-not (Test-Path -LiteralPath $MountDir)) { New-Item -ItemType Directory -Path $MountDir | Out-Null }
  Write-Log "Mounting WIM: $WimPath (Index $Index) -> $MountDir" INFO

  $args = @('/English','/Mount-Image',"/ImageFile:$WimPath","/Index:$Index","/MountDir:$MountDir")
  if ($ScratchDir) { $args += "/ScratchDir:$ScratchDir" }

  Invoke-Dism -Arguments $args | Out-Null
}

function New-IsolatedMountDir {
  param(
    [Parameter(Mandatory)] [string]$MountRoot,
    [string]$Prefix = 'Mount'
  )

  if (-not (Test-Path -LiteralPath $MountRoot)) {
    New-Item -ItemType Directory -Path $MountRoot -Force | Out-Null
  }

  $mountDir = Join-Path $MountRoot ("$Prefix-" + (Get-Date).ToString('yyyyMMdd-HHmmss'))
  if (Test-Path -LiteralPath $mountDir) {
    Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
  return $mountDir
}

function Dismount-InstallImage {
  param(
    [Parameter(Mandatory)] [string]$MountDir,
    [switch]$Commit,
    [string]$ScratchDir
  )

  $mode = if ($Commit) { '/Commit' } else { '/Discard' }
  Write-Log "Dismounting image: $MountDir ($mode)" INFO

  $args = @('/English','/Unmount-Image',"/MountDir:$MountDir",$mode)
  if ($ScratchDir) { $args += "/ScratchDir:$ScratchDir" }

  Invoke-Dism -Arguments $args -AllowNonZero:$false | Out-Null
}

function Remount-InstallImage {
  param([Parameter(Mandatory)] [string]$MountDir)

  Write-Log "Remounting image: $MountDir" INFO
  Invoke-Dism -Arguments @('/English','/Remount-Image',"/MountDir:$MountDir") | Out-Null
}

function Test-MountedImageReady {
  param(
    [Parameter(Mandatory)] [string]$MountDir,
    [string]$ScratchDir
  )

  $args = @('/English',"/Image:$MountDir",'/Get-Features','/Format:Table')
  if ($ScratchDir) { $args += "/ScratchDir:$ScratchDir" }

  try {
    Invoke-Dism -Arguments $args | Out-Null
    return $true
  } catch {
    Write-Log "Mounted image not ready for servicing yet: $($_.Exception.Message)" WARN
    return $false
  }
}

function Ensure-MountedImageReady {
  param(
    [Parameter(Mandatory)] [string]$MountDir,
    [string]$ScratchDir,
    [int]$MaxAttempts = 3
  )

  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    if (Test-MountedImageReady -MountDir $MountDir -ScratchDir $ScratchDir) {
      if ($attempt -gt 1) {
        Write-Log "Mounted image became ready after remount attempt $attempt." INFO
      }
      return
    }

    if ($attempt -ge $MaxAttempts) {
      throw "Mounted image at $MountDir never became ready for servicing after $MaxAttempts attempts."
    }

    Write-Log "Mounted image requires remount before servicing, attempt $attempt of $MaxAttempts." WARN
    Remount-InstallImage -MountDir $MountDir
    Start-Sleep -Seconds 2
  }
}

function Clear-StaleMounts {
  Write-Log "Clearing stale mount states (Cleanup-Wim)" INFO
  Invoke-Dism -Arguments @('/English','/Cleanup-Wim') -AllowNonZero | Out-Null
}

# ----------------------------
# Updates classification + sort
# ----------------------------
function Get-PackageClassification {
  param([Parameter(Mandatory)] [string]$Path)

  $name = [IO.Path]::GetFileName($Path)
  $type = 'Other'
  $details = ''
  $kbNumber = ''

  # Prefer metadata sidecar from Get-LatestWindows11LCU.ps1 when available.
  $metadataPath = "$Path.metadata.json"
  if (Test-Path -LiteralPath $metadataPath) {
    try {
      $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($metadata.KB) { $kbNumber = [string]$metadata.KB }
      if ($metadata.Title) { $details = [string]$metadata.Title }
      if ($metadata.PSObject.Properties['PackageType'] -and ([string]$metadata.PackageType) -eq 'SafeOS') { $type = 'SafeOSDU' }
      elseif ($metadata.Title -match '(?i)Safe OS Dynamic Update') { $type = 'SafeOSDU' }
      elseif ($metadata.Title -match '(?i)\.NET') { $type = 'DotNetCU' }
      elseif ($metadata.Title -match '(?i)Cumulative Update' -and $metadata.Title -match '(?i)Windows 11') { $type = 'LCU' }
      elseif ($metadata.Classification -match '(?i)Security') { $type = 'Security' }
    } catch {
      Write-Log "Could not read update metadata sidecar: $metadataPath ($($_.Exception.Message))" WARN
    }
  }

  # Try to get proper package identity from DISM
  try {
    $dismInfo = Invoke-Dism -Arguments @('/English','/Get-PackageInfo',"/PackagePath:$Path") -AllowNonZero
    if ($dismInfo.ExitCode -eq 0 -and $dismInfo.StdOut) {
      $out = $dismInfo.StdOut
      if ($out -match '(?mi)Package Identity\s*:\s*([^\r\n]+)') {
        $ident = $matches[1].Trim()
        $details = $ident
        if ($ident -match '(?i)Package_\d+~([^~]+)~') {
          $kbNumber = $matches[1].Trim()
        }
      }
      if ($out -match '(?mi)Classification\s*:\s*(\w+)') {
        $dismClass = $matches[1].Trim().ToUpperInvariant()
        if ($type -in @('DotNetCU','SafeOSDU')) {
          # Keep sidecar/title-derived specialized package types. DISM often reports
          # both .NET CU and Safe OS DU simply as UPDATE/CUMULATIVE, which is not
          # enough to decide the correct servicing target.
        }
        elseif ($dismClass -eq 'UPDATE') {
          if ($out -match '(?i)SERVICING') { $type = 'SSU' }
          elseif ($out -match '(?i)SECURITY') { $type = 'Security' }
          elseif ($out -match '(?i)CUMULATIVE') { $type = 'LCU' }
          elseif ($out -match '(?i)SETUP') { $type = 'Other' }
          else { $type = 'Other' }
        }
        elseif ($dismClass -in @('SSU','SECURITY','LCU','UPDATE','HOTFIX')) { $type = $dismClass }
      }
    }
  }
  catch {
    # DISM could not read package info     fall through to filename heuristics
  }

  # Fallback: filename-based heuristics
  if ($type -eq 'Other') {
    if ($name -match '(?i)ssu') { $type = 'SSU' }
    elseif ($name -match '(?i)safeos|safe-os|winre') { $type = 'SafeOSDU' }
    elseif ($name -match '(?i)lcu|cumulative') { $type = 'LCU' }
    elseif ($name -match '(?i)ndp|dotnet|\.net') { $type = 'DotNetCU' }
    elseif ($name -match '(?i)setup') { $type = 'Setup' }
    elseif ($name -match '(?i)hotfix|kb\d+') { $type = 'Hotfix' }
  }

  # Extract KB number from filename as backup
  if (-not $kbNumber) {
    if ($name -match '(?i)kb(\d+)') { $kbNumber = "KB$($matches[1])" }
  }

  return [pscustomobject]@{
    Path = $Path
    FileName = $name
    Classification = $type
    Details = if ($details) { $details } else { $kbNumber }
    KBNumber = $kbNumber
  }
}

function Sort-PackagesByServicingOrder {
  param([Parameter(Mandatory=$false)] [AllowEmptyCollection()] [object[]]$Packages = @())

  if (-not $Packages -or $Packages.Count -eq 0) { return @() }
  $order = @{
    SSU = 0
    LCU = 10
    DotNetCU = 20
    SafeOSDU = 25
    Security = 30
    Hotfix = 40
    Setup = 50
    Other = 90
  }
  $sorted = @($Packages | Sort-Object @{ Expression = { if ($order.ContainsKey($_.Classification)) { $order[$_.Classification] } else { 99 } } }, @{ Expression = { $_.FileName } })
  return $sorted
}

function Add-OfflinePackages {
  param(
    [Parameter(Mandatory)] [string]$MountDir,
    [Parameter(Mandatory=$false)] [AllowEmptyCollection()] [object[]]$SortedPackages = @(),
    [string]$ScratchDir
  )

  $expandedPackages = @()
  foreach ($pkg in @($SortedPackages)) {
    $pkgPaths = @()

    if ($pkg.Path -is [System.Array]) {
      $pkgPaths = @($pkg.Path)
    } elseif ($pkg.Path) {
      $pathText = [string]$pkg.Path
      $matches = [regex]::Matches($pathText, '[A-Za-z]:\\[^\r\n]+?\.(?:msu|cab)')
      if ($matches.Count -gt 1) {
        $pkgPaths = @($matches | ForEach-Object { $_.Value.Trim() })
      } else {
        $pkgPaths = @($pathText)
      }
    }

    foreach ($singlePath in @($pkgPaths)) {
      $trimmedPath = ([string]$singlePath).Trim()
      if (-not $trimmedPath) { continue }
      $expandedPackages += [pscustomobject]@{
        Path = $trimmedPath
        FileName = [IO.Path]::GetFileName($trimmedPath)
        Classification = $pkg.Classification
        Details = $pkg.Details
        KBNumber = $pkg.KBNumber
      }
    }
  }

  $total = @($expandedPackages).Count
  for ($i = 0; $i -lt $total; $i++) {
    $pkg = $expandedPackages[$i]
    Write-Log (("Adding package [{0}] ({1}/{2}): {3}" -f $pkg.Classification, ($i+1), $total, $pkg.FileName)) INFO

    $args = @('/English',"/Image:$MountDir",'/Add-Package',"/PackagePath:$($pkg.Path)")
    if ($ScratchDir) { $args += "/ScratchDir:$ScratchDir" }

    try {
      Assert-TrustedMicrosoftFileSignature -Path $pkg.Path -Context "Update package $($pkg.FileName)"
      Invoke-Dism -Arguments $args | Out-Null
      $script:Run.Packages.Injected += $pkg
    } catch {
      $reason = $_.Exception.Message
      $exitCode = 0
      if ($reason -match 'exit (\d+)') { $exitCode = [int]$matches[1] }
      $isBenign = Test-PackageFailureIsBenign -ExitCode $exitCode -ErrorMessage $reason -PackagePath $pkg.Path
      if ($isBenign) {
        Add-Warn "Skipping benign package [$($pkg.Classification)]: $($pkg.FileName)     $($reason -replace 'DISM failed.*Hint: ','')"
        $script:Run.Packages.Skipped += [pscustomobject]@{
          FileName = $pkg.FileName
          Classification = $pkg.Classification
          Path = $pkg.Path
          Reason = $reason
          Benign = $true
        }
        continue
      } else {
        Add-Warn "Fatal package injection failure: $($pkg.FileName). Error: $reason"
        $script:Run.Packages.Skipped += [pscustomobject]@{
          FileName = $pkg.FileName
          Classification = $pkg.Classification
          Path = $pkg.Path
          Reason = $reason
          Benign = $false
        }
        throw
      }
    }
  }
}


function Get-ConfigPropertyValue {
  param(
    [Parameter(Mandatory)] [AllowNull()] [object]$Object,
    [Parameter(Mandatory)] [string]$Name,
    $Default = $null
  )

  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $Default }
  return $prop.Value
}

function Get-DefenderOfflineUpdateUrl {
  param([string]$Architecture)

  switch -Regex ($Architecture) {
    '^(x64|amd64)$' { return 'https://go.microsoft.com/fwlink/?linkid=2144531' }
    '^(x86|i386)$'  { return 'https://go.microsoft.com/fwlink/?linkid=2144828' }
    '^(arm64|arm)$' { return 'https://www.microsoft.com/security/encyclopedia/adlpackages.aspx?package=dismpackage&arch=arm' }
    default { throw "Unsupported Defender offline update architecture: $Architecture" }
  }
}

function Get-DefenderOfflineUpdatePackage {
  param(
    [Parameter(Mandatory)] [pscustomobject]$Config,
    [string]$ImageArchitecture
  )

  $defenderConfig = Get-ConfigPropertyValue -Object $Config -Name 'Defender'
  $enabledByConfig = [bool](Get-ConfigPropertyValue -Object $defenderConfig -Name 'InjectLatestOfflineUpdate' -Default $false)
  $enabled = (($enabledByConfig -or $AddDefenderSignatures.IsPresent) -and (-not $SkipDefenderSignatures.IsPresent))

  $script:Run.Defender.Enabled = $enabled
  if (-not $enabled) {
    Write-Log "Skipping Microsoft Defender offline update injection (disabled)." INFO
    return $null
  }

  $arch = [string](Get-ConfigPropertyValue -Object $defenderConfig -Name 'Architecture' -Default '')
  if ([string]::IsNullOrWhiteSpace($arch)) { $arch = $ImageArchitecture }
  if ([string]::IsNullOrWhiteSpace($arch)) { $arch = 'x64' }
  if ($arch -match '(?i)amd64') { $arch = 'x64' }
  elseif ($arch -match '(?i)64-bit|x64') { $arch = 'x64' }
  elseif ($arch -match '(?i)arm64|arm') { $arch = 'arm64' }
  elseif ($arch -match '(?i)x86|32-bit') { $arch = 'x86' }

  $url = [string](Get-ConfigPropertyValue -Object $defenderConfig -Name 'UpdateKitUrl' -Default '')
  if ([string]::IsNullOrWhiteSpace($url)) { $url = Get-DefenderOfflineUpdateUrl -Architecture $arch }
  if (-not (Test-TrustedMicrosoftDownloadUrl -Url $url)) { throw "Untrusted Microsoft Defender update URL: $url" }

  $script:Run.Defender.Architecture = $arch
  $script:Run.Defender.UpdateKitUrl = $url

  $defenderRoot = $script:Paths['Defender']
  $downloadLatest = [bool](Get-ConfigPropertyValue -Object $defenderConfig -Name 'DownloadLatest' -Default $true)
  $kitPath = Join-Path $defenderRoot ("defender-update-kit-{0}.zip" -f $arch)
  $extractDir = Join-Path $defenderRoot ("defender-update-kit-{0}" -f $arch)

  if ($DryRun) {
    Write-Log "[DryRun] Would download latest Microsoft Defender offline update kit: $url" INFO
    return [pscustomobject]@{ Architecture=$arch; Url=$url; KitPath=$kitPath; CabPath=(Join-Path $extractDir ("defender-dism-{0}.cab" -f $arch)); CabSHA256=$null }
  }

  if ($downloadLatest -or (-not (Test-Path -LiteralPath $kitPath))) {
    Write-Log "Downloading latest Microsoft Defender offline update kit ($arch): $url" INFO
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $kitPath -UseBasicParsing
  } else {
    Write-Log "Using existing Microsoft Defender offline update kit: $kitPath" INFO
  }

  if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
  New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
  Expand-Archive -LiteralPath $kitPath -DestinationPath $extractDir -Force

  $cab = Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter 'defender-dism-*.cab' | Select-Object -First 1
  if (-not $cab) { throw "Microsoft Defender update kit did not contain defender-dism-*.cab: $kitPath" }
  Assert-TrustedMicrosoftFileSignature -Path $cab.FullName -Context 'Microsoft Defender offline update CAB'

  $hash = (Get-FileHash -LiteralPath $cab.FullName -Algorithm SHA256).Hash
  $script:Run.Defender.KitPath = $kitPath
  $script:Run.Defender.CabPath = $cab.FullName
  $script:Run.Defender.CabSHA256 = $hash
  $script:Run.Defender.Details = "Downloaded latest Defender offline update kit and extracted $($cab.Name)"

  return [pscustomobject]@{ Architecture=$arch; Url=$url; KitPath=$kitPath; CabPath=$cab.FullName; CabSHA256=$hash }
}

function Add-DefenderOfflineUpdate {
  param(
    [Parameter(Mandatory)] [string]$MountDir,
    [Parameter(Mandatory)] [pscustomobject]$DefenderPackage,
    [string]$ScratchDir
  )

  # Microsoft Defender offline update kits are not normal DISM packages even
  # though the payload is named defender-dism-*.cab. Microsoft's supported
  # script expands the CAB and copies definitions/platform files into the
  # mounted image. Do the same here so this works while BuildWIM already has
  # the image mounted for LCU/.NET/WinRE servicing.
  $cabPath = [string]$DefenderPackage.CabPath
  if ([string]::IsNullOrWhiteSpace($cabPath) -or (-not (Test-Path -LiteralPath $cabPath))) {
    throw "Microsoft Defender offline update CAB not found: $cabPath"
  }

  Write-Log "Injecting Microsoft Defender offline update package: $cabPath" INFO

  if ([string]::IsNullOrWhiteSpace($ScratchDir)) { $ScratchDir = $script:Paths['Scratch'] }
  $workRoot = Join-Path $ScratchDir ("DefenderOffline-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $cabContent = Join-Path $workRoot 'cab'

  try {
    New-Item -ItemType Directory -Path $cabContent -Force | Out-Null
    Write-Log "Expanding Defender offline update CAB to: $cabContent" DEBUG
    $expandOut = & expand.exe $cabPath -F:* $cabContent 2>&1
    foreach ($ln in $expandOut) {
      $msg = [string]$ln
      if (-not [string]::IsNullOrWhiteSpace($msg)) { Write-Log $msg DEBUG }
    }
    if ($LASTEXITCODE -ne 0) { throw "expand.exe failed for Defender offline update CAB (exit $LASTEXITCODE)" }

    $defSrc = Join-Path $cabContent 'Definition Updates\Updates'
    $platformSrc = Join-Path $cabContent 'Platform'
    $pkgXml = Join-Path $cabContent 'package-defender.xml'
    foreach ($required in @($defSrc, $platformSrc, $pkgXml)) {
      if (-not (Test-Path -LiteralPath $required)) { throw "Defender offline update payload missing required path: $required" }
    }

    $defTarget = Join-Path $MountDir 'ProgramData\Microsoft\Windows Defender\Definition Updates\Updates'
    $platformTarget = Join-Path $MountDir 'ProgramData\Microsoft\Windows Defender\Platform'
    $tempTarget = Join-Path $MountDir 'Windows\Temp'

    foreach ($dir in @($defTarget, $platformTarget, $tempTarget)) {
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    Copy-Item -Path (Join-Path $defSrc '*') -Destination $defTarget -Recurse -Force
    Copy-Item -Path (Join-Path $platformSrc '*') -Destination $platformTarget -Recurse -Force
    Copy-Item -LiteralPath $pkgXml -Destination $tempTarget -Force

    $pkgDetails = $null
    try { $pkgDetails = [xml](Get-Content -LiteralPath $pkgXml -Raw) } catch { }
    $script:Run.Defender.Applied = $true
    $script:Run.Defender.Details = "Injected Defender definitions/platform from $([IO.Path]::GetFileName($cabPath))"
    Write-Log "Microsoft Defender offline update injected successfully." INFO
  } finally {
    if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-ImageCleanup {
  param(
    [Parameter(Mandatory)] [string]$MountDir,
    [pscustomobject]$Config,
    [string]$ScratchDir
  )

  if (-not $Config.Servicing.CleanupStartComponentCleanup) {
    Write-Log "Skipping StartComponentCleanup (disabled in config)" INFO
    return
  }

  $args = @('/English',"/Image:$MountDir",'/Cleanup-Image','/StartComponentCleanup')
  if ($Config.Servicing.CleanupResetBase) { $args += '/ResetBase' }
  if ($ScratchDir) { $args += "/ScratchDir:$ScratchDir" }

  Write-Log "Running offline cleanup (StartComponentCleanup)" INFO
  Invoke-Dism -Arguments $args | Out-Null
}

# ----------------------------
# Output helpers
# ----------------------------
function Get-FileHashSafe {
  param([Parameter(Mandatory)][string]$Path)
  if ($DryRun) { return $null }
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}


function Get-GitCommitSafe {
  try {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return $null }
    $repo = $PSScriptRoot
    $commit = (& git -C $repo rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $commit) { return [string]$commit.Trim() }
  } catch { }
  return $null
}

function Get-DismVersionSafe {
  try {
    $r = Invoke-Dism -Arguments @('/English','/?') -AllowNonZero
    if ($r.StdOut -match 'Version:\s*([0-9\.]+)') { return $matches[1] }
  } catch { }
  return $null
}

function Get-HostOsCaptionSafe {
  try {
    return (Get-CimInstance Win32_OperatingSystem).Caption
  } catch { }
  return $null
}

function Get-UpdateMetadataForPackage {
  param([Parameter(Mandatory)] [object]$Package)

  $sidecarPath = $null
  if ($Package.Path) { $sidecarPath = "$($Package.Path).metadata.json" }
  if ($sidecarPath -and (Test-Path -LiteralPath $sidecarPath)) {
    try {
      $meta = Get-Content -LiteralPath $sidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
      return [pscustomobject]@{
        KB = [string]$meta.KB
        Title = [string]$meta.Title
        Classification = [string]$meta.Classification
        LastUpdated = [string]$meta.LastUpdated
        Build = [string]$meta.Build
        UpdateId = [string]$meta.UpdateId
        Url = [string]$meta.Url
        Path = [string]$meta.Path
        FileName = [string]$meta.FileName
        SidecarPath = $sidecarPath
      }
    } catch {
      Write-Log "Could not read update metadata sidecar: $sidecarPath ($($_.Exception.Message))" WARN
    }
  }

  $kb = if ($Package.KBNumber) { [string]$Package.KBNumber } else { [regex]::Match($Package.FileName, '(?i)kb\d+').Value.ToUpperInvariant() }
  return [pscustomobject]@{
    KB = $kb
    Title = [string]$Package.Details
    Classification = [string]$Package.Classification
    LastUpdated = $null
    Build = $null
    UpdateId = $null
    Url = $null
    Path = [string]$Package.Path
    FileName = [string]$Package.FileName
    SidecarPath = $sidecarPath
  }
}

function Get-OfflineRegistryValues {
  param(
    [Parameter(Mandatory)] [string]$MountDir
  )

  $hiveName = 'BWV2_' + ([guid]::NewGuid().ToString('N'))
  $hiveRoot = "HKLM\$hiveName"
  $softwareHive = Join-Path $MountDir 'Windows\System32\config\SOFTWARE'
  $result = [ordered]@{}

  if (-not (Test-Path -LiteralPath $softwareHive)) { return $result }

  try {
    & reg.exe load $hiveRoot $softwareHive | Out-Null
    $key = "Registry::$hiveRoot\Microsoft\Windows NT\CurrentVersion"
    $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    foreach ($name in @('ProductName','CurrentBuild','CurrentBuildNumber','DisplayVersion','ReleaseId','UBR')) {
      if ($null -ne $props.$name) { $result[$name] = $props.$name }
    }
  } catch {
    Write-Log "Could not read offline registry values from final WIM: $($_.Exception.Message)" WARN
  } finally {
    try { & reg.exe unload $hiveRoot | Out-Null } catch { }
  }

  return $result
}

function Test-FinalImageVerification {
  param(
    [Parameter(Mandatory)] [string]$FinalWim,
    [Parameter(Mandatory)] [string]$MountDir,
    [Parameter(Mandatory=$false)] [AllowEmptyCollection()] [object[]]$FinalPackages = @(),
    [Parameter(Mandatory=$false)] [AllowEmptyCollection()] [object[]]$InjectedPackages = @()
  )

  $verification = [ordered]@{
    status = 'OK'
    checks = @()
    image = [ordered]@{}
    registry = [ordered]@{}
    expectedUpdates = @()
  }

  try {
    $detail = Invoke-Dism -Arguments @('/English','/Get-WimInfo',"/WimFile:$FinalWim",'/Index:1')
    foreach ($ln in ($detail.StdOut -split "`r?`n")) {
      if ($ln -match '^Version\s*:\s*(.+)$') { $verification.image.Version = $matches[1].Trim() }
      elseif ($ln -match '^ServicePack Build\s*:\s*(\d+)') { $verification.image.ServicePackBuild = [int]$matches[1] }
      elseif ($ln -match '^Architecture\s*:\s*(.+)$') { $verification.image.Architecture = $matches[1].Trim() }
      elseif ($ln -match '^Name\s*:\s*(.+)$') { $verification.image.Name = $matches[1].Trim() }
    }
  } catch {
    $verification.status = 'WARN'
    $verification.checks += [pscustomobject]@{ Name='Read final WIM info'; Status='WARN'; Details=$_.Exception.Message }
  }

  $verification.registry = Get-OfflineRegistryValues -MountDir $MountDir

  foreach ($expected in @($InjectedPackages | Where-Object { $_.Classification -in @('LCU','DotNetCU','SSU') })) {
    $meta = Get-UpdateMetadataForPackage -Package $expected
    $expectedRevision = $null
    if ($meta.Build -match '^(?:\d+)\.(\d+)$') { $expectedRevision = [int]$matches[1] }
    elseif ($expected.Details -match '\((?:\d+)\.(\d+)\)\s*$') { $expectedRevision = [int]$matches[1] }

    $kb = if ($meta.KB) { [string]$meta.KB } elseif ($expected.KBNumber) { [string]$expected.KBNumber } else { [regex]::Match($expected.FileName, '(?i)kb\d+').Value.ToUpperInvariant() }
    $matchedByKb = @()
    if ($kb) { $matchedByKb = @($FinalPackages | Where-Object { $_ -match [regex]::Escape($kb) }) }

    $matchedByRollup = @()
    if ($expected.Classification -eq 'LCU' -and $expectedRevision) {
      $rollupPattern = 'Package_for_RollupFix~.*\.(' + [regex]::Escape([string]$expectedRevision) + ')\.'
      $matchedByRollup = @($FinalPackages | Where-Object { $_ -match $rollupPattern })
    }

    $matchedByDotNetRollup = @()
    if ($expected.Classification -eq 'DotNetCU') {
      # .NET Framework cumulative updates often do not expose the KB number in
      # DISM /Get-Packages after offline servicing. Verify the servicing target
      # by the canonical DotNetRollup/NetFx package identities instead of
      # requiring a KB literal that CBS may not keep in the final identity.
      $matchedByDotNetRollup = @($FinalPackages | Where-Object { $_ -match '(?i)Package_for_DotNetRollup|NetFx|NDP' })
    }

    $servicePackOk = $true
    if ($expected.Classification -eq 'LCU' -and $expectedRevision -and $verification.image.ServicePackBuild) {
      $servicePackOk = ([int]$verification.image.ServicePackBuild -eq [int]$expectedRevision)
    }

    $ubrOk = $true
    if ($expected.Classification -eq 'LCU' -and $expectedRevision -and $verification.registry.Contains('UBR')) {
      $ubrOk = ([int]$verification.registry.UBR -eq [int]$expectedRevision)
    }

    $packageOk = (($matchedByKb.Count -gt 0) -or ($matchedByRollup.Count -gt 0) -or ($matchedByDotNetRollup.Count -gt 0))
    $ok = $packageOk -and $servicePackOk -and $ubrOk

    $detail = [ordered]@{
      file = $expected.FileName
      classification = $expected.Classification
      kb = $kb
      catalogBuild = $meta.Build
      expectedRevision = $expectedRevision
      matchedByKb = @($matchedByKb)
      matchedByRollup = @($matchedByRollup)
      matchedByDotNetRollup = @($matchedByDotNetRollup)
      servicePackBuild = $verification.image.ServicePackBuild
      ubr = if ($verification.registry.Contains('UBR')) { $verification.registry.UBR } else { $null }
      packageOk = $packageOk
      servicePackOk = $servicePackOk
      ubrOk = $ubrOk
      status = if ($ok) { 'OK' } else { 'WARN' }
    }
    $verification.expectedUpdates += [pscustomobject]$detail
    $verification.checks += [pscustomobject]@{ Name="Verify $($expected.Classification) $kb"; Status=$detail.status; Details=("Package={0}; ServicePack={1}; UBR={2}" -f $packageOk,$servicePackOk,$ubrOk) }

    if (-not $ok) {
      $verification.status = 'WARN'
      Add-Warn "Slutverifiering: kunde inte bevisa $kb fullt ut i final WIM (package=$packageOk, servicePack=$servicePackOk, ubr=$ubrOk)."
    } else {
      Write-Log "Final verification OK for $kb ($($expected.Classification)); revision $expectedRevision confirmed." INFO
    }
  }

  return [pscustomobject]$verification
}

function Write-Sha256SumsFile {
  param([Parameter(Mandatory)] [string]$OutputDir)

  if ($DryRun) { return $null }
  $sumPath = Join-Path $OutputDir 'SHA256SUMS.txt'
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($file in (Get-ChildItem -LiteralPath $OutputDir -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if ($file.Name -eq 'SHA256SUMS.txt') { continue }
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $lines.Add(("{0}  {1}" -f $hash, $file.Name)) | Out-Null
  }
  Set-Content -LiteralPath $sumPath -Value $lines.ToArray() -Encoding ASCII
  return $sumPath
}

function Test-UsbSplitCompatibility {
  param(
    [Parameter(Mandatory)] [string]$OutputDir,
    [int]$SplitSizeMB = 3800
  )

  $maxFat32Bytes = 4294967295
  $swmFiles = @(Get-ChildItem -LiteralPath $OutputDir -Filter 'install*.swm' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  $checks = New-Object System.Collections.Generic.List[object]

  $checks.Add([pscustomobject]@{ Name='SWM files exist'; Status=($(if ($swmFiles.Count -gt 0) { 'OK' } else { 'WARN' })); Details="$($swmFiles.Count) file(s)" }) | Out-Null
  foreach ($file in $swmFiles) {
    $ok = ($file.Length -lt $maxFat32Bytes)
    $checks.Add([pscustomobject]@{ Name="FAT32 size $($file.Name)"; Status=($(if ($ok) { 'OK' } else { 'WARN' })); Details=("{0} bytes" -f $file.Length) }) | Out-Null
  }

  return [pscustomobject]@{
    status = if (@($checks | Where-Object { $_.Status -ne 'OK' }).Count -eq 0) { 'OK' } else { 'WARN' }
    splitSizeMB = $SplitSizeMB
    files = @($swmFiles | ForEach-Object { [pscustomobject]@{ Path=$_.FullName; SizeBytes=$_.Length; SHA256=(Get-FileHashSafe -Path $_.FullName) } })
    checks = @($checks.ToArray())
  }
}

function New-BuildManifestObject {
  param(
    [Parameter(Mandatory)] [string]$Timestamp,
    [Parameter(Mandatory)] [string]$OutputDir,
    [string]$Sha256SumsPath
  )

  $sourceHash = $null
  if (-not $DryRun -and $script:Run.Input.Path -and (Test-Path -LiteralPath $script:Run.Input.Path)) {
    $sourceHash = Get-FileHashSafe -Path $script:Run.Input.Path
  }

  return [ordered]@{
    schema = 'buildwim.v2.manifest'
    generatedAt = (Get-Date).ToString('o')
    timestamp = $Timestamp
    host = [ordered]@{
      computerName = $env:COMPUTERNAME
      userName = $env:USERNAME
      os = (Get-HostOsCaptionSafe)
      dismVersion = (Get-DismVersionSafe)
    }
    script = [ordered]@{
      version = $script:Run.Version
      path = $PSCommandPath
      gitCommit = (Get-GitCommitSafe)
    }
    input = [ordered]@{
      type = $script:Run.Input.Type
      path = $script:Run.Input.Path
      sha256 = $sourceHash
      selectedEdition = $script:Run.Image.SelectedEditionName
      proIndex = $script:Run.Image.ProIndex
    }
    packages = [ordered]@{
      found = @($script:Run.Packages.Found | ForEach-Object { Get-UpdateMetadataForPackage -Package $_ })
      injected = @($script:Run.Packages.Injected | ForEach-Object { Get-UpdateMetadataForPackage -Package $_ })
      skipped = @($script:Run.Packages.Skipped)
    }
    outputs = [ordered]@{
      directory = $OutputDir
      mode = $script:Run.Output.Mode
      wim = [ordered]@{ path=$script:Run.Output.FinalWim; sizeBytes=$script:Run.Output.FinalWimSizeBytes; sha256=$script:Run.Output.FinalWimHash }
      intermediateWim = $script:Run.Output.IntermediateWim
      swm = @($script:Run.Output.SwmFiles)
      sha256Sums = $Sha256SumsPath
    }
    verification = $script:Run.Verification
    warnings = @($script:Run.Warnings.ToArray())
    errors = @($script:Run.Errors.ToArray())
    steps = @($script:Run.Steps.ToArray())
  }
}

function Export-FinalWim {
  param(
    [Parameter(Mandatory)] [string]$SourceWim,
    [Parameter(Mandatory)] [string]$DestWim
  )

  if (Test-Path -LiteralPath $DestWim) {
    Write-Log "Removing existing output WIM: $DestWim" INFO
    if (-not $DryRun) { Remove-Item -LiteralPath $DestWim -Force }
  }

  # SourceWim in this pipeline already contains one index; export index 1.
  Write-Log "Exporting final WIM: $SourceWim -> $DestWim" INFO
  Invoke-Dism -Arguments @('/English','/Export-Image',"/SourceImageFile:$SourceWim","/SourceIndex:1","/DestinationImageFile:$DestWim",'/Compress:Max','/CheckIntegrity') | Out-Null
}

function Split-WimForFat32 {
  param(
    [Parameter(Mandatory)] [string]$WimPath,
    [Parameter(Mandatory)] [string]$SwmBasePath,
    [Parameter(Mandatory)] [int]$SizeMB
  )

  # DISM /Split-Image wants base path to .swm
  Write-Log "Splitting WIM for FAT32: $WimPath -> $SwmBasePath (SizeMB=$SizeMB)" INFO
  Invoke-Dism -Arguments @('/English','/Split-Image',"/ImageFile:$WimPath", "/SWMFile:$SwmBasePath", "/FileSize:$SizeMB") | Out-Null
}

# ----------------------------
# HTML reporting
# ----------------------------
function Get-BuildVerdict {
  param([hashtable]$Run)

  if ($Run.Errors.Count -gt 0) { return 'FAILED' }
  if ($Run.Warnings.Count -gt 0) { return 'SUCCESS WITH WARNINGS' }
  return 'SUCCESS'
}

function Get-OutputFilesInfo {
  param([hashtable]$Run)

  $items = New-Object System.Collections.Generic.List[object]
  $output = $Run.Output

  if ($output.Contains('FinalWim') -and $output.FinalWim) {
    $items.Add([pscustomobject]@{
      Type = 'WIM'
      Path = $output.FinalWim
      SizeBytes = $(if ($output.Contains('FinalWimSizeBytes')) { $output.FinalWimSizeBytes } else { $null })
      SHA256 = $(if ($output.Contains('FinalWimHash')) { $output.FinalWimHash } else { $null })
    }) | Out-Null
  }

  if ($output.Contains('SwmFiles')) {
    foreach ($swm in @($output.SwmFiles)) {
      $items.Add([pscustomobject]@{
        Type = 'SWM'
        Path = $swm.Path
        SizeBytes = $swm.SizeBytes
        SHA256 = $swm.SHA256
      }) | Out-Null
    }
  }

  if ($output.Contains('BuildManifest') -and $output.BuildManifest) {
    $items.Add([pscustomobject]@{
      Type = 'MANIFEST'
      Path = $output.BuildManifest
      SizeBytes = $(if ($output.Contains('BuildManifestSizeBytes')) { $output.BuildManifestSizeBytes } else { $null })
      SHA256 = $(if ($output.Contains('BuildManifestHash')) { $output.BuildManifestHash } else { $null })
    }) | Out-Null
  }

  if ($output.Contains('Sha256Sums') -and $output.Sha256Sums) {
    $items.Add([pscustomobject]@{
      Type = 'SHA256SUMS'
      Path = $output.Sha256Sums
      SizeBytes = $(if ($output.Contains('Sha256SumsSizeBytes')) { $output.Sha256SumsSizeBytes } else { $null })
      SHA256 = $(if ($output.Contains('Sha256SumsHash')) { $output.Sha256SumsHash } else { $null })
    }) | Out-Null
  }

  if ($output.Contains('MetadataJson') -and $output.MetadataJson) {
    $items.Add([pscustomobject]@{
      Type = 'JSON'
      Path = $output.MetadataJson
      SizeBytes = $(if ($output.Contains('MetadataJsonSizeBytes')) { $output.MetadataJsonSizeBytes } else { $null })
      SHA256 = $(if ($output.Contains('MetadataJsonHash')) { $output.MetadataJsonHash } else { $null })
    }) | Out-Null
  }

  return $items.ToArray()
}

function Format-Size {
  param([Nullable[long]]$Bytes)

  if ($null -eq $Bytes) { return '' }
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
  return "$Bytes B"
}

function New-HtmlReport {
  param(
    [Parameter(Mandatory)] [hashtable]$Run,
    [Parameter(Mandatory)] [string]$ReportPath
  )

  $enc = [System.Net.WebUtility]
  $start = $Run.StartTime
  $end = $Run.EndTime
  $dur = $Run.Duration
  $verdict = Get-BuildVerdict -Run $Run
  $outputFiles = @(Get-OutputFilesInfo -Run $Run)

  $summaryRows = @(
    [pscustomobject]@{ Label = 'Verdict'; Value = $verdict },
    [pscustomobject]@{ Label = 'Version'; Value = $Run.Version },
    [pscustomobject]@{ Label = 'Start'; Value = $start },
    [pscustomobject]@{ Label = 'End'; Value = $end },
    [pscustomobject]@{ Label = 'Duration'; Value = $dur },
    [pscustomobject]@{ Label = 'Input'; Value = ('{0} ({1})' -f $Run.Input.Path, $Run.Input.Type) },
    [pscustomobject]@{ Label = 'Selected edition'; Value = $Run.Image.SelectedEditionName },
    [pscustomobject]@{ Label = 'Pro index'; Value = $Run.Image.ProIndex },
    [pscustomobject]@{ Label = 'Working WIM'; Value = $Run.Image.WorkingWim },
    [pscustomobject]@{ Label = 'Defender offline update'; Value = $(if ($Run.Defender.Enabled) { if ($Run.Defender.Applied) { 'Applied' } else { 'Enabled, not applied' } } else { 'Disabled' }) },
    [pscustomobject]@{ Label = 'Defender package'; Value = $Run.Defender.CabPath },
    [pscustomobject]@{ Label = 'Output WIM'; Value = $Run.Output.FinalWim },
    [pscustomobject]@{ Label = 'Output SWM base'; Value = $Run.Output.SwmBase },
    [pscustomobject]@{ Label = 'Started from'; Value = ('{0} {1}' -f $Run.Image.SourceSelectedEditionName, $Run.Image.SourceSelectedEditionVersion) },
    [pscustomobject]@{ Label = 'Now at'; Value = ('{0} {1}' -f $Run.Image.FinalEditionName, $Run.Image.FinalEditionVersion) },
    [pscustomobject]@{ Label = 'Latest LCU'; Value = ('{0} / {1}' -f $Run.Summary.LatestLcuKB, $Run.Summary.LatestLcuBuild) },
    [pscustomobject]@{ Label = 'Release type'; Value = ('{0} (OOB: {1}, released {2}, month Patch Tuesday {3:yyyy-MM-dd})' -f $Run.Summary.LatestLcuReleaseType, $Run.Summary.LatestLcuIsOob, $Run.Summary.LatestLcuLastUpdated, $Run.Summary.LatestLcuPatchTuesday) },
    [pscustomobject]@{ Label = '.NET CU'; Value = ('{0} / {1} / OOB: {2}' -f $Run.Summary.LatestDotNetKB, $Run.Summary.LatestDotNetReleaseType, $Run.Summary.LatestDotNetIsOob) },
    [pscustomobject]@{ Label = 'Safe OS DU / WinRE'; Value = ('{0} / {1}' -f $Run.Summary.LatestSafeOsKB, $Run.Summary.LatestSafeOsLastUpdated) },
    [pscustomobject]@{ Label = 'Next Patch Tuesday'; Value = ('{0:yyyy-MM-dd} ({1} days)' -f $Run.Summary.NextPatchTuesday, $Run.Summary.DaysUntilPatchTuesday) },
    [pscustomobject]@{ Label = 'Disk free at start'; Value = ('{0} GB' -f $Run.Summary.DiskFreeGBAtStart) }
  )

  $summaryTableRows = New-HtmlRows -Items $summaryRows -Renderer {
    "<tr><th>$($enc::HtmlEncode($_.Label))</th><td>$($enc::HtmlEncode([string]$_.Value))</td></tr>"
  }

  $imageRows = @(
    [pscustomobject]@{ Stage = 'Source image'; Name = $Run.Image.SourceSelectedEditionName; Version = $Run.Image.SourceSelectedEditionVersion; Architecture = $Run.Image.SourceSelectedEditionArchitecture },
    [pscustomobject]@{ Stage = 'Working Pro-only WIM'; Name = $Run.Image.WorkingEditionName; Version = $Run.Image.WorkingEditionVersion; Architecture = $Run.Image.WorkingEditionArchitecture },
    [pscustomobject]@{ Stage = 'Final output WIM'; Name = $Run.Image.FinalEditionName; Version = $Run.Image.FinalEditionVersion; Architecture = $Run.Image.FinalEditionArchitecture }
  ) | Where-Object { $_.Name -or $_.Version -or $_.Architecture }

  $imageTableRows = New-HtmlRows -Items $imageRows -Renderer {
    "<tr><td>$($enc::HtmlEncode($_.Stage))</td><td>$($enc::HtmlEncode($_.Name))</td><td>$($enc::HtmlEncode($_.Version))</td><td>$($enc::HtmlEncode($_.Architecture))</td></tr>"
  } -EmptyMessage 'No image details captured.'

  $stepRows = New-HtmlRows -Items @($Run.Steps.ToArray()) -Renderer {
    "<tr><td>$($enc::HtmlEncode($_.Name))</td><td>$($enc::HtmlEncode($_.Status))</td><td>$($enc::HtmlEncode([string]$_.StartTime))</td><td>$($enc::HtmlEncode([string]$_.EndTime))</td><td>$($enc::HtmlEncode([string]$_.DurationSeconds))</td><td>$($enc::HtmlEncode($_.Details))</td></tr>"
  } -EmptyMessage 'No step timing captured.'

  $pkgRows = New-HtmlRows -Items @($Run.Packages.Sorted) -Renderer {
    "<tr><td>$($enc::HtmlEncode($_.FileName))</td><td>$($enc::HtmlEncode($_.Classification))</td><td>$($enc::HtmlEncode($_.Path))</td></tr>"
  } -EmptyMessage 'No update packages discovered.'

  $injRows = New-HtmlRows -Items @($Run.Packages.Injected) -Renderer {
    "<tr><td>$($enc::HtmlEncode($_.FileName))</td><td>$($enc::HtmlEncode($_.Classification))</td></tr>"
  } -EmptyMessage 'No packages injected.'

  $skippedRows = New-HtmlRows -Items @($Run.Packages.Skipped) -Renderer {
    "<tr><td>$($enc::HtmlEncode($_.FileName))</td><td>$($enc::HtmlEncode($_.Classification))</td><td>$($enc::HtmlEncode($_.Reason))</td></tr>"
  } -EmptyMessage 'No skipped packages.'

  $outputRows = New-HtmlRows -Items $outputFiles -Renderer {
    "<tr><td>$($enc::HtmlEncode($_.Type))</td><td>$($enc::HtmlEncode($_.Path))</td><td>$($enc::HtmlEncode((Format-Size $_.SizeBytes)))</td><td><code>$($enc::HtmlEncode($_.SHA256))</code></td></tr>"
  } -EmptyMessage 'No output files captured.'

  $existingPkgRows = New-HtmlRows -Items @($Run.Image.ExistingPackages) -Renderer {
    "<tr><td>$($enc::HtmlEncode([string]$_))</td></tr>"
  } -EmptyMessage 'No existing packages captured.'

  $enabledFeatRows = New-HtmlRows -Items @($Run.Image.EnabledFeatures) -Renderer {
    "<tr><td>$($enc::HtmlEncode([string]$_))</td></tr>"
  } -EmptyMessage 'No enabled features captured.'

  $warnRows = if ($Run.Warnings.Count -gt 0) { ($Run.Warnings | ForEach-Object { "<li>$($enc::HtmlEncode($_))</li>" }) -join "`n" } else { '<li><i>None</i></li>' }
  $errRows  = if ($Run.Errors.Count -gt 0) { ($Run.Errors | ForEach-Object { "<li>$($enc::HtmlEncode($_))</li>" }) -join "`n" } else { '<li><i>None</i></li>' }

  $dismRows = if ($Run.DismCommands.Count -gt 0) { ($Run.DismCommands | ForEach-Object { "<li><code>$($enc::HtmlEncode($_))</code></li>" }) -join "`n" } else { '<li><i>None</i></li>' }

  $html = @"
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>BuildWIM Report</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; color: #222; }
    h1,h2 { margin-bottom: 6px; }
    .banner { padding: 14px 16px; border-radius: 8px; margin-bottom: 16px; font-weight: 600; background: #eef5ff; border-left: 6px solid #2d6cdf; }
    .banner.success { background: #eefaf2; border-left-color: #0a7; }
    .banner.warn { background: #fff8e8; border-left-color: #b80; }
    .banner.fail { background: #fff1f1; border-left-color: #c00; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 16px; }
    .panel { background: #f7f7f7; padding: 12px; border-radius: 8px; }
    table { border-collapse: collapse; width: 100%; margin-top: 10px; }
    th, td { border: 1px solid #ddd; padding: 8px; font-size: 13px; vertical-align: top; }
    th { background: #222; color: #fff; text-align: left; }
    code { background: #eee; padding: 2px 4px; border-radius: 4px; word-break: break-all; }
    ul, ol { padding-left: 22px; }
  </style>
</head>
<body>
  <h1>BuildWIM     Report</h1>
  <div class="banner $(if ($verdict -eq 'FAILED') { 'fail' } elseif ($verdict -eq 'SUCCESS WITH WARNINGS') { 'warn' } else { 'success' })">$($enc::HtmlEncode($verdict))</div>

  <div class="grid">
    <div class="panel">
      <h2>Run summary</h2>
      <table>
        <tbody>
          $summaryTableRows
        </tbody>
      </table>
    </div>
    <div class="panel">
      <h2>Build totals</h2>
      <table>
        <tbody>
          <tr><th>Packages found</th><td>$($Run.Packages.Found.Count)</td></tr>
          <tr><th>Packages sorted</th><td>$($Run.Packages.Sorted.Count)</td></tr>
          <tr><th>Packages injected</th><td>$($Run.Packages.Injected.Count)</td></tr>
          <tr><th>Packages skipped</th><td>$($Run.Packages.Skipped.Count)</td></tr>
          <tr><th>Defender update</th><td>$(if ($Run.Defender.Applied) { 'Applied' } elseif ($Run.Defender.Enabled) { 'Enabled, not applied' } else { 'Disabled' })</td></tr>
          <tr><th>Warnings</th><td>$($Run.Warnings.Count)</td></tr>
          <tr><th>Errors</th><td>$($Run.Errors.Count)</td></tr>
        </tbody>
      </table>
    </div>
  </div>

  <h2>Image details (before/after)</h2>
  <table>
    <thead><tr><th>Stage</th><th>Edition</th><th>Version</th><th>Architecture</th></tr></thead>
    <tbody>
      $imageTableRows
    </tbody>
  </table>

  <h2>Step timings</h2>
  <table>
    <thead><tr><th>Step</th><th>Status</th><th>Start</th><th>End</th><th>Duration (s)</th><th>Details</th></tr></thead>
    <tbody>
      $stepRows
    </tbody>
  </table>

  <h2>Output files and hashes</h2>
  <table>
    <thead><tr><th>Type</th><th>Path</th><th>Size</th><th>SHA256</th></tr></thead>
    <tbody>
      $outputRows
    </tbody>
  </table>

  <h2>Packages (sorted order)</h2>
  <table>
    <thead><tr><th>File</th><th>Classification</th><th>Path</th></tr></thead>
    <tbody>
      $pkgRows
    </tbody>
  </table>

  <h2>Injected packages</h2>
  <table>
    <thead><tr><th>File</th><th>Classification</th></tr></thead>
    <tbody>
      $injRows
    </tbody>
  </table>

  <h2>Skipped packages</h2>
  <table>
    <thead><tr><th>File</th><th>Classification</th><th>Reason</th></tr></thead>
    <tbody>
      $skippedRows
    </tbody>
  </table>

  <h2>Existing packages / KBs in image</h2>
  <table>
    <thead><tr><th>Package</th></tr></thead>
    <tbody>
      $existingPkgRows
    </tbody>
  </table>

  <h2>Enabled Windows features (offline)</h2>
  <table>
    <thead><tr><th>Feature</th></tr></thead>
    <tbody>
      $enabledFeatRows
    </tbody>
  </table>

  <h2>Warnings</h2>
  <ul>
    $warnRows
  </ul>

  <h2>Errors</h2>
  <ul>
    $errRows
  </ul>

  <h2>DISM commands</h2>
  <ol>
    $dismRows
  </ol>
</body>
</html>
"@

  if (-not $DryRun) {
    $dir = Split-Path -Parent $ReportPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Set-Content -LiteralPath $ReportPath -Value $html -Encoding UTF8
  }
}

# ----------------------------
# Main
# ----------------------------
function New-MarkdownReport {
  param(
    [Parameter(Mandatory)] [hashtable]$Run,
    [Parameter(Mandatory)] [string]$ReportPath
  )

  $verdict = Get-BuildVerdict -Run $Run
  $verdictEmoji = switch ($verdict) {
    'SUCCESS' { '   ' }
    'SUCCESS WITH WARNINGS' { '      ' }
    'FAILED' { '   ' }
    default { '   ' }
  }

  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.AppendLine("# BuildWIM Report")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("$verdictEmoji **$verdict**")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("## Summary")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("| Field | Value |")
  [void]$sb.AppendLine("|-------|-------|")
  [void]$sb.AppendLine("| Version | $($Run.Version) |")
  [void]$sb.AppendLine("| Start | $($Run.StartTime) |")
  [void]$sb.AppendLine("| End | $($Run.EndTime) |")
  [void]$sb.AppendLine("| Duration | $(Format-DurationHuman $Run.Duration.TotalSeconds) |")
  [void]$sb.AppendLine("| Input | $($Run.Input.Path) ($($Run.Input.Type)) |")
  [void]$sb.AppendLine("| Edition | $($Run.Image.SelectedEditionName) |")
  [void]$sb.AppendLine("| Final Version | $($Run.Image.FinalEditionVersion) |")
  [void]$sb.AppendLine("| Architecture | $($Run.Image.FinalEditionArchitecture) |")
  [void]$sb.AppendLine("")

  [void]$sb.AppendLine("## Packages")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("| Metric | Count |")
  [void]$sb.AppendLine("|--------|-------|")
  [void]$sb.AppendLine("| Found | $($Run.Packages.Found.Count) |")
  [void]$sb.AppendLine("| Injected | $($Run.Packages.Injected.Count) |")
  [void]$sb.AppendLine("| Skipped | $($Run.Packages.Skipped.Count) |")
  [void]$sb.AppendLine("")

  if ($Run.Packages.Injected.Count -gt 0) {
    [void]$sb.AppendLine("### Injected")
    [void]$sb.AppendLine("")
    foreach ($pkg in $Run.Packages.Injected) {
      [void]$sb.AppendLine("- ``$($pkg.FileName)`` [$($pkg.Classification)]")
    }
    [void]$sb.AppendLine("")
  }

  if ($Run.Packages.Skipped.Count -gt 0) {
    [void]$sb.AppendLine("### Skipped")
    [void]$sb.AppendLine("")
    foreach ($pkg in $Run.Packages.Skipped) {
      [void]$sb.AppendLine("- ``$($pkg.FileName)`` - $($pkg.Reason)")
    }
    [void]$sb.AppendLine("")
  }

  [void]$sb.AppendLine("## Step Timings")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("| Step | Duration | Status |")
  [void]$sb.AppendLine("|------|----------|--------|")
  foreach ($step in $Run.Steps.ToArray()) {
    [void]$sb.AppendLine("| $($step.Name) | $(Format-DurationHuman $step.DurationSeconds) | $($step.Status) |")
  }
  [void]$sb.AppendLine("")

  [void]$sb.AppendLine("## Output Files")
  [void]$sb.AppendLine("")
  $outputFiles = @(Get-OutputFilesInfo -Run $Run)
  foreach ($f in $outputFiles) {
    [void]$sb.AppendLine("- **$($f.Type)**: ``$($f.Path)`` ($(Format-Size $f.SizeBytes))")
    if ($f.SHA256) { [void]$sb.AppendLine("  - SHA256: ``$($f.SHA256)``") }
  }
  [void]$sb.AppendLine("")

  if ($Run.Warnings.Count -gt 0) {
    [void]$sb.AppendLine("## Warnings")
    [void]$sb.AppendLine("")
    foreach ($w in $Run.Warnings.ToArray()) { [void]$sb.AppendLine("- $w") }
    [void]$sb.AppendLine("")
  }

  if ($Run.Errors.Count -gt 0) {
    [void]$sb.AppendLine("## Errors")
    [void]$sb.AppendLine("")
    foreach ($e in $Run.Errors.ToArray()) { [void]$sb.AppendLine("- $e") }
    [void]$sb.AppendLine("")
  }

  if (-not $DryRun) {
    $dir = Split-Path -Parent $ReportPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Set-Content -LiteralPath $ReportPath -Value $sb.ToString() -Encoding UTF8
  }
}

function New-DiffReport {
  param(
    [Parameter(Mandatory)] [hashtable]$Run,
    [Parameter(Mandatory)] [string]$ReportPath
  )

  $historyPath = Get-BuildHistoryPath
  $previousKBs = @()

  if (Test-Path -LiteralPath $historyPath) {
    try {
      $raw = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8
      if ($raw.Trim()) {
        $loaded = $raw | ConvertFrom-Json
        $history = if ($loaded -is [System.Array]) { @($loaded) } else { @($loaded) }
        if ($history.Count -gt 0) {
          $lastBuild = $history[-1]
          if ($lastBuild.PSObject.Properties['PackageNames']) {
            $previousKBs = @($lastBuild.PackageNames)
          }
        }
      }
    } catch { }
  }

  $currentKBs = @($Run.Packages.Injected | ForEach-Object { $_.FileName })
  $newKBs = @($currentKBs | Where-Object { $_ -notin $previousKBs })
  $removedKBs = @($previousKBs | Where-Object { $_ -notin $currentKBs })
  $unchangedKBs = @($currentKBs | Where-Object { $_ -in $previousKBs })

  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.AppendLine("# BuildWIM Diff Report")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
  [void]$sb.AppendLine("")

  if ($previousKBs.Count -eq 0) {
    [void]$sb.AppendLine("*No previous build found for comparison.*")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Current Build KBs ($($currentKBs.Count))")
    [void]$sb.AppendLine("")
    foreach ($kb in $currentKBs) { [void]$sb.AppendLine("-      ``$kb``") }
  } else {
    [void]$sb.AppendLine("## Changes from Previous Build")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Metric | Count |")
    [void]$sb.AppendLine("|--------|-------|")
    [void]$sb.AppendLine("| New KBs | $($newKBs.Count) |")
    [void]$sb.AppendLine("| Removed KBs | $($removedKBs.Count) |")
    [void]$sb.AppendLine("| Unchanged | $($unchangedKBs.Count) |")
    [void]$sb.AppendLine("")

    if ($newKBs.Count -gt 0) {
      [void]$sb.AppendLine("###     New KBs")
      foreach ($kb in $newKBs) { [void]$sb.AppendLine("- ``$kb``") }
      [void]$sb.AppendLine("")
    }

    if ($removedKBs.Count -gt 0) {
      [void]$sb.AppendLine("###     Removed KBs")
      foreach ($kb in $removedKBs) { [void]$sb.AppendLine("- ``$kb``") }
      [void]$sb.AppendLine("")
    }

    if ($unchangedKBs.Count -gt 0) {
      [void]$sb.AppendLine("###     Unchanged KBs")
      foreach ($kb in $unchangedKBs) { [void]$sb.AppendLine("- ``$kb``") }
      [void]$sb.AppendLine("")
    }
  }

  if (-not $DryRun) {
    $dir = Split-Path -Parent $ReportPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Set-Content -LiteralPath $ReportPath -Value $sb.ToString() -Encoding UTF8
  }

  # Print diff summary to console
  Write-Host ""
  if ($previousKBs.Count -eq 0) {
    Write-Host "       Diff: First build (no previous build to compare)" -ForegroundColor DarkCyan
  } else {
    $diffColor = if ($newKBs.Count -gt 0 -or $removedKBs.Count -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ("       Diff: +{0} new / -{1} removed / {2} unchanged KBs" -f $newKBs.Count, $removedKBs.Count, $unchangedKBs.Count) -ForegroundColor $diffColor
  }
}

function Complete-CurrentBuildReport {
  param(
    [Parameter(Mandatory)] [hashtable]$Run,
    [Parameter(Mandatory)] [string]$ReportPath
  )

  $Run.EndTime = Get-Date
  $Run.Duration = ($Run.EndTime - $Run.StartTime)
  $nextPatchTuesday = Get-NextPatchTuesday -From (Get-Date)
  $Run.Summary.NextPatchTuesday = $nextPatchTuesday
  $Run.Summary.DaysUntilPatchTuesday = [Math]::Ceiling(($nextPatchTuesday - (Get-Date)).TotalDays)
  New-HtmlReport -Run $Run -ReportPath $ReportPath
  $mdReportPath = [IO.Path]::ChangeExtension($ReportPath, '.md')
  New-MarkdownReport -Run $Run -ReportPath $mdReportPath
  return [pscustomobject]@{ Html = $ReportPath; Markdown = $mdReportPath }
}

function Send-BuildNotification {
  param(
    [Parameter(Mandatory)] [hashtable]$Run
  )

  $verdict = Get-BuildVerdict -Run $Run
  $duration = Format-DurationHuman $Run.Duration.TotalSeconds
  $edition = $Run.Image.FinalEditionName
  $version = $Run.Image.FinalEditionVersion
  $kbCount = $Run.Packages.Injected.Count

  $title = "BuildWIM $verdict"
  $body = "Edition: $edition $version`nDuration: $duration`nKBs injected: $kbCount"

  try {
    # Windows toast notification via BurntToast (if available)
    if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
      Import-Module BurntToast -ErrorAction SilentlyContinue
      New-BurntToastNotification -Text $title, $body -ErrorAction SilentlyContinue
      Write-Log "Toast notification sent via BurntToast" INFO
      return
    }

    # Fallback: Windows native notification via PowerShell
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipTitle = $title
    $notify.BalloonTipText = $body
    $notify.BalloonTipIcon = if ($verdict -eq 'FAILED') { 'Error' } elseif ($verdict -like '*WARNING*') { 'Warning' } else { 'Info' }
    $notify.Visible = $true
    $notify.ShowBalloonTip(10000)
    Start-Sleep -Seconds 2
    $notify.Dispose()
    Write-Log "Balloon notification sent" INFO
  } catch {
    Write-Log "Could not send notification: $($_.Exception.Message)" WARN
  }
}

function Get-ExistingLatestDotNetPackage {
  param(
    [Parameter(Mandatory)] [string]$Destination,
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64'
  )

  $items = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $Destination)) { return $null }

  foreach ($sidecar in @(Get-ChildItem -LiteralPath $Destination -File -Filter '*.msu.metadata.json' -ErrorAction SilentlyContinue)) {
    try {
      $meta = Get-Content -LiteralPath $sidecar.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $title = if ($meta.PSObject.Properties['Title']) { [string]$meta.Title } else { '' }
      if ($title -notmatch '(?i)\.NET Framework') { continue }
      if ($title -notmatch '(?i)Cumulative Update') { continue }
      if ($WindowsVersion -and $title -notmatch "version $([regex]::Escape($WindowsVersion))") { continue }

      $fileName = if ($meta.FileName) { [string]$meta.FileName } else { [IO.Path]::GetFileNameWithoutExtension($sidecar.Name) }
      $packagePath = Join-Path $Destination $fileName
      $items.Add([pscustomobject]@{
        KB = [string]$meta.KB
        Title = [string]$meta.Title
        LastUpdated = [string]$meta.LastUpdated
        UpdateId = [string]$meta.UpdateId
        FileName = $fileName
        Path = $packagePath
        SidecarPath = $sidecar.FullName
      }) | Out-Null
    } catch {
      Write-Log "Could not read existing .NET metadata: $($sidecar.FullName) ($($_.Exception.Message))" WARN
    }
  }

  if ($items.Count -eq 0) { return $null }
  return @($items.ToArray() | Sort-Object @{ Expression = { $_.LastUpdated }; Descending = $true }, @{ Expression = { $_.KB }; Descending = $true } | Select-Object -First 1)[0]
}

function Invoke-LatestExtraPackageDownload {
  param(
    [Parameter(Mandatory)] [string]$Destination,
    [ValidateSet('DotNet','SafeOS')] [string]$PackageType,
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64'
  )

  $labels = @{
    DotNet = '.NET CU'
    SafeOS = 'Safe OS Dynamic Update'
  }
  $label = $labels[$PackageType]
  $downloader = Join-Path $PSScriptRoot 'Get-LatestWindows11LCU.ps1'
  if (-not (Test-Path -LiteralPath $downloader)) { throw "$label downloader dependency missing: $downloader" }
  if ($DryRun) { Write-Log "Latest $label auto-detection is enabled, but DryRun is active. Skipping side effects." WARN; return }

  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $downloader,
    '-WindowsVersion', $WindowsVersion,
    '-Architecture', $Architecture,
    '-OutputPath', $Destination,
    '-PackageType', $PackageType
  )
  $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
  if ($proc.ExitCode -ne 0) { throw "Latest $label downloader failed with exit code $($proc.ExitCode)." }

  if ($PackageType -eq 'DotNet') {
    $pkg = Get-ExistingLatestDotNetPackage -Destination $Destination -WindowsVersion $WindowsVersion -Architecture $Architecture
    if ($pkg) {
      $script:Run.Summary.LatestDotNetKB = $pkg.KB
      $script:Run.Summary.LatestDotNetTitle = $pkg.Title
      $script:Run.Summary.LatestDotNetLastUpdated = $pkg.LastUpdated
      $class = Get-LcuReleaseClassification -Title $pkg.Title -LastUpdated $pkg.LastUpdated
      $script:Run.Summary.LatestDotNetReleaseType = $class.Type
      $script:Run.Summary.LatestDotNetIsOob = $class.IsOob
    }
  } else {
    $pkg = Get-ExistingLatestSafeOsPackage -Destination $Destination -WindowsVersion $WindowsVersion -Architecture $Architecture
    if ($pkg) {
      $script:Run.Summary.LatestSafeOsKB = $pkg.KB
      $script:Run.Summary.LatestSafeOsTitle = $pkg.Title
      $script:Run.Summary.LatestSafeOsLastUpdated = $pkg.LastUpdated
      $script:Run.Summary.LatestSafeOsUpdateId = $pkg.UpdateId
      $script:Run.Summary.LatestSafeOsFileName = $pkg.FileName
    }
  }

  if ($pkg) { Write-Log ("Latest {0} ready: {1} ({2})" -f $label, $pkg.KB, $pkg.LastUpdated) INFO }
}

function Get-ExistingLatestSafeOsPackage {
  param(
    [Parameter(Mandatory)] [string]$Destination,
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64'
  )

  $items = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $Destination)) { return $null }

  foreach ($sidecar in @(Get-ChildItem -LiteralPath $Destination -File -Filter '*.metadata.json' -ErrorAction SilentlyContinue)) {
    try {
      $meta = Get-Content -LiteralPath $sidecar.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $title = if ($meta.PSObject.Properties['Title']) { [string]$meta.Title } else { '' }
      $packageType = if ($meta.PSObject.Properties['PackageType']) { [string]$meta.PackageType } else { '' }
      if ($packageType -ne 'SafeOS' -and $title -notmatch '(?i)Safe OS Dynamic Update') { continue }
      if ($WindowsVersion -and $title -notmatch "version $([regex]::Escape($WindowsVersion))") { continue }

      $fileName = if ($meta.FileName) { [string]$meta.FileName } else { [IO.Path]::GetFileNameWithoutExtension($sidecar.Name) }
      $packagePath = Join-Path $Destination $fileName
      $items.Add([pscustomobject]@{
        KB = [string]$meta.KB
        Title = [string]$meta.Title
        LastUpdated = [string]$meta.LastUpdated
        UpdateId = [string]$meta.UpdateId
        FileName = $fileName
        Path = $packagePath
        SidecarPath = $sidecar.FullName
      }) | Out-Null
    } catch {
      Write-Log "Could not read existing Safe OS metadata: $($sidecar.FullName) ($($_.Exception.Message))" WARN
    }
  }

  if ($items.Count -eq 0) { return $null }
  return @($items.ToArray() | Sort-Object @{ Expression = { $_.LastUpdated }; Descending = $true }, @{ Expression = { $_.KB }; Descending = $true } | Select-Object -First 1)[0]
}

function Get-LatestPackageCatalogMetadata {
  param(
    [Parameter(Mandatory)] [string]$Destination,
    [ValidateSet('LCU','DotNet','SafeOS')] [string]$PackageType = 'LCU',
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64'
  )

  $downloader = Join-Path $PSScriptRoot 'Get-LatestWindows11LCU.ps1'
  if (-not (Test-Path -LiteralPath $downloader)) { throw "Update catalog dependency missing: $downloader" }
  if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $downloader,
    '-WindowsVersion', $WindowsVersion,
    '-Architecture', $Architecture,
    '-OutputPath', $Destination,
    '-MetadataOnly',
    '-PackageType', $PackageType
  )
  $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
  if ($proc.ExitCode -ne 0) { throw "Latest $PackageType metadata check failed with exit code $($proc.ExitCode)." }

  $cachePath = Join-Path $Destination 'catalog-cache.json'
  if (-not (Test-Path -LiteralPath $cachePath)) { throw "Update metadata check did not create cache: $cachePath" }
  $cache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $keys = @("Windows11-$WindowsVersion-$Architecture-$PackageType")
  if ($PackageType -eq 'LCU') { $keys += "Windows11-$WindowsVersion-$Architecture" }
  foreach ($key in $keys) {
    $entry = $cache.PSObject.Properties[$key]
    if ($entry -and $entry.Value) {
      $latest = $entry.Value
      if ($PackageType -eq 'LCU') {
        $latest | Add-Member -NotePropertyName BuildVersion -NotePropertyValue (ConvertTo-BuildVersion -Build ([string]$latest.Build)) -Force
      }
      return $latest
    }
  }
  throw "Update metadata cache entry missing for $PackageType."
}

function Get-ExistingLatestUpdatePackageByType {
  param(
    [Parameter(Mandatory)] [string]$Destination,
    [ValidateSet('LCU','DotNet','SafeOS')] [string]$PackageType,
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64'
  )

  switch ($PackageType) {
    'LCU'    { return (Get-ExistingLatestLcuPackage -Destination $Destination -WindowsVersion $WindowsVersion -Architecture $Architecture) }
    'DotNet' { return (Get-ExistingLatestDotNetPackage -Destination $Destination -WindowsVersion $WindowsVersion -Architecture $Architecture) }
    'SafeOS' { return (Get-ExistingLatestSafeOsPackage -Destination $Destination -WindowsVersion $WindowsVersion -Architecture $Architecture) }
  }
}

function Test-UpdatePromptAvailable {
  if ($SkipUpdateSelectionPrompt -or $AcceptRecommendedUpdates -or $DryRun) { return $false }
  try {
    if ([Console]::IsInputRedirected) { return $false }
  } catch { return $false }
  if (-not $Host -or $Host.Name -match '(?i)ServerRemoteHost') { return $false }
  return $true
}

function Format-BytesHuman {
  param([Nullable[Int64]]$Bytes)

  if ($null -eq $Bytes -or $Bytes -lt 0) { return 'unknown' }
  if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
  return ("$Bytes B")
}

function Resolve-RemoteContentLength {
  param([AllowNull()] [string]$Url)

  if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
    $len = $response.Headers['Content-Length']
    if ($len) { return [int64]$len }
  } catch {
    Write-Log "Could not resolve remote size for $Url : $($_.Exception.Message)" DEBUG
  }
  return $null
}

function Get-Windows11IsoPreview {
  param([Parameter(Mandatory)] [string]$InputFolder)

  $existing = @(Get-ChildItem -LiteralPath $InputFolder -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -ieq '.iso' } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1)

  if ($existing.Count -gt 0) {
    return [pscustomobject]@{
      Name = $existing[0].Name
      SizeBytes = [int64]$existing[0].Length
      SizeText = Format-BytesHuman -Bytes ([int64]$existing[0].Length)
      Status = 'Local ISO'
      Note = 'No ISO download needed'
    }
  }

  $metadata = @(Get-ChildItem -LiteralPath $InputFolder -File -Filter '*.iso.metadata.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1)
  if ($metadata.Count -gt 0) {
    try {
      $json = Get-Content -LiteralPath $metadata[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($json.PSObject.Properties['SizeBytes'] -and $json.SizeBytes) {
        return [pscustomobject]@{
          Name = if ($json.PSObject.Properties['FriendlyFileName']) { [string]$json.FriendlyFileName } else { 'Windows 11 ISO' }
          SizeBytes = [int64]$json.SizeBytes
          SizeText = Format-BytesHuman -Bytes ([int64]$json.SizeBytes)
          Status = 'Cached size'
          Note = 'ISO will download after selection if missing'
        }
      }
    } catch { }
  }

  return [pscustomobject]@{
    Name = 'Windows 11 x64 ISO'
    SizeBytes = $null
    SizeText = '~8.0-8.5 GB'
    Status = 'Will download'
    Note = 'Estimated until Microsoft link is resolved'
  }
}

function Format-UpdateUiText {
  param(
    [AllowNull()] [string]$Value,
    [int]$Width = 34
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { $Value = '-' }
  $clean = [regex]::Replace($Value, '\s+', ' ').Trim()
  if ($clean.Length -gt $Width) { return $clean.Substring(0, [Math]::Max(0, $Width - 3)) + '...' }
  return $clean.PadRight($Width)
}

function Split-UpdateUiText {
  param(
    [AllowNull()] [string]$Value,
    [int]$Width = 80
  )

  if ([string]::IsNullOrWhiteSpace($Value)) { $Value = '-' }
  $remaining = ([regex]::Replace([string]$Value, '\s+', ' ')).Trim()
  $lines = New-Object System.Collections.Generic.List[string]

  while ($remaining.Length -gt $Width) {
    $cut = $remaining.LastIndexOf(' ', [Math]::Min($Width, $remaining.Length - 1))
    if ($cut -lt 1) { $cut = $Width }
    $lines.Add($remaining.Substring(0, $cut).Trim()) | Out-Null
    $remaining = $remaining.Substring($cut).TrimStart()
  }

  $lines.Add($remaining) | Out-Null
  return @($lines)
}

function Get-UpdateSelectionStatus {
  param(
    [Parameter(Mandatory)] [object]$Latest,
    [AllowNull()] [object]$Existing,
    [ValidateSet('LCU','DotNet','SafeOS')] [string]$PackageType
  )

  if (-not $Existing) { return 'NEW / not local' }
  if ($PackageType -eq 'LCU') {
    $latestVersion = ConvertTo-BuildVersion -Build ([string]$Latest.Build)
    $existingVersion = if ($Existing.PSObject.Properties['BuildVersion']) { $Existing.BuildVersion } else { ConvertTo-BuildVersion -Build ([string]$Existing.Build) }
    if ($latestVersion -and $existingVersion -and ($latestVersion -gt $existingVersion)) { return 'NEWER available' }
  }
  if ($Latest.UpdateId -and $Existing.UpdateId -and ([string]$Latest.UpdateId -ne [string]$Existing.UpdateId)) { return 'NEWER/different' }
  $path = if ($Existing.PSObject.Properties['Path']) { [string]$Existing.Path } else { '' }
  if ($path -and (Test-Path -LiteralPath $path)) { return 'Local/current' }
  return 'Metadata only'
}

function Show-UpdateSelectionCenter {
  param(
    [Parameter(Mandatory)] [object[]]$Items,
    [AllowNull()] [object]$IsoPreview,
    [ValidateSet('Prompt','WIM','SWM','Both')] [string]$RequestedOutputMode = 'Prompt',
    [ValidateSet('Newbie','Expert')] [string]$SelectedUiMode = 'Newbie',
    [Parameter(Mandatory)] [pscustomobject]$Config
  )

  $selectedSize = 0L
  $knownSelectedSize = $true
  foreach ($item in ($Items | Where-Object { $_.Recommended })) {
    if ($null -ne $item.SizeBytes) { $selectedSize += [int64]$item.SizeBytes }
    else { $knownSelectedSize = $false }
  }
  $selectedSizeText = Format-BytesHuman -Bytes $selectedSize
  if (-not $knownSelectedSize) { $selectedSizeText = "$selectedSizeText + unknown" }
  $isoText = if ($IsoPreview) { $IsoPreview.SizeText } else { '~8.0-8.5 GB' }
  $isoStatus = if ($IsoPreview) { $IsoPreview.Status } else { 'Will download' }

  $boxWidth = 94
  $contentWidth = $boxWidth - 4

  function Write-UpdateRule {
    Write-Host ("  +{0}+" -f ('-' * ($boxWidth - 2))) -ForegroundColor Cyan
  }

  function Write-UpdateLine {
    param(
      [string]$Text = '',
      [ConsoleColor]$Color = 'DarkCyan'
    )
    if ($Text.Length -gt $contentWidth) { $Text = $Text.Substring(0, $contentWidth) }
    Write-Host ("  | {0,-$contentWidth} |" -f $Text) -ForegroundColor $Color
  }

  function Write-UpdateWrapped {
    param(
      [string]$Prefix,
      [string]$Value,
      [ConsoleColor]$Color = 'DarkGray'
    )

    $available = $contentWidth - $Prefix.Length
    if ($available -lt 20) { $available = 20 }
    $parts = @(Split-UpdateUiText -Value $Value -Width $available)
    for ($i = 0; $i -lt @($parts).Count; $i++) {
      if ($i -eq 0) { Write-UpdateLine ("$Prefix$($parts[$i])") $Color }
      else { Write-UpdateLine (((' ' * $Prefix.Length) + $parts[$i])) $Color }
    }
  }

  Write-Host ''
  Write-UpdateRule
  Write-UpdateLine 'BuildWIM Startup Selection Center' White
  Write-UpdateLine ("Mode: $SelectedUiMode") White
  if ($SelectedUiMode -eq 'Newbie') {
    Write-UpdateLine 'Simple mode: Enter keeps recommended safe defaults. Patches are shown below.' DarkCyan
  } else {
    Write-UpdateLine 'Expert mode: output, patches, cleanup, Defender and split size can be changed.' DarkCyan
  }
  Write-UpdateLine ("ISO payload: $isoText    ISO status: $isoStatus") DarkCyan
  Write-UpdateLine ("Recommended patch download size: $selectedSizeText") DarkCyan
  $outputText = if ($RequestedOutputMode -eq 'Prompt') { 'SWM only (default), WIM only, or Both' } else { $RequestedOutputMode }
  Write-UpdateLine ("Output format: $outputText") DarkCyan
  $cleanupText = if ($Config.Servicing.CleanupStartComponentCleanup -and $Config.Servicing.CleanupResetBase) { 'Component cleanup + ResetBase' } elseif ($Config.Servicing.CleanupStartComponentCleanup) { 'Component cleanup only' } else { 'Disabled' }
  Write-UpdateLine ("Cleanup: $cleanupText") DarkCyan
  Write-UpdateRule

  Write-UpdateLine 'Output format' White
  Write-UpdateLine '[O1] SWM only  (default)  -> install.swm + install2.swm ...' Green
  Write-UpdateLine '[O2] WIM only             -> install.wim' Yellow
  Write-UpdateLine '[O3] Both                 -> install.wim + install*.swm' Cyan
  Write-UpdateRule

  $defenderText = if ($Config.Defender.InjectLatestOfflineUpdate) { 'Enabled - offline signatures into main image' } else { 'Disabled (can be enabled in Expert mode)' }
  Write-UpdateLine 'Patch plan' White
  Write-UpdateLine 'BuildWIM separates OS image patches, WinRE recovery patches and Defender signatures.' DarkCyan
  Write-UpdateLine 'Main image : Windows LCU + .NET CU' DarkCyan
  Write-UpdateLine 'WinRE      : Safe OS Dynamic Update' DarkCyan
  Write-UpdateLine ("Defender   : $defenderText") DarkCyan
  Write-UpdateRule

  function Write-PatchGroup {
    param(
      [string]$Title,
      [string]$Description,
      [object[]]$GroupItems
    )

    Write-UpdateLine $Title White
    Write-UpdateLine $Description DarkCyan
    Write-UpdateRule
    foreach ($entry in $GroupItems) {
      $item = $entry.Item
      $number = $entry.Number
      $pick = if ($item.Recommended) { 'YES' } else { 'NO' }
      $statusText = if ($item.Status) { [string]$item.Status } else { '-' }
      $color = if ($item.Status -match 'NEW|NEWER') { 'Yellow' } elseif ($item.Status -match 'Local') { 'Green' } elseif ($item.Status -match 'Unavailable') { 'Red' } else { 'DarkCyan' }
      $stage = if ($item.PackageType -eq 'LCU') { 'Operating system cumulative update' } elseif ($item.PackageType -eq 'DotNet') { '.NET Framework cumulative update' } elseif ($item.PackageType -eq 'SafeOS') { 'WinRE / recovery environment update' } else { 'Offline package' }

      Write-UpdateLine ("[$number] $($item.Label)    Pick: $pick    Status: $statusText") $color
      Write-UpdateLine ("    Purpose: $stage") $color
      Write-UpdateLine ("    Inject : $($item.Target)") $color
      Write-UpdateLine ("    Patch  : $($item.KB)    Released: $($item.LastUpdated)    Size: $($item.SizeText)") $color
      if ($item.Build) { Write-UpdateLine ("    Build  : $($item.Build)") $color }
      if ($item.Title) { Write-UpdateWrapped '    Title  : ' ([string]$item.Title) DarkGray }
      if ($item.FileName) { Write-UpdateWrapped '    File   : ' ([string]$item.FileName) DarkGray }
      Write-UpdateRule
    }
  }

  $numberedItems = New-Object System.Collections.Generic.List[object]
  $i = 1
  foreach ($item in $Items) {
    $numberedItems.Add([pscustomobject]@{ Number = $i; Item = $item }) | Out-Null
    $i++
  }

  $mainImageItems = @($numberedItems.ToArray() | Where-Object { $_.Item.PackageType -in @('LCU','DotNet') })
  $recoveryItems = @($numberedItems.ToArray() | Where-Object { $_.Item.PackageType -eq 'SafeOS' })
  $otherItems = @($numberedItems.ToArray() | Where-Object { $_.Item.PackageType -notin @('LCU','DotNet','SafeOS') })

  Write-PatchGroup -Title 'Patch group 1/2 - Main Windows image' -Description 'Injected into install.wim/install.swm: OS security fixes and .NET fixes.' -GroupItems $mainImageItems
  Write-PatchGroup -Title 'Patch group 2/2 - Recovery environment (WinRE)' -Description 'Injected into winre.wim so recovery/setup media is serviced too.' -GroupItems $recoveryItems
  if ($otherItems.Count -gt 0) { Write-PatchGroup -Title 'Additional offline packages' -Description 'Extra packages discovered for this run.' -GroupItems $otherItems }

  if ($SelectedUiMode -eq 'Newbie') {
    Write-UpdateLine 'Newbie: Enter = SWM + recommended patches + ComponentCleanup/ResetBase' DarkCyan
    Write-UpdateLine '        O2/WIM = WIM only    O3/Both = both    E = switch to Expert' DarkCyan
  } else {
    Write-UpdateLine 'Expert updates: Enter = recommended    A = all    N = none    1,3 = custom' DarkCyan
    Write-UpdateLine 'Expert output : Enter = SWM only       O2/WIM = WIM only       O3/Both = both' DarkCyan
  }
  Write-UpdateLine 'Tip: use -AcceptRecommendedUpdates and/or -OutputMode for automation.' DarkCyan
  Write-UpdateRule
  Write-Host ''
}


function Set-UpdateSelectionFromAnswer {
  param(
    [Parameter(Mandatory)] [object[]]$Selection,
    [AllowNull()] [string]$Answer
  )

  $answerText = if ($null -eq $Answer) { '' } else { $Answer.Trim() }
  if ($answerText -match '(?i)^n(o|one)?$') {
    foreach ($item in $Selection) { $item.Selected = $false }
  } elseif ($answerText -match '(?i)^a(ll)?$' -or [string]::IsNullOrWhiteSpace($answerText)) {
    foreach ($item in $Selection) { $item.Selected = [bool]$item.Recommended }
  } else {
    foreach ($item in $Selection) { $item.Selected = $false }
    foreach ($token in ($answerText -split '[,;\s]+' | Where-Object { $_ })) {
      $idx = 0
      if ([int]::TryParse($token, [ref]$idx) -and $idx -ge 1 -and $idx -le @($Selection).Count) {
        $Selection[$idx - 1].Selected = $true
      }
    }
  }
}

function Get-CleanupSelectionText {
  param([Parameter(Mandatory)] [pscustomobject]$Config)
  if ($Config.Servicing.CleanupStartComponentCleanup -and $Config.Servicing.CleanupResetBase) { return 'Component cleanup + ResetBase' }
  if ($Config.Servicing.CleanupStartComponentCleanup) { return 'Component cleanup only' }
  return 'Disabled'
}

function Get-SelectedPatchSummaryText {
  param([Parameter(Mandatory)] [object[]]$Selection)
  $selected = @($Selection | Where-Object { $_.Selected } | ForEach-Object { if ($_.KB -and $_.KB -ne '-') { "$($_.Label) $($_.KB)" } else { $_.Label } })
  if ($selected.Count -eq 0) { return 'None' }
  return ($selected -join ', ')
}

function Set-OutputModeFromAnswer {
  param(
    [string]$CurrentOutputMode = 'SWM',
    [AllowNull()] [string]$Answer
  )
  $answerText = if ($null -eq $Answer) { '' } else { $Answer.Trim() }
  switch -Regex ($answerText) {
    '(?i)^(o?2|wim)$' { return 'WIM' }
    '(?i)^(o?3|both|b)$' { return 'Both' }
    '(?i)^(o?1|swm)$' { return 'SWM' }
    default { return $CurrentOutputMode }
  }
}

function Invoke-ExpertOptionsMenu {
  param(
    [Parameter(Mandatory)] [object[]]$Selection,
    [Parameter(Mandatory)] [pscustomobject]$Config,
    [ValidateSet('WIM','SWM','Both')] [string]$CurrentOutputMode = 'SWM'
  )

  while ($true) {
    Write-Host ''
    Write-Host '  +----------------------------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '  | BuildWIM Expert Options                                                    |' -ForegroundColor Cyan
    Write-Host '  +----------------------------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host ("  | [1] Output format       {0,-47} |" -f $CurrentOutputMode) -ForegroundColor White
    Write-Host ("  | [2] Patch plan          {0,-47} |" -f (Format-UpdateUiText -Value (Get-SelectedPatchSummaryText -Selection $Selection) -Width 47)) -ForegroundColor White
    Write-Host ("  | [3] Cleanup             {0,-47} |" -f (Get-CleanupSelectionText -Config $Config)) -ForegroundColor White
    $defenderText = if ($Config.Defender.InjectLatestOfflineUpdate) { 'Enabled' } else { 'Disabled' }
    Write-Host ("  | [4] Defender signatures {0,-47} |" -f $defenderText) -ForegroundColor White
    Write-Host ("  | [5] SWM split size      {0,-47} |" -f ("$($Config.Output.SplitSizeMB) MB")) -ForegroundColor White
    Write-Host '  +----------------------------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '  | [S]/Enter Start build    [R] Reset recommended    [Q] Abort                |' -ForegroundColor DarkCyan
    Write-Host '  +----------------------------------------------------------------------------+' -ForegroundColor Cyan

    $choice = Read-Host '  Expert choice'
    $choice = if ($null -eq $choice) { '' } else { $choice.Trim() }
    switch -Regex ($choice) {
      '(?i)^(s|start)?$' { return $CurrentOutputMode }
      '(?i)^q(uit)?$' { throw 'Build aborted by operator from Expert Options menu.' }
      '(?i)^r(eset)?$' {
        $CurrentOutputMode = 'SWM'
        foreach ($item in $Selection) { $item.Selected = [bool]$item.Recommended }
        $Config.Servicing.CleanupStartComponentCleanup = $true
        $Config.Servicing.CleanupResetBase = $true
        $Config.Defender.InjectLatestOfflineUpdate = $false
        $Config.Output.SplitSizeMB = 3800
      }
      '^1$' {
        $answer = Read-Host '  Output [Enter=keep, O1/SWM=SWM, O2/WIM=WIM, O3/Both=Both]'
        $CurrentOutputMode = Set-OutputModeFromAnswer -CurrentOutputMode $CurrentOutputMode -Answer $answer
      }
      '^2$' {
        $answer = Read-Host '  Patch plan [Enter=recommended, A=all, N=none, 1,2,3=custom]'
        Set-UpdateSelectionFromAnswer -Selection $Selection -Answer $answer
      }
      '^3$' {
        $answer = Read-Host '  Cleanup [Enter=Component cleanup + ResetBase, C=Component only, N=None]'
        $answer = if ($null -eq $answer) { '' } else { $answer.Trim() }
        switch -Regex ($answer) {
          '(?i)^n(one)?$' { $Config.Servicing.CleanupStartComponentCleanup = $false; $Config.Servicing.CleanupResetBase = $false; break }
          '(?i)^c(omponent)?$' { $Config.Servicing.CleanupStartComponentCleanup = $true; $Config.Servicing.CleanupResetBase = $false; break }
          default { $Config.Servicing.CleanupStartComponentCleanup = $true; $Config.Servicing.CleanupResetBase = $true }
        }
      }
      '^4$' {
        $answer = Read-Host '  Defender offline signatures [Y=inject, N=skip, Enter=toggle]'
        $answer = if ($null -eq $answer) { '' } else { $answer.Trim() }
        if ($answer -match '(?i)^y(es)?$') { $Config.Defender.InjectLatestOfflineUpdate = $true }
        elseif ($answer -match '(?i)^n(o)?$') { $Config.Defender.InjectLatestOfflineUpdate = $false }
        else { $Config.Defender.InjectLatestOfflineUpdate = -not [bool]$Config.Defender.InjectLatestOfflineUpdate }
      }
      '^5$' {
        $answer = Read-Host ("  SWM split size MB [Enter={0}]" -f $Config.Output.SplitSizeMB)
        $answer = if ($null -eq $answer) { '' } else { $answer.Trim() }
        $splitValue = 0
        if ([int]::TryParse($answer, [ref]$splitValue) -and $splitValue -ge 512) { $Config.Output.SplitSizeMB = $splitValue }
      }
    }
  }
}

function Invoke-UpdateSelectionCenter {
  param(
    [Parameter(Mandatory)] [string]$Destination,
    [string]$WindowsVersion = '25H2',
    [string]$Architecture = 'x64',
    [AllowNull()] [object]$IsoPreview,
    [ValidateSet('Prompt','WIM','SWM','Both')] [string]$RequestedOutputMode = 'Prompt',
    [ValidateSet('Prompt','Newbie','Expert')] [string]$RequestedUiMode = 'Prompt',
    [Parameter(Mandatory)] [pscustomobject]$Config
  )

  $defs = @(
    [pscustomobject]@{ PackageType='LCU';    Label='Windows LCU';       Target='Main image' },
    [pscustomobject]@{ PackageType='DotNet'; Label='.NET Framework CU'; Target='Main image' },
    [pscustomobject]@{ PackageType='SafeOS'; Label='Safe OS / WinRE DU'; Target='WinRE' }
  )

  $items = New-Object System.Collections.Generic.List[object]
  foreach ($def in $defs) {
    try {
      $latest = Get-LatestPackageCatalogMetadata -Destination $Destination -PackageType $def.PackageType -WindowsVersion $WindowsVersion -Architecture $Architecture
      $existing = Get-ExistingLatestUpdatePackageByType -Destination $Destination -PackageType $def.PackageType -WindowsVersion $WindowsVersion -Architecture $Architecture
      $status = Get-UpdateSelectionStatus -Latest $latest -Existing $existing -PackageType $def.PackageType
      $fileName = if ($latest.FileName) { [string]$latest.FileName } elseif ($existing -and $existing.FileName) { [string]$existing.FileName } else { '' }
      $sizeBytes = $null
      $sizeText = $null
      if ($existing -and $existing.PSObject.Properties['Path'] -and $existing.Path -and (Test-Path -LiteralPath ([string]$existing.Path))) {
        $sizeBytes = [int64](Get-Item -LiteralPath ([string]$existing.Path)).Length
        $sizeText = Format-BytesHuman -Bytes $sizeBytes
      } elseif ($latest.PSObject.Properties['SizeBytes'] -and $null -ne $latest.SizeBytes) {
        $sizeBytes = [int64]$latest.SizeBytes
        $sizeText = if ($latest.PSObject.Properties['SizeText'] -and $latest.SizeText) { [string]$latest.SizeText } else { Format-BytesHuman -Bytes $sizeBytes }
      } elseif ($latest.PSObject.Properties['Url'] -and $latest.Url) {
        $sizeBytes = Resolve-RemoteContentLength -Url ([string]$latest.Url)
        $sizeText = Format-BytesHuman -Bytes $sizeBytes
      } elseif ($latest.PSObject.Properties['SizeText'] -and $latest.SizeText) {
        $sizeText = [string]$latest.SizeText
      } else {
        $sizeText = Format-BytesHuman -Bytes $sizeBytes
      }
      $recommended = $true
      $items.Add([pscustomobject]@{
        PackageType = $def.PackageType
        Label = $def.Label
        Target = $def.Target
        KB = [string]$latest.KB
        Title = [string]$latest.Title
        LastUpdated = [string]$latest.LastUpdated
        Build = [string]$latest.Build
        UpdateId = [string]$latest.UpdateId
        Url = if ($latest.PSObject.Properties['Url']) { [string]$latest.Url } else { '' }
        FileName = $fileName
        SizeBytes = $sizeBytes
        SizeText = $sizeText
        Status = $status
        Recommended = $recommended
        Selected = $recommended
      }) | Out-Null
    } catch {
      Add-Warn "Update discovery failed for $($def.Label): $($_.Exception.Message)"
      $items.Add([pscustomobject]@{
        PackageType = $def.PackageType; Label = $def.Label; Target = $def.Target; KB = '-'; Title = ''; LastUpdated = ''; Build = ''; UpdateId = ''; Url = ''; FileName = ''; SizeBytes = $null; SizeText = 'unknown'; Status = 'Unavailable'; Recommended = $false; Selected = $false
      }) | Out-Null
    }
  }

  $selection = @($items.ToArray())
  $canPrompt = Test-UpdatePromptAvailable
  $selectedUiMode = if ($RequestedUiMode -ne 'Prompt') { $RequestedUiMode } else { 'Newbie' }

  if ($RequestedUiMode -eq 'Prompt' -and $canPrompt) {
    Write-Host ''
    Write-Host '  BuildWIM mode' -ForegroundColor White
    Write-Host '  [Enter] Newbie - simple defaults, visible patch list' -ForegroundColor Green
    Write-Host '  [E]     Expert - change output, patches, cleanup and advanced options' -ForegroundColor Yellow
    $modeAnswer = Read-Host '  Choose mode [Enter=Newbie, E=Expert]'
    if ($modeAnswer -match '(?i)^e(xpert)?$') { $selectedUiMode = 'Expert' }
  }

  Show-UpdateSelectionCenter -Items $selection -IsoPreview $IsoPreview -RequestedOutputMode $RequestedOutputMode -SelectedUiMode $selectedUiMode -Config $Config

  $selectedOutputMode = if ($RequestedOutputMode -ne 'Prompt') { $RequestedOutputMode } else { 'SWM' }

  foreach ($item in $selection) { $item.Selected = [bool]$item.Recommended }

  if ($RequestedOutputMode -ne 'Prompt') {
    Write-Log "Output mode selected by parameter: $selectedOutputMode" INFO
  } elseif ($canPrompt -and $selectedUiMode -eq 'Newbie') {
    $outputAnswer = Read-Host '  Newbie output [Enter=SWM default, O2/WIM=WIM, O3/Both=Both, E=Expert]'
    $outputAnswer = if ($null -eq $outputAnswer) { '' } else { $outputAnswer.Trim() }
    if ($outputAnswer -match '(?i)^e(xpert)?$') { $selectedUiMode = 'Expert' }
    else { $selectedOutputMode = Set-OutputModeFromAnswer -CurrentOutputMode $selectedOutputMode -Answer $outputAnswer }
  } elseif (-not $canPrompt) {
    if ($SkipUpdateSelectionPrompt) { Write-Log 'Update selection prompt skipped; using recommended defaults.' INFO }
    else { Write-Log 'Non-interactive console detected; using recommended defaults.' INFO }
  }

  if ($canPrompt -and $selectedUiMode -eq 'Expert') {
    $selectedOutputMode = Invoke-ExpertOptionsMenu -Selection $selection -Config $Config -CurrentOutputMode $selectedOutputMode
  } elseif ($selectedUiMode -eq 'Newbie') {
    $Config.Servicing.CleanupStartComponentCleanup = $true
    $Config.Servicing.CleanupResetBase = $true
    Write-Log 'Newbie mode selected; using recommended patch selection and ComponentCleanup+ResetBase.' INFO
  }

  $script:Run.Output.Mode = $selectedOutputMode
  Add-StepResult -Name 'Output format selection' -StartTime (Get-Date) -EndTime (Get-Date) -Details $selectedOutputMode

  $script:Run.Packages.UpdateSelection = @($selection)
  $script:Run.Packages.SelectedUpdateFileNames = @($selection | Where-Object { $_.Selected -and $_.FileName } | ForEach-Object { $_.FileName })
  return @($selection)
}

function Test-UpdateTypeSelected {
  param(
    [Parameter(Mandatory)] [object[]]$Selection,
    [ValidateSet('LCU','DotNet','SafeOS')] [string]$PackageType
  )
  $item = $Selection | Where-Object { $_.PackageType -eq $PackageType } | Select-Object -First 1
  return [bool]($item -and $item.Selected)
}

function Get-SelectedUpdateItem {
  param(
    [Parameter(Mandatory)] [object[]]$Selection,
    [ValidateSet('LCU','DotNet','SafeOS')] [string]$PackageType
  )
  return ($Selection | Where-Object { $_.PackageType -eq $PackageType } | Select-Object -First 1)
}

function Add-SafeOsDynamicUpdateToWinRe {
  param(
    [Parameter(Mandatory)] [string]$MountDir,
    [Parameter(Mandatory=$false)] [AllowEmptyCollection()] [object[]]$Packages = @(),
    [Parameter(Mandatory)] [string]$ScratchDir,
    [Parameter(Mandatory)] [pscustomobject]$Config
  )

  $safeOsPackages = @($Packages | Where-Object { $_.Classification -eq 'SafeOSDU' })
  if ($safeOsPackages.Count -eq 0) { return 0 }

  $winRePath = Join-Path $MountDir 'Windows\System32\Recovery\winre.wim'
  if (-not (Test-Path -LiteralPath $winRePath)) {
    Add-Warn "Safe OS Dynamic Update hittades, men WinRE saknas i imagen: $winRePath"
    return 0
  }

  $winReMount = New-IsolatedMountDir -MountRoot $script:Paths['Mount'] -Prefix 'WinRE'
  Write-Log "Mounting WinRE for Safe OS Dynamic Update: $winRePath -> $winReMount" INFO

  try {
    Mount-InstallImage -WimPath $winRePath -MountDir $winReMount -Index 1 -ScratchDir $ScratchDir
    Ensure-MountedImageReady -MountDir $winReMount -ScratchDir $ScratchDir
    Add-OfflinePackages -MountDir $winReMount -SortedPackages $safeOsPackages -ScratchDir $ScratchDir
    Invoke-ImageCleanup -MountDir $winReMount -Config $Config -ScratchDir $ScratchDir
    Dismount-InstallImage -MountDir $winReMount -Commit -ScratchDir $ScratchDir
    return $safeOsPackages.Count
  } catch {
    try { Dismount-InstallImage -MountDir $winReMount -ScratchDir $ScratchDir } catch { }
    throw
  }
}

function Start-BuildProcess {
  param([pscustomobject]$Config)

  $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $dateFolder = (Get-Date).ToString('yyyy-MM-dd')
  $script:Paths['OutputDated'] = Join-Path $script:Paths['Output'] $dateFolder
  if (-not (Test-Path -LiteralPath $script:Paths['OutputDated'])) {
    New-Item -ItemType Directory -Path $script:Paths['OutputDated'] | Out-Null
  }
  $script:LogFile = Join-Path $script:Paths['Logs'] "BuildWIM-$timestamp.log"
  $transcript = Join-Path $script:Paths['Logs'] "BuildWIM-$timestamp.transcript.txt"
  $reportPath = Join-Path $script:Paths['Reports'] "BuildWIM-$timestamp.html"

  if (-not $DryRun) {
    Start-Transcript -LiteralPath $transcript -Force | Out-Null
  }

  try {
    Write-Log "BuildWIM v$($script:Run.Version) starting" INFO

    # Disk space is checked before download, ISO extraction, mount, or package work.
    $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($Root).Substring(0,1))
    $script:Run.Summary.DiskFreeGBAtStart = [math]::Round($drive.Free/1GB, 2)
    Test-FreeDiskSpace -Path $Root -MinGB $Config.Safety.MinFreeSpaceGB
    Add-StepResult -Name 'Disk space preflight' -StartTime (Get-Date) -EndTime (Get-Date) -Details ("Free {0} GB, required {1} GB" -f $script:Run.Summary.DiskFreeGBAtStart, $Config.Safety.MinFreeSpaceGB)
    Show-Progress -Activity "BuildWIM Pipeline" -Status "Disk space preflight OK" -Percent 2

    # Put the single operator menu first. The Startup Selection Center intentionally runs
    # before Windows ISO download/source discovery so the user can review output format,
    # patch scope, and estimated payload sizes before expensive downloads begin.
    $stepStart = Get-Date
    $isoPreview = Get-Windows11IsoPreview -InputFolder $script:Paths['Input']
    $updateSelection = @(Invoke-UpdateSelectionCenter -Destination $script:Paths['Updates'] -WindowsVersion $UpdateWindowsVersion -Architecture $UpdateArchitecture -IsoPreview $isoPreview -RequestedOutputMode $OutputMode -RequestedUiMode $UiMode -Config $Config)
    Add-StepResult -Name 'Startup selection menu' -StartTime $stepStart -EndTime (Get-Date) -Details ((@($updateSelection | Where-Object { $_.Selected }) | ForEach-Object { "$($_.PackageType):$($_.KB)" }) -join ', ')

    $outputModeSelected = if ($script:Run.Output.Mode) { [string]$script:Run.Output.Mode } else { 'SWM' }
    Write-Log "Output mode for this run: $outputModeSelected" INFO

    # Detect input for banner. If Input is empty, pull the official Windows 11 ISO
    # only after update selection has completed.
    Invoke-Windows11IsoAutoDownload -Destination $script:Paths['Input']
    $bannerInput = Get-InputSourceType -InputFolder $script:Paths['Input'] -TempFolder $script:Paths['Temp']
    Show-Banner -InputType $bannerInput.Type -InputFile ([IO.Path]::GetFileName($bannerInput.Path))

    # Thorough cleanup before starting - prevents locked file issues
    Write-Log "Performing thorough cleanup before starting..." INFO
    Clear-StaleMounts
    Start-Sleep -Seconds 2

    # Clean up any old working WIM files with this pattern
    $oldWims = Get-ChildItem -LiteralPath $script:Paths['Temp'] -Filter "install-pro-*.wim" -ErrorAction SilentlyContinue
    foreach ($wim in $oldWims) {
      try {
        Remove-Item -LiteralPath $wim.FullName -Force -ErrorAction Stop
        Write-Log "Cleaned up old working WIM: $($wim.Name)" INFO
      } catch {
        try {
          $renamed = $wim.FullName + ".cleanup"
          Rename-Item -LiteralPath $wim.FullName -NewName (Split-Path $renamed -Leaf) -Force -ErrorAction SilentlyContinue
        } catch { }
      }
    }

    if ($Config.Safety.ForceCleanupWim) { Clear-StaleMounts }

    $stepStart = Get-Date
    $input = $bannerInput
    $script:Run.Input.Type = $input.Type
    $script:Run.Input.Path = $input.Path

    # Hash input
    $script:Run.Input.SHA256 = Get-FileHashSafe -Path $input.Path
    Initialize-EtaState -Config $Config
    Update-EtaProgress -CurrentStep 'Startup' -PercentComplete 0
    Add-StepResult -Name 'Detect input' -StartTime $stepStart -EndTime (Get-Date) -Details ("{0} ({1})" -f $input.Path, $input.Type)
    Update-EtaProgress -CurrentStep 'Detect input' -PercentComplete 5

    $workingInputPath = $null

    if ($input.Type -eq 'ISO') {
      $stepStart = Get-Date
      $found = Mount-IsoIfNeeded -IsoPath $input.Path -SearchRelativePaths $Config.Input.IsoSearchRelativePaths
      $dest = Join-Path $script:Paths['Temp'] (Split-Path -Leaf $found)
      Write-Log "Copying image from ISO: $found -> $dest" INFO
      if (-not $DryRun) { Copy-Item -LiteralPath $found -Destination $dest -Force }
      $workingInputPath = $dest
      Dismount-IsoIfNeeded
      Add-StepResult -Name 'Extract image from ISO' -StartTime $stepStart -EndTime (Get-Date) -Details $found
      Update-EtaProgress -CurrentStep 'Extract image from ISO' -PercentComplete 15
    } else {
      $workingInputPath = $input.Path
    }

    # If ESD -> convert to temp WIM
    if ([IO.Path]::GetExtension($workingInputPath) -ieq '.esd') {
      $stepStart = Get-Date
      $tempWim = Join-Path $script:Paths['Temp'] 'install-from-esd.wim'
      Convert-EsdToWim -EsdPath $workingInputPath -WimOutPath $tempWim | Out-Null
      $workingInputPath = $tempWim
      Add-StepResult -Name 'Convert ESD to WIM' -StartTime $stepStart -EndTime (Get-Date) -Details $tempWim
      Update-EtaProgress -CurrentStep 'Convert ESD to WIM' -PercentComplete 20
    }

    # Get image info and pro index
    $stepStart = Get-Date
    $info = Get-ImageInfo -ImagePath $workingInputPath
    $script:Run.Image.AllEditions = $info
    $proIndex = Get-Windows11ProIndex -ImageInfo $info -EditionNameMatch $Config.Servicing.EditionNameMatch
    $script:Run.Image.ProIndex = $proIndex
    $selectedEdition = $info | Where-Object { $_.Index -eq $proIndex } | Select-Object -First 1
    if ($selectedEdition) {
      $script:Run.Image.SelectedEditionName = $selectedEdition.Name
      $script:Run.Image.SourceSelectedEditionName = $selectedEdition.Name
      $script:Run.Image.SourceSelectedEditionVersion = $selectedEdition.Version
      $script:Run.Image.SourceSelectedEditionArchitecture = $selectedEdition.Architecture
      $script:Run.Image.SourceSelectedEditionServicePackBuild = $selectedEdition.ServicePackBuild
    }
    Add-StepResult -Name 'Inspect source image' -StartTime $stepStart -EndTime (Get-Date) -Details ("Selected index {0}: {1}" -f $proIndex, $script:Run.Image.SelectedEditionName)
    Update-EtaProgress -CurrentStep 'Inspect source image' -PercentComplete 22

    # Delta detection uses the already-captured early update selection after the
    # source image is available, because source build revision requires WIM/ISO inspection.
    $latestLcu = $null
    $latestDotNet = $null
    $latestSafeOs = $null

    $lcuItem = Get-SelectedUpdateItem -Selection $updateSelection -PackageType 'LCU'
    if ($lcuItem -and $lcuItem.KB -ne '-') {
      $script:Run.Summary.LatestLcuKB = $lcuItem.KB
      $script:Run.Summary.LatestLcuBuild = $lcuItem.Build
      $script:Run.Summary.LatestLcuLastUpdated = $lcuItem.LastUpdated
      $releaseClass = Get-LcuReleaseClassification -Title ([string]$lcuItem.Title) -LastUpdated ([string]$lcuItem.LastUpdated)
      $script:Run.Summary.LatestLcuReleaseType = $releaseClass.Type
      $script:Run.Summary.LatestLcuIsOob = $releaseClass.IsOob
      $script:Run.Summary.LatestLcuPatchTuesday = $releaseClass.PatchTuesday
      $sourceRev = if ($script:Run.Image.SourceSelectedEditionServicePackBuild) { [int]$script:Run.Image.SourceSelectedEditionServicePackBuild } else { Get-BuildRevision -Version ([string]$script:Run.Image.SourceSelectedEditionVersion) }
      $targetRev = Get-LcuBuildRevision -Build ([string]$lcuItem.Build)
      $script:Run.Summary.SourceBuildRevision = $sourceRev
      $script:Run.Summary.TargetBuildRevision = $targetRev
    }

    if (Test-UpdateTypeSelected -Selection $updateSelection -PackageType 'LCU') {
      $stepStart = Get-Date
      Invoke-LatestLcuDownload -Destination $script:Paths['Updates'] -WindowsVersion $UpdateWindowsVersion -Architecture $UpdateArchitecture
      $latestLcu = Get-ExistingLatestLcuPackage -Destination $script:Paths['Updates'] -WindowsVersion $UpdateWindowsVersion -Architecture $UpdateArchitecture
      Add-StepResult -Name 'Ensure selected LCU' -StartTime $stepStart -EndTime (Get-Date) -Details ("{0} {1}" -f $script:Run.Summary.LatestLcuKB, $script:Run.Summary.LatestLcuBuild)
    } else {
      Write-Log 'Windows LCU was not selected for this WIM run.' WARN
    }

    if (Test-UpdateTypeSelected -Selection $updateSelection -PackageType 'DotNet') {
      $stepStart = Get-Date
      Invoke-LatestExtraPackageDownload -Destination $script:Paths['Updates'] -PackageType DotNet -WindowsVersion $UpdateWindowsVersion -Architecture $UpdateArchitecture
      $latestDotNet = Get-ExistingLatestDotNetPackage -Destination $script:Paths['Updates'] -WindowsVersion $UpdateWindowsVersion -Architecture $UpdateArchitecture
      Add-StepResult -Name 'Ensure selected .NET CU' -StartTime $stepStart -EndTime (Get-Date) -Details ("{0} {1}" -f $script:Run.Summary.LatestDotNetKB, $script:Run.Summary.LatestDotNetLastUpdated)
    } else {
      Write-Log '.NET Framework CU was not selected for this WIM run.' WARN
    }

    if (Test-UpdateTypeSelected -Selection $updateSelection -PackageType 'SafeOS') {
      $stepStart = Get-Date
      Invoke-LatestExtraPackageDownload -Destination $script:Paths['Updates'] -PackageType SafeOS -WindowsVersion $UpdateWindowsVersion -Architecture $UpdateArchitecture
      $latestSafeOs = Get-ExistingLatestSafeOsPackage -Destination $script:Paths['Updates'] -WindowsVersion $UpdateWindowsVersion -Architecture $UpdateArchitecture
      Add-StepResult -Name 'Ensure selected Safe OS DU' -StartTime $stepStart -EndTime (Get-Date) -Details ("{0} {1}" -f $script:Run.Summary.LatestSafeOsKB, $script:Run.Summary.LatestSafeOsLastUpdated)
    } else {
      Write-Log 'Safe OS / WinRE Dynamic Update was not selected for this WIM run.' WARN
    }

    $dotNetRequiresRebuild = (Test-UpdateTypeSelected -Selection $updateSelection -PackageType 'DotNet') -and ($null -ne $latestDotNet)
    $safeOsRequiresRebuild = (Test-UpdateTypeSelected -Selection $updateSelection -PackageType 'SafeOS') -and ($null -ne $latestSafeOs)

    if ($script:Run.Summary.LatestLcuKB) {
      $sourceRev = $script:Run.Summary.SourceBuildRevision
      $targetRev = $script:Run.Summary.TargetBuildRevision
      if ((-not $ForceRebuild) -and (-not $dotNetRequiresRebuild) -and (-not $safeOsRequiresRebuild) -and $sourceRev -and $targetRev -and ($sourceRev -ge $targetRev)) {
        $script:Run.Summary.SkippedBecauseCurrent = $true
        $script:Run.Image.FinalEditionName = $script:Run.Image.SourceSelectedEditionName
        $script:Run.Image.FinalEditionVersion = $script:Run.Image.SourceSelectedEditionVersion
        $script:Run.Image.FinalEditionArchitecture = $script:Run.Image.SourceSelectedEditionArchitecture
        $script:Run.Image.FinalEditionServicePackBuild = $script:Run.Image.SourceSelectedEditionServicePackBuild
        Add-StepResult -Name 'Delta decision' -StartTime (Get-Date) -EndTime (Get-Date) -Details ("Source image is already current ({0} >= {1}) and no selected .NET CU or Safe OS DU package requires rebuild. Use -ForceRebuild to rebuild anyway." -f $sourceRev, $targetRev)
        $reports = Complete-CurrentBuildReport -Run $script:Run -ReportPath $reportPath
        Write-Log ("No rebuild needed. Source image is already at or above latest LCU {0} build {1}, and no selected .NET CU or Safe OS DU package requires rebuild. Report: {2}" -f $script:Run.Summary.LatestLcuKB, $script:Run.Summary.LatestLcuBuild, $reports.Html) INFO
        return
      }
      if ((-not $ForceRebuild) -and ($dotNetRequiresRebuild -or $safeOsRequiresRebuild) -and $sourceRev -and $targetRev -and ($sourceRev -ge $targetRev)) {
        Write-Log ("Source image is current for OS LCU ({0} >= {1}), but selected extra servicing packages are present (.NET={2}, SafeOS={3}); continuing rebuild." -f $sourceRev, $targetRev, $script:Run.Summary.LatestDotNetKB, $script:Run.Summary.LatestSafeOsKB) INFO
      }
    }
    Update-EtaProgress -CurrentStep 'Update Selection Center' -PercentComplete 28

    # Export Pro-only working WIM BEFORE patching
    $stepStart = Get-Date
    $workingWim = Join-Path $script:Paths['Temp'] "install-pro-only-$timestamp.wim"
    Export-ProEditionOnly -SourceWim $workingInputPath -ProIndex $proIndex -DestWim $workingWim | Out-Null
    $script:Run.Image.WorkingWim = $workingWim

    # Safety: verify working wim has only one index
    $workingInfo = @(Get-ImageInfo -ImagePath $workingWim)
    if ($workingInfo.Length -ne 1) {
      throw "Working WIM is expected to have exactly 1 index, found $($workingInfo.Length). Aborting."
    }
    if ($workingInfo[0]) {
      $script:Run.Image.WorkingEditionName = $workingInfo[0].Name
      $script:Run.Image.WorkingEditionVersion = $workingInfo[0].Version
      $script:Run.Image.WorkingEditionArchitecture = $workingInfo[0].Architecture
    }
    Add-StepResult -Name 'Export Pro-only working WIM' -StartTime $stepStart -EndTime (Get-Date) -Details $workingWim
    Update-EtaProgress -CurrentStep 'Export Pro-only working WIM' -PercentComplete 30

    # Discover updates
    $stepStart = Get-Date
    $updatesFolder = $script:Paths['Updates']
    $allowed = $Config.Updates.AllowedExtensions
    $updateFiles = Get-ChildItem -LiteralPath $updatesFolder -File -ErrorAction SilentlyContinue | Where-Object { $allowed -contains $_.Extension.ToLowerInvariant() }

    $pkgs = @()

    foreach ($u in ($updateFiles | Sort-Object FullName)) {
      # MSU extraction is intentionally not used. DISM can service MSU directly offline.
      $pkgs += (Get-PackageClassification -Path $u.FullName)
    }

    $selectedFileNames = @($script:Run.Packages.SelectedUpdateFileNames)
    if ($selectedFileNames.Count -gt 0) {
      $excluded = @($pkgs | Where-Object { $selectedFileNames -notcontains $_.FileName })
      if ($excluded.Count -gt 0) {
        $script:Run.Packages.ExcludedBySelection = @($excluded)
        foreach ($ex in $excluded) { Write-Log ("Excluded by Update Selection Center: [{0}] {1}" -f $ex.Classification, $ex.FileName) INFO }
      }
      $pkgs = @($pkgs | Where-Object { $selectedFileNames -contains $_.FileName })
    }

    $script:Run.Packages.Found = $pkgs

    # Sort
    $sorted = @(Sort-PackagesByServicingOrder -Packages $pkgs)
    $script:Run.Packages.Sorted = $sorted
    $packageWarnings = @(Test-UpdatePackageSet -Packages $sorted)
    foreach ($pkgWarn in $packageWarnings) { Add-Warn $pkgWarn }
    Add-StepResult -Name 'Discover update packages' -StartTime $stepStart -EndTime (Get-Date) -Details ("Found {0} package(s)" -f $sorted.Length)
    Update-EtaProgress -CurrentStep 'Discover update packages' -PercentComplete 35

    if ($sorted.Length -eq 0) {
      Add-Warn "No updates found in $updatesFolder. Continuing with Pro-only export and outputs."
    } else {
      Write-Log "Package servicing order:" INFO
      foreach ($p in $sorted) { Write-Log ("  - [{0}] {1}" -f $p.Classification, $p.FileName) INFO }
    }

    # Optionally fetch the latest Microsoft Defender offline update package for WIM servicing.
    $stepStart = Get-Date
    $defenderPackage = Get-DefenderOfflineUpdatePackage -Config $Config -ImageArchitecture $script:Run.Image.WorkingEditionArchitecture
    if ($defenderPackage) {
      Add-StepResult -Name 'Download Defender offline update' -StartTime $stepStart -EndTime (Get-Date) -Details $defenderPackage.CabPath
      Update-EtaProgress -CurrentStep 'Download Defender offline update' -PercentComplete 38
    }

    Show-Progress -Activity "BuildWIM Pipeline" -Status "Mounting working WIM" -Percent 30

    # Mount into an isolated per-run directory. Reusing the mount root directly can
    # leave DISM in stale/Needs Remount states after interrupted runs.
    $mountRoot = $script:Paths['Mount']
    $mountDir = if ($DryRun) { Join-Path $mountRoot 'Mount-DryRun' } else { New-IsolatedMountDir -MountRoot $mountRoot }
    $scratch = $script:Paths['Scratch']

    # Cleanup any existing mount at $mountDir (only relevant for DryRun reuse)
    if ($DryRun -and (Test-Path -LiteralPath $mountDir)) {
      try {
        Dismount-InstallImage -MountDir $mountDir -ScratchDir $scratch
      } catch {
        Write-Log "Warning: Failed to dismount existing image at ${mountDir}: $($_.Exception.Message)" WARN
      }
    }

    # Ensure mount dir empty when using the reusable DryRun mount path
    if ($DryRun) {
      Get-ChildItem -LiteralPath $mountDir -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }

    $stepStart = Get-Date
    Mount-InstallImage -WimPath $workingWim -MountDir $mountDir -Index 1 -ScratchDir $scratch
    Ensure-MountedImageReady -MountDir $mountDir -ScratchDir $scratch
    Add-StepResult -Name 'Mount working WIM' -StartTime $stepStart -EndTime (Get-Date) -Details $mountDir
    Update-EtaProgress -CurrentStep 'Mount working WIM' -PercentComplete 40

    try {
      # Capture existing packages and enabled features for reporting
      try {
        $pkgOut = (Invoke-Dism -Arguments @('/English',"/Image:$mountDir",'/Get-Packages'))
        $pkgLines = ($pkgOut.StdOut -split "`r?`n") | Where-Object { $_ -match '(?i)^Package Identity\s*:\s*' } | ForEach-Object { ($_ -replace '(?i)^Package Identity\s*:\s*','').Trim() }
        $script:Run.Image.ExistingPackages = @($pkgLines)
      } catch { Add-Warn "Failed to query existing packages: $($_.Exception.Message)" }

      try {
        $featOut = (Invoke-Dism -Arguments @('/English',"/Image:$mountDir",'/Get-Features'))
        # Pull lines like: Feature Name : X / State : Enabled
        $lines = ($featOut.StdOut -split "`r?`n")
        $enabled = New-Object System.Collections.Generic.List[string]
        $current = $null
        foreach ($ln in $lines) {
          if ($ln -match '(?i)^Feature Name\s*:\s*(.+)$') { $current = $matches[1].Trim() }
          elseif ($current -and $ln -match '(?i)^State\s*:\s*Enabled') { $enabled.Add($current) | Out-Null; $current = $null }
        }
        $script:Run.Image.EnabledFeatures = @($enabled)
      } catch { Add-Warn "Failed to query features: $($_.Exception.Message)" }

      $mainImagePackages = @($sorted | Where-Object { $_.Classification -ne 'SafeOSDU' })
      $safeOsPackages = @($sorted | Where-Object { $_.Classification -eq 'SafeOSDU' })

      if ($mainImagePackages.Length -gt 0) {
        $stepStart = Get-Date
        Show-Progress -Activity "BuildWIM Pipeline" -Status "Injecting update packages" -Percent 55
        Add-OfflinePackages -MountDir $mountDir -SortedPackages $mainImagePackages -ScratchDir $scratch
        Add-StepResult -Name 'Inject update packages' -StartTime $stepStart -EndTime (Get-Date) -Details ("Injected {0} package(s)" -f $script:Run.Packages.Injected.Count)
        Update-EtaProgress -CurrentStep 'Inject update packages' -PercentComplete 60
      }

      if ($safeOsPackages.Length -gt 0) {
        $stepStart = Get-Date
        Show-Progress -Activity "BuildWIM Pipeline" -Status "Injecting Safe OS DU into WinRE" -Percent 62
        $safeOsInjected = Add-SafeOsDynamicUpdateToWinRe -MountDir $mountDir -Packages $safeOsPackages -ScratchDir $scratch -Config $Config
        Add-StepResult -Name 'Inject Safe OS DU into WinRE' -StartTime $stepStart -EndTime (Get-Date) -Details ("Injected {0} Safe OS package(s) into winre.wim" -f $safeOsInjected)
        Update-EtaProgress -CurrentStep 'Inject Safe OS DU into WinRE' -PercentComplete 64
      }

      if ($defenderPackage) {
        $stepStart = Get-Date
        Show-Progress -Activity "BuildWIM Pipeline" -Status "Injecting Microsoft Defender offline update" -Percent 64
        Add-DefenderOfflineUpdate -MountDir $mountDir -DefenderPackage $defenderPackage -ScratchDir $scratch
        Add-StepResult -Name 'Inject Defender offline update' -StartTime $stepStart -EndTime (Get-Date) -Details $defenderPackage.CabPath
        Update-EtaProgress -CurrentStep 'Inject Defender offline update' -PercentComplete 65
      }

      $stepStart = Get-Date
      Show-Progress -Activity "BuildWIM Pipeline" -Status "Running image cleanup" -Percent 65
      Invoke-ImageCleanup -MountDir $mountDir -Config $Config -ScratchDir $scratch
      Add-StepResult -Name 'Offline cleanup' -StartTime $stepStart -EndTime (Get-Date) -Details 'StartComponentCleanup completed'
      Update-EtaProgress -CurrentStep 'Offline cleanup' -PercentComplete 70

      $stepStart = Get-Date
      Dismount-InstallImage -MountDir $mountDir -Commit -ScratchDir $scratch
      Add-StepResult -Name 'Commit and unmount image' -StartTime $stepStart -EndTime (Get-Date) -Details $mountDir
      Update-EtaProgress -CurrentStep 'Commit and unmount image' -PercentComplete 78
    } catch {
      Add-Err $_.Exception.Message
      try { Dismount-InstallImage -MountDir $mountDir -ScratchDir $scratch } catch { }
      throw
    }

    $selectedOutputMode = if ($script:Run.Output.Mode) { [string]$script:Run.Output.Mode } else { 'SWM' }
    $keepFinalWim = ($selectedOutputMode -eq 'WIM' -or $selectedOutputMode -eq 'Both')
    $createSwm = ($selectedOutputMode -eq 'SWM' -or $selectedOutputMode -eq 'Both')

    Show-Progress -Activity "BuildWIM Pipeline" -Status "Exporting final WIM" -Percent 80

    # Export final WIM to Output. SWM-only still needs a temporary WIM because DISM
    # splits from a WIM source; it is deleted before final hashes/manifests are written.
    $stepStart = Get-Date
    $finalWim = Join-Path $script:Paths['OutputDated'] $Config.Output.InstallWimName
    Export-FinalWim -SourceWim $workingWim -DestWim $finalWim
    Add-StepResult -Name 'Export final WIM' -StartTime $stepStart -EndTime (Get-Date) -Details $finalWim
    Update-EtaProgress -CurrentStep 'Export final WIM' -PercentComplete 88

    $size = if ($PSBoundParameters.ContainsKey('SplitSizeMB') -and $SplitSizeMB) { $SplitSizeMB } else { [int]$Config.Output.SplitSizeMB }
    $swmBase = Join-Path $script:Paths['OutputDated'] $Config.Output.SplitBaseName

    if ($createSwm) {
      Show-Progress -Activity "BuildWIM Pipeline" -Status "Splitting WIM for FAT32 media" -Percent 90
      $stepStart = Get-Date
      Split-WimForFat32 -WimPath $finalWim -SwmBasePath $swmBase -SizeMB $size
      Add-StepResult -Name 'Split WIM to SWM' -StartTime $stepStart -EndTime (Get-Date) -Details ("Base {0}, size {1} MB" -f $swmBase, $size)
      Update-EtaProgress -CurrentStep 'Split WIM to SWM' -PercentComplete 95
    } else {
      Write-Log 'Output mode is WIM only; skipping SWM split.' INFO
      Add-StepResult -Name 'Split WIM to SWM' -StartTime (Get-Date) -EndTime (Get-Date) -Details 'Skipped by output mode: WIM'
      Update-EtaProgress -CurrentStep 'Output selection' -PercentComplete 95
    }

    $finalInfo = @(Get-ImageInfo -ImagePath $finalWim)
    if ($finalInfo.Count -gt 0) {
      $script:Run.Image.FinalEditionName = $finalInfo[0].Name
      $script:Run.Image.FinalEditionVersion = $finalInfo[0].Version
      $script:Run.Image.FinalEditionArchitecture = $finalInfo[0].Architecture
      $script:Run.Image.FinalEditionServicePackBuild = $finalInfo[0].ServicePackBuild
    }

    if ($DryRun) {
      Write-Log "[DryRun] Skipping final mounted-image package verification." INFO
      $script:Run.Image.FinalPackageIdentities = @()
    } else {
      $verifyMountDir = Join-Path $script:Paths['Mount'] ("verify-final-" + $timestamp)
      New-Item -ItemType Directory -Force -Path $verifyMountDir | Out-Null
      try {
        Mount-InstallImage -WimPath $finalWim -Index 1 -MountDir $verifyMountDir -ScratchDir $scratch
        Ensure-MountedImageReady -MountDir $verifyMountDir -ScratchDir $scratch
        $finalPackages = @(Get-InstalledPackageIdentities -MountDir $verifyMountDir)
        $script:Run.Image.FinalPackageIdentities = $finalPackages
        $script:Run.Verification = Test-FinalImageVerification -FinalWim $finalWim -MountDir $verifyMountDir -FinalPackages $finalPackages -InjectedPackages @($script:Run.Packages.Injected)
      } finally {
        try { Dismount-InstallImage -MountDir $verifyMountDir -ScratchDir $scratch } catch { Add-Warn "Slutverifiering: kunde inte avmontera verify-final mount: $($_.Exception.Message)" }
      }
    }

    if ($createSwm -and (-not $keepFinalWim) -and (-not $DryRun) -and (Test-Path -LiteralPath $finalWim)) {
      $script:Run.Output.IntermediateWim = $finalWim
      Write-Log "Output mode is SWM only; removing intermediate WIM from final output: $finalWim" INFO
      Remove-Item -LiteralPath $finalWim -Force
    }

    # Hash output
    if ($keepFinalWim) {
      $script:Run.Output.FinalWim = $finalWim
      $script:Run.Output.FinalWimHash = Get-FileHashSafe -Path $finalWim
      $script:Run.Output.FinalWimSizeBytes = if ((-not $DryRun) -and (Test-Path -LiteralPath $finalWim)) { (Get-Item -LiteralPath $finalWim).Length } else { $null }
    } else {
      $script:Run.Output.FinalWim = $null
      $script:Run.Output.FinalWimHash = $null
      $script:Run.Output.FinalWimSizeBytes = $null
    }

    $script:Run.Output.SwmBase = if ($createSwm) { $swmBase } else { $null }
    $script:Run.Output.SwmFiles = @()
    if ($createSwm -and (-not $DryRun)) {
      $swmPattern = ('{0}*.swm' -f [IO.Path]::GetFileNameWithoutExtension($swmBase))
      $swmFiles = Get-ChildItem -LiteralPath (Split-Path -Parent $swmBase) -Filter $swmPattern -File -ErrorAction SilentlyContinue | Sort-Object Name
      $script:Run.Output.SwmFiles = @($swmFiles | ForEach-Object {
        [pscustomobject]@{
          Path = $_.FullName
          SizeBytes = $_.Length
          SHA256 = (Get-FileHashSafe -Path $_.FullName)
        }
      })
    }

    if (-not $DryRun) {
      if ($createSwm) {
        $script:Run.Output.UsbCompatibility = Test-UsbSplitCompatibility -OutputDir $script:Paths['OutputDated'] -SplitSizeMB $size
        if ($script:Run.Output.UsbCompatibility.status -ne 'OK') {
          Add-Warn "USB/SWM compatibility validation reported warnings."
        }
      } else {
        $script:Run.Output.UsbCompatibility = [ordered]@{ status='SKIPPED'; reason='Output mode is WIM only' }
      }

      $sha256SumsPath = Write-Sha256SumsFile -OutputDir $script:Paths['OutputDated']
      $script:Run.Output.Sha256Sums = $sha256SumsPath
      if ($sha256SumsPath) {
        $script:Run.Output.Sha256SumsSizeBytes = (Get-Item -LiteralPath $sha256SumsPath).Length
        $script:Run.Output.Sha256SumsHash = Get-FileHashSafe -Path $sha256SumsPath
      }

      $manifestPath = Join-Path $script:Paths['OutputDated'] 'build-manifest.json'
      $manifest = New-BuildManifestObject -Timestamp $timestamp -OutputDir $script:Paths['OutputDated'] -Sha256SumsPath $sha256SumsPath
      $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
      $script:Run.Output.BuildManifest = $manifestPath
      $script:Run.Output.BuildManifestSizeBytes = (Get-Item -LiteralPath $manifestPath).Length
      $script:Run.Output.BuildManifestHash = Get-FileHashSafe -Path $manifestPath

      # Re-write checksums so the manifest itself is included in SHA256SUMS.txt.
      $sha256SumsPath = Write-Sha256SumsFile -OutputDir $script:Paths['OutputDated']
      $script:Run.Output.Sha256Sums = $sha256SumsPath
      $script:Run.Output.Sha256SumsHash = Get-FileHashSafe -Path $sha256SumsPath
    }

    # Optional metadata
    if ($EmitMetadataJson -or $Config.Output.EmitMetadataJson) {
      $metaPath = Join-Path $script:Paths['Output'] "BuildWIM-$timestamp.metadata.json"
      $obj = [ordered]@{
        version = $script:Run.Version
        verdict = (Get-BuildVerdict -Run $script:Run)
        input = $script:Run.Input
        image = [ordered]@{
          selectedEdition = $script:Run.Image.SelectedEditionName
          sourceVersion = $script:Run.Image.SourceSelectedEditionVersion
          workingVersion = $script:Run.Image.WorkingEditionVersion
          finalVersion = $script:Run.Image.FinalEditionVersion
          proIndex = $script:Run.Image.ProIndex
        }
        packages = [ordered]@{
          found = @($script:Run.Packages.Found | ForEach-Object { [ordered]@{ file=$_.FileName; classification=$_.Classification; path=$_.Path } })
          injected = @($script:Run.Packages.Injected | ForEach-Object { [ordered]@{ file=$_.FileName; classification=$_.Classification; path=$_.Path } })
          skipped = @($script:Run.Packages.Skipped | ForEach-Object { [ordered]@{ file=$_.FileName; classification=$_.Classification; path=$_.Path; reason=$_.Reason } })
        }
        outputs = [ordered]@{
          mode = $script:Run.Output.Mode
          wim = [ordered]@{ path = $script:Run.Output.FinalWim; sha256 = $script:Run.Output.FinalWimHash; sizeBytes = $script:Run.Output.FinalWimSizeBytes }
          intermediateWim = $script:Run.Output.IntermediateWim
          swm = @($script:Run.Output.SwmFiles)
          buildManifest = $script:Run.Output.BuildManifest
          sha256Sums = $script:Run.Output.Sha256Sums
          usbCompatibility = $script:Run.Output.UsbCompatibility
        }
        verification = $script:Run.Verification
        warnings = @($script:Run.Warnings.ToArray())
        errors = @($script:Run.Errors.ToArray())
        steps = @($script:Run.Steps.ToArray())
      }
      if (-not $DryRun) { $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metaPath -Encoding UTF8 }
      $script:Run.Output.MetadataJson = $metaPath
      if (-not $DryRun -and (Test-Path -LiteralPath $metaPath)) {
        $script:Run.Output.MetadataJsonSizeBytes = (Get-Item -LiteralPath $metaPath).Length
        $script:Run.Output.MetadataJsonHash = Get-FileHashSafe -Path $metaPath
      }
    }

    $script:Run.EndTime = Get-Date
    $script:Run.Duration = ($script:Run.EndTime - $script:Run.StartTime)
    $nextPatchTuesday = Get-NextPatchTuesday -From (Get-Date)
    $script:Run.Summary.NextPatchTuesday = $nextPatchTuesday
    $script:Run.Summary.DaysUntilPatchTuesday = [Math]::Ceiling(($nextPatchTuesday - (Get-Date)).TotalDays)
    Update-EtaProgress -CurrentStep 'Finalizing report and hashes' -PercentComplete 100

    Show-Progress -Activity "BuildWIM Pipeline" -Status "Finalizing report and hashes" -Percent 100

    Complete-InlineProgress

    New-HtmlReport -Run $script:Run -ReportPath $reportPath

    # Markdown report
    $mdReportPath = [IO.Path]::ChangeExtension($reportPath, '.md')
    New-MarkdownReport -Run $script:Run -ReportPath $mdReportPath

    # Diff report
    $diffReportPath = Join-Path $script:Paths['Reports'] "BuildWIM-$timestamp.diff.md"
    New-DiffReport -Run $script:Run -ReportPath $diffReportPath

    # Save history (with package names for future diffs)
    Save-EtaHistory -Config $Config

    Write-Log ("BuildWIM completed in {0}. Report: {1}" -f (Format-DurationHuman $script:Run.Duration.TotalSeconds), $reportPath) INFO

    # ============================================
    # BUILD SUMMARY (color-coded by verdict)
    # ============================================
    $verdict = Get-BuildVerdict -Run $script:Run
    $verdictColor = switch ($verdict) {
      'SUCCESS' { 'Green' }
      'SUCCESS WITH WARNINGS' { 'Yellow' }
      'FAILED' { 'Red' }
      default { 'White' }
    }
    $verdictEmoji = switch ($verdict) {
      'SUCCESS' { '   ' }
      'SUCCESS WITH WARNINGS' { '      ' }
      'FAILED' { '   ' }
      default { '   ' }
    }

    Write-Host ""
    Write-Host "  +--------------------------------------------------+" -ForegroundColor $verdictColor
    Write-Host "  -              BUILD SUMMARY                      -" -ForegroundColor $verdictColor
    Write-Host "  +--------------------------------------------------|" -ForegroundColor $verdictColor
    Write-Host ("  -  $verdictEmoji {0,-47}-" -f $verdict) -ForegroundColor $verdictColor
    Write-Host "  +--------------------------------------------------|" -ForegroundColor $verdictColor
    Write-Host ("  -  Edition:    {0,-37}-" -f "$($script:Run.Image.FinalEditionName)") -ForegroundColor Cyan
    Write-Host ("  -  Version:    {0,-37}-" -f "$($script:Run.Image.FinalEditionVersion)") -ForegroundColor Cyan
    Write-Host ("  -  Arch:       {0,-37}-" -f "$($script:Run.Image.FinalEditionArchitecture)") -ForegroundColor Cyan
    Write-Host ("  -  Duration:   {0,-37}-" -f "$([math]::Round($script:Run.Duration.TotalMinutes, 1)) minutes") -ForegroundColor Cyan
    Write-Host "  +--------------------------------------------------|" -ForegroundColor $verdictColor

    if ($script:Run.Packages.Injected.Count -gt 0) {
        Write-Host ("  -  Injected KBs: {0,-35}-" -f "$($script:Run.Packages.Injected.Count) package(s)") -ForegroundColor Yellow
        foreach ($kb in $script:Run.Packages.Injected) {
            $kbLine = "    - $($kb.FileName) [$($kb.Classification)]"
            Write-Host ("  -  {0,-48}-" -f $kbLine.Substring(0, [math]::Min($kbLine.Length, 48))) -ForegroundColor White
        }
    } else {
        Write-Host ("  -  Injected KBs: {0,-35}-" -f "None") -ForegroundColor DarkGray
    }

    Write-Host "  +--------------------------------------------------|" -ForegroundColor $verdictColor
    Write-Host ("  -  Output: {0,-41}-" -f $script:Run.Output.Mode) -ForegroundColor White
    if ($script:Run.Output.FinalWim) {
      Write-Host ("  -  WIM: {0,-44}-" -f ([IO.Path]::GetFileName($script:Run.Output.FinalWim))) -ForegroundColor White
      Write-Host ("  -  WIM Size: {0,-39}-" -f (Format-Size $script:Run.Output.FinalWimSizeBytes)) -ForegroundColor White
    }
    if ($script:Run.Output.SwmFiles.Count -gt 0) {
      Write-Host ("  -  SWM files: {0,-38}-" -f ("$($script:Run.Output.SwmFiles.Count) file(s)")) -ForegroundColor White
    }
    Write-Host "  +--------------------------------------------------|" -ForegroundColor $verdictColor
    Write-Host ("  -  HTML:     {0,-39}-" -f ([IO.Path]::GetFileName($reportPath))) -ForegroundColor DarkCyan
    Write-Host ("  -  Markdown: {0,-39}-" -f ([IO.Path]::GetFileName($mdReportPath))) -ForegroundColor DarkCyan
    Write-Host ("  -  Diff:     {0,-39}-" -f ([IO.Path]::GetFileName($diffReportPath))) -ForegroundColor DarkCyan

    if ($script:Run.Warnings.Count -gt 0) {
      Write-Host "  +--------------------------------------------------|" -ForegroundColor Yellow
      Write-Host ("  -          Warnings: {0,-34}-" -f "$($script:Run.Warnings.Count)") -ForegroundColor Yellow
    }

    Write-Host "  |--------------------------------------------------+" -ForegroundColor $verdictColor

    # Clean up Temp folder after successful build
    Write-Host ""
    Write-Host "  Cleaning up Temp folder..." -ForegroundColor DarkGray
    $tempFiles = Get-ChildItem -LiteralPath $script:Paths['Temp'] -File -ErrorAction SilentlyContinue
    $cleanedCount = 0
    foreach ($file in $tempFiles) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $cleanedCount++
        } catch { }
    }
    Write-Host "  Cleaned $cleanedCount temporary files" -ForegroundColor DarkGray

    # Toast notification
    if ($NotifyOnComplete) {
      Send-BuildNotification -Run $script:Run
    }

    Write-Host ""

  } finally {
    try { Dismount-IsoIfNeeded } catch { }
    if (-not $DryRun) { try { Stop-Transcript | Out-Null } catch { } }
  }
}

# Load config
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Config not found: $ConfigPath"
}

$cfgRaw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
$cfg = $cfgRaw | ConvertFrom-Json

Initialize-BuildFolders -Root $Root
Test-Prerequisites -Config $cfg
Test-FreeDiskSpace -Path $Root -MinGB $cfg.Safety.MinFreeSpaceGB
Invoke-PreflightCleanup

if ($CheckLatestLCU) {
  $downloader = Join-Path $PSScriptRoot 'Get-LatestWindows11LCU.ps1'
  if (-not (Test-Path -LiteralPath $downloader)) { throw "Downloader script missing: $downloader" }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $downloader -WindowsVersion $UpdateWindowsVersion -Architecture $UpdateArchitecture -OutputPath $script:Paths['Updates'] -MetadataOnly
  exit $LASTEXITCODE
}

Start-BuildProcess -Config $cfg
