# Development setup

This repository is structured for Rojo-driven Roblox development. Follow the steps below to get a reproducible environment for editing scripts and testing the game loop locally.

## Prerequisites
- **Roblox Studio** with the Rojo plugin installed so you can attach to `rojo serve` sessions.
- **Rojo CLI 7.4+** – required for `rojo serve` and `rojo build`. A Windows binary (`rojo.exe`) is included at the repository root; macOS/Linux users should install Rojo via Cargo or download a release build.
- **Git** for source control and dependency syncing.
- (Optional) **VS Code** or another Luau-aware editor for IntelliSense and linting.

## First-time setup
1. Clone the repository and open a shell at the project root.
2. Install Rojo if it is not already present and add it to your PATH.
3. In Roblox Studio, enable **API Services** in `Game Settings > Security` if you plan to test DataStore-powered systems like `SaveService` locally.【F:ServerScriptService/Data/SaveService.lua†L1-L40】
4. Start a live sync session:
   ```bash
   rojo serve default.project.json
   ```
5. In Roblox Studio, open the Rojo plugin and connect to the server shown in the terminal. The mapping defined in `default.project.json` will stream source files into the live DataModel.【F:default.project.json†L1-L40】
6. Press **Play** in Studio. Fire the `GameStart` remote from an in-game trigger or the developer console to spawn an arena and exercise the server bootstrap.【F:ServerScriptService/GameServer/Init.server.lua†L103-L123】
7. In **Game Settings ➜ Security ➜ Asset Permissions**, grant the experience access to each sound used by the audio bus so pooled effects can preload successfully (see `Shared/Systems/AudioBus.lua` for the asset IDs).【F:ReplicatedStorage/Shared/Systems/AudioBus.lua†L36-L123】

## Building a place file
When you need a `.rbxl` for distribution or regression testing, run:
```bash
rojo build default.project.json --output FruitSmash_V2.rbxl
```
The provided `FruitSmash_V2.rbxl` can serve as a baseline file for Studio uploads if you are not building fresh every time.

## Data reset tips
- `SaveService` caches profile data in-memory when Studio emulates servers. Clear the `ServerScriptService/Data/SaveService.lua` module or restart the session to reset state between tests.【F:ServerScriptService/Data/SaveService.lua†L42-L84】
- The round director and arena services clear out `Workspace/Arenas` before cloning a fresh arena, so re-running `GameStart` is safe within the same session.【F:ServerScriptService/GameServer/Init.server.lua†L87-L122】

## Deployment checklist
- Update `ReplicatedStorage/Shared/Config/BuildInfo.lua` with the correct version metadata before publishing builds.【F:ReplicatedStorage/Shared/Config/BuildInfo.lua†L1-L8】
- Regenerate the place file with `rojo build` and upload it through Studio or CI.
- Verify remotes and DataStore endpoints in [`docs/API.md`](API.md) whenever you add or rename events to keep the client/server contract documented.

# Fruit Smash Setup Guide

This guide describes the exact steps required to set up a local development environment for the Fruit Smash Roblox experience from a clean machine.

## 1. Prerequisites

### Supported operating systems
- **Windows 10/11 (64-bit)**
- **macOS 12 (Monterey) or newer**

Roblox Studio is only available on these platforms. Linux users must develop inside a supported Windows/macOS virtual machine.

### Accounts and access
- A Roblox account with permission to install and sign in to Roblox Studio.
- Access to the FruitSmash repository in your source-control provider (for example GitHub).

