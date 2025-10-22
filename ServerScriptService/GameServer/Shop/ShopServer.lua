--!strict
-- ShopServer
-- Handles coin-based purchases for melee weapons, consumable tokens, and utility items
-- during intermission/shop windows. Provides helpers so other systems can read and mutate
-- the authoritative inventory/profile snapshot.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local QuickbarServer = require(script.Parent.Parent:WaitForChild("QuickbarServer"))

-- Remotes (ShopOpen, PurchaseMade, RE_Notice, RF_Purchase)
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))

-- ---------- Utilities ----------

local function safeRequire(instance: Instance?): any?
        if instance == nil then
                return nil
        end
        if not instance:IsA("ModuleScript") then
                return nil
        end
        local ok, result = pcall(require, instance)
        if not ok then
                warn(string.format("[ShopServer] Failed to require %s: %s", instance:GetFullName(), tostring(result)))
                return nil
        end
        return result
end

local function findFirstChildPath(root: Instance, path: {string}): Instance?
        local current: Instance? = root
        for _, name in ipairs(path) do
                if current == nil then
                        return nil
                end
                current = current:FindFirstChild(name)
        end
        return current
end

local function toArenaKey(value: any): string?
        local valueType = typeof(value)
        if valueType == "string" then
                if value == "" then
                        return ""
                end
                return value
        elseif valueType == "number" then
                return tostring(value)
        end
        return nil
end

-- ---------- Config ----------

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local ShopConfig = require(configFolder:WaitForChild("ShopConfig"))
local ShopItems = (type(ShopConfig.All) == "function" and ShopConfig.All()) or ShopConfig.Items or {}

local function clearDictionary(tbl: { [any]: any })
        for key in pairs(tbl) do
                tbl[key] = nil
        end
end

local function sanitizeStockValue(rawValue: any): number?
        if typeof(rawValue) ~= "number" then
                return nil
        end

        if rawValue ~= rawValue then -- NaN check
                return nil
        end

        if rawValue == math.huge or rawValue == -math.huge then
                return nil
        end

        local limit = math.floor(rawValue)
        if limit < 0 then
                limit = 0
        end

        return limit
end

local function sanitizeStackLimit(rawValue: any): number
        local limit = sanitizeStockValue(rawValue)
        if limit == nil then
                return math.huge
        end
        return limit
end

local initialStockByItem: { [string]: number } = {}
local remainingStockByItem: { [string]: number } = {}

for itemId, item in pairs(ShopItems) do
        if type(item) == "table" then
                local limit = sanitizeStockValue(item.Stock)
                if limit ~= nil then
                        initialStockByItem[itemId] = limit
                        remainingStockByItem[itemId] = limit
                end
        end
end

local function ensureStockEntry(item: any)
        if type(item) ~= "table" then
                return
        end

        local itemId = item.Id
        if typeof(itemId) ~= "string" or itemId == "" then
                return
        end

        if remainingStockByItem[itemId] ~= nil or initialStockByItem[itemId] ~= nil then
                return
        end

        local limit = sanitizeStockValue(item.Stock)
        if limit ~= nil then
                initialStockByItem[itemId] = limit
                remainingStockByItem[itemId] = limit
        end
end

local function getRemainingStock(itemId: string): number?
        return remainingStockByItem[itemId]
end

local function reserveStock(itemId: string): (boolean, number?)
        local remaining = remainingStockByItem[itemId]
        if remaining == nil then
                return true, nil
        end

        if remaining <= 0 then
                return false, remaining
        end

        remaining = remaining - 1
        remainingStockByItem[itemId] = remaining
        return true, remaining
end

local function releaseStock(itemId: string)
        local remaining = remainingStockByItem[itemId]
        if remaining == nil then
                return
        end

        local limit = initialStockByItem[itemId]
        remaining = remaining + 1
        if limit ~= nil and remaining > limit then
                remaining = limit
        end

        remainingStockByItem[itemId] = remaining
end

-- ---------- ProfileServer / EconomyServer resolution ----------

local profileCandidates = {
        { "GameServer", "Data", "ProfileServer" },
        { "GameServer", "ProfileServer" },
        { "Data", "ProfileServer" },
        { "GameServer", "Data", "PersistenceServer" },
        { "GameServer", "PersistenceServer" },
        { "Data", "PersistenceServer" },
}

