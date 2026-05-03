<#
.SYNOPSIS
    Downloads the official Windows 11 ISO from Microsoft's software download service.

.DESCRIPTION
    Automates the same Microsoft flow used by:
    https://www.microsoft.com/en-us/software-download/windows11

    The script resolves the current Windows 11 ISO SKU/language through Microsoft's
    software-download-connector API, obtains the temporary download URL, downloads
    the ISO, calculates SHA256, and writes a small metadata sidecar.

    No third-party ISO mirrors are used.

.EXAMPLE
    .\Get-Windows11Iso.ps1 -OutputDirectory C:\BuildWimV2\Input

.EXAMPLE
    .\Get-Windows11Iso.ps1 -Language 'English' -OutputDirectory C:\BuildWimV2\Input -Force

.EXAMPLE
    .\Get-Windows11Iso.ps1 -LinkOnly
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory,

    # Microsoft language display name from the Windows 11 ISO language picker.
    [string]$Language = 'English International',

    # Windows 11 x64 multi-edition ISO product edition id from Microsoft's page.
    [string]$ProductEditionId = '3321',

    [string]$Locale = 'en-us',

    [switch]$Force,

    # Resolve and print the temporary Microsoft download URL, but do not download the ISO.
    [switch]$LinkOnly,

    [int]$TimeoutSec = 30,

    # Avoid burning more Microsoft Sentinel attempts immediately after a rejection.
    [int]$SentinelCooldownMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $OutputDirectory = Join-Path $scriptRoot 'Input'
}

$MicrosoftPage = 'https://www.microsoft.com/en-us/software-download/windows11'
$ApiBase = 'https://www.microsoft.com/software-download-connector/api'
$OrgId = 'y6jn8c31'
$ProfileId = '606624d44113'
$InstanceId = '560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175'
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123 Safari/537.36'
$script:WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$script:WebSession.UserAgent = $UserAgent

function Write-Step {
    param([string]$Message)
    Write-Host "[Windows11 ISO] $Message" -ForegroundColor Cyan
}

$script:DownloadStartUtc = [DateTimeOffset]::UtcNow
$script:SentinelBlocks = @()

function Get-ShortDuration {
    param([TimeSpan]$Duration)

    if ($Duration.TotalHours -ge 1) { return ('{0:N1} h' -f $Duration.TotalHours) }
    if ($Duration.TotalMinutes -ge 1) { return ('{0:N1} min' -f $Duration.TotalMinutes) }
    return ('{0:N0} sec' -f [Math]::Max(0, $Duration.TotalSeconds))
}

function Write-IsoDownloaderFailureState {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [string]$SessionId,
        [string]$Message,
        [int]$Attempt = 0,
        [int]$Attempts = 0
    )

    try {
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        }

        $now = [DateTimeOffset]::UtcNow
        $firstBlock = $null
        $blockedFor = $null
        if ($script:SentinelBlocks.Count -gt 0) {
            $firstBlock = $script:SentinelBlocks[0].AtUtc
            $blockedFor = Get-ShortDuration -Duration ($now - [DateTimeOffset]$firstBlock)
        }

        [pscustomobject]@{
            Reason = $Reason
            Message = $Message
            SessionId = $SessionId
            Attempt = $Attempt
            Attempts = $Attempts
            StartedUtc = $script:DownloadStartUtc.ToString('o')
            LastSeenUtc = $now.ToString('o')
            Elapsed = Get-ShortDuration -Duration ($now - $script:DownloadStartUtc)
            FirstSentinelBlockUtc = if ($firstBlock) { ([DateTimeOffset]$firstBlock).ToString('o') } else { $null }
            SentinelBlockedFor = $blockedFor
            SentinelBlockCount = $script:SentinelBlocks.Count
            Advice = @(
                'Microsoft Sentinel/anti-abuse rejected temporary ISO link generation before the ISO download started.',
                'This is usually a Microsoft/network reputation or rate-limit block, not a broken ISO file.',
                'Use an existing local ISO in Input, try again later, or run the ISO download from another network/VPN.'
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'windows11-iso-download-error.json') -Encoding UTF8
    } catch {
        # Failure-state writing must never hide the real downloader error.
    }
}

