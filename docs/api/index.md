# FruitSmash API Index

This high-level index groups every documented module by its gameplay or platform area.
Use it to locate the generated per-module API pages and drill into specific systems.

## Client

Scripts that run on the client, handling controllers, UI, and player-facing tooling.

### Controllers

- [AchievementToast](modules/StarterPlayer/StarterPlayerScripts/Controllers/AchievementToast.client.md) — ClientScript • 290 lines • docstrings ✅
- [AudioController](modules/StarterPlayer/StarterPlayerScripts/Controllers/AudioController.client.md) — ClientScript • 234 lines • docstrings ✅
- [CameraFeel](modules/StarterPlayer/StarterPlayerScripts/Controllers/CameraFeel.client.md) — ClientScript • 260 lines • docstrings ✅
- [CameraFeelBus](modules/StarterPlayer/StarterPlayerScripts/Controllers/CameraFeelBus.md) — ModuleScript • 45 lines • docstrings ✅
- [ControllerSupport](modules/StarterPlayer/StarterPlayerScripts/Controllers/ControllerSupport.client.md) — ClientScript • 575 lines • docstrings ✅
- [HUDController](modules/StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.md) — ClientScript • 1569 lines • docstrings ✅
- [LeaderboardUI](modules/StarterPlayer/StarterPlayerScripts/Controllers/LeaderboardUI.client.md) — ClientScript • 750 lines • docstrings ✅
- [MeleeController](modules/StarterPlayer/StarterPlayerScripts/Controllers/MeleeController.client.md) — ClientScript • 447 lines • docstrings ❌
- [PlayerController](modules/StarterPlayer/StarterPlayerScripts/Controllers/PlayerController.client.md) — ClientScript • 420 lines • docstrings ✅
- [QueueUI](modules/StarterPlayer/StarterPlayerScripts/Controllers/QueueUI.client.md) — ClientScript • 488 lines • docstrings ✅
- [QuickbarController](modules/StarterPlayer/StarterPlayerScripts/Controllers/QuickbarController.client.md) — ClientScript • 710 lines • docstrings ✅
- [RoundSummary](modules/StarterPlayer/StarterPlayerScripts/Controllers/RoundSummary.client.md) — ClientScript • 432 lines • docstrings ✅
- [SettingsUI](modules/StarterPlayer/StarterPlayerScripts/Controllers/SettingsUI.client.md) — ClientScript • 1398 lines • docstrings ✅
- [TutorialUI](modules/StarterPlayer/StarterPlayerScripts/Controllers/TutorialUI.client.md) — ClientScript • 600 lines • docstrings ✅
- [UIRouter](modules/StarterPlayer/StarterPlayerScripts/Controllers/UIRouter.client.md) — ClientScript • 216 lines • docstrings ✅

### Core Scripts

- [AdminPanel](modules/StarterPlayer/StarterPlayerScripts/AdminPanel.client.md) — ClientScript • 471 lines • docstrings ✅

### Tools

- [PerfHUD](modules/StarterPlayer/StarterPlayerScripts/Tools/PerfHUD.client.md) — ClientScript • 224 lines • docstrings ✅

### User Interface

- [GlobalLeaderboard](modules/StarterGui/Lobby/GlobalLeaderboard.client.md) — ClientScript • 275 lines • docstrings ✅
- [Screen_RoundTimer](modules/StarterGui/WorldScreens/Screen_RoundTimer.client.md) — ClientScript • 212 lines • docstrings ✅
- [Screen_WaveTimer](modules/StarterGui/WorldScreens/Screen_WaveTimer.client.md) — ClientScript • 156 lines • docstrings ✅

## Shared

Modules replicated between server and client that expose configuration, systems, and shared data.

### Configuration

- [BuildInfo](modules/ReplicatedStorage/Shared/Config/BuildInfo.md) — ModuleScript • 9 lines • docstrings ✅
- [Flags](modules/ReplicatedStorage/Shared/Config/Flags.md) — ModuleScript • 929 lines • docstrings ✅
- [FruitConfig](modules/ReplicatedStorage/Shared/Config/FruitConfig.md) — ModuleScript • 111 lines • docstrings ✅
- [GameConfig](modules/ReplicatedStorage/Shared/Config/GameConfig.md) — ModuleScript • 217 lines • docstrings ✅
- [ShopConfig](modules/ReplicatedStorage/Shared/Config/ShopConfig.md) — ModuleScript • 160 lines • docstrings ✅

### Content

- [ContentRegistry](modules/ReplicatedStorage/Shared/Content/ContentRegistry.md) — ModuleScript • 493 lines • docstrings ❌

### Localization

- [Strings](modules/ReplicatedStorage/Shared/Locale/Strings.md) — ModuleScript • 256 lines • docstrings ✅

### Networking Remotes

- [RemoteBootstrap](modules/ReplicatedStorage/Remotes/RemoteBootstrap.md) — ModuleScript • 110 lines • docstrings ✅