local ProfileServer: any? = nil
for _, parts in ipairs(profileCandidates) do
        local inst = findFirstChildPath(ServerScriptService, parts)
        local module = safeRequire(inst)
        if module then
                ProfileServer = module
                break
        end
end

local economyCandidates = {
        { "Economy", "EconomyServer" },
        { "GameServer", "Economy", "EconomyServer" },
        { "EconomyServer" },
}

local EconomyServer: any? = nil
for _, parts in ipairs(economyCandidates) do
        local inst = findFirstChildPath(ServerScriptService, parts)
        local module = safeRequire(inst)
        if module then
                EconomyServer = module
                break
        end
end

-- ---------- Legacy remote support ----------

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
        remotesFolder = Instance.new("Folder")
        remotesFolder.Name = "Remotes"
        remotesFolder.Parent = ReplicatedStorage
end

local function ensureRemote(name: string, className: "RemoteEvent" | "RemoteFunction")
        local existing = remotesFolder:FindFirstChild(name)
        if existing and existing.ClassName == className then
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

local legacyPurchaseRemote = ensureRemote("RF_RequestPurchase", "RemoteFunction") :: RemoteFunction

-- ---------- Fallback profiles (when ProfileServer is absent) ----------

local FALLBACK_DEFAULTS = {
        Coins = 0,
        Inventory = {
                MeleeLoadout = {} :: {string},
                ActiveMelee = nil :: string?,
                TokenCounts = {} :: { [string]: number },
                UtilityQueue = {} :: { any },
        },
}

local fallbackProfiles: { [number]: { Data: any } } = {}

local function cloneDefaults(): any
        return {
                Coins = FALLBACK_DEFAULTS.Coins,
                Inventory = {
                        MeleeLoadout = {},
                        ActiveMelee = nil,
                        TokenCounts = {},
                        UtilityQueue = {},
                },
        }
end

local function ensureFallbackProfile(player: Player)
        local uid = player.UserId
        local profile = fallbackProfiles[uid]
        if not profile then
                profile = { Data = cloneDefaults() }
                fallbackProfiles[uid] = profile
        end
        return profile
end

-- ---------- Profile helpers ----------

local function callProfile(methodName: string, player: Player, ...: any): any?
        if not ProfileServer then
                return nil
        end

        local method = (ProfileServer :: any)[methodName]
        if type(method) ~= "function" then
                return nil
        end

        local ok, result = pcall(method, ProfileServer, player, ...)
        if ok and result ~= nil then
                return result
        end

        ok, result = pcall(method, player, ...)
        if ok and result ~= nil then
                return result
        end

        if not ok and result ~= nil then
                warn(string.format("[ShopServer] ProfileServer.%s failed: %s", methodName, tostring(result)))
        end

        return nil
end

local function getProfile(player: Player)
        local profile = callProfile("GetProfile", player)
        if profile then
                return profile
        end

        profile = callProfile("GetProfileAsync", player)
        if profile then
                return profile
        end

        if ProfileServer and type((ProfileServer :: any)[player]) == "table" then
                return (ProfileServer :: any)[player]
        end

        return ensureFallbackProfile(player)
end

local function markProfileDirty(player: Player, profile: any)
        if not profile then
                return
        end

        if ProfileServer then
                if type((ProfileServer :: any).MarkDirty) == "function" then
                        local ok, err = pcall(function()
                                return (ProfileServer :: any):MarkDirty(player, profile)
                        end)
                        if not ok then
                                ok, err = pcall(function()
                                        return (ProfileServer :: any).MarkDirty(player, profile)
                                end)
                        end
                        if not ok and err then
                                warn(string.format("[ShopServer] MarkDirty failed: %s", tostring(err)))
                        end
                        return
                end

                if type((ProfileServer :: any).MarkProfileDirty) == "function" then
                        local ok, err = pcall(function()
                                return (ProfileServer :: any):MarkProfileDirty(player, profile)
                        end)
                        if not ok then
                                ok, err = pcall(function()
                                        return (ProfileServer :: any).MarkProfileDirty(player, profile)
                                end)
                        end
                        if not ok and err then
                                warn(string.format("[ShopServer] MarkProfileDirty failed: %s", tostring(err)))
                        end
                        return
                end
        end

        if type(profile) == "table" then
                if type(profile.MarkDirty) == "function" then
                        local ok, err = pcall(function()
                                return profile:MarkDirty()
                        end)
                        if not ok and err then
                                warn(string.format("[ShopServer] profile:MarkDirty failed: %s", tostring(err)))
                        end
                elseif type(profile.Save) == "function" then
                        local ok, err = pcall(function()
                                return profile:Save()
                        end)
                        if not ok and err then
                                warn(string.format("[ShopServer] profile:Save failed: %s", tostring(err)))
                        end
                end
        end
