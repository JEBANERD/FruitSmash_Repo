# FruitSmash Documentation Hub

FruitSmash ships with a distributed Luau codebase that mirrors the live Roblox experience. These docs gather the core references we use while developing and operating the experience.

## Document Map

- [Architecture overview](./architecture.md#service-layout) — server/client boundaries and shared modules.
- [Gameplay loops](./gameplay.md#core-match-flow) — match lifecycle, scoring, and rewards.
- [UI reference](./ui-guide.md#hud-systems) — HUD composition and lobby shell navigation.

## Useful Repository Links

- [`default.project.json`](../default.project.json) defines the Rojo tree for syncing into Roblox Studio.
- [`ServerScriptService/Data/ProfileServer.lua`](../ServerScriptService/Data/ProfileServer.lua) — authoritative profile + inventory persistence.
- [`StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua`](../StarterPlayer/StarterPlayerScripts/Controllers/HUDController.client.lua) — UI routing for match and lobby HUD states.

See [architecture.md](./architecture.md#sync-pipeline) for the Rojo deployment pipeline.
