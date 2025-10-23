--!strict
-- QuickbarServer
-- Authoritative quickbar snapshots sourced from profile/inventory state.
-- API:
--   Refresh(player [, data, inventory]) -> QuickbarState?
--   RefreshAll([arenaId])
--   RegisterInventoryResolver(resolver)
--   BuildState(data, inventory) -> QuickbarState
--   GetState(player) -> QuickbarState?
--   GetTokenSlot(player, index) -> QuickbarTokenEntry?
--   EquipMelee(player, itemId) -> QuickbarState?, string?

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local ShopConfig = require(configFolder:WaitForChild("ShopConfig"))
local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = GameConfigModule.Get()

local FlagsModule
do
        local ok, module = pcall(function()
                return require(configFolder:WaitForChild("Flags"))
        end)
        if ok and typeof(module) == "table" then
                FlagsModule = module
        end
end

local function resolveTokensFlag(): boolean
        if FlagsModule and typeof((FlagsModule :: any).IsEnabled) == "function" then
                local ok, result = pcall((FlagsModule :: any).IsEnabled, "Tokens")
                if ok and typeof(result) == "boolean" then
                        return result
                end
        end
        return true
end

local quickbarConfig = (GameConfig.UI and GameConfig.UI.Quickbar) or {}
local MELEE_SLOTS = quickbarConfig.MeleeSlots or 2
local TOKEN_SLOTS = quickbarConfig.TokenSlots or 3
local DEFAULT_MELEE = (GameConfig.Melee and GameConfig.Melee.DefaultWeapon) or nil

local shopItems = (type(ShopConfig.All) == "function" and ShopConfig.All()) or ShopConfig.Items or {}

local function getShopItem(itemId: string): any?
        local cached = shopItems[itemId]
        if typeof(cached) == "table" then
                return cached
        end

        if typeof(ShopConfig.Get) == "function" then
                local ok, item = pcall(ShopConfig.Get, itemId)
                if ok and typeof(item) == "table" then
                        shopItems[itemId] = item
                        return item
                end
        end

        return nil
end

local function coerceNumber(value: any): number?
        local valueType = typeof(value)
        if valueType == "number" then
                return value
        elseif valueType == "string" then
                local numeric = tonumber(value)
                if typeof(numeric) == "number" then
                        return numeric
                end
        end

        return nil
end

local tokenOrderIndex: {[string]: number} = {}
local tokenOrderBase = 0

do
        local sortable: {{ Id: string, Order: number, Price: number, Name: string }} = {}

        for itemId, rawItem in pairs(shopItems) do
                if typeof(itemId) == "string" and typeof(rawItem) == "table" then
                        local kind = rawItem.Kind
                        if typeof(kind) == "string" and string.lower(kind) == "token" then
                                local orderValue = coerceNumber(rawItem.QuickbarOrder)
                                        or coerceNumber(rawItem.SortOrder)
                                        or coerceNumber(rawItem.DisplayOrder)
                                        or coerceNumber(rawItem.PriceCoins)
                                        or math.huge
                                local priceValue = coerceNumber(rawItem.PriceCoins) or math.huge
                                local nameValue = if typeof(rawItem.Name) == "string" then rawItem.Name else itemId

                                table.insert(sortable, {
                                        Id = itemId,
                                        Order = orderValue,
                                        Price = priceValue,
                                        Name = nameValue,
                                })
                        end
                end
        end

        table.sort(sortable, function(a, b)
                if a.Order ~= b.Order then
                        return a.Order < b.Order
                end
                if a.Price ~= b.Price then
                        return a.Price < b.Price
                end
                if a.Name ~= b.Name then
                        return a.Name < b.Name
                end
                return a.Id < b.Id
        end)

        for index, entry in ipairs(sortable) do
                tokenOrderIndex[entry.Id] = index
        end

        tokenOrderBase = #sortable
end

export type QuickbarMeleeEntry = { Id: string, Active: boolean }
export type QuickbarTokenEntry = { Id: string, Count: number, StackLimit: number? }
export type QuickbarState = {
        coins: number?,
        melee: { QuickbarMeleeEntry? },
        tokens: { QuickbarTokenEntry? },
}

local QuickbarServer = {}

local profileServer: any? = nil
local profileRequireWarned = false
local profileMissingWarned = false

local function findFirstChildPath(root: Instance, parts: {string}): Instance?
        local current: Instance? = root
        for _, name in ipairs(parts) do
                if not current then return nil end
                current = current:FindFirstChild(name)
        end
        return current
end

local profileCandidates = {
        {"GameServer", "Data", "ProfileServer"},
        {"GameServer", "ProfileServer"},
        {"Data", "ProfileServer"},
}

