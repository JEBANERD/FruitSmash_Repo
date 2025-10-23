# Dependencies

Fruit Smash leans on a small set of development tools and Roblox platform services. Use this list to verify your environment before running or deploying the experience.

## Development tooling
- **Rojo CLI 7.4+** – Required for live-sync (`rojo serve`) and building place files; a Windows binary is bundled as `rojo.exe` for convenience.【F:docs/SETUP.md†L7-L24】
- **Git** – Source control for all Luau, asset, and marketing files.
- **Luau-aware editor (VS Code + extensions, IDEA, etc.)** – Recommended for diagnostics but not required.【F:docs/SETUP.md†L7-L14】

## Core Roblox services
- **DataStoreService** – `SaveService` persists player profiles with retries and studio fallbacks; enable API services when testing in Studio.【F:ServerScriptService/Data/SaveService.lua†L1-L40】【F:docs/SETUP.md†L15-L26】
- **ServerStorage** – Arena templates are cloned from `ServerStorage/ArenaTemplates/BaseArena` during bootstrap, so the folder must be available when the server starts.【F:ServerScriptService/GameServer/Init.server.lua†L93-L123】【F:ServerStorage/ArenaTemplates/BaseArena/init.lua†L1-L72】
- **HttpService** – Used for GUID generation and analytics payload preparation in arena management and telemetry modules.【F:ServerScriptService/GameServer/ArenaServer.lua†L1-L38】【F:ServerScriptService/Analytics/TelemetryServer.lua†L1-L40】
- **TeleportService** – Lobby matchmaking relies on reserved servers and teleporting parties into match instances when remote places are configured.【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L1-L20】【F:ServerScriptService/Match/LobbyMatchmaker.server.lua†L825-L856】
- **StatsService & Diagnostics** – Developer tooling such as `PerfHarness.server.lua` reads frame timing and counts workspace instances to surface health warnings.【F:ServerScriptService/Tools/PerfHarness.server.lua†L1-L34】

## Shared modules and configuration
- **Content registry** – `ReplicatedStorage/Shared/Content/ContentRegistry.lua` resolves assets lazily and expects shared content folders to be populated; optional server-only assets can live in `ServerStorage`.【F:ReplicatedStorage/Shared/Content/ContentRegistry.lua†L1-L80】
- **Feature flags** – `Shared/Config/Flags.lua` toggles telemetry, achievements, obstacles, and other subsystems. Modules such as telemetry and achievements read these flags at runtime, so keep the configuration in sync with live expectations.【F:ServerScriptService/Analytics/TelemetryServer.lua†L29-L44】【F:ServerScriptService/GameServer/AchievementServer.lua†L12-L37】
- **Save schema & configs** – Shared defaults in `Shared/Types/SaveSchema.lua` and `Shared/Config/GameConfig.lua` must load before profile and settings services initialize.【F:ServerScriptService/Data/ProfileServer.lua†L1-L68】【F:ReplicatedStorage/Shared/Config/GameConfig.lua†L1-L68】

## Optional integrations
- **Telemetry sinks** – `Analytics/TelemetryServer.lua` exposes a sink registration system; populate sinks when wiring external analytics providers. The module safely no-ops if telemetry is disabled via flags.【F:ServerScriptService/Analytics/TelemetryServer.lua†L1-L88】
- **Guard moderation hooks** – `Moderation/GuardServer.lua` backs remote rate limiting and exploit heuristics. Shop, token, and combat remotes already wrap through it, but you can extend guard thresholds or telemetry event names as needed.【F:ServerScriptService/Tools/AdminCommands.server.lua†L1-L34】【F:ServerScriptService/Moderation/GuardServer.lua†L810-L846】

