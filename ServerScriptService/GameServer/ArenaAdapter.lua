local ArenaAdapter = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local arenaModule = ServerScriptService:WaitForChild("GameServer"):FindFirstChild("ArenaServer")
local ArenaServer = arenaModule and require(arenaModule)

local LaneConfig = GameConfig.Lanes or {}

local function getArenaState(arenaId)
    if not ArenaServer or type(ArenaServer.GetArenaState) ~= "function" then
        return nil
    end

    local ok, state = pcall(ArenaServer.GetArenaState, arenaId)
    if ok then
        return state
    end

    return nil
end

function ArenaAdapter.GetLevel(arenaId)
    local state = getArenaState(arenaId)
    if state then
        if typeof(state.level) == "number" then
            return state.level
        end
        if typeof(state.Level) == "number" then
            return state.Level
        end
    end

    return 1
end

local function resolveLaneCountFromState(state)
    if not state then
        return nil
    end

    if typeof(state.activeLanes) == "number" then
        return state.activeLanes
    end

    if typeof(state.laneCount) == "number" then
        return state.laneCount
    end

    local lanes = state.lanes
    if typeof(lanes) == "table" then
        local count = 0
        for _, lane in pairs(lanes) do
            if lane ~= nil then
                count += 1
            end
        end
        if count > 0 then
            return count
        end
    end

    return nil
end

function ArenaAdapter.GetLaneCount(arenaId)
    local state = getArenaState(arenaId)
    local count = resolveLaneCountFromState(state)

    if typeof(count) ~= "number" then
        count = LaneConfig.StartCount or 0
    end

    return math.max(count, 0)
end

function ArenaAdapter.GetLaneIds(arenaId)
    local laneCount = ArenaAdapter.GetLaneCount(arenaId)
    local lanes = table.create(laneCount)

    for index = 1, laneCount do
        lanes[index] = index
    end

    return lanes
end

return ArenaAdapter
