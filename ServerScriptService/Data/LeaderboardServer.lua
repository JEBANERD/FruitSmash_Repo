--!strict
-- LeaderboardServer
-- Maintains a live session leaderboard and optional global OrderedDataStore standings for points.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local Remotes = require(remotesFolder:WaitForChild("RemoteBootstrap"))

local LeaderboardServer = {}

local SESSION_MAX_ENTRIES = 10
local GLOBAL_STORE_NAME = "GlobalPointsLeaderboard"
local GLOBAL_MAX_RETRIES = 5
local GLOBAL_RETRY_DELAY = 2
local GLOBAL_UPDATE_COOLDOWN = 15
local GLOBAL_FETCH_LIMIT = 50
local MAX_ALLOWED_SCORE = 9e18

local sessionScores: {[number]: number} = {}
local sessionPlayers: {[number]: Player?} = {}
local sessionOrder: {{ userId: number, score: number }} = {}
local sessionTop: {{ userId: number, score: number, points: number, value: number, name: string, username: string, displayName: string, rank: number }} = {}
local sessionRanks: {[number]: number} = {}

local attributeConnections: {[Player]: RBXScriptConnection} = {}

local globalBest: {[number]: number} = {}
local globalNameCache: {[number]: string} = {}
local globalDisplayNameCache: {[number]: string} = {}
local globalCooldowns: {[number]: number} = {}
local pendingGlobalUpdate: {[number]: boolean} = {}

local hasDisplayNameAsync = typeof((Players :: any).GetDisplayNameFromUserIdAsync) == "function"
local isStudio = RunService:IsStudio()

local sessionRemote: RemoteEvent? = Remotes and Remotes.RE_SessionLeaderboard or nil
local globalRemoteFunction: RemoteFunction? = Remotes and Remotes.RF_GetGlobalLeaderboard or nil

local globalStore: any = nil
if not isStudio then
    local ok, result = pcall(function()
        return DataStoreService:GetOrderedDataStore(GLOBAL_STORE_NAME)
    end)
    if ok then
        globalStore = result
    else
        warn(string.format("[LeaderboardServer] Failed to access OrderedDataStore '%s': %s", GLOBAL_STORE_NAME, tostring(result)))
    end
end

local function sanitizeScore(value: any): number?
    local numeric = tonumber(value)
    if numeric == nil then
        return nil
    end

    if numeric >= 0 then
        numeric = math.floor(numeric + 0.5)
    else
        numeric = math.ceil(numeric - 0.5)
    end

    if numeric < 0 then
        numeric = 0
    end

    if numeric > MAX_ALLOWED_SCORE then
        numeric = MAX_ALLOWED_SCORE
    end

    return numeric
end

local function resolveNames(userId: number): (string, string)
    if userId <= 0 then
        local placeholder = string.format("User%d", userId)
        return placeholder, placeholder
    end

    local player = Players:GetPlayerByUserId(userId)
    if player then
        local username = player.Name
        local displayName = player.DisplayName
        globalNameCache[userId] = username
        globalDisplayNameCache[userId] = displayName
        return username, displayName
    end

    local cachedName = globalNameCache[userId]
    local cachedDisplay = globalDisplayNameCache[userId]

    if not cachedName then
        local ok, result = pcall(function()
            return Players:GetNameFromUserIdAsync(userId)
        end)
        if ok and typeof(result) == "string" then
            cachedName = result
            globalNameCache[userId] = result
        end
    end

    if not cachedDisplay and hasDisplayNameAsync then
        local ok, result = pcall(function()
            return Players:GetDisplayNameFromUserIdAsync(userId)
        end)
        if ok and typeof(result) == "string" then
            cachedDisplay = result
            globalDisplayNameCache[userId] = result
        end
    end

    if not cachedName then
        cachedName = string.format("User%d", userId)
        globalNameCache[userId] = cachedName
    end

    if not cachedDisplay then
        cachedDisplay = cachedName
        globalDisplayNameCache[userId] = cachedDisplay
    end

    return cachedName, cachedDisplay
end

local function cloneTopEntries(): { { [string]: any } }
    local copy: { { [string]: any } } = {}
    for index, entry in ipairs(sessionTop) do
        copy[index] = {
            userId = entry.userId,
            score = entry.score,
            points = entry.points,
            value = entry.value,
            name = entry.name,
            username = entry.username,
            displayName = entry.displayName,
            rank = entry.rank,
        }
    end
    return copy
end

