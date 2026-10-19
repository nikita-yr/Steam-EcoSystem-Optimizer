<h1 align="center">⚡ Steam Ecosystem Optimizer (SESO)</h1>

<p align="center">
  <img src="https://img.shields.io/badge/powershell-5.1-5391FE?logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows&logoColor=white" alt="Windows 10 | 11">
  <img src="https://img.shields.io/badge/size-%7E80%20KB-lightgrey" alt="~80 KB">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center">
  Cuts Steam's RAM footprint by <b>~75–85%</b> while you play (measured: <b>1.6 GB → 0.2–0.6 GB</b>) — helping reduce micro-stutters and improve 1% Low FPS.<br>
  No clicks. No background UI clutter. No configuration.
</p>

<p align="center">
  ⚠️ Especially beneficial for systems with <b>8 GB or 16 GB RAM</b>, where every megabyte matters.
</p>

<p align="center">
  <img width="800" height="467" alt="SESO in action during a CS2 session" src="https://github.com/user-attachments/assets/e868d474-2ab1-4d11-85d7-40d5e16905cb" />
</p>

---

## ⚡ Why SESO?

Steam keeps multiple Chromium (`steamwebhelper.exe`) processes alive even while you're in-game. Those background web views can consume **1.5–1.7 GB of RAM**, increasing paging activity and causing inconsistent frame times on memory-constrained systems.

SESO watches for game launches in the background and puts every `steamwebhelper` into a *background mode* using documented Windows APIs: its memory is moved out of RAM, it gets the lowest memory priority, Efficiency mode (EcoQoS) and below-normal CPU priority. Nothing is killed, so Steam, the overlay, friends and chat keep working. When you close the game, everything is restored.

---

## 📊 Real-World Measurements

Measured with `src/Bench-SESO.ps1` and a load test on a real system: Steam opened with Store, Community and Library pages browsed, then a game (Cossacks 3) launched.

| Moment | Steam RAM (working set) |
|---|---:|
| Before the game, Store pages loaded | **1613 MB** |
| In game, +5 s (background mode applied) | 224 MB |
| In game, +15 s | 287 MB |
| In game, +30 s | 506 MB |
| In game, +60 s | 622 MB |
| In game, +90 s (after periodic re-trim) | 194 MB |
| After the game, +30 s (restored) | 807 MB |

Over two weeks of normal use the watchdog log shows **560–1580 MB** moved out of RAM at every game launch.

### Why not just kill the renderers?

Earlier versions killed `steamwebhelper` renderers. Measured, it made things worse: Steam respawned them within seconds and total RAM went **up by 160 MB** (still +94 MB after 2 minutes). Background mode keeps the processes and only takes their memory away.

---

## 🔬 How background mode works

| Measure | Windows API | Effect |
|---|---|---|
| Trim working set | `EmptyWorkingSet` | Pages leave RAM; they return only if Steam actually touches them |
| Very low memory priority | `SetProcessInformation(ProcessMemoryPriority)` | Under memory pressure Windows evicts Steam's pages first, not the game's |
| Efficiency mode (EcoQoS) | `SetProcessInformation(ProcessPowerThrottling)` | Scheduler runs Steam on efficient cores/clocks |
| Below-normal CPU priority | `PriorityClass` | Steam never competes with the game for CPU |

The trim is repeated 20 s after launch (Steam is busy with overlay/cloud sync right then) and every 60 s while you play. Everything is reverted 15 s after the last game exits — so switching from one game to another does not flip the Steam UI back and forth.

---

## 🚀 Quick Installation

