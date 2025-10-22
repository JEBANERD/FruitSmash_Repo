local ArenaAdapter = {}

local arenaServerModule = script.Parent:FindFirstChild("ArenaServer")
if not arenaServerModule then
    error("[ArenaAdapter] ArenaServer module is missing")
end

local ArenaServer = require(arenaServerModule)

local function freezeTable(tbl)
    if table.freeze then
        table.freeze(tbl)
    end

    return tbl
end

local function copyDictionary(source)
    local result = {}

    for key, value in pairs(source) do
        result[key] = value
    end

    return result
end

local function copyArray(source)
    local result = {}

    for index, value in ipairs(source) do
        result[index] = value
    end

    return result
end

local function snapshotTable(value)
    if type(value) ~= "table" then
        return nil
    end

    local snapshot = copyDictionary(value)

    if type(snapshot.lanes) == "table" then
        snapshot.lanes = freezeTable(copyArray(snapshot.lanes))
    end

    if type(snapshot.targets) == "table" then
        snapshot.targets = freezeTable(copyDictionary(snapshot.targets))
    end

    if type(snapshot.players) == "table" then
        local players = {}

        for key, entry in pairs(snapshot.players) do
            players[key] = entry
        end

        snapshot.players = freezeTable(players)
    end

    return freezeTable(snapshot)
end

local function getArenaState(arenaId)
    if arenaId == nil then
        return nil
    end

    local getState = ArenaServer and ArenaServer.GetArenaState
    if type(getState) ~= "function" then
        return nil
    end

    local ok, state = pcall(getState, arenaId)
    if not ok then
        warn(string.format("[ArenaAdapter] Failed to fetch arena '%s': %s", tostring(arenaId), tostring(state)))
        return nil
    end

    if type(state) ~= "table" then
        return nil
    end

    return state
end

function ArenaAdapter.GetState(arenaId)
    local state = getArenaState(arenaId)
    if not state then
        return nil
    end

    return snapshotTable(state)
end

function ArenaAdapter.GetModel(arenaId)
    local state = getArenaState(arenaId)
    if not state then
        return nil
    end

    return state.instance or state.model or state.arena
end

function ArenaAdapter.GetLanes(arenaId)
    local state = getArenaState(arenaId)
    if not state then
        return nil
    end

    local lanes = state.lanes
    if type(lanes) ~= "table" then
        return nil
    end

    return freezeTable(copyArray(lanes))
end

function ArenaAdapter.GetTargets(arenaId)
    local state = getArenaState(arenaId)
    if not state then
        return nil
    end

    local targets = state.targets
    if type(targets) ~= "table" then
        return nil
    end

    return freezeTable(copyDictionary(targets))
end

function ArenaAdapter.GetPlayers(arenaId)
    local state = getArenaState(arenaId)
    if not state then
        return nil
    end

    local players = state.players
    if type(players) ~= "table" then
        return nil
    end

    local isArray = (#players > 0)

    if isArray then
        return freezeTable(copyArray(players))
    end

    local snapshot = {}
    for key, value in pairs(players) do
        snapshot[key] = value
    end

    return freezeTable(snapshot)
end

return ArenaAdapter

