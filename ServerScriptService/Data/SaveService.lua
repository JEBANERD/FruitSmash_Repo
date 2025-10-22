--!strict
-- SaveService
-- Wraps DataStoreService with a studio-safe in-memory fallback and simple retries.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SAVE_STORE_NAME = "PlayerProfiles"
local SAVE_KEY_PREFIX = "player_"
local IS_STUDIO = RunService:IsStudio()

local MAX_RETRIES = 3
local RETRY_DELAY_SECONDS = 2
local SAVE_COOLDOWN_SECONDS = if IS_STUDIO then 0 else 6
local BIND_CLOSE_TIMEOUT_SECONDS = 30
local BIND_CLOSE_POLL_INTERVAL = 0.25

local dataStore = if not IS_STUDIO then DataStoreService:GetDataStore(SAVE_STORE_NAME) else nil

local SaveService = {}

export type SavePayload = { [string]: any }

local buildMetadataVersion: string? = nil
local buildMetadataCommit: string? = nil
local buildMetadataGeneratedAt: string? = nil

if RunService:IsServer() then
    local okFlags, flagsModule = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Flags"))
    end)
    if okFlags and typeof(flagsModule) == "table" then
        local metadata = (flagsModule :: any).Metadata
        if typeof(metadata) == "table" then
            local cast = metadata :: any
            if typeof(cast.Version) == "string" and cast.Version ~= "" then
                buildMetadataVersion = cast.Version
            end
            if typeof(cast.Commit) == "string" and cast.Commit ~= "" then
                buildMetadataCommit = cast.Commit
            end
            if typeof(cast.GeneratedAt) == "string" and cast.GeneratedAt ~= "" then
                buildMetadataGeneratedAt = cast.GeneratedAt
            end
        end
    end
end

local function describeBuildMetadata(): string?
    local parts = {}

    if buildMetadataVersion and buildMetadataVersion ~= "" then
        table.insert(parts, string.format("version=%s", buildMetadataVersion))
    end
    if buildMetadataCommit and buildMetadataCommit ~= "" then
        table.insert(parts, string.format("commit=%s", buildMetadataCommit))
    end
    if buildMetadataGeneratedAt and buildMetadataGeneratedAt ~= "" then
        table.insert(parts, string.format("generated=%s", buildMetadataGeneratedAt))
    end

    if #parts > 0 then
        return table.concat(parts, " ")
    end

    return nil
end

local sessionCache: { [number]: SavePayload } = {}
local studioMemoryStore: { [number]: SavePayload } = {}

local saveStates: {
    [number]: {
        saving: boolean,
        queued: SavePayload?,
        lastSuccess: boolean,
        lastError: string?,
        nextAllowedTime: number?,
        lastAttemptTime: number?,
    }
} = {}

type SaveState = {
    saving: boolean,
    queued: SavePayload?,
    lastSuccess: boolean,
    lastError: string?,
    nextAllowedTime: number?,
    lastAttemptTime: number?,
}

type CheckpointProvider = (Player?, number, SavePayload?) -> SavePayload?

local checkpointProviders: { CheckpointProvider } = {}
local bindToCloseConnected = false
local flushInProgress = false

