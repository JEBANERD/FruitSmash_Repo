--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local function safeRequire(instance: Instance?)
    if instance == nil then
        return nil
    end

    local ok, result = pcall(require, instance)
    if not ok then
        warn(string.format("[ShopServer] Failed to require %s: %s", instance:GetFullName(), result))
        return nil
    end

    return result
end

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local ShopConfig = require(configFolder:WaitForChild("ShopConfig"))
local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = GameConfigModule.Get()
local QuickbarConfig = (GameConfig.UI and GameConfig.UI.Quickbar) or {}
local MELEE_SLOTS = QuickbarConfig.MeleeSlots or 2
local TOKEN_SLOTS = QuickbarConfig.TokenSlots or 3

local dataFolder = ServerScriptService:FindFirstChild("Data")
local PersistenceServer = dataFolder and safeRequire(dataFolder:FindFirstChild("PersistenceServer")) or nil

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
remotesFolder.Name = "Remotes"
remotesFolder.Parent = ReplicatedStorage

local function getOrCreateRemote(name: string, className: string)
    local existing = remotesFolder:FindFirstChild(name)
    if existing and existing:IsA(className) then
        return existing
    end

    if existing then
        existing:Destroy()
    end

    local remote = Instance.new(className)
    remote.Name = name
    remote.Parent = remotesFolder
    return remote
end

local RF_RequestPurchase = getOrCreateRemote("RF_RequestPurchase", "RemoteFunction") :: RemoteFunction
local RE_QuickbarUpdate = getOrCreateRemote("RE_QuickbarUpdate", "RemoteEvent") :: RemoteEvent
local RE_Notice = getOrCreateRemote("RE_Notice", "RemoteEvent") :: RemoteEvent

local FALLBACK_DEFAULTS = {
    Coins = 0,
    Inventory = {
        MeleeLoadout = {},
        ActiveMelee = nil,
        TokenCounts = {},
        UtilityQueue = {},
    },
}

local fallbackProfiles: {[number]: { Data: any }} = {}

local ShopItems = (type(ShopConfig.All) == "function" and ShopConfig.All()) or ShopConfig.Items or {}

local ShopServer = {}
local initialized = false

local function cloneDefaults()
    local data = {
        Coins = FALLBACK_DEFAULTS.Coins,
        Inventory = {
            MeleeLoadout = {},
            ActiveMelee = nil,
            TokenCounts = {},
            UtilityQueue = {},
        },
    }

    return data
end

local function ensureFallbackProfile(player: Player)
    local userId = player.UserId
    local profile = fallbackProfiles[userId]
    if profile == nil then
        profile = { Data = cloneDefaults() }
        fallbackProfiles[userId] = profile
    end

    return profile
end

local function callPersistence(methodName: string, player: Player, ...: any)
    if not PersistenceServer then
        return nil
    end

    local method = PersistenceServer[methodName]
    if type(method) ~= "function" then
        return nil
    end

    local ok, result = pcall(function()
        return method(PersistenceServer, player, ...)
    end)
    if ok and result ~= nil then
        return result
    end

    ok, result = pcall(function()
        return method(player, ...)
    end)
    if ok and result ~= nil then
        return result
    end

    if not ok and result then
        warn(string.format("[ShopServer] Persistence call '%s' failed: %s", methodName, tostring(result)))
    end

    return nil
end

local function getProfile(player: Player)
    local profile = callPersistence("GetProfile", player)
    if profile then
        return profile
    end

    profile = callPersistence("GetProfileAsync", player)
    if profile then
        return profile
    end

    if PersistenceServer and type(PersistenceServer[player]) == "table" then
        return PersistenceServer[player]
    end

    return ensureFallbackProfile(player)
end

local function markProfileDirty(player: Player, profile: any)
    if not PersistenceServer then
        return
    end

    if type(PersistenceServer.MarkDirty) == "function" then
        local ok, err = pcall(function()
            return PersistenceServer:MarkDirty(player, profile)
        end)
        if not ok then
            ok, err = pcall(function()
                return PersistenceServer.MarkDirty(player, profile)
            end)
        end
        if not ok and err then
            warn(string.format("[ShopServer] Failed to mark profile dirty: %s", tostring(err)))
        end
        return
    end

    if profile then
        if type(profile.MarkDirty) == "function" then
            local ok, err = pcall(function()
                profile:MarkDirty()
            end)
            if not ok then
                warn(string.format("[ShopServer] profile:MarkDirty failed: %s", tostring(err)))
            end
        elseif type(profile.Save) == "function" then
            local ok, err = pcall(function()
                profile:Save()
            end)
            if not ok then
                warn(string.format("[ShopServer] profile:Save failed: %s", tostring(err)))
            end
        end
    end
end

local function ensureInventory(profile: any)
    if type(profile) ~= "table" then
        return nil
    end

    local data = profile.Data
    if type(data) ~= "table" then
        data = cloneDefaults()
        profile.Data = data
    end

    if type(data.Coins) ~= "number" then
        data.Coins = FALLBACK_DEFAULTS.Coins
    end

    local inventory = data.Inventory
    if type(inventory) ~= "table" then
        inventory = cloneDefaults().Inventory
        data.Inventory = inventory
    end

    inventory.MeleeLoadout = inventory.MeleeLoadout or {}
    inventory.TokenCounts = inventory.TokenCounts or {}
    inventory.UtilityQueue = inventory.UtilityQueue or {}

    return data, inventory
end

local function sendNotice(player: Player, message: string, kind: string)
    if not RE_Notice then
        return
    end

    local payload = {
        msg = message,
        kind = kind,
    }

    RE_Notice:FireClient(player, payload)