end

local function ensureInventory(profile: any): (any?, any?)
        if type(profile) ~= "table" then
                return nil, nil
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
        if Remotes.RE_Notice then
                Remotes.RE_Notice:FireClient(player, {
                        msg = message,
                        kind = kind,
                })
        end
end

-- ---------- Inventory application helpers ----------

local function applyMeleePurchase(inventory: any, item: any): (boolean, string?)
        local loadout = inventory.MeleeLoadout
        if table.find(loadout, item.Id) then
                return false, "AlreadyOwned"
        end
        table.insert(loadout, item.Id)
        if inventory.ActiveMelee == nil then
                inventory.ActiveMelee = item.Id
        end
        return true, nil
end

local function applyTokenPurchase(inventory: any, item: any): (boolean, string?)
        local counts = inventory.TokenCounts
        local current = counts[item.Id]
        if typeof(current) ~= "number" then
                current = 0
        else
                current = math.max(0, math.floor(current))
        end

        local limit = sanitizeStackLimit(item.StackLimit)
        if current >= limit then
                return false, "StackLimit"
        end
        counts[item.Id] = current + 1
        return true, nil
end

local function applyUtilityPurchase(inventory: any, item: any): (boolean, string?)
        table.insert(inventory.UtilityQueue, {
                Id = item.Id,
                Effect = item.Effect,
                Applied = false,
        })
        return true, nil
end

-- ---------- Shop state ----------

local globalOpen = false
local gatingActive = false
local openArenaKeys: { [string]: boolean } = {}

local function dispatchShopState(isOpen: boolean, arenaId: any?)
        if not Remotes.ShopOpen then
                return
        end

        local payload = {
                open = isOpen,
                arenaId = arenaId,
        }

        if arenaId == nil then
                Remotes.ShopOpen:FireAllClients(payload)
                return
        end

        local targetKey = toArenaKey(arenaId)
        if not targetKey then
                return
        end

        for _, player in ipairs(Players:GetPlayers()) do
                local playerKey = toArenaKey(player:GetAttribute("ArenaId"))
                if playerKey == targetKey then
                        Remotes.ShopOpen:FireClient(player, payload)
                end
        end
end

local function isShopOpenForPlayer(player: Player): boolean
        if not gatingActive then
                return true
        end

        if globalOpen then
                return true
        end

        local key = toArenaKey(player:GetAttribute("ArenaId"))
        if not key then
                return false
        end

        return openArenaKeys[key] == true
end

-- ---------- Purchasing ----------

local function resolveCoinsFromEconomy(player: Player, fallbackCoins: number): number
        if not EconomyServer then
                return fallbackCoins
        end

        local totalsFn = (EconomyServer :: any).Totals
        if type(totalsFn) ~= "function" then
                return fallbackCoins
        end

        local ok, totals = pcall(totalsFn, EconomyServer, player)
        if not ok then
                ok, totals = pcall(totalsFn, player)
        end
        if ok and type(totals) == "table" and type(totals.coins) == "number" then
                local walletCoins = math.max(0, math.floor(totals.coins + 0.5))
                if walletCoins < fallbackCoins then
                        return walletCoins
                end
        end

        return fallbackCoins
end

