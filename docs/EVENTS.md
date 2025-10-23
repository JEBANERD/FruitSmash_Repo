# Event & Messaging Map

This document catalogs the messaging primitives used by Fruit Smash. Remote events/functions live in `ReplicatedStorage.Remotes`, while bindable events stay within server or client packages. Each entry lists who sends the message, who listens, and the expected payload shape.

## RemoteEvents

### GameStart
* **Direction:** Client ➜ Server. `Init.server` listens for a fire from a player to spawn the arena. 【F:ServerScriptService/GameServer/Init.server.lua†L113-L118】
* **Payload:** None; only the firing player is used.
* **Emitted by:** Any client trigger (e.g., dev quickbar feeder or UI). 【F:ServerScriptService/GameServer/DevTest_QuickbarFeeder.server.lua†L82-L90】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L65-L72】

### RE_PrepTimer
* **Direction:** Server ➜ Clients. Broadcast when the prep timer changes. 【F:ServerScriptService/GameServer/HUDServer.lua†L200-L227】
* **Payload:** Table with `arenaId`, `seconds` (countdown), and `stop` (boolean when timer stops).
* **Emitted by:** `HUDServer.BroadcastPrep` when match timing changes. 【F:ServerScriptService/GameServer/HUDServer.lua†L200-L207】
* **Listeners:**
  * HUD controller updates counters and prep UI. 【F:StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua†L1538-L1546】
  * World round timer screen mirrors countdown. 【F:StarterGui/WorldScreens/Screen_RoundTimer.client.lua†L44-L47】【F:StarterGui/WorldScreens/Screen_RoundTimer.client.lua†L163-L170】
  * `UIRouter` toggles global UI state to Prep/InWave. 【F:StarterPlayer/StarterPlayerScripts/Controllers/UIRouter.client.lua†L159-L170】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L65-L72】

### RE_WaveChanged
* **Direction:** Server ➜ Clients. Fired whenever the active wave changes. 【F:ServerScriptService/GameServer/HUDServer.lua†L209-L228】
* **Payload:** Table with `arenaId`, `wave`, `level`, and optional `phase` metadata.
* **Emitted by:** `HUDServer.WaveChanged`. 【F:ServerScriptService/GameServer/HUDServer.lua†L209-L228】
* **Listeners:**
  * HUD controller refreshes labels. 【F:StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua†L1548-L1550】
  * `UIRouter` transitions between lobby/intermission/in-wave states. 【F:StarterPlayer/StarterPlayerScripts/Controllers/UIRouter.client.lua†L174-L182】
  * World wave timer HUD. 【F:StarterGui/WorldScreens/Screen_WaveTimer.client.lua†L44-L52】【F:StarterGui/WorldScreens/Screen_WaveTimer.client.lua†L114-L120】
  * Audio controller plays wave cues. 【F:StarterPlayer/StarterPlayerScripts/Controllers/AudioController.client.lua†L219-L222】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L65-L75】

### PartyUpdate
* **Direction:** Server ➜ Party members. 【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L549-L582】
* **Payload:** `{ partyId, hostUserId?, status, members = [{ name, userId, ... }], extra? }` plus optional status-specific extras.
* **Emitted by:** `LobbyMatchmaker` whenever matchmaking status changes (queued, disbanded, teleporting, etc.). 【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L549-L603】
* **Listeners:** Queue UI updates the matchmaking panel and countdowns. 【F:StarterPlayer/StarterPlayerScripts/Controllers/QueueUI.client.lua†L450-L484】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L65-L72】

### RE_RoundSummary
* **Direction:** Bidirectional.
  * Server ➜ Client: sends round summary payloads to each participant (`arenaId`, `level`, `outcome`, per-player stats, timestamp). 【F:ServerScriptService/GameServer/RoundSummaryServer.lua†L213-L245】
  * Client ➜ Server: UI requests a lobby return via `action = "ReturnToLobby"`. 【F:StarterPlayer/StarterPlayerScripts/Controllers/RoundSummary.client.lua†L312-L323】
