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

