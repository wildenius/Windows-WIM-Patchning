<#
.SYNOPSIS
  Bootstrap/installation for BuildWIM solution.

.DESCRIPTION
  - Creates folder structure under C:\BuildWimV2\
  - Copies scripts + default config to C:\BuildWimV2\
  - Optionally installs Windows ADK + WinPE Add-on from C:\tmp\ for broader deployment/WinPE workflows

.NOTES
  Version: 1.0.1
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Root = 'C:\BuildWimV2',
  [string]$SourceDir,
  [switch]$InstallAdk,
  [string]$AdkSetupPath,
  [string]$AdkWinPeSetupPath,
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
  Assert-NoReparsePointPath -Path $Path -StopAt $Root
}

function Assert-NoReparsePointPath {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$StopAt
  )

  $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  $stopPath = [IO.Path]::GetFullPath($StopAt).TrimEnd('\')
  if (-not ($fullPath.Equals($stopPath, [StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($stopPath + '\', [StringComparison]::OrdinalIgnoreCase))) {
    throw "Path is outside expected root: $fullPath (root: $stopPath)"
  }

  $current = $fullPath
  while ($current -and ($current.Equals($stopPath, [StringComparison]::OrdinalIgnoreCase) -or $current.StartsWith($stopPath + '\', [StringComparison]::OrdinalIgnoreCase))) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing reparse point/junction/symlink under BuildWIM root: $current"
      }
    }
    if ($current.Equals($stopPath, [StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = Split-Path -Parent $current
    if ($parent -eq $current) { break }
    $current = $parent
  }
}

function Assert-TrustedMicrosoftInstaller {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Name
  )

  if (-not (Test-Path -LiteralPath $Path)) { throw "$Name installer not found: $Path" }
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Name installer must not be a reparse point: $Path" }
  $sig = Get-AuthenticodeSignature -LiteralPath $Path
  if ($sig.Status -ne 'Valid') { throw "$Name installer is not Authenticode-valid: $Path (status: $($sig.Status))" }
  $subject = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
  $issuer = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Issuer } else { '' }
  if (($subject -notmatch '(?i)Microsoft') -and ($issuer -notmatch '(?i)Microsoft')) {
    throw "$Name installer is signed, but not by Microsoft: subject=$subject issuer=$issuer"
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

  if ([string]::IsNullOrWhiteSpace($AdkSetupPath) -or [string]::IsNullOrWhiteSpace($AdkWinPeSetupPath)) {
    throw 'InstallAdk requires explicit -AdkSetupPath and -AdkWinPeSetupPath. Download the current ADK installers from Microsoft, store them in a locked admin-owned folder, then rerun.'
  }

  $adk = $AdkSetupPath
  $winpe = $AdkWinPeSetupPath
  Assert-TrustedMicrosoftInstaller -Path $adk -Name 'Windows ADK'
  Assert-TrustedMicrosoftInstaller -Path $winpe -Name 'Windows ADK WinPE Add-on'

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

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
  if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $SourceDir = $PSScriptRoot
  } elseif ($MyInvocation.MyCommand.Path) {
    $SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
  } else {
    $SourceDir = (Get-Location).Path
  }
}

$folders = @(
  'Input','Updates','Mount','Output','Logs','Temp','Tools','Config','Reports'
)

New-Dir -Path $Root
foreach ($f in $folders) { New-Dir -Path (Join-Path $Root $f) }

# Copy payload
$payloadFiles = @(
  'Install-BuildWIM.ps1',
  'Build-WIM.ps1',
  'Resolve-BuildWimMicrosoftEsd.ps1',
  'Get-Windows11Iso.ps1',
  'Get-LatestWindows11LCU.ps1'
)

foreach ($file in $payloadFiles) {
  Copy-ItemSafe -From (Join-Path $SourceDir $file) -To (Join-Path $Root $file)
}

Copy-ItemSafe -From (Join-Path $SourceDir 'Config\buildwim.config.json') -To (Join-Path $Root 'Config\buildwim.config.json')
foreach ($policyFile in @('approved-sources.json','approved-updates-policy.json')) {
  $srcPolicy = Join-Path $SourceDir "Config\$policyFile"
  if (Test-Path -LiteralPath $srcPolicy) {
    Copy-ItemSafe -From $srcPolicy -To (Join-Path $Root "Config\$policyFile")
  }
}

Install-AdkIfRequested -DoInstall:$InstallAdk

Write-Host "BuildWIM installed to $Root" -ForegroundColor Green
Write-Host "Next: put ISO/WIM/ESD in $Root\Input and updates in $Root\Updates, then run:" -ForegroundColor Green
Write-Host "  powershell -NoProfile -File $Root\Build-WIM.ps1" -ForegroundColor Yellow