local function processPurchase(player: Player, itemId: string)
        local response = {
                ok = false,
                itemId = itemId,
        }

        if typeof(itemId) ~= "string" or itemId == "" then
                response.err = "InvalidItem"
                sendNotice(player, "Invalid item selection.", "error")
                return response
        end

        if not isShopOpenForPlayer(player) then
                response.err = "ShopClosed"
                sendNotice(player, "Shop is currently closed.", "warn")
                return response
        end

        local item = (type(ShopConfig.Get) == "function" and ShopConfig.Get(itemId)) or ShopItems[itemId]
        if not item then
                response.err = "UnknownItem"
                sendNotice(player, "Item not available.", "error")
                return response
        end

        ensureStockEntry(item)

        if typeof(item.Id) ~= "string" or item.Id == "" then
                item.Id = itemId
        end

        local stockReserved = false
        local reservedStockRemaining: number? = nil

        local function releaseReservedStock()
                if stockReserved then
                        releaseStock(item.Id)
                        stockReserved = false
                end
        end

        local profile = getProfile(player)
        if not profile then
                response.err = "NoProfile"
                sendNotice(player, "Could not access your save data.", "error")
                return response
        end

        local data, inventory = ensureInventory(profile)
        if not data or not inventory then
                response.err = "InventoryUnavailable"
                sendNotice(player, "Unable to load inventory.", "error")
                return response
        end

        local priceValue = tonumber(item.PriceCoins)
        if priceValue == nil then
                priceValue = 0
        end
        priceValue = math.floor(priceValue)
        if priceValue < 0 then
                priceValue = 0
        end

        local price = priceValue
        response.price = price

        local coins = if type(data.Coins) == "number" then data.Coins else FALLBACK_DEFAULTS.Coins
        coins = resolveCoinsFromEconomy(player, math.max(coins, 0))
        if typeof(coins) ~= "number" then
                coins = FALLBACK_DEFAULTS.Coins
        end
        coins = math.max(0, math.floor(coins))

        if coins < price then
                response.err = "InsufficientFunds"
                response.coins = coins
                sendNotice(player, "Not enough coins for that purchase.", "warn")
                return response
        end

        local kind = string.lower(tostring(item.Kind or ""))
        local applyFn: ((any, any) -> (boolean, string?))?
        if kind == "melee" then
                applyFn = applyMeleePurchase
        elseif kind == "token" then
                applyFn = applyTokenPurchase
        elseif kind == "utility" then
                applyFn = applyUtilityPurchase
        else
                response.err = "UnsupportedKind"
                sendNotice(player, "That item cannot be purchased right now.", "error")
                return response
        end

        local reserveOk, newStockRemaining = reserveStock(item.Id)
        if not reserveOk then
                response.err = "OutOfStock"
                response.stockRemaining = newStockRemaining or 0
                response.stockLimit = initialStockByItem[item.Id]
                sendNotice(player, "That item is sold out.", "warn")
                return response
        end

        if newStockRemaining ~= nil then
                stockReserved = true
                reservedStockRemaining = newStockRemaining
        end

        local ok, failureReason = applyFn(inventory, item)
        if not ok then
                releaseReservedStock()
                if failureReason == "StackLimit" then
                        sendNotice(player, "You are already holding the maximum amount of that item.", "warn")
                elseif failureReason == "AlreadyOwned" then
                        sendNotice(player, "You already own that item.", "warn")
                else
                        sendNotice(player, "Purchase failed.", "error")
                end
                response.err = failureReason or "PurchaseFailed"
                return response
        end

        local remainingCoins = math.max(coins - price, 0)
        data.Coins = remainingCoins

        if player and player.Parent then
                player:SetAttribute("Coins", remainingCoins)
        end

        markProfileDirty(player, profile)
        local quickbarState = QuickbarServer.Refresh(player, data, inventory)

        sendNotice(player, string.format("Purchased %s!", item.Name or item.Id), "info")

        response.ok = true
        response.err = nil
        response.coins = remainingCoins
        response.kind = item.Kind
        response.price = price
        response.stockRemaining = reservedStockRemaining
        response.stockLimit = initialStockByItem[item.Id]
        response.quickbar = quickbarState or QuickbarServer.BuildState(data, inventory)

        if stockReserved then
                -- Item had limited stock and was successfully consumed; do not release.
                stockReserved = false
        end

        if Remotes.PurchaseMade then
                Remotes.PurchaseMade:FireClient(player, {
                        itemId = item.Id,
                        kind = item.Kind,
                        coins = remainingCoins,
                        price = price,
                        stockRemaining = response.stockRemaining,
                        stockLimit = response.stockLimit,
                        quickbar = response.quickbar,
                })
        end

        return response
