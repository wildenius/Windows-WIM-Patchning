<#
.SYNOPSIS
  Bootstrap/installation for BuildWIM solution.

.DESCRIPTION
  - Creates folder structure under C:\BuildWimV2\
  - Copies scripts + default config to C:\BuildWimV2\
  - Optionally installs Windows ADK + WinPE Add-on from C:\tmp\ for broader deployment/WinPE workflows

.NOTES
  Version: 1.0.0
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Root = 'C:\BuildWimV2',
  [string]$SourceDir = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [switch]$InstallAdk,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function New-Dir {
  param([Parameter(Mandatory)] [string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Copy-ItemSafe {
  param(
    [Parameter(Mandatory)] [string]$From,
    [Parameter(Mandatory)] [string]$To
  )
  if (-not (Test-Path -LiteralPath $From)) {
    throw "Source file missing: $From"
  }
  $destDir = Split-Path -Parent $To
  New-Dir -Path $destDir
  if ((Test-Path -LiteralPath $To) -and -not $Force) {
    return
  }
  Copy-Item -LiteralPath $From -Destination $To -Force
}

function Install-AdkIfRequested {
  param([switch]$DoInstall)

  if (-not $DoInstall) { return }

  $adk = 'C:\tmp\adksetup.exe'
  $winpe = 'C:\tmp\adkwinpesetup.exe'

  if (-not (Test-Path -LiteralPath $adk)) {
    throw "ADK installer not found at $adk"
  }
  if (-not (Test-Path -LiteralPath $winpe)) {
    throw "ADK WinPE Add-on installer not found at $winpe"
  }

  # ADK/WinPE is not required for offline WIM servicing. Install only when you also need WinPE/deployment tooling.
  $adkArgs = @(
    '/quiet',
    '/norestart',
    '/ceip',
    'off',
    '/features',
    "OptionId.DeploymentTools"
  )

  $winpeArgs = @(
    '/quiet',
    '/norestart',
    '/ceip',
    'off',
    '/features',
    "OptionId.WindowsPreinstallationEnvironment"
  )

  Write-Host "Installing Windows ADK (Deployment Tools)..." -ForegroundColor Cyan
  $p1 = Start-Process -FilePath $adk -ArgumentList $adkArgs -Wait -PassThru
  if ($p1.ExitCode -ne 0) { throw "ADK installer failed with exit code $($p1.ExitCode)" }

  Write-Host "Installing Windows ADK WinPE Add-on..." -ForegroundColor Cyan
  $p2 = Start-Process -FilePath $winpe -ArgumentList $winpeArgs -Wait -PassThru
  if ($p2.ExitCode -ne 0) { throw "WinPE installer failed with exit code $($p2.ExitCode)" }
}

if (-not (Test-IsAdministrator)) {
  throw 'Run this script as Administrator.'
}

$folders = @(
  'Input','Updates','Mount','Output','Logs','Temp','Tools','Config','Reports','docs'
)

New-Dir -Path $Root
foreach ($f in $folders) { New-Dir -Path (Join-Path $Root $f) }

# Copy payload
$payloadFiles = @(
  'Install-BuildWIM.ps1',
  'Build-WIM.ps1',
  'Get-Windows11Iso.ps1',
  'Get-LatestWindows11LCU.ps1',
  'Start-BuildWIM-GUI.ps1',
  'Start-BuildWIM-MissionControl.ps1',
  'Start-BuildWIM-ProStudio.ps1',
  'Start-BuildWIM-ProStudio-Sexy.ps1',
  'README.md'
)

foreach ($file in $payloadFiles) {
  Copy-ItemSafe -From (Join-Path $SourceDir $file) -To (Join-Path $Root $file)
}

Copy-ItemSafe -From (Join-Path $SourceDir 'Config\buildwim.config.json') -To (Join-Path $Root 'Config\buildwim.config.json')

$docsDir = Join-Path $SourceDir 'docs'
if (Test-Path -LiteralPath $docsDir) {
  Get-ChildItem -LiteralPath $docsDir -File -Filter '*.md' | ForEach-Object {
    Copy-ItemSafe -From $_.FullName -To (Join-Path (Join-Path $Root 'docs') $_.Name)
  }
}

Install-AdkIfRequested -DoInstall:$InstallAdk

Write-Host "BuildWIM installed to $Root" -ForegroundColor Green
Write-Host "Next: put ISO/WIM/ESD in $Root\Input and updates in $Root\Updates, then run:" -ForegroundColor Green
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File $Root\Build-WIM.ps1" -ForegroundColor Yellow
