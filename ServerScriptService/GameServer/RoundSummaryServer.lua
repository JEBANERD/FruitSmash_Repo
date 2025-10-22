--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local Remotes = require(remotesFolder:WaitForChild("RemoteBootstrap"))

local roundSummaryRemote: RemoteEvent? = Remotes and Remotes.RE_RoundSummary or nil

local MatchReturnService: any = nil
do
    local matchFolder = ServerScriptService:FindFirstChild("Match")
    local serviceModule = matchFolder and matchFolder:FindFirstChild("MatchReturnService")
    if serviceModule and serviceModule:IsA("ModuleScript") then
        local ok, result = pcall(require, serviceModule)
        if ok then
            MatchReturnService = result
        else
            warn(string.format("[RoundSummaryServer] Failed to require MatchReturnService: %s", tostring(result)))
        end
    end
end

type Player = Player

type LevelRecord = {
    arenaId: any,
    level: number?,
    tokensByPlayer: { [Player]: number },
    tokensTotal: number,
}

local RoundSummaryServer = {}

local activeLevels: { [string]: LevelRecord } = {}
local recentSummaries: { [string]: { [string]: any } } = {}

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

local function sanitizeInteger(value: any): number
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric then
        return 0
    end

    if numeric >= 0 then
        return math.floor(numeric + 0.5)
    end

    return -math.floor(-numeric + 0.5)
end

local function sanitizeNonNegativeInteger(value: any): number
    local integer = sanitizeInteger(value)
    if integer < 0 then
        return 0
    end
    return integer
end

local function ensureRecord(arenaId: any): (LevelRecord?, string?)
    local key = getArenaKey(arenaId)
    if not key then
        return nil, nil
    end

    local record = activeLevels[key]
    if not record then
        record = {
            arenaId = arenaId,
            level = nil,
            tokensByPlayer = {},
            tokensTotal = 0,
        }
        activeLevels[key] = record
    else
        record.arenaId = arenaId
    end

    return record, key
end

function RoundSummaryServer.BeginLevel(arenaId: any, level: number?, _baseline: { [Player]: number }?)
    local record, key = ensureRecord(arenaId)
    if not record or not key then
        return
    end

    if level ~= nil then
        record.level = sanitizeNonNegativeInteger(level)
    else
        record.level = nil
    end

    table.clear(record.tokensByPlayer)
    record.tokensTotal = 0
    recentSummaries[key] = nil
end

function RoundSummaryServer.RecordTokenUse(player: Player)
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return
    end

    local arenaId = player:GetAttribute("ArenaId")
    if arenaId == nil then
        return
    end

    local record = ensureRecord(arenaId)
    if not record then
        return
    end

    local tokensMap = record.tokensByPlayer
    local current = sanitizeNonNegativeInteger(tokensMap[player] or 0) + 1
    tokensMap[player] = current
    record.tokensTotal = sanitizeNonNegativeInteger(record.tokensTotal) + 1
end

local function cloneTotals(template: { [string]: any }): { [string]: any }
    local copy: { [string]: any } = {}
    for key, value in pairs(template) do
        copy[key] = value
    end
    return copy
end

