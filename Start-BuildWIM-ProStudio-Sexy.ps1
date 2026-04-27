<#
.SYNOPSIS
  BuildWIM Pro Studio Neon - premium WPF prototype.

.DESCRIPTION
  A sellable-looking experimental WPF front-end for Build-WIM.ps1.
  It focuses on packaging the existing automation as a polished product:
  - branded command-center layout
  - readiness score
  - system/input/update/mount checks
  - guided actions
  - command preview
  - launch dry-run / production builds in terminal windows

.NOTES
  Prototype only. No production pipeline logic lives here.
#>

[CmdletBinding()]
param(
  [string]$Root = 'C:\BuildWIM',
  [switch]$SelfTest,
  [string]$RenderPreviewPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function Test-IsAdministrator {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Get-FreeGb {
  param([string]$Path)
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $driveName = (Get-Item -LiteralPath $Path).PSDrive.Name
    $drive = Get-PSDrive -Name $driveName
    return [math]::Round($drive.Free / 1GB, 1)
  } catch { return $null }
}

function Get-LatestFilePath {
  param([string]$Folder, [string]$Filter)
  if (-not (Test-Path -LiteralPath $Folder)) { return $null }
  $file = Get-ChildItem -LiteralPath $Folder -Filter $Filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($file) { return $file.FullName }
  return $null
}

function Get-ProStudioState {
  param([string]$RootPath)
  $scriptPath = Join-Path $RootPath 'Build-WIM.ps1'
  $inputDir = Join-Path $RootPath 'Input'
  $updatesDir = Join-Path $RootPath 'Updates'
  $reportsDir = Join-Path $RootPath 'Reports'
  $outputDir = Join-Path $RootPath 'Output'

  $admin = Test-IsAdministrator
  $dismPath = Join-Path $env:windir 'System32\dism.exe'
  $dismOk = Test-Path -LiteralPath $dismPath
  $scriptOk = Test-Path -LiteralPath $scriptPath
  $freeGb = Get-FreeGb -Path $RootPath
  $diskOk = ($null -ne $freeGb -and $freeGb -ge 45)
  $diskWarn = ($null -ne $freeGb -and $freeGb -ge 30 -and $freeGb -lt 45)

  $inputs = @()
  if (Test-Path -LiteralPath $inputDir) {
    $inputs = @(Get-ChildItem -LiteralPath $inputDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.iso','.wim','.esd') })
  }
  $updates = @()
  if (Test-Path -LiteralPath $updatesDir) {
    $updates = @(Get-ChildItem -LiteralPath $updatesDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.msu','.cab') })
  }

  $mountClean = $false
  $mountText = ''
  try {
    $mountText = (dism /English /Get-MountedWimInfo 2>&1 | Out-String)
    $mountClean = ($mountText -match 'No mounted images found')
  } catch { $mountText = $_.Exception.Message }

  $score = 0
  if ($admin) { $score += 15 }
  if ($dismOk) { $score += 15 }
  if ($scriptOk) { $score += 15 }
  if ($diskOk) { $score += 20 } elseif ($diskWarn) { $score += 8 }
  if ($inputs.Count -gt 0) { $score += 15 }
  if ($updates.Count -gt 0) { $score += 10 }
  if ($mountClean) { $score += 10 }

  $latestReport = Get-LatestFilePath -Folder $reportsDir -Filter 'BuildWIM-*.html'
  $latestMetadata = Get-LatestFilePath -Folder $outputDir -Filter 'BuildWIM-*.metadata.json'

  [pscustomobject]@{
    Root = $RootPath
    ScriptPath = $scriptPath
    ScriptOk = $scriptOk
    Admin = $admin
    DismOk = $dismOk
    DismPath = $dismPath
    FreeGb = $freeGb
    DiskOk = $diskOk
    DiskWarn = $diskWarn
    Inputs = $inputs
    Updates = $updates
    MountClean = $mountClean
    MountText = $mountText
    Score = [math]::Min(100, $score)
    LatestReport = $latestReport
    LatestMetadata = $latestMetadata
  }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BuildWIM Pro Studio Neon" Height="860" Width="1320" MinHeight="760" MinWidth="1120"
        WindowStartupLocation="CenterScreen" Background="#020617" FontFamily="Segoe UI">
  <Window.Resources>
    <LinearGradientBrush x:Key="HeroBrush" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#22D3EE" Offset="0" />
      <GradientStop Color="#A855F7" Offset="0.42" />
      <GradientStop Color="#F97316" Offset="0.78" />
      <GradientStop Color="#020617" Offset="1" />
    </LinearGradientBrush>
    <Style x:Key="Panel" TargetType="Border">
      <Setter Property="Background" Value="#0B1020" />
      <Setter Property="CornerRadius" Value="24" />
      <Setter Property="Padding" Value="18" />
      <Setter Property="BorderBrush" Value="#164E63" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Effect"><Setter.Value><DropShadowEffect BlurRadius="22" ShadowDepth="0" Color="#0EA5E9" Opacity="0.18"/></Setter.Value></Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#070B17" />
      <Setter Property="CornerRadius" Value="16" />
      <Setter Property="Padding" Value="14" />
      <Setter Property="BorderBrush" Value="#155E75" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Effect"><Setter.Value><DropShadowEffect BlurRadius="18" ShadowDepth="0" Color="#7C3AED" Opacity="0.16"/></Setter.Value></Setter>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E5EEF9" />
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#E5EEF9" />
      <Setter Property="Background" Value="#0E7490" />
      <Setter Property="BorderBrush" Value="#67E8F9" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Padding" Value="14,9" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="12" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#07111F" />
      <Setter Property="Foreground" Value="#E5EEF9" />
      <Setter Property="BorderBrush" Value="#334155" />
      <Setter Property="Padding" Value="10,7" />
      <Setter Property="FontSize" Value="13" />
    </Style>
  </Window.Resources>

  <Grid Margin="22">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="230"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <Border Grid.Column="0" Background="#0B1628" CornerRadius="24" Padding="18" BorderBrush="#1E3A5F" BorderThickness="1">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top">
          <TextBlock Text="BuildWIM" FontSize="30" FontWeight="Bold"/>
          <TextBlock Text="Pro Studio Neon" FontSize="23" FontWeight="Bold" Foreground="#38BDF8" Margin="0,-4,0,18"/>
          <TextBlock Text="Offline Windows image engineering. Polished enough to demo. Dangerous enough to sell." Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,24"/>
          <Border Background="#07111F" CornerRadius="16" Padding="14" Margin="0,0,0,14">
            <StackPanel>
              <TextBlock Text="PLAN" Foreground="#94A3B8" FontSize="11" FontWeight="Bold"/>
              <TextBlock Text="1. Readiness" Margin="0,8,0,0"/>
              <TextBlock Text="2. Dry run" Margin="0,8,0,0"/>
              <TextBlock Text="3. Build" Margin="0,8,0,0"/>
              <TextBlock Text="4. Verify" Margin="0,8,0,0"/>
              <TextBlock Text="5. Ship" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>
          <Border Background="#052E3B" CornerRadius="16" Padding="14">
            <StackPanel>
              <TextBlock Text="WHY IT SELLS" Foreground="#67E8F9" FontSize="11" FontWeight="Bold"/>
              <TextBlock Text="Takes DISM chaos and turns it into a premium operator cockpit with evidence, scoring and repeatability." TextWrapping="Wrap" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
        <TextBlock DockPanel.Dock="Bottom" Text="NEON PROTOTYPE | local only | no push" Foreground="#64748B"/>
      </DockPanel>
    </Border>

    <ScrollViewer Grid.Column="1" Margin="22,0,0,0" VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <Border Background="{StaticResource HeroBrush}" CornerRadius="28" Padding="26" Margin="0,0,0,18">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="250"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Text="Patch. Verify. Ship." FontSize="38" FontWeight="Bold"/>
              <TextBlock Text="A premium cockpit for building patched Windows 11 Pro images with readiness intelligence, traceable evidence and one-click operator flow." Foreground="#DBEAFE" FontSize="14" TextWrapping="Wrap" Margin="0,8,40,0"/>
              <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
                <Border Background="#AA020617" BorderBrush="#67E8F9" BorderThickness="1" CornerRadius="14" Padding="10,5" Margin="0,0,8,0"><TextBlock Text="DISM HARDENED" Foreground="#A5F3FC" FontSize="11" FontWeight="Bold"/></Border>
                <Border Background="#AA020617" BorderBrush="#C084FC" BorderThickness="1" CornerRadius="14" Padding="10,5" Margin="0,0,8,0"><TextBlock Text="AUDIT READY" Foreground="#E9D5FF" FontSize="11" FontWeight="Bold"/></Border>
                <Border Background="#AA020617" BorderBrush="#FDBA74" BorderThickness="1" CornerRadius="14" Padding="10,5"><TextBlock Text="PATCH TUESDAY" Foreground="#FED7AA" FontSize="11" FontWeight="Bold"/></Border>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,22,0,0">
                <Button x:Name="BtnRefresh" Content="Scan readiness" Width="150" Margin="0,0,10,0"/>
                <Button x:Name="BtnDryRun" Content="Simulate build" Width="135" Margin="0,0,10,0" Background="#0891B2"/>
                <Button x:Name="BtnBuild" Content="Ignite production" Width="165" Background="#C2410C"/>
              </StackPanel>
            </StackPanel>
            <Border Grid.Column="1" Background="#AA07111F" CornerRadius="22" Padding="18">
              <StackPanel HorizontalAlignment="Center">
                <TextBlock Text="SHIP SCORE" Foreground="#93C5FD" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center"/>
                <TextBlock x:Name="TxtScore" Text="--" FontSize="58" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,4,0,0"/>
                <TextBlock x:Name="TxtVerdict" Text="Scanning..." Foreground="#CBD5E1" FontSize="14" HorizontalAlignment="Center"/>
                <ProgressBar x:Name="ScoreBar" Height="10" Width="180" Maximum="100" Margin="0,16,0,0"/>
              </StackPanel>
            </Border>
          </Grid>
        </Border>

        <Grid Margin="0,0,0,18">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,12,0">
            <StackPanel><TextBlock Text="ENGINE ROOM" Foreground="#67E8F9"/><TextBlock x:Name="TxtSystem" Text="--" FontSize="20" FontWeight="Bold" Margin="0,8,0,0"/><TextBlock x:Name="TxtSystemDetail" Text="--" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,8,0,0"/></StackPanel>
          </Border>
          <Border Grid.Column="1" Style="{StaticResource Card}" Margin="6,0,6,0">
            <StackPanel><TextBlock Text="SOURCE IMAGE" Foreground="#C084FC"/><TextBlock x:Name="TxtInput" Text="--" FontSize="20" FontWeight="Bold" Margin="0,8,0,0"/><TextBlock x:Name="TxtInputDetail" Text="--" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,8,0,0"/></StackPanel>
          </Border>
          <Border Grid.Column="2" Style="{StaticResource Card}" Margin="12,0,0,0">
            <StackPanel><TextBlock Text="PATCH PAYLOAD" Foreground="#FDBA74"/><TextBlock x:Name="TxtUpdates" Text="--" FontSize="20" FontWeight="Bold" Margin="0,8,0,0"/><TextBlock x:Name="TxtUpdatesDetail" Text="--" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,8,0,0"/></StackPanel>
          </Border>
        </Grid>

        <Border Style="{StaticResource Panel}" Margin="0,0,0,18">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/><ColumnDefinition Width="110"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <TextBlock Text="Root" Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" Foreground="#94A3B8"/>
            <TextBox x:Name="TxtRoot" Grid.Row="0" Grid.Column="1" Text="C:\BuildWIM" Margin="0,0,10,10"/>
            <Button x:Name="BtnBrowseRoot" Grid.Row="0" Grid.Column="2" Content="Browse" Margin="0,0,0,10"/>
            <TextBlock Text="Command" Grid.Row="1" Grid.Column="0" VerticalAlignment="Center" Foreground="#94A3B8"/>
            <TextBox x:Name="TxtCommand" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" IsReadOnly="True" FontFamily="Consolas"/>
          </Grid>
        </Border>

        <Grid Margin="0,0,0,18">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Border Grid.Column="0" Style="{StaticResource Panel}" Margin="0,0,9,0">
            <StackPanel>
              <TextBlock Text="Operator Command" FontSize="18" FontWeight="Bold"/>
              <TextBlock x:Name="TxtAction" Text="Refresh readiness to get recommended next step." Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,8,0,14"/>
              <WrapPanel>
                <Button x:Name="BtnReport" Content="Open latest report" Margin="0,0,10,10"/>
                <Button x:Name="BtnOutput" Content="Open output" Margin="0,0,10,10"/>
                <Button x:Name="BtnCleanup" Content="Cleanup mounts" Margin="0,0,10,10"/>
              </WrapPanel>
            </StackPanel>
          </Border>
          <Border Grid.Column="1" Style="{StaticResource Panel}" Margin="9,0,0,0">
            <StackPanel>
              <TextBlock Text="Evidence Locker" FontSize="18" FontWeight="Bold"/>
              <TextBlock Text="Report" Foreground="#94A3B8" Margin="0,10,0,0"/>
              <TextBlock x:Name="TxtReport" Text="--" TextWrapping="Wrap"/>
              <TextBlock Text="Metadata" Foreground="#94A3B8" Margin="0,12,0,0"/>
              <TextBlock x:Name="TxtMetadata" Text="--" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>
        </Grid>

        <Border Style="{StaticResource Panel}" Margin="0,0,0,18">
          <StackPanel>
            <TextBlock Text="Executive Signal" FontSize="18" FontWeight="Bold"/>
            <TextBlock x:Name="TxtNotes" Text="--" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,10,0,0"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$names = @('TxtScore','TxtVerdict','ScoreBar','TxtSystem','TxtSystemDetail','TxtInput','TxtInputDetail','TxtUpdates','TxtUpdatesDetail','TxtRoot','TxtCommand','TxtAction','TxtReport','TxtMetadata','TxtNotes','BtnRefresh','BtnDryRun','BtnBuild','BtnBrowseRoot','BtnReport','BtnOutput','BtnCleanup')
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }
$script:TxtRoot.Text = $Root

function Set-BrushByScore {
  param($TextBlock, [int]$Score)
  if ($Score -ge 85) { $TextBlock.Foreground = '#22C55E' }
  elseif ($Score -ge 65) { $TextBlock.Foreground = '#FACC15' }
  else { $TextBlock.Foreground = '#FB7185' }
}

function Update-ProStudioUi {
  $state = Get-ProStudioState -RootPath $script:TxtRoot.Text.Trim()
  $script:CurrentState = $state

  $script:TxtScore.Text = "$($state.Score)%"
  $script:ScoreBar.Value = $state.Score
  Set-BrushByScore $script:TxtScore $state.Score

  if ($state.Score -ge 90) { $script:TxtVerdict.Text = 'Ready to ship'; $script:TxtAction.Text = 'Run Dry run first, then Production build. This machine is ready.' }
  elseif ($state.Score -ge 70) { $script:TxtVerdict.Text = 'Almost ready'; $script:TxtAction.Text = 'Fix yellow items before a production run. Dry run is safe.' }
  else { $script:TxtVerdict.Text = 'Needs attention'; $script:TxtAction.Text = 'Do not sell this run yet. Fix blockers: admin, disk, input, DISM or mounts.' }

  $sys = @()
  $sys += if ($state.Admin) { 'Admin OK' } else { 'Not admin' }
  $sys += if ($state.DismOk) { 'DISM OK' } else { 'DISM missing' }
  $sys += if ($state.ScriptOk) { 'Build script OK' } else { 'Build script missing' }
  $script:TxtSystem.Text = if ($state.Admin -and $state.DismOk -and $state.ScriptOk) { 'Ready' } else { 'Attention' }
  $script:TxtSystemDetail.Text = (($sys -join ' | ') + "`nDisk: $($state.FreeGb) GB free")

  $script:TxtInput.Text = if ($state.Inputs.Count -gt 0) { "$($state.Inputs.Count) image found" } else { 'Missing' }
  $script:TxtInputDetail.Text = if ($state.Inputs.Count -gt 0) { ($state.Inputs | Select-Object -First 2 | ForEach-Object Name) -join "`n" } else { 'Put ISO/WIM/ESD in Input folder.' }

  $script:TxtUpdates.Text = if ($state.Updates.Count -gt 0) { "$($state.Updates.Count) package(s)" } else { 'No updates' }
  $script:TxtUpdatesDetail.Text = if ($state.Updates.Count -gt 0) { ($state.Updates | Select-Object -First 2 | ForEach-Object Name) -join "`n" } else { 'Build can run, but image will not be patched.' }

  $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitMetadataJson' -f $state.ScriptPath
  $script:TxtCommand.Text = $cmd
  $script:TxtReport.Text = if ($state.LatestReport) { $state.LatestReport } else { 'No report found yet.' }
  $script:TxtMetadata.Text = if ($state.LatestMetadata) { $state.LatestMetadata } else { 'No metadata found yet.' }

  $notes = @()
  if (-not $state.Admin) { $notes += 'Run Pro Studio as Administrator for production builds.' }
  if ($state.FreeGb -lt 45) { $notes += "Disk is below production threshold: $($state.FreeGb) GB free, 45 GB recommended." }
  if (-not $state.MountClean) { $notes += 'Mounted WIM state is not clean. Use Cleanup mounts.' }
  if ($state.Updates.Count -eq 0) { $notes += 'No update packages found. Add MSU/CAB files for a patched image.' }
  if ($notes.Count -eq 0) { $notes += 'Everything looks clean. This is the green-room state.' }
  $script:TxtNotes.Text = $notes -join "`n"

  return $state
}

function Start-BuildTerminal {
  param([switch]$DryRun)
  $state = Get-ProStudioState -RootPath $script:TxtRoot.Text.Trim()
  if (-not $state.ScriptOk) { [System.Windows.MessageBox]::Show("Missing Build-WIM.ps1: $($state.ScriptPath)", 'BuildWIM Pro Studio', 'OK', 'Error') | Out-Null; return }
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $state.ScriptPath))
  if ($DryRun) { $args += '-DryRun' }
  $args += '-EmitMetadataJson'
  Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory $state.Root
}

$script:BtnRefresh.Add_Click({ Update-ProStudioUi | Out-Null })
$script:BtnDryRun.Add_Click({ Start-BuildTerminal -DryRun })
$script:BtnBuild.Add_Click({
  $answer = [System.Windows.MessageBox]::Show('Start production build? This can take 60-90 minutes.', 'BuildWIM Pro Studio', 'YesNo', 'Warning')
  if ($answer -eq 'Yes') { Start-BuildTerminal }
})
$script:BtnBrowseRoot.Add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = 'Select BuildWIM root'
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:TxtRoot.Text = $dlg.SelectedPath; Update-ProStudioUi | Out-Null }
})
$script:BtnReport.Add_Click({ $s = Update-ProStudioUi; if ($s.LatestReport) { Start-Process $s.LatestReport } })
$script:BtnOutput.Add_Click({ $s = Update-ProStudioUi; $out = Join-Path $s.Root 'Output'; if (Test-Path -LiteralPath $out) { Start-Process explorer.exe -ArgumentList @($out) } })
$script:BtnCleanup.Add_Click({ dism /English /Cleanup-Wim | Out-Null; Update-ProStudioUi | Out-Null })
$script:TxtRoot.Add_TextChanged({ try { Update-ProStudioUi | Out-Null } catch {} })

