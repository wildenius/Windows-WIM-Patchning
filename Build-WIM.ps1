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
  Version: 1.1.0
  Author: BuildWIM
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Root = 'C:\BuildWIM',
  [string]$ConfigPath = 'C:\BuildWIM\Config\buildwim.config.json',
  [int]$SplitSizeMB,
  [switch]$DryRun,
  [switch]$EmitMetadataJson,
  [switch]$NotifyOnComplete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------
# Logging
# ----------------------------
$script:Run = [ordered]@{
  Version = '1.1.0'
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
  Steps = New-Object System.Collections.Generic.List[object]
  Summary = [ordered]@{}
  ETA = [ordered]@{
    HistoryPath = $null
    History = @()
    Current = [ordered]@{}
  }
  Output = [ordered]@{}
}

$script:Paths = [ordered]@{}
$script:IsoMount = [ordered]@{ Mounted = $false; DriveLetter = $null; ImagePath = $null }

function Show-Banner {
  param(
    [string]$InputType = '?',
    [string]$InputFile = '?'
  )

  $date = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  $ver = $script:Run.Version

  Write-Host ""
  Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
  Write-Host "  ║                                                  ║" -ForegroundColor Cyan
  Write-Host "  ║       ██████╗ ██╗   ██╗██╗██╗     ██████╗        ║" -ForegroundColor Cyan
  Write-Host "  ║       ██╔══██╗██║   ██║██║██║     ██╔══██╗       ║" -ForegroundColor Cyan
  Write-Host "  ║       ██████╔╝██║   ██║██║██║     ██║  ██║       ║" -ForegroundColor Cyan
  Write-Host "  ║       ██╔══██╗██║   ██║██║██║     ██║  ██║       ║" -ForegroundColor Cyan
  Write-Host "  ║       ██████╔╝╚██████╔╝██║██████╗ ██████╔╝       ║" -ForegroundColor Cyan
  Write-Host "  ║       ╚═════╝  ╚═════╝ ╚═╝╚═════╝╚═════╝        ║" -ForegroundColor Cyan
  Write-Host "  ║                 W I M                            ║" -ForegroundColor Cyan
  Write-Host "  ║                                                  ║" -ForegroundColor Cyan
  Write-Host "  ╠══════════════════════════════════════════════════╣" -ForegroundColor DarkCyan
  Write-Host ("  ║  Version:  {0,-39}║" -f $ver) -ForegroundColor DarkCyan
  Write-Host ("  ║  Date:     {0,-39}║" -f $date) -ForegroundColor DarkCyan
  Write-Host ("  ║  Input:    {0,-39}║" -f "$InputType ($InputFile)".Substring(0, [math]::Min("$InputType ($InputFile)".Length, 39))) -ForegroundColor DarkCyan
  Write-Host ("  ║  Mode:     {0,-39}║" -f $(if ($DryRun) { 'DRY RUN' } else { 'PRODUCTION' })) -ForegroundColor DarkCyan
  Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
  Write-Host ""
}

function Show-InlineProgress {
  param(
    [string]$Step,
    [int]$Percent,
    [string]$ETA = ''
  )

  if ($Percent -lt 0) { $Percent = 0 }
  if ($Percent -gt 100) { $Percent = 100 }

  $barWidth = 30
  $filled = [math]::Round($barWidth * $Percent / 100)
  $empty = $barWidth - $filled
  $bar = ('█' * $filled) + ('░' * $empty)

  $etaStr = if ($ETA) { " | ETA $ETA" } else { '' }
  $line = "`r  [{0}] {1,3}% {2}{3}" -f $bar, $Percent, $Step, $etaStr

  Write-Host $line -NoNewline -ForegroundColor $(
    if ($Percent -ge 90) { 'Green' }
    elseif ($Percent -ge 50) { 'Yellow' }
    else { 'Cyan' }
  )
}