local function gatherGlobalCache(limit: number): { { [string]: any } }
    local ordered: { { userId: number, score: number } } = {}
    for userId, score in pairs(globalBest) do
        ordered[#ordered + 1] = { userId = userId, score = score }
    end

    table.sort(ordered, function(a, b)
        if a.score == b.score then
            return a.userId < b.userId
        end
        return a.score > b.score
    end)

    local entries: { { [string]: any } } = {}
    local count = math.min(limit, #ordered)
    for index = 1, count do
        local entry = ordered[index]
        local username, displayName = resolveNames(entry.userId)
        entries[#entries + 1] = {
            userId = entry.userId,
            score = entry.score,
            points = entry.score,
            value = entry.score,
            name = username,
            username = username,
            displayName = displayName,
            rank = index,
        }
    end

    return entries
end

local function recomputeSession()
    table.clear(sessionOrder)
    table.clear(sessionTop)
    table.clear(sessionRanks)

    for userId, score in pairs(sessionScores) do
        sessionOrder[#sessionOrder + 1] = { userId = userId, score = score }
    end

    table.sort(sessionOrder, function(a, b)
        if a.score == b.score then
            return a.userId < b.userId
        end
        return a.score > b.score
    end)

    for index, entry in ipairs(sessionOrder) do
        sessionRanks[entry.userId] = index
        if index <= SESSION_MAX_ENTRIES then
            local player = sessionPlayers[entry.userId]
            if not player or player.Parent ~= Players then
                player = Players:GetPlayerByUserId(entry.userId)
                if player then
                    sessionPlayers[entry.userId] = player
                end
            end

            local username: string
            local displayName: string
            if player then
                username = player.Name
                displayName = player.DisplayName
            else
                local resolvedName, resolvedDisplay = resolveNames(entry.userId)
                username = resolvedName
                displayName = resolvedDisplay
            end

            sessionTop[#sessionTop + 1] = {
                userId = entry.userId,
                score = entry.score,
                points = entry.score,
                value = entry.score,
                name = username,
                username = username,
                displayName = displayName,
                rank = index,
            }
        end
    end
end

local function broadcastSession()
    if not sessionRemote then
        return
    end

    local players = Players:GetPlayers()
    if #players == 0 then
        return
    end

    local totalPlayers = #sessionOrder
    local timestamp = os.time()

    for _, player in ipairs(players) do
        local snapshot = cloneTopEntries()
        local userId = player.UserId
        local payload = {
            top = snapshot,
            entries = snapshot,
            totalPlayers = totalPlayers,
            yourRank = sessionRanks[userId],
            yourScore = sessionScores[userId] or 0,
            updated = timestamp,
        }
        sessionRemote:FireClient(player, payload)
    end
end

local function attemptGlobalSubmit(userId: number)
    local best = globalBest[userId]
    if not best or userId <= 0 then
        pendingGlobalUpdate[userId] = false
        return
    end

    if not globalStore then
        pendingGlobalUpdate[userId] = false
        return
    end

    local now = os.clock()
    local last = globalCooldowns[userId]
    if last and now - last < GLOBAL_UPDATE_COOLDOWN then
        if not pendingGlobalUpdate[userId] then
            pendingGlobalUpdate[userId] = true
            local waitTime = GLOBAL_UPDATE_COOLDOWN - (now - last)
            if waitTime < 0 then
                waitTime = GLOBAL_UPDATE_COOLDOWN
            end
            task.delay(waitTime, function()
                pendingGlobalUpdate[userId] = false
                attemptGlobalSubmit(userId)
            end)
        end
        return
    end

    globalCooldowns[userId] = now
    pendingGlobalUpdate[userId] = false

    task.spawn(function()
        local success = false
        local lastError: any = nil

        for attempt = 1, GLOBAL_MAX_RETRIES do
            success, lastError = pcall(function()
                globalStore:UpdateAsync(tostring(userId), function(currentValue)
                    local currentNumeric = sanitizeScore(currentValue) or 0
                    if best > currentNumeric then
                        return best
                    end
                    return currentNumeric
                end)
            end)

            if success then
                break
            end

            warn(string.format("[LeaderboardServer] Global update attempt %d failed for %d: %s", attempt, userId, tostring(lastError)))
            if attempt < GLOBAL_MAX_RETRIES then
                task.wait(GLOBAL_RETRY_DELAY)
            end
        end

        if not success then
            if not pendingGlobalUpdate[userId] then
                pendingGlobalUpdate[userId] = true
                task.delay(GLOBAL_UPDATE_COOLDOWN, function()
                    pendingGlobalUpdate[userId] = false
                    attemptGlobalSubmit(userId)
                end)
            end
        end
    end)
end

local function trackGlobalScore(player: Player, score: number)
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return
    end

    local userId = player.UserId
    if userId <= 0 then
        return
    end

    local sanitized = sanitizeScore(score) or 0
    globalNameCache[userId] = player.Name
    globalDisplayNameCache[userId] = player.DisplayName

    local currentBest = globalBest[userId]
    if currentBest == nil then
        globalBest[userId] = sanitized
        if sanitized > 0 then
            attemptGlobalSubmit(userId)
        end
        return
    end

    if sanitized > currentBest then
        globalBest[userId] = sanitized
        attemptGlobalSubmit(userId)
    end
end

function LeaderboardServer.SubmitScore(player: Player, points: any): number?
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return nil
    end

    local userId = player.UserId
    if typeof(userId) ~= "number" then
        return nil
    end

    sessionPlayers[userId] = player

    local sanitized = sanitizeScore(points)
    if sanitized == nil then
        sanitized = 0
    end

    local previous = sessionScores[userId]
    sessionScores[userId] = sanitized

    trackGlobalScore(player, sanitized)

    if previous == sanitized then
        return sessionRanks[userId]
    end

    recomputeSession()
    broadcastSession()

    return sessionRanks[userId]
end

function LeaderboardServer.FetchGlobalTop(count: number?): { [string]: any }
    local limit = tonumber(count)
    if limit == nil then
        limit = SESSION_MAX_ENTRIES
    else
        limit = math.floor(limit + 0.5)
        if limit < 1 then
            limit = 1
        elseif limit > GLOBAL_FETCH_LIMIT then
            limit = GLOBAL_FETCH_LIMIT
        end
    end

    if not globalStore then
        local fallback = gatherGlobalCache(limit)
        return {
            entries = fallback,
            total = #fallback,
            updated = os.time(),
            source = "session",
        }
    end

    local success, pages = false, nil
    local lastError: any = nil

    for attempt = 1, GLOBAL_MAX_RETRIES do
        success, pages = pcall(function()
            return globalStore:GetSortedAsync(false, limit)
        end)

        if success then
            break
        end

        lastError = pages
        warn(string.format("[LeaderboardServer] Global fetch attempt %d failed: %s", attempt, tostring(lastError)))
        if attempt < GLOBAL_MAX_RETRIES then
            task.wait(GLOBAL_RETRY_DELAY)
        end
    end

    if not success or type(pages) ~= "table" or type((pages :: any).GetCurrentPage) ~= "function" then
        local fallback = gatherGlobalCache(limit)
        return {
            entries = fallback,
            total = #fallback,
            updated = os.time(),
            source = "fallback",
            error = lastError and tostring(lastError) or "DataStore unavailable",
        }
    end

    local pageData = (pages :: any):GetCurrentPage()
    local results: { { [string]: any } } = {}

    for index, record in ipairs(pageData) do
        local keyValue = (record :: any).key
        local userId = tonumber(keyValue)
        local scoreValue = sanitizeScore((record :: any).value) or 0

        if userId then
            if globalBest[userId] == nil or scoreValue > (globalBest[userId] :: number) then
                globalBest[userId] = scoreValue
            end
            local username, displayName = resolveNames(userId)
            results[#results + 1] = {
                userId = userId,
                score = scoreValue,
                points = scoreValue,
                value = scoreValue,
                name = username,
                username = username,
                displayName = displayName,
                rank = index,
            }
        end

        if #results >= limit then
            break
        end
    end

    return {
        entries = results,
        total = #results,
        updated = os.time(),
        source = "datastore",
    }
end

function LeaderboardServer.GetSessionTop(): { { [string]: any } }
    return cloneTopEntries()
end

function LeaderboardServer.GetSessionRank(player: Player): number?
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return nil
    end

    return sessionRanks[player.UserId]
end

if globalRemoteFunction then
    globalRemoteFunction.OnServerInvoke = function(_, count)
        local ok, result = pcall(function()
            return LeaderboardServer.FetchGlobalTop(count)
        end)

        if ok and typeof(result) == "table" then
            return result
        end

        warn(string.format("[LeaderboardServer] FetchGlobalTop failed: %s", tostring(result)))
        local fallback = gatherGlobalCache(tonumber(count) or SESSION_MAX_ENTRIES)
        return {
            entries = fallback,
            error = "Global leaderboard unavailable",
            source = "error",
            updated = os.time(),
        }
    end
end

local function observePlayer(player: Player)
    sessionPlayers[player.UserId] = player

    local connection = player:GetAttributeChangedSignal("Points"):Connect(function()
        LeaderboardServer.SubmitScore(player, player:GetAttribute("Points"))
    end)
    attributeConnections[player] = connection

    task.defer(function()
        LeaderboardServer.SubmitScore(player, player:GetAttribute("Points"))
    end)
end

local function cleanupPlayer(player: Player)
    local connection = attributeConnections[player]
    if connection then
        connection:Disconnect()
        attributeConnections[player] = nil
    end

    local userId = player.UserId
    sessionPlayers[userId] = nil
    sessionScores[userId] = nil
    sessionRanks[userId] = nil

    recomputeSession()
    broadcastSession()
end

for _, player in ipairs(Players:GetPlayers()) do
    task.defer(observePlayer, player)
end

Players.PlayerAdded:Connect(observePlayer)
Players.PlayerRemoving:Connect(cleanupPlayer)

return LeaderboardServer
