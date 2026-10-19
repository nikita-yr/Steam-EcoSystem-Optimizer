# ====================================================================
# SteamWatchdog.ps1
#
# Persistent Steam background optimizer (SESO - Steam Ecosystem Optimizer).
#
# - Detects Steam game start/stop (event-driven ETW trace when elevated,
#   WMI polling filtered to steamapps\common otherwise)
# - Switches Steam UI to Mini Games List while playing
# - Puts steamwebhelper into background mode (trim RAM, EcoQoS,
#   low memory/CPU priority) instead of killing it
# - Debounced restore: game-to-game switches never flip the Steam UI
# - Keeps the game database in sync via manifest watchers
# ====================================================================

. (Join-Path $PSScriptRoot "Common.ps1")

# Single instance per user session
$createdNew = $false
$Global:SesoMutex = New-Object System.Threading.Mutex($true, "Local\SESO_SteamWatchdog", [ref]$createdNew)
if (-not $createdNew) { exit }

# Global: these are read from event-action scopes too
$Global:CachePath       = Join-Path $PSScriptRoot "gamelist.json"
$Global:LogPath         = Join-Path $PSScriptRoot "watchdog.log"
$Global:RestoreDelaySec = 15     # wait before restoring Steam after the last game exits
$Global:RetrimEverySec  = 60     # re-apply background mode while a game runs
$Global:LogMaxBytes     = 256KB


function Global:Write-Log {
    param($Message, $Color = "White")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {}
    Write-Host $line -ForegroundColor $Color
}


function Global:Limit-Log {
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt $LogMaxBytes) {
            $tail = Get-Content $LogPath -Tail 1000 -Encoding UTF8
            Set-Content -Path $LogPath -Value $tail -Encoding UTF8
        }
    }
    catch {}
}


# ====================================================================
# SHARED STATE
# ====================================================================

$Global:WatchdogState = [hashtable]::Synchronized(@{
    Games           = @()
    TargetGames     = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    NonGames        = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    ActiveProcesses = [hashtable]::Synchronized(@{})
    PendingAppIds   = [hashtable]::Synchronized(@{})
    PendingRescan   = [hashtable]::Synchronized(@{})
    LastSteamStart  = (Get-Date).AddMinutes(-10)
    SteamPid        = (Get-Process steam -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1).Id
    Optimized       = $false
    RestoreAt       = $null
    LastRetrim      = Get-Date
    LastLogCheck    = Get-Date
})


function Global:Rebuild-TargetLists {
    $set = $Global:WatchdogState.TargetGames
    $set.Clear()
    foreach ($game in @($Global:WatchdogState.Games)) {
        foreach ($p in @($game.ExePaths)) { if ($p) { [void]$set.Add($p) } }
    }
}


# ====================================================================
# CACHE
# ====================================================================

