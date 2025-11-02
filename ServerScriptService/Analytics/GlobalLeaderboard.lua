--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

export type LeaderboardEntry = {
    userId: number,
    score: number,
    rank: number,
    name: string,
    username: string,
    displayName: string,
}

export type LeaderboardSnapshot = {
    entries: { LeaderboardEntry },
    total: number,
    source: string,
    updated: number,
    error: string?,
}

export type PlayerStats = {
    userId: number,
    score: number,
    name: string,
    username: string,
    displayName: string,
    rank: number?,
}

local GlobalLeaderboard = {}

local STORE_NAME = "GlobalPointsLeaderboard"
local DEFAULT_LIMIT = 10
local MAX_LIMIT = 50
local MAX_RETRIES = 3
local RETRY_DELAY = 2

local nameCache: { [number]: string } = {}
local displayCache: { [number]: string } = {}

local orderedStore: any = nil

local LeaderboardServer: {
    GetSessionTop: (() -> { { [string]: any } })?,
}? = nil

do
    local ok, module = pcall(function()
        local dataFolder = ServerScriptService:FindFirstChild("Data")
        if dataFolder then
            local scriptObject = dataFolder:FindFirstChild("LeaderboardServer")
            if scriptObject then
                return require(scriptObject)
            end
        end
        return nil
    end)

    if ok and typeof(module) == "table" then
        LeaderboardServer = module
    end
end

local function clampLimit(value: number?): number
    local numeric = if typeof(value) == "number" then value else DEFAULT_LIMIT
    if numeric ~= numeric or numeric == math.huge or numeric == -math.huge then
        numeric = DEFAULT_LIMIT
    end
    numeric = math.floor(numeric + 0.5)
    if numeric < 1 then
        numeric = 1
    elseif numeric > MAX_LIMIT then
        numeric = MAX_LIMIT
    end
    return numeric
end

local function sanitizeScore(raw: any): number?
    local numeric = tonumber(raw)
    if numeric == nil then
        return nil
    end

    if numeric ~= numeric or numeric == math.huge or numeric == -math.huge then
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

    return numeric
end

local function resolveDisplayNames(userId: number): (string, string)
    local cachedUsername = nameCache[userId]
    local cachedDisplayName = displayCache[userId]

    if cachedUsername and cachedDisplayName then
        return cachedUsername, cachedDisplayName
    end

    local player = Players:GetPlayerByUserId(userId)
    if player then
        local username = player.Name
        local displayName = player.DisplayName
        nameCache[userId] = username
        displayCache[userId] = displayName
        return username, displayName
    end

    if not cachedUsername then
        local ok, result = pcall(function()
            return Players:GetNameFromUserIdAsync(userId)
        end)
        if ok and typeof(result) == "string" and result ~= "" then
            cachedUsername = result
            nameCache[userId] = result
        end
    end

    if not cachedDisplayName and typeof((Players :: any).GetDisplayNameFromUserIdAsync) == "function" then
        local ok, result = pcall(function()
            return (Players :: any):GetDisplayNameFromUserIdAsync(userId)
        end)
        if ok and typeof(result) == "string" and result ~= "" then
            cachedDisplayName = result
            displayCache[userId] = result
        end
    end

    if not cachedUsername or cachedUsername == "" then
        cachedUsername = string.format("User%d", userId)
        nameCache[userId] = cachedUsername
    end

    if not cachedDisplayName or cachedDisplayName == "" then
        cachedDisplayName = cachedUsername
        displayCache[userId] = cachedDisplayName
    end

    return cachedUsername, cachedDisplayName
end

local function getOrderedStore(): any?
    if orderedStore ~= nil then
        return orderedStore
    end

    local ok, result = pcall(function()
        return DataStoreService:GetOrderedDataStore(STORE_NAME)
    end)

    if ok and result ~= nil then
        orderedStore = result
    else
        warn(string.format("[GlobalLeaderboard] Failed to access OrderedDataStore '%s': %s", STORE_NAME, tostring(result)))
    end

    return orderedStore
end

local function sortEntries(entries: { LeaderboardEntry })
    table.sort(entries, function(a, b)
        if a.score == b.score then
            return a.userId < b.userId
        end
        return a.score > b.score
    end)

    for index, entry in ipairs(entries) do
        entry.rank = index
    end
end

