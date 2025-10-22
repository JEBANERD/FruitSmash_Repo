--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local isServer = RunService:IsServer()

local DEFAULT_FLAGS = {
    Obstacles = true,
    Telemetry = true,
    Achievements = true,
}

local STATIC_PLACE_OVERRIDES: { [number | string]: { [string]: boolean } } = {
    -- [1234567890] = { Obstacles = false },
}

local ATTRIBUTE_PREFIX = "Flag_"

export type FlagValue = boolean
export type FlagSnapshot = { [string]: FlagValue }

export type FlagChangedCallback = (FlagValue, string) -> ()
export type FlagAnyChangedCallback = (string, FlagValue) -> ()

export type CheckpointMetadata = {
    Version: string,
    Commit: string,
    GeneratedAt: string?,
    Flags: {
        Defaults: FlagSnapshot?,
        PlaceOverrides: { [string]: FlagSnapshot }?,
    }?,
}

local Flags = {}

local type FlagEntry = {
    name: string,
    canonical: string,
    baseDefault: boolean,
    default: boolean,
    override: boolean?,
    current: boolean,
}

local entries: { [string]: FlagEntry } = {}
local watchers: { [string]: { FlagChangedCallback } } = {}
local watchersAll: { [string]: { FlagAnyChangedCallback } } = {}

type FlagOverrideMap = FlagSnapshot

local function normalizePlaceKey(key: any): string?
    if key == nil then
        return nil
    end

    local keyType = typeof(key)
    if keyType == "number" then
        if key ~= key or key == math.huge or key == -math.huge then
            return nil
        end

        local rounded = if key >= 0 then math.floor(key + 0.5) else math.ceil(key - 0.5)
        return tostring(rounded)
    elseif keyType == "string" then
        local trimmed = string.gsub(key, "^%s*(.-)%s*$", "%1")
        if trimmed == "" then
            return nil
        end
        if trimmed == "*" then
            return trimmed
        end

        local numeric = tonumber(trimmed)
        if numeric then
            return normalizePlaceKey(numeric)
        end

        local trailingDigits = string.match(trimmed, "(%d+)$")
        if trailingDigits then
            return normalizePlaceKey(tonumber(trailingDigits))
        end

        return trimmed
    end

    return nil
end

local placeOverrides: { [string]: FlagOverrideMap } = {}

local function getOrCreateOverrideBucket(key: string): FlagOverrideMap
    local existing = placeOverrides[key]
    if existing then
        return existing
    end

    local bucket: FlagOverrideMap = {}
    placeOverrides[key] = bucket
    return bucket
end

local function mergePlaceOverrides(source: any)
    if typeof(source) ~= "table" then
        return
    end

    for placeKey, overrides in pairs(source :: any) do
        local normalizedKey = normalizePlaceKey(placeKey)
        if normalizedKey and typeof(overrides) == "table" then
            local bucket = getOrCreateOverrideBucket(normalizedKey)
            for flagName, flagValue in pairs(overrides :: any) do
                if typeof(flagName) == "string" then
                    bucket[flagName] = flagValue == true
                end
            end
        end
    end
end

mergePlaceOverrides(STATIC_PLACE_OVERRIDES)

local function canonicalize(name: string?): string?
    if typeof(name) ~= "string" then
        return nil
    end

    local trimmed = string.gsub(name, "^%s*(.-)%s*$", "%1")
    if trimmed == "" then
        return nil
    end

    return string.lower(trimmed)
end

local function registerFlag(flagName: string, defaultValue: boolean?): FlagEntry?
    local canonical = canonicalize(flagName)
    if not canonical then
        return nil
    end

    local existing = entries[canonical]
    if existing then
        if defaultValue ~= nil and existing.baseDefault == nil then
            existing.baseDefault = defaultValue == true
        end
        return existing
    end

    local baseDefault = if defaultValue == nil then false else (defaultValue and true or false)

    local entry: FlagEntry = {
        name = flagName,
        canonical = canonical,
        baseDefault = baseDefault,
        default = baseDefault,
        override = nil,
        current = baseDefault,
    }

    entries[canonical] = entry

    return entry
end

for name, defaultValue in pairs(DEFAULT_FLAGS) do
    registerFlag(name, defaultValue)
end

local function getAttributeName(entry: FlagEntry): string
    return ATTRIBUTE_PREFIX .. entry.name
end

local function updateAttribute(entry: FlagEntry)
    if not isServer then
        return
    end

    local attrName = getAttributeName(entry)
    local ok, err = pcall(ReplicatedStorage.SetAttribute, ReplicatedStorage, attrName, entry.current)
    if not ok then
        warn(string.format("[Flags] Failed to set attribute %s: %s", attrName, tostring(err)))
    end
end

local function fireWatchers(entry: FlagEntry)
    local canonical = entry.canonical
    local named = watchers[canonical]
    if named then
        for _, callback in ipairs(named) do
            task.spawn(callback, entry.current, entry.name)
        end
    end

    local global = watchersAll["*"]
    if global then
        for _, callback in ipairs(global) do
            task.spawn(callback, entry.name, entry.current)
        end
    end
