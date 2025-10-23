# Fruit Smash Usage Guide

## Project layout
- **Project manifest** – `default.project.json` maps the Roblox DataModel to the source tree so Rojo can sync folders such as `ReplicatedStorage`, `ServerScriptService`, `StarterPlayer`, and `Workspace` from this repository into Studio. Double-check that the `GameServer` entry points at `ServerScriptService/GameServer` before syncing; the default manifest still points to the legacy `ServerScriptService/__GS` path. 【F:default.project.json†L1-L40】
- **Game server runtime** – Core round management lives under `ServerScriptService/GameServer`, including arena lifecycle (`ArenaServer`), round flow (`RoundDirectorServer`), and combat pacing (`TurretControllerServer`). 【F:ServerScriptService/GameServer/ArenaServer.lua†L1-L95】【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L104-L226】【F:ServerScriptService/GameServer/TurretControllerServer.lua†L256-L360】
- **Shared configuration** – Gameplay tuning (turrets, lanes, obstacles, match flags) is centralized in `ReplicatedStorage/Shared/Config/GameConfig.lua`, while feature flags default to `Obstacles = true` in `Shared/Config/Flags.lua`. 【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L1-L215】【F:ReplicatedStorage/Shared/Config/Flags.lua†L24-L38】
- **Content templates** – Arena geometry and lane attachments originate from `ServerStorage/ArenaTemplates/BaseArena/init.lua`, which generates the baseline `Arenas` folder used during tests. 【F:ServerStorage/ArenaTemplates/BaseArena/init.lua†L1-L170】

## Prerequisites
- Roblox Studio with playtesting access to the place file (ship the included `FruitSmash_V2.rbxl` or your own derived place).
- Rojo CLI ≥ 7.x installed on your development machine. If you are on Windows you can reuse the bundled `rojo.exe`; on macOS/Linux install via `cargo install rojo`. Ensure your PATH exposes the `rojo` binary before running the commands below.
- (Optional) A git-aware shell so you can commit changes after iterating on scripts and configuration.

## Minimal end-to-end example
The following workflow spins up a playable solo arena in Studio and exercises the server systems that spawn fruit waves and obstacles.

1. **Start Rojo** – From the repository root, run `rojo serve default.project.json`. If Rojo errors about `ServerScriptService/__GS`, update the manifest entry to point at `ServerScriptService/GameServer` before retrying. 【F:default.project.json†L1-L40】
2. **Open the place** – Launch Roblox Studio, open your working place (for example, `FruitSmash_V2.rbxl`), and attach to the Rojo server. Start a *Play Solo* session.
3. **Run the server bootstrap snippet** – In the *Server* command bar, execute:

   ```lua
   local ServerScriptService = game:GetService("ServerScriptService")
   local ReplicatedStorage = game:GetService("ReplicatedStorage")

   local ArenaServer = require(ServerScriptService.GameServer.ArenaServer)
   local RoundDirector = require(ServerScriptService.GameServer.RoundDirectorServer)
   local TurretController = require(ServerScriptService.GameServer.TurretControllerServer)
   local MiniTurretServer = require(ServerScriptService.Obstacles.MiniTurretServer)
   local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)

   local arenaId = ArenaServer.SpawnArena("solo-test")
   TurretController:Start(arenaId, { level = 1, laneCount = 4 })
   RoundDirector.Start(arenaId, { StartLevel = 1 })
   MiniTurretServer.Start(arenaId)

   Remotes.GameStart:FireAllClients()
   print("Arena started:", arenaId)
   ```

   - `ArenaServer.SpawnArena` clones the `BaseArena` template into `Workspace/Arenas` and tracks level/wave state. 【F:ServerScriptService/GameServer/ArenaServer.lua†L50-L95】
   - `RoundDirector.Start` kicks off the prep + wave loop, eventually calling into `TurretControllerServer` to schedule fruit bursts and obstacle waves. 【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L1483-L1563】【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L1180-L1227】
   - `TurretController:Start` applies the context (level, lane count, roster) and begins spawning fruit via `FruitSpawnerServer`. 【F:ServerScriptService/GameServer/TurretControllerServer.lua†L256-L334】【F:ServerScriptService/GameServer/TurretControllerServer.lua†L578-L720】
   - `MiniTurretServer.Start` scans the arena for turret attachments (matching `ObstacleType = "MiniTurret"` or name patterns) and starts firing projectiles. 【F:ServerScriptService/Obstacles/MiniTurretServer.lua†L334-L373】【F:ServerScriptService/Obstacles/MiniTurretServer.lua†L1000-L1065】
   - `RemoteBootstrap` guarantees that the `GameStart` RemoteEvent exists so clients can mirror HUD state. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L40-L109】

You should see `[Init] Boot complete; waiting for GameStart` in the output before running the snippet, followed by your custom `Arena started:` message when the arena spins up. 【F:ServerScriptService/GameServer/Init.server.lua†L1-L123】