local function buildFallback(limit: number): LeaderboardSnapshot
    if LeaderboardServer and typeof(LeaderboardServer.GetSessionTop) == "function" then
        local ok, results = pcall(LeaderboardServer.GetSessionTop :: any)
        if ok and typeof(results) == "table" then
            local entries: { LeaderboardEntry } = {}
            for index, rawEntry in ipairs(results) do
                if index > limit then
                    break
                end
                local candidate = rawEntry
                if typeof(candidate) == "table" then
                    local userIdValue = tonumber(candidate.userId)
                    local scoreValue = sanitizeScore(candidate.score or candidate.points or candidate.value)
                    if userIdValue and scoreValue then
                        local username, displayName = resolveDisplayNames(userIdValue)
                        entries[#entries + 1] = {
                            userId = userIdValue,
                            score = scoreValue,
                            rank = index,
                            name = username,
                            username = username,
                            displayName = displayName,
                        }
                    end
                end
            end

            sortEntries(entries)
            return {
                entries = entries,
                total = #entries,
                updated = os.time(),
                source = "session",
            }
        end
    end

    return {
        entries = {},
        total = 0,
        updated = os.time(),
        source = "empty",
    }
end

local function extractEntries(pageData: any, limit: number): { LeaderboardEntry }
    local entries: { LeaderboardEntry } = {}
    if typeof(pageData) ~= "table" then
        return entries
    end

    for _, record in ipairs(pageData) do
        local keyValue = if record then (record :: any).key else nil
        local userId = tonumber(keyValue)
        local score = sanitizeScore(record and (record :: any).value)

        if userId and score then
            local username, displayName = resolveDisplayNames(userId)
            entries[#entries + 1] = {
                userId = userId,
                score = score,
                rank = #entries + 1,
                name = username,
                username = username,
                displayName = displayName,
            }
        end

        if #entries >= limit then
            break
        end
    end

    sortEntries(entries)
    return entries
end

function GlobalLeaderboard.FetchTop(limit: number?): LeaderboardSnapshot
    local resolvedLimit = clampLimit(limit)
    local store = getOrderedStore()

    if not store then
        return buildFallback(resolvedLimit)
    end

    local lastError: any = nil
    local pages: any = nil

    for attempt = 1, MAX_RETRIES do
        local ok, result = pcall(function()
            return store:GetSortedAsync(false, resolvedLimit)
        end)

        if ok then
            pages = result
            break
        end

        lastError = result
        warn(string.format("[GlobalLeaderboard] GetSortedAsync attempt %d failed: %s", attempt, tostring(lastError)))
        if attempt < MAX_RETRIES then
            task.wait(RETRY_DELAY)
        end
    end

    if pages == nil or typeof((pages :: any).GetCurrentPage) ~= "function" then
        local fallback = buildFallback(resolvedLimit)
        fallback.error = lastError and tostring(lastError) or "datastore_unavailable"
        fallback.source = "fallback"
        return fallback
    end

    local pageOk, pageData = pcall(function()
        return (pages :: any):GetCurrentPage()
    end)

    if not pageOk or typeof(pageData) ~= "table" then
        local fallback = buildFallback(resolvedLimit)
        fallback.error = tostring(pageData)
        fallback.source = "fallback"
        return fallback
    end

    local entries = extractEntries(pageData, resolvedLimit)

    return {
        entries = entries,
        total = #entries,
        updated = os.time(),
        source = "datastore",
    }
end

function GlobalLeaderboard.GetPlayerStats(userId: number): PlayerStats?
    if typeof(userId) ~= "number" then
        return nil
    end

    local snapshot = GlobalLeaderboard.FetchTop(MAX_LIMIT)
    for _, entry in ipairs(snapshot.entries) do
        if entry.userId == userId then
            return {
                userId = entry.userId,
                score = entry.score,
                name = entry.name,
                username = entry.username,
                displayName = entry.displayName,
                rank = entry.rank,
            }
        end
    end

    local store = getOrderedStore()
    if not store then
        return nil
    end

    local ok, result = pcall(function()
        return store:GetAsync(tostring(userId))
    end)

    if not ok then
        warn(string.format("[GlobalLeaderboard] GetAsync failed for %d: %s", userId, tostring(result)))
        return nil
    end

    local score = sanitizeScore(result)
    if not score then
        return nil
    end

    local username, displayName = resolveDisplayNames(userId)

    return {
        userId = userId,
        score = score,
        name = username,
        username = username,
        displayName = displayName,
    }
end

return GlobalLeaderboard