* **Emitted by:** `RoundSummaryServer.Publish` after a level completes. 【F:ServerScriptService/GameServer/RoundSummaryServer.lua†L213-L245】
* **Listeners:**
  * Summary UI renders stats and allows returning to lobby. 【F:StarterPlayer/StarterPlayerScripts/Controllers/RoundSummary.client.lua†L400-L425】
  * `RoundSummaryServer` handles client requests to leave the arena and forwards them to `MatchReturnService`. 【F:ServerScriptService/GameServer/RoundSummaryServer.lua†L287-L318】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L65-L72】

### RE_MeleeHitAttempt
* **Direction:** Client ➜ Server for hit validation.
* **Payload:** Table with the targeted fruit instance (`fruit`), identifier (`fruitId`/`id`), and optional hit position (`position`). 【F:StarterPlayer/StarterPlayerScripts/Controllers/MeleeController.client.lua†L334-L382】
* **Emitted by:** `MeleeController` whenever the player swings. 【F:StarterPlayer/StarterPlayerScripts/Controllers/MeleeController.client.lua†L334-L382】
* **Listeners:**
  * `HitValidationServer` enforces reach, cooldowns, and arena ownership before awarding fruit. 【F:ServerScriptService/Combat/HitValidationServer.lua†L489-L589】
  * `CombatServer` wraps the remote with moderation guard/rate limits. 【F:ServerScriptService/GameServer/Combat/CombatServer.lua†L492-L504】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L73-L75】

### RE_TargetHP
* **Direction:** Server ➜ Clients. Mirrors per-lane health, shields, and game-over state. 【F:ServerScriptService/GameServer/HUDServer.lua†L230-L251】
* **Payload:** `{ arenaId, lane, pct, maxHp?, currentHp?, laneCount?, shieldActive?, shieldRemaining?, gameOver? , ... }`.
* **Emitted by:** `HUDServer.TargetHp` whenever target health changes. 【F:ServerScriptService/GameServer/HUDServer.lua†L230-L251】
* **Listeners:**
  * HUD controller updates lane panels and defeat state. 【F:StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua†L1472-L1510】【F:StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua†L1538-L1554】
  * Audio controller reacts to shield break/target damage. 【F:StarterPlayer/StarterPlayerScripts/Controllers/AudioController.client.lua†L219-L232】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L73-L76】

### RE_CoinPointDelta
* **Direction:** Server ➜ Client(s). Broadcasts wallet deltas and totals. 【F:ServerScriptService/GameServer/HUDServer.lua†L253-L270】
* **Payload:** `{ coins?, points?, totalCoins?, totalPoints?, reason?, metadata? }` (sanitized keys mirrored with PascalCase variants).
* **Emitted by:** `HUDServer.CoinPointDelta`, either to all players or a targeted list. 【F:ServerScriptService/GameServer/HUDServer.lua†L253-L270】
* **Listeners:** HUD controller animates coin/point counters. 【F:StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua†L1299-L1337】【F:StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua†L1538-L1542】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L77-L79】

### RE_QuickbarUpdate
* **Direction:** Server ➜ Client. Sends the current quickbar state (`coins`, melee loadout, token slots). 【F:ServerScriptService/GameServer/QuickbarServer.lua†L587-L600】
* **Payload:** `QuickbarState = { coins, melee = [{ Id, Equipped?, ... }], tokens = [{ Id, Count, StackLimit }] }` built by `QuickbarServer.BuildState`.
* **Emitted by:** `QuickbarServer.Refresh` (per player) and debug quickbar feeder. 【F:ServerScriptService/GameServer/QuickbarServer.lua†L587-L600】【F:ServerScriptService/GameServer/DevTest_QuickbarFeeder.server.lua†L70-L90】
* **Listeners:**
  * Quickbar controller rebuilds UI and safe area layout. 【F:StarterPlayer/StarterPlayerScripts/Controllers/QuickbarController.client.lua†L640-L688】
  * Controller support maps tokens to gamepad glyphs. 【F:StarterPlayer/StarterPlayerScripts/Controllers/ControllerSupport.client.lua†L40-L88】【F:StarterPlayer/StarterPlayerScripts/Controllers/ControllerSupport.client.lua†L180-L236】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L77-L79】

