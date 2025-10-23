# Fruit Smash

## Elevator Pitch
Fruit Smash is a cooperative wave-defense experience for Roblox where squads of up to four players smash runaway produce before it overruns the arena. Dynamic lane expansions, escalating obstacles, and turret placements keep every round evolving while players sprint, dodge, and swing through increasingly chaotic waves. Accessibility-friendly controls and progression systems aim to make repeat sessions welcoming for veterans and newcomers alike.【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L8-L147】【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L17-L101】

**Reference Docs:** [Architecture](#architecture-overview) · [Setup](#setup) · [Usage](#usage) · [API](#api) · [Changelog](#changelog)

## Key Features
- **Matchmade co-op sessions** that form four-player parties, queue them, and fall back to local arenas if teleportation fails, ensuring reliable matchmaking in live and studio environments.【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L17-L102】
- **Progression-friendly arena tuning** with adjustable turret cadence, lane unlocks, player stamina, and power-up behaviors configured from a single shared module for easy balancing.【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L8-L147】
- **Robust economy and shop catalog** featuring melee upgrades, consumable tokens, cosmetics, and gacha rolls to keep players chasing new loadouts each run.【F:ReplicatedStorage/Shared/Config/ShopConfig.lua†L6-L146】
- **Persistent profiles with build metadata** that cache saves in studio, retry DataStore writes, and embed version information for support diagnostics.【F:ServerScriptService/Data/SaveService.lua†L1-L200】
- **Session telemetry pipeline** that aggregates match summaries, tracks coin gains, and emits sanitized events for downstream analytics sinks.【F:ServerScriptService/Analytics/TelemetryServer.lua†L1-L200】

## Quick Start
1. **Install prerequisites:** Roblox Studio plus the Rojo CLI or plugin so you can sync this repository into Studio sessions.【F:default.project.json†L1-L39】
2. **Clone the repo** and open a terminal at the repository root (`FruitSmash_Repo`).
3. **Launch Rojo** with `rojo serve default.project.json` (or use the bundled binary) to map the project tree defined in `default.project.json` into Studio.【F:default.project.json†L1-L39】
4. **Connect from Studio** via the Rojo plugin, then open the experience place to stream assets from `ReplicatedStorage`, `ServerScriptService`, `StarterGui`, and other sources declared in the project file.【F:default.project.json†L1-L39】
5. **Press Play in Studio** to join the lobby, queue into a match, and iterate on gameplay scripts live.

## Folder Map
- `ReplicatedStorage/Shared/` – Shared configs, content registry, locale strings, and systems consumed on both client and server.【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L1-L200】【F:manifest/repo_manifest.json†L327-L333】
- `ServerScriptService/` – Server-authoritative services covering matchmaking, combat, economy, data, analytics, monetization, and tools.【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L1-L200】【F:manifest/repo_manifest.json†L797-L947】
- `StarterPlayer/StarterPlayerScripts/` – Client controllers for HUD, audio, tutorials, settings, melee control, and admin tooling.【F:manifest/repo_manifest.json†L57-L107】
- `StarterGui/WorldScreens/` – In-world UI such as wave and round timers shown across the arena.【F:StarterGui/WorldScreens/Screen_WaveTimer.client.lua†L1-L120】【F:manifest/repo_manifest.json†L347-L353】
- `ServerStorage/ArenaTemplates/` – Authoritative arena templates and props streamed into live servers for match play.【F:ServerStorage/ArenaTemplates/BaseArena/init.lua†L1-L170】【F:manifest/repo_manifest.json†L17-L23】
- `Marketing/StoreAssets/` – App store copy, imagery, and localization files for storefront submissions.【F:Marketing/StoreAssets/README.md†L1-L80】【F:manifest/repo_manifest.json†L377-L467】
- `manifest/repo_manifest.json` – Auto-generated inventory of repository files to aid tooling and audits.【F:manifest/repo_manifest.json†L1-L16】

## Architecture Overview
Gameplay is split between Rojo-synced client controllers and server services. Match flow begins in `LobbyMatchmaker`, which forms parties, teleports them to live servers, or spins up a local fallback pipeline via arena and round directors. Shared configuration modules in `ReplicatedStorage/Shared` define gameplay knobs consumed by both client HUD controllers and server economy systems, keeping balancing centralized. Remote events bootstrap a typed contract between layers so combat, rewards, and UI updates stay synchronized across the network.【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L1-L200】【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L1-L200】【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L1-L109】

## Setup
- Ensure Roblox Studio is installed and authenticated for your development account.
- Install Rojo 7.x (CLI or Studio plugin) so `default.project.json` can mirror the repository into Studio.【F:default.project.json†L1-L39】
- (Optional) Install `rojo.exe` from the repository root if you prefer the bundled binary.
- Configure environment variables or secrets for telemetry and analytics sinks before deploying to production; `TelemetryServer` expects downstream handlers to be registered during runtime bootstrap.【F:ServerScriptService/Analytics/TelemetryServer.lua†L40-L103】
- When collaborating, review `manifest/repo_manifest.json` to confirm new assets are captured by automation jobs.【F:manifest/repo_manifest.json†L1-L16】

## Usage
- Tweak gameplay tuning (turrets, lanes, economy, power-ups, accessibility defaults) inside `GameConfig` for immediate round-to-round balancing passes.【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L8-L200】
- Adjust shop inventory, pricing, and gacha tables in `ShopConfig` before publishing balance updates or seasonal content drops.【F:ReplicatedStorage/Shared/Config/ShopConfig.lua†L6-L146】
- Extend player progression by wiring new stats or badges through `EconomyServer` and the leaderboard submission pipeline.【F:ServerScriptService/Economy/EconomyServer.lua†L1-L53】
- Register additional remotes via `RemoteBootstrap` when exposing new client/server interactions.【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L1-L109】

## API
`ReplicatedStorage/Remotes/RemoteBootstrap.lua` centralizes remote events and functions such as `GameStart`, `RE_CoinPointDelta`, `RF_JoinQueue`, and `RF_SaveSettings`. Require this module from both server and client contexts to obtain the same typed table of remotes, ensuring new calls are created in one place and stay discoverable to the whole team.【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L1-L109】

## Changelog
Document notable updates alongside releases. Until a dedicated changelog file exists, capture gameplay, content, or balance changes in pull request descriptions and Git history so downstream marketing copy and telemetry expectations stay aligned.
