# API reference

This document captures the network contract (RemoteEvents and RemoteFunctions) and the primary server-side services that other systems and tools integrate with. Every remote is provisioned through [`ReplicatedStorage/Remotes/RemoteBootstrap.lua`](../ReplicatedStorage/Remotes/RemoteBootstrap.lua), which freezes the table returned by `require` so both client and server rely on the same instances.【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L1-L104】

## Remote events
| Name | Direction | Primary server broadcaster | Purpose |
| --- | --- | --- | --- |
| `GameStart` | Client → Server | `GameServer/Init.server.lua` | Clients fire to request an arena spawn; the handler clones `ServerStorage/ArenaTemplates/BaseArena` into `Workspace/Arenas` before starting the round.【F:ServerScriptService/GameServer/Init.server.lua†L93-L123】【F:ServerStorage/ArenaTemplates/BaseArena/init.lua†L1-L72】 |
| `RE_PrepTimer` | Server → Client | `GameServer/HUDServer.lua` | Broadcasts lobby or intermission countdowns with arena IDs and remaining seconds so HUD panels and world screens can show prep timers.【F:ServerScriptService/GameServer/HUDServer.lua†L193-L207】 |
| `RE_WaveChanged` | Server → Client | `GameServer/HUDServer.lua` | Announces wave/level transitions and optional phase text to update HUD counters.【F:ServerScriptService/GameServer/HUDServer.lua†L209-L228】 |
| `PartyUpdate` | Server → Client | `Match/LobbyMatchmaker.server.lua` | Sends party roster/status updates (queued, retrying, teleporting, etc.) to each member whenever queue state changes.【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L549-L582】 |
| `RE_RoundSummary` | Server → Client | `GameServer/RoundSummaryServer.lua` | Publishes per-level summaries (tokens used, outcome, rewards) after each round for UI display and match return flows.【F:ServerScriptService/GameServer/RoundSummaryServer.lua†L1-L118】 |
| `RE_MeleeHitAttempt` | Client → Server | `GameServer/Combat/CombatServer.lua` | Clients submit melee swing attempts; the server validates hit geometry, rate limits the remote, and applies damage when valid.【F:ServerScriptService/GameServer/Combat/CombatServer.lua†L488-L506】 |
| `RE_TargetHP` | Server → Client | `GameServer/HUDServer.lua` | Streams per-lane target health percentages so HUD health bars stay in sync with server authority.【F:ServerScriptService/GameServer/HUDServer.lua†L230-L250】 |
| `RE_CoinPointDelta` | Server → Client | `GameServer/HUDServer.lua` | Delivers coin/point gains (optionally per-player) with totals and contextual metadata for HUD counters.【F:ServerScriptService/GameServer/HUDServer.lua†L253-L303】 |
| `RE_QuickbarUpdate` | Server → Client | `GameServer/QuickbarServer.lua` | Sends the assembled quickbar state (melee loadout, token slots) whenever a player’s inventory changes.【F:ServerScriptService/GameServer/QuickbarServer.lua†L587-L600】 |
| `ShopOpen` | Server → Client | `GameServer/Shop/ShopServer.lua` | Indicates whether the shop UI should open globally or for a specific arena depending on round phase gating.【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L509-L534】 |
| `PurchaseMade` | Server → Client | `GameServer/Shop/ShopServer.lua` | Confirms successful purchases with item metadata, remaining coins, and quickbar snapshot so clients can animate receipts.【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L731-L740】 |
| `PlayerKO` | Server → Client (reserved) | `RemoteBootstrap.lua` | Reserved remote for knockout notifications; `RoundDirectorServer` tracks KO counts for summaries even though no broadcaster is wired yet.【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L51-L84】【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L416-L740】 |
| `RE_Notice` | Server → Client | Shop, token, match, and round services | Sends localized notifications for shop results, token usage, queue changes, and round messages.【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L421-L438】【F:ServerScriptService/GameServer/TokenUseServer.server.lua†L168-L195】【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L594-L603】 |
| `RE_AchievementToast` | Server → Client | `GameServer/AchievementServer.lua` | Fires lightweight toast notifications when players earn achievements gated by feature flags.【F:ServerScriptService/GameServer/AchievementServer.lua†L1-L60】 |
| `WaveComplete` | Server → Client | `GameServer/RoundDirectorServer.lua` | Announces end-of-wave results (success/failure plus metadata) and mirrors telemetry payloads.【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L776-L799】 |
| `RE_SettingsPushed` | Server → Client | `GameServer/SettingsServer.lua` | Pushes sanitized accessibility/player settings after load or server-side updates.【F:ServerScriptService/GameServer/SettingsServer.lua†L329-L347】 |
| `RE_SessionLeaderboard` | Server → Client | `Data/LeaderboardServer.lua` | Streams the top session leaderboard entries, player rank, and timestamp to every connected client.【F:ServerScriptService/Data/LeaderboardServer.lua†L231-L255】 |

