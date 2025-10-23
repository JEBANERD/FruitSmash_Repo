# UI Guide

The UI is split between lobby shell interfaces and in-match HUD overlays. Controllers live under [`StarterPlayerScripts/Controllers`](../StarterPlayer/StarterPlayerScripts/Controllers).

## HUD Systems

HUD orchestration flows through [`HUDController.client.lua`](../StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua). Key surfaces:

- **Scoreboard** — fed by [`MatchReturnServer.server.lua`](../ServerScriptService/Match/MatchReturnServer.server.lua) and rendered through `HUDController.client.lua` panels.
- **Ability tray** — managed by `Controllers/PlayerController.client.lua` with cooldown overlays.
- **Event prompts** — triggered by shared signals registered in [`ReplicatedStorage/Remotes/RemoteBootstrap.lua`](../ReplicatedStorage/Remotes/RemoteBootstrap.lua).

Match overlays reference the [core match flow](./gameplay.md#core-match-flow) for sequencing.

## Lobby Shell

Lobby navigation is implemented with [`UIRouter.client.lua`](../StarterPlayer/StarterPlayerScripts/Controllers/UIRouter.client.lua). Panels include:

1. **Play** — queue selection and squad status.
2. **Locker** — loadout configuration backed by [`ProfileServer`](../ServerScriptService/Data/ProfileServer.lua).
3. **Shop** — powered by [`EconomyServer.lua`](../ServerScriptService/Economy/EconomyServer.lua) and remote product metadata.

## Match Prompts

Special mechanics (boss warnings, capture points, etc.) use prompt definitions exposed through [`ReplicatedStorage/Shared/Content/ContentRegistry.lua`](../ReplicatedStorage/Shared/Content/ContentRegistry.lua). The client surfaces them through `Controllers/TutorialUI.client.lua` and `Controllers/AchievementToast.client.lua`.

For boss callouts, coordinate with the [gameplay doc](./gameplay.md#coop-boss-variant) so prompt copy matches mechanic timings.
