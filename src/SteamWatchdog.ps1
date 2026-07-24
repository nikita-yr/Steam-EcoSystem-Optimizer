# ====================================================================
# SteamWatchdog.ps1
#
# Persistent Steam background optimizer (SESO - Steam Ecosystem Optimizer).
#
# Features:
# - Detect Steam games start/stop
# - Switch Steam UI mode
# - Maintain live game database
# - Watch Steam manifests
# - Surgical SteamWebHelper RAM offloading (kills renderers, keeps core)
# - Safe recovery from missing Steam libraries
# ====================================================================

. (Join-Path $PSScriptRoot "Common.ps1")

$CachePath = Join-Path $PSScriptRoot "gamelist.json"
$LogPath   = Join-Path $PSScriptRoot "watchdog.log"


function Global:Write-Log {
    param(
        $Message,
        $Color = "White"
    )

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"

    try {
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    }
    catch {}

    Write-Host $line -ForegroundColor $Color
}


# ====================================================================
# SHARED STATE
# ====================================================================

$Global:WatchdogState = [hashtable]::Synchronized(@{
    Games           = @()
    TargetGames     = @()
    TargetNames     = @()
    ActiveProcesses = [hashtable]::Synchronized(@{})
    LastLoaded      = $null
    LastLogCleanup  = $null
    LastSteamStart  = (Get-Date).AddMinutes(-10)
    PendingAppIds   = [hashtable]::Synchronized(@{})
    PendingRescan   = [hashtable]::Synchronized(@{})
})


function Global:Get-ActiveGameCount {
    return $Global:WatchdogState.ActiveProcesses.Count
}


function Global:Rebuild-TargetLists {
    $allPaths = @()
    foreach ($game in @($Global:WatchdogState.Games)) {
        if ($game.ExePaths) {
            $allPaths += @($game.ExePaths)
        }
    }

    $Global:WatchdogState.TargetGames = @($allPaths)
    $Global:WatchdogState.TargetNames = @($allPaths | ForEach-Object {
        Split-Path $_ -Leaf
    })
}


# ====================================================================
# CACHE
# ====================================================================

function Global:Save-Cache {
    try {
        $cache = @{
            GeneratedAt = (Get-Date).ToString("o")
            Count       = $Global:WatchdogState.Games.Count
            Games       = $Global:WatchdogState.Games
        }

        $cache |
            ConvertTo-Json -Depth 5 |
            Set-Content -Path $CachePath -Encoding UTF8
    }
    catch {
        Write-Log "Cache save failed: $_" "Red"
    }
}


function Global:Load-GameCache {
    if (-not (Test-Path $CachePath)) {
        Write-Log "Cache not found. Run scanner first." "Red"
        return
    }

    try {
        $data = Get-Content $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json

        $Global:WatchdogState.Games = @($data.Games)
        Rebuild-TargetLists
        $Global:WatchdogState.LastLoaded = Get-Date

        Write-Log "Cache loaded: $($Global:WatchdogState.Games.Count) games, $($Global:WatchdogState.TargetGames.Count) executables" "Cyan"
    }
    catch {
        Write-Log "Cache load failed: $_" "Red"
    }
}


# ====================================================================
# PROCESS PATH RESOLUTION
# ====================================================================

function Global:Resolve-ExePath {
    param($TargetInstance)

    if ($TargetInstance.ExecutablePath) {
        return $TargetInstance.ExecutablePath
    }

    $procId = $TargetInstance.ProcessId

    if (-not $procId) {
        return $null
    }

    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
        if ($proc.ExecutablePath) {
            return $proc.ExecutablePath
        }
    }
    catch {}

    try {
        $p = Get-Process -Id $procId -ErrorAction Stop
        if ($p.Path) {
            return $p.Path
        }
    }
    catch {}

    return $null
}


# ====================================================================
# LOG CLEANUP
# ====================================================================

function Global:Invoke-WeeklyLogCleanup {
    $now = Get-Date

    if ($Global:WatchdogState.LastLogCleanup -and (($now - $Global:WatchdogState.LastLogCleanup).TotalHours -lt 24)) {
        return
    }

    $Global:WatchdogState.LastLogCleanup = $now

    Get-ChildItem -Path $PSScriptRoot -Filter "*.log" -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ((($now - $_.LastWriteTime).TotalDays) -ge 7) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}


# ====================================================================
# STEAM UI SWITCH
# ====================================================================

