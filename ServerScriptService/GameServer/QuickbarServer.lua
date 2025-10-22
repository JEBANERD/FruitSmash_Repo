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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local ShopConfig = require(configFolder:WaitForChild("ShopConfig"))
local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = GameConfigModule.Get()

local quickbarConfig = (GameConfig.UI and GameConfig.UI.Quickbar) or {}
local MELEE_SLOTS = quickbarConfig.MeleeSlots or 2
local TOKEN_SLOTS = quickbarConfig.TokenSlots or 3
local DEFAULT_MELEE = (GameConfig.Melee and GameConfig.Melee.DefaultWeapon) or nil

local shopItems = (type(ShopConfig.All) == "function" and ShopConfig.All()) or ShopConfig.Items or {}

export type QuickbarMeleeEntry = { Id: string, Active: boolean }
export type QuickbarTokenEntry = { Id: string, Count: number, StackLimit: number? }
export type QuickbarState = {
        coins: number?,
        melee: { QuickbarMeleeEntry? },
        tokens: { QuickbarTokenEntry? },
}

local QuickbarServer = {}

local profileServer: any? = nil

local function safeRequire(moduleScript: Instance?): any?
        if not moduleScript or not moduleScript:IsA("ModuleScript") then
                return nil
        end

        local ok, result = pcall(require, moduleScript)
        if not ok then
                warn(string.format("[QuickbarServer] Failed to require %s: %s", moduleScript:GetFullName(), tostring(result)))
                return nil
        end

        return result
end

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

for _, parts in ipairs(profileCandidates) do
        local inst = findFirstChildPath(ServerScriptService, parts)
        local candidate = safeRequire(inst)
        if candidate then
                profileServer = candidate
                break
        end
end

local inventoryResolver: ((Player) -> (any?, any?))? = nil
local lastStates: {[Player]: QuickbarState} = {}

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
        if not profileServer then
                return nil
        end

        local method = (profileServer :: any)[methodName]
        if type(method) ~= "function" then
                return nil
        end

        local ok, r1, r2, r3 = pcall(method, profileServer, player)
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

        if inventoryResolver then
                local ok, resolvedData, resolvedInventory = pcall(inventoryResolver, player)
                if ok and resolvedData and resolvedInventory then
                        return resolvedData, resolvedInventory
                end
        end

        local profileData, profileInventory = resolveFromProfileServer(player)
        if profileData and profileInventory then
                return profileData, profileInventory
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

        return entries
end

local function buildTokenEntries(inventory: any): {QuickbarTokenEntry}
        local entries: {QuickbarTokenEntry} = {}
        local tokensMap = (typeof(inventory) == "table" and inventory.TokenCounts) or nil
        if typeof(tokensMap) ~= "table" then
                return entries
        end

        local sortable = {}
        for tokenId, count in pairs(tokensMap) do
                if typeof(tokenId) == "string" then
                        local numericCount = if typeof(count) == "number" then count else tonumber(count) or 0
                        if numericCount > 0 then
                                table.insert(sortable, {
                                        Id = tokenId,
                                        Count = numericCount,
                                })
                        end
                end
        end

        table.sort(sortable, function(a, b)
                return a.Id < b.Id
        end)

        for _, entry in ipairs(sortable) do
                if #entries >= TOKEN_SLOTS then
                        break
                end
                local stackLimit = nil
                local item = shopItems[entry.Id]
                if item and typeof(item.StackLimit) == "number" then
                        stackLimit = item.StackLimit
                end
                table.insert(entries, {
                        Id = entry.Id,
                        Count = entry.Count,
                        StackLimit = stackLimit,
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