### ShopOpen
* **Direction:** Server ➜ Clients (global or arena-scoped). 【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L509-L533】
* **Payload:** `{ open = boolean, arenaId? }` indicating whether the shop UI should be accessible.
* **Emitted by:** `ShopServer.Open/Close` via `dispatchShopState`, including arena filtering. 【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L503-L540】
* **Listeners:** Audio controller cues shop ambience when the event arrives. 【F:StarterPlayer/StarterPlayerScripts/Controllers/AudioController.client.lua†L224-L227】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L77-L82】

### PurchaseMade
* **Direction:** Server ➜ Client (purchasing player).
* **Payload:** `{ itemId, kind, coins, price, stockRemaining?, stockLimit?, quickbar = QuickbarState }` returned after a successful purchase. 【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L731-L738】
* **Emitted by:** `ShopServer.processPurchase` after applying the transaction. 【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L580-L738】
* **Listeners:** No client consumer yet; payload is ready for future UI work.
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L77-L82】

### PlayerKO
* **Direction:** Intended Server ➜ Clients (player knockout notifications).
* **Status:** Remote is provisioned but no server currently fires it; `RoundDirectorServer` only tracks KO counts locally. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L83-L85】【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L416-L860】

### RE_Notice
* **Direction:** Server ➜ Clients. General-purpose toast/notice bus with localization support. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L83-L86】
* **Payload:** `{ msg, kind, key?, args?, locale?, ... }`, with optional domain-specific extras (e.g., summaries).
* **Emitted by:**
  * Shop server (errors, sold out, success). 【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L416-L432】
  * Token usage feedback. 【F:ServerScriptService/GameServer/TokenUseServer.server.lua†L168-L185】
  * Match return flows notify players before teleporting. 【F:ServerScriptService/Match/MatchReturnService.lua†L320-L347】
  * Round director sends gameplay notices per player. 【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L720-L768】
* **Listeners:** `UIRouter` reacts to error/failure notices to show Game Over or other states. 【F:StarterPlayer/StarterPlayerScripts/Controllers/UIRouter.client.lua†L185-L209】

### RE_AchievementToast
* **Direction:** Server ➜ Client (single player).
* **Payload:** `{ id, title, message }` describing the achievement toast. 【F:ServerScriptService/GameServer/AchievementServer.lua†L88-L105】
* **Emitted by:** `AchievementServer.grantAchievement` when thresholds are met. 【F:ServerScriptService/GameServer/AchievementServer.lua†L88-L105】
* **Listeners:** Client toast controller queues and animates popups. 【F:StarterPlayer/StarterPlayerScripts/Controllers/AchievementToast.client.lua†L19-L74】【F:StarterPlayer/StarterPlayerScripts/Controllers/AchievementToast.client.lua†L108-L156】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L83-L87】

### WaveComplete
* **Direction:** Server ➜ Clients. Announces the outcome of each wave, including metadata. 【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L776-L799】
* **Payload:** `{ arenaId, level, wave, success, ... }` with optional telemetry fields.
* **Emitted by:** `RoundDirectorServer` after a wave finishes or fails. 【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L776-L799】
* **Listeners:** None yet; hook available for UI or analytics.
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L88-L90】

### RE_SettingsPushed
* **Direction:** Server ➜ Client (per player). Mirrors the authoritative settings after load/save. 【F:ServerScriptService/GameServer/SettingsServer.lua†L322-L336】
* **Payload:** Sanitized settings `{ SprintToggle, AimAssistWindow, CameraShakeStrength, ColorblindPalette, TextScale, Locale }`.
* **Emitted by:** `SettingsServer.broadcastToClient` during load, changes, or defaults reset. 【F:ServerScriptService/GameServer/SettingsServer.lua†L322-L336】【F:ServerScriptService/GameServer/SettingsServer.lua†L360-L372】
* **Listeners:** Settings UI keeps its local state in sync with pushes. 【F:StarterPlayer/StarterPlayerScripts/Controllers/SettingsUI.client.lua†L1369-L1374】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L91-L95】

