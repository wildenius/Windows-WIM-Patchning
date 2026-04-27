<#
.SYNOPSIS
  BuildWIM Mission Control - experimental GUI.

.DESCRIPTION
  A test-only WinForms cockpit for Build-WIM.ps1:
  - dark mission-control style interface
  - drag/drop ISO/WIM/ESD and update packages/folders
  - preflight cards with smart readiness checks
  - command preview
  - live redirected Build-WIM output
  - timeline/progress parsing
  - report/output shortcuts

.NOTES
  Not part of the production pipeline. Run as Administrator for real builds.
#>

[CmdletBinding()]
param(
  [string]$Root = 'C:\BuildWimV2',
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:BuildProcess = $null
$script:LastSummary = ''
$script:LatestReport = $null
$script:LatestOutput = $null

$Colors = [ordered]@{
  Bg = [System.Drawing.Color]::FromArgb(12, 16, 24)
  Panel = [System.Drawing.Color]::FromArgb(22, 29, 42)
  Panel2 = [System.Drawing.Color]::FromArgb(31, 41, 59)
  Text = [System.Drawing.Color]::FromArgb(226, 232, 240)
  Muted = [System.Drawing.Color]::FromArgb(148, 163, 184)
  Accent = [System.Drawing.Color]::FromArgb(56, 189, 248)
  Good = [System.Drawing.Color]::FromArgb(34, 197, 94)
  Warn = [System.Drawing.Color]::FromArgb(250, 204, 21)
  Bad = [System.Drawing.Color]::FromArgb(248, 113, 113)
  Border = [System.Drawing.Color]::FromArgb(51, 65, 85)
}

function Test-IsAdministrator {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function New-Dir {
  param([Parameter(Mandatory)] [string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
}

function Get-FreeGb {
  param([Parameter(Mandatory)] [string]$Path)
  try {
    $rootPath = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path)
    if (-not $rootPath) { $rootPath = [IO.Path]::GetPathRoot($Path) }
    $driveName = $rootPath.Substring(0,1)
    $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
    return [math]::Round($drive.Free / 1GB, 2)
  } catch { return $null }
}

function Set-DarkControl {
  param([System.Windows.Forms.Control]$Control)
  $Control.BackColor = $Colors.Panel
  $Control.ForeColor = $Colors.Text
  if ($Control -is [System.Windows.Forms.TextBox]) {
    $Control.BorderStyle = 'FixedSingle'
    $Control.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $Control.ForeColor = $Colors.Text
  }
  if ($Control -is [System.Windows.Forms.Button]) {
    $Control.FlatStyle = 'Flat'
    $Control.FlatAppearance.BorderColor = $Colors.Border
    $Control.BackColor = $Colors.Panel2
    $Control.ForeColor = $Colors.Text
  }
}

function New-Label {
  param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 22, [int]$Size = 9, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Text
  $l.Location = New-Object System.Drawing.Point($X, $Y)
  $l.Size = New-Object System.Drawing.Size($W, $H)
  $l.ForeColor = $Colors.Text
  $l.BackColor = $Parent.BackColor
  $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $Style)
  $Parent.Controls.Add($l)
  return $l
}

function New-Button {
  param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 32)
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $Text
  $b.Location = New-Object System.Drawing.Point($X, $Y)
  $b.Size = New-Object System.Drawing.Size($W, $H)
  Set-DarkControl $b
  $Parent.Controls.Add($b)
  return $b
}

function New-TextBox {
  param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 24)
  $t = New-Object System.Windows.Forms.TextBox
  $t.Text = $Text
  $t.Location = New-Object System.Drawing.Point($X, $Y)
  $t.Size = New-Object System.Drawing.Size($W, $H)
  Set-DarkControl $t
  $Parent.Controls.Add($t)
  return $t
}

