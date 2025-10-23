# Gameplay Loops

Gameplay in FruitSmash revolves around timed arena matches where squads collect fruit combos and trigger power-ups.

## Core Match Flow

1. The lobby queues players through [`LobbyMatchmaker.server.lua`](../ServerScriptService/Match/LobbyMatchmaker.server.lua).
2. Once matched, [`MatchArrivalServer.server.lua`](../ServerScriptService/Match/MatchArrivalServer.server.lua) spawns players into the selected arena template from [`ServerStorage/ArenaTemplates`](../ServerStorage/ArenaTemplates).
3. Client controllers such as [`PlayerController.client.lua`](../StarterPlayer/StarterPlayerScripts/Controllers/PlayerController.client.lua) handle input, ability cooldowns, and replication hooks.
4. Match results flow back through [`MatchReturnServer.server.lua`](../ServerScriptService/Match/MatchReturnServer.server.lua) which emits reward events.

Cross-reference the [architecture overview](./architecture.md#service-layout) for how these services align with Rojo.

## Reward Payouts

- [`EconomyServer.lua`](../ServerScriptService/Economy/EconomyServer.lua) grants coins and seasonal tokens based on the match summary.
- [`DailyRewardsServer.lua`](../ServerScriptService/Economy/DailyRewardsServer.lua) checks streak progress and schedules the next claim time.
- [`SaveService.lua`](../ServerScriptService/Data/SaveService.lua) persists the resulting currency and unlock flags.

Reward tuning happens via [`ReplicatedStorage/Shared/Config/GameConfig.lua`](../ReplicatedStorage/Shared/Config/GameConfig.lua) and related config tables consumed by the economy services.

## Coop Boss Variant

The Jungle Jam variant uses cooperative objectives:

- Boss AI spawns are defined by [`ServerStorage/EnemyProfiles`](../ServerStorage/EnemyProfiles).
- [`MiniTurretServer.lua`](../ServerScriptService/Obstacles/MiniTurretServer.lua) handles turret hazards triggered during phases.
- Client FX and prompts are routed through [`HUDController.client.lua`](../StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua).

See the [UI guide](./ui-guide.md#match-prompts) for HUD callouts delivered during boss mechanics.