end

local function handlePurchaseRequest(player: Player, payloadOrItemId: any)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return { ok = false, err = "InvalidPlayer" }
        end

        local itemId: string? = nil
        if typeof(payloadOrItemId) == "string" then
                itemId = payloadOrItemId
        elseif typeof(payloadOrItemId) == "table" then
                itemId = payloadOrItemId.itemId or payloadOrItemId.Id or payloadOrItemId.id
        end

        if typeof(itemId) ~= "string" or itemId == "" then
                return { ok = false, err = "InvalidItem" }
        end

        return processPurchase(player, itemId)
end

-- ---------- Public API ----------

local ShopServer = {}
local initialized = false

function ShopServer.Init()
        if initialized then
                return
        end
        initialized = true

        if Remotes.RF_Purchase then
                Remotes.RF_Purchase.OnServerInvoke = handlePurchaseRequest
        end

        legacyPurchaseRemote.OnServerInvoke = handlePurchaseRequest

        Players.PlayerRemoving:Connect(function(player)
                fallbackProfiles[player.UserId] = nil
        end)

        print("[ShopServer] Initialized")
end

function ShopServer.Open(arenaId: any?)
        gatingActive = true
        if arenaId == nil then
                globalOpen = true
                dispatchShopState(true, nil)
                return
        end

        local key = toArenaKey(arenaId)
        if not key then
                return
        end

        openArenaKeys[key] = true
        dispatchShopState(true, arenaId)
end

function ShopServer.Close(arenaId: any?)
        gatingActive = true
        if arenaId == nil then
                globalOpen = false
                table.clear(openArenaKeys)
                dispatchShopState(false, nil)
                return
        end

        local key = toArenaKey(arenaId)
        if not key then
                return
        end

        openArenaKeys[key] = nil
        dispatchShopState(false, arenaId)
end

ShopServer.Init()

function ShopServer.GetProfileAndInventory(player: Player)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return nil, nil, nil
        end
        local profile = getProfile(player)
        if not profile then
                return nil, nil, nil
        end
        local data, inventory = ensureInventory(profile)
        if not data or not inventory then
                return nil, nil, nil
        end
        return profile, data, inventory
end

function ShopServer.MarkProfileDirty(player: Player, profile: any)
        markProfileDirty(player, profile)
end

function ShopServer.UpdateQuickbarForPlayer(player: Player, data: any, inventory: any)
        QuickbarServer.Refresh(player, data, inventory)
end

function ShopServer.ApplyMeleeToInventory(inventory: any, item: any)
        return applyMeleePurchase(inventory, item)
end

function ShopServer.BuildQuickbarState(data: any, inventory: any)
        return QuickbarServer.BuildState(data, inventory)
end

function ShopServer.GetRemainingStock(itemId: string)
        if typeof(itemId) ~= "string" or itemId == "" then
                return nil
        end
        return getRemainingStock(itemId)
end

function ShopServer.ResetStock(itemId: string?)
        if itemId == nil then
                for id, item in pairs(ShopItems) do
                        if type(item) == "table" then
                                ensureStockEntry(item)
                        end
                end

                clearDictionary(remainingStockByItem)
                for id, limit in pairs(initialStockByItem) do
                        remainingStockByItem[id] = limit
                end
                return
        end

        if typeof(itemId) ~= "string" or itemId == "" then
                return
        end

        local configItem = (type(ShopConfig.Get) == "function" and ShopConfig.Get(itemId)) or ShopItems[itemId]
        if configItem then
                ensureStockEntry(configItem)
        end

        local limit = initialStockByItem[itemId]
        if limit ~= nil then
                remainingStockByItem[itemId] = limit
        else
                remainingStockByItem[itemId] = nil
        end
end

QuickbarServer.RegisterInventoryResolver(function(player: Player)
        local _, data, inventory = ShopServer.GetProfileAndInventory(player)
        return data, inventory
end)

QuickbarServer.RefreshAll()

return ShopServer