function Complete-InlineProgress {
  Write-Host ""
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

function Show-Progress {
  param(
    [string]$Activity,
    [string]$Status,
    [int]$Percent
  )

  if ($Percent -lt 0) { $Percent = 0 }
  if ($Percent -gt 100) { $Percent = 100 }

  $etaSuffix = ''
  $etaShort = ''
  if ($script:Run -and $script:Run.ETA -and $script:Run.ETA.Current -and $script:Run.ETA.Current.Contains('RemainingSeconds')) {
    $etaSuffix = " | ETA ~$(Format-DurationHuman $script:Run.ETA.Current.RemainingSeconds)"
    $etaShort = "~$(Format-DurationHuman $script:Run.ETA.Current.RemainingSeconds)"
  }

  Write-Progress -Activity $Activity -Status ($Status + $etaSuffix) -PercentComplete $Percent
  Show-InlineProgress -Step $Status -Percent $Percent -ETA $etaShort
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
    Write-Log ("ETA [{0}] elapsed={1} remaining~={2} finish~={3}" -f $CurrentStep, (Format-DurationHuman $elapsed), (Format-DurationHuman $remaining), $script:Run.ETA.Current.FinishAt.ToString('HH:mm:ss')) INFO
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
  Write-Log -Message 'Rensar gamla mount-punkter (pre-flight cleanup)' -Level 'INFO'
  try {
    & dism.exe /English /Cleanup-Wim 2>&1 | Out-Null
  } catch {
    Write-Log -Message "Fel vid pre-flight dism /Cleanup-Wim: $_" -Level 'WARN'
  }

  try {
    $dismInfo = & dism.exe /English /Get-MountedWimInfo 2>&1
    if ($dismInfo) {
      $mountMatches = $dismInfo | Select-String 'Mount Dir'
      foreach ($m in $mountMatches) {
        $parts = $m.Line.Split(':',2)
        if ($parts.Count -lt 2) { continue }
        $mount = $parts[1].Trim()
        if (-not $mount) { continue }
        Write-Log -Message "Avmonterar gamla mount: $mount" -Level 'INFO'
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
      $reason = $_.Exception.Message
      Add-Warn "Failed to inject package: $($pkg.FileName). Error: $reason"
      $script:Run.Packages.Skipped += [pscustomobject]@{
        FileName = $pkg.FileName
        Classification = $pkg.Classification
        Path = $pkg.Path
        Reason = $reason
      }
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
    [pscustomobject]@{ Label = 'Output WIM'; Value = $Run.Output.FinalWim },
    [pscustomobject]@{ Label = 'Output SWM base'; Value = $Run.Output.SwmBase }
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
  <h1>BuildWIM – Report</h1>
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
    'SUCCESS' { '✅' }
    'SUCCESS WITH WARNINGS' { '⚠️' }
    'FAILED' { '❌' }
    default { '❓' }
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
      [void]$sb.AppendLine("- ``$($pkg.FileName)`` — $($pkg.Reason)")
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
    foreach ($kb in $currentKBs) { [void]$sb.AppendLine("- 🆕 ``$kb``") }
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
      [void]$sb.AppendLine("### ➕ New KBs")
      foreach ($kb in $newKBs) { [void]$sb.AppendLine("- ``$kb``") }
      [void]$sb.AppendLine("")
    }

    if ($removedKBs.Count -gt 0) {
      [void]$sb.AppendLine("### ➖ Removed KBs")
      foreach ($kb in $removedKBs) { [void]$sb.AppendLine("- ``$kb``") }
      [void]$sb.AppendLine("")
    }

    if ($unchangedKBs.Count -gt 0) {
      [void]$sb.AppendLine("### ✅ Unchanged KBs")
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
    Write-Host "  📋 Diff: First build (no previous build to compare)" -ForegroundColor DarkCyan
  } else {
    $diffColor = if ($newKBs.Count -gt 0 -or $removedKBs.Count -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ("  📋 Diff: +{0} new / -{1} removed / {2} unchanged KBs" -f $newKBs.Count, $removedKBs.Count, $unchangedKBs.Count) -ForegroundColor $diffColor
  }
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
    
    # Detect input early for banner
    $bannerInput = Get-InputSourceType -InputFolder $script:Paths['Input']
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
    
    Test-FreeDiskSpace -Path $Root -MinGB $Config.Safety.MinFreeSpaceGB

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
    }
    Add-StepResult -Name 'Inspect source image' -StartTime $stepStart -EndTime (Get-Date) -Details ("Selected index {0}: {1}" -f $proIndex, $script:Run.Image.SelectedEditionName)
    Update-EtaProgress -CurrentStep 'Inspect source image' -PercentComplete 22

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

    $script:Run.Packages.Found = $pkgs

    # Sort
    $sorted = @(Sort-PackagesByServicingOrder -Packages $pkgs)
    $script:Run.Packages.Sorted = $sorted
    Add-StepResult -Name 'Discover update packages' -StartTime $stepStart -EndTime (Get-Date) -Details ("Found {0} package(s)" -f $sorted.Length)
    Update-EtaProgress -CurrentStep 'Discover update packages' -PercentComplete 35

    if ($sorted.Length -eq 0) {
      Add-Warn "No updates found in $updatesFolder. Continuing with Pro-only export and outputs." 
    } else {
      Write-Log "Package servicing order:" INFO
      foreach ($p in $sorted) { Write-Log ("  - [{0}] {1}" -f $p.Classification, $p.FileName) INFO }
    }

    Show-Progress -Activity "BuildWIM Pipeline" -Status "Mounting working WIM" -Percent 30

    # Mount
    $mountDir = $script:Paths['Mount']
    $scratch = $script:Paths['Scratch']

    # Cleanup any existing mount at $mountDir
    if (Test-Path -LiteralPath $mountDir) {
      try {
        Dismount-InstallImage -MountDir $mountDir -ScratchDir $scratch
      } catch {
        Write-Log "Warning: Failed to dismount existing image at ${mountDir}: $($_.Exception.Message)" WARN
      }
    }

    # Ensure mount dir empty
    if (-not $DryRun) {
      Get-ChildItem -LiteralPath $mountDir -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }

    $stepStart = Get-Date
    Mount-InstallImage -WimPath $workingWim -MountDir $mountDir -Index 1 -ScratchDir $scratch
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

      if ($sorted.Length -gt 0) {
        $stepStart = Get-Date
        Show-Progress -Activity "BuildWIM Pipeline" -Status "Injecting update packages" -Percent 55
        Add-OfflinePackages -MountDir $mountDir -SortedPackages $sorted -ScratchDir $scratch
        Add-StepResult -Name 'Inject update packages' -StartTime $stepStart -EndTime (Get-Date) -Details ("Injected {0} package(s)" -f $script:Run.Packages.Injected.Count)
        Update-EtaProgress -CurrentStep 'Inject update packages' -PercentComplete 60
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

    Show-Progress -Activity "BuildWIM Pipeline" -Status "Exporting final WIM" -Percent 80

    # Export final WIM to Output
    $stepStart = Get-Date
    $finalWim = Join-Path $script:Paths['OutputDated'] $Config.Output.InstallWimName
    Export-FinalWim -SourceWim $workingWim -DestWim $finalWim
    Add-StepResult -Name 'Export final WIM' -StartTime $stepStart -EndTime (Get-Date) -Details $finalWim
    Update-EtaProgress -CurrentStep 'Export final WIM' -PercentComplete 88

    Show-Progress -Activity "BuildWIM Pipeline" -Status "Splitting WIM for FAT32 media" -Percent 90

    # Split
    $stepStart = Get-Date
    $size = if ($PSBoundParameters.ContainsKey('SplitSizeMB') -and $SplitSizeMB) { $SplitSizeMB } else { [int]$Config.Output.SplitSizeMB }
    $swmBase = Join-Path $script:Paths['OutputDated'] $Config.Output.SplitBaseName
    Split-WimForFat32 -WimPath $finalWim -SwmBasePath $swmBase -SizeMB $size
    Add-StepResult -Name 'Split WIM to SWM' -StartTime $stepStart -EndTime (Get-Date) -Details ("Base {0}, size {1} MB" -f $swmBase, $size)
    Update-EtaProgress -CurrentStep 'Split WIM to SWM' -PercentComplete 95

    $finalInfo = @(Get-ImageInfo -ImagePath $finalWim)
    if ($finalInfo.Count -gt 0) {
      $script:Run.Image.FinalEditionName = $finalInfo[0].Name
      $script:Run.Image.FinalEditionVersion = $finalInfo[0].Version
      $script:Run.Image.FinalEditionArchitecture = $finalInfo[0].Architecture
    }

    # Hash output
    $script:Run.Output.FinalWim = $finalWim
    $script:Run.Output.FinalWimHash = Get-FileHashSafe -Path $finalWim
    $script:Run.Output.FinalWimSizeBytes = if ((-not $DryRun) -and (Test-Path -LiteralPath $finalWim)) { (Get-Item -LiteralPath $finalWim).Length } else { $null }
    $script:Run.Output.SwmBase = $swmBase
    $script:Run.Output.SwmFiles = @()
    if (-not $DryRun) {
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
          wim = [ordered]@{ path = $finalWim; sha256 = $script:Run.Output.FinalWimHash; sizeBytes = $script:Run.Output.FinalWimSizeBytes }
          swm = @($script:Run.Output.SwmFiles)
        }
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
      'SUCCESS' { '✅' }
      'SUCCESS WITH WARNINGS' { '⚠️' }
      'FAILED' { '❌' }
      default { '❓' }
    }

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor $verdictColor
    Write-Host "  ║              BUILD SUMMARY                      ║" -ForegroundColor $verdictColor
    Write-Host "  ╠══════════════════════════════════════════════════╣" -ForegroundColor $verdictColor
    Write-Host ("  ║  $verdictEmoji {0,-47}║" -f $verdict) -ForegroundColor $verdictColor
    Write-Host "  ╠══════════════════════════════════════════════════╣" -ForegroundColor $verdictColor
    Write-Host ("  ║  Edition:    {0,-37}║" -f "$($script:Run.Image.FinalEditionName)") -ForegroundColor Cyan
    Write-Host ("  ║  Version:    {0,-37}║" -f "$($script:Run.Image.FinalEditionVersion)") -ForegroundColor Cyan
    Write-Host ("  ║  Arch:       {0,-37}║" -f "$($script:Run.Image.FinalEditionArchitecture)") -ForegroundColor Cyan
    Write-Host ("  ║  Duration:   {0,-37}║" -f "$([math]::Round($script:Run.Duration.TotalMinutes, 1)) minutes") -ForegroundColor Cyan
    Write-Host "  ╠══════════════════════════════════════════════════╣" -ForegroundColor $verdictColor
    
    if ($script:Run.Packages.Injected.Count -gt 0) {
        Write-Host ("  ║  Injected KBs: {0,-35}║" -f "$($script:Run.Packages.Injected.Count) package(s)") -ForegroundColor Yellow
        foreach ($kb in $script:Run.Packages.Injected) {
            $kbLine = "    - $($kb.FileName) [$($kb.Classification)]"
            Write-Host ("  ║  {0,-48}║" -f $kbLine.Substring(0, [math]::Min($kbLine.Length, 48))) -ForegroundColor White
        }
    } else {
        Write-Host ("  ║  Injected KBs: {0,-35}║" -f "None") -ForegroundColor DarkGray
    }
    
    Write-Host "  ╠══════════════════════════════════════════════════╣" -ForegroundColor $verdictColor
    Write-Host ("  ║  WIM: {0,-44}║" -f ([IO.Path]::GetFileName($script:Run.Output.FinalWim))) -ForegroundColor White
    Write-Host ("  ║  Size: {0,-43}║" -f (Format-Size $script:Run.Output.FinalWimSizeBytes)) -ForegroundColor White
    Write-Host "  ╠══════════════════════════════════════════════════╣" -ForegroundColor $verdictColor
    Write-Host ("  ║  HTML:     {0,-39}║" -f ([IO.Path]::GetFileName($reportPath))) -ForegroundColor DarkCyan
    Write-Host ("  ║  Markdown: {0,-39}║" -f ([IO.Path]::GetFileName($mdReportPath))) -ForegroundColor DarkCyan
    Write-Host ("  ║  Diff:     {0,-39}║" -f ([IO.Path]::GetFileName($diffReportPath))) -ForegroundColor DarkCyan

    if ($script:Run.Warnings.Count -gt 0) {
      Write-Host "  ╠══════════════════════════════════════════════════╣" -ForegroundColor Yellow
      Write-Host ("  ║  ⚠️  Warnings: {0,-34}║" -f "$($script:Run.Warnings.Count)") -ForegroundColor Yellow
    }

    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor $verdictColor
    
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
Invoke-PreflightCleanup

Start-BuildProcess -Config $cfg
