# ServerScriptService/Match Runbook

> Match flow scripts live here. Review the parent [ServerScriptService handbook](../README.md) and the [project guide](../../README.md) for broader patterns.

## Modules & scripts
- **LobbyMatchmaker.server.lua** – Manages lobby parties, queue states, teleport orchestration, and local fallback arenas when TeleportService fails.
- **MatchArrivalServer.server.lua** – Runs inside match servers, handling spawn logic, timer start, and synchronization when players arrive.
- **MatchReturnServer.server.lua** – Executes when matches end to funnel players back to the lobby experience with summary payloads.
- **MatchReturnService.lua** – Shared module used by both lobby and match servers to coordinate teleport retries and recovery logic.

## Data flow overview
- Players join lobby -> `LobbyMatchmaker` groups them into parties up to `MAX_PARTY_SIZE` (currently 4).
- When ready, `LobbyMatchmaker` uses `TeleportService` to send parties to match place IDs defined in `Shared/Config/GameConfig.lua`.
- Match servers load `MatchArrivalServer`, spawn arenas, and notify clients via remotes (e.g., `GameStart`, `RE_WaveChanged`).
- Post-round, `MatchReturnServer` triggers teleports back to the lobby, optionally passing round summaries and rewards.
- If teleports fail, `MatchReturnService` enforces retries or falls back to local arenas for seamless experience.

## Key remotes & dependencies
- `Remotes.RF_JoinQueue` / `RF_LeaveQueue` – Exposed to clients for queue management; handled in `LobbyMatchmaker`.
- `Remotes.PartyUpdate` – Broadcasts party membership changes to clients, ensuring UI stays accurate.
- `Remotes.RE_PrepTimer` / `RE_WaveChanged` – Notifies clients about prep countdowns and active wave numbers.
- `Shared/Systems/Localizer` – Generates localized status text for notices and error messages.
- `ServerScriptService/GameServer` – Provides local fallback support via `ArenaServer` and `RoundDirectorServer` when teleports fail.

## Configuration touchpoints
- `Shared/Config/GameConfig.lua` contains `Match` settings (e.g., `MatchPlaceId`, teleport retry timing, fallback behavior).
- Teleport retry constants (`RETRY_MIN_SECONDS`, `RETRY_MAX_SECONDS`, `RETRY_JITTER_SECONDS`) are derived from config and used by `LobbyMatchmaker`.
- Local fallback toggles (`UseTeleport`, `LocalFallback`, `LocalFallbackOnFailure`) dictate whether arena simulations run in the lobby server.
- Update config values in version control; do not hard-code overrides in scripts.
- Document changes to party size or queue rules in release notes and this README.

## Adding new match logic
1. Determine whether the change affects lobby, match, or shared return flows and pick the correct script.
2. If new remotes are required, register them through `ReplicatedStorage/Remotes/RemoteBootstrap.lua` and add payload documentation.
3. Update associated client controllers (`StarterPlayerScripts/Controllers/QueueUI.client.lua`, `HUDController.client.lua`) to handle new events.
4. Test teleports in Studio and a private live server to ensure fallback logic behaves as expected.
5. Reflect updates in this README, noting any new configuration knobs or dependencies.

## Teleport troubleshooting
- Enable `DEBUG_PRINT` in config when diagnosing queue issues; logs include party IDs and retry information.
- Verify `MATCH_PLACE_ID` matches the destination place published to Roblox; mismatches cause silent failures.
- Monitor `retryCount` and `pendingRetry` fields to ensure loops do not spin indefinitely.
- Clean up party tables (`partiesById`, `partyByPlayer`) when players leave or disconnect to avoid stale references.
- Use `MatchReturnService` helpers to handle failure cases uniformly across lobby and match servers.

## Local fallback guidance
- Local fallback requires `ServerScriptService/GameServer` modules to be present and implement `SpawnArena` and `GetArenaState`.
- When fallback is enabled, ensure arenas spawn in dedicated folders to prevent collisions with live teleport arrivals.
- Reset fallback arenas between runs to avoid leftover enemies or props.
- Communicate to QA when fallback is toggled so they can test both teleport and local modes.
- Log fallback activations to telemetry to measure reliability.

## Maintenance checklist
- [ ] Revisit queue size and matchmaking rules each season to align with design goals.
- [ ] Verify TeleportService place IDs after every deployment; update config if place URLs change.
- [ ] Audit logs for repeated teleport failures and adjust retry backoff or fallback thresholds as needed.
- [ ] Ensure remotes fired here remain documented in client READMEs and type definitions.
- [ ] Keep this README updated when new match lifecycle scripts or services are added.

## Related documentation
- [ServerScriptService handbook](../README.md) – Domain overview and naming conventions.
- [GameServer modules](../GameServer/) – Local fallback and in-match logic referenced by `LobbyMatchmaker`.
- [ReplicatedStorage Remotes](../../ReplicatedStorage/README.md) – Source of remote contracts used by match flow.
- [StarterPlayerScripts controllers](../../StarterPlayer/StarterPlayerScripts/README.md) – Client listeners for queue and match events.
- [Top-level guide](../../README.md) – Release processes and contact points.
