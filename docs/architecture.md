# FruitSmash Systems Overview

This document tracks the high-level flows that tie the major gameplay services together.  Each diagram is authored in Mermaid so it can be validated and, when tooling is available, exported as an image for slide decks or wikis.  Run `python tools/mermaid_render.py` from the repository root to lint these diagrams and produce SVG exports in `docs/assets/diagrams/`.

## Match Lifecycle Flow

```mermaid
flowchart TD
    Lobby["Lobby"] --> Prep["Pre-Match Prep"]
    Prep --> InWave["Wave In Progress"]
    InWave -- Victory --> Intermission["Intermission"]
    InWave -- Defeat --> GameOver["Game Over"]
    Intermission --> Prep
    GameOver --> Lobby
```

The flow mirrors the UI router in `StarterPlayer/StarterPlayerScripts/Controllers/UIRouter.client.lua` and the server match coordination scripts under `ServerScriptService/Match/`.

## Matchmaking Sequence

```mermaid
sequenceDiagram
    participant Player
    participant LobbyMatchmaker
    participant MatchServer
    Player->>LobbyMatchmaker: QueueJoinRequest(profileId)
    LobbyMatchmaker->>LobbyMatchmaker: PlaceInQueue
    LobbyMatchmaker-->>Player: QueueStatus(update)
    LobbyMatchmaker->>MatchServer: CreateArena(players)
    MatchServer-->>Player: TeleportToArena(arenaId)
    Player->>MatchServer: ConfirmReady()
```

This diagram outlines the interplay between the lobby matchmaker (`ServerScriptService/Match/LobbyMatchmaker.server.lua`) and the arena host scripts that live under `ServerScriptService/Match/`.

## Profile Persistence Overview

```mermaid
graph LR
    ProfileServer[[ProfileServer]] -->|Load| DataStore[(Roblox DataStore)]
    ProfileServer -->|Save| DataStore
    ProfileServer -->|Replicate| Remotes{{Profile Replication Remotes}}
    Remotes --> PlayerClients[(Player Clients)]
```

`ServerScriptService/Data/ProfileServer.lua` coordinates persistent data round-trips.  Clients read their profile state through the replicated remotes after the server finishes loading from the Roblox DataStore layer.
