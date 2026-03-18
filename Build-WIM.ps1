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
    9) Offline cleanup
   10) Commit + export final WIM
   11) Split WIM into SWM for FAT32
   12) Generate HTML report + hashes

.NOTES
  Version: 1.0.0
  Author: BuildWIM
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Root = 'C:\BuildWIM',
  [string]$ConfigPath = 'C:\BuildWIM\Config\buildwim.config.json',
  [int]$SplitSizeMB,
  [switch]$DryRun,
  [switch]$EmitMetadataJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------
# Logging
# ----------------------------
$script:Run = [ordered]@{
  Version = '1.0.0'
  StartTime = (Get-Date)
  EndTime = $null
  Duration = $null
  Warnings = New-Object System.Collections.Generic.List[string]
  Errors = New-Object System.Collections.Generic.List[string]
  DismCommands = New-Object System.Collections.Generic.List[string]
  Input = [ordered]@{}
  Image = [ordered]@{ ExistingPackages = @(); EnabledFeatures = @() }
  Packages = [ordered]@{
    Found = @()
    Sorted = @()
    Injected = @()
    Skipped = @()
  }
  Output = [ordered]@{}
}

$script:Paths = [ordered]@{}
$script:IsoMount = [ordered]@{ Mounted = $false; DriveLetter = $null; ImagePath = $null }

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