end

local function recompute(entry: FlagEntry, shouldNotify: boolean)
    local previous = entry.current
    local candidate = entry.override
    if candidate == nil then
        candidate = entry.default
    end

    entry.current = candidate and true or false

    updateAttribute(entry)

    if shouldNotify and previous ~= entry.current then
        fireWatchers(entry)
    end
end

local function ensureEntry(flagName: string): FlagEntry?
    local canonical = canonicalize(flagName)
    if not canonical then
        return nil
    end

    local entry = entries[canonical]
    if entry then
        return entry
    end

    return registerFlag(flagName, false)
end

local function resolvePlaceOverridesForCurrentGame(): FlagOverrideMap?
    local seen: { [string]: boolean } = {}

    local function check(candidate: any): FlagOverrideMap?
        local normalized = normalizePlaceKey(candidate)
        if not normalized or seen[normalized] then
            return nil
        end
        seen[normalized] = true
        return placeOverrides[normalized]
    end

    local override = check(game.PlaceId)
    if override then
        return override
    end

    override = check(game.GameId)
    if override then
        return override
    end

    override = check("*")
    if override then
        return override
    end

    return nil
end

local function applyPlaceOverrides()
    local overrides = resolvePlaceOverridesForCurrentGame()
    if typeof(overrides) ~= "table" then
        return
    end

    for name, value in pairs(overrides :: any) do
        local entry = ensureEntry(name)
        if entry then
            entry.default = value and true or false
            entry.override = nil
            entry.current = entry.default
        end
    end
end

local function applyDefaultOverrides(map: any)
    if typeof(map) ~= "table" then
        return
    end

    for flagName, flagValue in pairs(map :: any) do
        if typeof(flagName) == "string" then
            local entry = ensureEntry(flagName)
            if entry then
                local coerced = flagValue == true
                entry.default = coerced
                if entry.override == nil then
                    entry.current = entry.default
                end
            end
        end
    end
end

local function snapshotDefaultFlags(): FlagSnapshot
    local snapshot: FlagSnapshot = {}
    for _, entry in pairs(entries) do
        snapshot[entry.name] = entry.default
    end
    return snapshot
end

local function snapshotPlaceOverrideTable(): { [string]: FlagSnapshot }
    local snapshot: { [string]: FlagSnapshot } = {}
    for key, overrides in pairs(placeOverrides) do
        local clone: FlagSnapshot = {}
        for flagName, value in pairs(overrides) do
            clone[flagName] = value and true or false
        end
        snapshot[key] = clone
    end
    return snapshot
end

local buildInfoModule = ReplicatedStorage:FindFirstChild("Shared")
local buildInfo
if buildInfoModule then
    buildInfoModule = (buildInfoModule :: Instance):FindFirstChild("Config")
    if buildInfoModule then
        local moduleScript = (buildInfoModule :: Instance):FindFirstChild("BuildInfo")
        if moduleScript and moduleScript:IsA("ModuleScript") then
            local ok, info = pcall(require, moduleScript)
            if ok and typeof(info) == "table" then
                buildInfo = info
            end
        end
    end
end

local metadata: CheckpointMetadata = {
    Version = string.format("place-%d", game.PlaceVersion),
    Commit = "local-dev",
    GeneratedAt = nil,
    Flags = nil,
}

if typeof(buildInfo) == "table" then
    local cast = buildInfo :: any
    if typeof(cast.Version) == "string" and cast.Version ~= "" then
        metadata.Version = cast.Version
    end
    if typeof(cast.Commit) == "string" and cast.Commit ~= "" then
        metadata.Commit = cast.Commit
    end
    if typeof(cast.GeneratedAt) == "string" and cast.GeneratedAt ~= "" then
        metadata.GeneratedAt = cast.GeneratedAt
    end

    if typeof(cast.FlagDefaults) == "table" then
        applyDefaultOverrides(cast.FlagDefaults)
    end
    if typeof(cast.FlagOverrides) == "table" then
        mergePlaceOverrides(cast.FlagOverrides)
    end

    local nestedFlags = cast.Flags
    if typeof(nestedFlags) == "table" then
        local nestedDefaults = (nestedFlags :: any).Defaults
        if typeof(nestedDefaults) == "table" then
            applyDefaultOverrides(nestedDefaults)
        end

        local nestedOverrides = (nestedFlags :: any).PlaceOverrides
        if typeof(nestedOverrides) == "table" then
            mergePlaceOverrides(nestedOverrides)
        end
    end
end

applyPlaceOverrides()

metadata.Flags = {
    Defaults = snapshotDefaultFlags(),
    PlaceOverrides = snapshotPlaceOverrideTable(),
}

