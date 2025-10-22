--!strict
-- ProfileServer
-- Session-scoped profile storage for coins, points, melee inventory, and consumable tokens.
-- Provides a thin facade while persistence is under development.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local typesFolder = sharedFolder:WaitForChild("Types")

local function safeRequire(moduleScript: Instance?): any?
    if not moduleScript or not moduleScript:IsA("ModuleScript") then
        return nil
    end

    local ok, result = pcall(require, moduleScript)
    if not ok then
        warn(string.format("[ProfileServer] Failed to require %s: %s", moduleScript:GetFullName(), tostring(result)))
        return nil
    end

    return result
end

local SaveSchemaModule = safeRequire(typesFolder:FindFirstChild("SaveSchema"))
local ShopConfigModule = safeRequire(configFolder:FindFirstChild("ShopConfig"))

local saveDefaults = if type(SaveSchemaModule) == "table" and type(SaveSchemaModule.Defaults) == "table"
    then SaveSchemaModule.Defaults
    else {}

local shopItems = (typeof(ShopConfigModule) == "table" and typeof((ShopConfigModule :: any).All) == "function"
        and (ShopConfigModule :: any).All())
    or (typeof(ShopConfigModule) == "table" and (ShopConfigModule :: any).Items)
    or {}

type TokenCounts = { [string]: number }
type OwnedMeleeMap = { [string]: boolean }

type Inventory = {
    MeleeLoadout: {string},
    ActiveMelee: string?,
    TokenCounts: TokenCounts,
    UtilityQueue: {string},
    OwnedMelee: OwnedMeleeMap,
}

type ProfileData = {
    Coins: number,
    Stats: { [string]: any },
    Inventory: Inventory,
}

type Profile = {
    Player: Player,
    UserId: number,
    Data: ProfileData,
}

local ProfileServer = {}

local profilesByPlayer: { [Player]: Profile } = {}
local profilesByUserId: { [number]: Profile } = {}

local function deepCopy(value: any, seen: {[any]: any}?): any
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy: {[any]: any} = {}
    seen[value] = copy

    for key, subValue in pairs(value) do
        copy[deepCopy(key, seen)] = deepCopy(subValue, seen)
    end

    return copy
end

local function sanitizeStringList(list: any): {string}
    local result: {string} = {}
    if type(list) ~= "table" then
        return result
    end

    for _, item in ipairs(list) do
        if type(item) == "string" and item ~= "" then
            table.insert(result, item)
        end
    end

    return result
end

local function sanitizeTokenCounts(map: any): TokenCounts
    local counts: TokenCounts = {}
    if type(map) ~= "table" then
        return counts
    end

    for tokenId, count in pairs(map) do
        if type(tokenId) == "string" and tokenId ~= "" then
            local numeric = if type(count) == "number" then count else tonumber(count)
            if type(numeric) == "number" then
                counts[tokenId] = math.max(0, math.floor(numeric + 0.5))
            end
        end
    end

    return counts
end

local function sanitizeOwnedMelee(map: any): OwnedMeleeMap
    local owned: OwnedMeleeMap = {}
    if type(map) ~= "table" then
        return owned
    end

    for meleeId, flag in pairs(map) do
        if type(meleeId) == "string" and meleeId ~= "" and flag then
            owned[meleeId] = true
        end
    end

    return owned
end

local function buildDefaultData(): ProfileData
    local data: ProfileData = {
        Coins = 0,
        Stats = {},
        Inventory = {
            MeleeLoadout = {},
            ActiveMelee = nil,
            TokenCounts = {},
            UtilityQueue = {},
            OwnedMelee = {},
        },
    }

    if type(saveDefaults) == "table" then
        local cloned = deepCopy(saveDefaults)
        if type(cloned.Coins) == "number" then
            data.Coins = cloned.Coins
        end

        if type(cloned.Stats) == "table" then
            data.Stats = cloned.Stats
        end

        if type(cloned.Inventory) == "table" then
            local inventory = cloned.Inventory
            data.Inventory.MeleeLoadout = sanitizeStringList(inventory.MeleeLoadout)
            data.Inventory.ActiveMelee = if type(inventory.ActiveMelee) == "string" then inventory.ActiveMelee else nil
            data.Inventory.TokenCounts = sanitizeTokenCounts(inventory.TokenCounts)
            data.Inventory.UtilityQueue = sanitizeStringList(inventory.UtilityQueue)
            data.Inventory.OwnedMelee = sanitizeOwnedMelee(inventory.OwnedMelee)
        end
    end

    local stats = data.Stats
    if type(stats) ~= "table" then
        stats = {}
        data.Stats = stats
    end
    if type(stats.TotalPoints) ~= "number" then
        stats.TotalPoints = 0
    end

    local inventory = data.Inventory
    inventory.MeleeLoadout = inventory.MeleeLoadout or {}
    inventory.TokenCounts = inventory.TokenCounts or {}
    inventory.UtilityQueue = inventory.UtilityQueue or {}
    inventory.OwnedMelee = inventory.OwnedMelee or {}

    return data
