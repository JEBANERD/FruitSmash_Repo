--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local remotesModule = remotesFolder:WaitForChild("RemoteBootstrap")

local Remotes = require(remotesModule)
local toastRemote: RemoteEvent? = Remotes and Remotes.RE_AchievementToast or nil

local FlagsModule
do
    local ok, module = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Flags"))
    end)
    if ok and typeof(module) == "table" then
        FlagsModule = module
    end
end

local function resolveAchievementsFlag(): boolean
    if FlagsModule and typeof((FlagsModule :: any).IsEnabled) == "function" then
        local ok, result = pcall((FlagsModule :: any).IsEnabled, "Achievements")
        if ok and typeof(result) == "boolean" then
            return result
        end
    end
    return true
end

local SPEEDRUNNER_THRESHOLD_SECONDS = 120
local MIN_POINTS_FOR_MVP = 1

local AchievementId = {
    MVP = "MVP",
    Untouched = "Untouched",
    Speedrunner = "Speedrunner",
}

local ACHIEVEMENTS: { [string]: { id: string, title: string, message: string } } = {
    [AchievementId.MVP] = {
        id = AchievementId.MVP,
        title = "MVP",
        message = "Highest points this level.",
    },
    [AchievementId.Untouched] = {
        id = AchievementId.Untouched,
        title = "Untouched",
        message = "Clear a level without any lane damage.",
    },
    [AchievementId.Speedrunner] = {
        id = AchievementId.Speedrunner,
        title = "Speedrunner",
        message = string.format("Clear a level in under %d seconds.", SPEEDRUNNER_THRESHOLD_SECONDS),
    },
}

type Player = Player
type ArenaState = {
    arenaId: any,
    level: number?,
    startedAt: number?,
    lanesUntouched: boolean,
    damagedLanes: { [number]: boolean }?,
    players: { Player }?,
}

local activeArenas: { [string]: ArenaState } = {}
local awardedAchievements: { [Player]: { [string]: boolean } } = {}

local achievementsEnabled = true

local function applyAchievementsFlag(state: any)
    local newState = false
    if typeof(state) == "boolean" then
        newState = state
    elseif typeof(state) == "number" then
        newState = state ~= 0
    end

    achievementsEnabled = newState
    if not achievementsEnabled then
        table.clear(awardedAchievements)
    end
end

local AchievementServer = {}

local function getArenaKey(arenaId: any): string?
    if arenaId == nil then
        return nil
    end

    local valueType = typeof(arenaId)
    if valueType == "number" then
        return "num:" .. tostring(arenaId)
    elseif valueType == "string" then
        return "str:" .. arenaId
    elseif valueType == "boolean" then
        return "bool:" .. tostring(arenaId)
    end

    return tostring(arenaId)
end

local function sanitizeNumber(value: any): number
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric then
        return 0
    end
    return numeric
end

local function sanitizePlayerList(list: any): { Player }
    local sanitized: { Player } = {}
    if typeof(list) ~= "table" then
        return sanitized
    end

    local seen: { [Player]: boolean } = {}

    if #list > 0 then
        for index = 1, #list do
            local entry = list[index]
            if typeof(entry) == "Instance" and entry:IsA("Player") and entry.Parent == Players then
                if not seen[entry] then
                    table.insert(sanitized, entry)
                    seen[entry] = true
                end
            end
        end
    end

    for key, value in pairs(list) do
        local candidate: Player? = nil
        if typeof(key) == "Instance" and key:IsA("Player") then
            candidate = key
        elseif typeof(value) == "Instance" and value:IsA("Player") then
            candidate = value
        end

        if candidate and candidate.Parent == Players and not seen[candidate] then
            table.insert(sanitized, candidate)
            seen[candidate] = true
        end
    end

    return sanitized
end

local function grantAchievement(player: Player, achievementId: string, overrides: { title: string?, message: string? }?)
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return
    end

    if not achievementsEnabled then
        return
    end

    local definition = ACHIEVEMENTS[achievementId]
    if not definition then
        return
    end

    local awarded = awardedAchievements[player]
    if not awarded then
        awarded = {}
        awardedAchievements[player] = awarded
    end

    if awarded[achievementId] then
        return
    end

    awarded[achievementId] = true

    if not toastRemote then
        return
    end

    local payload = {
        id = definition.id,
        title = overrides and overrides.title or definition.title,
        message = overrides and overrides.message or definition.message,
    }

    local ok, err = pcall(function()
        toastRemote:FireClient(player, payload)
    end)

    if not ok then
        warn(string.format("[AchievementServer] Failed to dispatch achievement '%s': %s", tostring(achievementId), tostring(err)))
    end
end

