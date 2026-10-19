<#
.SYNOPSIS
    SESO efficiency benchmark. Run from the repo's src folder:
      powershell -ExecutionPolicy Bypass -File .\Bench-SESO.ps1            # overhead tests only
      powershell -ExecutionPolicy Bypass -File .\Bench-SESO.ps1 -Steam     # + Steam RAM/CPU test (Steam open, no game running)
    Results go to the console and to seso-bench.txt.
#>
param([switch]$Steam, [int]$Seconds = 60)

. (Join-Path $PSScriptRoot "Common.ps1")
$out = Join-Path $PSScriptRoot "seso-bench.txt"
function Out-Bench($s) { Write-Host $s; Add-Content $out $s -Encoding UTF8 }
function Avg($block) { $r = 1..5 | % { (Measure-Command $block).TotalMilliseconds }; [math]::Round(($r | Measure-Object -Average).Average, 1) }
Out-Bench "`n===== SESO bench $(Get-Date -Format s) ====="

# --- 1. Unknown-exe lookup: old full rescan vs new targeted lookup ---
$old = Avg {
    foreach ($lib in Get-SteamLibraryPaths) {
        $sa = Join-Path $lib "steamapps"
        foreach ($m in Get-ChildItem $sa -Filter "appmanifest_*.acf" -ErrorAction SilentlyContinue) {
            $dir = [regex]::Match((Get-Content $m.FullName -Raw), '"installdir"\s+"([^"]+)"').Groups[1].Value
            $null = Get-ChildItem (Join-Path "$sa\common" $dir) -Filter "*.exe" -Recurse -Depth 2 -ErrorAction SilentlyContinue
        }
    }
}
$new = Avg {
    foreach ($lib in Get-SteamLibraryPaths) {
        foreach ($m in Get-ChildItem (Join-Path $lib "steamapps") -Filter "appmanifest_*.acf" -ErrorAction SilentlyContinue) {
            $null = [regex]::Match([IO.File]::ReadAllText($m.FullName), '"installdir"\s+"([^"]+)"')
        }
    }
}
Out-Bench "[1] Unknown exe lookup: old full rescan $old ms -> new targeted $new ms"

# --- 2. How many process starts would trigger work ---
$global:benchAll = 0; $global:benchSteam = 0
Register-CimIndicationEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process'" -SourceIdentifier BenchStart -Action {
    $global:benchAll++
    if ("$($Event.SourceEventArgs.NewEvent.TargetInstance.ExecutablePath)" -like "*\steamapps\common\*") { $global:benchSteam++ }
} | Out-Null
Write-Host "Sampling process starts for $Seconds s..."
Start-Sleep $Seconds
Unregister-Event BenchStart
Out-Bench "[2] Process starts in $Seconds s: $benchAll (old watchdog: $benchAll rescans; new: $benchSteam)"

# --- 3. Steam: Mini list only vs Mini list + background mode ---
if ($Steam) {
    function Snap {
        $p = @(Get-Process steam*, steamwebhelper -ErrorAction SilentlyContinue)
        [PSCustomObject]@{
            MB  = [math]::Round(($p | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
            CPU = ($p | % { $_.TotalProcessorTime.TotalMilliseconds } | Measure-Object -Sum).Sum
            H   = @($p | ? { $_.ProcessName -eq "steamwebhelper" }).Count
        }
    }
    $s0 = Snap
    Out-Bench "[3] Large list idle: $($s0.MB) MB, helpers $($s0.H)"

    Start-Process "steam://open/minigameslist"
    Start-Sleep 30; $a = Snap; Start-Sleep 60; $b = Snap
    Out-Bench "    A) Mini list only:      $($b.MB) MB, helpers $($b.H), Steam CPU $([math]::Round($b.CPU - $a.CPU)) ms / 60 s"

    $r = Set-SteamHelpersMode -Mode Game
    $c = Snap
    Out-Bench "    B) + background mode:   $($c.MB) MB right after (trimmed $($r.TrimmedMB) MB in $($r.Count) helpers)"
    $last = 0
    foreach ($t in 10, 30, 60) {
        Start-Sleep ($t - $last); $last = $t
        $now = Snap
        Out-Bench ("       t+{0,2}s: {1} MB, helpers {2}" -f $t, $now.MB, $now.H)
    }
    Out-Bench "       Steam CPU in background mode: $([math]::Round($now.CPU - $c.CPU)) ms / 60 s"
    $r = Set-SteamHelpersMode -Mode Game
    Out-Bench "       Re-trim after 60 s (watchdog does this every 60 s): $($r.TrimmedMB) MB, now $((Snap).MB) MB"

    Set-SteamHelpersMode -Mode Normal | Out-Null
    Start-Process "steam://open/largegameslist"
    Out-Bench "    Saved vs large list: Mini only $([math]::Round($s0.MB - $b.MB)) MB, Mini+background $([math]::Round($s0.MB - $now.MB)) MB (after 60 s regrowth)"
}
Out-Bench "Saved to $out"