### Systems

- [AudioBus](modules/ReplicatedStorage/Shared/Systems/AudioBus.md) — ModuleScript • 382 lines • docstrings ✅
- [Localizer](modules/ReplicatedStorage/Shared/Systems/Localizer.md) — ModuleScript • 168 lines • docstrings ✅
- [RNG](modules/ReplicatedStorage/Shared/Systems/RNG.md) — ModuleScript • 48 lines • docstrings ❌
- [VFXBus](modules/ReplicatedStorage/Shared/Systems/VFXBus.md) — ModuleScript • 588 lines • docstrings ❌
- [WeightedTable](modules/ReplicatedStorage/Shared/Systems/WeightedTable.md) — ModuleScript • 85 lines • docstrings ❌

### Types

- [NetTypes](modules/ReplicatedStorage/Shared/Types/NetTypes.md) — ModuleScript • 21 lines • docstrings ❌
- [SaveSchema](modules/ReplicatedStorage/Shared/Types/SaveSchema.md) — ModuleScript • 25 lines • docstrings ❌

## Server

Authoritative gameplay and service logic that executes on the Roblox server.

### Analytics

- [TelemetryServer](modules/ServerScriptService/Analytics/TelemetryServer.md) — ModuleScript • 1254 lines • docstrings ✅
- [VersionAnnounce](modules/ServerScriptService/Analytics/VersionAnnounce.server.md) — ServerScript • 100 lines • docstrings ✅

### Combat Systems

- [ArenaAdapter](modules/ServerScriptService/Combat/ArenaAdapter.md) — ModuleScript • 332 lines • docstrings ❌
- [HitValidationServer](modules/ServerScriptService/Combat/HitValidationServer.md) — ModuleScript • 597 lines • docstrings ❌
- [ProjectileServer](modules/ServerScriptService/Combat/ProjectileServer.md) — ModuleScript • 487 lines • docstrings ❌

### Data Services

- [LeaderboardServer](modules/ServerScriptService/Data/LeaderboardServer.md) — ModuleScript • 549 lines • docstrings ✅
- [ProfileServer](modules/ServerScriptService/Data/ProfileServer.md) — ModuleScript • 1431 lines • docstrings ✅
- [SaveService](modules/ServerScriptService/Data/SaveService.md) — ModuleScript • 663 lines • docstrings ✅

### Economy Services

- [DailyRewardsServer](modules/ServerScriptService/Economy/DailyRewardsServer.md) — ModuleScript • 587 lines • docstrings ✅
- [EconomyServer](modules/ServerScriptService/Economy/EconomyServer.md) — ModuleScript • 509 lines • docstrings ✅

### GameServer Combat

- [CombatServer](modules/ServerScriptService/GameServer/Combat/CombatServer.md) — ModuleScript • 518 lines • docstrings ✅

### GameServer Core

- [AchievementServer](modules/ServerScriptService/GameServer/AchievementServer.md) — ModuleScript • 391 lines • docstrings ✅
- [AnalyticsServer](modules/ServerScriptService/GameServer/AnalyticsServer.server.md) — ServerScript • 113 lines • docstrings ❌
- [ArenaAdapter](modules/ServerScriptService/GameServer/ArenaAdapter.md) — ModuleScript • 245 lines • docstrings ❌
- [ArenaServer](modules/ServerScriptService/GameServer/ArenaServer.md) — ModuleScript • 95 lines • docstrings ❌
- [ArenaTemplateSetup](modules/ServerScriptService/GameServer/ArenaTemplateSetup.server.md) — ServerScript • 241 lines • docstrings ✅
- [DebugServer](modules/ServerScriptService/GameServer/DebugServer.server.md) — ServerScript • 367 lines • docstrings ✅
- [DevTest_QuickbarFeeder](modules/ServerScriptService/GameServer/DevTest_QuickbarFeeder.server.md) — ServerScript • 93 lines • docstrings ✅
- [FruitSpawnerServer](modules/ServerScriptService/GameServer/FruitSpawnerServer.md) — ModuleScript • 715 lines • docstrings ❌
- [HUDServer](modules/ServerScriptService/GameServer/HUDServer.md) — ModuleScript • 305 lines • docstrings ✅
- [Init](modules/ServerScriptService/GameServer/Init.server.md) — ServerScript • 123 lines • docstrings ✅
- [MatchmakingServer](modules/ServerScriptService/GameServer/MatchmakingServer.md) — ModuleScript • 147 lines • docstrings ❌
- [ProjectileMotionServer](modules/ServerScriptService/GameServer/ProjectileMotionServer.md) — ModuleScript • 371 lines • docstrings ❌
- [ProjectileServer](modules/ServerScriptService/GameServer/ProjectileServer.md) — ModuleScript • 55 lines • docstrings ❌
- [QuickbarServer](modules/ServerScriptService/GameServer/QuickbarServer.md) — ModuleScript • 673 lines • docstrings ✅
- [RoundDirectorServer](modules/ServerScriptService/GameServer/RoundDirectorServer.md) — ModuleScript • 1760 lines • docstrings ❌
- [RoundSummaryServer](modules/ServerScriptService/GameServer/RoundSummaryServer.md) — ModuleScript • 345 lines • docstrings ✅
- [SettingsServer](modules/ServerScriptService/GameServer/SettingsServer.md) — ModuleScript • 421 lines • docstrings ✅
- [TargetHealthServer](modules/ServerScriptService/GameServer/TargetHealthServer.md) — ModuleScript • 454 lines • docstrings ❌
- [TargetImmunityServer](modules/ServerScriptService/GameServer/TargetImmunityServer.md) — ModuleScript • 375 lines • docstrings ❌
- [TokenEffectsServer](modules/ServerScriptService/GameServer/TokenEffectsServer.md) — ModuleScript • 899 lines • docstrings ✅
- [TokenUseServer](modules/ServerScriptService/GameServer/TokenUseServer.server.md) — ServerScript • 215 lines • docstrings ✅
- [TurretControllerServer](modules/ServerScriptService/GameServer/TurretControllerServer.md) — ModuleScript • 753 lines • docstrings ❌
- [TutorialServer](modules/ServerScriptService/GameServer/TutorialServer.md) — ModuleScript • 134 lines • docstrings ✅

