--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local ShopConfig = require(configFolder:WaitForChild("ShopConfig"))
local ShopServer = require(script.Parent:WaitForChild("ShopServer"))

local gachaConfig = ShopConfig.Gacha or {}
local outcomeTable = gachaConfig.Table or {}

local SpinsPerLevelCap = gachaConfig.SpinsPerLevelCap or 0
local SPIN_CAP = SpinsPerLevelCap > 0 and SpinsPerLevelCap or math.huge

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

local RF_SpinGacha = getOrCreateRemote("RF_SpinGacha", "RemoteFunction") :: RemoteFunction

local cachedArenaServer

local function getArenaServer()
    if cachedArenaServer ~= nil then
        return cachedArenaServer
    end

    local arenaModule = script.Parent.Parent:FindFirstChild("ArenaServer")
    if not arenaModule then
        cachedArenaServer = false
        return nil
    end

    local ok, result = pcall(require, arenaModule)
    if not ok then
        warn(string.format("[MeleeGachaServer] Failed to require ArenaServer: %s", tostring(result)))
        cachedArenaServer = false
        return nil
    end

    cachedArenaServer = result
    return cachedArenaServer
end

type SpinState = { level: number, spins: number }

local playerSpins: {[Player]: SpinState} = {}

local rng = Random.new()

local function resolveOutcome(): string?
    if #outcomeTable == 0 then
        return nil
    end

    local totalWeight = 0
    for _, entry in ipairs(outcomeTable) do
        totalWeight += entry.Weight or 0
    end

    if totalWeight <= 0 then
        return nil
    end

    local roll = rng:NextNumber() * totalWeight
    local cumulative = 0

    for _, entry in ipairs(outcomeTable) do
        local weight = entry.Weight or 0
        cumulative += weight
        if roll <= cumulative then
            return entry.ItemId
        end
    end

    local last = outcomeTable[#outcomeTable]
    return last and last.ItemId or nil
end

local function resolvePlayerLevel(player: Player): number
    local candidateAttributes = { "Level", "ArenaLevel", "HighestLevel", "CurrentLevel" }

    for _, attributeName in ipairs(candidateAttributes) do
        local value = player:GetAttribute(attributeName)
        if typeof(value) == "number" and value > 0 then
            return math.floor(value)
        end
    end

    local arenaIdValue = player:GetAttribute("ArenaId")
    if typeof(arenaIdValue) == "string" and arenaIdValue ~= "" then
        local arenaServer = getArenaServer()
        if arenaServer and typeof(arenaServer.GetArenaState) == "function" then
            local ok, arenaState = pcall(arenaServer.GetArenaState, arenaIdValue)
            if ok and arenaState and typeof(arenaState.level) == "number" then
                return math.max(math.floor(arenaState.level), 1)
            end
        end
    end

    return 1
end

local function getSpinState(player: Player, level: number): SpinState
    local state = playerSpins[player]

    if not state or state.level ~= level then
        state = { level = level, spins = 0 }
        playerSpins[player] = state
    end

    return state
end

local function fetchItem(itemId: string)
    if typeof(ShopConfig.Get) == "function" then
        local ok, item = pcall(ShopConfig.Get, itemId)
        if ok and item then
            return item
        end
    end

    local items = ShopConfig.Items or {}
    return items[itemId]
end

local function addMeleeToInventory(player: Player, itemId: string)
    local profile, data, inventory = ShopServer.GetProfileAndInventory(player)
    if not profile or not data or not inventory then
        return false, "InventoryUnavailable"
    end

    local item = fetchItem(itemId)
    if not item then
        return false, "UnknownItem"
    end

    local ok, reason = ShopServer.ApplyMeleeToInventory(inventory, item)
    if not ok then
        return false, reason or "ApplyFailed"
    end

    ShopServer.MarkProfileDirty(player, profile)
    ShopServer.UpdateQuickbarForPlayer(player, data, inventory)

    return true
end

local function processSpin(player: Player)
    local response = {
        ok = false,
    }

    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        response.reason = "InvalidPlayer"
        return response
    end

    local level = resolvePlayerLevel(player)
    local state = getSpinState(player, level)

    if state.spins >= SPIN_CAP then
        response.reason = "SpinCapReached"
        return response
    end

    local outcomeId = resolveOutcome()
    if not outcomeId then
        response.reason = "NoOutcome"
        return response
    end

    state.spins += 1

    if outcomeId == "Nothing" then
        response.ok = true
        response.whiff = true
        return response
    end

    local success, reason = addMeleeToInventory(player, outcomeId)
    if not success then
        if reason == "AlreadyOwned" then
            response.ok = true
            response.whiff = true
            return response
        end

        response.reason = reason
        return response
    end

    response.ok = true
    response.itemId = outcomeId
    return response
end

local MeleeGachaServer = {}
local initialized = false

local function handleSpin(player: Player)
    return processSpin(player)
end

function MeleeGachaServer.Init()
    if initialized then
        return
    end
    initialized = true

    RF_SpinGacha.OnServerInvoke = handleSpin

    Players.PlayerRemoving:Connect(function(player)
        playerSpins[player] = nil
    end)

    print("[MeleeGachaServer] Initialized")
end

MeleeGachaServer.Init()

return MeleeGachaServer