function Show-Progress {
  param(
    [string]$Activity,
    [string]$Status,
    [int]$Percent
  )

  if ($Percent -lt 0) { $Percent = 0 }
  if ($Percent -gt 100) { $Percent = 100 }

  Write-Progress -Activity $Activity -Status $Status -PercentComplete $Percent
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
  $folders = @('Input','Updates','Mount','Output','Logs','Temp','Tools','Config','Reports')
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

  # ADK detection (per requirement). We don't hard-fail if DISM exists,
  # but we do report exactly what is missing.
  $adkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
  $adkDeploymentTools = Join-Path $adkRoot 'Deployment Tools'
  if (-not (Test-Path -LiteralPath $adkDeploymentTools)) {
    Add-Warn "Windows ADK Deployment Tools not detected at: $adkDeploymentTools. DISM from Windows will be used. (Install ADK if your process requires it.)"
  } else {
    Write-Log "ADK detected: $adkDeploymentTools" INFO
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
function Get-InputSourceType {
  param([string]$InputFolder)

  $candidates = Get-ChildItem -LiteralPath $InputFolder -File -ErrorAction Stop
  if (-not $candidates) { throw "No input files found in $InputFolder" }

  $iso = $candidates | Where-Object { $_.Extension -ieq '.iso' } | Select-Object -First 1
  if ($iso) { return [pscustomobject]@{ Type='ISO'; Path=$iso.FullName } }

  $wim = $candidates | Where-Object { $_.Name -ieq 'install.wim' -or $_.Extension -ieq '.wim' } | Select-Object -First 1
  if ($wim) { return [pscustomobject]@{ Type='WIM'; Path=$wim.FullName } }

  $esd = $candidates | Where-Object { $_.Name -ieq 'install.esd' -or $_.Extension -ieq '.esd' } | Select-Object -First 1
  if ($esd) { return [pscustomobject]@{ Type='ESD'; Path=$esd.FullName } }

  throw "Unsupported input type. Put an ISO/WIM/ESD in $InputFolder"
}

function Mount-IsoIfNeeded {
  param(
    [Parameter(Mandatory)] [string]$IsoPath,
    [string[]]$SearchRelativePaths
  )

  if ($DryRun) {
    Write-Log "[DryRun] Would mount ISO: $IsoPath" INFO
    return $null
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
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($stdout) { Add-Content -LiteralPath $script:LogFile -Value $stdout }
  if ($stderr) { Add-Content -LiteralPath $script:LogFile -Value $stderr }

  if (($p.ExitCode -ne 0) -and (-not $AllowNonZero)) {
    throw "DISM failed (exit $($p.ExitCode)). Command: $cmd"
  }

  return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

# ----------------------------
# Image processing
# ----------------------------
function Get-ImageInfo {
  param([Parameter(Mandatory)] [string]$ImagePath)

  $r = Invoke-Dism -Arguments @('/English','/Get-WimInfo',"/WimFile:$ImagePath")

  # Parse indices and names from DISM output (robust-ish for English output)
  $lines = ($r.StdOut -split "`r?`n")
  $items = @()
  $current = $null

  foreach ($ln in $lines) {
    if ($ln -match '^Index\s*:\s*(\d+)') {
      if ($current) { $items += [pscustomobject]$current }
      $current = [ordered]@{ Index = [int]$matches[1]; Name=''; Description=''; Architecture=''; Version=''; } 
    }
    elseif ($current -and $ln -match '^Name\s*:\s*(.+)$') { $current.Name = $matches[1].Trim() }
    elseif ($current -and $ln -match '^Description\s*:\s*(.+)$') { $current.Description = $matches[1].Trim() }
    elseif ($current -and $ln -match '^Architecture\s*:\s*(.+)$') { $current.Architecture = $matches[1].Trim() }
    elseif ($current -and $ln -match '^Version\s*:\s*(.+)$') { $current.Version = $matches[1].Trim() }
  }
  if ($current) { $items += [pscustomobject]$current }

  if (-not $items) {
    throw "Failed to parse WIM info from DISM output for: $ImagePath"
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
    if (-not $DryRun) { Remove-Item -LiteralPath $DestWim -Force }
  }

  Write-Log "Exporting Pro-only WIM (Index $ProIndex): $SourceWim -> $DestWim" INFO
  Invoke-Dism -Arguments @('/English','/Export-Image',"/SourceImageFile:$SourceWim","/SourceIndex:$ProIndex","/DestinationImageFile:$DestWim",'/Compress:Max','/CheckIntegrity') | Out-Null

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

  # Heuristics – robust enough for production-ish.
  # MSU extraction is intentionally NOT used; classification is best-effort from file name.
  $type = 'Other'
  $details = ''

  if ($name -match '(?i)ssu') { $type = 'SSU' }
  elseif ($name -match '(?i)lcu|cumulative') { $type = 'LCU' }
  elseif ($name -match '(?i)ndp|dotnet|\.net') { $type = 'DotNetCU' }

  return [pscustomobject]@{ Path=$Path; FileName=$name; Classification=$type; Details=$details }
}

function Sort-PackagesByServicingOrder {
  param([Parameter(Mandatory=$false)] [object[]]$Packages)

  if (-not $Packages -or $Packages.Count -eq 0) { return @() }
  $order = @('SSU','LCU','DotNetCU','Other')
  $sorted = $Packages | Sort-Object @{ Expression = { $order.IndexOf($_.Classification) } }, @{ Expression = { $_.FileName } }
  return ,$sorted
}

function Add-OfflinePackages {
  param(
    [Parameter(Mandatory)] [string]$MountDir,
    [Parameter(Mandatory)] [object[]]$SortedPackages,
    [string]$ScratchDir
  )

  # Detailed progress: show per-package injection progress
  $total = $SortedPackages.Count
  for ($i = 0; $i -lt $total; $i++) {
    $pkg = $SortedPackages[$i]
    # Calculate overall percent (30-55% range)
    $percent = 30 + [int](($i / $total) * 25)
    Write-Progress -Id 1 -Activity "BuildWIM Pipeline" -Status ("Injecting packages ({0}/{1}): {2}" -f ($i+1), $total, $pkg.FileName) -PercentComplete $percent

    Write-Log "Adding package [$($pkg.Classification)]: $($pkg.FileName)" INFO

    $args = @('/English',"/Image:$MountDir",'/Add-Package',"/PackagePath:$($pkg.Path)")
    if ($ScratchDir) { $args += "/ScratchDir:$ScratchDir" }

    try {
      Invoke-Dism -Arguments $args | Out-Null
      $script:Run.Packages.Injected += $pkg
    } catch {
      Add-Warn "Failed to inject package: $($pkg.FileName). Error: $($_.Exception.Message)"
      $script:Run.Packages.Skipped += $pkg
      throw
    }
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
function New-HtmlReport {
  param(
    [Parameter(Mandatory)] [hashtable]$Run,
    [Parameter(Mandatory)] [string]$ReportPath
  )

  $enc = [System.Web.HttpUtility]
  $start = $Run.StartTime
  $end = $Run.EndTime
  $dur = $Run.Duration

  $pkgRows = ($Run.Packages.Sorted | ForEach-Object {
    "<tr><td>$($enc::HtmlEncode($_.FileName))</td><td>$($enc::HtmlEncode($_.Classification))</td><td>$($enc::HtmlEncode($_.Path))</td></tr>"
  }) -join "`n"

  $injRows = ($Run.Packages.Injected | ForEach-Object {
    "<tr><td>$($enc::HtmlEncode($_.FileName))</td><td>$($enc::HtmlEncode($_.Classification))</td></tr>"
  }) -join "`n"

  $existingPkgRows = ($Run.Image.ExistingPackages | ForEach-Object {
    "<tr><td>$($enc::HtmlEncode($_))</td></tr>"
  }) -join "`n"

  $enabledFeatRows = ($Run.Image.EnabledFeatures | ForEach-Object {
    "<tr><td>$($enc::HtmlEncode($_))</td></tr>"
  }) -join "`n"

  $warnRows = ($Run.Warnings | ForEach-Object { "<li>$($enc::HtmlEncode($_))</li>" }) -join "`n"
  $errRows  = ($Run.Errors   | ForEach-Object { "<li>$($enc::HtmlEncode($_))</li>" }) -join "`n"

  $dismRows = ($Run.DismCommands | ForEach-Object { "<li><code>$($enc::HtmlEncode($_))</code></li>" }) -join "`n"

  $html = @"
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>BuildWIM Report</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; }
    h1,h2 { margin-bottom: 6px; }
    .meta { background: #f5f5f5; padding: 10px; border-radius: 6px; }
    table { border-collapse: collapse; width: 100%; margin-top: 10px; }
    th, td { border: 1px solid #ddd; padding: 8px; font-size: 13px; }
    th { background: #222; color: #fff; text-align: left; }
    .ok { color: #0a7; }
    .warn { color: #b80; }
    .err { color: #c00; }
    code { background: #eee; padding: 2px 4px; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>BuildWIM – Report</h1>
  <div class="meta">
    <div><b>Version:</b> $($Run.Version)</div>
    <div><b>Start:</b> $start</div>
    <div><b>End:</b> $end</div>
    <div><b>Duration:</b> $dur</div>
    <div><b>Input:</b> $($Run.Input.Path) ($($Run.Input.Type))</div>
    <div><b>Pro index:</b> $($Run.Image.ProIndex)</div>
    <div><b>Working WIM:</b> $($Run.Image.WorkingWim)</div>
    <div><b>Output WIM:</b> $($Run.Output.FinalWim)</div>
    <div><b>Output WIM SHA256:</b> $($Run.Output.FinalWimHash)</div>
    <div><b>Output SWM base:</b> $($Run.Output.SwmBase)</div>
  </div>

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
  <ul class="warn">
    $warnRows
  </ul>

  <h2>Errors</h2>
  <ul class="err">
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
function Start-BuildProcess {
  param([pscustomobject]$Config)

  $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $script:LogFile = Join-Path $script:Paths['Logs'] "BuildWIM-$timestamp.log"
  $transcript = Join-Path $script:Paths['Logs'] "BuildWIM-$timestamp.transcript.txt"
  $reportPath = Join-Path $script:Paths['Reports'] "BuildWIM-$timestamp.html"

  if (-not $DryRun) {
    Start-Transcript -LiteralPath $transcript -Force | Out-Null
  }

  try {
    Write-Log "BuildWIM v$($script:Run.Version) starting" INFO
    Test-FreeDiskSpace -Path $Root -MinGB $Config.Safety.MinFreeSpaceGB

    if ($Config.Safety.ForceCleanupWim) { Clear-StaleMounts }

    $input = Get-InputSourceType -InputFolder $script:Paths['Input']
    $script:Run.Input.Type = $input.Type
    $script:Run.Input.Path = $input.Path

    # Hash input
    $script:Run.Input.SHA256 = Get-FileHashSafe -Path $input.Path

    $workingInputPath = $null

    if ($input.Type -eq 'ISO') {
      $found = Mount-IsoIfNeeded -IsoPath $input.Path -SearchRelativePaths $Config.Input.IsoSearchRelativePaths
      $dest = Join-Path $script:Paths['Temp'] (Split-Path -Leaf $found)
      Write-Log "Copying image from ISO: $found -> $dest" INFO
      if (-not $DryRun) { Copy-Item -LiteralPath $found -Destination $dest -Force }
      $workingInputPath = $dest
      Dismount-IsoIfNeeded
    } else {
      $workingInputPath = $input.Path
    }

    # If ESD -> convert to temp WIM
    if ([IO.Path]::GetExtension($workingInputPath) -ieq '.esd') {
      $tempWim = Join-Path $script:Paths['Temp'] 'install-from-esd.wim'
      Convert-EsdToWim -EsdPath $workingInputPath -WimOutPath $tempWim | Out-Null
      $workingInputPath = $tempWim
    }

    # Get image info and pro index
    $info = Get-ImageInfo -ImagePath $workingInputPath
    $script:Run.Image.AllEditions = $info
    $proIndex = Get-Windows11ProIndex -ImageInfo $info -EditionNameMatch $Config.Servicing.EditionNameMatch
    $script:Run.Image.ProIndex = $proIndex

    # Export Pro-only working WIM BEFORE patching
    $workingWim = Join-Path $script:Paths['Temp'] 'install-pro-only-working.wim'
    Export-ProEditionOnly -SourceWim $workingInputPath -ProIndex $proIndex -DestWim $workingWim | Out-Null
    $script:Run.Image.WorkingWim = $workingWim

    # Safety: verify working wim has only one index
    $workingInfo = @(Get-ImageInfo -ImagePath $workingWim)
    if ($workingInfo.Length -ne 1) {
      throw "Working WIM is expected to have exactly 1 index, found $($workingInfo.Length). Aborting."
    }

    # Discover updates
    $updatesFolder = $script:Paths['Updates']
    $allowed = $Config.Updates.AllowedExtensions
    $updateFiles = Get-ChildItem -LiteralPath $updatesFolder -File -ErrorAction SilentlyContinue | Where-Object { $allowed -contains $_.Extension.ToLowerInvariant() }

    $pkgs = @()

    foreach ($u in ($updateFiles | Sort-Object FullName)) {
      # MSU extraction is intentionally not used. DISM can service MSU directly offline.
      $pkgs += (Get-PackageClassification -Path $u.FullName)
    }

    $script:Run.Packages.Found = $pkgs

    # Sort
    $sorted = @(Sort-PackagesByServicingOrder -Packages $pkgs)
    $script:Run.Packages.Sorted = $sorted

    if ($sorted.Length -eq 0) {
      Add-Warn "No updates found in $updatesFolder. Continuing with Pro-only export and outputs." 
    } else {
      Write-Log "Package servicing order:" INFO
      foreach ($p in $sorted) { Write-Log ("  - [{0}] {1}" -f $p.Classification, $p.FileName) INFO }
    }

    Show-Progress -Activity "BuildWIM Pipeline" -Status "Mounting working WIM" -Percent 30

    # Mount
    # Cleanup any existing mount at $mountDir
    if (Test-Path $mountDir) {
      try {
        Dismount-InstallImage -MountDir $mountDir -ScratchDir $scratch
      } catch {
        Write-Log "Warning: Failed to dismount existing image at ${mountDir}: $($_.Exception.Message)" WARN
      }
    }
    $mountDir = $script:Paths['Mount']
    $scratch = $script:Paths['Scratch']

    # Ensure mount dir empty
    if (-not $DryRun) {
      Get-ChildItem -LiteralPath $mountDir -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }

    Mount-InstallImage -WimPath $workingWim -MountDir $mountDir -Index 1 -ScratchDir $scratch

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

      if ($sorted.Length -gt 0) {
        Show-Progress -Activity "BuildWIM Pipeline" -Status "Injecting update packages" -Percent 55
        Add-OfflinePackages -MountDir $mountDir -SortedPackages $sorted -ScratchDir $scratch
      }

      Show-Progress -Activity "BuildWIM Pipeline" -Status "Running image cleanup" -Percent 65
      Invoke-ImageCleanup -MountDir $mountDir -Config $Config -ScratchDir $scratch

      Dismount-InstallImage -MountDir $mountDir -Commit -ScratchDir $scratch
    } catch { 
      Add-Err $_.Exception.Message
      try { Dismount-InstallImage -MountDir $mountDir -ScratchDir $scratch } catch { }
      throw
    }

    Show-Progress -Activity "BuildWIM Pipeline" -Status "Exporting final WIM" -Percent 80

    # Export final WIM to Output
    $finalWim = Join-Path $script:Paths['Output'] $Config.Output.InstallWimName
    Export-FinalWim -SourceWim $workingWim -DestWim $finalWim

    Show-Progress -Activity "BuildWIM Pipeline" -Status "Splitting WIM for FAT32 media" -Percent 90

    # Split
    $size = if ($PSBoundParameters.ContainsKey('SplitSizeMB') -and $SplitSizeMB) { $SplitSizeMB } else { [int]$Config.Output.SplitSizeMB }
    $swmBase = Join-Path $script:Paths['Output'] $Config.Output.SplitBaseName
    Split-WimForFat32 -WimPath $finalWim -SwmBasePath $swmBase -SizeMB $size

    # Hash output
    $script:Run.Output.FinalWim = $finalWim
    $script:Run.Output.FinalWimHash = Get-FileHashSafe -Path $finalWim
    $script:Run.Output.SwmBase = $swmBase

    # Optional metadata
    if ($EmitMetadataJson -or $Config.Output.EmitMetadataJson) {
      $metaPath = Join-Path $script:Paths['Output'] "BuildWIM-$timestamp.metadata.json"
      $obj = [ordered]@{
        version = $script:Run.Version
        input = $script:Run.Input
        proIndex = $script:Run.Image.ProIndex
        injected = @($script:Run.Packages.Injected | ForEach-Object { [ordered]@{ file=$_.FileName; classification=$_.Classification; path=$_.Path } })
        outputWim = $finalWim
        outputWimSha256 = $script:Run.Output.FinalWimHash
      }
      if (-not $DryRun) { $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metaPath -Encoding UTF8 }
      $script:Run.Output.MetadataJson = $metaPath
    }

    $script:Run.EndTime = Get-Date
    $script:Run.Duration = ($script:Run.EndTime - $script:Run.StartTime)

    Show-Progress -Activity "BuildWIM Pipeline" -Status "Finalizing report and hashes" -Percent 100

    New-HtmlReport -Run $script:Run -ReportPath $reportPath

    Write-Log "BuildWIM completed. Report: $reportPath" INFO

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

Start-BuildProcess -Config $cfg
