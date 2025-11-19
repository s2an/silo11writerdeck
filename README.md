# silo11writerdeck

![Python 3](https://img.shields.io/badge/Python-3.11-2d2d2d?style=for-the-badge&logo=python&logoColor=ffcc33)
![Bash](https://img.shields.io/badge/Bash-2d2d2d?style=for-the-badge&logo=gnu-bash&logoColor=bfbfbf)
![systemd](https://img.shields.io/badge/systemd-2d2d2d?style=for-the-badge&logo=systemd&logoColor=c0c0c0)
![curses TUI](https://img.shields.io/badge/curses%20TUI-2d2d2d?style=for-the-badge&logo=gnome-terminal&logoColor=bfbfbf)

![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-2d2d2d?style=for-the-badge&logo=raspberrypi&logoColor=b36363)
![Raspbian](https://img.shields.io/badge/Raspbian-2d2d2d?style=for-the-badge&logo=raspberrypi&logoColor=ffcc66)
![Debian](https://img.shields.io/badge/Debian-2d2d2d?style=for-the-badge&logo=debian&logoColor=ba5c5c)
![macOS](https://img.shields.io/badge/macOS-2d2d2d?style=for-the-badge&logo=apple&logoColor=cccccc)

## Description

silo11writerdeck turns Raspberry Pi, macOS, and apt/systemd-based Linux systems into a distraction-free writing environment, featuring a curses-driven TUI, curated editors, integrated Linux utilities, and a retro post-apocalyptic aesthetic.

> ⚠️ **BEWARE:** Development stage: Pre-Beta (unstable). The wastes are harsh and unforgiving. Everything may fail. Nothing may work. All is harvested from the scraps left behind. Be thankful that you are here at all.
>
> ⚙️ **Signal uplink established.**
> silo11writerdeck boots from the ruins to provide a **distraction-free writing deck** for surviving scribes bunkering down to escape the harshness of the wastes and record the last signals of humanity.
>
> Built for **Raspberry Pi (Raspbian/Debian)** and **macOS**, it’s a **curses-driven control terminal** forged for low-power field use — offline, hardened, and bunker-ready.
>
> 🧭 *Status: ACTIVE BUILD.*
> Unauthorized modules (Custom HTTP Exporter, Auto Bluetooth Agent, Display Hijacker) remain sealed behind the **Unauthorized Zone** during their construction.

---

## Table of Contents

* [Description](#description)
* [Field Manual](#field-manual)
  * [Core Systems](#core-systems)
  * [Writing Suite](#writing-suite)
  * [File Operations](#file-operations)
  * [Network Tools](#network-tools)
  * [Visual Control & Themes](#visual-control--themes)
  * [Power Controls](#power-controls)
  * [Unauthorized Zone](#unauthorized-zone)
* [Pre-Installation](#pre-installation)
  * [Raspberry Pi](#raspberry-pi)
  * [Debian](#debian)
  * [macOS](#macos)
  * [Requirements](#requirements)
* [Quick Start Installation](#quick-start-installation)
* [Installation Walkthrough](#installation-walkthrough)
  * [Linux / Raspberry Pi](#linuxraspberry-pi)
  * [macOS](#macos-1)
* [Health Diagnostics](#health-diagnostics)
* [Update Routine](#update-routine)
* [Uninstall Procedure](#uninstall-procedure)
* [Silo Directory Layout](#silo-directory-layout)
* [Incident Recovery (Troubleshooting)](#incident-recovery-troubleshooting)
* [Future Signals (Roadmap)](#future-signals-roadmap)
* [Contributing Agents](#contributing-agents)
* [License](#license)

---

## Field Manual

### Core Systems

* **Silo-style curses HUD launcher** — patina flicker, riveted frames, hazard-striped headers, and beacon footers.
* **Keyboard-driven navigation:** arrows ↑↓, **Enter** to confirm, **ESC / Back** to retreat. Programs are primarily requisitioned to work without a mouse.
* Built with **Python 3.11** and **Bash** — so (almost) any salvaged devices is workable.

---

### Writing Suite

Each tool is a different kind of weapon — some light, some heavy, all forged for field conditions.
Run any from the HUD, or let **Last Used** remember your favorite loadout.

* **Diary** *(macOS only, under construction)* — personal command-line journal for daily logs, reflections, and mission notes. Minimal, persistent, and private.
* **Emacs** — the *Eternal Editor.* A relic from before the collapse — vast, self-contained, intimidating.
* **Gedit** *(macOS only, under construction)* — graphical fallback for surface dwellers. Functional, but heavy on resources.
* **Nano** — the **micro-scribe**. Perfect for quick field entries or emergency note patches. Lightweight, unkillable.
* **Obsidian** *(macOS only)* — modern GUI vault for linked notes and long-form writing. Beautiful but power-hungry.
* **Vim** — precision editor for veterans. Requires discipline, rewards mastery. *For those who fear no modal interface.*
* **WordGrinder** — long-form fortress for prose. Works entirely offline, immune to distractions, EMPs, and notifications. (Where all novices start.)

---

### File Operations

* **Embedded HTTP Server:**
  Secure local relay using Python’s `http.server`, serving from:

  ```
  ~/silo11writerdeck/!save_files_here
  ```

  URL is printed on the HUD when active. Accessible from any browser in the local network.
  *(Broadcast stays LAN-bound — safe within the perimeter.)*

---

### Network Tools

#### Linux
* **Wi-Fi Control:** Launches `nmtui` for scanning and connecting. 
  - *Experimental:* `wpa_cli` workflows exist in the unauthorized sector.
* **Bluetooth Relay:** Simplified `bluetoothctl` shell for **pair/trust/connect** cycles.
  - *Prototype auto-agent in development: boot-time trust loop for easy salvage of peripherals.*

#### macOS
* **Not Supported:** Use the built-in System Settings.

---

### Visual Control & Themes

* **Rotation Module (Linux-only):** 0° / 90° / 180° / 270° — for when your scavenged screen is sideways.
* **Theme Selector:**
  - `Day ☀` – clean & bright
  - `Night ☾` – green/blue phosphor HUD
  - `Toxic ☣` – hazard glow under emergency lighting
  
*Feature Under Construction:* `Repaired` - a mode to remove the static from the screen.

---

### Power Controls

#### Linux
* **Shutdown** and **Reboot** with confirmation interlocks.
* **Wi-Fi / Bluetooth toggles** for power saving and stealth ops.

#### macOS
* **Not Supported:** Use the built-in System Settings.
---

### Unauthorized Zone

* **HTTP Exporter 2.0** — modular LAN courier server.
* **Auto Bluetooth Agent** — auto-pair/trust/connect at boot.
* **Wi-Fi Recovery Daemon** — reconnect logic and silent scans.
* **Display Hijacker** — mirror the HUD to an old tablet display (plug a Pi into any screen to take it over).
* **Vault Linker** — experimental content archiver (auto-save).

---

### 🧭 Pre-Installation

| OS                                    | Supported  | Notes                                 |
| ------------------------------------- | ---------- | ------------------------------------- |
| **Raspberry Pi OS (Bookworm/Trixie)** | ✅          | Full feature support                  |
| **Debian (apt + systemd)**            | ✅          | Full feature support                  |
| **Ubuntu / Linux Mint / Pop!_OS**     | ⚠️ partial | Works, but not officially targeted    |
| **macOS (Intel / Apple Silicon)**     | ✅          | No Linux-specific system utilities    |
| **Fedora / Arch / Alpine / Void**     | ❌          | Not supported (non-apt or no systemd) |

#### 🫐 Raspberry Pi

For the smoothest setup, use **Raspberry Pi Imager:** https://www.raspberrypi.com/software/

When prompted, **enter your Wi-Fi and SSH credentials** — this makes it easy to connect to your pi from another computer to install the program. (Disregard if your Pi is already set up with peripherals!)

Select:

* **Device:** your Pi model (e.g., *Pi 5*, *Zero 2 W*, etc.)
* **OS:** `Raspberry Pi OS Lite` → *(terminal-only experience, ideal for silo11writerdeck)*
* **Storage:** your microsd card ready for flashing

---

#### 🪶 Debian

Perfect for reclaiming an old laptop or breathing life into spare hardware.
Download and install **Debian** (https://www.debian.org/distrib/netinst).

The installer is long but simple — just **accept the defaults** and **skip the GUI** for a clean, terminal-only system. (You will need your password during silo11writerdeck installation!)

---

#### 🍎 macOS

Already have a MacBook or desktop lying around?

If it’s feeling sluggish, you can either:

* install **silo11writerdeck directly on macOS**, or
* **install Debian** on it for a lightweight, terminal-only revival.
  *(A fresh Debian install can make older Macs feel brand new.)*

---

#### Requirements

**Linux (Raspberry Pi / Debian / Raspbian)**

* Internet connection
* `git` — to pull the repo from the uplink
* `systemd` — already standard on most Pi and Debian installs

**macOS**

* Internet connection
* **Homebrew** package manager (`brew`)
* `git` — to pull the repo from the uplink

---

### Quick Start Installation

#### Linux (Raspberry Pi / Debian)

```bash
sudo apt update
sudo apt install git -y
git clone https://github.com/s2an/silo11writerdeck.git
cd silo11writerdeck
bash install-silo11writerdeck.sh
```
#### macOS

```bash
brew install git
git clone https://github.com/s2an/silo11writerdeck.git
cd silo11writerdeck
bash install-silo11writerdeck.sh
```

### Installation Walkthrough

#### Linux/Raspberry Pi

1. **Install prerequisites**

   ```bash
   sudo apt update
   sudo apt upgrade
   sudo apt install git -y
   ```

2. **Clone and deploy**

   ```bash
   cd ~
   git clone https://github.com/.../silo11writerdeck.git
   cd silo11writerdeck
   bash ./install-silo11writerdeck.sh
   ```

3. **Choose your deployment mode**

   During installation, you’ll be prompted to enter **sudo (password)** permission and then how the program should initialize:

   * **System** *(default)* — launches **silo11writerdeck** at boot, bypassing login and binding directly to `tty1`.
   * **User** — runs under your user session (multi-user compatible).
   * **Linger** — enables persistent user services that survive logout (prompt during user install).
   * **None** — disables autostart; run manually from any terminal with `silo11writerdeck`.

   *(These settings can be changed later through the updater.)*

#### macOS

1. **Install prerequisites**

   Visit [brew.sh](https://brew.sh) for installation instructions, or run:

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

*Note: During installation, you’ll be prompted to enter **sudo (password)** permission.*

2. **Clone and deploy**

   ```bash
   cd ~
   git clone https://github.com/.../silo11writerdeck.git
   cd silo11writerdeck
   bash ./install-silo11writerdeck.sh
   ```
3. **Add to PATH**

*NOTE: After a successful installation you’ll be prompted to add `silo11writerdeck` to your PATH, or it will become available after opening a new terminal session.*

> ☑️ **Once complete:**
> Run `silo11writerdeck` from your terminal to enter the HUD.
> Use the updater anytime to reconfigure your deployment or refresh the build.

---

### Health Diagnostics

* **From within the HUD:** `System Maintenance → Health Check`

  *NOTE: It may hang for a while before refreshing*

* **From the terminal:**

  ```bash
  bash ./healthcheck-silo11writerdeck.sh
  ```

Performs a full diagnostic sweep:

* Wrapper integrity (`~/.local/bin/silo11writerdeck`)
* Repo path & manifest sync
* Active `systemd` units (TTY or user)
* Optional linger & Bluetooth agent states

---

### Update Routine

* **From within the HUD:** `System Maintenance → Update`
* **From the terminal:**

  ```bash
  bash ./update-silo11writerdeck.sh
  ```

Performs a **safe sync** — no data loss, reconciles wrappers and user services.
If the repo path is missing, the updater prompts for re-installation.

---

### Uninstall Procedure

* **From within the HUD:** `System Maintenance → Uninstall`
* **From the terminal:**

  ```bash
  bash ./uninstall-silo11writerdeck.sh
  ```

Removes system/user units, launcher wrappers, and logs while preserving your writing archives.

*NOTE: After backing up the `!save_files_here` directory, you may delete the entire repo:*

```bash
rm -rf ~/silo11writerdeck
```

---

## Silo Directory Layout

```
silo11writerdeck/
├─ install-silo11writerdeck.sh       # deployment crate
├─ update-silo11writerdeck.sh        # synchronization patcher
├─ uninstall-silo11writerdeck.sh     # clean removal routine
├─ healthcheck-silo11writerdeck.sh   # diagnostics probe
├─ systemd/
│  ├─ user/silo11writerdeck-tui.service
│  └─ system/silo11writerdeck-tty.service
├─ tui/
│  ├─ menu.py
│  ├─ actions.py
│  ├─ theme.py
│  ├─ view.py
│  └─ widgets.py
├─ !save_files_here/                 # export chamber
└─ unauthorized_zone/                # experimental modules (sealed)
```

---

## Incident Recovery (Troubleshooting)

| Symptom                               | Remedy                                                                    |
| ------------------------------------- | ------------------------------------------------------------------------- |
| **HUD not found / command not found** | Add `~/.local/bin` to `PATH`, or rerun installer.                         |
| **TTY1 blank / boot hang**            | Inspect logs: `sudo journalctl -u silo11writerdeck-tty.service -e`.       |
| **Export server offline**             | Verify LAN connection, retry browser, or try a different browser; confirm no firewall interference. |
| **Bluetooth fails pairing**           | Fallback to manual `bluetoothctl` pairing until agent is deployed.        |
| **No internet for update**            | Updater fails gracefully with ⚠️ and suggests reinstall when online.      |

---

## Future Signals (Roadmap)

- **macOS Auto-Start** — a mac mirror installation option to allow silo11writerdeck to launch upon opening a terminal shell and to auto-launch a terminal shell after logging in to your macOS device.
- **Display Hijacker** — tablet mirror via browser view or VNC stub.
- **Auto Bluetooth Agent** — easy link to salvaged peripherals without needing a peripheral (auto-connect to a device in pairing mode during boot; Linux-only).
- **Vault Mode** — encrypted archive of writing output for long-term preservation (auto-save).
- **Theme Expansion** — add a repaired mode to clean the static from the screen.
- **HTTP Exporter 2.0** — structured endpoints, file sanitization, live HUD status.
- **Wi-Fi Recovery Daemon** — automatic reconnect on network loss.

---

## Contributing Agents

Contributions welcome — but keep them disciplined:

* One module per pull request.
* Preserve **SRP (Single Responsibility Principle)**.
* File all prototype work in `/unauthorized_zone` until stable.
* Document your commits with **sector logs** and **hazard tags**.

---

## License

**MIT** — open to the scavengers, scribes, and engineers of Sector 11.

> ⛓️ *“We write what the world forgot.”* ⛓️