### Required tooling
| Tool | Minimum version | Purpose |
| --- | --- | --- |
| [Roblox Studio](https://create.roblox.com/landing/studio) | Latest release | Runs the game client/server and hosts the Rojo plugin. |
| [Rojo CLI](https://rojo.space/docs/v7/getting-started/installation/) | 7.4 or newer | Syncs the project files in this repository into Roblox Studio using `default.project.json`. |
| [Git](https://git-scm.com/downloads) | 2.35 or newer | Clones the repository and manages version control. |
| [Rojo Roblox Studio plugin](https://www.roblox.com/library/5656197456/Rojo) | Latest | Connects Studio to the Rojo CLI service. |

Optional but recommended:
- Visual Studio Code with the [Roblox LSP extension](https://marketplace.visualstudio.com/items?itemName=Nightrains.robloxlsp) for Luau language support.

## 2. Install tooling

Follow the instructions for your operating system. Perform each step in order.

### Windows
1. **Install Git**
   - Download the 64-bit installer from [git-scm.com](https://git-scm.com/download/win) and run it with the default options.
   - After installation, open a new PowerShell window and confirm: `git --version`.
2. **Install Roblox Studio**
   - Sign in at [create.roblox.com](https://create.roblox.com), click **Download Studio**, run the installer, and sign in when prompted.
3. **Install the Rojo CLI**
   - Recommended: install via [winget](https://learn.microsoft.com/windows/package-manager/winget/) in an elevated PowerShell window:
     ```powershell
     winget install --id Rojo-rbx.Rojo --source winget
     ```
   - Verify installation: `rojo --version` (ensure it reports `7.4.x` or newer).
   - Alternate: the repository includes `rojo.exe`. You can copy it into a folder on your `PATH` (for example `%LOCALAPPDATA%\Programs\Rojo`) and run it directly.
4. **Install the Rojo Studio plugin**
   - Open Roblox Studio, sign in, and open the **Plugins** tab.
   - Click **Manage Plugins ➜ Find Plugins**, search for **"Rojo"**, and install the plugin published by **Roblox**.
   - Restart Studio after installation so the plugin loads.

### macOS
1. **Install Git**
   - Install [Homebrew](https://brew.sh/) if it is not already present.
   - Run `brew install git` and confirm with `git --version`.
2. **Install Roblox Studio**
   - Log in at [create.roblox.com](https://create.roblox.com), download the macOS `.dmg`, drag **RobloxStudio.app** into **Applications**, and launch it once to finish setup.
3. **Install the Rojo CLI**
   - Run `brew install rojo-rbx/rojo/rojo`.
   - Confirm with `rojo --version` (should report `7.4.x` or newer).
4. **Install the Rojo Studio plugin**
   - Launch Roblox Studio, open any place file, and use **Plugins ➜ Manage Plugins ➜ Find Plugins** to install the **Rojo** plugin by **Roblox**.
   - Restart Studio.

## 3. Clone the repository
1. Open a terminal (PowerShell on Windows, Terminal.app on macOS).
2. Choose a parent directory for your source code (for example `C:\Dev` or `~/Dev`).
3. Clone the repository using the remote URL you have access to. Example for an SSH remote:
   ```sh
   git clone git@github.com:YourOrg/FruitSmash_Repo.git
   ```
4. Enter the project directory:
   ```sh
   cd FruitSmash_Repo
   ```

If you received the project as a `.zip`, extract it instead and change into the extracted `FruitSmash_Repo` directory.

## 4. First-time project sync

Rojo keeps Roblox Studio in sync with the Luau source files in this repository. The `default.project.json` file defines how folders map into the DataModel.

### Start the Rojo server
1. In the project root, start Rojo:
   ```sh
   rojo serve
   ```
2. Leave this terminal running. Rojo listens on `localhost:34872` by default and watches the repository for changes.

### Connect from Roblox Studio
1. Launch Roblox Studio.
2. Open the included base place: **File ➜ Open from File... ➜ FruitSmash_V2.rbxl** in the repository root.
3. Open the **Rojo** plugin window (Plugins tab ➜ Rojo).
4. In the connection list, a server named `localhost` (port `34872`) should appear. Click **Connect**, then **Sync** to push the repository files into Studio.
5. Once synced, press **Play** inside Studio to run the game locally.

## 5. Building a place file from source

To export a fresh place file from the source tree (for example before publishing):

```sh
mkdir -p builds
rojo build default.project.json --output builds/FruitSmash.rbxlx
```

The resulting `builds/FruitSmash.rbxlx` can be opened in Roblox Studio or uploaded through **File ➜ Publish to Roblox**.

## 6. Environment variables and secrets

The project does not rely on environment variables or external secret files. Game-specific settings such as DataStore scopes, monetization products, and experience permissions are configured within Roblox Studio under **Game Settings**. Ensure you use Roblox Studio's built-in configuration panels for any keys or secrets rather than storing them in the repository.

## 7. Updating your environment
- Keep Rojo up to date with `winget upgrade Rojo-rbx.Rojo` (Windows) or `brew upgrade rojo` (macOS).
- Pull the latest code with `git pull` before starting new work.
- After updates, restart the `rojo serve` session and reconnect the Studio plugin if necessary.

You are now ready to iterate on Fruit Smash locally.