end

local function applyMeleePurchase(inventory: any, item: any)
    local loadout = inventory.MeleeLoadout
    if table.find(loadout, item.Id) then
        return false, "AlreadyOwned"
    end

    table.insert(loadout, item.Id)
    if inventory.ActiveMelee == nil then
        inventory.ActiveMelee = item.Id
    end

    return true
end

local function applyTokenPurchase(inventory: any, item: any)
    local counts = inventory.TokenCounts
    local current = counts[item.Id] or 0
    local limit = item.StackLimit or math.huge

    if current >= limit then
        return false, "StackLimit"
    end

    counts[item.Id] = current + 1
    return true
end

local function applyUtilityPurchase(inventory: any, item: any)
    local queue = inventory.UtilityQueue
    table.insert(queue, {
        Id = item.Id,
        Effect = item.Effect,
        Applied = false,
    })
    return true
end

local function buildQuickbarState(data: any, inventory: any)
    local state = {
        coins = data.Coins or 0,
        melee = {},
        tokens = {},
        utility = {},
    }

    if inventory.ActiveMelee then
        table.insert(state.melee, {
            Id = inventory.ActiveMelee,
            Active = true,
        })
    end

    for _, id in ipairs(inventory.MeleeLoadout) do
        if id ~= inventory.ActiveMelee then
            table.insert(state.melee, {
                Id = id,
                Active = false,
            })
        end
        if #state.melee >= MELEE_SLOTS then
            break
        end
    end

    local tokenEntries = {}
    for tokenId, count in pairs(inventory.TokenCounts) do
        if count > 0 then
            table.insert(tokenEntries, {
                Id = tokenId,
                Count = count,
                StackLimit = (ShopItems[tokenId] and ShopItems[tokenId].StackLimit) or nil,
            })
        end
    end

    table.sort(tokenEntries, function(a, b)
        return a.Id < b.Id
    end)

    for _, entry in ipairs(tokenEntries) do
        table.insert(state.tokens, entry)
        if #state.tokens >= TOKEN_SLOTS then
            break
        end
    end

    for _, entry in ipairs(inventory.UtilityQueue) do
        if typeof(entry) == "table" then
            table.insert(state.utility, {
                Id = entry.Id,
                Effect = entry.Effect,
                Applied = entry.Applied,
            })
        else
            table.insert(state.utility, {
                Id = entry,
            })
        end
    end

    return state
end

local function updateQuickbar(player: Player, data: any, inventory: any)
    if not RE_QuickbarUpdate then
        return
    end

    local state = buildQuickbarState(data, inventory)
    RE_QuickbarUpdate:FireClient(player, state)
end

local function processPurchase(player: Player, itemId: string)
    local response = {
        success = false,
        itemId = itemId,
    }

    if typeof(itemId) ~= "string" or itemId == "" then
        sendNotice(player, "Invalid item selection.", "error")
        response.reason = "InvalidItem"
        return response
    end

    local item = (type(ShopConfig.Get) == "function" and ShopConfig.Get(itemId)) or ShopItems[itemId]
    if not item then
        sendNotice(player, "Item not available.", "error")
        response.reason = "UnknownItem"
        return response
    end

    local profile = getProfile(player)
    if not profile then
        sendNotice(player, "Could not access your save data.", "error")
        response.reason = "NoProfile"
        return response
    end

    local data, inventory = ensureInventory(profile)
    if not data or not inventory then
        sendNotice(player, "Unable to load inventory.", "error")
        response.reason = "InventoryUnavailable"
        return response
    end

    local price = item.PriceCoins or 0
    if (data.Coins or 0) < price then
        sendNotice(player, "Not enough coins for that purchase.", "warn")
        response.reason = "InsufficientFunds"
        response.coins = data.Coins
        return response
    end

    local kind = string.lower(item.Kind or "")
    local ok, failureReason
    if kind == "melee" then
        ok, failureReason = applyMeleePurchase(inventory, item)
    elseif kind == "token" then
        ok, failureReason = applyTokenPurchase(inventory, item)
    elseif kind == "utility" then
        ok, failureReason = applyUtilityPurchase(inventory, item)
    else
        sendNotice(player, "That item cannot be purchased right now.", "error")
        response.reason = "UnsupportedKind"
        return response
    end

    if not ok then
        if failureReason == "StackLimit" then
            sendNotice(player, "You are already holding the maximum amount of that item.", "warn")
            response.reason = failureReason
        elseif failureReason == "AlreadyOwned" then
            sendNotice(player, "You already own that item.", "warn")
            response.reason = failureReason
        else
            sendNotice(player, "Purchase failed.", "error")
            response.reason = failureReason or "PurchaseFailed"
        end
        return response
    end

    data.Coins = math.max((data.Coins or 0) - price, 0)

    markProfileDirty(player, profile)

    updateQuickbar(player, data, inventory)

    local successMessage = string.format("Purchased %s!", item.Name or item.Id)
    sendNotice(player, successMessage, "info")

    response.success = true
    response.coins = data.Coins
    response.kind = item.Kind
    response.quickbar = buildQuickbarState(data, inventory)
    return response
end

local function handlePurchaseRequest(player: Player, itemId: string)
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return {
            success = false,
            reason = "InvalidPlayer",
        }
    end

    return processPurchase(player, itemId)
end

function ShopServer.Init()
    if initialized then
        return
    end
    initialized = true

    RF_RequestPurchase.OnServerInvoke = handlePurchaseRequest

    Players.PlayerRemoving:Connect(function(player)
        fallbackProfiles[player.UserId] = nil
    end)

    print("[ShopServer] Initialized")
end

ShopServer.Init()

return ShopServer
