# LeaderboardServer

## Overview
LeaderboardServer manages both a live session leaderboard sourced from player `Points` attributes and an optional global standings table backed by an `OrderedDataStore`. It pushes updates to clients through configured remotes and keeps local caches in sync with Roblox user metadata.

## Remotes
- `Remotes.RE_SessionLeaderboard` (`RemoteEvent`) &mdash; Fired to each client whenever the session leaderboard is recomputed. Payload includes `top`, `entries`, `totalPlayers`, `yourRank`, `yourScore`, and `updated` timestamp.  
- `Remotes.RF_GetGlobalLeaderboard` (`RemoteFunction`) &mdash; Invoked by clients to fetch global standings; returns datastore-backed results or session fallbacks.

## Functions
<a id="leaderboardserver-submitscore"></a>
### `LeaderboardServer.SubmitScore(player: Player, points: any): number?`
**Purpose & behavior**  
Normalizes the submitted score, caches it per user, recalculates session ordering, broadcasts leaderboard snapshots, and queues global datastore submissions when the new score exceeds the cached best.

**Side effects & external interactions**  
- Updates internal session caches (`sessionScores`, `sessionOrder`, `sessionRanks`).  
- Fires `Remotes.RE_SessionLeaderboard:FireClient` to all players with refreshed data.  
- Schedules writes to the `GlobalPointsLeaderboard` `OrderedDataStore` (when available).  
- Caches Roblox username and display name metadata for leaderboard display.

**Usage example**
```lua
local LeaderboardServer = require(ServerScriptService.Data.LeaderboardServer)

local rank = LeaderboardServer.SubmitScore(player, player:GetAttribute("Points"))
print(("Player rank is now %d"):format(rank or -1))
```

**Cross-refs**  
- [LeaderboardServer.GetSessionRank](#leaderboardserver-getsessionrank)
- [LeaderboardServer.FetchGlobalTop](#leaderboardserver-fetchglobaltop)

<a id="leaderboardserver-fetchglobaltop"></a>
### `LeaderboardServer.FetchGlobalTop(count: number?): { [string]: any }`
**Purpose & behavior**  
Retrieves the top global scores up to `count` entries. Prefers the live datastore when accessible, retrying failures, and falls back to cached session data when necessary.

**Side effects & external interactions**  
- Calls `OrderedDataStore:GetSortedAsync` on `GlobalPointsLeaderboard` with retry logic.  
- On failure, logs warnings and returns a fallback payload with an `error` field.  
- Populates caches for usernames and display names via Roblox web APIs when not already known.

**Usage example**
```lua
local LeaderboardServer = require(ServerScriptService.Data.LeaderboardServer)

local global = LeaderboardServer.FetchGlobalTop(25)
print(global.source, #global.entries)
```

**Cross-refs**  
- [LeaderboardServer.SubmitScore](#leaderboardserver-submitscore)

<a id="leaderboardserver-getsessiontop"></a>
### `LeaderboardServer.GetSessionTop(): { { [string]: any } }`
**Purpose & behavior**  
Returns a deep-cloned snapshot of the current session leaderboard entries limited to the configured maximum.

**Side effects & external interactions**  
- None; operates on cached leaderboard data.

**Usage example**
```lua
local LeaderboardServer = require(ServerScriptService.Data.LeaderboardServer)

for _, entry in ipairs(LeaderboardServer.GetSessionTop()) do
    print(entry.rank, entry.displayName, entry.score)
end
```

**Cross-refs**  
- [LeaderboardServer.SubmitScore](#leaderboardserver-submitscore)

<a id="leaderboardserver-getsessionrank"></a>
### `LeaderboardServer.GetSessionRank(player: Player): number?`
**Purpose & behavior**  
Looks up the cached rank for a player within the session leaderboard, if they have submitted a score.

**Side effects & external interactions**  
- None beyond reading the `sessionRanks` table.

**Usage example**
```lua
local LeaderboardServer = require(ServerScriptService.Data.LeaderboardServer)

local rank = LeaderboardServer.GetSessionRank(player)
if rank then
    print(("Current session rank: %d"):format(rank))
end
```

**Cross-refs**  
- [LeaderboardServer.GetSessionTop](#leaderboardserver-getsessiontop)
- [LeaderboardServer.SubmitScore](#leaderboardserver-submitscore)