local function resolveDuration(levelInfo: { [string]: any }?, state: ArenaState?): number?
    if levelInfo then
        local directDuration = levelInfo.duration or levelInfo.Duration
        if typeof(directDuration) == "number" and directDuration >= 0 then
            return directDuration
        end

        local startedAt = levelInfo.startedAt or levelInfo.StartedAt
        local finishedAt = levelInfo.finishedAt or levelInfo.FinishedAt or os.clock()
        if typeof(startedAt) == "number" then
            return math.max(0, finishedAt - startedAt)
        end
    end

    if state and typeof(state.startedAt) == "number" then
        return math.max(0, os.clock() - state.startedAt)
    end

    return nil
end

local function computeMvpWinners(perPlayerStats: any, participantSet: { [Player]: boolean }): ({ Player }, number?)
    local winners: { Player } = {}
    local topPoints: number? = nil

    if typeof(perPlayerStats) ~= "table" then
        return winners, topPoints
    end

    for player, stats in pairs(perPlayerStats) do
        if typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players and participantSet[player] then
            local pointsValue = 0
            if typeof(stats) == "table" then
                local candidate = stats.points
                if candidate == nil then
                    candidate = stats.Points
                end
                if candidate == nil then
                    candidate = stats.score or stats.Score
                end
                pointsValue = sanitizeNumber(candidate)
            end

            if pointsValue > 0 then
                if not topPoints or pointsValue > topPoints then
                    topPoints = pointsValue
                    table.clear(winners)
                    table.insert(winners, player)
                elseif pointsValue == topPoints then
                    table.insert(winners, player)
                end
            end
        end
    end

    return winners, topPoints
end

function AchievementServer.BeginLevel(arenaId: any, level: number?, players: { Player }?, startedAt: number?)
    local key = getArenaKey(arenaId)
    if not key then
        return
    end

    local sanitizedPlayers = sanitizePlayerList(players)
    local state: ArenaState = {
        arenaId = arenaId,
        level = typeof(level) == "number" and level or nil,
        startedAt = typeof(startedAt) == "number" and startedAt or os.clock(),
        lanesUntouched = true,
        damagedLanes = {},
        players = sanitizedPlayers,
    }

    activeArenas[key] = state
end

function AchievementServer.UpdateParticipants(arenaId: any, players: { Player }?)
    local key = getArenaKey(arenaId)
    if not key then
        return
    end

    local state = activeArenas[key]
    if not state then
        return
    end

    state.players = sanitizePlayerList(players)
end

function AchievementServer.RecordLaneDamage(arenaId: any, laneId: any)
    local key = getArenaKey(arenaId)
    if not key then
        return
    end

    local state = activeArenas[key]
    if not state then
        state = {
            arenaId = arenaId,
            lanesUntouched = false,
            damagedLanes = {},
        }
        activeArenas[key] = state
    end

    state.lanesUntouched = false

    if typeof(laneId) == "number" then
        local lanes = state.damagedLanes or {}
        lanes[laneId] = true
        state.damagedLanes = lanes
    end
end

function AchievementServer.HandleLevelComplete(arenaId: any, outcome: string?, players: { Player }?, perPlayerStats: any, levelInfo: { [string]: any }?)
    local key = getArenaKey(arenaId)
    if not key then
        return
    end

    local state = activeArenas[key]

    local participants = sanitizePlayerList(players)
    if #participants == 0 and state and state.players then
        participants = sanitizePlayerList(state.players)
    end

    local participantSet: { [Player]: boolean } = {}
    for _, player in ipairs(participants) do
        participantSet[player] = true
    end

    if outcome ~= "victory" then
        activeArenas[key] = nil
        return
    end

    if #participants == 0 then
        activeArenas[key] = nil
        return
    end

    if state then
        state.players = participants
    end

    if state and state.lanesUntouched then
        for _, player in ipairs(participants) do
            grantAchievement(player, AchievementId.Untouched, nil)
        end
    end

    local duration = resolveDuration(levelInfo, state)
    if duration and duration <= SPEEDRUNNER_THRESHOLD_SECONDS then
        local formatted = string.format("Cleared in %.1f seconds!", duration)
        for _, player in ipairs(participants) do
            grantAchievement(player, AchievementId.Speedrunner, { message = formatted })
        end
    end

    local winners, topPoints = computeMvpWinners(perPlayerStats, participantSet)
    if topPoints and topPoints >= MIN_POINTS_FOR_MVP then
        local message = string.format("Highest points this level (%d)", math.floor(topPoints + 0.5))
        for _, player in ipairs(winners) do
            grantAchievement(player, AchievementId.MVP, { message = message })
        end
    end

    activeArenas[key] = nil
end

function AchievementServer.ResetArena(arenaId: any)
    local key = getArenaKey(arenaId)
    if not key then
        return
    end

    activeArenas[key] = nil
end

applyAchievementsFlag(resolveAchievementsFlag())

if FlagsModule and typeof((FlagsModule :: any).OnChanged) == "function" then
    (FlagsModule :: any).OnChanged("Achievements", function(isEnabled)
        applyAchievementsFlag(isEnabled)
    end)
end

Players.PlayerRemoving:Connect(function(player)
    awardedAchievements[player] = nil
end)

return AchievementServer
