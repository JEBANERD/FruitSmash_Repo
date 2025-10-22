--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TAG = "[MatchArrival]"

local noticeRemote: RemoteEvent? = nil

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if remotesFolder then
    local bootstrap = remotesFolder:FindFirstChild("RemoteBootstrap")
    if bootstrap and bootstrap:IsA("ModuleScript") then
        local ok, result = pcall(require, bootstrap)
        if ok then
            local candidate = (result :: any).RE_Notice
            if candidate and typeof(candidate.FireClient) == "function" then
                noticeRemote = candidate
            end
        else
            warn(string.format("%s Failed to require RemoteBootstrap: %s", TAG, tostring(result)))
        end
    end
end

local function safeRequire(parent: Instance?, name: string)
    if not parent then
        return nil
    end

    local module = parent:FindFirstChild(name)
    if not module then
        warn(string.format("%s Missing module %s", TAG, name))
        return nil
    end

    local ok, result = pcall(require, module)
    if not ok then
        warn(string.format("%s Failed to require %s: %s", TAG, name, tostring(result)))
        return nil
    end

    return result
end

local gameServerFolder = ServerScriptService:FindFirstChild("GameServer")

local ArenaServer = safeRequire(gameServerFolder, "ArenaServer")
local RoundDirectorServer = safeRequire(gameServerFolder, "RoundDirectorServer")
local QuickbarServer = safeRequire(gameServerFolder, "QuickbarServer")

local playerContexts: { [Player]: { partyId: string, arenaId: string, connection: RBXScriptConnection? } } = {}

local function toStringId(value: any): string?
    local valueType = typeof(value)
    if valueType == "string" then
        if value == "" then
            return nil
        end
        return value
    elseif valueType == "number" or valueType == "boolean" then
        return tostring(value)
    end

    return nil
end

local function extractPartyId(data: any): string?
    if typeof(data) ~= "table" then
        return nil
    end

    local keys = { "partyId", "PartyId", "partyID", "PartyID", "party_id", "Party_id" }
    for _, key in ipairs(keys) do
        local value = data[key]
        local str = toStringId(value)
        if str then
            return str
        end
    end

    local nested = data.party or data.Party
    if typeof(nested) == "table" then
        local fromNested = extractPartyId(nested)
        if fromNested then
            return fromNested
        end

        local id = nested.id or nested.Id or nested.partyId or nested.PartyId
        local str = toStringId(id)
        if str then
            return str
        end
    end

    return nil
end

local function extractArenaId(data: any): string?
    if typeof(data) ~= "table" then
        return nil
    end

    local keys = { "arenaId", "ArenaId", "arenaID", "ArenaID", "arena_id", "Arena_id" }
    for _, key in ipairs(keys) do
        local str = toStringId(data[key])
        if str then
            return str
        end
    end

    return nil
end

local function findArenaByParty(partyId: string): (string?, any)
    if not ArenaServer then
        return nil, nil
    end

    local getAll = (ArenaServer :: any).GetAllArenas
    if typeof(getAll) ~= "function" then
        return nil, nil
    end

    local arenas = getAll()
    if typeof(arenas) ~= "table" then
        return nil, nil
    end

    for arenaKey, arenaState in pairs(arenas) do
        if typeof(arenaState) == "table" then
            local stateParty = arenaState.partyId or arenaState.PartyId
            if not stateParty then
                local instance = arenaState.instance
                if typeof(instance) == "Instance" then
                    stateParty = instance:GetAttribute("PartyId")
                end
            end

            local statePartyStr = toStringId(stateParty)
            if statePartyStr and statePartyStr == partyId then
                local arenaId = toStringId(arenaKey)
                if not arenaId then
                    local instance = arenaState.instance
                    if typeof(instance) == "Instance" then
                        arenaId = toStringId(instance:GetAttribute("ArenaId"))
                    end
                end

                arenaId = arenaId or tostring(arenaKey)
                return arenaId, arenaState
            end
        end
    end

    return nil, nil
end

