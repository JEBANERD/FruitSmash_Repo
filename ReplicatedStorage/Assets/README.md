# ReplicatedStorage/Assets Guide

> Shared asset factories live here. For shared-code context see the [ReplicatedStorage overview](../README.md) and the [project guide](../../README.md).

## Contents
- `Fruit/init.lua` – returns a table of `Model` factories such as `FruitAssets.Apple`, `FruitAssets.Banana`, and `FruitAssets.Pineapple`.
- `VFX/init.lua` – describes particle-driven effects (`FruitPop`, `CoinBurst`, `ShieldBubble`, `CritSparkle`) with metadata used by `VFXBus`.
- Additional asset subfolders (e.g., `SFX`) may hold raw Roblox Instances inserted at runtime via shared systems.
- Each module exposes lightweight constructors; no assets are instantiated until a consumer explicitly calls the factory.
- Asset scripts are pure Luau and avoid Roblox API calls that require workspace ancestry until run time.

## Fruit model conventions
- Factory helper `createFruitModel` builds a `Model` with a named `Part` and optional `SpecialMesh` according to option tables.
- Physics defaults ensure fruits spawn non-collidable (`Anchored = false`, `CanCollide = false`, `Massless = true`).
- Attachments named `RootAttachment`, `ImpactAttachment`, `TrailAttachment`, and `OverheadAttachment` are pre-created to support effects.
- Relative offsets let attachments scale with fruit dimensions; set `Relative = true` and pass normalized vectors.
- When defining new fruit, always provide `Name`, `Color`, and `Size`; optional fields include `MeshType`, `MeshId`, `TextureId`, and custom attachments.

## VFX descriptor conventions
- The VFX table entries specify `Type` (`World` or `UI`), `Lifetime`, emitter counts, and a `Factory` that returns the root Instance.
- World effects call `createBasePart` to generate an invisible, anchored part with attachments for particle emitters.
- Each emitter lists key properties (`Lifetime`, `Speed`, `SpreadAngle`, `Size`, `Transparency`, `Color`) to keep behavior predictable.
- UI effects (e.g., `CritSparkle`) build `ImageLabel` templates and often include `UIGradient` or tween metadata consumed by controllers.
- Emitters are intentionally named (`Burst`, `Coins`, `Shell`, `Sparkle`) so controllers can match them to analytic events.

## Naming patterns
- Modules use `init.lua` to return dictionaries; exported keys are **PascalCase** nouns describing the asset (`FruitAssets.Apple`).
- Attachment names should be **PascalCase** with descriptive suffixes (`Attachment`, `Emitter`).
- Particle emitter names map to analytics and code triggers; keep them `PascalCase` without spaces.
- Use `Enum` properties via typed constants instead of magic numbers (e.g., `Enum.PartType.Ball`).
- Keep asset-local helper functions (`applyPhysicsDefaults`, `resolveRelativeOffset`) private within the module.

## Adding a new fruit asset
1. Duplicate an existing entry in `Fruit/init.lua` and update the option fields.
2. Adjust `Size` and `MeshScale` to match intended visuals; prefer relative attachments for effect alignment.
3. If the fruit requires bespoke attachments, append to `DefaultAttachments` or `Attachments` with `Name`, `Offset`, and `Relative` fields.
4. Run Studio, require the module, and `FruitAssets.<Name>:Clone()` inside a test folder to verify collisions, mass, and attachments.
5. Update the relevant gameplay scripts (e.g., spawners) and add coverage in analytics dashboards if the fruit has unique scoring rules.

## Adding a new VFX asset
1. Register a new dictionary entry inside `VFX/init.lua` with a unique key.
2. Inside the `Factory`, create a base part or GUI object and configure emitters; respect existing property patterns.
3. Set `Lifetime`, `Emitters`, and other metadata so `VFXBus` can plan cleanup and pooling.
4. If the effect supports color theming, expose tweakable properties or accept parameters in the consumer system rather than hard-coding variations.
5. Document the emitter names and expected triggers in the consuming controller or server script.

## Integration touchpoints
- `Shared/Systems/VFXBus.lua` consumes this module to spawn and recycle effects; keep metadata consistent with its expectations.
- `Shared/Systems/AudioBus.lua` may play complementary SFX; ensure effect names align when pairing audio with particles.
- Server-side spawners (`GameServer/FruitSpawnerServer.lua`) clone fruit models when generating match waves.
- Client controllers (`StarterPlayerScripts/Controllers/HUDController`) trigger UI VFX such as `CritSparkle` for player feedback.
- Analytics events reference asset names; keep keys stable or add migration code in analytics pipelines.

## Maintenance checklist
- [ ] Periodically verify that all fruit models include required attachments and have non-zero sizes.
- [ ] Confirm that VFX factories do not leave loose Instances; they should rely on controllers to destroy them after `Lifetime` elapses.
- [ ] Ensure asset colors and materials match brand guidelines set by the art team.
- [ ] Audit particle counts and lifetimes to stay within Roblox budget for devices with lower GPU capability.
- [ ] Keep this README updated when new asset categories or helper modules appear.

## Additional references
- For shared usage patterns see [`../README.md`](../README.md).
- For system-level orchestration consult [`../Shared/Systems/README.md`](../Shared/Systems/README.md).
- Gameplay consumers are documented in [`../../ServerScriptService/README.md`](../../ServerScriptService/README.md).
- UI consumers and triggers live in [`../../StarterPlayer/StarterPlayerScripts/Controllers/README.md`](../../StarterPlayer/StarterPlayerScripts/Controllers/README.md).
- Top-level repository processes remain in the [project guide](../../README.md).
