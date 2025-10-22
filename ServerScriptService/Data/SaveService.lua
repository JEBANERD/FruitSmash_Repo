--!strict
-- SaveService
-- Wraps DataStoreService with a studio-safe in-memory fallback and simple retries.

local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")

local SAVE_STORE_NAME = "PlayerProfiles"
local SAVE_KEY_PREFIX = "player_"
local MAX_RETRIES = 3
local RETRY_DELAY_SECONDS = 2

local IS_STUDIO = RunService:IsStudio()

local dataStore = if not IS_STUDIO then DataStoreService:GetDataStore(SAVE_STORE_NAME) else nil

local SaveService = {}

export type SavePayload = { [string]: any }

local sessionCache: { [number]: SavePayload } = {}
local studioMemoryStore: { [number]: SavePayload } = {}

local saveStates: {
    [number]: {
        saving: boolean,
        queued: SavePayload?,
        lastSuccess: boolean,
        lastError: string?,
    }
} = {}

type SaveState = {
    saving: boolean,
    queued: SavePayload?,
    lastSuccess: boolean,
    lastError: string?,
}

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

        success, err = performStoreSave(userId, payload)
        state.lastSuccess = success
        state.lastError = err

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

function SaveService.GetCached(userId: number): SavePayload?
    local cached = sessionCache[userId]
    if cached then
        return deepCopy(cached)
    end
    return nil
end

return SaveService

