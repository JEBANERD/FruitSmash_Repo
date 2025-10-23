# ReplicatedStorage/Shared/Systems Field Guide

> Systems are reusable modules invoked by both server and client. Start with the [Shared manual](../README.md) and the [project guide](../../../README.md) for context.

## Modules at a glance
- **AudioBus.lua** – Centralized sound playback with pooled emitters and pre-warmed `Sound` instances sourced from `Shared/Assets/SFX`.
- **Localizer.lua** – Locale-aware string lookup for UI and gameplay messaging, reading translations from `Shared/Locale/Strings.lua`.
- **RNG.lua** – Deterministic random utilities that support seeded sequences, useful for synchronized drop tables.
- **VFXBus.lua** – Runtime manager that spawns particle or UI effects defined in `ReplicatedStorage/Assets/VFX` and coordinates cleanup.
- **WeightedTable.lua** – Helper for weighted random selection, enabling data-driven loot and reward tables.

## Design principles
- Modules must be safe to require on both server and client; avoid referencing services not available in both contexts during module load.
- Initialization should be idempotent; repeated `require` calls should not spawn duplicate folders or connections.
- Keep public APIs small: prefer exposing a single table with methods like `play`, `spawn`, or `choose`.
- Use explicit Luau types for public method signatures to catch incorrect payloads before runtime.
- Cache references (e.g., folders, assets) the first time they are needed to reduce workspace lookups.

## AudioBus usage
- Call `AudioBus.play("swing", position?)` to play sounds by keyword; the bus handles emitter pooling and fallback to SoundService.
- Sound definitions live inside the module (`SOUND_DEFINITIONS`); keep metadata (Volume, PlaybackSpeed, RollOff distances) accurate.
- Prewarm counts ensure frequently used sounds have ready emitters; adjust `PREWARM_COUNTS` if patterns change.
- When adding new sounds, create entries in `Shared/Assets/SFX` if the asset is stored in the tree, or embed the `SoundId` directly.
- Clean up emitters in consumers if they persist beyond their intended lifetime.

## Localizer usage
- Use `Localizer.format(key, contextTable?)` to fetch localized strings with token substitution.
- Players expose a `Locale` attribute that controllers update; `Localizer.getLocalPlayerLocale()` inspects it.
- When adding languages, extend `Locale/Strings.lua` with new locale tables keyed by ISO codes (e.g., `"en"`, `"fr"`).
- Provide fallback keys (`DEFAULT_LOCALE`) to avoid missing-text bugs in Studio or early builds.
- Avoid heavy computations in formatting functions; keep locale lookups lean.

## RNG and WeightedTable
- `RNG.lua` returns a table with deterministic helpers like `nextNumber(seed, min, max)`; use it for reproducible sequences.
- `WeightedTable.lua` exposes constructors and `roll` functions to select entries based on weight; ensure weights sum to more than zero.
- Keep RNG seeds consistent between server and client when mirroring behavior (e.g., predicted loot spawns).
- Document weight changes in balancing notes so designers can audit probability shifts.
- Combine `WeightedTable` with `RNG` to create deterministic yet replayable content sequences.

## VFXBus lifecycle
- Call `VFXBus.spawn("FruitPop", params)` to create an effect; the bus reads metadata (`Type`, `Lifetime`, `Emitters`) from the assets module.
- World effects expect a `CFrame` or parent, while UI effects anticipate a GUI instance; follow the module's API docs for arguments.
- The bus should handle cleanup after `Lifetime`; ensure new effects specify realistic durations to avoid lingering Instances.
- Pair VFX with matching audio by using consistent keys between `VFXBus` and `AudioBus`.
- Consider device performance: keep particle counts within Roblox's recommended budgets to maintain frame rates.

## Adding a new system module
1. Create a PascalCase ModuleScript in this folder and return a table of well-documented methods.
2. Require only the services needed; wrap server-only dependencies behind `RunService:IsServer()` checks if necessary.
3. Define Luau types for payloads and responses; export them when other modules need to reference the structure.
4. Update this README under the relevant sections and add usage notes in consumer documentation.
5. Add unit or integration tests where feasible, ideally via a small harness in `StarterPlayerScripts/Tools` or server smoke tests.

## Maintenance checklist
- [ ] Audit bus modules quarterly to ensure asset references and remote listeners are still valid.
- [ ] Confirm localization lookups cover every key referenced by UI controllers after feature launches.
- [ ] Keep RNG helpers deterministic by avoiding time-based seeds unless explicitly passed in.
- [ ] Monitor memory usage in pooled systems and adjust prewarm counts or cleanup timers as needed.
- [ ] Document any public API changes in both this README and module doc comments.

## Related documentation
- [Shared manual](../README.md) – high-level overview of the Shared folder.
- [Assets guide](../../Assets/README.md) – details on VFX templates and sound assets consumed here.
- [ServerScriptService README](../../../ServerScriptService/README.md) – references to systems used during gameplay.
- [StarterPlayerScripts README](../../../StarterPlayer/StarterPlayerScripts/README.md) – client controllers that call these systems.
- [Top-level guide](../../../README.md) – release workflows and process notes.