function Test-SentinelCooldown {
    if ($Force -or $SentinelCooldownMinutes -le 0) { return }

    $statePath = Join-Path $OutputDirectory 'windows11-iso-download-error.json'
    if (-not (Test-Path -LiteralPath $statePath)) { return }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.Reason -ne 'MicrosoftSentinelRejected' -or -not $state.LastSeenUtc) { return }

        $lastSeen = [DateTimeOffset]::Parse([string]$state.LastSeenUtc)
        $age = [DateTimeOffset]::UtcNow - $lastSeen
        $cooldown = [TimeSpan]::FromMinutes($SentinelCooldownMinutes)
        if ($age -lt $cooldown) {
            $remaining = Get-ShortDuration -Duration ($cooldown - $age)
            $blockedFor = if ($state.SentinelBlockedFor) { $state.SentinelBlockedFor } else { Get-ShortDuration -Duration $age }
            throw "Microsoft Sentinel blocked the previous Windows 11 ISO link-generation attempt recently. Cooldown remaining: $remaining. Previously blocked for: $blockedFor. Not retrying yet because repeated immediate attempts usually extend the block. Put an ISO in $OutputDirectory, wait and retry, use -Force to override cooldown, or run from another network/VPN."
        }
    } catch {
        if ($_.Exception.Message -match 'Microsoft Sentinel blocked the previous') { throw }
    }
}

function New-SentinelRejectedMessage {
    param(
        [string]$SessionId,
        [int]$Attempt = 0,
        [int]$Attempts = 0
    )

    $now = [DateTimeOffset]::UtcNow
    $alreadyRecorded = @($script:SentinelBlocks | Where-Object { $_.SessionId -eq $SessionId -and $_.Attempt -eq $Attempt }).Count -gt 0
    if (-not $alreadyRecorded) {
        $script:SentinelBlocks += [pscustomobject]@{ AtUtc = $now; SessionId = $SessionId; Attempt = $Attempt }
    }
    $blockedFor = Get-ShortDuration -Duration ($now - [DateTimeOffset]$script:SentinelBlocks[0].AtUtc)
    $elapsed = Get-ShortDuration -Duration ($now - $script:DownloadStartUtc)
    $attemptText = if ($Attempt -gt 0 -and $Attempts -gt 0) { " Attempt $Attempt/$Attempts." } else { '' }

    return "Microsoft Sentinel rejected the temporary Windows 11 ISO link request for session $SessionId.$attemptText Blocked for: $blockedFor. Total resolver time: $elapsed. Cause: Microsoft accepted the language lookup but denied link generation, usually because this public IP/session hit Microsoft's anti-abuse/rate-limit rules. Fix: reuse a local ISO in Input, wait before retrying, or run the ISO download from another network/VPN."
}