## Remote functions
| Name | Direction | Server handler | Purpose |
| --- | --- | --- | --- |
| `RF_Purchase` | Client → Server | `GameServer/Shop/ShopServer.lua` (`Guard.WrapRemote`) | Processes shop purchase requests with validation, rate limits, and quickbar refresh payloads.【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L820-L842】 |
| `RF_JoinQueue` | Client → Server | `Match/LobbyMatchmaker.server.lua` | Queues a party for matchmaking, creating/disbanding parties and returning status or error codes.【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L889-L959】 |
| `RF_LeaveQueue` | Client → Server | `Match/LobbyMatchmaker.server.lua` | Lets a party exit the matchmaking queue, handling teleport-in-progress and cleanup cases.【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L962-L985】 |
| `RF_UseToken` | Client → Server | `GameServer/TokenUseServer.server.lua` | Validates token-slot payloads, applies token effects, emits notices, and records usage for summaries.【F:ServerScriptService/GameServer/TokenUseServer.server.lua†L168-L210】 |
| `RF_SaveSettings` | Client → Server | `GameServer/SettingsServer.lua` | Allows clients to fetch or persist settings; responses contain sanitized copies persisted to profiles and mirrored back via `RE_SettingsPushed`.【F:ServerScriptService/GameServer/SettingsServer.lua†L330-L351】 |
| `RF_Tutorial` | Client ↔ Server | `GameServer/TutorialServer.lua` | Retrieves or mutates tutorial completion state, falling back to player attributes when persistence is unavailable.【F:ServerScriptService/GameServer/TutorialServer.lua†L1-L118】 |
| `RF_GetGlobalLeaderboard` | Client → Server | `Data/LeaderboardServer.lua` | Returns ordered global leaderboard snapshots, falling back to cached results if DataStore calls fail.【F:ServerScriptService/Data/LeaderboardServer.lua†L470-L504】 |

## Data services
These modules provide reusable APIs for other systems and tools.

- **`ServerScriptService/Data/SaveService.lua`** – Wraps Roblox DataStore access with studio-safe in-memory storage, queued saves, mutation helpers, checkpoint providers, and a manual flush for shutdown handlers.【F:ServerScriptService/Data/SaveService.lua†L313-L360】【F:ServerScriptService/Data/SaveService.lua†L564-L656】
- **`ServerScriptService/Data/ProfileServer.lua`** – Manages session profiles built from `Shared/Types/SaveSchema.lua`, exposing helpers for currency management, inventory, tokens, and tutorial flags to other systems like the shop and tutorial servers.【F:ServerScriptService/Data/ProfileServer.lua†L1-L68】【F:ServerScriptService/Data/ProfileServer.lua†L990-L1267】
- **`ServerScriptService/GameServer/QuickbarServer.lua`** – Builds quickbar states and dispatches updates via `RE_QuickbarUpdate`, with helpers to query slots and refresh individual players or arenas.【F:ServerScriptService/GameServer/QuickbarServer.lua†L587-L639】
- **`ServerScriptService/GameServer/RoundDirectorServer.lua`** – Orchestrates wave cadence, economy payouts, obstacle gating, and telemetry hooks while calling HUD broadcast helpers and summary publishing services.【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L1-L118】【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L776-L808】
- **`ServerScriptService/GameServer/Shop/ShopServer.lua`** – Coordinates shop state toggles, purchase validation, Quickbar refreshes, and telemetry logging; initializes via `ShopServer.Init()` in the bootstrap.【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L509-L743】【F:ServerScriptService/GameServer/Init.server.lua†L44-L61】