function Global:Save-Cache {
    try {
        @{
            GeneratedAt = (Get-Date).ToString("o")
            Count       = $Global:WatchdogState.Games.Count
            Games       = $Global:WatchdogState.Games
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $CachePath -Encoding UTF8
    }
    catch { Write-Log "Cache save failed: $_" "Red" }
}


function Global:Load-GameCache {
    if (-not (Test-Path $CachePath)) {
        Write-Log "Cache not found. Unknown games will be detected on first launch." "DarkGray"
        return
    }
    try {
        $data = Get-Content $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $Global:WatchdogState.Games = @($data.Games)
        Rebuild-TargetLists
        Write-Log "Cache loaded: $($Global:WatchdogState.Games.Count) games, $($Global:WatchdogState.TargetGames.Count) executables" "Cyan"
    }
    catch { Write-Log "Cache load failed: $_" "Red" }
}


function Global:Add-OrUpdateGame {
    param($ManifestPath, $CommonPath)

    $game = Read-SteamManifest -ManifestPath $ManifestPath -CommonPath $CommonPath
    if (-not $game) { return $null }

    $Global:WatchdogState.Games = @($Global:WatchdogState.Games | Where-Object { $_.AppId -ne $game.AppId }) + $game
    Rebuild-TargetLists
    Save-Cache
    Write-Log "Game updated: $($game.Name) ($($game.AppId))" "Green"
    return $game
}


function Global:Remove-Game {
    param($AppId)

    $old = $Global:WatchdogState.Games | Where-Object { $_.AppId -eq $AppId }
    if (-not $old) { return }

    $Global:WatchdogState.Games = @($Global:WatchdogState.Games | Where-Object { $_.AppId -ne $AppId })
    Rebuild-TargetLists
    Save-Cache
    Write-Log "Game removed: $($old.Name)" "Magenta"
}


# ====================================================================
# STEAM UI + BACKGROUND MODE
# ====================================================================

function Global:Switch-SteamView {
    param([ValidateSet("minigameslist", "largegameslist")] $Mode)

    $steam = Get-Process "steam" -ErrorAction SilentlyContinue | Select-Object -First 1

    # Steam closed or just starting: only set the registry value it reads on start
    if (-not $steam -or ($Mode -eq "largegameslist" -and ((Get-Date) - $steam.StartTime).TotalSeconds -lt 30)) {
        try {
            Set-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name "LastGameListUsed" -Value $Mode -ErrorAction Stop
            Write-Log "Registry set: $Mode" "DarkGray"
        }
        catch { Write-Log "Registry write failed: $_" "Red" }
        return
    }

    try {
        Start-Process "steam://open/$Mode"
        Write-Log "Steam switched to $Mode" "Cyan"
    }
    catch { Write-Log "Steam switch failed: $_" "Red" }
}


function Global:Enter-GameMode {
    $state = $Global:WatchdogState
    $state.RestoreAt = $null
    if ($state.Optimized) { return }   # game-to-game: Steam is already optimized

    $state.Optimized = $true
    # Steam is busy for a while after a launch (overlay, cloud sync) and pulls
    # pages back in, so the first re-trim comes 20 s later, then every minute.
    $state.LastRetrim = (Get-Date).AddSeconds(20 - $Global:RetrimEverySec)
    Switch-SteamView -Mode "minigameslist"
    $r = Set-SteamHelpersMode -Mode Game
    Write-Log "Background mode: $($r.Count) helpers, trimmed $($r.TrimmedMB) MB" "Cyan"
}


function Global:Exit-GameMode {
    $state = $Global:WatchdogState
    $state.RestoreAt = $null
    $state.Optimized = $false
    Set-SteamHelpersMode -Mode Normal | Out-Null
    Switch-SteamView -Mode "largegameslist"
}


# ====================================================================
# PROCESS EVENTS
# ====================================================================

function Global:On-ProcessStart {
    param($ProcessId, $Name, $ExePath)

    $state = $Global:WatchdogState

    if ($Name -eq "steam.exe") {
        # steam:// links spawn a short-lived second steam.exe that forwards
        # the command to the running client; only a new main client counts.
        $now = Get-Date
        if ($state.SteamPid -and (Get-Process -Id $state.SteamPid -ErrorAction SilentlyContinue)) { return }
        $state.SteamPid = $ProcessId
        if (($now - $state.LastSteamStart).TotalSeconds -gt 30) {
            $state.LastSteamStart = $now
            $state.Optimized = $false
            Set-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name "LastGameListUsed" -Value "largegameslist" -ErrorAction SilentlyContinue
            Write-Log "Steam started" "Cyan"
        }
        return
    }

    if (-not $ExePath) {
        try { $ExePath = [SESO.Native]::GetPath($ProcessId) } catch { return }
    }
    if (-not $ExePath -or $ExePath -notlike "*\steamapps\common\*") { return }
    if ($state.NonGames.Contains($ExePath)) { return }

    if (-not $state.TargetGames.Contains($ExePath)) {
        $state.PendingRescan[$ProcessId] = @{ Name = $Name; ExePath = $ExePath }
        return
    }

    if ($state.ActiveProcesses.ContainsKey($ProcessId)) { return }
    $state.ActiveProcesses[$ProcessId] = $ExePath
    Write-Log "Game started: $Name PID=$ProcessId Active=$($state.ActiveProcesses.Count)" "Yellow"
    Enter-GameMode
}


function Global:On-ProcessStop {
    param($ProcessId, $Name)

    $state = $Global:WatchdogState
    $state.PendingRescan.Remove($ProcessId)
    if (-not $state.ActiveProcesses.ContainsKey($ProcessId)) { return }

    $exe = Split-Path $state.ActiveProcesses[$ProcessId] -Leaf   # ETW truncates names to 15 chars
    $state.ActiveProcesses.Remove($ProcessId)
    $count = $state.ActiveProcesses.Count
    Write-Log "Game stopped: $exe Active=$count" "Yellow"

    if ($count -eq 0) {
        $state.RestoreAt = (Get-Date).AddSeconds($Global:RestoreDelaySec)
    }
}



$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

try {
    if (-not $isAdmin) { throw "not elevated" }

    # Event-driven (ETW): zero cost while nothing starts, no polling
    Register-CimIndicationEvent -Query "SELECT * FROM Win32_ProcessStartTrace" -SourceIdentifier "SesoStart" -ErrorAction Stop -Action {
        try {
            $e = $Event.SourceEventArgs.NewEvent
            On-ProcessStart -ProcessId ([int]$e.ProcessID) -Name $e.ProcessName -ExePath $null
        }
        catch { Write-Log "Start event error: $_" "Red" }
    } | Out-Null

    Register-CimIndicationEvent -Query "SELECT * FROM Win32_ProcessStopTrace" -SourceIdentifier "SesoStop" -ErrorAction Stop -Action {
        try {
            $e = $Event.SourceEventArgs.NewEvent
            On-ProcessStop -ProcessId ([int]$e.ProcessID) -Name $e.ProcessName
        }
        catch { Write-Log "Stop event error: $_" "Red" }
    } | Out-Null

    Write-Log "Process tracking: ETW trace" "DarkGray"
}
catch {
    Get-EventSubscriber -SourceIdentifier "SesoStart" -ErrorAction SilentlyContinue | Unregister-Event

    # Fallback: WMI polling, filtered so only Steam and steamapps\common
    # processes ever reach PowerShell ("_" matches the backslash).
    $filter = "(TargetInstance.Name = 'steam.exe' OR TargetInstance.ExecutablePath LIKE '%_steamapps_common_%')"

    Register-CimIndicationEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process' AND $filter" -SourceIdentifier "SesoStart" -Action {
        try {
            $p = $Event.SourceEventArgs.NewEvent.TargetInstance
            On-ProcessStart -ProcessId ([int]$p.ProcessId) -Name $p.Name -ExePath $p.ExecutablePath
        }
        catch { Write-Log "Start event error: $_" "Red" }
    } | Out-Null

    Register-CimIndicationEvent -Query "SELECT * FROM __InstanceDeletionEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process' AND $filter" -SourceIdentifier "SesoStop" -Action {
        try {
            $p = $Event.SourceEventArgs.NewEvent.TargetInstance
            On-ProcessStop -ProcessId ([int]$p.ProcessId) -Name $p.Name
        }
        catch { Write-Log "Stop event error: $_" "Red" }
    } | Out-Null

    Write-Log "Process tracking: WMI polling (filtered)" "DarkGray"
}