function New-Card {
  param($Parent, [string]$Title, [int]$X, [int]$Y, [int]$W, [int]$H)
  $p = New-Object System.Windows.Forms.Panel
  $p.Location = New-Object System.Drawing.Point($X, $Y)
  $p.Size = New-Object System.Drawing.Size($W, $H)
  $p.BackColor = $Colors.Panel
  $p.BorderStyle = 'FixedSingle'
  $Parent.Controls.Add($p)
  $titleLabel = New-Label $p $Title 12 8 ($W - 24) 22 9 ([System.Drawing.FontStyle]::Bold)
  $valueLabel = New-Label $p 'UNKNOWN' 12 34 ($W - 24) 24 13 ([System.Drawing.FontStyle]::Bold)
  $detailLabel = New-Label $p '' 12 62 ($W - 24) ($H - 66) 8 ([System.Drawing.FontStyle]::Regular)
  $detailLabel.ForeColor = $Colors.Muted
  return [pscustomobject]@{ Panel=$p; Title=$titleLabel; Value=$valueLabel; Detail=$detailLabel }
}

function Set-Card {
  param($Card, [string]$State, [string]$Value, [string]$Detail)
  $Card.Value.Text = $Value
  $Card.Detail.Text = $Detail
  switch ($State) {
    'OK' { $Card.Value.ForeColor = $Colors.Good; $Card.Panel.BackColor = [System.Drawing.Color]::FromArgb(15, 44, 32) }
    'WARN' { $Card.Value.ForeColor = $Colors.Warn; $Card.Panel.BackColor = [System.Drawing.Color]::FromArgb(50, 44, 12) }
    'BAD' { $Card.Value.ForeColor = $Colors.Bad; $Card.Panel.BackColor = [System.Drawing.Color]::FromArgb(54, 24, 28) }
    default { $Card.Value.ForeColor = $Colors.Muted; $Card.Panel.BackColor = $Colors.Panel }
  }
}

function Select-File {
  param([string]$Filter, [string]$Title)
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = $Filter
  $dlg.Title = $Title
  $dlg.CheckFileExists = $true
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
  return $null
}

