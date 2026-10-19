# Check for Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Elevating privileges to Administrator..." -ForegroundColor Yellow
    # Relaunch this exact script with Admin rights, bypassed Execution Policy, and explicit working directory
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -WorkingDirectory $PSScriptRoot -Verb RunAs
    Exit
}

# Now running with full Admin privileges
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   SESO AUTOMATIC MASTER INSTALLER            " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# Force the execution context to the script's actual directory
Set-Location $PSScriptRoot

# Define task names
$ScannerTaskName  = "SteamScannerOnLogon"
$WatchdogTaskName = "SteamWatchdogOnLogon"

Write-Host "Locating components..." -ForegroundColor Cyan
# Smart search for VBS files across the repository structure
$WatchdogVbsPath = Get-ChildItem -Path $PSScriptRoot -Filter "RunWatchdogHidden.vbs" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

# Verify that critical components exist before installing
if (-not $WatchdogVbsPath) {
    Write-Host "ERROR: RunWatchdogHidden.vbs was NOT found inside $PSScriptRoot!" -ForegroundColor Red
    Write-Host "Please make sure these files exist in your repository." -ForegroundColor Yellow
    Start-Sleep -Seconds 4
    Exit
}

Write-Host "[1/3] Stopping previous SESO instances (upgrade-safe)..." -ForegroundColor Yellow
Unregister-ScheduledTask -TaskName $ScannerTaskName -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*SteamWatchdog*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# One-time full scan. After this the watchdog keeps the list in sync itself
# (manifest watchers + targeted detection), so no scan runs at every logon.
Write-Host "[2/3] Scanning Steam libraries..." -ForegroundColor Yellow
& (Join-Path (Split-Path $WatchdogVbsPath -Parent) "SteamScanner.ps1")

Write-Host "[3/3] Registering and starting the watchdog..." -ForegroundColor Yellow
$WTrigger = New-ScheduledTaskTrigger -AtLogOn
$WAction  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$WatchdogVbsPath`""
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 365)
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# Highest = elevated, which lets the watchdog use the event-driven ETW process trace
Register-ScheduledTask -TaskName $WatchdogTaskName -Trigger $WTrigger -Action $WAction -Settings $Settings -User $CurrentUser -RunLevel Highest | Out-Null
Start-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue

Write-Host "==============================================" -ForegroundColor Green
Write-Host "   SESO HAS BEEN SUCCESSFULLY INSTALLED!      " -ForegroundColor Green
Write-Host "   Steam EcoSystem Optimizer is now active.   " -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green

# Soft exit without annoying key prompts
Start-Sleep -Seconds 3
