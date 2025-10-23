# Fruit Smash

Fruit Smash is a cooperative wave-defense experience built for Roblox. Players protect a shared target while clearing lanes of fruit-themed enemies, investing coins into upgrades, and unlocking new arena features over time. The project is structured for Rojo-based development so that server, client, and shared code can evolve alongside place assets in source control.

## Highlights
- **Round-based progression** – `RoundDirectorServer` coordinates prep, wave, and shop phases, expanding lanes and spawning arena hazards as levels climb.【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L1-L118】
- **Shared configuration** – Gameplay tuning, player accessibility defaults, and monetization rules are centralized in `ReplicatedStorage/Shared/Config/GameConfig.lua` and shared save defaults in `Shared/Types/SaveSchema.lua` so that both server and client read the same data.【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L1-L120】【F:ReplicatedStorage/Shared/Types/SaveSchema.lua†L1-L21】
- **Resilient services** – Data and matchmaking modules wrap Roblox services with retries, studio-safe fallbacks, and telemetry hooks to keep live operations visible and stable.【F:ServerScriptService/Data/SaveService.lua†L1-L84】【F:ServerScriptService/Analytics/TelemetryServer.lua†L1-L96】
- **Cross-play remotes** – A single `RemoteBootstrap` script provisions every RemoteEvent and RemoteFunction used by the experience so both server and client code depend on a frozen contract.【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L1-L83】

## Repository layout
| Path | Description |
| --- | --- |
| `default.project.json` | Rojo mapping that defines how source folders map into the Roblox DataModel.【F:default.project.json†L1-L40】 |
| `ReplicatedStorage/` | Shared modules, configs, assets, and remote definitions consumed by both server and client code.【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L1-L83】【F:ReplicatedStorage/Shared/Content/ContentRegistry.lua†L1-L80】 |
| `ServerScriptService/` | Server-side services for matchmaking, arena control, combat, economy, telemetry, and tooling.【F:ServerScriptService/GameServer/Init.server.lua†L1-L102】【F:ServerScriptService/GameServer/ArenaServer.lua†L1-L72】 |
| `StarterPlayer/StarterPlayerScripts/` | Client controllers for HUD, input, tutorial flows, quickbar, and accessibility settings.【F:StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua†L1-L37】 |
| `StarterGui/` | UI screens that pair with HUD remotes for world-space timers and lobby information.【F:StarterGui/WorldScreens/Screen_RoundTimer.client.lua†L1-L52】 |
| `ServerStorage/ArenaTemplates/` | Base arena templates cloned at runtime with lane definitions and spawn markers.【F:ServerStorage/ArenaTemplates/BaseArena/init.lua†L1-L72】 |
| `Marketing/` | Store and promotional assets that ship alongside the experience. |

## Getting started
1. Follow the environment setup instructions in [`docs/SETUP.md`](docs/SETUP.md) to install Roblox Studio, Rojo, and configure the project.
2. Use `rojo serve` with `default.project.json` to stream changes into a local Studio session.
3. Run the `GameStart` remote (bound to in-game triggers or debug tools) to spawn the arena when testing server logic.【F:ServerScriptService/GameServer/Init.server.lua†L103-L123】
4. Refer to [`docs/API.md`](docs/API.md) for the list of remotes and save-service entry points exposed to clients.

## Additional documentation
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) – high-level system overview and module responsibilities.
- [`docs/API.md`](docs/API.md) – RemoteEvent/RemoteFunction contract and major service entry points.
- [`docs/SETUP.md`](docs/SETUP.md) – development environment and deployment workflow.
- [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md) – runtime and tooling dependencies.
- [`CHANGELOG.md`](CHANGELOG.md) – release notes and feature history.

## Contributing
- Run `rojo serve` or `rojo build` before committing to ensure the tree compiles to a valid place file.
- Keep new network messages and datastore keys documented in [`docs/API.md`](docs/API.md) so the client/server contract stays in sync.
- Prefer updating shared configuration modules over hardcoding values in client or server scripts to keep tuning centralized.【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L1-L120】

