# Architecture overview

Fruit Smash splits shared, server, and client responsibilities across dedicated folders so that features can evolve independently while sharing configuration.

## DataModel mapping
- The Rojo project (`default.project.json`) maps `ReplicatedStorage`, `ServerScriptService`, `StarterGui`, `StarterPlayerScripts`, `ServerStorage`, and `Workspace` folders directly into the DataModel, ensuring source folders mirror the runtime hierarchy.【F:default.project.json†L1-L40】
- `ServerStorage/ArenaTemplates` contains the `BaseArena` template cloned into `Workspace/Arenas` during server bootstrap, providing spawn zones, lane markers, and targets.【F:ServerStorage/ArenaTemplates/BaseArena/init.lua†L1-L72】【F:ServerScriptService/GameServer/Init.server.lua†L74-L122】

## Shared layer (`ReplicatedStorage`)
- **Remotes** – `Remotes/RemoteBootstrap.lua` ensures every RemoteEvent/RemoteFunction exists and freezes a table reference used by server and client scripts.【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L1-L83】
- **Config** – `Shared/Config/GameConfig.lua` centralizes gameplay tuning (lanes, player stats, obstacles, monetization, UI flags) while `BuildInfo.lua` and `Flags.lua` expose metadata and feature toggles.【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L1-L120】【F:ReplicatedStorage/Shared/Config/BuildInfo.lua†L1-L8】
- **Types & Save schema** – `Shared/Types/SaveSchema.lua` defines default coins, stats, cosmetics, and settings that `ProfileServer` and clients consume.【F:ReplicatedStorage/Shared/Types/SaveSchema.lua†L1-L21】
- **Systems** – `Shared/Systems/Localizer.lua` resolves localized strings, while utilities like `WeightedTable.lua` and `RNG.lua` support gameplay rolls and deterministic behavior.【F:ReplicatedStorage/Shared/Systems/Localizer.lua†L1-L48】【F:ReplicatedStorage/Shared/Systems/WeightedTable.lua†L1-L53】
- **Content registry** – `Shared/Content/ContentRegistry.lua` abstracts access to stored assets, handling optional server-only items and caching to avoid duplicate requires.【F:ReplicatedStorage/Shared/Content/ContentRegistry.lua†L1-L80】

## Server layer (`ServerScriptService`)
- **GameServer** – `Init.server.lua` wires remotes, seeds tutorial/settings modules, spawns arena templates, and listens for `GameStart`. Submodules cover arena cloning, HUD replication, target health, turret control, analytics forwarding, and tutorial state.【F:ServerScriptService/GameServer/Init.server.lua†L1-L123】【F:ServerScriptService/GameServer/ArenaServer.lua†L1-L72】【F:ServerScriptService/GameServer/HUDServer.lua†L1-L62】
- **Round flow** – `RoundDirectorServer.lua` orchestrates prep timers, wave cadence, lane expansion, obstacle gating, and economy/achievement hooks. It integrates telemetry, shop rewards, and match return services to keep party progress consistent.【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L1-L118】
- **Matchmaking** – `MatchmakingServer.lua` tracks parties, caps membership, and coordinates arena assignment via `ArenaServer`. It synchronizes membership when hosts leave and logs transitions for debugging.【F:ServerScriptService/GameServer/MatchmakingServer.lua†L1-L76】
- **Combat & obstacles** – Dedicated folders (`Combat`, `Obstacles`) host projectile validation, damage tracking, and enemy hazards like `MiniTurretServer` so that combat tuning stays isolated from round flow.【F:ServerScriptService/Combat/HitValidationServer.lua†L1-L40】【F:ServerScriptService/Obstacles/MiniTurretServer.lua†L250-L320】
- **Economy & shop** – `EconomyServer.lua`, `DailyRewardsServer.lua`, and the `Shop` subfolder manage coin awards, rerolls, and purchase remotes using shared config tables.【F:ServerScriptService/Economy/EconomyServer.lua†L1-L60】【F:ReplicatedStorage/Shared/Config/ShopConfig.lua†L1-L40】
- **Data services** – `SaveService.lua` wraps DataStoreService with retries, studio fallbacks, and checkpoint hooks, while `ProfileServer.lua` builds session inventories, settings, and tutorial flags from the shared schema.【F:ServerScriptService/Data/SaveService.lua†L1-L84】【F:ServerScriptService/Data/ProfileServer.lua†L1-L68】
- **Telemetry & moderation** – `Analytics/TelemetryServer.lua` aggregates gameplay events before flushing to sinks, and `Moderation/GuardServer.lua` integrates with admin tooling to vet privileged commands.【F:ServerScriptService/Analytics/TelemetryServer.lua†L1-L88】【F:ServerScriptService/Tools/AdminCommands.server.lua†L1-L44】
- **Tools** – `Tools/AdminCommands.server.lua`, `PerfHarness.server.lua`, and `RepoHealthCheck.server.lua` expose developer utilities for spawning waves, stress testing, and validating remotes in non-production environments.【F:ServerScriptService/Tools/AdminCommands.server.lua†L1-L44】【F:ServerScriptService/Tools/PerfHarness.server.lua†L1-L40】

## Client layer (`StarterPlayer` & `StarterGui`)
- **HUD & world screens** – `HUDController.client.lua` listens to prep, wave, target health, and coin remotes to update UI panels, while `StarterGui/WorldScreens` renders shared timers for all players.【F:StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua†L1-L37】【F:StarterGui/WorldScreens/Screen_RoundTimer.client.lua†L1-L52】
- **Input & camera** – Controllers such as `PlayerController`, `MeleeController`, and `CameraFeel` manage movement, melee swings, and camera shake tuned to `GameConfig` values.【F:StarterPlayer/StarterPlayerScripts/Controllers/PlayerController.client.lua†L1-L40】【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L21-L68】
- **Menus & settings** – `SettingsUI.client.lua` syncs accessible defaults (colorblind palettes, text scale) from `SettingsServer`, and `TutorialUI.client.lua` walks new players through mechanics while recording completion in their profile.【F:StarterPlayer/StarterPlayerScripts/Controllers/SettingsUI.client.lua†L1-L40】【F:ServerScriptService/GameServer/SettingsServer.lua†L1-L69】
- **Quickbar & achievements** – `QuickbarController` mirrors the server-managed inventory slots and listens for `RE_AchievementToast` to display progress notifications.【F:StarterPlayer/StarterPlayerScripts/Controllers/QuickbarController.client.lua†L1-L32】【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L52-L74】

## Networking contract
- All server/client communication routes through the frozen table returned by `RemoteBootstrap`. Remotes cover match flow (`GameStart`, `RF_JoinQueue`), HUD replication (`RE_PrepTimer`, `RE_TargetHP`), economy (`RE_CoinPointDelta`, `RF_UseToken`), and social features (`PartyUpdate`, `RE_SessionLeaderboard`).【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L33-L83】
- Services that need to expose functions (e.g., queue joins or tutorial progress) register handlers on these remotes so clients never create their own remote instances.

## Analytics and telemetry
- `TelemetryServer.lua` normalizes events (coins earned, tokens used, wave outcomes) and batches them before sending to registered sinks, letting features like admin commands piggyback on the same pipeline.【F:ServerScriptService/Analytics/TelemetryServer.lua†L1-L88】【F:ServerScriptService/Tools/AdminCommands.server.lua†L27-L44】
- The module respects feature flags from `Shared/Config/Flags.lua`, so turning telemetry on/off does not require editing individual services.【F:ServerScriptService/Analytics/TelemetryServer.lua†L29-L44】

