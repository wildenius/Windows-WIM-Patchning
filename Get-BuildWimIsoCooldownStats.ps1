<#
.SYNOPSIS
    Summarizes BuildWIM Windows 11 ISO Sentinel/cooldown history.

.DESCRIPTION
    Reads the append-only JSONL history written by Get-Windows11Iso.ps1 and
    reports observed Microsoft Sentinel rejections, successful retries, and
    local cooldown state. This measures observed behaviour only; Microsoft does
    not expose its internal Sentinel/rate-limit timer or Retry-After value here.

.EXAMPLE
    .\Get-BuildWimIsoCooldownStats.ps1

.EXAMPLE
    .\Get-BuildWimIsoCooldownStats.ps1 -SinceDays 7 -AsJson
#>
[CmdletBinding()]
param(
    [string]$HistoryPath = 'C:\BuildWimV2\Logs\windows11-iso-sentinel-history.jsonl',
    [int]$SinceDays = 30,
    [int]$CooldownMinutes = 30,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-Duration {
    param([AllowNull()] [Nullable[double]]$Seconds)
    if ($null -eq $Seconds) { return 'n/a' }
    if ($Seconds -ge 3600) { return ('{0:N1} h' -f ($Seconds / 3600)) }
    if ($Seconds -ge 60) { return ('{0:N1} min' -f ($Seconds / 60)) }
    return ('{0:N0} sec' -f $Seconds)
}

function Get-Percentile {
    param(
        [AllowEmptyCollection()] [double[]]$Values = @(),
        [double]$Percentile = 0.5
    )
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) { return [double]$sorted[0] }
    $index = [Math]::Ceiling($Percentile * $sorted.Count) - 1
    $index = [Math]::Max(0, [Math]::Min($sorted.Count - 1, $index))
    return [double]$sorted[$index]
}

if (-not (Test-Path -LiteralPath $HistoryPath)) {
    $empty = [ordered]@{
        HistoryPath = $HistoryPath
        SinceDays = $SinceDays
        Events = 0
        Rejects = 0
        Successes = 0
        CurrentState = 'No history file found'
        Recommendation = 'Run BuildWIM/Get-Windows11Iso once, or stage an official ISO/WIM/ESD in C:\BuildWimV2\Input.'
    }
    if ($AsJson) { [pscustomobject]$empty | ConvertTo-Json -Depth 5; return }
    Write-Host 'BuildWIM ISO cooldown stats' -ForegroundColor Cyan
    Write-Host '---------------------------' -ForegroundColor Cyan
    Write-Host "History path : $HistoryPath"
    Write-Host 'State        : no history file found'
    Write-Host 'Recommendation: run once to collect data, or use local ISO to avoid Microsoft link generation.'
    return
}

$cutoff = [DateTimeOffset]::UtcNow.AddDays(-1 * [Math]::Abs($SinceDays))
$events = New-Object System.Collections.Generic.List[object]
$badLines = 0

Get-Content -LiteralPath $HistoryPath -ErrorAction Stop | ForEach-Object {
    $line = [string]$_
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    try {
        $obj = $line | ConvertFrom-Json
        if (-not $obj.PSObject.Properties['TimestampUtc']) { return }
        $ts = [DateTimeOffset]::Parse([string]$obj.TimestampUtc)
        if ($ts -lt $cutoff) { return }
        Add-Member -InputObject $obj -NotePropertyName ParsedTimestampUtc -NotePropertyValue $ts -Force
        $events.Add($obj) | Out-Null
    } catch {
        $badLines++
    }
}

$orderedEvents = @($events.ToArray() | Sort-Object ParsedTimestampUtc)
$rejects = @($orderedEvents | Where-Object { $_.Event -eq 'MicrosoftSentinelRejected' -or $_.Event -eq 'SentinelRejected' })
$cooldownEvents = @($orderedEvents | Where-Object { $_.Event -eq 'CooldownActive' })
$successEvents = @($orderedEvents | Where-Object { $_.Event -in @('LinkResolved','LinkOnlySuccess','DownloadSuccess','ExistingIsoUsed','CachedLinkUsed') })
$networkSuccessEvents = @($orderedEvents | Where-Object { $_.Event -in @('LinkResolved','LinkOnlySuccess','DownloadSuccess','CachedLinkUsed') })

$recoverySeconds = New-Object System.Collections.Generic.List[double]
foreach ($reject in $rejects) {
    $nextSuccess = $networkSuccessEvents | Where-Object { $_.ParsedTimestampUtc -gt $reject.ParsedTimestampUtc } | Select-Object -First 1
    if ($nextSuccess) {
        $recoverySeconds.Add(($nextSuccess.ParsedTimestampUtc - $reject.ParsedTimestampUtc).TotalSeconds) | Out-Null
    }
}

$lastEvent = $orderedEvents | Select-Object -Last 1
$lastReject = $rejects | Select-Object -Last 1
$lastCooldown = $cooldownEvents | Select-Object -Last 1
$lastBlock = @($rejects + $cooldownEvents | Sort-Object ParsedTimestampUtc | Select-Object -Last 1)
$lastNetworkSuccess = $networkSuccessEvents | Select-Object -Last 1
$now = [DateTimeOffset]::UtcNow
$currentState = 'No Sentinel reject in selected window'
$remainingSeconds = $null