# ====================================================================
# STARTUP
# ====================================================================

Limit-Log
Load-GameCache

$manifestWatchers = @()
foreach ($library in Get-SteamLibraryPaths) {
    $steamapps = Join-Path $library "steamapps"
    if (-not (Test-Path $steamapps)) { continue }

    try {
        $watcher = New-Object System.IO.FileSystemWatcher $steamapps, "appmanifest_*.acf"
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName, [System.IO.NotifyFilters]::LastWrite
        $watcher.EnableRaisingEvents = $true
        $manifestWatchers += $watcher

        foreach ($evt in "Created", "Changed", "Deleted") {
            Register-ObjectEvent -InputObject $watcher -EventName $evt -MessageData (Join-Path $steamapps "common") -Action {
                $appId = Get-AppIdFromManifestPath -ManifestPath $Event.SourceEventArgs.Name
                if ($appId) {
                    $Global:WatchdogState.PendingAppIds[$appId] = @{
                        ManifestPath = $Event.SourceEventArgs.FullPath
                        CommonPath   = $Event.MessageData
                        LastWrite    = Get-Date
                        Action       = $(if ($Event.SourceEventArgs.ChangeType -eq "Deleted") { "Remove" } else { "Add" })
                    }
                }
            } | Out-Null
        }
    }
    catch { Write-Log "Watcher failed for $library : $_" "Red" }
}