function Select-Folder {
  param([string]$Description)
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = $Description
  $dlg.ShowNewFolderButton = $true
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
  return $null
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BuildWIM Mission Control - experimental'
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.MinimumSize = New-Object System.Drawing.Size(1080, 700)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Colors.Bg
$form.ForeColor = $Colors.Text
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Label $form 'BuildWIM Mission Control' 22 14 470 34 21 ([System.Drawing.FontStyle]::Bold)
$title.ForeColor = $Colors.Accent
$subtitle = New-Label $form 'Preflight. Patch. Verify. Ship.  Experimental GUI cockpit.' 24 50 620 22 9
$subtitle.ForeColor = $Colors.Muted

$statusPill = New-Label $form 'IDLE' 1000 22 130 30 13 ([System.Drawing.FontStyle]::Bold)
$statusPill.TextAlign = 'MiddleCenter'
$statusPill.BackColor = $Colors.Panel2
$statusPill.ForeColor = $Colors.Muted
$statusPill.BorderStyle = 'FixedSingle'

# Left setup panel
$setup = New-Object System.Windows.Forms.Panel
$setup.Location = New-Object System.Drawing.Point(22, 86)
$setup.Size = New-Object System.Drawing.Size(520, 250)
$setup.BackColor = $Colors.Panel
$setup.BorderStyle = 'FixedSingle'
$form.Controls.Add($setup)
New-Label $setup 'Launch configuration' 14 10 300 24 12 ([System.Drawing.FontStyle]::Bold) | Out-Null

New-Label $setup 'Root' 16 50 90 | Out-Null
$txtRoot = New-TextBox $setup $Root 110 48 310
$btnRoot = New-Button $setup 'Browse' 430 45 72 28

New-Label $setup 'Input image' 16 88 90 | Out-Null
$txtInput = New-TextBox $setup '' 110 86 310
$btnInput = New-Button $setup 'Browse' 430 83 72 28

New-Label $setup 'Updates' 16 126 90 | Out-Null
$txtUpdates = New-TextBox $setup '' 110 124 310
$btnUpdates = New-Button $setup 'Browse' 430 121 72 28

$chkCopyInput = New-Object System.Windows.Forms.CheckBox
$chkCopyInput.Text = 'Stage selected image into Root\Input'
$chkCopyInput.Checked = $true
$chkCopyInput.Location = New-Object System.Drawing.Point(110, 157)
$chkCopyInput.Size = New-Object System.Drawing.Size(280, 22)
$chkCopyInput.BackColor = $setup.BackColor
$chkCopyInput.ForeColor = $Colors.Text
$setup.Controls.Add($chkCopyInput)

$chkCopyUpdates = New-Object System.Windows.Forms.CheckBox
$chkCopyUpdates.Text = 'Stage *.msu/*.cab into Root\Updates'
$chkCopyUpdates.Checked = $true
$chkCopyUpdates.Location = New-Object System.Drawing.Point(110, 181)
$chkCopyUpdates.Size = New-Object System.Drawing.Size(280, 22)
$chkCopyUpdates.BackColor = $setup.BackColor
$chkCopyUpdates.ForeColor = $Colors.Text
$setup.Controls.Add($chkCopyUpdates)

$chkMetadata = New-Object System.Windows.Forms.CheckBox
$chkMetadata.Text = 'Metadata JSON'
$chkMetadata.Checked = $true
$chkMetadata.Location = New-Object System.Drawing.Point(110, 207)
$chkMetadata.Size = New-Object System.Drawing.Size(130, 22)
$chkMetadata.BackColor = $setup.BackColor
$chkMetadata.ForeColor = $Colors.Text
$setup.Controls.Add($chkMetadata)

# Preflight cards
$cardsPanel = New-Object System.Windows.Forms.Panel
$cardsPanel.Location = New-Object System.Drawing.Point(560, 86)
$cardsPanel.Size = New-Object System.Drawing.Size(580, 250)
$cardsPanel.BackColor = $Colors.Bg
$form.Controls.Add($cardsPanel)

$cardAdmin = New-Card $cardsPanel 'ADMIN' 0 0 180 112
$cardDism = New-Card $cardsPanel 'DISM' 200 0 180 112
$cardDisk = New-Card $cardsPanel 'DISK' 400 0 180 112
$cardInput = New-Card $cardsPanel 'INPUT' 0 132 180 112
$cardUpdates = New-Card $cardsPanel 'UPDATES' 200 132 180 112
$cardMount = New-Card $cardsPanel 'MOUNTS' 400 132 180 112

# Command preview and action bar
$cmdPanel = New-Object System.Windows.Forms.Panel
$cmdPanel.Location = New-Object System.Drawing.Point(22, 350)
$cmdPanel.Size = New-Object System.Drawing.Size(1118, 82)
$cmdPanel.BackColor = $Colors.Panel
$cmdPanel.BorderStyle = 'FixedSingle'
$form.Controls.Add($cmdPanel)
New-Label $cmdPanel 'Command preview' 14 8 180 22 10 ([System.Drawing.FontStyle]::Bold) | Out-Null
$txtCommand = New-TextBox $cmdPanel '' 14 36 880 24
$txtCommand.ReadOnly = $true
$btnScan = New-Button $cmdPanel 'Scan' 910 32 86 30
$btnDryRun = New-Button $cmdPanel 'Dry run' 1006 32 86 30

# Progress/log/timeline
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(22, 448)
$progress.Size = New-Object System.Drawing.Size(1118, 18)
$progress.Minimum = 0
$progress.Maximum = 100
$form.Controls.Add($progress)
$currentStep = New-Label $form 'Current step: idle' 24 471 560 22 9
$currentStep.ForeColor = $Colors.Muted

$timeline = New-Object System.Windows.Forms.ListView
$timeline.Location = New-Object System.Drawing.Point(22, 500)
$timeline.Size = New-Object System.Drawing.Size(370, 165)
$timeline.View = 'Details'
$timeline.FullRowSelect = $true
$timeline.GridLines = $false
$timeline.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$timeline.ForeColor = $Colors.Text
$timeline.Columns.Add('Time', 70) | Out-Null
$timeline.Columns.Add('Event', 270) | Out-Null
$form.Controls.Add($timeline)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Location = New-Object System.Drawing.Point(408, 500)
$txtLog.Size = New-Object System.Drawing.Size(732, 165)
Set-DarkControl $txtLog
$form.Controls.Add($txtLog)

$btnBuild = New-Button $form 'START PRODUCTION BUILD' 22 682 210 36
$btnReports = New-Button $form 'Open latest report' 246 682 145 36
$btnOutput = New-Button $form 'Open output' 404 682 120 36
$btnCleanup = New-Button $form 'Cleanup mounts' 537 682 130 36
$btnCopy = New-Button $form 'Copy summary' 680 682 130 36
$btnStop = New-Button $form 'Stop process' 824 682 130 36
$btnStop.Enabled = $false

function Add-Timeline {
  param([string]$Event)
  $item = New-Object System.Windows.Forms.ListViewItem((Get-Date -Format 'HH:mm:ss'))
  [void]$item.SubItems.Add($Event)
  [void]$timeline.Items.Add($item)
  $timeline.EnsureVisible($timeline.Items.Count - 1)
}

function Write-LogUi {
  param([string]$Line)
  if (-not $Line) { return }
  $txtLog.AppendText($Line + [Environment]::NewLine)
  $txtLog.SelectionStart = $txtLog.TextLength
  $txtLog.ScrollToCaret()

  if ($Line -match 'SUCCESS WITH WARNINGS') {
    $statusPill.Text = 'WARNINGS'
    $statusPill.ForeColor = $Colors.Warn
    $progress.Value = 100
    Add-Timeline 'Build finished with warnings'
  } elseif ($Line -match '\bSUCCESS\b') {
    $statusPill.Text = 'SUCCESS'
    $statusPill.ForeColor = $Colors.Good
    $progress.Value = 100
    Add-Timeline 'Build succeeded'
  } elseif ($Line -match '\bFAILED\b|\[ERROR\]') {
    $statusPill.Text = 'FAILED'
    $statusPill.ForeColor = $Colors.Bad
    Add-Timeline 'Build failed'
  }

  $stepMap = @(
    @{Pattern='Detect input'; Percent=8},
    @{Pattern='Extract image from ISO'; Percent=15},
    @{Pattern='Inspect source image'; Percent=22},
    @{Pattern='Export Pro-only'; Percent=30},
    @{Pattern='Discover update'; Percent=35},
    @{Pattern='Mount working'; Percent=42},
    @{Pattern='Inject update'; Percent=60},
    @{Pattern='Offline cleanup'; Percent=72},
    @{Pattern='Commit and unmount'; Percent=82},
    @{Pattern='Export final'; Percent=90},
    @{Pattern='Split WIM'; Percent=95},
    @{Pattern='Finalizing'; Percent=98}
  )
  foreach ($s in $stepMap) {
    if ($Line -match [regex]::Escape($s.Pattern)) {
      $progress.Value = [math]::Min(100, [int]$s.Percent)
      $currentStep.Text = "Current step: $($s.Pattern)"
      Add-Timeline $s.Pattern
      break
    }
  }
}

function Get-CommandPreview {
  param([switch]$DryRun)
  $rootPath = $txtRoot.Text.Trim()
  $scriptPath = Join-Path $rootPath 'Build-WIM.ps1'
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $scriptPath))
  if ($DryRun) { $args += '-DryRun' }
  if ($chkMetadata.Checked) { $args += '-EmitMetadataJson' }
  return ('powershell.exe {0}' -f ($args -join ' '))
}

