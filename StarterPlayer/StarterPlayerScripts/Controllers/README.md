# StarterPlayerScripts/Controllers Guide

> Controllers coordinate client state machines and UI flows. Start with the [StarterPlayerScripts field manual](../README.md) and the [project guide](../../../README.md).

## Controller roster
- **AchievementToast.client.lua** – Listens for `RE_AchievementToast` and displays localized toasts with iconography.
- **AudioController.client.lua** – Bridges gameplay signals to `AudioBus`, managing 3D and UI sound playback.
- **CameraFeel.client.lua** – Applies camera sway, shake, and smoothing based on player state.
- **CameraFeelBus.lua** – Shared helper exposing effect registration (`CameraFeelBus.register`, `CameraFeelBus.play`).
- **ControllerSupport.client.lua** – Handles gamepad bindings, prompts, and input glyph swaps.
- **HUDController.client.lua** – Central HUD orchestrator: health, combo meters, quickbar, buffs, and VFX overlays.
- **LeaderboardUI.client.lua** – Displays session leaderboard and handles `RE_SessionLeaderboard` updates.
- **MeleeController.client.lua** – Client prediction for melee swings, using `RE_MeleeHitAttempt` to inform the server.
- **PlayerController.client.lua** – Movement, ability input, cursor locking, and coordination with `CameraFeel`.
- **QueueUI.client.lua** – Party management UI tied to `RF_JoinQueue`, `RF_LeaveQueue`, and `PartyUpdate` events.
- **QuickbarController.client.lua** – Manages quickbar slots, cooldown display, and ability assignment.
- **RoundSummary.client.lua** – Presents post-match stats using payloads from `MatchReturnServer`.
- **SettingsUI.client.lua** – Accessibility, audio, and gameplay settings; persists via `RF_SaveSettings` and `RE_SettingsPushed`.
- **TutorialUI.client.lua** – Walks new players through steps, hooking into `RF_Tutorial` when saving progress.
- **UIRouter.client.lua** – Central dispatcher for showing/hiding screens; other controllers register with it for transitions.

## Patterns & conventions
- Each controller exports a module table with `Start`/`Stop` or similar lifecycle functions; keep them idempotent.
- Use `--!strict` and annotate exported functions with Luau types for clarity.
- Keep remote references localized; require `ReplicatedStorage.Remotes.RemoteBootstrap` and destructure needed remotes.
- Access shared systems (e.g., `Localizer`, `VFXBus`, `AudioBus`) through `ReplicatedStorage.Shared.Systems`.
- Avoid cross-controller coupling; communicate via signals or routers rather than directly requiring siblings unless necessary.

## UI integration
- Controllers typically expect templates in `StarterGui`; fetch them lazily to avoid race conditions on player spawn.
- Use `UIRouter` as the single source of truth for screen state transitions to prevent overlapping modals.
- Respect layering conventions: HUD overlays, modal dialogs, and world-space screens each have dedicated containers.
- Apply `Localizer` lookups when setting text and re-run on locale change signals.
- Keep animation logic in controllers; UI templates should remain mostly declarative.

## Input handling
- Use `ContextActionService` bindings within controllers to manage input scopes cleanly.
- Debounce repeated actions (e.g., queue toggles, ability triggers) to avoid remote spam.
- Provide fallback keyboard/mouse bindings when controller support is unavailable.
- When adjusting bindings, update onboarding tooltips and tutorial prompts to stay consistent.
- Log input-related warnings sparingly; rely on analytics events for aggregated insight.

## Adding or updating a controller
1. Copy the structure of a similar controller and adjust the lifecycle methods.
2. Register new UI screens with `UIRouter` to integrate with the global state machine.
3. Document remotes, shared modules, and UI dependencies in the controller's header comments.
4. Update this README roster with a brief summary of responsibilities.
5. Verify cleanup paths (`RBXScriptConnection:Disconnect()`, `RunService` events) to prevent leaks on respawn.

## Testing tips
- Simulate network latency using Roblox Studio settings to confirm controllers handle delayed remote responses.
- Toggle accessibility features (e.g., colorblind modes) to ensure UI adapts correctly.
- Run through tutorial flows after major updates to verify gating logic and message sequencing.
- Leverage `AdminPanel` to fire test remotes like `RE_Notice` and inspect resulting UI states.
- Monitor `Output` for warnings; controllers should `warn` only on actionable issues.

## Maintenance checklist
- [ ] Ensure remote names used here exist in `ReplicatedStorage.Remotes.RemoteBootstrap` after every release.
- [ ] Keep controller dependencies documented; prune unused requires to reduce load times.
- [ ] Verify that camera and input controllers respect platform-specific constraints.
- [ ] Audit quickbar and HUD controllers when adding new abilities or stats.
- [ ] Update localization keys referenced in controllers when strings change.

## Related docs
- [StarterPlayerScripts manual](../README.md) – Overview of client folder responsibilities.
- [StarterGui README](../../../StarterGui/README.md) – Details on UI templates these controllers manipulate.
- [ReplicatedStorage systems](../../../ReplicatedStorage/Shared/Systems/README.md) – Shared buses used for audio, VFX, and localization.
- [ServerScriptService Match README](../../../ServerScriptService/Match/README.md) – Server events that drive many controller updates.
- [Top-level guide](../../../README.md) – Release workflow and contact points.