local function ensureProfileServer(): any?
        if profileServer ~= nil then
                return profileServer
        end

        local foundModule: Instance? = nil
        for _, parts in ipairs(profileCandidates) do
                local candidate = findFirstChildPath(ServerScriptService, parts)
                if candidate and candidate:IsA("ModuleScript") then
                        foundModule = candidate
                        local ok, result = pcall(require, candidate)
                        if ok then
                                profileServer = result
                                return profileServer
                        else
                                if not profileRequireWarned then
                                        warn(string.format("[QuickbarServer] Failed to require ProfileServer (%s): %s", candidate:GetFullName(), tostring(result)))
                                        profileRequireWarned = true
                                end
                        end
                end
        end

        if not profileMissingWarned then
                if foundModule == nil then
                        warn("[QuickbarServer] ProfileServer module missing; quickbar will fall back to defaults.")
                end
                profileMissingWarned = true
        end

        return nil
end

local inventoryResolver: ((Player) -> (any?, any?))? = nil
local lastStates: {[Player]: QuickbarState} = {}

local tokensEnabled = true

local function applyTokensFlag(state: any)
        local newState = false
        if typeof(state) == "boolean" then
                newState = state
        elseif typeof(state) == "number" then
                newState = state ~= 0
        end

        local previous = tokensEnabled
        tokensEnabled = newState

        if not tokensEnabled then
                for _, quickbarState in pairs(lastStates) do
                        if typeof(quickbarState) == "table" then
                                quickbarState.tokens = {}
                        end
                end
        end

        if previous ~= tokensEnabled then
                if typeof((QuickbarServer :: any).RefreshAll) == "function" then
                        task.defer(function()
                                QuickbarServer.RefreshAll()
                        end)
                end
        end
end

local function cloneDefaults()
        local inventory = {
                MeleeLoadout = {},
                ActiveMelee = nil,
                TokenCounts = {},
        }
        local data = {
                Coins = 0,
                Inventory = inventory,
        }
        return data, inventory
end

local function callProfileServer(methodName: string, player: Player)
        local server = ensureProfileServer()
        if not server then
                return nil
        end

        local method = (server :: any)[methodName]
        if type(method) ~= "function" then
                return nil
        end

        local ok, r1, r2, r3 = pcall(method, server, player)
        if ok then
                return r1, r2, r3
        end

        ok, r1, r2, r3 = pcall(method, player)
        if ok then
                return r1, r2, r3
        end

        warn(string.format("[QuickbarServer] ProfileServer.%s failed: %s", methodName, tostring(r1)))
        return nil
end

local function coerceDataAndInventory(a: any, b: any): (any?, any?)
        if typeof(a) == "table" then
                local data = (a :: any).Data
                if typeof(data) == "table" and typeof(data.Inventory) == "table" then
                        return data, data.Inventory
                end
                if typeof((a :: any).Inventory) == "table" then
                        return a, (a :: any).Inventory
                end
        end

        if typeof(b) == "table" then
                local data = (b :: any).Data
                if typeof(data) == "table" and typeof(data.Inventory) == "table" then
                        return data, data.Inventory
                end
                if typeof((b :: any).Inventory) == "table" then
                        return b, (b :: any).Inventory
                end
        end

        if typeof(a) == "table" and typeof(b) == "table" then
                return a, b
        end

        return nil, nil
end

local function resolveFromProfileServer(player: Player)
        if not profileServer then
                return nil, nil
        end

        local a, b, c = callProfileServer("GetProfileAndInventory", player)
        if a or b or c then
                local data, inventory = coerceDataAndInventory(a, b)
                if data and inventory then
                        return data, inventory
                end
                data, inventory = coerceDataAndInventory(a, c)
                if data and inventory then
                        return data, inventory
                end
                data, inventory = coerceDataAndInventory(b, c)
                if data and inventory then
                        return data, inventory
                end
        end

        local profile = callProfileServer("GetProfile", player)
        if profile then
                local data, inventory = coerceDataAndInventory(profile, nil)
                if data and inventory then
                        return data, inventory
                end
        end

        local data = callProfileServer("GetData", player)
        if typeof(data) == "table" then
                local _, inventory = coerceDataAndInventory(data, nil)
                if data and inventory then
                        return data, inventory
                end
        end

        return nil, nil
end

local function resolveDataAndInventory(player: Player, data: any?, inventory: any?)
        if data and inventory then
                return data, inventory
        end

        local profileData, profileInventory = resolveFromProfileServer(player)
        if profileData and profileInventory then
                return profileData, profileInventory
        end

        if inventoryResolver then
                local ok, resolvedData, resolvedInventory = pcall(inventoryResolver, player)
                if ok and resolvedData and resolvedInventory then
                        return resolvedData, resolvedInventory
                end
        end

        local defaultsData, defaultsInventory = cloneDefaults()
        return defaultsData, defaultsInventory