local function resolveArena(partyId: string, explicitArenaId: string?): (string?, any)
    local arenaId = explicitArenaId
    local arenaState: any = nil

    if arenaId and ArenaServer then
        local getState = (ArenaServer :: any).GetArenaState
        if typeof(getState) == "function" then
            arenaState = getState(arenaId)
            if not arenaState then
                arenaId = nil
            end
        end
    end

    if (not arenaId) and partyId ~= nil then
        arenaId, arenaState = findArenaByParty(partyId)
    end

    return arenaId, arenaState
end

local function canJoinArena(arenaId: string?): (boolean, string?)
    if not arenaId or not RoundDirectorServer then
        return true, nil
    end

    local getState = (RoundDirectorServer :: any).GetState
    if typeof(getState) ~= "function" then
        return true, nil
    end

    local ok, state = pcall(getState, arenaId)
    if not ok then
        warn(string.format("%s GetState failed for arena %s: %s", TAG, tostring(arenaId), tostring(state)))
        return true, nil
    end

    if typeof(state) ~= "table" then
        return true, nil
    end

    local phase = state.phase
    if phase == nil or phase == "Prep" then
        return true, nil
    end

    return false, toStringId(phase) or tostring(phase)
end

local function notifyPlayer(player: Player, message: string)
    if noticeRemote then
        local payload = {
            msg = message,
            kind = "warning",
        }
        noticeRemote:FireClient(player, payload)
    end
end

local function findSpawnTarget(instance: Instance): Instance?
    local patterns = { "spawn", "start", "entry", "platform" }

    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local lowerName = string.lower(descendant.Name)
            for _, pattern in ipairs(patterns) do
                if string.find(lowerName, pattern, 1, true) then
                    return descendant
                end
            end

            if descendant:GetAttribute("Spawn") or descendant:GetAttribute("PlayerSpawn") then
                return descendant
            end
        elseif descendant:IsA("Attachment") then
            local lowerName = string.lower(descendant.Name)
            for _, pattern in ipairs(patterns) do
                if string.find(lowerName, pattern, 1, true) then
                    return descendant
                end
            end
        end
    end

    local primary = instance:FindFirstChildWhichIsA("BasePart")
    if primary then
        return primary
    end

    return instance
end

local function computeSpawnCFrame(arenaState: any): CFrame?
    if typeof(arenaState) ~= "table" then
        return nil
    end

    local instance = arenaState.instance
    if typeof(instance) ~= "Instance" then
        return nil
    end

    local target = findSpawnTarget(instance)
    if not target then
        return nil
    end

    if target:IsA("BasePart") then
        return target.CFrame
    elseif target:IsA("Attachment") then
        return target.WorldCFrame
    elseif typeof((target :: any).GetPivot) == "function" then
        local ok, pivot = pcall((target :: any).GetPivot, target)
        if ok then
            return pivot
        end
    end

    if typeof((instance :: any).GetPivot) == "function" then
        local ok, pivot = pcall((instance :: any).GetPivot, instance)
        if ok then
            return pivot
        end
    end

    return nil
end

local function moveCharacterToSpawn(player: Player, context: { partyId: string, arenaId: string, connection: RBXScriptConnection? })
    if not ArenaServer then
        return
    end

    local getState = (ArenaServer :: any).GetArenaState
    if typeof(getState) ~= "function" then
        return
    end

    local arenaState = getState(context.arenaId)
    if not arenaState then
        return
    end

    local spawnCFrame = computeSpawnCFrame(arenaState)
    if not spawnCFrame then
        return
    end

    local character = player.Character
    if not character then
        return
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then
        local ok, result = pcall(function()
            return character:WaitForChild("HumanoidRootPart", 5)
        end)
        if ok then
            root = result
        end
    end

    if typeof((character :: any).PivotTo) == "function" then
        (character :: any):PivotTo(spawnCFrame * CFrame.new(0, 3, 0))
        return
    end

    if root and root:IsA("BasePart") then
        root.CFrame = spawnCFrame * CFrame.new(0, 3, 0)
    end
end