### GameServer Data

- [PersistenceServer](modules/ServerScriptService/GameServer/Data/PersistenceServer.md) — ModuleScript • 442 lines • docstrings ✅

### GameServer Economy

- [EconomyServer](modules/ServerScriptService/GameServer/Economy/EconomyServer.md) — ModuleScript • 289 lines • docstrings ❌

### GameServer Libraries

- [ArenaAdapter](modules/ServerScriptService/GameServer/Libraries/ArenaAdapter.md) — ModuleScript • 100 lines • docstrings ❌

### GameServer Monetization

- [MonetizationServer](modules/ServerScriptService/GameServer/Monetization/MonetizationServer.md) — ModuleScript • 287 lines • docstrings ✅

### GameServer Obstacles

- [Obstacle_MiniTurretServer](modules/ServerScriptService/GameServer/Obstacles/Obstacle_MiniTurretServer.md) — ModuleScript • 547 lines • docstrings ❌
- [SawbladeServer](modules/ServerScriptService/GameServer/Obstacles/SawbladeServer.md) — ModuleScript • 994 lines • docstrings ❌

### GameServer Shop

- [MeleeGachaServer](modules/ServerScriptService/GameServer/Shop/MeleeGachaServer.md) — ModuleScript • 242 lines • docstrings ✅
- [ShopServer](modules/ServerScriptService/GameServer/Shop/ShopServer.md) — ModuleScript • 980 lines • docstrings ✅

### Matchmaking

- [LobbyMatchmaker](modules/ServerScriptService/Match/LobbyMatchmaker.server.md) — ServerScript • 1018 lines • docstrings ✅
- [MatchArrivalServer](modules/ServerScriptService/Match/MatchArrivalServer.server.md) — ServerScript • 681 lines • docstrings ✅
- [MatchReturnServer](modules/ServerScriptService/Match/MatchReturnServer.server.md) — ServerScript • 230 lines • docstrings ✅
- [MatchReturnService](modules/ServerScriptService/Match/MatchReturnService.md) — ModuleScript • 390 lines • docstrings ✅

### Moderation

- [GuardServer](modules/ServerScriptService/Moderation/GuardServer.md) — ModuleScript • 1035 lines • docstrings ✅

### Obstacle Systems

- [MiniTurretServer](modules/ServerScriptService/Obstacles/MiniTurretServer.md) — ModuleScript • 1065 lines • docstrings ❌

### Shop Services

- [ShopServer](modules/ServerScriptService/Shop/ShopServer.md) — ModuleScript • 9 lines • docstrings ✅

### Tooling

- [AdminCommands](modules/ServerScriptService/Tools/AdminCommands.server.md) — ServerScript • 1167 lines • docstrings ✅
- [BotLoad](modules/ServerScriptService/Tools/BotLoad.server.md) — ServerScript • 407 lines • docstrings ✅
- [PerfHarness](modules/ServerScriptService/Tools/PerfHarness.server.md) — ServerScript • 265 lines • docstrings ✅
- [RepoHealthCheck](modules/ServerScriptService/Tools/RepoHealthCheck.server.md) — ServerScript • 201 lines • docstrings ✅
- [StressConfig](modules/ServerScriptService/Tools/StressConfig.md) — ModuleScript • 76 lines • docstrings ✅

## Server Storage

Server-only modules kept in storage for templating and offline use.

### Arena Templates

- [init](modules/ServerStorage/ArenaTemplates/BaseArena/init.md) — ModuleScript • 170 lines • docstrings ❌
