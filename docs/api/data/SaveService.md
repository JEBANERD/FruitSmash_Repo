# SaveService

## Overview
SaveService centralizes persistence for player profiles by wrapping Roblox's `DataStoreService` with a studio-friendly in-memory fallback, retry logic, and checkpoint helpers. It keeps a session cache, queues writes to avoid rate limits, and automatically flushes data during `game:BindToClose` on live servers.

## Types
- `SavePayload = { [string]: any }` &mdash; Arbitrary serializable table stored per user. Saved copies are deep-cloned to avoid accidental mutation between callers.
- `CheckpointProvider = (Player?, number, SavePayload?) -> SavePayload?` &mdash; Callback signature for modules that want to contribute additional data before a save checkpoint executes.

## Functions
<a id="saveservice-loadasync"></a>
### `SaveService.LoadAsync(userId: number): (SavePayload?, string?)`
**Purpose & behavior**  
Fetches the latest saved payload for a user. Loads from the session cache when present, falls back to an in-memory studio store, and finally to the live `DataStoreService` entry identified by `player_<userId>` with up to three retries.

**Side effects & external interactions**  
- Populates the per-user session cache on successful loads.  
- Calls `DataStoreService:GetAsync` when running on a live server.

**Usage example**
```lua
local SaveService = require(ServerScriptService.Data.SaveService)

local data, err = SaveService.LoadAsync(player.UserId)
if err then
    warn(("Failed to load save for %s: %s"):format(player.Name, err))
end
```

**Cross-refs**  
- [ProfileServer.LoadSerialized](./ProfileServer.md#profileserver-loadserialized)

<a id="saveservice-saveasync"></a>
### `SaveService.SaveAsync(userId: number, data: SavePayload): (boolean, string?)`
**Purpose & behavior**  
Queues a payload to persist for the user. Save requests are deep-cloned, batched per user, throttled by a cooldown, and retried up to three times via `UpdateAsync`. Concurrent callers wait on the in-flight operation and reuse queued payloads.

**Side effects & external interactions**  
- Writes to the session cache and, on live servers, to the `PlayerProfiles` data store via `UpdateAsync`.  
- Emits warnings when retries fail.  
- Maintains internal per-user save state used by [`SaveService.Flush`](#saveservice-flush).

**Usage example**
```lua
local SaveService = require(ServerScriptService.Data.SaveService)

local payload = {
    Coins = 250,
    Inventory = {
        OwnedMelee = { BananaBlade = true },
    },
}

local ok, err = SaveService.SaveAsync(player.UserId, payload)
if not ok then
    warn(("Could not save profile: %s"):format(err or "unknown"))
end
```

**Cross-refs**  
- [ProfileServer.Serialize](./ProfileServer.md#profileserver-serialize)

<a id="saveservice-updateasync"></a>
### `SaveService.UpdateAsync(userId: number, mutator: (SavePayload?) -> SavePayload?): (SavePayload?, string?)`
**Purpose & behavior**  
Provides transactional updates by cloning the current payload, passing it to `mutator`, and saving the returned table. If the mutator returns `nil`, the previous payload is preserved. The function ensures mutations persist via [`SaveService.SaveAsync`](#saveservice-saveasync).

**Side effects & external interactions**  
- Loads data through [`SaveService.LoadAsync`](#saveservice-loadasync) when no cache exists.  
- Persists the returned payload using `SaveService.SaveAsync`, including DataStore writes on live servers.

**Usage example**
```lua
local SaveService = require(ServerScriptService.Data.SaveService)

local updatedProfile, err = SaveService.UpdateAsync(player.UserId, function(snapshot)
    snapshot = snapshot or {}
    snapshot.Coins = (snapshot.Coins or 0) + 100
    return snapshot
end)
```

**Cross-refs**  
- [ProfileServer.LoadSerialized](./ProfileServer.md#profileserver-loadserialized)
- [ProfileServer.Serialize](./ProfileServer.md#profileserver-serialize)

<a id="saveservice-getcached"></a>
### `SaveService.GetCached(userId: number): SavePayload?`
**Purpose & behavior**  
Returns a deep-cloned copy of the payload currently cached for a user within this server session.

**Side effects & external interactions**  
- None beyond cloning data already in memory.

**Usage example**
```lua
local SaveService = require(ServerScriptService.Data.SaveService)

local cached = SaveService.GetCached(player.UserId)
if cached then
    print(("Cached coins: %d"):format(cached.Coins or 0))
end
```

**Cross-refs**  
- [`SaveService.UpdateAsync`](#saveservice-updateasync)

<a id="saveservice-registercheckpointprovider"></a>
### `SaveService.RegisterCheckpointProvider(provider: CheckpointProvider): () -> ()`
**Purpose & behavior**  
Registers a callback that can supply or amend payload data when [`SaveService.CheckpointAsync`](#saveservice-checkpointasync) builds a save checkpoint. Returns a disconnect function that removes the provider when invoked.

**Side effects & external interactions**  
- Adds the provider to an internal list that is iterated during checkpoint builds.  
- Emits warnings if a provider throws or returns invalid data.

**Usage example**
```lua
local SaveService = require(ServerScriptService.Data.SaveService)

local disconnect = SaveService.RegisterCheckpointProvider(function(player, userId, payload)
    payload = payload or {}
    payload.LastCheckpoint = os.time()
    return payload
end)

-- Later, stop contributing metadata
disconnect()
```

**Cross-refs**  
- [ProfileServer.Serialize](./ProfileServer.md#profileserver-serialize)

<a id="saveservice-checkpointasync"></a>
### `SaveService.CheckpointAsync(subject: any, payload: SavePayload?): (boolean, string?)`
**Purpose & behavior**  
Triggers an immediate save for the player identified by a `Player` instance or user ID. When `payload` is omitted, SaveService gathers data from the cache and registered checkpoint providers before persisting.

**Side effects & external interactions**  
- Resolves players via `Players:GetPlayerByUserId`.  
- Delegates to [`SaveService.SaveAsync`](#saveservice-saveasync) for persistence.

**Usage example**
```lua
local SaveService = require(ServerScriptService.Data.SaveService)

local ok, err = SaveService.CheckpointAsync(player)
if not ok then
    warn(("Checkpoint failed: %s"):format(err or "unknown"))
end
```

**Cross-refs**  
- [ProfileServer.Serialize](./ProfileServer.md#profileserver-serialize)

<a id="saveservice-flush"></a>
### `SaveService.Flush(timeoutSeconds: number?): boolean`
**Purpose & behavior**  
Forces all pending saves to complete, waiting until the queue is empty or an optional timeout elapses. Used when shutting down a server to avoid data loss.

**Side effects & external interactions**  
- Iterates live players via `Players:GetPlayers()` and processes outstanding save states.  
- Called automatically during `game:BindToClose`, ensuring flushes occur on shutdown.  
- Emits warnings if pending saves cannot finish before the timeout.

**Usage example**
```lua
local SaveService = require(ServerScriptService.Data.SaveService)

if not SaveService.Flush(30) then
    warn("Timed out while flushing saves before shutdown")
end
```

**Cross-refs**  
- [`SaveService.SaveAsync`](#saveservice-saveasync)
- [ProfileServer.LoadSerialized](./ProfileServer.md#profileserver-loadserialized)