end

local function ensureInventory(data: ProfileData): Inventory
    if type(data.Inventory) ~= "table" then
        data.Inventory = buildDefaultData().Inventory
    end

    local inventory = data.Inventory
    if type(inventory.MeleeLoadout) ~= "table" then
        inventory.MeleeLoadout = {}
    end
    if type(inventory.TokenCounts) ~= "table" then
        inventory.TokenCounts = {}
    end
    if type(inventory.UtilityQueue) ~= "table" then
        inventory.UtilityQueue = {}
    end
    if type(inventory.OwnedMelee) ~= "table" then
        inventory.OwnedMelee = {}
    end

    return inventory
end

local cachedQuickbar: any? = nil
local quickbarWarned = false
local function getQuickbarServer(): any?
    if cachedQuickbar ~= nil then
        return cachedQuickbar
    end

    local gameServerFolder = ServerScriptService:FindFirstChild("GameServer")
    if not gameServerFolder then
        return nil
    end

    local moduleScript = gameServerFolder:FindFirstChild("QuickbarServer")
    if not moduleScript or not moduleScript:IsA("ModuleScript") then
        return nil
    end

    local ok, quickbar = pcall(require, moduleScript)
    if ok then
        cachedQuickbar = quickbar
        return quickbar
    else
        if not quickbarWarned then
            warn(string.format("[ProfileServer] Failed to require QuickbarServer: %s", tostring(quickbar)))
            quickbarWarned = true
        end
        return nil
    end
end

local function refreshQuickbar(player: Player, data: ProfileData?, inventory: Inventory?)
    local quickbar = getQuickbarServer()
    if not quickbar then
        return
    end

    local refresh = (quickbar :: any).Refresh
    if type(refresh) ~= "function" then
        return
    end

    local ok, err = pcall(function()
        refresh(player, data, inventory)
    end)
    if not ok then
        warn(string.format("[ProfileServer] Quickbar refresh failed: %s", tostring(err)))
    end
end

local function ensureProfile(player: Player): Profile
    local existing = profilesByPlayer[player]
    if existing then
        return existing
    end

    local data = buildDefaultData()
    local profile: Profile = {
        Player = player,
        UserId = player.UserId,
        Data = data,
    }

    profilesByPlayer[player] = profile
    profilesByUserId[player.UserId] = profile

    return profile
end

local function removeProfile(player: Player)
    profilesByPlayer[player] = nil
    local userId = player.UserId
    if userId ~= 0 then
        profilesByUserId[userId] = nil
    end
end

local function getTokenCounts(inventory: Inventory): TokenCounts
    if type(inventory.TokenCounts) ~= "table" then
        inventory.TokenCounts = {}
    end
    return inventory.TokenCounts
end

local function getOwnedMelee(inventory: Inventory): OwnedMeleeMap
    if type(inventory.OwnedMelee) ~= "table" then
        inventory.OwnedMelee = {}
    end
    return inventory.OwnedMelee
end

local function insertUniqueMelee(loadout: {string}, meleeId: string)
    for _, existing in ipairs(loadout) do
        if existing == meleeId then
            return
        end
    end
    table.insert(loadout, meleeId)
end

function ProfileServer.Get(player: Player): Profile
    assert(typeof(player) == "Instance" and player:IsA("Player"), "ProfileServer.Get expects a Player")
    return ensureProfile(player)
end

ProfileServer.GetProfile = ProfileServer.Get

function ProfileServer.GetData(player: Player): ProfileData
    return ProfileServer.Get(player).Data
end

function ProfileServer.GetInventory(player: Player): Inventory
    local profile = ProfileServer.Get(player)
    return ensureInventory(profile.Data)
end

function ProfileServer.GetProfileAndInventory(player: Player): (Profile, ProfileData, Inventory)
    local profile = ProfileServer.Get(player)
    local data = profile.Data
    local inventory = ensureInventory(data)
    return profile, data, inventory
end

function ProfileServer.AddCoins(player: Player, amount: number?): number
    local profile = ProfileServer.Get(player)
    local data = profile.Data
    local numeric = if type(amount) == "number" then amount else tonumber(amount)
    if type(numeric) ~= "number" then
        return data.Coins or 0
    end

    local delta = math.floor(numeric)
    if delta <= 0 then
        return data.Coins or 0
    end

    local current = if type(data.Coins) == "number" then data.Coins else 0
    local newTotal = current + delta
    data.Coins = math.max(0, newTotal)

    refreshQuickbar(player, data, ensureInventory(data))

    return data.Coins
end