function RoundSummaryServer.Publish(arenaId: any, payload: { [string]: any })
    if typeof(payload) ~= "table" then
        return
    end

    if not roundSummaryRemote then
        warn("[RoundSummaryServer] RE_RoundSummary remote is unavailable; summary will not be delivered")
        return
    end

    local record, key = ensureRecord(arenaId)
    local tokensByPlayer = record and record.tokensByPlayer or nil
    local tokensTotal = record and sanitizeNonNegativeInteger(record.tokensTotal) or 0

    local levelValue = payload.level
    if levelValue == nil and record and record.level ~= nil then
        levelValue = record.level
    end
    local levelNumber = sanitizeNonNegativeInteger(levelValue)

    local totalsTable = if typeof(payload.totals) == "table" then payload.totals else {}
    local perPlayer = if typeof(payload.players) == "table" then payload.players else {}
    local recipients = payload.recipients

    local teamCoins = sanitizeInteger(totalsTable.coins or totalsTable.Coins)
    local teamPoints = sanitizeInteger(totalsTable.points or totalsTable.Points)
    local wavesCleared = sanitizeNonNegativeInteger(totalsTable.wavesCleared or totalsTable.WavesCleared or totalsTable.waves or totalsTable.Waves)
    local teamKos = sanitizeNonNegativeInteger(totalsTable.kos or totalsTable.KOs or totalsTable.kosTotal or totalsTable.totalKOs)

    local totalsPayload = {
        coins = teamCoins,
        points = teamPoints,
        wavesCleared = wavesCleared,
        kos = teamKos,
        tokensUsed = tokensTotal,
    }

    local outcomeValue = payload.outcome
    if outcomeValue ~= nil and typeof(outcomeValue) ~= "string" then
        outcomeValue = tostring(outcomeValue)
    end

    local reasonValue = payload.reason
    if reasonValue ~= nil and typeof(reasonValue) ~= "string" then
        reasonValue = tostring(reasonValue)
    end

    local recipientList: { Player } = {}
    if typeof(recipients) == "table" then
        for _, entry in ipairs(recipients) do
            if typeof(entry) == "Instance" and entry:IsA("Player") then
                table.insert(recipientList, entry)
            end
        end
    end

    if #recipientList == 0 then
        for player, _ in pairs(perPlayer) do
            if typeof(player) == "Instance" and player:IsA("Player") then
                table.insert(recipientList, player)
            end
        end
    end

    local dispatched = false
    local recipientsCopy: { Player } = {}

    for _, player in ipairs(recipientList) do
        if typeof(player) == "Instance" and player:IsA("Player") then
            local entry = perPlayer[player]
            local playerCoins = sanitizeInteger(entry and (entry.coins or entry.Coins))
            local playerPoints = sanitizeInteger(entry and (entry.points or entry.Points))
            local playerKos = sanitizeNonNegativeInteger(entry and (entry.kos or entry.KOs))
            local playerTokens = sanitizeNonNegativeInteger(tokensByPlayer and tokensByPlayer[player] or 0)

            local personalPayload = {
                coins = playerCoins,
                points = playerPoints,
                kos = playerKos,
                tokensUsed = playerTokens,
                name = player.Name,
            }

            if typeof(player.UserId) == "number" then
                personalPayload.userId = player.UserId
            end

            local eventData = {
                arenaId = record and record.arenaId or arenaId,
                level = levelNumber,
                outcome = outcomeValue,
                reason = reasonValue,
                totals = cloneTotals(totalsPayload),
                player = personalPayload,
                timestamp = os.time(),
            }

            roundSummaryRemote:FireClient(player, eventData)
            table.insert(recipientsCopy, player)
            dispatched = true
        end
    end

    if record and key then
        activeLevels[key] = nil
    end

    if dispatched and key then
        recentSummaries[key] = {
            arenaId = record and record.arenaId or arenaId,
            level = levelNumber,
            outcome = outcomeValue,
            reason = reasonValue,
            totals = cloneTotals(totalsPayload),
            tokensUsed = tokensTotal,
            timestamp = os.time(),
            players = recipientsCopy,
        }
    elseif key then
        recentSummaries[key] = nil
    end
end

function RoundSummaryServer.Reset(arenaId: any)
    local key = getArenaKey(arenaId)
    if not key then
        return
    end

    activeLevels[key] = nil
    recentSummaries[key] = nil
end

local function purgePlayer(player: Player)
    for _, record in pairs(activeLevels) do
        record.tokensByPlayer[player] = nil
    end
end

Players.PlayerRemoving:Connect(purgePlayer)

if roundSummaryRemote then
    roundSummaryRemote.OnServerEvent:Connect(function(player: Player, payload: any)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
            return
        end

        if typeof(payload) ~= "table" then
            return
        end

        local actionValue = payload.action or payload.Action or payload.command or payload.Command or payload.intent or payload.Intent
        if typeof(actionValue) ~= "string" then
            return
        end

        local action = string.lower(actionValue)
        if action == "returntolobby" or action == "return" or action == "lobby" then
            local arenaId = payload.arenaId
            if arenaId == nil then
                arenaId = player:GetAttribute("ArenaId")
            end

            local key = getArenaKey(arenaId)
            if not key then
                return
            end

            local summary = recentSummaries[key]
            local requestedBy = if typeof(player.UserId) == "number" then player.UserId else player.Name

            local context = {
                reason = summary and summary.reason or "PlayerRequest",
                level = summary and summary.level or nil,
                outcome = summary and summary.outcome or nil,
                totals = summary and summary.totals or nil,
                tokensUsed = summary and summary.tokensUsed or nil,
                players = summary and summary.players or { player },
                requestedBy = requestedBy,
            }

            if typeof(context.reason) ~= "string" or context.reason == "" then
                if summary and summary.outcome == "defeat" then
                    context.reason = "Defeat"
                else
                    context.reason = "PlayerRequest"
                end
            end

            if MatchReturnService and typeof(MatchReturnService.ReturnArena) == "function" then
                local ok, err = pcall(MatchReturnService.ReturnArena, arenaId, context)
                if not ok then
                    warn(string.format("[RoundSummaryServer] ReturnArena failed: %s", tostring(err)))
                end
            end
        end
    end)
end

return RoundSummaryServer
