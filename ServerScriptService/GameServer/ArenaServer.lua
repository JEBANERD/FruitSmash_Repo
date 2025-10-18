local ArenaServer = {}

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local ARENA_FOLDER_NAME = "Arenas"
local BASE_TEMPLATE_NAME = "BaseArena"

local arenaStates = {}

local function getArenasFolder()
    local folder = Workspace:FindFirstChild(ARENA_FOLDER_NAME)

    if not folder then
        folder = Instance.new("Folder")
        folder.Name = ARENA_FOLDER_NAME
        folder.Parent = Workspace
    end

    return folder
end

local function getBaseArenaTemplate()
    local templatesFolder = ServerStorage:WaitForChild("ArenaTemplates")
    local template = templatesFolder:FindFirstChild(BASE_TEMPLATE_NAME)

    if not template then
        error(string.format("Base arena template '%s' is missing", BASE_TEMPLATE_NAME))
    end

    return template
end

local function gatherLanes(arenaInstance)
    local lanesFolder = arenaInstance:FindFirstChild("Lanes")
    local lanes = {}

    if lanesFolder then
        for _, lane in ipairs(lanesFolder:GetChildren()) do
            table.insert(lanes, lane)
        end
    end

    return lanes
end

function ArenaServer.SpawnArena(partyId)
    local arenaId = HttpService:GenerateGUID(false)
    local arenasFolder = getArenasFolder()
    local template = getBaseArenaTemplate()

    local arena = template:Clone()
    arena.Name = string.format("Arena_%s", arenaId)
    arena:SetAttribute("ArenaId", arenaId)
    arena:SetAttribute("PartyId", partyId)
    arena.Parent = arenasFolder

    local state = {
        id = arenaId,
        partyId = partyId,
        instance = arena,
        level = 1,
        wave = 1,
        lanes = gatherLanes(arena),
    }

    arenaStates[arenaId] = state

    return arenaId
end

function ArenaServer.DespawnArena(arenaId)
    local state = arenaStates[arenaId]
    if not state then
        return
    end

    local arena = state.instance
    if arena then
        arena:Destroy()
    end

    arenaStates[arenaId] = nil
end

function ArenaServer.GetArenaState(arenaId)
    return arenaStates[arenaId]
end

function ArenaServer.GetAllArenas()
    return arenaStates
end

return ArenaServer