$state = Update-ProStudioUi

if ($RenderPreviewPath) {
  $dir = Split-Path -Parent $RenderPreviewPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $width = [int]$window.Width
  $height = [int]$window.Height
  $window.Left = -32000
  $window.Top = -32000
  $window.Show()
  $window.Activate() | Out-Null
  $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
  Start-Sleep -Milliseconds 350
  $window.UpdateLayout()
  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($window)
  $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $fs = [System.IO.File]::Open($RenderPreviewPath, [System.IO.FileMode]::Create)
  try { $encoder.Save($fs) } finally { $fs.Dispose() }
  $window.Close()
  Write-Host "RENDER PREVIEW OK: $RenderPreviewPath"
  exit 0
}

if ($SelfTest) {
  Write-Host 'BuildWIM Pro Studio Neon self-test'
  Write-Host "Root=$($state.Root)"
  Write-Host "Score=$($state.Score)"
  Write-Host "Admin=$($state.Admin)"
  Write-Host "DismOk=$($state.DismOk)"
  Write-Host "ScriptOk=$($state.ScriptOk)"
  Write-Host "Inputs=$($state.Inputs.Count)"
  Write-Host "Updates=$($state.Updates.Count)"
  Write-Host "MountClean=$($state.MountClean)"
  Write-Host "Command=$($script:TxtCommand.Text)"

  $fail = @()
  if (-not $state.DismOk) { $fail += 'DISM missing' }
  if (-not $state.ScriptOk) { $fail += 'Build-WIM.ps1 missing' }
  if ($script:TxtCommand.Text -notmatch 'Build-WIM.ps1') { $fail += 'Command preview invalid' }
  if ($state.Inputs.Count -lt 1) { $fail += 'No input image found' }
  if ($fail.Count -gt 0) {
    Write-Host 'SELFTEST FAILED'
    $fail | ForEach-Object { Write-Host " - $_" }
    exit 1
  }
  Write-Host 'SELFTEST OK'
  exit 0
}

[void]$window.ShowDialog()
