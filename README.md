# Fruit Smash Repository Guide

> For folder-specific playbooks see the localized `README.md` files; this document anchors the shared vocabulary.

## Project overview
- **Fruit Smash** is a cooperative arena experience built for Roblox where players slice waves of fruit-driven enemies and chase leaderboard scores.
- The repository is organized for use with [Rojo](https://rojo.space/), mirroring Roblox services on disk so code review and automation stay git-native.
- Gameplay code is authored in typed Luau, leaning on ModuleScripts to keep server and client responsibilities isolated yet testable.
- Assets such as particle emitters, sound definitions, and model factories live alongside the scripts that consume them to simplify refactors.
- RemoteEvents and RemoteFunctions are centralized to make network contracts explicit and auditable.

## Tech stack
- **Engine:** Roblox, targeting live servers with studio-friendly fallbacks for offline iteration.
- **Language:** Strict-mode Luau with type annotations and module encapsulation.
- **Tooling:** Rojo for file-to-instance syncing, Selene/Luau lints (run via CI), and in-game debug panels like `AdminPanel.client.lua` and `PerfHUD.client.lua`.
- **Data:** DataStoreService on production with in-memory simulators for Studio, orchestrated by `SaveService` and `ProfileServer`.
- **Effects:** Customizable VFX and SFX registries under `ReplicatedStorage/Assets` and `Shared/Systems`.

## Directory quick-map
- `ReplicatedStorage/` – shared constants, assets, remotes, and thin service locators reachable by both server and client.
- `ServerScriptService/` – authoritative match flow, economy, telemetry, and gameplay systems that only run on the server.
- `StarterPlayer/StarterPlayerScripts/` – client controllers, UI routers, accessibility affordances, and debug tooling injected when players spawn.
- `StarterGui/` – screen and world-space UI templates that controllers clone and populate at runtime.
- `ServerStorage/` – arena templates, spawn profiles, and item prefabs that never replicate but fuel procedural runs.
- `Workspace/` – placeholder for synced workspace references; run-time population happens via server scripts.
- `Marketing/` – storefront collateral, icons, blurbs, and trailer scripts for reference when publishing updates.

## Development workflow
- Install Rojo 7.x and run `rojo build -o FruitSmash_V2.rbxlx` or `rojo serve` while Roblox Studio is open to sync live edits.
- When serving, ensure the `default.project.json` tree stays aligned with new folders; mismatches cause silent instance drops.
- Prefer editing ModuleScripts locally and relying on `rojo serve`; avoid Studio-only edits unless back-porting into git immediately afterward.
- For network debugging, use the `AdminPanel` quick actions and the `PerfHUD` stats overlay included in `StarterPlayerScripts/Tools`.
- Studio testing should cover: solo queue entry, party teleport fallbacks, save/load flows, and daily reward claims.

## Testing & quality gates
- Run automated unit or integration tests in Studio via `TestService` hooks embedded in controllers and servers (look for `--!strict` and `_test` patterns).
- Use in-game toggles exposed by `SettingsUI` to simulate accessibility options, ensuring translations and input modes behave.
- Data-critical modules like `SaveService` and `ProfileServer` log build metadata; validate the metadata fields before rolling a live build.
- Matchmaking scripts (`LobbyMatchmaker`, `MatchArrivalServer`, `MatchReturnServer`) rely on RemoteEvents enumerated in `RemoteBootstrap`; keep the tables frozen to catch typos early.
- Particle and sound assets expose typed factories; run VFX previews in a throwaway place to confirm performance budgets.

## Coding conventions
- ModuleScripts are PascalCase, returning a single table with clear method boundaries; prefer dependency injection via arguments over globals.
- Client scripts end with `.client.lua`, server scripts with `.server.lua`; plain `.lua` indicates shared modules required by multiple contexts.
- Maintain strict typing annotations and explicit `::` casts where inference fails; lint warnings must be resolved before merging.
- Folders that only ensure tree stability (e.g., `.gitkeep`) should be documented in their localized README to avoid accidental deletion.
- Remote identifiers (`RE_` events, `RF_` functions) must be declared in `RemoteBootstrap` and consumed via `require(ReplicatedStorage.Remotes.RemoteBootstrap)`.

## Adding new features
1. Prototype the gameplay or UI module in the relevant service folder (`ServerScriptService`, `StarterPlayerScripts`, etc.).
2. Update or create the directory-local `README.md` to capture the intent, entry points, and onboarding steps for future contributors.
3. If new assets are required, register them in `ReplicatedStorage/Assets` and surface them through the appropriate bus (`AudioBus`, `VFXBus`).
4. Wire new remotes centrally so both client and server have a single source of truth; document payload formats in code comments.
5. Verify Rojo sync by running `rojo build` and opening the generated place file before pushing changes.

## Data & telemetry checklist
- `Analytics/TelemetryServer.lua` streams session metrics; keep the schema forward-compatible because dashboards rely on string keys.
- `Analytics/VersionAnnounce.server.lua` informs players about builds; bump the version string in `Shared/Config/Flags.lua` when releasing.
- Leaderboards fetch through `ServerScriptService/Data/LeaderboardServer.lua`; ensure `StarterGui/Lobby/GlobalLeaderboard.client.lua` gracefully handles downtime.
- Economy scripts (`EconomyServer`, `DailyRewardsServer`) must respect currency caps defined in `Shared/Config/GameConfig.lua`.
- When editing save schemas, update `Shared/Types/SaveSchema.lua` and add migration notes to `Data/SaveService.lua` comments.

## Documentation pointers
- Every key folder now owns a local README summarizing its moving pieces; start with the service that matches your change.
- See [`ReplicatedStorage/README.md`](ReplicatedStorage/README.md) for cross-cutting modules shared between client and server.
- See [`ServerScriptService/README.md`](ServerScriptService/README.md) for authoritative gameplay and persistence flows.
- See [`StarterPlayer/StarterPlayerScripts/README.md`](StarterPlayer/StarterPlayerScripts/README.md) for client-controller relationships and UI wiring.
- See [`StarterGui/README.md`](StarterGui/README.md) for screen compositions and world-space signage.
- Use the `manifest/repo_manifest.json` snapshot when auditing file counts or verifying that large refactors touched all expected scripts.

## Support & contact
- Feature questions: reach out to the gameplay team (#gameplay channel) and reference the module owner table in `ServerScriptService/README.md`.
- Live issues: coordinate with ops to toggle matchmaking via `MatchReturnService` safeguards before shipping hotfixes.
- Documentation updates: open a PR tagged `docs` and keep line counts within the 50–150 guideline for localized READMEs.
- Asset pipeline questions: ping the art lead; see the `ReplicatedStorage/Assets` README for naming and registration patterns.
- Marketing requests: consult the `Marketing/StoreAssets` subtree; it already includes publishing templates and screenshot guidelines.

## Change log
- 2025-01-XX: Initial localized documentation pass generated from repository audit.
- Future updates should append dated bullets summarizing scope and linking to the corresponding PR.