### RE_SessionLeaderboard
* **Direction:** Server ➜ Clients. Periodic session leaderboard snapshots. 【F:ServerScriptService/Data/LeaderboardServer.lua†L232-L258】
* **Payload:** `{ top/entries = [{ userId, score, rank, name, displayName }], totalPlayers, yourRank?, yourScore?, updated }`.
* **Emitted by:** `LeaderboardServer.broadcastSession`. 【F:ServerScriptService/Data/LeaderboardServer.lua†L232-L258】
* **Listeners:** In-game leaderboard UI renders session standings. 【F:StarterPlayer/StarterPlayerScripts/Controllers/LeaderboardUI.client.lua†L660-L707】
* **Defined at:** `RemoteBootstrap`. 【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L91-L95】

### PerfHarnessUpdate
* **Direction:** Server ➜ Clients (dev tooling). Streams performance samples (`dtAverage`, `dtMax`, `gcMb`, counts, warnings, budgets). 【F:ServerScriptService/Tools/PerfHarness.server.lua†L10-L140】
* **Payload:** `PerfSample` record with frame times, GC, projectile/VFX counts, budgets, and warnings. 【F:ServerScriptService/Tools/PerfHarness.server.lua†L120-L204】
* **Emitted by:** `PerfHarness` heartbeat sampler every second. 【F:ServerScriptService/Tools/PerfHarness.server.lua†L138-L204】
* **Listeners:** Client Perf HUD overlays debug metrics. 【F:StarterPlayer/StarterPlayerScripts/Tools/PerfHUD.client.lua†L10-L120】【F:StarterPlayer/StarterPlayerScripts/Tools/PerfHUD.client.lua†L200-L240】

### LevelComplete (expected)
* **Status:** `RoundDirectorServer` tries to fire `Remotes.LevelComplete`, but `RemoteBootstrap` does not provision this remote, so calls are no-ops. 【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L801-L817】【F:ReplicatedStorage/Remotes/RemoteBootstrap.lua†L65-L105】 Consider adding the remote if downstream consumers need it.

## RemoteFunctions

### RF_Purchase & RF_RequestPurchase
* **Direction:** Client ➜ Server request/response.
* **Payload:** Either `{ itemId = string }` or plain string item IDs (legacy). Validation trims to 64 chars and checks ownership/stock. 【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L780-L830】
* **Responses:** `{ ok, err?, coins?, price?, kind?, stockRemaining?, stockLimit?, quickbar? }` with notices fired separately. 【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L580-L738】
* **Handlers:** Modern clients should call `RF_Purchase`; legacy support remains via `RF_RequestPurchase`, both wrapped by Guard. 【F:ServerScriptService/GameServer/Shop/ShopServer.lua†L833-L857】

### RF_JoinQueue / RF_LeaveQueue
* **Direction:** Client ➜ Server (matchmaking).
* **Payload:**
  * `RF_JoinQueue(player, options?)` accepts optional member lists, returns `{ ok, partyId?, members?, error? }`. 【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L889-L959】【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L987-L995】
  * `RF_LeaveQueue` returns `{ ok }` or `{ ok = false, error = ... }` when teleporting/absent. 【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L962-L996】
* **Guard:** Both remotes are registered in `LobbyMatchmaker` with sanity checks before queue mutations. 【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L987-L996】

### RF_UseToken
* **Direction:** Client ➜ Server.
* **Payload:** Slot index (number) or `{ slot = number }`; validator enforces range and optional effect overrides. 【F:ServerScriptService/GameServer/TokenUseServer.server.lua†L128-L157】【F:ServerScriptService/GameServer/TokenUseServer.server.lua†L198-L206】
* **Responses:** `{ ok, err?, effect?, remaining?, ... }` from `TokenEffectsServer`.
* **Handlers:** `TokenUseServer` wraps the remote, records usage, and dispatches notices on success. 【F:ServerScriptService/GameServer/TokenUseServer.server.lua†L160-L207】
* **Clients:** Quickbar UI and controller support call the remote when tokens are activated. 【F:StarterPlayer/StarterPlayerScripts/Controllers/QuickbarController.client.lua†L508-L528】【F:StarterPlayer/StarterPlayerScripts/Controllers/ControllerSupport.client.lua†L58-L78】

