# ====================================================================

# Disable.ps1 — Turn off autostart and stop the watchdog, without

# removing any files. Run .\Setup.ps1 again at any time to re-enable.

# ====================================================================



$ScannerTaskName  = "SteamScannerOnLogon"

$WatchdogTaskName = "SteamWatchdogOnLogon"



foreach ($name in @($ScannerTaskName, $WatchdogTaskName)) {

    Disable-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue | Out-Null

}



Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue |

    Where-Object { $_.CommandLine -and ($_.CommandLine -like "*SteamScanner.ps1*" -or $_.CommandLine -like "*SteamWatchdog.ps1*" -or $_.CommandLine -like "*RunScannerHidden.vbs*" -or $_.CommandLine -like "*RunWatchdogHidden.vbs*") } |

    ForEach-Object {

        Write-Host "Stopping running process: PID $($_.ProcessId)" -ForegroundColor DarkGray

        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue

    }



Write-Host "Disabled. Autostart turned off and the watchdog has been stopped." -ForegroundColor Yellow

Write-Host "Run '.\Setup.ps1' again at any time to re-enable everything." -ForegroundColor Gray

