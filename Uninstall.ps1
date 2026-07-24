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

# 1. Safely remove scheduled tasks from Task Scheduler
Write-Host "[1/4] Removing scheduled tasks from Windows Task Scheduler..." -ForegroundColor Yellow
Unregister-ScheduledTask -TaskName $ScannerTaskName -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue

# 2. Terminate all running background processes, skipping current script process ($PID)
Write-Host "[2/4] Stopping all active SESO background processes..." -ForegroundColor Yellow
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine -like "*SteamScanner.ps1*" -or $_.CommandLine -like "*SteamWatchdog.ps1*" -or $_.CommandLine -like "*RunScannerHidden.vbs*" -or $_.CommandLine -like "*RunWatchdogHidden.vbs*") } |
    ForEach-Object {
        Write-Host "Stopping process PID: $($_.ProcessId)" -ForegroundColor DarkGray
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

# 3. Clean up dynamic runtime files (logs, caches) just in case
Write-Host "[3/4] Cleaning up generated cache, logs, and configuration files..." -ForegroundColor Yellow
$FilesToClean = @("gamelist.json", "watchdog.log", "scanner.log")
foreach ($File in $FilesToClean) {
    $FilePath = Join-Path $TargetFolder $File
    if (Test-Path $FilePath) {
        Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
    }
}

# 4. Asynchronous self-destruction of the root project folder
Write-Host "[4/4] Activating folder self-destruction sequence..." -ForegroundColor Yellow
Write-Host "SESO directory and all its contents will be completely removed shortly." -ForegroundColor Green

# Change directory to PS C:\Windows\system32> to release the lock from the current PowerShell session
Set-Location "PS C:\Windows\system32>"

# Spawn a completely detached background job using a script block with strict path arguments.
# This avoids any CMD syntax or quote escaping bugs.
Start-Job -ScriptBlock {
    param($FolderToRemove)
    # Wait 3 seconds for the main uninstaller window to close completely
    Start-Sleep -Seconds 3
    
    # Safely close only the Explorer window that views this specific folder
    $ExplorerWindows = (New-Object -ComObject Shell.Application).Windows()
    if ($ExplorerWindows) {
        $ExplorerWindows | Where-Object { $_.LocationURL -like "*$($FolderToRemove.Replace('\', '/'))*" } | ForEach-Object { $_.Quit() }
    }
    
    # Force delete the folder and everything inside it
    if (Test-Path $FolderToRemove) {
        Remove-Item -Path $FolderToRemove -Recurse -Force -ErrorAction SilentlyContinue
    }
} -ArgumentList $TargetFolder | Out-Null

Write-Host "Uninstall complete! System ecosystem is clean." -ForegroundColor Green