Open **PowerShell**. Administrator privileges are **not required** initially — the installer will request elevation automatically if needed.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; $repoUrl = "https://github.com/nikita-yr/Steam-EcoSystem-Optimizer/archive/refs/heads/main.zip"; $destDir = "C:\Scripts"; $zipFile = "$destDir\seso.zip"; if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }; Invoke-WebRequest -Uri $repoUrl -OutFile $zipFile; Expand-Archive -Path $zipFile -DestinationPath $destDir -Force; Remove-Item -Path $zipFile -Force; Set-Location "$destDir\Steam-EcoSystem-Optimizer-main"; .\Install.ps1
```

### What the installer does

1. Temporarily bypasses the execution policy for the current PowerShell session.
2. Creates `C:\Scripts` if it doesn't exist.
3. Downloads the latest version directly from GitHub.
4. Extracts the project.
5. Runs `Install.ps1`.
6. Registers scheduled tasks and background workers.

---

## ⚙️ How It Works

A lightweight PowerShell watchdog monitors Steam in the background. It uses the event-driven ETW process trace (no polling) and only reacts to processes from `steamapps\common`, so it does no work while you are not starting games.

| Event | Action |
|---|---|
| Game launched | Switches Steam to Mini Games List and puts `steamwebhelper` into background mode |
| Game closed | After 15 s without games, restores normal mode and the Large Games List |
| New game installed | Automatically added to the database |
| Game uninstalled | Automatically removed |
| Unknown game launched | Reads only the manifest that owns that folder (~5 ms instead of a full ~130 ms rescan) and remembers the game |

---

## 📏 Measuring RAM yourself

`src/Bench-SESO.ps1` reproduces the numbers above:

```powershell
cd C:\Scripts\Steam-EcoSystem-Optimizer-main\src
powershell -ExecutionPolicy Bypass -File .\Bench-SESO.ps1 -Steam
```

It measures the cost of game detection, then Steam RAM in Mini Games List alone vs. Mini Games List + background mode, and writes the results to `seso-bench.txt`. Run it with Steam open and no game running.

`src/Measure-SteamRAM.ps1 -Label "before"` / `-Label "after"` takes simple snapshots into `seso-ram-log.csv`.

---

## 🖥️ Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 (included with Windows)
- Steam

> **Not supported:** Linux and macOS — SESO relies on Windows Task Scheduler and Steam's Windows registry keys, so it won't work under Wine/Proton or on non-Windows systems.

---

## ❓ FAQ

<details>
<summary><b>Is SESO safe? Can it cause a VAC ban?</b></summary>
<br>

Yes, it's safe. SESO only interacts with Steam's own Chromium helper processes. It does not modify game files, game memory, or anything monitored by anti-cheat systems. VAC does not care about Steam UI processes.
</details>

<details>
<summary><b>Is SESO open-source? Can I review the code before running it?</b></summary>
<br>

Yes — everything is in this repository. `Install.ps1`, `SteamWatchdog.ps1`, and every other script are plain, readable PowerShell with no obfuscation or compiled binaries. Read through the [Project Files](#-project-files) section before running the installer if you want to verify what it does first.
</details>

<details>
<summary><b>Does SESO affect the Steam Overlay or disable any Steam features?</b></summary>
<br>

No. SESO does not terminate any Steam process — it only lowers their priority and moves their memory out of RAM.  
All core Steam functionality remains fully operational during gameplay, including the overlay, screenshots, chat, and the friends list.
</details>

<details>
<summary><b>Will this touch my Steam account, password, or saved games?</b></summary>
<br>

No. SESO only reads local process and registry information to detect installed/running games and switch the library view. It never touches your Steam credentials, cloud saves, or game files.
</details>

<details>
<summary><b>Does SESO work on Steam Deck, Linux, or macOS?</b></summary>
<br>

No. SESO relies on:

- Windows Task Scheduler
- PowerShell 5.1
- Steam's Windows registry keys

It will not run under Proton/Wine or on non-Windows systems.
</details>

<details>
<summary><b>Do I need to keep PowerShell open?</b></summary>
<br>

No. The watchdog runs silently in the background via Task Scheduler.
</details>

<details>
<summary><b>Can SESO break Steam?</b></summary>
<br>

No. SESO never kills Steam processes. It uses the same documented Windows APIs that Task Manager's Efficiency mode uses, and reverts everything when you stop playing.
</details>

<details>
<summary><b>Will Steam restore the interface after I close a game?</b></summary>
<br>

Yes. Steam automatically reloads the Store, Library, and Community tabs on demand.
</details>

<details>
<summary><b>Does SESO increase FPS?</b></summary>
<br>

Indirectly. By reducing RAM pressure and paging, SESO improves frame-time consistency, micro-stutter frequency, and 1% Low FPS stability. It does not "boost FPS" directly — there's no GPU or CPU optimization involved.
</details>

<details>
<summary><b>Can I configure SESO?</b></summary>
<br>

No. SESO is intentionally zero-configuration to avoid UI clutter and ensure safe defaults.
</details>

<details>
<summary><b>Does SESO work with the Steam Beta Client?</b></summary>
<br>

Yes, but behavior may vary slightly if Valve changes the underlying CEF process structure.
</details>

<details>
<summary><b>Why does Steam's RAM grow back a bit during the game?</b></summary>
<br>

Trimmed pages come back only when Steam touches them (Mini Games List, overlay, downloads). SESO re-trims every 60 s, so Steam stays in the 0.2–0.6 GB range instead of 1.6 GB.
</details>

<details>
<summary><b>Can I disable or remove SESO?</b></summary>
<br>

Yes, from an elevated PowerShell window:

```powershell
.\Uninstall.ps1
```

This removes scheduled tasks, background workers, logs, and the installation directory.
</details>

---

## 📦 Manual Installation

Clone or download the repository and run from an elevated PowerShell window:

```powershell
.\Install.ps1
```

---

## 🔍 Checking Status

**Watchdog**

```powershell
Get-ScheduledTask -TaskName "SteamWatchdogOnLogon"
```

**Game database**

```powershell
(Get-Content .\gamelist.json | ConvertFrom-Json).Games | Select-Object Name, AppId
```

**Live log**

```powershell
Get-Content .\watchdog.log -Wait
```

---

## 📁 Project Files

| File | Description |
|---|---|
| `Install.ps1` | Installer and updater. Stops an older SESO, scans libraries once, registers and starts the watchdog. |
| `Uninstall.ps1` | Removes SESO, scheduled tasks, and generated files. |
| `SteamWatchdog.ps1` | Watches for game launches and exits; switches Steam to background mode. |
| `SteamScanner.ps1` | One-time full library scan (run by the installer). |
| `Common.ps1` | Shared helpers: library scan, manifest parsing, background mode. |
| `RunWatchdogHidden.vbs` | Starts the watchdog without a visible console. |
| `src/Measure-SteamRAM.ps1` | Snapshots Steam RAM usage and logs results to CSV. |
| `src/Bench-SESO.ps1` | Benchmark: detection cost and Steam RAM with/without background mode. |
| `gamelist.json` | Automatically generated game database. |
| `watchdog.log` | Runtime log file. |

---


## 🛑 Uninstallation

Run the following from an elevated PowerShell window:

```powershell
Set-Location "C:\Scripts\Steam-EcoSystem-Optimizer-main"
.\Uninstall.ps1
```

The uninstaller automatically:

- Stops background processes
- Removes scheduled tasks
- Deletes logs
- Removes the installation directory

---
## 📄 License

Licensed under the [MIT License](LICENSE).
