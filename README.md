<h1 align="center">⚡ Steam Ecosystem Optimizer (SESO)</h1>

<p align="center">
  <img src="https://img.shields.io/badge/powershell-5.1-5391FE?logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows&logoColor=white" alt="Windows 10 | 11">
  <img src="https://img.shields.io/badge/size-%7E80%20KB-lightgrey" alt="~80 KB">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center">
  Cuts Steam's RAM usage by <b>~47%</b> while you play, reclaiming around <b>800 MB</b> of memory — helping reduce micro-stutters and improve 1% Low FPS.<br>
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

SESO watches for game launches in the background and surgically terminates the browser-tab renderer processes — the ones rendering the Store, Library, and Community pages — while keeping the Steam interface, Friends list, overlay, and network stack alive. When you close the game, Steam restores everything on demand.

---

## 📊 Real-World Measurements

These numbers come from `Measure-SteamRAM.ps1`, included in the project, run on a real session with Steam open in Large Library View.

These benchmarks represent average test values recorded on a laptop with  ⚠️8 GB RAM ⚠️. Actual RAM usage and savings may vary slightly depending on your system configuration and active Steam features.

### Before SESO (Large Library View, idle)

| Process | PID | RAM |
|---|---|---:|
| steamwebhelper | 13236 | 746.0 MB |
| steamwebhelper | 1032 | 453.4 MB |
| steamwebhelper | 10744 | 166.9 MB |
| steamwebhelper | 11548 | 129.9 MB |
| steam | 5228 | 97.8 MB |
| steamwebhelper | 11556 | 33.2 MB |
| steamwebhelper | 12660 | 21.4 MB |
| steamwebhelper | 11564 | 20.6 MB |
| steamservice | 10192 | 14.0 MB |
| steamwebhelper | 10400 | 13.6 MB |
| **Total** | **10 processes** | **1696.7 MB** |

### After SESO (game running, renderers offloaded)

| Process | PID | RAM |
|---|---|---:|
| steamwebhelper | 10588 | 359.0 MB |
| steamwebhelper | 10744 | 252.1 MB |
| steam | 5228 | 98.9 MB |
| steamwebhelper | 11548 | 71.2 MB |
| steamwebhelper | 6412 | 48.1 MB |
| steamwebhelper | 11556 | 32.6 MB |
| steamwebhelper | 8264 | 21.6 MB |
| steamservice | 10192 | 13.9 MB |
| **Total** | **8 processes** | **897.4 MB** |

### Summary

| Metric | Before | After | Saved |
|---|---:|---:|---:|
| Total RAM | 1696.7 MB | 897.4 MB | **799.3 MB (~47%)** |
| steamwebhelper processes | 8 | 6 | −2 |
| Total background processes | 10 | 8 | −2 |

> The surviving heavy processes (`MAIN` and `gpu-process`) are structural — they host the Steam window and GPU compositing respectively and cannot be removed without crashing the interface. SESO kills everything above that floor that can be safely respawned.

---

## 🔬 How the offload works

SESO maps each `steamwebhelper.exe` by its `--type` flag before deciding what to kill:

| CEF process type | Role | SESO action |
|---|---|---|
| `MAIN` (no flag) | Hosts all child CEF processes, owns the Steam window | **Keep** |
| `gpu-process` | GPU compositing, in-game overlay rendering | **Keep** |
| `network.mojom.NetworkService` | Network stack — Friends, notifications, overlay | **Keep** |
| `renderer` | One per open tab: Store, Library, Community | **Kill** |
| `storage.mojom.StorageService` | Browser cache service | **Kill** |
| `crashpad-handler` | Crash reporter | **Kill** |

After the offload, the Friends list remains reachable — opening it causes Steam to spin up exactly one new `renderer` (~50 MB) for that panel alone.

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

A lightweight PowerShell watchdog monitors Steam in the background.

| Event | Action |
|---|---|
| Game launched | Switches Steam to Mini Games List and offloads browser renderers |
| Game closed | Restores the Large Games List; Steam reloads tabs on demand |
| New game installed | Automatically added to the database |
| Game uninstalled | Automatically removed |
| Unknown game launched | Performs a quick rescan and applies optimization |

---

## 📏 Measuring RAM yourself

The project includes `src/Measure-SteamRAM.ps1` — the same script used to produce the numbers above.

```powershell
# Take a snapshot before starting a game
.\Measure-SteamRAM.ps1 -Label "before"

# Start a game, wait ~30 seconds for SESO to act, then snapshot again
.\Measure-SteamRAM.ps1 -Label "after"
```

Each run appends a row to `seso-ram-log.csv` so you can track results across multiple sessions. Run the pair 3–5 times on different days for a stable average.

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

No. SESO never terminates the `gpu-process` or `NetworkService` CEF processes — these are responsible for the Steam Overlay, GPU compositing, friends, notifications, and chat.  
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

No. SESO only terminates renderer-type `steamwebhelper` processes — the ones Steam safely respawns when needed. Core processes (`MAIN`, `gpu-process`, `NetworkService`) are never touched.
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
<summary><b>Why do some steamwebhelper processes remain after offload?</b></summary>
<br>

Because they're structural: `MAIN` hosts the Steam window, `gpu-process` handles GPU compositing and overlay, and `NetworkService` handles friends, notifications, and chat. Removing any of them would crash Steam — see [How the offload works](#-how-the-offload-works) for the full breakdown.
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
| `Install.ps1` | Main installer. Registers scheduled tasks and starts SESO. |
| `Uninstall.ps1` | Removes SESO, scheduled tasks, and generated files. |
| `SteamWatchdog.ps1` | Watches for game launches and exits; handles the CEF offload. |
| `SteamScanner.ps1` | Scans Steam libraries and maintains the game database. |
| `Common.ps1` | Shared helper functions. |
| `RunScannerHidden.vbs` | Starts the scanner without a visible console. |
| `RunWatchdogHidden.vbs` | Starts the watchdog without a visible console. |
| `src/Measure-SteamRAM.ps1` | Snapshots Steam RAM usage and logs results to CSV. |
| `src/Identify-SteamWebHelpers.ps1` | Maps each steamwebhelper process to its CEF role. |
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
