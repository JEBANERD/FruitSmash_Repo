# ReplicatedStorage Playbook

> This folder syncs to Roblox `ReplicatedStorage`, making everything inside available to both server and client. See the [project overview](../README.md) for repository-wide conventions.

## What lives here
- **Assets/** – Luau factories that build 3D fruit models (`Assets/Fruit/init.lua`) and reusable VFX definitions (`Assets/VFX/init.lua`).
- **Remotes/** – `RemoteBootstrap.lua` enumerates every RemoteEvent/RemoteFunction the game supports and guarantees they exist on boot.
- **Shared/** – Shared config tables, localization helpers, data types, and system utilities consumed by both gameplay contexts.
- Lightweight ModuleScripts that expose constants or helper functions intended to be required from multiple services.
- Transient folders or `.gitkeep` files should not be added here; everything should have an explicit runtime consumer.

## Access patterns
- Require modules with `require(ReplicatedStorage.Shared.<Module>)` to benefit from Rojo's mirrored folder names.
- Remote callers must import `ReplicatedStorage.Remotes.RemoteBootstrap` instead of storing raw references to avoid mismatched names.
- Asset registries return tables that controllers iterate over; avoid calling constructors during module load to keep replication light.
- Config modules typically export a `Get()` function that returns a frozen table; mutate copies locally if adjustments are needed.
- Localization strings come from `Shared/Locale/Strings.lua` via the `Localizer` system; never hard-code user-facing text.

## Naming conventions
- ModuleScripts use **PascalCase** and carry `.lua`; client-only or server-only scripts should live elsewhere.
- Table members that represent remotes follow `RF_` (RemoteFunction) or `RE_` (RemoteEvent) prefixes for clarity.
- Asset keys (e.g., `FruitAssets.Apple`) use **PascalCase** for exported members, matching in-game naming for analytics.
- Configuration modules that return dictionaries append `Config` to the filename (`GameConfig.lua`, `ShopConfig.lua`).
- Shared systems that behave like buses (`AudioBus.lua`, `VFXBus.lua`) accept dictionaries with `Name` or `Id` keys to avoid collisions.

## Adding a new shared module
1. Create a ModuleScript under `Shared/` with a descriptive PascalCase filename.
2. Export a table; avoid side effects during module evaluation to preserve replication performance.
3. If the module consumes remotes, import the bootstrapper and assert the remote exists before using it.
4. Document usage inside the module with Luau doc comments and add a summary bullet in this README under the relevant section.
5. Update any dependent folders' READMEs if the module becomes a required part of their workflows.

## Adding assets
1. Extend `Assets/Fruit/init.lua` or `Assets/VFX/init.lua` by registering new entries in the returned table.
2. Follow existing constructors: use helper functions such as `createFruitModel` or `createBasePart` to ensure attachments and physics defaults are set.
3. Keep asset option tables declarative; prefer offsets in relative coordinates to simplify resizing.
4. If the asset needs audio or VFX triggers, register corresponding SFX names in `Shared/Systems/AudioBus.lua` and `VFXBus.lua`.
5. Test new assets in Studio by requiring the module via the command bar and instantiating it in a temporary Workspace folder.

## Remote management checklist
- Add new remotes to `Remotes/RemoteBootstrap.lua`; the helper will destroy incorrectly typed instances before recreating them.
- Keep the remote table typed (`type RemoteRefs = { ... }`) so Luau surfaces contract mismatches in both client and server code.
- Freeze the exported remotes table to catch accidental assignments (`table.freeze(Remotes)` already runs at the end of the file).
- Update localized documentation (e.g., `StarterPlayerScripts/Controllers`) whenever new remotes are introduced for UI flows.
- Use explicit payload tables (e.g., `{ player = Player, amount = number }`) and document shapes in the module that fires the remote.

## Dependencies & interactions
- `Shared/Systems/Localizer.lua` pulls translation tables from `Shared/Locale/Strings.lua`; keep keys stable across releases.
- `Shared/Config/Flags.lua` surfaces build metadata that `ServerScriptService/Data/SaveService.lua` reads for diagnostics.
- `Shared/Content/ContentRegistry.lua` tracks reward and drop tables used by both server loot logic and client UI previews.
- Audio definitions under `Shared/Assets/SFX` are consumed by `Shared/Systems/AudioBus.lua`; avoid duplicating sound IDs elsewhere.
- Type definitions in `Shared/Types` should be required by both server and client modules to ensure structural parity.

## When to move code elsewhere
- Server-only logic (DataStore writes, matchmaking) belongs in `ServerScriptService`.
- Client-only view models or controllers live in `StarterPlayer/StarterPlayerScripts`.
- Anything that requires 3D instantiation on spawn belongs in `ServerStorage` or `Workspace` templates and should not be stored here.
- Marketing or build automation assets should stay under `Marketing/` to avoid being replicated into the game runtime.
- Tool-specific scripts that players equip belong in `StarterPack` or relevant tool subfolders.

## Maintenance to-dos
- [ ] Audit `Assets` factories quarterly to ensure attachments and SFX align with gameplay expectations.
- [ ] Verify remote names against analytics dashboards before each season release to keep metrics stable.
- [ ] Review shared configuration defaults when balance patches ship; update `GameConfig` and `FruitConfig` accordingly.
- [ ] Run localization sweeps by diffing `Locale/Strings.lua` against third-party translation exports.
- [ ] Keep this README updated with any new subfolder additions or workflow changes.

## Additional resources
- Review [`Shared/README.md`](Shared/README.md) for deep dives on the shared config and system modules.
- Check [`Assets/README.md`](Assets/README.md) for asset-specific conventions and extension guidance.
- Consult [`StarterPlayer/StarterPlayerScripts/README.md`](../StarterPlayer/StarterPlayerScripts/README.md) when wiring new client consumers.
- See [`ServerScriptService/README.md`](../ServerScriptService/README.md) for server systems that rely on these shared modules.
- Use the top-level [repository guide](../README.md) for release processes and contact points.
