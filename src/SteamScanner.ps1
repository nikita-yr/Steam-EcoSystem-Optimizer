# ====================================================================

# SteamScanner.ps1 — ONE-TIME full library scan.

#

# Run once during setup (Setup.ps1) to build the initial game database.

# After this, SteamWatchdog.ps1 keeps the database in sync incrementally

# by watching for appmanifest_*.acf changes (new installs / uninstalls)

# — there is no need to ever run a full rescan again during normal use.

# ====================================================================



. (Join-Path $PSScriptRoot "Common.ps1")



$CachePath = Join-Path $PSScriptRoot "gamelist.json"



function Get-AllInstalledGames {

    $libraryPaths = Get-SteamLibraryPaths

    $games = @()



    foreach ($libPath in $libraryPaths) {

        $steamappsPath = Join-Path $libPath "steamapps"

        $commonPath    = Join-Path $steamappsPath "common"

        if (-not (Test-Path $steamappsPath)) { continue }



        $manifests = Get-ChildItem -Path $steamappsPath -Filter "appmanifest_*.acf" -ErrorAction SilentlyContinue

        foreach ($manifest in $manifests) {

            $game = Read-SteamManifest -ManifestPath $manifest.FullName -CommonPath $commonPath

            if ($game) { $games += $game }

        }

    }



    # Defensive de-duplication by AppId, in case a library path was somehow

    # picked up twice (e.g. registry value and libraryfolders.vdf entry

    # pointing at the same disk, differing only by trailing separators).

    $seen = @{}

    $deduped = @()

    foreach ($g in $games) {

        if (-not $seen.ContainsKey($g.AppId)) {

            $seen[$g.AppId] = $true

            $deduped += $g

        }

    }

    return $deduped

}



$games = Get-AllInstalledGames



$cacheObject = @{

    GeneratedAt = (Get-Date).ToString("o")

    Count       = $games.Count

    Games       = $games

}



$cacheObject | ConvertTo-Json -Depth 4 | Set-Content -Path $CachePath -Encoding UTF8



Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Initial scan complete. Found $($games.Count) games:" -ForegroundColor Green

$games | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor DarkGray }

Write-Host "Cache written to $CachePath" -ForegroundColor Green

