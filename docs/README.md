# FruitSmash Developer Hub

[![Engine](https://img.shields.io/badge/engine-Roblox-6f42c1)](https://create.roblox.com/) [![Docs](https://img.shields.io/badge/docs-quick_start-0a84ff)](#quick-links) [![License](https://img.shields.io/badge/license-TBD-lightgrey)](#license) [![Issues](https://img.shields.io/badge/issues-github-orange)](../../issues)

> Fast-paced arena battles with co-op boss fights, wild power-ups, and seasonal events keep squads jumping back into FruitSmash. Refer to the localized [store blurb](../Marketing/StoreAssets/blurbs/en-US.json) for messaging updates.

## Quick Links

- 🎮 **Playable place file:** [FruitSmash_V2.rbxl](../FruitSmash_V2.rbxl) — Roblox Studio snapshot for rapid testing.
- 🛠️ **Rojo project:** [default.project.json](../default.project.json) — sync entry point for live game services and UI packages.
- 🗂️ **Asset manifest:** [manifest/repo_manifest.json](../manifest/repo_manifest.json) — generated file index with size, language, and docstring metadata.
- 🧾 **Marketing assets:** [Marketing/StoreAssets/README.md](../Marketing/StoreAssets/README.md) — icon, screenshot, and trailer export checklists.
- 🐞 **Issue tracker:** [GitHub Issues](../../issues) — file bugs, balance requests, and UX feedback.

## Core Experience Snapshot

FruitSmash is positioned as a frantic multiplayer brawler stacked with power-ups, social play, and rotating events, encouraging squads to chase cosmetics and tournament leaderboards ([store blurb](../Marketing/StoreAssets/blurbs/en-US.json)).

## Key Systems at a Glance

- **EconomyServer** centralizes point and coin rewards, wiring fruit hits and round bonuses into leaderboard submissions and player attributes ([ServerScriptService/Economy/EconomyServer.lua](../ServerScriptService/Economy/EconomyServer.lua)).
- **LeaderboardServer** pushes live session standings and optionally syncs a global ordered DataStore for long-term competition ([ServerScriptService/Data/LeaderboardServer.lua](../ServerScriptService/Data/LeaderboardServer.lua)).
- **TutorialUI** coordinates onboarding, adapting steps to the player’s input mode and remote tutorial state ([StarterPlayer/StarterPlayerScripts/Controllers/TutorialUI.client.lua](../StarterPlayer/StarterPlayerScripts/Controllers/TutorialUI.client.lua)).
- **VersionAnnounce** surfaces build metadata (version, commit, timestamps) into logs and game attributes for runtime diagnostics ([ServerScriptService/Analytics/VersionAnnounce.server.lua](../ServerScriptService/Analytics/VersionAnnounce.server.lua)).

## Getting Started

1. Install the [Roblox Studio](https://create.roblox.com/landing/studio) tooling bundle if you have not already.
2. Launch `FruitSmash_V2.rbxl` in Studio for quick inspection of the current content drop.
3. Use the bundled `rojo.exe` to sync code changes into Studio with `./rojo.exe serve default.project.json`.
4. Confirm build metadata in the output window (`[VersionAnnounce] FruitSmash v...`) before publishing test instances ([VersionAnnounce](../ServerScriptService/Analytics/VersionAnnounce.server.lua)).

## Release Assets

- Store copy and localization strings live in `Marketing/StoreAssets/blurbs/` alongside per-locale JSON stubs ([blurbs README](../Marketing/StoreAssets/blurbs/README.md)).
- Icon, screenshot, and trailer guidelines are documented in the `Marketing/StoreAssets/` subfolders before upload drives ([marketing overview](../Marketing/StoreAssets/README.md), [trailer notes](../Marketing/StoreAssets/trailer/README.md), [screenshot plan](../Marketing/StoreAssets/screenshots/README.md)).

## License

This repository does not yet specify an open-source license. Treat the contents as internal-only until a license is published.