local function hydrateClientState()
    for _, entry in pairs(entries) do
        local attributeName = getAttributeName(entry)
        local value = ReplicatedStorage:GetAttribute(attributeName)
        if typeof(value) == "boolean" then
            entry.current = value
        end

        ReplicatedStorage:GetAttributeChangedSignal(attributeName):Connect(function()
            local updated = ReplicatedStorage:GetAttribute(attributeName)
            if typeof(updated) ~= "boolean" then
                return
            end

            local previous = entry.current
            entry.current = updated
            if previous ~= entry.current then
                fireWatchers(entry)
            end
        end)
    end
end

if isServer then
    for _, entry in pairs(entries) do
        updateAttribute(entry)
    end
else
    hydrateClientState()
end

Flags.Metadata = metadata

if isServer then
    pcall(game.SetAttribute, game, "BuildVersion", metadata.Version)
    pcall(game.SetAttribute, game, "BuildCommit", metadata.Commit)
    if metadata.GeneratedAt then
        pcall(game.SetAttribute, game, "BuildGeneratedAt", metadata.GeneratedAt)
    end
end

function Flags.Register(flagName: string, defaultValue: boolean?): boolean
    if typeof(flagName) ~= "string" or flagName == "" then
        return false
    end

    local entry = registerFlag(flagName, defaultValue)
    if not entry then
        return false
    end

    if defaultValue ~= nil then
        entry.default = defaultValue and true or false
        if entry.override == nil then
            entry.current = entry.default
            recompute(entry, true)
        end
    end

    if isServer then
        updateAttribute(entry)
    end

    return true
end

function Flags.Get(flagName: string): FlagValue?
    local entry = ensureEntry(flagName)
    if not entry then
        return nil
    end
    return entry.current
end

function Flags.IsEnabled(flagName: string): FlagValue
    local entry = ensureEntry(flagName)
    if not entry then
        return false
    end
    return entry.current
end

function Flags.GetDefault(flagName: string): FlagValue?
    local entry = ensureEntry(flagName)
    if not entry then
        return nil
    end
    return entry.default
end

function Flags.Set(flagName: string, value: boolean?): (FlagValue, boolean)
    local entry = ensureEntry(flagName)
    if not entry then
        return false, false
    end

    if not isServer then
        warn(string.format("[Flags] Set for '%s' ignored on client", flagName))
        return entry.current, false
    end

    local overrideValue: boolean? = nil
    if value ~= nil then
        overrideValue = value and true or false
    end

    if entry.override == overrideValue then
        return entry.current, false
    end

    entry.override = overrideValue
    recompute(entry, true)
    return entry.current, true
end

function Flags.SetMany(map: { [string]: any }): FlagSnapshot
    if not isServer then
        warn("[Flags] SetMany ignored on client")
        return Flags.GetAll()
    end

    for name, value in pairs(map) do
        if value == nil then
            Flags.Set(name, nil)
        else
            Flags.Set(name, value == true)
        end
    end

    return Flags.GetAll()
end

function Flags.Reset(flagName: string): FlagValue
    local entry = ensureEntry(flagName)
    if not entry then
        return false
    end

    if not isServer then
        warn(string.format("[Flags] Reset for '%s' ignored on client", flagName))
        return entry.current
    end

    entry.override = nil
    recompute(entry, true)
    return entry.current
end

function Flags.ResetAll(): FlagSnapshot
    if not isServer then
        warn("[Flags] ResetAll ignored on client")
        return Flags.GetAll()
    end

    for _, entry in pairs(entries) do
        entry.override = nil
        recompute(entry, true)
    end

    return Flags.GetAll()
end

function Flags.GetAll(): FlagSnapshot
    local snapshot: FlagSnapshot = {}
    for _, entry in pairs(entries) do
        snapshot[entry.name] = entry.current
    end
    return snapshot
end

function Flags.OnChanged(flagName: string, callback: FlagChangedCallback): () -> ()
    local entry = ensureEntry(flagName)
    if not entry or typeof(callback) ~= "function" then
        return function() end
    end

    local canonical = entry.canonical
    local bucket = watchers[canonical]
    if not bucket then
        bucket = {}
        watchers[canonical] = bucket
    end

    table.insert(bucket, callback)
    task.defer(callback, entry.current, entry.name)

    local disconnected = false
    return function()
        if disconnected then
            return
        end
        disconnected = true

        local list = watchers[canonical]
        if not list then
            return
        end

        for index = #list, 1, -1 do
            if list[index] == callback then
                table.remove(list, index)
                break
            end
        end
    end
end

function Flags.OnAllChanged(callback: FlagAnyChangedCallback): () -> ()
    if typeof(callback) ~= "function" then
        return function() end
    end

    local bucket = watchersAll["*"]
    if not bucket then
        bucket = {}
        watchersAll["*"] = bucket
    end

    table.insert(bucket, callback)

    for _, entry in pairs(entries) do
        task.defer(callback, entry.name, entry.current)
    end

    local disconnected = false
    return function()
        if disconnected then
            return
        end
        disconnected = true

        local list = watchersAll["*"]
        if not list then
            return
        end

        for index = #list, 1, -1 do
            if list[index] == callback then
                table.remove(list, index)
                break
            end
        end
    end
end

return Flags