### RF_SaveSettings
* **Direction:** Client ➜ Server for persisting accessibility settings.
* **Payload:** `{ SprintToggle, AimAssistWindow, CameraShakeStrength, ColorblindPalette, TextScale, Locale }` or `nil` to fetch current values. 【F:ServerScriptService/GameServer/SettingsServer.lua†L300-L408】
* **Responses:** Sanitized settings table after clamping/defaulting. 【F:ServerScriptService/GameServer/SettingsServer.lua†L300-L408】
* **Handlers:** `SettingsServer` applies the payload, rebroadcasts via `RE_SettingsPushed`, and writes to ProfileServer. 【F:ServerScriptService/GameServer/SettingsServer.lua†L300-L408】
* **Clients:** Settings UI requests the latest settings on boot and saves changes/toggles. 【F:StarterPlayer/StarterPlayerScripts/Controllers/SettingsUI.client.lua†L1354-L1374】【F:StarterPlayer/StarterPlayerScripts/Controllers/SettingsUI.client.lua†L412-L520】

### RF_Tutorial
* **Direction:** Client ➜ Server (onboarding progress).
* **Payload:** `{ action = "status"|"complete"|"reset"|"set"|... , completed? = boolean }` or string shorthand. 【F:ServerScriptService/GameServer/TutorialServer.lua†L60-L105】
* **Responses:** `{ success = true/false, completed, action }` reflecting the authoritative state. 【F:ServerScriptService/GameServer/TutorialServer.lua†L60-L105】
* **Clients:** Tutorial UI queries status and reports state transitions. 【F:StarterPlayer/StarterPlayerScripts/Controllers/TutorialUI.client.lua†L320-L347】【F:StarterPlayer/StarterPlayerScripts/Controllers/TutorialUI.client.lua†L20-L58】
* **Other callers:** Settings UI exposes a “Reset tutorial” convenience action. 【F:StarterPlayer/StarterPlayerScripts/Controllers/SettingsUI.client.lua†L1198-L1222】

### RF_GetGlobalLeaderboard
* **Direction:** Client ➜ Server.
* **Payload:** Optional entry count (defaults to session max). 【F:ServerScriptService/Data/LeaderboardServer.lua†L488-L516】
* **Responses:** `{ entries = [...], total, updated, source }` or fallback error payload when datastore calls fail. 【F:ServerScriptService/Data/LeaderboardServer.lua†L488-L516】
* **Clients:** Leaderboard UI fetches global standings on demand and refresh intervals. 【F:StarterPlayer/StarterPlayerScripts/Controllers/LeaderboardUI.client.lua†L584-L613】【F:StarterPlayer/StarterPlayerScripts/Controllers/LeaderboardUI.client.lua†L601-L708】

### RF_RequestContinue
* **Direction:** Client ➜ Server (monetization placeholder).
* **Payload:** `{ method = "token"|"fee"|"robux"|"ad" }` or string shortcut; server validates caps by level band. 【F:ServerScriptService/GameServer/Monetization/MonetizationServer.lua†L150-L208】
* **Responses:** `{ allowed = boolean, remaining = number, reason? }` summarizing continue availability. 【F:ServerScriptService/GameServer/Monetization/MonetizationServer.lua†L180-L199】
* **Handlers:** `MonetizationServer` tracks per-player usage and integrates future monetization flows. 【F:ServerScriptService/GameServer/Monetization/MonetizationServer.lua†L24-L206】

### RF_QAAdminCommand
* **Direction:** Client ➜ Server (QA/dev only).
* **Payload:** `{ action = "getstate"|"skipprep"|"setlevel"|"granttoken"|"toggleobstacles"|"setturretrate"|"macro", ... }` with action-specific fields validated by Guard. 【F:ServerScriptService/Tools/AdminCommands.server.lua†L932-L1014】【F:ServerScriptService/Tools/AdminCommands.server.lua†L1140-L1164】
* **Responses:** `{ ok, err?, state?, message? }` depending on the command.
* **Handlers:** `AdminCommands` wraps the remote with rate limiting and telemetry logging. 【F:ServerScriptService/Tools/AdminCommands.server.lua†L1140-L1164】
* **Clients:** QA admin panel invokes the remote to execute macros and arena utilities. 【F:StarterPlayer/StarterPlayerScripts/AdminPanel.client.lua†L27-L76】