end

local function addMeleeEntry(target: {QuickbarMeleeEntry}, seen: {[string]: boolean}, meleeId: any, isActive: boolean)
        if typeof(meleeId) ~= "string" or meleeId == "" then
                return
        end
        if seen[meleeId] then
                return
        end
        table.insert(target, { Id = meleeId, Active = isActive })
        seen[meleeId] = true
end

local function insertUniqueString(list: {string}, value: string)
        for _, existing in ipairs(list) do
                if existing == value then
                        return
                end
        end
        table.insert(list, value)
end

local function buildMeleeEntries(inventory: any): {QuickbarMeleeEntry}
        local entries: {QuickbarMeleeEntry} = {}
        local seen: {[string]: boolean} = {}

        local activeMelee = if typeof(inventory) == "table" then inventory.ActiveMelee else nil
        addMeleeEntry(entries, seen, activeMelee, true)

        if typeof(inventory) == "table" and typeof(inventory.MeleeLoadout) == "table" then
                for _, meleeId in ipairs(inventory.MeleeLoadout) do
                        if #entries >= MELEE_SLOTS then
                                break
                        end
                        local isActive = meleeId == activeMelee
                        addMeleeEntry(entries, seen, meleeId, isActive)
                end
        end

        if #entries == 0 and typeof(DEFAULT_MELEE) == "string" and DEFAULT_MELEE ~= "" then
                addMeleeEntry(entries, seen, DEFAULT_MELEE, true)
        elseif typeof(DEFAULT_MELEE) == "string" and DEFAULT_MELEE ~= "" then
                if #entries < MELEE_SLOTS and not seen[DEFAULT_MELEE] then
                        addMeleeEntry(entries, seen, DEFAULT_MELEE, false)
                end
        end

        if #entries > MELEE_SLOTS then
                while #entries > MELEE_SLOTS do
                        table.remove(entries)
                end
        end

        for index, entry in ipairs(entries) do
                if entry and entry.Active and index ~= 1 then
                        entries[index], entries[1] = entries[1], entry
                        break
                end
        end

        return entries
end

local function buildTokenEntries(inventory: any): {QuickbarTokenEntry}
        local entries: {QuickbarTokenEntry} = {}
        if not tokensEnabled then
                return entries
        end
        local tokensMap = (typeof(inventory) == "table" and inventory.TokenCounts) or nil
        if typeof(tokensMap) ~= "table" then
                return entries
        end

        local sortable = {}
        local fallbackOffset = tokenOrderBase
        local fallbackCount = 0

        for tokenId, count in pairs(tokensMap) do
                if typeof(tokenId) == "string" then
                        local numericCount = if typeof(count) == "number" then count else tonumber(count) or 0
                        if typeof(numericCount) == "number" then
                                numericCount = math.max(0, math.floor(numericCount))
                                if numericCount > 0 then
                                        local item = getShopItem(tokenId)
                                        local kind = if item and typeof(item.Kind) == "string" then string.lower(item.Kind) else nil
                                        if kind == "token" then
                                                local stackLimit = nil
                                                if item and typeof(item.StackLimit) == "number" then
                                                        local limitValue = math.floor(item.StackLimit)
                                                        if limitValue > 0 then
                                                                stackLimit = limitValue
                                                        end
                                                end

                                                if stackLimit then
                                                        numericCount = math.min(numericCount, stackLimit)
                                                end

                                                if numericCount > 0 then
                                                        local orderIndex = tokenOrderIndex[tokenId]
                                                        if orderIndex == nil then
                                                                fallbackCount = fallbackCount + 1
                                                                orderIndex = fallbackOffset + fallbackCount
                                                        end

                                                        local priceValue = math.huge
                                                        if item then
                                                                local price = coerceNumber(item.PriceCoins)
                                                                if typeof(price) == "number" then
                                                                        priceValue = price
                                                                end
                                                        end

                                                        table.insert(sortable, {
                                                                Id = tokenId,
                                                                Count = numericCount,
                                                                StackLimit = stackLimit,
                                                                Order = orderIndex,
                                                                Price = priceValue,
                                                        })
                                                end
                                        end
                                end
                        end
                end
        end

        table.sort(sortable, function(a, b)
                if a.Order ~= b.Order then
                        return a.Order < b.Order
                end
                if a.Price ~= b.Price then
                        return a.Price < b.Price
                end
                return a.Id < b.Id
        end)

        for _, entry in ipairs(sortable) do
                if #entries >= TOKEN_SLOTS then
                        break
                end
                table.insert(entries, {
                        Id = entry.Id,
                        Count = entry.Count,
                        StackLimit = entry.StackLimit,
                })
        end

        return entries
end

