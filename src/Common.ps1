# ====================================================================
# Common.ps1 — Shared functions for Steam library scanning and manifest
# parsing. Dot-sourced by both SteamScanner.ps1 and SteamWatchdog.ps1
# to avoid duplicating logic between the one-time scan and the
# incremental live-update watcher.
# ====================================================================

# Executable names that are never the "real" game launcher, even though
# they live inside a game's install folder.
$Global:ExcludedNames = @(
    "unitycrashhandler", "unins000", "gldriverquery", "vulkaninfo",
    "dxwebsetup", "vcredist", "directx", "setup", "crashreporter",
    "easyanticheat", "battleye", "eossetup", "epiconlineservices",
    "cleanup", "touchup", "activationui", "overlayinjector",
    "7za", "sendrpt", "bugreporter", "launchpad", "webhelper",
    "webengineprocess", "anticheat", "installer", "config", "editor",
    "modman", "addoninstaller", "bsndrpt"
)

# Subfolders that only ever contain installers/redistributables/SDK tools,
# never the actual game binary.
$Global:ExcludedFolders = @(
    "_commonredist", "redist", "directx", "support",
    "__installer", "__overlay", "crash_handler", "crashreporter"
)

function Global:Get-SteamLibraryPaths {
    <#
        Returns every Steam library root path (the folder that directly
        contains "steamapps"), deduplicated and normalized. Reads the
        main install path from the registry and additional libraries
        from libraryfolders.vdf.
    #>
    try {
        $steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath
    } catch { return @() }
    if (-not $steamPath) { return @() }

    $libraryFile = Join-Path $steamPath "steamapps\libraryfolders.vdf"
    $paths = @($steamPath)

    if (Test-Path $libraryFile) {
        $content = Get-Content $libraryFile -Raw -Encoding UTF8
        $matches = [regex]::Matches($content, '"path"\s+"([^"]+)"')
        foreach ($m in $matches) {
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            if (Test-Path $p) { $paths += $p }
        }
    }

    # Normalize: lowercase + strip trailing backslash, so the same library
    # referenced twice (registry vs. libraryfolders.vdf) is not duplicated.
    return $paths | ForEach-Object { $_.Replace('/', '\').ToLower().TrimEnd('\') } | Select-Object -Unique
}

function Global:Get-GameExesInFolder {
    <#
        Finds candidate game executables inside a single game's install
        folder, excluding known junk (installers, redist, SDK tools).
        Uses .NET's Directory.EnumerateFiles for speed on large trees.
    #>
    param($FolderPath)

    if (-not (Test-Path $FolderPath)) { return @() }

    $rawFiles = @()
    try {
        $rawFiles = [System.IO.Directory]::EnumerateFiles($FolderPath, "*.exe", [System.IO.SearchOption]::AllDirectories)
    } catch {
        # .NET enumeration throws on the very first inaccessible folder it hits.
        # Fall back to the slower but more forgiving Get-ChildItem in that case.
        return Get-ChildItem -Path $FolderPath -Filter "*.exe" -Recurse -Depth 6 -ErrorAction SilentlyContinue |
            Where-Object {
                $folderLower = $_.DirectoryName.ToLower()
                -not ($Global:ExcludedFolders | Where-Object { $folderLower -like "*$_*" })
            } |
            Where-Object {
                $nameLower = $_.BaseName.ToLower()
                -not ($Global:ExcludedNames | Where-Object { $nameLower -like "*$_*" })
            } |
            Select-Object -ExpandProperty FullName
    }

    return $rawFiles | Where-Object {
        $folderLower = (Split-Path $_ -Parent).ToLower()
        $nameLower   = ([System.IO.Path]::GetFileNameWithoutExtension($_)).ToLower()
        (-not ($Global:ExcludedFolders | Where-Object { $folderLower -like "*$_*" })) -and
        (-not ($Global:ExcludedNames | Where-Object { $nameLower -like "*$_*" }))
    }
}

function Global:Get-AppIdFromManifestPath {
    <#
        Extracts the numeric Steam AppID from a manifest file PATH alone
        (e.g. "appmanifest_730.acf" -> "730"). Works even after the file
        has already been deleted, since it only needs the file name.
    #>
    param($ManifestPath)

    $fileName = Split-Path $ManifestPath -Leaf
    $match = [regex]::Match($fileName, 'appmanifest_(\d+)\.acf')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Global:Read-SteamManifest {
    <#
        Parses a single appmanifest_*.acf file and returns a PSCustomObject
        with AppId, Name, InstallDir, ExePaths — or $null if the manifest
        could not be read or has no usable executables (e.g. still
        downloading, or a tool/DLC-only entry with no binary).
    #>
    param($ManifestPath, $CommonPath)

    if (-not (Test-Path $ManifestPath)) { return $null }

    $appId = Get-AppIdFromManifestPath -ManifestPath $ManifestPath
    if (-not $appId) { return $null }

    $content = $null
    # The manifest may still be mid-write when the Created event fires,
    # so retry briefly before giving up.
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $content = Get-Content $ManifestPath -Raw -Encoding UTF8 -ErrorAction Stop
            if ($content) { break }
        } catch {}
        Start-Sleep -Milliseconds 400
    }
    if (-not $content) { return $null }

    $nameMatch = [regex]::Match($content, '"name"\s+"([^"]+)"')
    $dirMatch  = [regex]::Match($content, '"installdir"\s+"([^"]+)"')
    if (-not $nameMatch.Success -or -not $dirMatch.Success) { return $null }

    $gameName   = $nameMatch.Groups[1].Value
    $installDir = $dirMatch.Groups[1].Value
    $gameFolder = Join-Path $CommonPath $installDir

    $exes = Get-GameExesInFolder -FolderPath $gameFolder
    if ($exes.Count -eq 0) { return $null }

    return [PSCustomObject]@{
        AppId    = $appId
        Name     = $gameName
        ExePaths = @($exes)
    }
}

# ====================================================================
# STEAMWEBHELPER LOAD REDUCTION (no killing)
#
# Killing renderers does not work: Steam respawns them within seconds and
# total RAM ends up higher (measured: +160 MB after 10 s). Instead, while a
# game runs, every steamwebhelper is put into a "background" state using
# documented Windows APIs:
#   - EmptyWorkingSet: moves its pages out of RAM (they come back on demand)
#   - Memory priority VERY_LOW: its pages are the first to go under pressure
#   - EcoQoS / Efficiency mode: scheduler runs it on efficient cores/clocks
#   - BelowNormal CPU priority: never competes with the game
# Everything is reverted when the last game exits.
# ====================================================================

if (-not ('SESO.Native' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace SESO {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)] struct PowerThrottling { public uint Version, ControlMask, StateMask; }
        [StructLayout(LayoutKind.Sequential)] struct MemPriority { public uint Priority; }
        [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h);
        [DllImport("kernel32.dll")] static extern bool SetProcessInformation(IntPtr h, int cls, ref PowerThrottling i, int size);
        [DllImport("kernel32.dll")] static extern bool SetProcessInformation(IntPtr h, int cls, ref MemPriority i, int size);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, System.Text.StringBuilder name, ref int size);
        // Works immediately after process creation (Process.Path does not)
        public static string GetPath(int pid) {
            IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
            if (h == IntPtr.Zero) return null;
            try {
                var sb = new System.Text.StringBuilder(1024); int size = sb.Capacity;
                return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : null;
            } finally { CloseHandle(h); }
        }
        // ProcessPowerThrottling = 4, ProcessMemoryPriority = 0
        public static void SetBackground(IntPtr h, bool on) {
            var pt = new PowerThrottling { Version = 1, ControlMask = 1, StateMask = on ? 1u : 0u };
            SetProcessInformation(h, 4, ref pt, Marshal.SizeOf(pt));
            var mp = new MemPriority { Priority = on ? 1u : 5u };
            SetProcessInformation(h, 0, ref mp, Marshal.SizeOf(mp));
        }
    }
}
"@
}

function Global:Set-SteamHelpersMode {
    <#
        -Mode Game   : background state + trim working set (repeatable, cheap)
        -Mode Normal : restore defaults
        Returns count of processes touched and MB trimmed.
    #>
    param([ValidateSet("Game", "Normal")] $Mode)

    $count = 0
    $trimmed = 0L
    foreach ($p in Get-Process steamwebhelper -ErrorAction SilentlyContinue) {
        try {
            $h = $p.Handle
            if ($Mode -eq "Game") {
                $before = $p.WorkingSet64
                $p.PriorityClass = "BelowNormal"
                [SESO.Native]::SetBackground($h, $true)
                [void][SESO.Native]::EmptyWorkingSet($h)
                $p.Refresh()
                $trimmed += $before - $p.WorkingSet64
            }
            else {
                $p.PriorityClass = "Normal"
                [SESO.Native]::SetBackground($h, $false)
            }
            $count++
        }
        catch {}
        finally { $p.Dispose() }
    }
    return [PSCustomObject]@{ Count = $count; TrimmedMB = [math]::Round($trimmed / 1MB, 1) }
}