Write-Log "Steam-Watchdog active, watching $($manifestWatchers.Count) libraries" "Green"


# ====================================================================
# MAIN LOOP HELPERS
# ====================================================================

function Global:Invoke-PendingManifestChecks {
    $now = Get-Date
    foreach ($id in @($Global:WatchdogState.PendingAppIds.Keys)) {
        $item = $Global:WatchdogState.PendingAppIds[$id]
        if (-not $item -or ($now - $item.LastWrite).TotalSeconds -lt 3) { continue }

        $Global:WatchdogState.PendingAppIds.Remove($id)
        if ($item.Action -eq "Remove") { Remove-Game -AppId $id }
        else { [void](Add-OrUpdateGame -ManifestPath $item.ManifestPath -CommonPath $item.CommonPath) }
    }
}


function Global:Invoke-PendingRescan {
    # Targeted: only the manifest whose installdir owns this exe is parsed.
    $state = $Global:WatchdogState

    foreach ($processId in @($state.PendingRescan.Keys)) {
        $item = $state.PendingRescan[$processId]
        $state.PendingRescan.Remove($processId)
        if (-not $item) { continue }

        $m = [regex]::Match($item.ExePath, '^(.*\\steamapps)\\common\\([^\\]+)\\', 'IgnoreCase')
        if (-not $m.Success) { continue }
        $steamapps = $m.Groups[1].Value
        $installDir = $m.Groups[2].Value

        $game = $null
        foreach ($manifest in Get-ChildItem $steamapps -Filter "appmanifest_*.acf" -ErrorAction SilentlyContinue) {
            $dir = [regex]::Match([IO.File]::ReadAllText($manifest.FullName), '"installdir"\s+"([^"]+)"').Groups[1].Value
            if ($dir -eq $installDir) {
                $game = Add-OrUpdateGame -ManifestPath $manifest.FullName -CommonPath (Join-Path $steamapps "common")
                break
            }
        }

        if (-not $state.TargetGames.Contains($item.ExePath)) {
            [void]$state.NonGames.Add($item.ExePath)   # helper exe inside a game folder
            continue
        }

        # The process may have exited while we were looking it up
        if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) { continue }

        $state.ActiveProcesses[$processId] = $item.ExePath
        Write-Log "Detected game: $($game.Name) PID=$processId Active=$($state.ActiveProcesses.Count)" "Yellow"
        Enter-GameMode
    }
}


# ====================================================================
# MAIN LOOP
# ====================================================================

while ($true) {
    Start-Sleep -Seconds 1
    $state = $Global:WatchdogState
    $now = Get-Date

    if ($state.PendingAppIds.Count) { Invoke-PendingManifestChecks }
    if ($state.PendingRescan.Count) { Invoke-PendingRescan }

    if ($state.RestoreAt -and $now -ge $state.RestoreAt -and $state.ActiveProcesses.Count -eq 0) {
        Exit-GameMode
    }

    if ($state.Optimized -and $state.ActiveProcesses.Count -gt 0 -and ($now - $state.LastRetrim).TotalSeconds -ge $Global:RetrimEverySec) {
        $state.LastRetrim = $now
        [void](Set-SteamHelpersMode -Mode Game)
    }

    if (($now - $state.LastLogCheck).TotalHours -ge 24) {
        $state.LastLogCheck = $now
        Limit-Log
    }
}