local function deepCopy(value: any, seen: { [any]: any }?): any
    if typeof(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local clone: { [any]: any } = {}
    seen[value] = clone

    for key, subValue in pairs(value) do
        clone[deepCopy(key, seen)] = deepCopy(subValue, seen)
    end

    return clone
end

local function roundUserId(value: number): number
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

local function coerceUserId(value: any): number
    if typeof(value) == "number" then
        return roundUserId(value)
    elseif typeof(value) == "string" and value ~= "" then
        local numeric = tonumber(value)
        if typeof(numeric) == "number" then
            return roundUserId(numeric)
        end
    end
    return 0
end

local function resolvePlayerAndUserId(subject: any): (Player?, number)
    if typeof(subject) == "Instance" and subject:IsA("Player") then
        local player = subject :: Player
        local userId = coerceUserId(player.UserId)
        return player, userId
    end

    local userId = coerceUserId(subject)
    if userId ~= 0 then
        local player = Players:GetPlayerByUserId(userId)
        return player, userId
    end

    return nil, 0
end

local function findPlayerByUserId(userId: number): Player?
    if userId <= 0 then
        return nil
    end

    local ok, player = pcall(Players.GetPlayerByUserId, Players, userId)
    if ok then
        return player
    end

    return nil
end

local function getKey(userId: number): string
    return SAVE_KEY_PREFIX .. tostring(userId)
end

local function cacheSession(userId: number, data: SavePayload?)
    if data then
        sessionCache[userId] = deepCopy(data)
    else
        sessionCache[userId] = nil
    end
end

local function readMemory(userId: number): SavePayload?
    local cached = sessionCache[userId]
    if cached then
        return deepCopy(cached)
    end

    if IS_STUDIO then
        local stored = studioMemoryStore[userId]
        if stored then
            return deepCopy(stored)
        end
    end

    return nil
end

local function writeMemory(userId: number, data: SavePayload)
    cacheSession(userId, data)
    if IS_STUDIO then
        studioMemoryStore[userId] = deepCopy(data)
    end
end

local function applyCheckpointProviders(player: Player?, userId: number, basePayload: SavePayload?): SavePayload?
    local payload = if basePayload ~= nil then deepCopy(basePayload) else nil

    for _, provider in ipairs(checkpointProviders) do
        local ok, result = pcall(provider, player, userId, payload)
        if not ok then
            warn(string.format("[SaveService] Checkpoint provider failed for %d: %s", userId, tostring(result)))
        elseif result ~= nil then
            if typeof(result) == "table" then
                payload = result :: SavePayload
            else
                warn(string.format("[SaveService] Checkpoint provider returned invalid data for %d", userId))
            end
        end
    end

    return payload
end

local function buildCheckpointPayload(userId: number, player: Player?): SavePayload?
    local cached = readMemory(userId)
    return applyCheckpointProviders(player, userId, cached)
end

local function performStoreSave(userId: number, data: SavePayload): (boolean, string?)
    if userId <= 0 then
        writeMemory(userId, data)
        return true, nil
    end

    if IS_STUDIO or not dataStore then
        writeMemory(userId, data)
        return true, nil
    end

    local key = getKey(userId)
    local payload = deepCopy(data)

    local lastError: string? = nil
    for attempt = 1, MAX_RETRIES do
        local success, err = pcall(function()
            dataStore:UpdateAsync(key, function()
                return payload
            end)
        end)

        if success then
            writeMemory(userId, payload)
            return true, nil
        else
            lastError = tostring(err)
            warn(string.format("[SaveService] Save attempt %d failed for %d: %s", attempt, userId, lastError))
            if attempt < MAX_RETRIES then
                task.wait(RETRY_DELAY_SECONDS)
            end
        end
    end

    return false, lastError
end

local function loadFromStore(userId: number): (SavePayload?, string?)
    if userId <= 0 then
        return readMemory(userId), nil
    end

    local cached = readMemory(userId)
    if cached then
        return cached, nil
    end

    if IS_STUDIO or not dataStore then
        return readMemory(userId), nil
    end

    local key = getKey(userId)
    local lastError: string? = nil
    for attempt = 1, MAX_RETRIES do
        local success, result = pcall(function()
            return dataStore:GetAsync(key)
        end)

        if success then
            if typeof(result) == "table" then
                local data = result :: SavePayload
                cacheSession(userId, data)
                return deepCopy(data), nil
            else
                cacheSession(userId, nil)
                return nil, nil
            end
        else
            lastError = tostring(result)
            warn(string.format("[SaveService] Load attempt %d failed for %d: %s", attempt, userId, lastError))
            if attempt < MAX_RETRIES then
                task.wait(RETRY_DELAY_SECONDS)
            end
        end
    end

    return nil, lastError
end

local function waitForActiveSave(state: SaveState): (boolean, string?)
    while state.saving do
        task.wait()
    end
    return state.lastSuccess, state.lastError
end

function SaveService.LoadAsync(userId: number): (SavePayload?, string?)
    assert(typeof(userId) == "number", "SaveService.LoadAsync expects a numeric userId")

    local data, err = loadFromStore(userId)
    return data, err
end

function SaveService.SaveAsync(userId: number, data: SavePayload): (boolean, string?)
    assert(typeof(userId) == "number", "SaveService.SaveAsync expects a numeric userId")
    assert(typeof(data) == "table", "SaveService.SaveAsync expects table data")

    local state = saveStates[userId]
    if not state then
        state = {
            saving = false,
            queued = nil,
            lastSuccess = true,
            lastError = nil,
            nextAllowedTime = nil,
            lastAttemptTime = nil,
        }
        saveStates[userId] = state
    end

    state.queued = deepCopy(data)

    if state.saving then
        local success, err = waitForActiveSave(state)
        if not state.saving and state.queued ~= nil then
            return SaveService.SaveAsync(userId, state.queued :: SavePayload)
        end

        if success and state.queued == nil then
            saveStates[userId] = nil
        end

        return success, err
    end

    state.saving = true
    local success, err: (boolean, string?) = true, nil

    while state.queued do
        local payload = state.queued :: SavePayload
        state.queued = nil

        local now = os.clock()
        local nextAllowed = state.nextAllowedTime or 0
        if nextAllowed > now then
            task.wait(nextAllowed - now)
        end

        success, err = performStoreSave(userId, payload)
        state.lastSuccess = success
        state.lastError = err
        state.lastAttemptTime = os.clock()
        state.nextAllowedTime = (state.lastAttemptTime or now) + SAVE_COOLDOWN_SECONDS

        if not success then
            break
        end
    end

    state.saving = false

    if success and state.queued == nil then
        saveStates[userId] = nil
    end

    return success, err
end

local function gatherFlushTargets(): { number }
    local targets: { number } = {}
    local seen: { [number]: boolean } = {}

    local function add(userId: number)
        if typeof(userId) ~= "number" then
            return
        end
        if seen[userId] then
            return
        end
        seen[userId] = true
        table.insert(targets, userId)
    end

    for userId in pairs(sessionCache) do
        add(userId)
    end

    for userId, state in pairs(saveStates) do
        if state then
            if state.saving or state.queued ~= nil then
                add(userId)
            end
        end
    end

    for _, player in ipairs(Players:GetPlayers()) do
        local userId = coerceUserId(player.UserId)
        if userId ~= 0 then
            add(userId)
        end
    end

    table.sort(targets, function(a, b)
        return a < b
    end)

    return targets
end

local function hasPendingSaves(): boolean
    for _, state in pairs(saveStates) do
        if state and (state.saving or state.queued ~= nil) then
            return true
        end
    end
    return false
end

local function waitForPendingSaves(timeoutSeconds: number?): boolean
    local deadline = if timeoutSeconds and timeoutSeconds > 0 then os.clock() + timeoutSeconds else nil
    while hasPendingSaves() do
        if deadline and os.clock() >= deadline then
            return false
        end
        task.wait(BIND_CLOSE_POLL_INTERVAL)
    end
    return true
end

local function waitForActiveFlush(timeoutSeconds: number?): boolean
    local deadline = if timeoutSeconds and timeoutSeconds > 0 then os.clock() + timeoutSeconds else nil

    while flushInProgress do
        if deadline and os.clock() >= deadline then
            warn("[SaveService] Waiting for an active flush timed out.")
            return false
        end
        task.wait(BIND_CLOSE_POLL_INTERVAL)
    end

    if not deadline then
        return waitForPendingSaves(nil)
    end

    local remaining = deadline - os.clock()
    if remaining <= 0 then
        return not hasPendingSaves()
    end

    return waitForPendingSaves(remaining)
end

local function flushPendingSaves(timeoutSeconds: number?): boolean
    if flushInProgress then
        return waitForActiveFlush(timeoutSeconds)
    end

    flushInProgress = true
    local completed = false

    local ok, result = pcall(function()
        local targets = gatherFlushTargets()
        local total = #targets
        local successCount = 0
        local failureCount = 0
        local skippedCount = 0
        local startTime = os.clock()
        local metadataLabel = describeBuildMetadata()

        local startMessage = string.format("[SaveService] BindToClose: flushing %d profile(s)", total)
        if metadataLabel then
            startMessage = string.format("%s (%s)", startMessage, metadataLabel)
        end
        print(startMessage)

        for _, userId in ipairs(targets) do
            local player = findPlayerByUserId(userId)
            local payload = buildCheckpointPayload(userId, player)
            if payload ~= nil then
                local saveOk, saveSuccess, saveErr = pcall(SaveService.SaveAsync, userId, payload)
                if not saveOk then
                    failureCount += 1
                    warn(string.format("[SaveService] BindToClose save error for %d: %s", userId, tostring(saveSuccess)))
                elseif not saveSuccess then
                    failureCount += 1
                    local message = if saveErr then tostring(saveErr) else "Unknown error"
                    warn(string.format("[SaveService] BindToClose save failed for %d: %s", userId, message))
                else
                    successCount += 1
                end
            else
                skippedCount += 1
            end
        end

        local finished = waitForPendingSaves(timeoutSeconds or BIND_CLOSE_TIMEOUT_SECONDS)
        if not finished then
            warn("[SaveService] BindToClose timed out while waiting for pending saves.")
        end

        local elapsed = os.clock() - startTime
        local summaryMessage = string.format(
            "[SaveService] BindToClose summary: saved=%d skipped=%d failed=%d time=%.2fs",
            successCount,
            skippedCount,
            failureCount,
            elapsed
        )
        if metadataLabel then
            summaryMessage = string.format("%s (%s)", summaryMessage, metadataLabel)
        end
        print(summaryMessage)

        return finished
    end)

    flushInProgress = false

    if ok then
        completed = result == true
    else
        warn(string.format("[SaveService] Flush encountered an error: %s", tostring(result)))
    end

    return completed
end

local function ensureBindToClose()
    if bindToCloseConnected then
        return
    end

    if RunService:IsClient() then
        return
    end

    bindToCloseConnected = true

    game:BindToClose(function()
        flushPendingSaves(BIND_CLOSE_TIMEOUT_SECONDS)
    end)
end

function SaveService.UpdateAsync(userId: number, mutator: (SavePayload?) -> SavePayload?): (SavePayload?, string?)
    assert(typeof(userId) == "number", "SaveService.UpdateAsync expects a numeric userId")
    assert(typeof(mutator) == "function", "SaveService.UpdateAsync expects a mutator function")

    local current = SaveService.GetCached(userId)
    if current == nil then
        local loaded, loadErr = SaveService.LoadAsync(userId)
        if loadErr then
            return nil, loadErr
        end
        current = loaded
    end

    local snapshot = if current ~= nil then deepCopy(current) else nil

    local ok, result = pcall(mutator, snapshot)
    if not ok then
        return nil, tostring(result)
    end

    local target = result
    if target == nil then
        target = snapshot
    end

    if target == nil then
        return current, nil
    end

    if typeof(target) ~= "table" then
        return nil, "MutatorReturnedInvalidPayload"
    end

    local success, saveErr = SaveService.SaveAsync(userId, target :: SavePayload)
    if not success then
        return nil, saveErr
    end

    return deepCopy(target), nil
end

function SaveService.GetCached(userId: number): SavePayload?
    local cached = sessionCache[userId]
    if cached then
        return deepCopy(cached)
    end
    return nil
end

function SaveService.RegisterCheckpointProvider(provider: CheckpointProvider): () -> ()
    if typeof(provider) ~= "function" then
        return function() end
    end

    table.insert(checkpointProviders, provider)

    local disconnected = false
    return function()
        if disconnected then
            return
        end
        disconnected = true

        for index = #checkpointProviders, 1, -1 do
            if checkpointProviders[index] == provider then
                table.remove(checkpointProviders, index)
                break
            end
        end
    end
end

function SaveService.CheckpointAsync(subject: any, payload: SavePayload?): (boolean, string?)
    local player, userId = resolvePlayerAndUserId(subject)
    if userId == 0 then
        return false, "InvalidUser"
    end

    local checkpointPayload = payload
    if typeof(checkpointPayload) ~= "table" then
        checkpointPayload = buildCheckpointPayload(userId, player)
    end

    if checkpointPayload == nil then
        return true, nil
    end

    return SaveService.SaveAsync(userId, checkpointPayload :: SavePayload)
end

function SaveService.Flush(timeoutSeconds: number?): boolean
    return flushPendingSaves(timeoutSeconds)
end

if RunService:IsServer() then
    task.defer(ensureBindToClose)
end

return SaveService

