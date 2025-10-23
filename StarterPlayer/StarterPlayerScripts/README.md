# StarterPlayerScripts Field Manual

> Client controllers and utilities spawn with every player. Review the [project guide](../../README.md) and [ServerScriptService handbook](../../ServerScriptService/README.md) for context.

## Folder layout
- `AdminPanel.client.lua` – In-game admin tools for monitoring queues, economy, and debugging remote flows.
- **Controllers/** – Main client state machines for UI, combat input, audio, accessibility, and onboarding.
- **Tools/** – Optional client utilities such as `PerfHUD.client.lua` for real-time performance stats.
- Additional client modules may live alongside controllers when they need to be required by multiple scripts.
- Keep purely visual assets in `StarterGui`; use this folder for behavior and orchestration.

## Controller highlights
- `UIRouter.client.lua` – Manages screen transitions and ensures UI modules mount/unmount cleanly.
- `HUDController.client.lua` – Drives combat UI, coin updates, combo displays, and integrates VFX overlays.
- `SettingsUI.client.lua` – Surfaces accessibility toggles, binds to `RE_SettingsPushed`, and persists settings via remotes.
- `QueueUI.client.lua` – Interfaces with matchmaking remotes to display queue status and party information.
- `PlayerController.client.lua` – Core input handler for movement, camera smoothing, and ability triggers.
- `MeleeController.client.lua` – Handles melee hit detection client-side, coordinating with `RE_MeleeHitAttempt` remote.
- `TutorialUI.client.lua` – Guides new players through multi-step onboarding with localized prompts.
- `AchievementToast.client.lua` – Displays achievement notifications triggered via `RE_AchievementToast`.
- `LeaderboardUI.client.lua` – Shows session stats and global leaderboard data from `RE_SessionLeaderboard`.
- `CameraFeel.client.lua` / `CameraFeelBus.lua` – Provide camera shake, bob, and sensitivity adjustments.
- `AudioController.client.lua` – Routes gameplay events to `AudioBus` for sound playback.
- `RoundSummary.client.lua` – Presents post-match summaries and integrates with `MatchReturnServer` payloads.

## Naming conventions
- Client scripts end with `.client.lua` and are executed automatically when players spawn.
- Shared helper modules use `.lua` and return tables; require them in whichever controller needs the functionality.
- Use PascalCase filenames and maintain `--!strict` directives for Luau type safety.
- Controllers expose `Start` or `Init` entry points; document expected arguments within the module.
- Keep module-level state encapsulated; avoid polluting `_G` or global tables.

## Adding a new controller
1. Create a `.client.lua` ModuleScript inside `Controllers/` with a descriptive PascalCase name.
2. Require shared dependencies from `ReplicatedStorage.Shared` and remote references via `ReplicatedStorage.Remotes.RemoteBootstrap`.
3. Expose lifecycle methods (`start`, `stop`, etc.) and ensure they can be called multiple times without leaking connections.
4. Register the controller with existing routers if needed (e.g., have `UIRouter` require and initialize it).
5. Update this README with a bullet summarizing the controller's responsibilities and key remotes.

## Working with remotes
- Import `Remotes` from `ReplicatedStorage.Remotes.RemoteBootstrap` to guarantee consistent references.
- Use Luau type annotations to document remote payloads; align with definitions in `Shared/Types/NetTypes.lua`.
- Debounce UI triggers to prevent spamming remote calls; lean on server-side rate limits for critical paths.
- Listen for server pushes (`RE_QuickbarUpdate`, `RE_TargetHP`, etc.) and update local state in a frame-safe manner.
- When adding new remotes, update both this README and the relevant server documentation.

## UI coordination
- Controllers typically manipulate UI templates stored in `StarterGui`; require them via `Players.LocalPlayer:WaitForChild("PlayerGui")`.
- Keep UI-specific logic in dedicated controllers to avoid bloated monoliths.
- Use `Localizer` to fetch strings before rendering; do not hard-code text.
- When introducing new screens, pair them with a controller that handles open/close transitions and analytics logging.
- Coordinate with `UIRouter` to ensure screens respect the global layering and input lock rules.

## Debugging & profiling
- `AdminPanel` provides toggles for simulating remotes, granting currency, and reading queue states.
- `PerfHUD.client.lua` overlays FPS, ping, and memory metrics; useful when testing heavy VFX scenes.
- Use Roblox MicroProfiler for deeper dives; keep instrumentation out of production builds once issues are resolved.
- Log warnings sparingly; use `warn` for actionable issues and `print` for temporary debugging.
- Clean up `RBXScriptConnection`s when controllers stop to prevent memory leaks.

## Maintenance checklist
- [ ] Review controllers for stale remotes each release cycle; remove listeners for deprecated events.
- [ ] Confirm accessibility toggles persist correctly after settings schema changes.
- [ ] Ensure localization keys referenced in controllers exist in `Shared/Locale/Strings.lua`.
- [ ] Validate that tutorial steps align with the current gameplay flow.
- [ ] Keep this README synchronized with actual controller files and their responsibilities.

## Additional documentation
- Controller-specific deep dives exist in [`Controllers/README.md`](Controllers/README.md).
- UI layout details live in [`../../StarterGui/README.md`](../../StarterGui/README.md).
- Server logic references appear in [`../../ServerScriptService/README.md`](../../ServerScriptService/README.md).
- Shared system usage is documented in [`../../ReplicatedStorage/Shared/Systems/README.md`](../../ReplicatedStorage/Shared/Systems/README.md).
- Repository-wide policies remain in the [project guide](../../README.md).
