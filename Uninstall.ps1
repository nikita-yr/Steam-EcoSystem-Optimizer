# Check for Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Please run Uninstall.ps1 from an ELEVATED (Administrator) PowerShell session!" -ForegroundColor Red
    Exit
}

$ScannerTaskName  = "SteamScannerOnLogon"
$WatchdogTaskName = "SteamWatchdogOnLogon"
$TargetFolder     = $PSScriptRoot

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   SESO AUTOMATIC COMPLETELY UNINSTALLER       " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 1. Remove scheduled tasks
Write-Host "[1/4] Removing scheduled tasks..." -ForegroundColor Yellow
Unregister-ScheduledTask -TaskName $ScannerTaskName  -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue

# 2. Kill all running SESO processes
Write-Host "[2/4] Stopping all active SESO background processes..." -ForegroundColor Yellow
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and (
        $_.CommandLine -like "*SteamScanner.ps1*"  -or
        $_.CommandLine -like "*SteamWatchdog.ps1*" -or
        $_.CommandLine -like "*RunScannerHidden.vbs*" -or
        $_.CommandLine -like "*RunWatchdogHidden.vbs*"
    )} |
    ForEach-Object {
        Write-Host "Stopping PID: $($_.ProcessId)" -ForegroundColor DarkGray
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

# 3. Clean up generated runtime files
# FIX: gamelist.json and watchdog.log live in src/, not in the project root
Write-Host "[3/4] Cleaning up cache and logs..." -ForegroundColor Yellow
$FilesToClean = @(
    (Join-Path $TargetFolder "src\gamelist.json"),
    (Join-Path $TargetFolder "src\watchdog.log"),
    (Join-Path $TargetFolder "src\scanner.log")
)
foreach ($file in $FilesToClean) {
    if (Test-Path $file) {
        Remove-Item -Path $file -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed: $file" -ForegroundColor DarkGray
    }
}

# 4. Async self-destruction of the project folder
Write-Host "[4/4] Scheduling folder removal..." -ForegroundColor Yellow

Set-Location "C:\"

Start-Job -ScriptBlock {
    param($FolderToRemove)
    Start-Sleep -Seconds 3

    # Close any Explorer window open to this folder
    $shell = New-Object -ComObject Shell.Application
    if ($shell) {
        $shell.Windows() | Where-Object {
            $_.LocationURL -like "*$($FolderToRemove.Replace('\', '/'))*"
        } | ForEach-Object { $_.Quit() }
    }

    if (Test-Path $FolderToRemove) {
        Remove-Item -Path $FolderToRemove -Recurse -Force -ErrorAction SilentlyContinue
    }
} -ArgumentList $TargetFolder | Out-Null

Write-Host "Uninstall complete. SESO removed." -ForegroundColor Green