function Write-IsoDownloaderFriendlyError {
    param([Parameter(Mandatory)]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    $statePath = Join-Path $OutputDirectory 'windows11-iso-download-error.json'
    $state = $null
    if (Test-Path -LiteralPath $statePath) {
        try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { $state = $null }
    }

    Write-Host ''
    Write-Host '+--------------------------------------------------------------------+' -ForegroundColor Red
    Write-Host '| Windows 11 ISO download stopped                                    |' -ForegroundColor Red
    Write-Host '+--------------------------------------------------------------------+' -ForegroundColor Red

    if ($message -match 'Microsoft Sentinel|anti-abuse|rate-limit|link-generation') {
        Write-Host 'Microsoft rejected the temporary ISO download-link request.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'What happened:' -ForegroundColor White
        Write-Host '  - BuildWIM reached Microsoft and the language/SKU lookup worked.' -ForegroundColor Gray
        Write-Host '  - The next step asks Microsoft for a short-lived ISO URL.' -ForegroundColor Gray
        Write-Host '  - Microsoft Sentinel / anti-abuse denied that URL for this session/network.' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Most likely cause:' -ForegroundColor White
        Write-Host '  Public IP reputation, too many repeated attempts, VPN/proxy/datacenter egress,' -ForegroundColor Gray
        Write-Host '  or Microsoft temporarily rate-limiting the software-download endpoint.' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'This is not a broken WIM, bad ISO, or failed KB injection.' -ForegroundColor Green
        Write-Host ''
        Write-Host 'Recommended fixes:' -ForegroundColor White
        Write-Host "  1. Put an official Windows 11 ISO/WIM/ESD in: $OutputDirectory" -ForegroundColor Gray
        Write-Host '  2. Wait before retrying; immediate repeats often keep the block warm.' -ForegroundColor Gray
        Write-Host '  3. Try from another network/VPN path if Microsoft keeps rejecting this IP.' -ForegroundColor Gray
        Write-Host '  4. Use -Force only when you deliberately want to ignore the local cooldown.' -ForegroundColor Gray

        if ($state) {
            Write-Host ''
            Write-Host 'Diagnostic details:' -ForegroundColor White
            if ($state.SessionId) { Write-Host "  Session : $($state.SessionId)" -ForegroundColor DarkGray }
            if ($state.Attempt -and $state.Attempts) { Write-Host "  Attempt : $($state.Attempt)/$($state.Attempts)" -ForegroundColor DarkGray }
            if ($state.SentinelBlockedFor) { Write-Host "  Blocked : $($state.SentinelBlockedFor)" -ForegroundColor DarkGray }
            Write-Host "  State   : $statePath" -ForegroundColor DarkGray
        }
    } else {
        Write-Host $message -ForegroundColor Yellow
        Write-Host ''
        Write-Host "State file, if present: $statePath" -ForegroundColor DarkGray
    }

    Write-Host ''
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
        'software-download.microsoft.com',
        'download.microsoft.com',
        'windowsupdate.com',
        'download.windowsupdate.com',
        'delivery.mp.microsoft.com',
        'dl.delivery.mp.microsoft.com'
    )
    foreach ($suffix in $trustedSuffixes) {
        if ($uriHost -eq $suffix -or $uriHost.EndsWith(".$suffix", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Invoke-MicrosoftRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [switch]$Rest
    )

    $mergedHeaders = @{ 'User-Agent' = $UserAgent }
    foreach ($key in $Headers.Keys) { $mergedHeaders[$key] = $Headers[$key] }

    if ($Rest) {
        return Invoke-RestMethod -UseBasicParsing -TimeoutSec $TimeoutSec -Headers $mergedHeaders -WebSession $script:WebSession -Uri $Uri
    }

    return Invoke-WebRequest -UseBasicParsing -TimeoutSec $TimeoutSec -Headers $mergedHeaders -WebSession $script:WebSession -Uri $Uri
}

function Initialize-MicrosoftDownloadSession {
    $script:WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $script:WebSession.UserAgent = $UserAgent
    $sessionId = [guid]::NewGuid().ToString()

    Write-Step "Initializing Microsoft download session $sessionId"

    # The ISO API rejects download-link requests unless the session has passed
    # Microsoft's lightweight anti-abuse handshakes. These are the same first-party
    # services loaded by the Microsoft download page.
    $tagsUrl = "https://vlscppe.microsoft.com/tags?org_id=$([uri]::EscapeDataString($OrgId))&session_id=$sessionId"
    Invoke-MicrosoftRequest -Uri $tagsUrl | Out-Null

    $mdtUrl = "https://ov-df.microsoft.com/mdt.js?instanceId=$InstanceId&PageId=si&session_id=$sessionId"
    $mdt = Invoke-MicrosoftRequest -Uri $mdtUrl
    $mdtText = [string]$mdt.Content

    $w = $null
    $rticks = $null
    if ($mdtText -match '[?&]w=([A-Fa-f0-9]+)') { $w = $Matches[1] }
    if ($mdtText -match 'rticks\s*=\s*"?\+?(\d+)') { $rticks = $Matches[1] }

    if (-not $w -or -not $rticks) {
        throw "Could not extract Microsoft ov-df handshake values. The download page protocol may have changed."
    }

    $epochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $replyUrl = "https://ov-df.microsoft.com/?session_id=$sessionId&CustomerId=$InstanceId&PageId=si&w=$w&mdt=$epochMs&rticks=$rticks"
    Invoke-MicrosoftRequest -Uri $replyUrl | Out-Null

    return $sessionId
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$Attempts = 3,
        [int]$DelaySeconds = 2
    )

    $lastError = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            return & $ScriptBlock
        } catch {
            $lastError = $_
            if ($i -lt $Attempts) {
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }

    throw $lastError
}

function Get-Windows11IsoSku {
    param([string]$SessionId)

    $uri = "$ApiBase/getskuinformationbyproductedition?profile=$ProfileId&productEditionId=$([uri]::EscapeDataString($ProductEditionId))&SKU=undefined&friendlyFileName=undefined&Locale=$([uri]::EscapeDataString($Locale))&sessionID=$SessionId"
    Write-Step "Querying Microsoft ISO languages for product edition $ProductEditionId"

    $response = Invoke-WithRetry -ScriptBlock {
        Invoke-MicrosoftRequest -Uri $uri -Headers @{ Referer = $MicrosoftPage } -Rest
    }

    if ($response.PSObject.Properties['Errors'] -and $response.Errors) {
        $message = ($response.Errors | Select-Object -First 1).Value
        throw "Microsoft returned an error while resolving languages: $message"
    }

    $skus = @($response.Skus)
    if (-not $skus -or $skus.Count -eq 0) {
        throw 'Microsoft returned no Windows 11 ISO SKUs.'
    }

    $exact = @($skus | Where-Object { $_.Language -eq $Language -or $_.LocalizedLanguage -eq $Language })
    if ($exact.Count -gt 0) { return $exact[0] }

    $contains = @($skus | Where-Object { $_.Language -like "*$Language*" -or $_.LocalizedLanguage -like "*$Language*" })
    if ($contains.Count -gt 0) { return $contains[0] }

    $available = ($skus | Select-Object -ExpandProperty Language | Sort-Object) -join ', '
    throw "Language '$Language' was not found. Available languages: $available"
}

function Get-Windows11IsoDownloadOption {
    param(
        [string]$SessionId,
        [Parameter(Mandatory)]$Sku,
        [int]$Attempt = 0,
        [int]$Attempts = 0
    )

    $uri = "$ApiBase/GetProductDownloadLinksBySku?profile=$ProfileId&productEditionId=undefined&SKU=$($Sku.Id)&friendlyFileName=undefined&Locale=$([uri]::EscapeDataString($Locale))&sessionID=$SessionId"
    Write-Step "Requesting temporary Microsoft ISO download link for SKU $($Sku.Id) / $($Sku.Language)"

    $response = Invoke-WithRetry -ScriptBlock {
        Invoke-MicrosoftRequest -Uri $uri -Headers @{ Referer = $MicrosoftPage } -Rest
    }

    if ($response.PSObject.Properties['Errors'] -and $response.Errors) {
        $errorItem = $response.Errors | Select-Object -First 1
        if ($errorItem.Type -eq 9) {
            $message = New-SentinelRejectedMessage -SessionId $SessionId -Attempt $Attempt -Attempts $Attempts
            Write-IsoDownloaderFailureState -Reason 'MicrosoftSentinelRejected' -SessionId $SessionId -Message $message -Attempt $Attempt -Attempts $Attempts
            throw $message
        }
        throw "Microsoft returned an error while resolving download URL: $($errorItem.Value)"
    }

    $options = @($response.ProductDownloadOptions)
    if (-not $options -or $options.Count -eq 0) {
        throw 'Microsoft returned no ISO download options.'
    }

    $x64 = @($options | Where-Object { $_.DownloadType -match '64|x64' -or $_.Name -match 'x64|amd64' -or $_.Uri -match 'x64|amd64' })
    if ($x64.Count -gt 0) { return $x64[0] }

    return $options[0]
}

function Get-IsoFileName {
    param(
        [Parameter(Mandatory)]$Sku,
        $DownloadOption = $null
    )

    $fileName = $null
    if ($Sku.PSObject.Properties['FriendlyFileNames'] -and $Sku.FriendlyFileNames -and $Sku.FriendlyFileNames.Count -gt 0) {
        $fileName = [string]$Sku.FriendlyFileNames[0]
    }
    if (-not $fileName -and $DownloadOption -and $DownloadOption.PSObject.Properties['Uri']) {
        $fileName = [IO.Path]::GetFileName(([uri]$DownloadOption.Uri).AbsolutePath)
    }
    if (-not $fileName -or -not $fileName.EndsWith('.iso', [StringComparison]::OrdinalIgnoreCase)) {
        $safeLanguage = ($Sku.Language -replace '[^A-Za-z0-9]+', '')
        $fileName = "Win11_$safeLanguage.iso"
    }

    return $fileName
}

function Test-UriNotExpired {
    param([string]$Uri)

    if ([string]::IsNullOrWhiteSpace($Uri)) { return $false }
    if ($Uri -notmatch '[?&]P1=(\d+)') { return $true }

    $expiresUnix = [int64]$Matches[1]
    $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return ($expiresUnix -gt ($nowUnix + 300))
}

function Get-CompatibleExistingIso {
    param([string]$ExpectedFileName)

    if (-not (Test-Path -LiteralPath $OutputDirectory)) { return $null }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedFileName)) {
        $exactPath = Join-Path $OutputDirectory $ExpectedFileName
        if (Test-Path -LiteralPath $exactPath) {
            return Get-Item -LiteralPath $exactPath
        }
    }

    $languageTokens = @($Language -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -replace '[^A-Za-z0-9]', '') })
    $candidates = @(Get-ChildItem -LiteralPath $OutputDirectory -File -Filter '*.iso' -ErrorAction SilentlyContinue |
        Where-Object {
            $name = $_.Name
            if ($name -notmatch 'Win11' -or $name -notmatch 'x64') { return $false }
            foreach ($token in $languageTokens) {
                if ($token -and $name -notmatch [regex]::Escape($token)) { return $false }
            }
            return $true
        } |
        Sort-Object LastWriteTimeUtc -Descending)

    if ($candidates.Count -gt 0) { return $candidates[0] }
    return $null
}

