<#
.SYNOPSIS
    Measures total RAM used by all Steam-related processes and logs it,
    so SESO's README can quote real, reproducible numbers instead of
    unverified claims.

.USAGE
    1. Launch Steam normally (Large Games List), let it settle for ~30s.
       Run:  .\Measure-SteamRAM.ps1 -Label "before"
    2. Switch to Mini Games List (or let SESO do it while a game runs).
       Wait ~30s for Chromium to unload, then run:
       .\Measure-SteamRAM.ps1 -Label "after"
    3. Repeat 3-5 times on different days for a stable average.
    4. Results are appended to seso-ram-log.csv in the current folder.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Label
)

$steamProcs = Get-Process | Where-Object {
    $_.ProcessName -match "^steam" -or $_.ProcessName -eq "steamwebhelper"
}

if (-not $steamProcs) {
    Write-Host "No Steam processes found. Is Steam running?" -ForegroundColor Red
    exit 1
}

$totalMB = [math]::Round((($steamProcs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB), 1)
$procCount = $steamProcs.Count
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host ""
Write-Host "=== Steam RAM snapshot [$Label] ===" -ForegroundColor Cyan
$steamProcs | Sort-Object WorkingSet64 -Descending |
    Select-Object ProcessName, Id, @{N='RAM (MB)';E={[math]::Round($_.WorkingSet64/1MB,1)}} |
    Format-Table -AutoSize

Write-Host "Total: $totalMB MB across $procCount process(es)" -ForegroundColor Green
Write-Host ""

# Append to CSV log
$logFile = "seso-ram-log.csv"
$exists = Test-Path $logFile

$entry = [PSCustomObject]@{
    Timestamp    = $timestamp
    Label        = $Label
    ProcessCount = $procCount
    TotalRAM_MB  = $totalMB
}

if (-not $exists) {
    $entry | Export-Csv -Path $logFile -NoTypeInformation
} else {
    $entry | Export-Csv -Path $logFile -NoTypeInformation -Append
}

Write-Host "Logged to $logFile" -ForegroundColor Yellow
