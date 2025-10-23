# ProfileServer

## Overview
ProfileServer maintains session-scoped player profiles that track coins, statistics, melee inventory, consumable tokens, and player settings. The module eagerly loads data for players joining the server, refreshes the in-game quickbar when profile data changes, keeps tutorial completion attributes in sync, and coordinates with SaveService for persistence checkpoints.

## Constants
- `ProfileServer.SchemaVersion` &mdash; The current schema version (`1`) applied when serializing and migrating save data.

## Functions
<a id="profileserver-get"></a>
### `ProfileServer.Get(player: Player): Profile`
**Purpose & behavior**  
Ensures a `Profile` object exists for the specified player, creating a default profile when first accessed. Reconnects attribute tracking if needed.

**Side effects & external interactions**  
- Creates and caches a profile entry in module state.  
- Synchronizes the player's `TutorialCompleted` attribute.  
- Attaches listeners that mirror economy updates into profile stats.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local profile = ProfileServer.Get(player)
print(profile.Data.Coins)
```

**Cross-refs**  
- [ProfileServer.GetData](#profileserver-getdata)
- [SaveService.LoadAsync](./SaveService.md#saveservice-loadasync)

<a id="profileserver-getdata"></a>
### `ProfileServer.GetData(player: Player): ProfileData`
**Purpose & behavior**  
Returns the mutable `ProfileData` table belonging to a player's profile.

**Side effects & external interactions**  
- Invokes [`ProfileServer.Get`](#profileserver-get) which may initialize the profile.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local data = ProfileServer.GetData(player)
print(("Stats table has %d entries"):format(#data.Stats))
```