function Get-CachedDownloadOption {
    param([string]$ExpectedFileName)

    if (-not (Test-Path -LiteralPath $OutputDirectory)) { return $null }

    $metadataCandidates = @()
    $exactMetadata = Join-Path $OutputDirectory "$ExpectedFileName.metadata.json"
    if (Test-Path -LiteralPath $exactMetadata) { $metadataCandidates += Get-Item -LiteralPath $exactMetadata }
    $metadataCandidates += @(Get-ChildItem -LiteralPath $OutputDirectory -File -Filter '*.iso.metadata.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)

    foreach ($metadata in ($metadataCandidates | Select-Object -Unique)) {
        try {
            $json = Get-Content -LiteralPath $metadata.FullName -Raw | ConvertFrom-Json
            if (-not $json.PSObject.Properties['Uri'] -or [string]::IsNullOrWhiteSpace($json.Uri)) { continue }
            if (-not (Test-UriNotExpired -Uri ([string]$json.Uri))) { continue }
            if (-not (Test-TrustedMicrosoftDownloadUrl -Url ([string]$json.Uri))) { continue }
            if ($json.PSObject.Properties['Language'] -and $json.Language -and $json.Language -ne $Language) { continue }

            Write-Step "Using cached Microsoft temporary download link from $($metadata.Name)"
            return [pscustomobject]@{
                Name = if ($json.PSObject.Properties['FriendlyFileName']) { $json.FriendlyFileName } else { $ExpectedFileName }
                Uri = [string]$json.Uri
                DownloadType = if ($json.PSObject.Properties['DownloadType']) { $json.DownloadType } else { $null }
            }
        } catch {
            continue
        }
    }

    return $null
}

function Complete-ExistingIso {
    param(
        [Parameter(Mandatory)]$File,
        $Sku = $null,
        [string]$SessionId
    )

    Write-Step "ISO already exists: $($File.FullName)"
    Write-Step 'Skipping Microsoft checks and temporary download-link request. Use -Force to re-download.'

    if (-not $Sku) {
        $Sku = [pscustomobject]@{
            Id = $null
            Language = $Language
            LocalizedLanguage = $Language
            ProductDisplayName = 'Windows 11'
            FriendlyFileNames = @($File.Name)
        }
    }

    $hash = Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256
    $result = New-BaseResult -Sku $Sku -SessionId $SessionId
    $result['FriendlyFileName'] = $File.Name
    $result['Path'] = $File.FullName
    $result['SizeBytes'] = $File.Length
    $result['SHA256'] = $hash.Hash
    $result['AlreadyExists'] = $true

    $metadataPath = "$($File.FullName).metadata.json"
    [pscustomobject]$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataPath -Encoding UTF8

    Write-Host ''
    Write-Host 'Windows 11 ISO already exists.' -ForegroundColor Green
    Write-Host "Path   : $($File.FullName)"
    Write-Host "Size   : $($File.Length) bytes"
    Write-Host "SHA256 : $($hash.Hash)"
    Write-Host "Meta   : $metadataPath"
}

function Save-IsoFile {
    param(
        [Parameter(Mandatory)]$DownloadOption,
        [Parameter(Mandatory)]$Sku
    )

    if (-not (Test-TrustedMicrosoftDownloadUrl -Url ([string]$DownloadOption.Uri))) {
        throw "Refusing untrusted Microsoft ISO download URL: $($DownloadOption.Uri)"
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $fileName = Get-IsoFileName -Sku $Sku -DownloadOption $DownloadOption
    $destination = Join-Path $OutputDirectory $fileName

    Write-Step "Downloading $fileName"
    Write-Step "Destination: $destination"

    $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
    if ($bits) {
        Start-BitsTransfer -Source $DownloadOption.Uri -Destination $destination -DisplayName "Windows 11 ISO" -Description $fileName
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri $DownloadOption.Uri -OutFile $destination -Headers @{ 'User-Agent' = $UserAgent } -TimeoutSec 0
    }

    return Get-Item -LiteralPath $destination
}

function New-BaseResult {
    param(
        [Parameter(Mandatory)]$Sku,
        [string]$SessionId,
        $DownloadOption = $null
    )

    $downloadType = $null
    $uri = $null
    if ($DownloadOption) {
        if ($DownloadOption.PSObject.Properties['DownloadType']) { $downloadType = $DownloadOption.DownloadType }
        if ($DownloadOption.PSObject.Properties['Uri']) { $uri = $DownloadOption.Uri }
    }

    return [ordered]@{
        ProductEditionId = $ProductEditionId
        SkuId = $Sku.Id
        Language = $Sku.Language
        LocalizedLanguage = $Sku.LocalizedLanguage
        ProductDisplayName = $Sku.ProductDisplayName
        FriendlyFileName = Get-IsoFileName -Sku $Sku -DownloadOption $DownloadOption
        DownloadType = $downloadType
        Uri = $uri
        SessionId = $sessionId
        ResolvedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

try {
# Fast offline/idempotent path: if a compatible ISO already exists, do not call
# Microsoft at all. This avoids unnecessary Sentinel/link-generation exposure and
# makes repeated runs effectively free.
if (-not $LinkOnly -and -not $Force) {
    $existingIso = Get-CompatibleExistingIso -ExpectedFileName ''
    if ($existingIso) {
        Complete-ExistingIso -File $existingIso
        return
    }
}

# If Microsoft just rate-limited this network/session, fail fast with a useful
# cooldown message instead of burning three more sessions and making the block worse.
Test-SentinelCooldown

$sessionId = Initialize-MicrosoftDownloadSession
$sku = Get-Windows11IsoSku -SessionId $sessionId
$fileName = Get-IsoFileName -Sku $sku
$destination = Join-Path $OutputDirectory $fileName

# Important: avoid requesting a fresh temporary Microsoft download URL when an ISO
# is already present. Repeated link generation can trigger Microsoft Sentinel even
# though no download is needed. Accept the exact current filename or a compatible
# existing Windows 11 x64 ISO for the requested language (for example a non-v2 ISO).
if (-not $LinkOnly -and -not $Force) {
    $existingIso = Get-CompatibleExistingIso -ExpectedFileName $fileName
    if ($existingIso) {
        Complete-ExistingIso -File $existingIso -Sku $sku -SessionId $sessionId
        return
    }
}

$downloadOption = $null
$cachedDownloadOption = $null
if (-not $Force) {
    $cachedDownloadOption = Get-CachedDownloadOption -ExpectedFileName $fileName
    if ($cachedDownloadOption) {
        $downloadOption = $cachedDownloadOption
    }
}

$lastDownloadLinkError = $null
if (-not $downloadOption) {
    $maxDownloadLinkAttempts = 3
    for ($attempt = 1; $attempt -le $maxDownloadLinkAttempts; $attempt++) {
        try {
            if ($attempt -gt 1) {
                $blockedForText = if ($script:SentinelBlocks.Count -gt 0) {
                    Get-ShortDuration -Duration ([DateTimeOffset]::UtcNow - [DateTimeOffset]$script:SentinelBlocks[0].AtUtc)
                } else {
                    'unknown'
                }
                Write-Step "Retrying Microsoft download-link request with a fresh session ($attempt/$maxDownloadLinkAttempts; blocked for $blockedForText)"
                Start-Sleep -Seconds (5 * $attempt)
                $sessionId = Initialize-MicrosoftDownloadSession
                $sku = Get-Windows11IsoSku -SessionId $sessionId
            }
            $downloadOption = Get-Windows11IsoDownloadOption -SessionId $sessionId -Sku $sku -Attempt $attempt -Attempts $maxDownloadLinkAttempts
            break
        } catch {
            $lastDownloadLinkError = $_
            if ($attempt -eq $maxDownloadLinkAttempts) {
                if ($script:SentinelBlocks.Count -gt 0) {
                    $message = New-SentinelRejectedMessage -SessionId $sessionId -Attempt $attempt -Attempts $maxDownloadLinkAttempts
                    Write-IsoDownloaderFailureState -Reason 'MicrosoftSentinelRejected' -SessionId $sessionId -Message $message -Attempt $attempt -Attempts $maxDownloadLinkAttempts
                    throw $message
                }
                Write-IsoDownloaderFailureState -Reason 'DownloadLinkResolutionFailed' -SessionId $sessionId -Message $lastDownloadLinkError.Exception.Message -Attempt $attempt -Attempts $maxDownloadLinkAttempts
                throw
            }
        }
    }
}

$result = New-BaseResult -Sku $sku -SessionId $sessionId -DownloadOption $downloadOption

Write-Step "Resolved: $($result.FriendlyFileName) [$($result.Language)]"
Write-Step 'Microsoft temporary links usually expire after 24 hours.'

if ($LinkOnly) {
    [pscustomobject]$result | Format-List
    return
}

$file = Save-IsoFile -DownloadOption $downloadOption -Sku $sku
$hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256

$result['Path'] = $file.FullName
$result['SizeBytes'] = $file.Length
$result['SHA256'] = $hash.Hash
$result['AlreadyExists'] = $false

$metadataPath = "$($file.FullName).metadata.json"
[pscustomobject]$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataPath -Encoding UTF8

Write-Host ''
Write-Host 'Windows 11 ISO downloaded successfully.' -ForegroundColor Green
Write-Host "Path   : $($file.FullName)"
Write-Host "Size   : $($file.Length) bytes"
Write-Host "SHA256 : $($hash.Hash)"
Write-Host "Meta   : $metadataPath"

} catch {
    Write-IsoDownloaderFriendlyError -ErrorRecord $_
    exit 1
}
