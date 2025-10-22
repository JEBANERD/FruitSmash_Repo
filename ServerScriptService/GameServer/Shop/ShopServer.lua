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
        local current = counts[item.Id] or 0
        local limit = item.StackLimit or math.huge
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

        local price = tonumber(item.PriceCoins) or 0
        if price < 0 then
                price = 0
        end

        local coins = if type(data.Coins) == "number" then data.Coins else FALLBACK_DEFAULTS.Coins
        coins = resolveCoinsFromEconomy(player, math.max(coins, 0))

        if coins < price then
                response.err = "InsufficientFunds"
                response.coins = coins
                sendNotice(player, "Not enough coins for that purchase.", "warn")
                return response
        end

        local kind = string.lower(tostring(item.Kind or ""))
        local ok, failureReason = false, nil :: string?
        if kind == "melee" then
                ok, failureReason = applyMeleePurchase(inventory, item)
        elseif kind == "token" then
                ok, failureReason = applyTokenPurchase(inventory, item)
        elseif kind == "utility" then
                ok, failureReason = applyUtilityPurchase(inventory, item)
        else
                response.err = "UnsupportedKind"
                sendNotice(player, "That item cannot be purchased right now.", "error")
                return response
        end

        if not ok then
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
        response.quickbar = quickbarState or QuickbarServer.BuildState(data, inventory)

        if Remotes.PurchaseMade then
                Remotes.PurchaseMade:FireClient(player, {
                        itemId = item.Id,
                        kind = item.Kind,
                        coins = remainingCoins,
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

QuickbarServer.RegisterInventoryResolver(function(player: Player)
        local _, data, inventory = ShopServer.GetProfileAndInventory(player)
        return data, inventory
end)

QuickbarServer.RefreshAll()

return ShopServer