## BindableEvents

### ArenaAdapter.ArenaRemoved
* **Direction:** Server-internal signal when an arena instance is removed.
* **Payload:** `arenaId` string/number.
* **Emitted by:** `ArenaAdapter` when cleaning up arena records. 【F:ServerScriptService/Combat/ArenaAdapter.lua†L225-L235】
* **Listeners:**
  * Projectile server removes lingering projectiles. 【F:ServerScriptService/Combat/ProjectileServer.lua†L483-L519】
  * Mini turret server stops turrets in that arena. 【F:ServerScriptService/Obstacles/MiniTurretServer.lua†L1053-L1065】
  * Target immunity server clears shields. 【F:ServerScriptService/GameServer/TargetImmunityServer.lua†L360-L370】

### TargetHealthServer.GameOver
* **Direction:** Server-internal notification per arena/lane.
* **Payload:** `(arenaId, laneId)` when a lane drops to zero or the arena wipes. 【F:ServerScriptService/GameServer/TargetHealthServer.lua†L324-L340】
* **Emitted by:** `TargetHealthServer` after processing damage. 【F:ServerScriptService/GameServer/TargetHealthServer.lua†L324-L340】
* **Listeners:** `RoundDirectorServer` listens to trigger defeat handling/teleport flows. 【F:ServerScriptService/GameServer/RoundDirectorServer.lua†L1158-L1165】

### CameraFeelBus.CameraFeelRequest
* **Direction:** Client-only event bus.
* **Payload:** `(kind, payload)` where `kind` is `"shake"`, `"token"`, `"sprint"`, or custom identifiers; payload contents vary per effect. 【F:StarterPlayer/StarterPlayerScripts/Controllers/CameraFeelBus.lua†L5-L43】
* **Emitters:** Combat/UI scripts call helper methods (e.g., melee swings, token usage) to signal camera feedback. 【F:StarterPlayer/StarterPlayerScripts/Controllers/MeleeController.client.lua†L360-L378】【F:StarterPlayer/StarterPlayerScripts/Controllers/QuickbarController.client.lua†L508-L528】
* **Listeners:** `CameraFeel.client` consumes the bus to play tweens/effects. 【F:StarterPlayer/StarterPlayerScripts/Controllers/CameraFeel.client.lua†L8-L246】

### UIRouter.OnChanged
* **Direction:** Client-only UI state change signal.
* **Payload:** `(newState, previousState)` enumerating `Lobby|Prep|InWave|Intermission|GameOver`. 【F:StarterPlayer/StarterPlayerScripts/Controllers/UIRouter.client.lua†L30-L154】
* **Emitters:** `UIRouter.SetState` fires the bindable when remote-driven conditions change. 【F:StarterPlayer/StarterPlayerScripts/Controllers/UIRouter.client.lua†L132-L154】
* **Listeners:** Additional client modules can subscribe via `UIRouter.OnChanged`; no current consumers in the repository.

### DebugServer (GiveCoins, SpawnFruit, FastPrep)
* **Direction:** Server debug tooling (BindableEvents under `ServerScriptService.GameServer.Debug`).
* **Payloads:**
  * `GiveCoins(player, amount)` feeds coins via EconomyServer. 【F:ServerScriptService/GameServer/DebugServer.server.lua†L120-L198】
  * `SpawnFruit(arenaId, laneId, fruitId)` queues fruit spawns. 【F:ServerScriptService/GameServer/DebugServer.server.lua†L200-L260】
  * `FastPrep()` triggers floor button/floor signals to fast-forward prep. 【F:ServerScriptService/GameServer/DebugServer.server.lua†L300-L370】
* **Emitters:** Debug scripts or command bar can fire these events when `GameConfig.Debug.Enabled` is true. 【F:ServerScriptService/GameServer/DebugServer.server.lua†L18-L130】
* **Listeners:** Each event immediately binds to helper functions within `DebugServer`. 【F:ServerScriptService/GameServer/DebugServer.server.lua†L200-L370】

---

*This map only covers signals present in the repository at commit time. Future remotes should be added here to keep the reference accurate.*