function QuickbarServer.BuildState(data: any?, inventory: any?): QuickbarState
        local resolvedData = if typeof(data) == "table" then data else {}
        local resolvedInventory = if typeof(inventory) == "table" then inventory else {}

        local state: QuickbarState = {
                coins = if typeof(resolvedData.Coins) == "number" then resolvedData.Coins else 0,
                melee = {},
                tokens = {},
        }

        state.melee = buildMeleeEntries(resolvedInventory)
        state.tokens = buildTokenEntries(resolvedInventory)

        return state
end

function QuickbarServer.EquipMelee(player: Player, meleeId: string): (QuickbarState?, string?)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return nil, "InvalidPlayer"
        end

        if typeof(meleeId) ~= "string" or meleeId == "" then
                return nil, "InvalidMelee"
        end

        local item = getShopItem(meleeId)
        if item then
                local kind = item.Kind
                if typeof(kind) ~= "string" or string.lower(kind) ~= "melee" then
                        return nil, "NotMelee"
                end
        elseif DEFAULT_MELEE ~= meleeId then
                return nil, "UnknownMelee"
        end

        local data, inventory = resolveFromProfileServer(player)
        if not data or not inventory then
                return nil, "ProfileUnavailable"
        end

        if typeof(inventory.MeleeLoadout) ~= "table" then
                inventory.MeleeLoadout = {}
        end
        if typeof(inventory.OwnedMelee) ~= "table" then
                inventory.OwnedMelee = {}
        end

        local loadout = inventory.MeleeLoadout :: {string}
        local ownedMap = inventory.OwnedMelee

        local isOwned = false
        for _, existing in ipairs(loadout) do
                if existing == meleeId then
                        isOwned = true
                        break
                end
        end

        if not isOwned and typeof(ownedMap) == "table" then
                if ownedMap[meleeId] then
                        isOwned = true
                end
        end

        if not isOwned and typeof(DEFAULT_MELEE) == "string" and DEFAULT_MELEE ~= "" then
                if meleeId == DEFAULT_MELEE then
                        isOwned = true
                end
        end

        if not isOwned then
                return nil, "NotOwned"
        end

        if typeof(ownedMap) == "table" then
                ownedMap[meleeId] = true
        end

        insertUniqueString(loadout, meleeId)
        inventory.ActiveMelee = meleeId

        local newState = QuickbarServer.Refresh(player, data, inventory)
        if not newState then
                return nil, "RefreshFailed"
        end

        return newState, nil
end

function QuickbarServer.RegisterInventoryResolver(resolver: ((Player) -> (any?, any?))?)
        if typeof(resolver) == "function" then
                inventoryResolver = resolver
        else
                inventoryResolver = nil
        end
end

function QuickbarServer.Refresh(player: Player, data: any?, inventory: any?): QuickbarState?
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return nil
        end

        local resolvedData, resolvedInventory = resolveDataAndInventory(player, data, inventory)
        local state = QuickbarServer.BuildState(resolvedData, resolvedInventory)
        lastStates[player] = state

        if Remotes.RE_QuickbarUpdate then
                Remotes.RE_QuickbarUpdate:FireClient(player, state)
        end

        return state
end

function QuickbarServer.RefreshAll(arenaId: any?)
        if arenaId ~= nil then
                for _, player in ipairs(Players:GetPlayers()) do
                        if player:GetAttribute("ArenaId") == arenaId then
                                QuickbarServer.Refresh(player)
                        end
                end
                return
        end

        for _, player in ipairs(Players:GetPlayers()) do
                QuickbarServer.Refresh(player)
        end
end

function QuickbarServer.GetState(player: Player): QuickbarState?
        return lastStates[player]
end

function QuickbarServer.GetTokenSlot(player: Player, slotIndex: number): QuickbarTokenEntry?
        if typeof(slotIndex) ~= "number" or slotIndex < 1 then
                return nil
        end
        if not tokensEnabled then
                return nil
        end
        local state = lastStates[player]
        if not state then
                return nil
        end
        local tokens = state.tokens
        if typeof(tokens) ~= "table" then
                return nil
        end
        return tokens[slotIndex]
end

function QuickbarServer.IsEnabled(): boolean
        return true
end

applyTokensFlag(resolveTokensFlag())

if FlagsModule and typeof((FlagsModule :: any).OnChanged) == "function" then
        (FlagsModule :: any).OnChanged("Tokens", function(isEnabled)
                applyTokensFlag(isEnabled)
        end)
end

local function onPlayerAdded(player: Player)
        task.defer(function()
                QuickbarServer.Refresh(player)
        end)
end

local function onPlayerRemoving(player: Player)
        lastStates[player] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, existing in ipairs(Players:GetPlayers()) do
        task.defer(function()
                QuickbarServer.Refresh(existing)
        end)
end

print("[QuickbarServer] Ready (authoritative quickbar state)")

return QuickbarServer