function Global:Switch-SteamView {
    param(
        [ValidateSet("minigameslist", "largegameslist")]
        $Mode
    )

    $steam = Get-Process "steam" -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $steam) {
        try {
            Set-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name "LastGameListUsed" -Value $Mode -ErrorAction Stop
            Write-Log "Steam closed. Registry set: $Mode" "DarkGray"
        }
        catch {
            Write-Log "Registry write failed: $_" "Red"
        }
        return
    }

    try {
        $seconds = ((Get-Date) - $steam.StartTime).TotalSeconds

        if ($Mode -eq "largegameslist" -and $seconds -lt 30) {
            Set-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name "LastGameListUsed" -Value $Mode
            Write-Log "Steam startup detected. Registry only." "DarkGray"
            return
        }

        Start-Process "steam://open/$Mode"
        Write-Log "Steam switched to $Mode" "Cyan"
    }
    catch {
        Write-Log "Steam switch failed: $_" "Red"
    }
}


# ====================================================================
# STEAM LIBRARIES
# ====================================================================

function Global:Get-SteamLibraryPaths {
    $paths = @()

    try {
        $steamPath = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -Name "SteamPath" -ErrorAction SilentlyContinue).SteamPath

        if ($steamPath -and (Test-Path $steamPath -ErrorAction SilentlyContinue)) {
            $paths += $steamPath
        }

        if ($steamPath) {
            $vdf = Join-Path $steamPath "steamapps\libraryfolders.vdf"

            if (Test-Path $vdf -ErrorAction SilentlyContinue) {
                $content = Get-Content $vdf -Raw -ErrorAction SilentlyContinue
                $matches = [regex]::Matches($content, '"path"\s+"([^"]+)"')

                foreach ($m in $matches) {
                    $path = $m.Groups[1].Value -replace '\\\\', '\'

                    if (Test-Path -Path $path -ErrorAction SilentlyContinue) {
                        $paths += $path
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Steam library scan failed: $_" "Red"
    }

    return $paths | ForEach-Object { $_.TrimEnd('\', '/') } | Sort-Object -Unique
}


# ====================================================================
# MANIFEST
# ====================================================================

function Global:Read-SteamManifest {
    param(
        $ManifestPath,
        $CommonPath
    )

    try {
        $content = Get-Content $ManifestPath -Raw -Encoding UTF8

        $appId   = [regex]::Match($content, '"appid"\s+"(\d+)"').Groups[1].Value
        $name    = [regex]::Match($content, '"name"\s+"([^"]+)"').Groups[1].Value
        $install = [regex]::Match($content, '"installdir"\s+"([^"]+)"').Groups[1].Value

        if (-not $appId -or -not $name) {
            return $null
        }

        $gamePath = Join-Path $CommonPath $install
        $exePaths = @()

        if (Test-Path $gamePath) {
            $exePaths = Get-ChildItem -Path $gamePath -Filter "*.exe" -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName
        }

        return [PSCustomObject]@{
            AppId    = $appId
            Name     = $name
            ExePaths = @($exePaths)
        }
    }
    catch {
        Write-Log "Manifest error $ManifestPath : $_" "Red"
        return $null
    }
}


# ====================================================================
# GAME DATABASE UPDATE
# ====================================================================

function Global:Add-OrUpdateGame {
    param(
        $ManifestPath,
        $CommonPath
    )

    $game = Read-SteamManifest -ManifestPath $ManifestPath -CommonPath $CommonPath

    if (-not $game) {
        return
    }

    $Global:WatchdogState.Games = @(
        $Global:WatchdogState.Games | Where-Object { $_.AppId -ne $game.AppId }
    )

    $Global:WatchdogState.Games += $game

    Rebuild-TargetLists
    Save-Cache

    Write-Log "Game updated: $($game.Name) ($($game.AppId))" "Green"
}


function Global:Remove-Game {
    param($AppId)

    if (-not $AppId) {
        return
    }

    $old = $Global:WatchdogState.Games | Where-Object { $_.AppId -eq $AppId }

    if (-not $old) {
        return
    }

    $Global:WatchdogState.Games = @(
        $Global:WatchdogState.Games | Where-Object { $_.AppId -ne $AppId }
    )

    Rebuild-TargetLists
    Save-Cache

    Write-Log "Game removed: $($old.Name)" "Magenta"
}


# ====================================================================
# START CACHE
# ====================================================================

Load-GameCache


# ====================================================================
# FILE WATCHERS
# ====================================================================

$libraryPaths = Get-SteamLibraryPaths
$manifestWatchers = @()

foreach ($library in $libraryPaths) {
    $steamapps = Join-Path $library "steamapps"
    $common    = Join-Path $steamapps "common"

    if (-not (Test-Path $steamapps)) {
        continue
    }

    try {
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $steamapps
        $watcher.Filter = "appmanifest_*.acf"
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName, [System.IO.NotifyFilters]::LastWrite
        $watcher.EnableRaisingEvents = $true

        $manifestWatchers += $watcher
        $id = [guid]::NewGuid().ToString("N").Substring(0, 8)

        Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier "ManifestCreated_$id" -MessageData $common -Action {
            $appId = [regex]::Match($Event.SourceEventArgs.Name, 'appmanifest_(\d+)\.acf').Groups[1].Value

            if ($appId) {
                $Global:WatchdogState.PendingAppIds[$appId] = @{
                    ManifestPath = $Event.SourceEventArgs.FullPath
                    CommonPath   = $Event.MessageData
                    LastWrite    = Get-Date
                    Action       = "Add"
                }
            }
        } | Out-Null

        Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier "ManifestChanged_$id" -MessageData $common -Action {
            $appId = [regex]::Match($Event.SourceEventArgs.Name, 'appmanifest_(\d+)\.acf').Groups[1].Value

            if ($appId) {
                $Global:WatchdogState.PendingAppIds[$appId] = @{
                    ManifestPath = $Event.SourceEventArgs.FullPath
                    CommonPath   = $Event.MessageData
                    LastWrite    = Get-Date
                    Action       = "Add"
                }
            }
        } | Out-Null

        Register-ObjectEvent -InputObject $watcher -EventName Deleted -SourceIdentifier "ManifestDeleted_$id" -Action {
            $appId = [regex]::Match($Event.SourceEventArgs.Name, 'appmanifest_(\d+)\.acf').Groups[1].Value

            if ($appId) {
                $Global:WatchdogState.PendingAppIds[$appId] = @{
                    AppId     = $appId
                    LastWrite = Get-Date
                    Action    = "Remove"
                }
            }
        } | Out-Null
    }
    catch {
        Write-Log "Watcher failed for $library : $_" "Red"
    }
}

Write-Log "Watching $($manifestWatchers.Count) Steam libraries" "Cyan"


# ====================================================================
# SURGICAL STEAM WEB HELPER RAM CLEANER (SESO)
# ====================================================================

function Global:Invoke-SteamWebHelperOffload {
    $helpers = Get-CimInstance Win32_Process -Filter "Name='steamwebhelper.exe'" -ErrorAction SilentlyContinue

    if (-not $helpers) {
        return
    }

    $steam = Get-Process steam -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $steam) {
        return
    }

    # Идентифицируем главный процесс MAIN (у него обычно нет аргумента --type=)
    $main = $helpers | Where-Object {
        $_.ParentProcessId -eq $steam.Id -and $_.CommandLine -notmatch '--type='
    } | Select-Object -First 1

    $killed = 0

    foreach ($h in $helpers) {
        $cmd = $h.CommandLine

        # 1. Пропускаем главный процесс (MAIN)
        if ($main -and $h.ProcessId -eq $main.ProcessId) {
            continue
        }

        # 2. Пропускаем GPU-процесс (оверлей и графическое сведение)
        if ($cmd -match '--type=gpu-process') {
            continue
        }

        # 3. Пропускаем NetworkService (чат, список друзей, сетевые сервисы)
        if ($cmd -match 'network\.mojom\.NetworkService') {
            continue
        }

        # 4. Завершаем ТОЛЬКО лишние вкладки/рендереры (renderer, utility, storage, crashpad)
        $ram = [math]::Round($h.WorkingSet / 1MB, 1)

        Stop-Process -Id $h.ProcessId -Force -ErrorAction SilentlyContinue
        $killed++

        Write-Log "SteamWebHelper offloaded: PID $($h.ProcessId), RAM $ram MB" "DarkGray"
    }

    Write-Log "SteamWebHelper offload finished: $killed processes removed" "Cyan"
}


# ====================================================================
# PROCESS WATCHING
# ====================================================================

$StartQuery = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process'"
$StopQuery  = "SELECT * FROM __InstanceDeletionEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process'"

Register-CimIndicationEvent -Query $StartQuery -SourceIdentifier "AutoGameStarted" -Action {
    try {
        $proc = $Event.SourceEventArgs.NewEvent.TargetInstance
        $state = $Global:WatchdogState
        $processId = $proc.ProcessId
        $name = $proc.Name

        # Steam started
        if ($name -eq "steam.exe") {
            $now = Get-Date
            if (($now - $state.LastSteamStart).TotalSeconds -gt 30) {
                $state.LastSteamStart = $now
                Set-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name "LastGameListUsed" -Value "largegameslist" -ErrorAction SilentlyContinue
                Write-Log "Steam started" "Cyan"
            }
            return
        }

        $exe = Resolve-ExePath -TargetInstance $proc

        if (-not $exe) {
            return
        }

        # unknown exe
        if ($state.TargetGames -notcontains $exe) {
            $state.PendingRescan[$processId] = @{
                Name      = $name
                ExePath   = $exe
                Timestamp = Get-Date
            }
            return
        }

        if ($state.ActiveProcesses.ContainsKey($processId)) {
            return
        }

        $state.ActiveProcesses[$processId] = $exe
        $count = Get-ActiveGameCount

        Write-Log "Game started: $name PID=$processId Active=$count" "Yellow"

        if ($count -eq 1) {
            Switch-SteamView -Mode "minigameslist"
            Invoke-SteamWebHelperOffload
        }
    }
    catch {
        Write-Log "Start event error: $_" "Red"
    }
} | Out-Null


Register-CimIndicationEvent -Query $StopQuery -SourceIdentifier "AutoGameStopped" -Action {
    try {
        $proc = $Event.SourceEventArgs.NewEvent.TargetInstance
        $state = $Global:WatchdogState
        $processId = $proc.ProcessId
        $name = $proc.Name

        if ($state.ActiveProcesses.ContainsKey($processId)) {
            $state.ActiveProcesses.Remove($processId)
            $count = Get-ActiveGameCount

            Write-Log "Game stopped: $name Active=$count" "Yellow"

            if ($count -eq 0) {
                Start-Sleep -Milliseconds 1500
                if ((Get-ActiveGameCount) -eq 0) {
                    Switch-SteamView -Mode "largegameslist"
                }
            }
        }
    }
    catch {
        Write-Log "Stop event error: $_" "Red"
    }
} | Out-Null

Write-Log "Steam-Watchdog active" "Green"


# ====================================================================
# PENDING MANIFEST UPDATE
# ====================================================================

function Global:Invoke-PendingManifestChecks {
    if ($Global:WatchdogState.PendingAppIds.Count -eq 0) {
        return
    }

    $now = Get-Date

    foreach ($id in @($Global:WatchdogState.PendingAppIds.Keys)) {
        $item = $Global:WatchdogState.PendingAppIds[$id]

        if (-not $item) {
            continue
        }

        if (($now - $item.LastWrite).TotalSeconds -lt 3) {
            continue
        }

        $Global:WatchdogState.PendingAppIds.Remove($id)

        if ($item.Action -eq "Remove") {
            Remove-Game -AppId $id
        }
        else {
            Add-OrUpdateGame -ManifestPath $item.ManifestPath -CommonPath $item.CommonPath
        }
    }
}


# ====================================================================
# UNKNOWN PROCESS RESCAN
# ====================================================================

function Global:Invoke-PendingRescan {
    $now = Get-Date

    foreach ($processId in @($Global:WatchdogState.PendingRescan.Keys)) {
        $item = $Global:WatchdogState.PendingRescan[$processId]

        if (-not $item) {
            continue
        }

        if (($now - $item.Timestamp).TotalSeconds -lt 5) {
            continue
        }

        $Global:WatchdogState.PendingRescan.Remove($processId)

        foreach ($library in Get-SteamLibraryPaths) {
            $steamapps = Join-Path $library "steamapps"
            $common    = Join-Path $steamapps "common"

            if (-not (Test-Path $steamapps)) {
                continue
            }

            foreach ($manifest in Get-ChildItem $steamapps -Filter "appmanifest_*.acf" -ErrorAction SilentlyContinue) {
                $game = Read-SteamManifest -ManifestPath $manifest.FullName -CommonPath $common

                if (-not $game) {
                    continue
                }

                foreach ($exe in $game.ExePaths) {
                    if ($exe -eq $item.ExePath) {
                        $Global:WatchdogState.ActiveProcesses[$processId] = $item.ExePath

                        Write-Log "Detected game: $($game.Name)" "Yellow"

                        Switch-SteamView -Mode "minigameslist"
                        Invoke-SteamWebHelperOffload
                        return
                    }
                }
            }
        }
    }
}


# ====================================================================
# MAIN LOOP
# ====================================================================

while ($true) {
    Start-Sleep -Seconds 1
    Invoke-WeeklyLogCleanup
    Invoke-PendingManifestChecks
    Invoke-PendingRescan
}
