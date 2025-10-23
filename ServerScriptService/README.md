# ServerScriptService Handbook

> Server-authoritative gameplay, matchmaking, economy, and telemetry code lives here. For cross-cutting guidance review the [project guide](../README.md) and [ReplicatedStorage README](../ReplicatedStorage/README.md).

## Folder structure
- **Analytics/** – `TelemetryServer.lua` and `VersionAnnounce.server.lua` publish metrics and broadcast build messages.
- **Combat/** – Core hit validation (`HitValidationServer.lua`), projectile orchestration (`ProjectileServer.lua`), and arena helpers (`ArenaAdapter.lua`).
- **Data/** – Persistence wrappers (`SaveService.lua`), leaderboard services, and profile management modules.
- **Economy/** – `EconomyServer.lua` and `DailyRewardsServer.lua` manage currencies, rewards, and recurring bonuses.
- **GameServer/** – Runtime arena logic for match servers (spawn controllers, settings sync, monetization during rounds).
- **Match/** – Lobby matchmaking, teleport coordination, and server return flows (`LobbyMatchmaker.server.lua`, `MatchArrivalServer.server.lua`, `MatchReturnServer.server.lua`, `MatchReturnService.lua`).
- **Moderation/** – Holds live moderation hooks and admin utilities.
- **Monetization/** – Placeholder for future upsell flows; currently synced for structural parity.
- **Obstacles/** – Encounter scripts (e.g., `MiniTurretServer.lua`) managing environmental hazards.
- **Shop/** – Server handling for the in-match shop and purchase validation.
- **Tools/** – Support modules or admin commands used by server staff.

## Naming conventions
- Server scripts that run automatically end with `.server.lua`; plain `.lua` modules are required by other scripts.
- Module tables use PascalCase keys and avoid global state; prefer dependency injection or module-level caches with explicit reset functions.
- Remote names follow the `RE_`/`RF_` prefix convention from `ReplicatedStorage.Remotes.RemoteBootstrap`.
- Services are grouped by domain; avoid cross-domain dependencies unless orchestrated through shared systems.
- When adding placeholders, include `.gitkeep` and document intent in this README to prevent accidental removal.

## Adding a new server module
1. Choose the correct domain folder (Combat, Data, Economy, etc.) or create a new folder if the feature is substantial.
2. Create a ModuleScript or Script with a descriptive PascalCase filename and include `--!strict` at the top.
3. Require dependencies from `ReplicatedStorage.Shared` for shared types/config and from sibling folders when appropriate.
4. Register any new remotes via `ReplicatedStorage/Remotes/RemoteBootstrap.lua` and document payload types in code comments.
5. Update this README (and domain-specific READMEs if present) with a summary of the new module and how to extend it.

## Deployment considerations
- Matchmaking relies on TeleportService; ensure place IDs in `Shared/Config/GameConfig.lua` stay current when publishing builds.
- `SaveService` falls back to in-memory storage in Studio; exercise caution when simulating multiple players locally.
- `MatchReturnService` coordinates queue resets; always call its recovery routines when debugging teleport loops.
- `EconomyServer` and `DailyRewardsServer` guard against double-spend; maintain idempotent remote handlers.
- Obstacles like `MiniTurretServer.lua` may instantiate models from `ServerStorage`; keep asset references accurate.

## Testing workflow
- Use Studio's `Run` mode to validate server scripts without clients; check `Output` for warnings flagged by `warn` statements.
- Run live-match smoke tests by queueing through `LobbyMatchmaker` and verifying arrival/return flows.
- Exercise DataStore interactions by toggling Studio API access and monitoring `SaveService` retry logs.
- Validate obstacle scripts on a private test place with instrumentation to ensure physics and timers behave as expected.
- Leverage debug commands in `Tools/` (or `GameServer/Init.server.lua`) to spawn arenas, grant currency, or simulate damage.

## Coordination with other folders
- Shared types and configs live in `ReplicatedStorage/Shared`; require them instead of copying constants locally.
- Client controllers in `StarterPlayerScripts/Controllers` consume remote events triggered here; keep payloads backward-compatible.
- UI updates (e.g., leaderboard refresh) require coordination with `StarterGui` scripts to handle new data fields.
- Match servers may spawn assets defined in `ReplicatedStorage/Assets` or `ServerStorage`; update both sides when adjusting models.
- Analytics events should mirror definitions used by marketing dashboards; adjust `TelemetryServer` when new metrics are added.

## Maintenance checklist
- [ ] Audit remote handlers quarterly to ensure rate limits and permission checks remain effective.
- [ ] Review DataStore key formats before altering `SaveService` or `ProfileServer` to avoid migrations surprises.
- [ ] Confirm `LobbyMatchmaker` teleport fallbacks still point to valid spawn locations in `GameServer` scripts.
- [ ] Keep obstacle scripts aligned with level design updates; remove unused hazards to reduce maintenance.
- [ ] Document module owners and contact points in this README when team assignments change.

## Additional documentation
- Match-specific details are documented in [`Match/README.md`](Match/README.md).
- Persistence notes will live in `Data/README.md` when created; mirror updates there.
- Client perspectives on remote consumption appear in [`../StarterPlayer/StarterPlayerScripts/README.md`](../StarterPlayer/StarterPlayerScripts/README.md).
- Asset references are tracked in [`../ReplicatedStorage/Assets/README.md`](../ReplicatedStorage/Assets/README.md).
- Repository-wide practices remain in the [project guide](../README.md).