local function registerArenaPlayer(arenaState: any, player: Player)
    if typeof(arenaState) ~= "table" then
        return
    end

    if typeof(arenaState.players) ~= "table" then
        arenaState.players = {}
    end

    local playersList = arenaState.players
    for _, entry in ipairs(playersList) do
        if entry == player then
            return
        end
        if typeof(entry) == "table" then
            local value = entry.player or entry.Player or entry.owner
            if value == player then
                return
            end
        end
    end

    table.insert(playersList, player)
end

local function deregisterArenaPlayer(context: { partyId: string, arenaId: string, connection: RBXScriptConnection? }, player: Player)
    if not ArenaServer then
        return
    end

    local getState = (ArenaServer :: any).GetArenaState
    if typeof(getState) ~= "function" then
        return
    end

    local arenaState = getState(context.arenaId)
    if typeof(arenaState) ~= "table" then
        return
    end

    local playersList = arenaState.players
    if typeof(playersList) ~= "table" then
        return
    end

    for index = #playersList, 1, -1 do
        local entry = playersList[index]
        if entry == player then
            table.remove(playersList, index)
        elseif typeof(entry) == "table" then
            local value = entry.player or entry.Player or entry.owner
            if value == player then
                table.remove(playersList, index)
            end
        end
    end
end

local function refreshQuickbar(player: Player)
    if not QuickbarServer then
        return
    end

    local refresh = (QuickbarServer :: any).Refresh
    if typeof(refresh) ~= "function" then
        return
    end

    local ok, err = pcall(refresh, player)
    if not ok then
        warn(string.format("%s Quickbar refresh failed for %s: %s", TAG, player.Name, tostring(err)))
    end
end

local function trackCharacter(player: Player)
    local context = playerContexts[player]
    if not context then
        return
    end

    task.defer(function()
        moveCharacterToSpawn(player, context)
    end)
end

local function handlePlayerAdded(player: Player)
    local joinData
    local ok, result = pcall(function()
        return player:GetJoinData()
    end)
    if ok then
        joinData = result
    else
        warn(string.format("%s Failed to read join data for %s: %s", TAG, player.Name, tostring(result)))
    end

    local teleportData = nil
    if typeof(joinData) == "table" then
        teleportData = joinData.TeleportData
    end

    local partyId = extractPartyId(teleportData) or extractPartyId(joinData)
    if not partyId then
        return
    end

    local explicitArenaId = extractArenaId(teleportData) or extractArenaId(joinData)
    local arenaId, arenaState = resolveArena(partyId, explicitArenaId)
    if not arenaId then
        warn(string.format("%s %s joined party %s but no arena was found", TAG, player.Name, partyId))
        return
    end

    local allowed, phase = canJoinArena(arenaId)
    if not allowed then
        local message = string.format("Match already in progress (phase: %s).", phase or "unknown")
        notifyPlayer(player, message)
        task.defer(function()
            player:Kick(message)
        end)
        return
    end

    local context = {
        partyId = partyId,
        arenaId = arenaId,
        connection = nil,
    }

    playerContexts[player] = context

    player:SetAttribute("PartyId", partyId)
    player:SetAttribute("ArenaId", arenaId)

    if not arenaState and ArenaServer then
        local getState = (ArenaServer :: any).GetArenaState
        if typeof(getState) == "function" then
            arenaState = getState(arenaId)
        end
    end

    if arenaState then
        registerArenaPlayer(arenaState, player)
    end

    if context.connection then
        context.connection:Disconnect()
    end

    context.connection = player.CharacterAdded:Connect(function()
        trackCharacter(player)
    end)

    if player.Character then
        trackCharacter(player)
    end

    refreshQuickbar(player)
end

local function handlePlayerRemoving(player: Player)
    local context = playerContexts[player]
    if not context then
        return
    end

    if context.connection then
        context.connection:Disconnect()
        context.connection = nil
    end

    deregisterArenaPlayer(context, player)
    playerContexts[player] = nil
end

Players.PlayerAdded:Connect(function(player)
    task.spawn(handlePlayerAdded, player)
end)

Players.PlayerRemoving:Connect(handlePlayerRemoving)