## Typical workflows
### Run the game locally
1. **Sync content** – Run `rojo serve default.project.json` (after fixing the `GameServer` mapping if necessary). 【F:default.project.json†L1-L40】
2. **Verify remotes** – Require `ReplicatedStorage.Remotes.RemoteBootstrap` in the Studio command bar to ensure all RemoteEvents/Functions exist before pressing Play. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L40-L109】
3. **Join Play Solo** – Start a solo session; the server bootstrap script will warn if dependent modules such as `SettingsServer`, `TutorialServer`, or `ShopServer` fail to load. 【F:ServerScriptService/GameServer/Init.server.lua†L16-L66】
4. **Spawn an arena** – Either trigger the `GameStart` RemoteEvent from a client or call `ArenaServer.SpawnArena` manually. The bootstrap helper clones `ServerStorage/ArenaTemplates/BaseArena` when `GameStart` fires. 【F:ServerScriptService/GameServer/Init.server.lua†L97-L118】【F:ServerStorage/ArenaTemplates/BaseArena/init.lua†L82-L170】
5. **Monitor output** – Keep the output window visible; the Repo Health check prints ✅/❌ markers and warns about missing assets while you iterate. 【F:ServerScriptService/Tools/RepoHealthCheck.server.lua†L13-L200】

### Add a turret module
1. **Start from the existing contract** – `ServerScriptService/Obstacles/MiniTurretServer.lua` exposes `Start`, `Stop`, `GetState`, and `IsActive`, making it a reliable template for additional obstacle controllers. 【F:ServerScriptService/Obstacles/MiniTurretServer.lua†L1000-L1065】
2. **Provide arena hooks** – Ensure your arena template exposes attachments or models the module can detect (for example, use `ObstacleType` attributes or `*Turret*` naming similar to the mini-turret detector). Update `ServerStorage/ArenaTemplates/BaseArena/init.lua` or your custom template accordingly. 【F:ServerScriptService/Obstacles/MiniTurretServer.lua†L334-L352】【F:ServerStorage/ArenaTemplates/BaseArena/init.lua†L16-L138】
3. **Register configuration** – Add tuning knobs (fire interval, damage, search radius) to `GameConfig.Obstacles` so gameplay scripts can query them. 【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L134-L147】
4. **Wire it into round flow** – Require your new module from `ServerScriptService/GameServer/Obstacles` and invoke it from the round lifecycle (for example, alongside the Sawblade integration inside `RoundDirectorServer`). 【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L104-L126】【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L1180-L1227】
5. **Expose a feature flag (optional)** – Use `Shared/Config/Flags.lua` so you can enable/disable the turret without deploying code changes; subscribe via `Flags.OnChanged("Obstacles", ...)` similar to the mini-turret server. 【F:ReplicatedStorage/Shared/Config/Flags.lua†L24-L38】【F:ServerScriptService/Obstacles/MiniTurretServer.lua†L1049-L1057】

### Run the repository health check
1. Enable `ServerScriptService/Tools/RepoHealthCheck.server.lua` before playtesting; it automatically validates shared config, arena templates, remotes, and core GameServer modules, emitting ✅/❌ summaries in the output. 【F:ServerScriptService/Tools/RepoHealthCheck.server.lua†L55-L200】
2. Use the printed failures to locate missing modules (e.g., a deleted `QuickbarServer` or absent `RF_UseToken` handler) before shipping changes. 【F:ServerScriptService/Tools/RepoHealthCheck.server.lua†L122-L197】

## Troubleshooting
- **Rojo cannot find `ServerScriptService/__GS`** – Update the `GameServer` path in `default.project.json` to `ServerScriptService/GameServer` so the folder syncs correctly. 【F:default.project.json†L1-L40】
- **`GameStart` does nothing in Studio** – Confirm `RemoteBootstrap` created the `GameStart` RemoteEvent and that `Init.server.lua` subscribed to it; both scripts warn in the output if setup fails. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L40-L109】【F:ServerScriptService/GameServer/Init.server.lua†L97-L123】
- **Arena fails to spawn** – Check that `ServerStorage/ArenaTemplates/BaseArena` exists and contains lanes/targets; the bootstrap script logs `[Init] Missing ServerStorage/ArenaTemplates/BaseArena` if the template is absent. 【F:ServerScriptService/GameServer/Init.server.lua†L97-L111】【F:ServerStorage/ArenaTemplates/BaseArena/init.lua†L82-L170】
- **Mini turrets never fire** – Make sure arena parts carry the expected attributes or naming so `MiniTurretServer` can detect them, and verify the `Obstacles` feature flag is still enabled. 【F:ServerScriptService/Obstacles/MiniTurretServer.lua†L334-L373】【F:ServerScriptService/Obstacles/MiniTurretServer.lua†L1049-L1057】【F:ReplicatedStorage/Shared/Config/Flags.lua†L24-L38】
- **Fruit spawner errors flood the output** – `TurretControllerServer` logs warnings if queuing a fruit fails; ensure `FruitSpawnerServer` is loaded and that the requested fruit IDs exist in `GameConfig` and `FruitConfig`. 【F:ServerScriptService/GameServer/TurretControllerServer.lua†L578-L720】【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L8-L147】
- **Quickbar UI stays empty** – If `QuickbarServer` is inactive during Studio runs, enable the dev helper in `GameServer/DevTest_QuickbarFeeder.server.lua` or send `RE_QuickbarUpdate` yourself. 【F:ServerScriptService/GameServer/DevTest_QuickbarFeeder.server.lua†L1-L93】
- **Remote function requests fail silently** – Use the repo health check to verify `RF_UseToken` and other RemoteFunctions are registered and expose `OnServerInvoke` handlers before clients call them. 【F:ServerScriptService/Tools/RepoHealthCheck.server.lua†L171-L197】
