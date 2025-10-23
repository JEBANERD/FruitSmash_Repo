# ReplicatedStorage/Shared Manual

> Shared configuration, content tables, localization, and utility systems live here. Review the parent [ReplicatedStorage README](../README.md) and the [project guide](../../README.md) for broader context.

## Folder layout
- **Assets/** – Placeholder for shared Instances such as sound folders consumed by `Shared/Systems/AudioBus.lua`.
- **Config/** – Build metadata (`BuildInfo.lua`), live flags (`Flags.lua`), and gameplay balancing tables (`GameConfig.lua`, `ShopConfig.lua`, `FruitConfig.lua`).
- **Content/** – `ContentRegistry.lua` enumerates unlockables, quest chains, and drop tables shared across clients and servers.
- **Locale/** – `Strings.lua` houses translation dictionaries used by the `Localizer` helper to present localized text.
- **Systems/** – Cross-cutting modules like `AudioBus`, `Localizer`, `RNG`, `VFXBus`, and `WeightedTable`.
- **Types/** – Luau type definitions (`SaveSchema.lua`, `NetTypes.lua`) imported wherever structural contracts are enforced.

## Config conventions
- Config modules expose a `Get()` method returning a frozen table; mutate clones to avoid touching shared state.
- `Flags.lua` stores feature toggles and build metadata under `Metadata`; update `Version`, `Commit`, and `GeneratedAt` for each release.
- Balance-related files (`FruitConfig`, `GameConfig`, `ShopConfig`) should keep deterministic keys so both server and client can reference them reliably.
- Use Luau annotations to describe nested structures; they provide intellisense and reduce runtime casting.
- Keep comments inline when introducing temporary flags; document planned removal dates to avoid stale toggles.

## Localization flow
- `Localizer.lua` reads `Locale/Strings.lua` and exposes helpers like `getLocaleTable`, `getLocalPlayerLocale`, and formatted string retrieval.
- Controllers listen for locale attribute changes on the player to refresh UI text; ensure new strings follow the `namespace.key` pattern.
- Provide fallbacks (usually English) for every key; missing translations should return the default string instead of nil.
- When adding new strings, update translation spreadsheets and note them in release notes so localization vendors can deliver updates.
- Avoid embedding formatting placeholders not supported by all locales; prefer descriptive tokens like `{playerName}`.

## System modules
- `AudioBus.lua` pre-warms pooled `Sound` instances, reads definitions from `Shared/Assets/SFX`, and plays events by keyword.
- `VFXBus.lua` will instantiate templates from `ReplicatedStorage/Assets/VFX` and manage emitter lifetimes.
- `RNG.lua` centralizes seeded random utilities to keep drop tables consistent across server and client predictions.
- `WeightedTable.lua` offers helper functions for weighted random selection; require it wherever loot tables are used.
- `Localizer.lua` and other systems avoid side effects during module load, making them safe to require from both server and client contexts.

## Type definitions
- `NetTypes.lua` captures RemoteEvent payload shapes; update it when new remotes or payload fields are introduced.
- `SaveSchema.lua` enumerates player data structure versions; keep it in sync with `ServerScriptService/Data/SaveService.lua`.
- Prefer exporting types via `export type` and referencing them directly (`type ProfileData = Types.ProfileData`).
- When adding new types, annotate both server and client modules to catch mismatches early.
- Document migrations inside the type file when fields are renamed or replaced.

## Adding new shared content
1. Decide which subfolder best fits (Config, Content, Systems, Types, Locale, Assets).
2. Follow naming conventions: PascalCase for modules, uppercase snake case for constant table keys if needed.
3. Add Luau type annotations and doc comments summarizing purpose and sample usage.
4. Update this README and any relevant consumer documentation (e.g., server or controller README) to advertise the new resource.
5. Run `rojo serve` and validate that Studio sees the new module under `ReplicatedStorage.Shared`.

## When editing existing modules
- Keep helper functions pure; avoid storing state unless the module explicitly manages caches or pools.
- Use `table.freeze` for config tables that should not change at runtime.
- When adjusting drop tables, update analytics dashboards or tests that assert reward probabilities.
- Coordinate localization changes with UI engineers; string keys might drive layout decisions.
- Validate `AudioBus` and `VFXBus` definitions in Studio to ensure assets still exist and IDs are valid.

## Maintenance checklist
- [ ] Review config defaults every season and compare against live telemetry to confirm they match product decisions.
- [ ] Audit localization keys after large feature drops to ensure translations exist for all languages we support.
- [ ] Ensure type files reflect the latest schema before merging data migrations.
- [ ] Verify pooled systems (audio, VFX) purge unused instances to avoid memory leaks.
- [ ] Keep this README aligned with the actual folder tree when subdirectories are added or removed.

## Additional resources
- System-focused details live in [`Systems/README.md`](Systems/README.md).
- Data persistence behavior is covered in [`../../ServerScriptService/Data/README.md`](../../ServerScriptService/Data/README.md) once that folder adds documentation.
- Client integration notes appear in [`../../StarterPlayer/StarterPlayerScripts/README.md`](../../StarterPlayer/StarterPlayerScripts/README.md).
- For asset definitions see [`../Assets/README.md`](../Assets/README.md).
- Repository-wide policies remain in the [top-level README](../../README.md).
