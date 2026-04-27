<#
.SYNOPSIS
  Experimental GUI launcher for BuildWIM.

.DESCRIPTION
  Test-only WinForms launcher. It prepares C:\BuildWimV2\Input and Updates from selected
  files/folders, then starts Build-WIM.ps1 with the selected switches.

.NOTES
  This is intentionally separate from Build-WIM.ps1 so the core automation remains scriptable.
#>

[CmdletBinding()]
param(
  [string]$Root = 'C:\BuildWimV2'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-Dir {
  param([Parameter(Mandatory)] [string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Show-Message {
  param(
    [Parameter(Mandatory)] [string]$Text,
    [string]$Title = 'BuildWIM GUI',
    [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
  )
  [System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $Icon) | Out-Null
}

function Select-File {
  param(
    [string]$Filter = 'Windows images (*.iso;*.wim;*.esd)|*.iso;*.wim;*.esd|All files (*.*)|*.*',
    [string]$Title = 'Select file'
  )
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = $Filter
  $dlg.Title = $Title
  $dlg.CheckFileExists = $true
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
  return $null
}

function Select-Folder {
  param([string]$Description = 'Select folder')
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = $Description
  $dlg.ShowNewFolderButton = $true
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
  return $null
}

function Add-Label {
  param($Form, [string]$Text, [int]$X, [int]$Y, [int]$W = 120)
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Text
  $l.Location = New-Object System.Drawing.Point($X, $Y)
  $l.Size = New-Object System.Drawing.Size($W, 22)
  $Form.Controls.Add($l)
  return $l
}

function Add-TextBox {
  param($Form, [string]$Text, [int]$X, [int]$Y, [int]$W = 470)
  $t = New-Object System.Windows.Forms.TextBox
  $t.Text = $Text
  $t.Location = New-Object System.Drawing.Point($X, $Y)
  $t.Size = New-Object System.Drawing.Size($W, 22)
  $Form.Controls.Add($t)
  return $t
}

function Add-Button {
  param($Form, [string]$Text, [int]$X, [int]$Y, [int]$W = 90)
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $Text
  $b.Location = New-Object System.Drawing.Point($X, $Y)
  $b.Size = New-Object System.Drawing.Size($W, 26)
  $Form.Controls.Add($b)
  return $b
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BuildWIM GUI - experimental'
$form.Size = New-Object System.Drawing.Size(760, 510)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(720, 470)

Add-Label $form 'BuildWIM root' 18 22 | Out-Null
$txtRoot = Add-TextBox $form $Root 140 20 480
$btnRoot = Add-Button $form 'Browse...' 630 18 90

Add-Label $form 'Input ISO/WIM/ESD' 18 62 | Out-Null
$txtInput = Add-TextBox $form '' 140 60 480
$btnInput = Add-Button $form 'Browse...' 630 58 90

Add-Label $form 'Updates folder' 18 102 | Out-Null
$txtUpdates = Add-TextBox $form '' 140 100 480
$btnUpdates = Add-Button $form 'Browse...' 630 98 90

$chkCopyInput = New-Object System.Windows.Forms.CheckBox
$chkCopyInput.Text = 'Copy selected input into Root\Input before run'
$chkCopyInput.Checked = $true
$chkCopyInput.Location = New-Object System.Drawing.Point(140, 132)
$chkCopyInput.Size = New-Object System.Drawing.Size(300, 22)
$form.Controls.Add($chkCopyInput)

$chkCopyUpdates = New-Object System.Windows.Forms.CheckBox
$chkCopyUpdates.Text = 'Copy *.msu/*.cab from updates folder into Root\Updates'
$chkCopyUpdates.Checked = $true
$chkCopyUpdates.Location = New-Object System.Drawing.Point(140, 158)
$chkCopyUpdates.Size = New-Object System.Drawing.Size(360, 22)
$form.Controls.Add($chkCopyUpdates)

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = 'Dry run'
$chkDryRun.Location = New-Object System.Drawing.Point(140, 190)
$chkDryRun.Size = New-Object System.Drawing.Size(90, 22)
$form.Controls.Add($chkDryRun)

$chkMetadata = New-Object System.Windows.Forms.CheckBox
$chkMetadata.Text = 'Emit metadata JSON'
$chkMetadata.Checked = $true
$chkMetadata.Location = New-Object System.Drawing.Point(250, 190)
$chkMetadata.Size = New-Object System.Drawing.Size(160, 22)
$form.Controls.Add($chkMetadata)

$chkAdmin = New-Object System.Windows.Forms.CheckBox
$chkAdmin.Text = 'Run as Administrator'
$chkAdmin.Checked = $true
$chkAdmin.Location = New-Object System.Drawing.Point(430, 190)
$chkAdmin.Size = New-Object System.Drawing.Size(170, 22)
$form.Controls.Add($chkAdmin)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Location = New-Object System.Drawing.Point(18, 230)
$txtLog.Size = New-Object System.Drawing.Size(702, 170)
$form.Controls.Add($txtLog)

$btnStart = Add-Button $form 'Start build' 500 420 105
$btnOpenRoot = Add-Button $form 'Open root' 615 420 105

function Write-GuiLog {
  param([string]$Line)
  $txtLog.AppendText(('{0} {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $Line, [Environment]::NewLine))
}

$btnRoot.Add_Click({
  $selected = Select-Folder -Description 'Select BuildWIM root folder'
  if ($selected) { $txtRoot.Text = $selected }
})

$btnInput.Add_Click({
  $selected = Select-File -Title 'Select ISO/WIM/ESD'
  if ($selected) { $txtInput.Text = $selected }
})

$btnUpdates.Add_Click({
  $selected = Select-Folder -Description 'Select folder containing MSU/CAB files'
  if ($selected) { $txtUpdates.Text = $selected }
})

$btnOpenRoot.Add_Click({
  if (Test-Path -LiteralPath $txtRoot.Text) {
    Start-Process explorer.exe -ArgumentList @($txtRoot.Text)
  } else {
    Show-Message "Root does not exist: $($txtRoot.Text)" 'BuildWIM GUI' Warning
  }
})

$btnStart.Add_Click({
  try {
    $rootPath = $txtRoot.Text.Trim()
    if (-not $rootPath) { throw 'BuildWIM root is required.' }

    $scriptPath = Join-Path $rootPath 'Build-WIM.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
      throw "Build-WIM.ps1 not found: $scriptPath"
    }

    $inputDir = Join-Path $rootPath 'Input'
    $updatesDir = Join-Path $rootPath 'Updates'
    New-Dir -Path $inputDir
    New-Dir -Path $updatesDir

    if ($chkCopyInput.Checked -and $txtInput.Text.Trim()) {
      $inputFile = $txtInput.Text.Trim()
      if (-not (Test-Path -LiteralPath $inputFile)) { throw "Input file not found: $inputFile" }
      Write-GuiLog "Copying input to $inputDir"
      Copy-Item -LiteralPath $inputFile -Destination $inputDir -Force
    }

    if ($chkCopyUpdates.Checked -and $txtUpdates.Text.Trim()) {
      $updatesSource = $txtUpdates.Text.Trim()
      if (-not (Test-Path -LiteralPath $updatesSource)) { throw "Updates folder not found: $updatesSource" }
      $packages = @(Get-ChildItem -LiteralPath $updatesSource -File | Where-Object { $_.Extension -in @('.msu','.cab') })
      Write-GuiLog "Copying $($packages.Count) update package(s) to $updatesDir"
      foreach ($pkg in $packages) {
        Copy-Item -LiteralPath $pkg.FullName -Destination $updatesDir -Force
      }
    }

    $argList = @(
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', ('"{0}"' -f $scriptPath)
    )
    if ($chkDryRun.Checked) { $argList += '-DryRun' }
    if ($chkMetadata.Checked) { $argList += '-EmitMetadataJson' }

    Write-GuiLog ('Starting: powershell.exe {0}' -f ($argList -join ' '))

    $startInfo = @{
      FilePath = 'powershell.exe'
      ArgumentList = $argList
      WorkingDirectory = $rootPath
    }
    if ($chkAdmin.Checked) { $startInfo.Verb = 'RunAs' }
    Start-Process @startInfo
    Write-GuiLog 'Build process launched in a separate PowerShell window.'
  } catch {
    Write-GuiLog "ERROR: $($_.Exception.Message)"
    Show-Message $_.Exception.Message 'BuildWIM GUI error' Error
  }
})

Write-GuiLog 'Ready. Select input/updates or use existing files under Root.'
[void]$form.ShowDialog()