function ProfileServer.SpendCoins(player: Player, amount: number?): (boolean, string?)
    local profile = ProfileServer.Get(player)
    local data = profile.Data
    local numeric = if type(amount) == "number" then amount else tonumber(amount)
    if type(numeric) ~= "number" then
        return false, "InvalidAmount"
    end

    local cost = math.floor(numeric)
    if cost <= 0 then
        return false, "InvalidAmount"
    end

    local current = if type(data.Coins) == "number" then data.Coins else 0
    if current < cost then
        return false, "NotEnough"
    end

    data.Coins = current - cost
    refreshQuickbar(player, data, ensureInventory(data))

    return true, nil
end

local function coerceCount(value: any): number
    if type(value) == "number" then
        return value
    end
    local numeric = tonumber(value)
    if type(numeric) == "number" then
        return numeric
    end
    return 0
end

function ProfileServer.GrantItem(player: Player, itemId: string): (boolean, string?)
    if type(itemId) ~= "string" or itemId == "" then
        return false, "InvalidItem"
    end

    local itemInfo = shopItems[itemId]
    if type(itemInfo) ~= "table" then
        return false, "UnknownItem"
    end

    local _, data, inventory = ProfileServer.GetProfileAndInventory(player)
    local kind = if type(itemInfo.Kind) == "string" then itemInfo.Kind else ""

    if kind == "Melee" then
        local owned = getOwnedMelee(inventory)
        if owned[itemId] then
            return false, "AlreadyOwned"
        end
        owned[itemId] = true
        insertUniqueMelee(inventory.MeleeLoadout, itemId)
        if type(inventory.ActiveMelee) ~= "string" or inventory.ActiveMelee == "" then
            inventory.ActiveMelee = itemId
        end
        refreshQuickbar(player, data, inventory)
        return true, nil
    elseif kind == "Token" then
        local counts = getTokenCounts(inventory)
        local current = math.max(0, math.floor(coerceCount(counts[itemId])))
        local increment = if type(itemInfo.Count) == "number" and itemInfo.Count > 0 then math.floor(itemInfo.Count) else 1
        if increment <= 0 then
            increment = 1
        end

        local stackLimit = if type(itemInfo.StackLimit) == "number" then math.max(0, math.floor(itemInfo.StackLimit)) else nil
        if stackLimit and current >= stackLimit then
            return false, "StackLimit"
        end

        local newCount = current + increment
        if stackLimit then
            newCount = math.clamp(newCount, 0, stackLimit)
        end
        counts[itemId] = newCount

        refreshQuickbar(player, data, inventory)
        return true, nil
    elseif kind == "Utility" then
        table.insert(inventory.UtilityQueue, itemId)
        return true, nil
    end

    return false, "UnsupportedKind"
end

function ProfileServer.ConsumeToken(player: Player, itemId: string): (boolean, string?)
    if type(itemId) ~= "string" or itemId == "" then
        return false, "InvalidItem"
    end

    local _, data, inventory = ProfileServer.GetProfileAndInventory(player)
    local counts = getTokenCounts(inventory)
    local current = math.max(0, math.floor(coerceCount(counts[itemId])))
    if current <= 0 then
        return false, "NoToken"
    end

    local newCount = current - 1
    if newCount <= 0 then
        counts[itemId] = nil
    else
        counts[itemId] = newCount
    end

    refreshQuickbar(player, data, inventory)

    return true, nil
end

function ProfileServer.Serialize(player: Player): ProfileData
    local profile = profilesByPlayer[player]
    if not profile then
        return buildDefaultData()
    end

    local data = profile.Data
    local inventory = ensureInventory(data)
    local serialized: ProfileData = {
        Coins = if type(data.Coins) == "number" then data.Coins else 0,
        Stats = if type(data.Stats) == "table" then deepCopy(data.Stats) else {},
        Inventory = {
            MeleeLoadout = sanitizeStringList(inventory.MeleeLoadout),
            ActiveMelee = if type(inventory.ActiveMelee) == "string" then inventory.ActiveMelee else nil,
            TokenCounts = sanitizeTokenCounts(inventory.TokenCounts),
            UtilityQueue = sanitizeStringList(inventory.UtilityQueue),
            OwnedMelee = sanitizeOwnedMelee(inventory.OwnedMelee),
        },
    }

    return serialized
end

function ProfileServer.GetByUserId(userId: number): Profile?
    return profilesByUserId[userId]
end

function ProfileServer.Reset(player: Player)
    local profile = profilesByPlayer[player]
    if not profile then
        return
    end

    profile.Data = buildDefaultData()
    refreshQuickbar(player, profile.Data, profile.Data.Inventory)
end

Players.PlayerAdded:Connect(function(player)
    ensureProfile(player)
end)

Players.PlayerRemoving:Connect(function(player)
    removeProfile(player)
end)

for _, player in ipairs(Players:GetPlayers()) do
    ensureProfile(player)
end

return ProfileServer

