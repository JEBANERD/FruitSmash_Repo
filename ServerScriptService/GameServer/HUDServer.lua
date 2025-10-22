--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local Remotes = require(remotesFolder:WaitForChild("RemoteBootstrap"))

local HUDServer = {}

local prepRemote = Remotes and Remotes.RE_PrepTimer or nil
local waveRemote = Remotes and Remotes.RE_WaveChanged or nil
local targetRemote = Remotes and Remotes.RE_TargetHP or nil
local coinRemote = Remotes and Remotes.RE_CoinPointDelta or nil

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

local function sanitizeInteger(value: any)
    local numeric = tonumber(value)
    if not numeric then
        return nil
    end

    if numeric >= 0 then
        numeric = math.floor(numeric + 0.5)
    else
        numeric = math.ceil(numeric - 0.5)
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

local function resolveRecipients(target: any): { Player }?
    if target == nil then
        return nil
    end

    if typeof(target) == "Instance" and target:IsA("Player") then
        return { target }
    end

    if typeof(target) == "table" then
        local recipients: { Player } = {}
        if #target > 0 then
            for index = 1, #target do
                local candidate = target[index]
                if typeof(candidate) == "Instance" and candidate:IsA("Player") then
                    table.insert(recipients, candidate)
                end
            end
        else
            for _, candidate in pairs(target) do
                if typeof(candidate) == "Instance" and candidate:IsA("Player") then
                    table.insert(recipients, candidate)
                end
            end
        end

        if #recipients > 0 then
            return recipients
        end
    end

    return nil
end

local function sanitizeCoinPayload(source: { [string]: any }?)
    local payload: { [string]: any } = {}

    if not source then
        return payload
    end

    local coinsCandidate = source.coins
    if coinsCandidate == nil then
        coinsCandidate = source.Coins or source.deltaCoins or source.DeltaCoins
    end
    local sanitizedCoins = coinsCandidate ~= nil and sanitizeInteger(coinsCandidate) or nil
    assign(payload, "coins", sanitizedCoins, { "Coins", "deltaCoins", "DeltaCoins" })

    local pointsCandidate = source.points
    if pointsCandidate == nil then
        pointsCandidate = source.Points or source.deltaPoints or source.DeltaPoints
    end
    local sanitizedPoints = pointsCandidate ~= nil and sanitizeInteger(pointsCandidate) or nil
    assign(payload, "points", sanitizedPoints, { "Points", "deltaPoints", "DeltaPoints" })

    local totalCoinsCandidate = source.totalCoins
    if totalCoinsCandidate == nil then
        totalCoinsCandidate = source.TotalCoins
    end
    local sanitizedTotalCoins = totalCoinsCandidate ~= nil and sanitizeNonNegativeInteger(totalCoinsCandidate) or nil
    assign(payload, "totalCoins", sanitizedTotalCoins, { "TotalCoins" })

    local totalPointsCandidate = source.totalPoints
    if totalPointsCandidate == nil then
        totalPointsCandidate = source.TotalPoints
    end
    local sanitizedTotalPoints = totalPointsCandidate ~= nil and sanitizeNonNegativeInteger(totalPointsCandidate) or nil
    assign(payload, "totalPoints", sanitizedTotalPoints, { "TotalPoints" })

    if source.reason ~= nil then
        assign(payload, "reason", source.reason, { "Reason" })
    elseif source.Reason ~= nil then
        assign(payload, "reason", source.Reason, { "Reason" })
    end

    if source.metadata ~= nil then
        payload.metadata = source.metadata
    elseif source.Metadata ~= nil then
        payload.metadata = source.Metadata
    end

    for key, value in pairs(source) do
        if payload[key] == nil then
            payload[key] = value
        end
    end

    return payload
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

function HUDServer.CoinPointDelta(target: any, payloadOrCoins: any, pointsOrExtras: any?, extras: { [string]: any }?)
    if not coinRemote then
        return
    end

    local source: { [string]: any } = {}

    if typeof(payloadOrCoins) == "table" then
        for key, value in pairs(payloadOrCoins) do
            source[key] = value
        end

        if typeof(pointsOrExtras) == "table" then
            for key, value in pairs(pointsOrExtras) do
                source[key] = value
            end
        end
    else
        if payloadOrCoins ~= nil then
            source.coins = payloadOrCoins
        end

        local extrasTable: { [string]: any }? = nil
        if typeof(pointsOrExtras) == "number" then
            source.points = pointsOrExtras
            extrasTable = extras
        elseif typeof(pointsOrExtras) == "table" then
            extrasTable = pointsOrExtras
        elseif extras ~= nil then
            extrasTable = extras
        end

        if extrasTable then
            for key, value in pairs(extrasTable) do
                source[key] = value
            end
        end
    end

    local payload = sanitizeCoinPayload(source)
    local recipients = resolveRecipients(target)

    if recipients then
        for _, player in ipairs(recipients) do
            coinRemote:FireClient(player, payload)
        end
        return
    end

    coinRemote:FireAllClients(payload)
end

return HUDServer
