--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local Remotes = require(remotesFolder:WaitForChild("RemoteBootstrap"))

local HUDServer = {}

local prepRemote = Remotes and Remotes.RE_PrepTimer or nil
local waveRemote = Remotes and Remotes.RE_WaveChanged or nil
local targetRemote = Remotes and Remotes.RE_TargetHP or nil

local function sanitizeArenaId(value: any)
    local valueType = typeof(value)
    if valueType == "string" or valueType == "number" then
        return value
    end

    return nil
end

local function sanitizeSeconds(value: any)
    local numeric = tonumber(value)
    if not numeric then
        return nil
    end

    numeric = math.floor(numeric + 0.5)
    if numeric < 0 then
        numeric = 0
    end

    return numeric
end

local function sanitizeNonNegativeInteger(value: any)
    local numeric = tonumber(value)
    if not numeric then
        return nil
    end

    numeric = math.floor(numeric + 0.5)
    if numeric < 0 then
        numeric = 0
    end

    return numeric
end

local function sanitizePercent(value: any)
    local numeric = tonumber(value)
    if not numeric then
        return nil
    end

    if numeric > 1 then
        -- Allow values provided as percentages (0-100) as well as 0-1.
        if numeric <= 100 then
            numeric /= 100
        end
    end

    if numeric < 0 then
        numeric = 0
    elseif numeric > 1 then
        numeric = 1
    end

    return numeric
end

local function assign(payload: { [string]: any }, key: string, value: any, aliases: { string }?)
    if value == nil then
        return
    end

    payload[key] = value

    if aliases then
        for _, alias in ipairs(aliases) do
            payload[alias] = value
        end
    end
end

function HUDServer.BroadcastPrep(arenaId: any, seconds: any)
    if not prepRemote then
        return
    end

    local sanitizedArenaId = sanitizeArenaId(arenaId)
    local sanitizedSeconds = seconds ~= nil and sanitizeSeconds(seconds) or nil

    local payload = {}
    assign(payload, "arenaId", sanitizedArenaId, { "ArenaId" })
    assign(payload, "seconds", sanitizedSeconds, { "Seconds" })
    assign(payload, "stop", sanitizedSeconds == nil, { "Stop" })

    prepRemote:FireAllClients(payload)
end

function HUDServer.WaveChanged(arenaId: any, wave: any, level: any, phase: any?)
    if not waveRemote then
        return
    end

    local sanitizedArenaId = sanitizeArenaId(arenaId)
    local sanitizedWave = sanitizeNonNegativeInteger(wave)
    local sanitizedLevel = sanitizeNonNegativeInteger(level)

    local payload = {}
    assign(payload, "arenaId", sanitizedArenaId, { "ArenaId" })
    assign(payload, "wave", sanitizedWave, { "Wave", "currentWave", "CurrentWave" })
    assign(payload, "level", sanitizedLevel, { "Level" })

    if phase ~= nil then
        assign(payload, "phase", phase, { "Phase" })
    end

    waveRemote:FireAllClients(payload)
end

function HUDServer.TargetHp(arenaId: any, lane: any, pct: any, extras: { [string]: any }?)
    if not targetRemote then
        return
    end

    local sanitizedArenaId = sanitizeArenaId(arenaId)
    local sanitizedLane = lane ~= nil and sanitizeNonNegativeInteger(lane) or nil
    local sanitizedPercent = pct ~= nil and sanitizePercent(pct) or nil

    local payload = {}
    assign(payload, "arenaId", sanitizedArenaId, { "ArenaId" })
    assign(payload, "lane", sanitizedLane, { "Lane", "LaneId" })
    assign(payload, "pct", sanitizedPercent, { "Pct", "percent", "Percent" })

    if extras and typeof(extras) == "table" then
        for key, value in pairs(extras) do
            payload[key] = value
        end
    end

    targetRemote:FireAllClients(payload)
end

return HUDServer
