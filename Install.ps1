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
$ScannerVbsPath  = Get-ChildItem -Path $PSScriptRoot -Filter "RunScannerHidden.vbs" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
$WatchdogVbsPath = Get-ChildItem -Path $PSScriptRoot -Filter "RunWatchdogHidden.vbs" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

# Verify that critical components exist before installing
if (-not $ScannerVbsPath -or -not $WatchdogVbsPath) {
    Write-Host "ERROR: Critical components (RunScannerHidden.vbs or RunWatchdogHidden.vbs) were NOT found inside $PSScriptRoot!" -ForegroundColor Red
    Write-Host "Please make sure these files exist in your repository." -ForegroundColor Yellow
    Start-Sleep -Seconds 4
    Exit
}

Write-Host "[1/2] Creating Windows Task Scheduler triggers..." -ForegroundColor Yellow

# Clean up existing tasks first to avoid duplication or conflicts
Unregister-ScheduledTask -TaskName $ScannerTaskName -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue

# Define standard action and trigger arguments for invisible VBS execution
$STrigger = New-ScheduledTaskTrigger -AtLogOn
$SAction  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$ScannerVbsPath`""
$WTrigger = New-ScheduledTaskTrigger -AtLogOn
$WAction  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$WatchdogVbsPath`""

# Define settings (Allow start if on batteries, don't stop if runs longer than 3 days, etc.)
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 365)

# Register both tasks to run under the currently logged-on user with highest privileges
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

Register-ScheduledTask -TaskName $ScannerTaskName -Trigger $STrigger -Action $SAction -Settings $Settings -User $CurrentUser -RunLevel Highest | Out-Null
Register-ScheduledTask -TaskName $WatchdogTaskName -Trigger $WTrigger -Action $WAction -Settings $Settings -User $CurrentUser -RunLevel Highest | Out-Null

Write-Host "Tasks registered successfully in Task Scheduler." -ForegroundColor Green

Write-Host "[2/2] Initializing and launching SESO services..." -ForegroundColor Yellow

# Start the background tasks right now so the user doesn't have to re-logon to Windows
Start-ScheduledTask -TaskName $ScannerTaskName -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue

Write-Host "==============================================" -ForegroundColor Green
Write-Host "   SESO HAS BEEN SUCCESSFULLY INSTALLED!      " -ForegroundColor Green
Write-Host "   Steam EcoSystem Optimizer is now active.   " -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green

# Soft exit without annoying key prompts
Start-Sleep -Seconds 3