**Cross-refs**  
- [ProfileServer.Get](#profileserver-get)

<a id="profileserver-getinventory"></a>
### `ProfileServer.GetInventory(player: Player): Inventory`
**Purpose & behavior**  
Returns the player's inventory table, ensuring token counts, melee loadouts, utility queue, and ownership maps exist.

**Side effects & external interactions**  
- Calls [`ProfileServer.Get`](#profileserver-get) and normalizes the inventory structure.  
- May refresh the quickbar when missing inventory tables are instantiated.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local inventory = ProfileServer.GetInventory(player)
print(table.concat(inventory.MeleeLoadout, ", "))
```

**Cross-refs**  
- [ProfileServer.GetProfileAndInventory](#profileserver-getprofileandinventory)

<a id="profileserver-getprofileandinventory"></a>
### `ProfileServer.GetProfileAndInventory(player: Player): (Profile, ProfileData, Inventory)`
**Purpose & behavior**  
Provides a convenience triple with the profile object, its data table, and the normalized inventory for the player.

**Side effects & external interactions**  
- Calls [`ProfileServer.Get`](#profileserver-get) and [`ProfileServer.GetInventory`](#profileserver-getinventory).  
- Refreshes the quickbar to reflect inventory changes.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local profile, data, inventory = ProfileServer.GetProfileAndInventory(player)
print(profile.Player == player, inventory.ActiveMelee)
```

**Cross-refs**  
- [ProfileServer.GrantItem](#profileserver-grantitem)
- [ProfileServer.AddCoins](#profileserver-addcoins)

<a id="profileserver-addcoins"></a>
### `ProfileServer.AddCoins(player: Player, amount: number?): number`
**Purpose & behavior**  
Adds a positive integer amount of coins to the player's profile and returns the new balance. Non-positive or invalid amounts are ignored.

**Side effects & external interactions**  
- Mutates `profile.Data.Coins`.  
- Invokes the quickbar refresh helper to keep UI state current.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local newBalance = ProfileServer.AddCoins(player, 150)
print(("Player now has %d coins"):format(newBalance))
```

**Cross-refs**  
- [ProfileServer.SpendCoins](#profileserver-spendcoins)
- [SaveService.UpdateAsync](./SaveService.md#saveservice-updateasync)

<a id="profileserver-spendcoins"></a>
### `ProfileServer.SpendCoins(player: Player, amount: number?): (boolean, string?)`
**Purpose & behavior**  
Attempts to subtract a cost from the player's coins. Rejects invalid amounts and insufficient balances, returning `false` with an error code.

**Side effects & external interactions**  
- Decrements `profile.Data.Coins` on success.  
- Refreshes the quickbar to reflect the new coin count.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local ok, err = ProfileServer.SpendCoins(player, 75)
if not ok then
    warn(("Purchase failed: %s"):format(err))
end
```

**Cross-refs**  
- [ProfileServer.AddCoins](#profileserver-addcoins)

<a id="profileserver-grantitem"></a>
### `ProfileServer.GrantItem(player: Player, itemId: string): (boolean, string?)`
**Purpose & behavior**  
Grants a shop item to the player's profile. Supports melee weapons, stackable tokens, and utility queue items. Prevents duplicates or stack-limit violations and reports issues via error codes.

**Side effects & external interactions**  
- Updates inventory tables (owned melee, loadout, token counts, or utility queue).  
- Refreshes the quickbar so the new item appears in UI.  
- Validates items against the shop configuration snapshot.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local ok, err = ProfileServer.GrantItem(player, "BananaBlade")
if not ok then
    warn(("Grant failed: %s"):format(err))
end
```

**Cross-refs**  
- [ProfileServer.ConsumeToken](#profileserver-consumetoken)
- [ProfileServer.GetInventory](#profileserver-getinventory)

<a id="profileserver-consumetoken"></a>
### `ProfileServer.ConsumeToken(player: Player, itemId: string): (boolean, string?)`
**Purpose & behavior**  
Consumes one instance of a token from the player's inventory if available.

**Side effects & external interactions**  
- Decrements the relevant token count or removes the entry when it reaches zero.  
- Refreshes the quickbar to reflect the new token count.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local ok, err = ProfileServer.ConsumeToken(player, "DoubleXP")
if not ok then
    warn(("Token use failed: %s"):format(err))
end
```

**Cross-refs**  
- [ProfileServer.GrantItem](#profileserver-grantitem)

<a id="profileserver-serialize"></a>
### `ProfileServer.Serialize(player: Player): ProfileData`
**Purpose & behavior**  
Builds a sanitized snapshot of the player's profile suitable for saving. Defaults to schema defaults if no profile exists.

**Side effects & external interactions**  
- None; produces a deep-copied snapshot.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)
local SaveService = require(ServerScriptService.Data.SaveService)

local serialized = ProfileServer.Serialize(player)
SaveService.SaveAsync(player.UserId, { Profile = serialized })
```

**Cross-refs**  
- [SaveService.SaveAsync](./SaveService.md#saveservice-saveasync)
- [ProfileServer.LoadSerialized](#profileserver-loadserialized)

<a id="profileserver-loadserialized"></a>
### `ProfileServer.LoadSerialized(player: Player, serialized: ProfileData?)`
**Purpose & behavior**  
Replaces the player's in-memory profile with sanitized data loaded from storage. Applies schema migrations, normalizes inventory, refreshes the quickbar, and re-syncs tutorial attributes.

**Side effects & external interactions**  
- Mutates the cached profile data.  
- Calls the quickbar refresh helper.  
- Updates the player's `TutorialCompleted` attribute.  
- Invoked automatically after `SaveService.LoadAsync` completes for a player.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local payload = ProfileServer.Serialize(player)
ProfileServer.LoadSerialized(player, payload)
```

**Cross-refs**  
- [SaveService.LoadAsync](./SaveService.md#saveservice-loadasync)
- [SaveService.UpdateAsync](./SaveService.md#saveservice-updateasync)

<a id="profileserver-getbyuserid"></a>
### `ProfileServer.GetByUserId(userId: number): Profile?`
**Purpose & behavior**  
Looks up the cached profile for a user ID when the `Player` instance is unavailable (e.g. during checkpoints).

**Side effects & external interactions**  
- None; returns a reference to the in-memory profile if present.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local profile = ProfileServer.GetByUserId(player.UserId)
if profile then
    print(profile.Data.Settings.Locale)
end
```

**Cross-refs**  
- [SaveService.CheckpointAsync](./SaveService.md#saveservice-checkpointasync)

<a id="profileserver-reset"></a>
### `ProfileServer.Reset(player: Player)`
**Purpose & behavior**  
Restores the player's profile to default values, reattaching attribute tracking and refreshing the quickbar.

**Side effects & external interactions**  
- Overwrites cached profile data.  
- Calls quickbar refresh logic.  
- Synchronizes the tutorial completion attribute.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

ProfileServer.Reset(player)
```

**Cross-refs**  
- [ProfileServer.LoadSerialized](#profileserver-loadserialized)

<a id="profileserver-gettutorialcompleted"></a>
### `ProfileServer.GetTutorialCompleted(player: Player): boolean`
**Purpose & behavior**  
Returns whether the player has completed the tutorial by inspecting the profile stats and ensuring the attribute is up to date.

**Side effects & external interactions**  
- Synchronizes the `TutorialCompleted` attribute on the player instance.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

if ProfileServer.GetTutorialCompleted(player) then
    print("Tutorial already complete")
end
```

**Cross-refs**  
- [ProfileServer.SetTutorialCompleted](#profileserver-settutorialcompleted)

<a id="profileserver-settutorialcompleted"></a>
### `ProfileServer.SetTutorialCompleted(player: Player, completed: boolean?): boolean`
**Purpose & behavior**  
Marks the player's profile stats with tutorial completion state and updates the mirrored player attribute.

**Side effects & external interactions**  
- Mutates `profile.Data.Stats`.  
- Calls `Player:SetAttribute` for `TutorialCompleted`.

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

ProfileServer.SetTutorialCompleted(player, true)
```

**Cross-refs**  
- [ProfileServer.GetTutorialCompleted](#profileserver-gettutorialcompleted)

<a id="profileserver-registermigration"></a>
### `ProfileServer.RegisterMigration(fromVersion: number, handler: MigrationHandler): () -> ()`
**Purpose & behavior**  
Registers a schema migration callback that upgrades serialized save containers when loading older versions. Returns a disconnect function to unregister the handler.

**Side effects & external interactions**  
- Stores the handler in the migration registry executed by [`ProfileServer.LoadSerialized`](#profileserver-loadserialized).  
- Emits warnings if invalid registrations are attempted (handled internally).

**Usage example**
```lua
local ProfileServer = require(ServerScriptService.Data.ProfileServer)

local disconnect = ProfileServer.RegisterMigration(1, function(container, context)
    if container.Profile and container.Profile.Settings then
        container.Profile.Settings.Locale = container.Profile.Settings.Locale or "en-us"
    end
end)
```

**Cross-refs**  
- [SaveService.LoadAsync](./SaveService.md#saveservice-loadasync)
- [ProfileServer.LoadSerialized](#profileserver-loadserialized)