if ($lastBlock) {
    $successAfterLastReject = $false
    if ($lastNetworkSuccess -and $lastNetworkSuccess.ParsedTimestampUtc -gt $lastBlock.ParsedTimestampUtc) { $successAfterLastReject = $true }
    $ageSeconds = ($now - $lastBlock.ParsedTimestampUtc).TotalSeconds
    $cooldownSeconds = $CooldownMinutes * 60
    if ($successAfterLastReject) {
        $currentState = 'Recovered after last reject'
    } elseif ($ageSeconds -lt $cooldownSeconds) {
        $remainingSeconds = $cooldownSeconds - $ageSeconds
        $currentState = 'Local cooldown active'
    } else {
        $currentState = 'Local cooldown expired; Microsoft may still rate-limit externally'
    }
}

$medianRecovery = Get-Percentile -Values ([double[]]$recoverySeconds.ToArray()) -Percentile 0.50
$p75Recovery = Get-Percentile -Values ([double[]]$recoverySeconds.ToArray()) -Percentile 0.75
$shortestRecovery = if ($recoverySeconds.Count -gt 0) { [double](@($recoverySeconds.ToArray() | Sort-Object)[0]) } else { $null }
$longestRecovery = if ($recoverySeconds.Count -gt 0) { [double](@($recoverySeconds.ToArray() | Sort-Object)[-1]) } else { $null }

$recommendedWaitMinutes = $CooldownMinutes
if ($p75Recovery -and $p75Recovery -gt ($CooldownMinutes * 60)) {
    $recommendedWaitMinutes = [int][Math]::Ceiling($p75Recovery / 60)
}

$summary = [ordered]@{
    HistoryPath = $HistoryPath
    SinceDays = $SinceDays
    Events = $orderedEvents.Count
    ParseErrors = $badLines
    Rejects = $rejects.Count
    CooldownSkips = $cooldownEvents.Count
    Successes = $successEvents.Count
    NetworkSuccesses = $networkSuccessEvents.Count
    LastEventUtc = if ($lastEvent) { $lastEvent.ParsedTimestampUtc.ToString('o') } else { $null }
    LastRejectUtc = if ($lastReject) { $lastReject.ParsedTimestampUtc.ToString('o') } else { $null }
    LastCooldownUtc = if ($lastCooldown) { $lastCooldown.ParsedTimestampUtc.ToString('o') } else { $null }
    LastBlockUtc = if ($lastBlock) { $lastBlock.ParsedTimestampUtc.ToString('o') } else { $null }
    LastNetworkSuccessUtc = if ($lastNetworkSuccess) { $lastNetworkSuccess.ParsedTimestampUtc.ToString('o') } else { $null }
    CurrentState = $currentState
    LocalCooldownMinutes = $CooldownMinutes
    LocalCooldownRemainingSeconds = if ($remainingSeconds) { [int][Math]::Ceiling($remainingSeconds) } else { $null }
    ObservedRecoveryCount = $recoverySeconds.Count
    ShortestObservedRecoverySeconds = if ($shortestRecovery) { [int][Math]::Round($shortestRecovery) } else { $null }
    MedianObservedRecoverySeconds = if ($medianRecovery) { [int][Math]::Round($medianRecovery) } else { $null }
    P75ObservedRecoverySeconds = if ($p75Recovery) { [int][Math]::Round($p75Recovery) } else { $null }
    LongestObservedRecoverySeconds = if ($longestRecovery) { [int][Math]::Round($longestRecovery) } else { $null }
    RecommendedWaitMinutes = $recommendedWaitMinutes
    Note = 'Observed BuildWIM history only. Microsoft does not expose its internal Sentinel/rate-limit cooldown for this endpoint.'
}

if ($AsJson) {
    [pscustomobject]$summary | ConvertTo-Json -Depth 5
    return
}

Write-Host 'BuildWIM ISO cooldown stats' -ForegroundColor Cyan
Write-Host '---------------------------' -ForegroundColor Cyan
Write-Host "History path       : $HistoryPath"
Write-Host "Window             : last $SinceDays day(s)"
Write-Host "Events             : $($summary.Events)"
Write-Host "Rejects            : $($summary.Rejects)"
Write-Host "Cooldown skips     : $($summary.CooldownSkips)"
Write-Host "Network successes  : $($summary.NetworkSuccesses)"
Write-Host "Current state      : $($summary.CurrentState)"
if ($summary.LocalCooldownRemainingSeconds) { Write-Host "Cooldown remaining : $(Format-Duration $summary.LocalCooldownRemainingSeconds)" -ForegroundColor Yellow }
Write-Host "Last reject        : $(if ($summary.LastRejectUtc) { $summary.LastRejectUtc } else { 'n/a' })"
Write-Host "Last cooldown skip : $(if ($summary.LastCooldownUtc) { $summary.LastCooldownUtc } else { 'n/a' })"
Write-Host "Last success       : $(if ($summary.LastNetworkSuccessUtc) { $summary.LastNetworkSuccessUtc } else { 'n/a' })"
Write-Host ''
Write-Host 'Observed recovery after reject' -ForegroundColor White
Write-Host "  Samples : $($summary.ObservedRecoveryCount)"
Write-Host "  Shortest: $(Format-Duration $summary.ShortestObservedRecoverySeconds)"
Write-Host "  Median  : $(Format-Duration $summary.MedianObservedRecoverySeconds)"
Write-Host "  P75     : $(Format-Duration $summary.P75ObservedRecoverySeconds)"
Write-Host "  Longest : $(Format-Duration $summary.LongestObservedRecoverySeconds)"
Write-Host ''
Write-Host "Recommended wait   : $($summary.RecommendedWaitMinutes) min" -ForegroundColor Green
Write-Host 'Note               : observed history only; Microsoft does not publish the true Sentinel timer here.' -ForegroundColor DarkGray