function Update-CommandPreview {
  $txtCommand.Text = Get-CommandPreview
}

function Invoke-Preflight {
  try {
    $rootPath = $txtRoot.Text.Trim()
    if (-not $rootPath) { $rootPath = $Root }
    $scriptPath = Join-Path $rootPath 'Build-WIM.ps1'
    $inputDir = Join-Path $rootPath 'Input'
    $updatesDir = Join-Path $rootPath 'Updates'

    if (Test-IsAdministrator) { Set-Card $cardAdmin OK 'OK' 'Running elevated.' } else { Set-Card $cardAdmin BAD 'NO' 'Start this GUI as Administrator for real builds.' }

    $dism = Join-Path $env:windir 'System32\dism.exe'
    if (Test-Path -LiteralPath $dism) { Set-Card $cardDism OK 'READY' $dism } else { Set-Card $cardDism BAD 'MISSING' 'DISM not found.' }

    $free = Get-FreeGb -Path $rootPath
    if ($null -eq $free) { Set-Card $cardDisk WARN 'UNKNOWN' 'Could not read free disk space.' }
    elseif ($free -ge 45) { Set-Card $cardDisk OK "$free GB" 'Enough free space for current threshold.' }
    elseif ($free -ge 35) { Set-Card $cardDisk WARN "$free GB" 'Tight. Build may fail or run out of scratch/output space.' }
    else { Set-Card $cardDisk BAD "$free GB" 'Too low for a normal production build.' }

    $candidateInput = $txtInput.Text.Trim()
    $existingInputs = @()
    if (Test-Path -LiteralPath $inputDir) {
      $existingInputs = @(Get-ChildItem -LiteralPath $inputDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.iso','.wim','.esd') })
    }
    if ($candidateInput -and (Test-Path -LiteralPath $candidateInput)) { Set-Card $cardInput OK 'SELECTED' ([IO.Path]::GetFileName($candidateInput)) }
    elseif ($existingInputs.Count -gt 0) { Set-Card $cardInput OK "$($existingInputs.Count) FOUND" ($existingInputs[0].Name) }
    else { Set-Card $cardInput BAD 'MISSING' 'Drop/select ISO, WIM or ESD.' }

    $candidateUpdates = $txtUpdates.Text.Trim()
    $updates = @()
    if ($candidateUpdates -and (Test-Path -LiteralPath $candidateUpdates)) { $updates = @(Get-ChildItem -LiteralPath $candidateUpdates -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.msu','.cab') }) }
    elseif (Test-Path -LiteralPath $updatesDir) { $updates = @(Get-ChildItem -LiteralPath $updatesDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.msu','.cab') }) }
    if ($updates.Count -gt 0) { Set-Card $cardUpdates OK "$($updates.Count) PKG" (($updates | Select-Object -First 2 | ForEach-Object Name) -join ', ') }
    else { Set-Card $cardUpdates WARN 'EMPTY' 'Allowed, but output will be unpatched.' }

    $mountedText = ''
    try { $mountedText = (dism /English /Get-MountedWimInfo 2>&1 | Out-String) } catch { $mountedText = $_.Exception.Message }
    if ($mountedText -match 'No mounted images found') { Set-Card $cardMount OK 'CLEAN' 'No mounted images found.' }
    elseif ($mountedText -match 'Mount Dir|Status') { Set-Card $cardMount WARN 'CHECK' 'Mounted image state exists. Cleanup recommended.' }
    else { Set-Card $cardMount WARN 'UNKNOWN' 'Could not confirm mounted WIM state.' }

    if (-not (Test-Path -LiteralPath $scriptPath)) { Write-LogUi "WARN: Build-WIM.ps1 not found at $scriptPath" }
    Update-CommandPreview
    Add-Timeline 'Preflight scan complete'
  } catch {
    Write-LogUi "PREFLIGHT ERROR: $($_.Exception.Message)"
  }
}

function Stage-SelectedFiles {
  $rootPath = $txtRoot.Text.Trim()
  $inputDir = Join-Path $rootPath 'Input'
  $updatesDir = Join-Path $rootPath 'Updates'
  New-Dir -Path $inputDir
  New-Dir -Path $updatesDir

  if ($chkCopyInput.Checked -and $txtInput.Text.Trim()) {
    $inputFile = $txtInput.Text.Trim()
    if (-not (Test-Path -LiteralPath $inputFile)) { throw "Input file not found: $inputFile" }
    Write-LogUi "Staging input: $inputFile"
    Copy-Item -LiteralPath $inputFile -Destination $inputDir -Force
  }

  if ($chkCopyUpdates.Checked -and $txtUpdates.Text.Trim()) {
    $updatesSource = $txtUpdates.Text.Trim()
    if (-not (Test-Path -LiteralPath $updatesSource)) { throw "Updates path not found: $updatesSource" }
    $packages = @()
    if ((Get-Item -LiteralPath $updatesSource) -is [System.IO.DirectoryInfo]) {
      $packages = @(Get-ChildItem -LiteralPath $updatesSource -File | Where-Object { $_.Extension -in @('.msu','.cab') })
    } else {
      $packages = @(Get-Item -LiteralPath $updatesSource | Where-Object { $_.Extension -in @('.msu','.cab') })
    }
    Write-LogUi "Staging $($packages.Count) update package(s)."
    foreach ($pkg in $packages) { Copy-Item -LiteralPath $pkg.FullName -Destination $updatesDir -Force }
  }
}

function Start-BuildWimRun {
  param([switch]$DryRun)
  if ($script:BuildProcess -and -not $script:BuildProcess.HasExited) {
    Write-LogUi 'A build is already running.'
    return
  }
  try {
    Stage-SelectedFiles
    Invoke-Preflight

    $rootPath = $txtRoot.Text.Trim()
    $scriptPath = Join-Path $rootPath 'Build-WIM.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Build-WIM.ps1 not found: $scriptPath" }

    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $scriptPath))
    if ($DryRun) { $args += '-DryRun' }
    if ($chkMetadata.Checked) { $args += '-EmitMetadataJson' }

    $progress.Value = 0
    $txtLog.Clear()
    $timeline.Items.Clear()
    $statusPill.Text = if ($DryRun) { 'DRY RUN' } else { 'RUNNING' }
    $statusPill.ForeColor = if ($DryRun) { $Colors.Accent } else { $Colors.Warn }
    $currentStep.Text = 'Current step: starting'
    Add-Timeline $(if ($DryRun) { 'Dry run started' } else { 'Production build started' })
    Write-LogUi ('COMMAND: powershell.exe {0}' -f ($args -join ' '))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($args -join ' ')
    $psi.WorkingDirectory = $rootPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $p.EnableRaisingEvents = $true

    $outHandler = [System.Diagnostics.DataReceivedEventHandler]{ param($sender, $e) if ($e.Data) { $form.BeginInvoke([Action[string]]{ param($line) Write-LogUi $line }, $e.Data) | Out-Null } }
    $errHandler = [System.Diagnostics.DataReceivedEventHandler]{ param($sender, $e) if ($e.Data) { $form.BeginInvoke([Action[string]]{ param($line) Write-LogUi "ERR: $line" }, $e.Data) | Out-Null } }
    $exitHandler = [System.EventHandler]{
      param($sender, $e)
      $form.BeginInvoke([Action]{
        $btnStop.Enabled = $false
        $code = $script:BuildProcess.ExitCode
        if ($code -eq 0 -and $statusPill.Text -notin @('FAILED','WARNINGS','SUCCESS')) {
          $statusPill.Text = 'COMPLETE'
          $statusPill.ForeColor = $Colors.Good
          $progress.Value = 100
        } elseif ($code -ne 0) {
          $statusPill.Text = "EXIT $code"
          $statusPill.ForeColor = $Colors.Bad
        }
        Add-Timeline "Process exited: $code"
        Find-LatestArtifacts
      }) | Out-Null
    }

    $p.add_OutputDataReceived($outHandler)
    $p.add_ErrorDataReceived($errHandler)
    $p.add_Exited($exitHandler)
    [void]$p.Start()
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()
    $script:BuildProcess = $p
    $btnStop.Enabled = $true
  } catch {
    Write-LogUi "START ERROR: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'BuildWIM Mission Control', 'OK', 'Error') | Out-Null
  }
}

function Find-LatestArtifacts {
  $rootPath = $txtRoot.Text.Trim()
  $reports = Join-Path $rootPath 'Reports'
  $output = Join-Path $rootPath 'Output'
  if (Test-Path -LiteralPath $reports) {
    $script:LatestReport = Get-ChildItem -LiteralPath $reports -Filter 'BuildWIM-*.html' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  if (Test-Path -LiteralPath $output) {
    $script:LatestOutput = Get-ChildItem -LiteralPath $output -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  $script:LastSummary = @(
    "Status: $($statusPill.Text)",
    "Root: $rootPath",
    "Report: $(if($script:LatestReport){$script:LatestReport.FullName}else{'not found'})",
    "Output: $(if($script:LatestOutput){$script:LatestOutput.FullName}else{'not found'})"
  ) -join [Environment]::NewLine
}

function Enable-DropTarget {
  param([System.Windows.Forms.TextBox]$TextBox, [switch]$FolderPreferred)
  $TextBox.AllowDrop = $true
  $TextBox.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = [Windows.Forms.DragDropEffects]::Copy }
  })
  $TextBox.Add_DragDrop({
    $paths = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    if ($paths -and $paths.Count -gt 0) { $this.Text = $paths[0]; Invoke-Preflight }
  })
}

$btnRoot.Add_Click({ $s = Select-Folder 'Select BuildWIM root'; if ($s) { $txtRoot.Text = $s; Invoke-Preflight } })
$btnInput.Add_Click({ $s = Select-File 'Windows images (*.iso;*.wim;*.esd)|*.iso;*.wim;*.esd|All files (*.*)|*.*' 'Select ISO/WIM/ESD'; if ($s) { $txtInput.Text = $s; Invoke-Preflight } })
$btnUpdates.Add_Click({ $s = Select-Folder 'Select update package folder'; if ($s) { $txtUpdates.Text = $s; Invoke-Preflight } })
$btnScan.Add_Click({ Invoke-Preflight })
$btnDryRun.Add_Click({ Start-BuildWimRun -DryRun })
$btnBuild.Add_Click({
  $confirm = [System.Windows.Forms.MessageBox]::Show('Start production BuildWIM run? This can take 60-90 minutes.', 'Confirm production build', 'YesNo', 'Warning')
  if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) { Start-BuildWimRun }
})
$btnReports.Add_Click({ Find-LatestArtifacts; if ($script:LatestReport) { Start-Process $script:LatestReport.FullName } else { Write-LogUi 'No HTML report found yet.' } })
$btnOutput.Add_Click({ Find-LatestArtifacts; if ($script:LatestOutput) { Start-Process explorer.exe -ArgumentList @($script:LatestOutput.FullName) } else { Start-Process explorer.exe -ArgumentList @((Join-Path $txtRoot.Text.Trim() 'Output')) } })
$btnCopy.Add_Click({ Find-LatestArtifacts; [System.Windows.Forms.Clipboard]::SetText($script:LastSummary); Write-LogUi 'Summary copied to clipboard.' })
$btnStop.Add_Click({ if ($script:BuildProcess -and -not $script:BuildProcess.HasExited) { $script:BuildProcess.Kill(); Write-LogUi 'Process kill requested.' } })
$btnCleanup.Add_Click({
  try {
    Write-LogUi 'Running DISM cleanup...'
    $text = (dism /English /Cleanup-Wim 2>&1 | Out-String)
    Write-LogUi $text.Trim()
    Invoke-Preflight
  } catch { Write-LogUi "Cleanup failed: $($_.Exception.Message)" }
})

foreach ($tb in @($txtRoot, $txtInput, $txtUpdates)) {
  Enable-DropTarget -TextBox $tb
  $tb.Add_TextChanged({ Update-CommandPreview })
}
$chkMetadata.Add_CheckedChanged({ Update-CommandPreview })

Update-CommandPreview
Invoke-Preflight

if ($SelfTest) {
  $failures = New-Object System.Collections.Generic.List[string]
  $rootPath = $txtRoot.Text.Trim()
  $scriptPath = Join-Path $rootPath 'Build-WIM.ps1'
  $inputDir = Join-Path $rootPath 'Input'
  $updatesDir = Join-Path $rootPath 'Updates'

  if (-not (Test-Path -LiteralPath $scriptPath)) { $failures.Add("Build-WIM.ps1 missing: $scriptPath") | Out-Null }
  if (-not (Test-Path -LiteralPath (Join-Path $env:windir 'System32\dism.exe'))) { $failures.Add('DISM missing') | Out-Null }
  if (-not (Test-Path -LiteralPath $inputDir)) { $failures.Add("Input folder missing: $inputDir") | Out-Null }
  if (-not (Test-Path -LiteralPath $updatesDir)) { $failures.Add("Updates folder missing: $updatesDir") | Out-Null }
  if ($txtCommand.Text -notmatch 'Build-WIM.ps1') { $failures.Add('Command preview does not reference Build-WIM.ps1') | Out-Null }
  if ($cardDism.Value.Text -eq 'MISSING') { $failures.Add('Preflight card: DISM missing') | Out-Null }
  if ($cardInput.Value.Text -eq 'MISSING') { $failures.Add('Preflight card: input missing') | Out-Null }

  Write-Host 'BuildWIM Mission Control self-test'
  Write-Host "Root=$rootPath"
  Write-Host "Command=$($txtCommand.Text)"
  Write-Host "Admin=$($cardAdmin.Value.Text)"
  Write-Host "DISM=$($cardDism.Value.Text)"
  Write-Host "Disk=$($cardDisk.Value.Text)"
  Write-Host "Input=$($cardInput.Value.Text)"
  Write-Host "Updates=$($cardUpdates.Value.Text)"
  Write-Host "Mounts=$($cardMount.Value.Text)"

  if ($failures.Count -gt 0) {
    Write-Host 'SELFTEST FAILED'
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
  }

  Write-Host 'SELFTEST OK'
  exit 0
}

Write-LogUi 'Mission Control ready. Drag in an ISO/WIM/ESD, scan, then run Dry run first.'
[void]$form.ShowDialog()
