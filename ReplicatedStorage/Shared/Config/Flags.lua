--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local isServer = RunService:IsServer()

export type FlagValue = boolean | number
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

local DEFAULT_FLAGS: { [string]: FlagValue } = {
    Obstacles = true,
    Tokens = true,
    Telemetry = true,
    Achievements = true,
    CanaryPercent = 100,
}

local STATIC_PLACE_OVERRIDES: { [number | string]: { [string]: FlagValue } } = {
    -- [1234567890] = { Obstacles = false },
}

local ATTRIBUTE_PREFIX = "Flag_"

local Flags = {}

type ValueType = "boolean" | "number"

type FlagEntry = {
        name: string,
        canonical: string,
        valueType: ValueType,
        baseDefault: FlagValue,
        default: FlagValue,
        override: FlagValue?,
        current: FlagValue,
}

local entries: { [string]: FlagEntry } = {}
local watchers: { [string]: { FlagChangedCallback } } = {}
local watchersAll: { [string]: { FlagAnyChangedCallback } } = {}

type FlagOverrideMap = FlagSnapshot

local function trimString(value: string): string
    return string.gsub(value, "^%s*(.-)%s*$", "%1")
end

local function coerceToBoolean(value: any): boolean?
    local valueType = typeof(value)
    if valueType == "boolean" then
        return value
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return nil
        end
        return value ~= 0
    elseif valueType == "string" then
        local trimmed = trimString(value)
        if trimmed == "" then
            return nil
        end

        local lower = string.lower(trimmed)
        if lower == "true" or lower == "1" or lower == "yes" or lower == "y" or lower == "on" then
            return true
        elseif lower == "false" or lower == "0" or lower == "no" or lower == "n" or lower == "off" then
            return false
        end
    end

    return nil
end

local function coerceToNumber(value: any): number?
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric or numeric == math.huge or numeric == -math.huge then
        return nil
    end
    return numeric
end

local function sanitizeSnapshotValue(value: any): FlagValue?
    if value == nil then
        return nil
    end

    local valueType = typeof(value)
    if valueType == "boolean" then
        return value
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return nil
        end
        return value
    elseif valueType == "string" then
        local numeric = tonumber(value)
        if numeric then
            return numeric
        end

        local booleanValue = coerceToBoolean(value)
        if booleanValue ~= nil then
            return booleanValue
        end
    end

    return nil
end

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
                    local sanitized = sanitizeSnapshotValue(flagValue)
                    if sanitized ~= nil then
                        bucket[flagName] = sanitized
                    end
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

local numericConstraints: { [string]: { min: number?, max: number? } } = {}

local CANARY_CANONICAL = canonicalize("CanaryPercent")
if CANARY_CANONICAL then
    numericConstraints[CANARY_CANONICAL] = { min = 0, max = 100 }
end

local function registerRollout(featureName: string, percentFlag: string)
    local featureCanonical = canonicalize(featureName)
    local percentCanonical = canonicalize(percentFlag)
    if not featureCanonical or not percentCanonical then
        return
    end

    rolloutConfig[featureCanonical] = {
        percentFlag = percentFlag,
        percentCanonical = percentCanonical,
    }

    local bucket = rolloutDependencies[percentCanonical]
    if not bucket then
        bucket = {}
        rolloutDependencies[percentCanonical] = bucket
    end

    table.insert(bucket, featureCanonical)
end

local rolloutBuckets: { [string]: number } = {}
local fallbackRandomSeed = math.floor(os.clock() * 1000) % 2147483646
local fallbackRandom = Random.new(fallbackRandomSeed + 1)

local function sanitizeRolloutPercent(value: any): number
    local numeric = coerceToNumber(value)
    if numeric == nil then
        return 0
    end

    if numeric >= 0 then
        numeric = math.floor(numeric + 0.5)
    else
        numeric = math.ceil(numeric - 0.5)
    end

    return math.clamp(numeric, 0, 100)
end

local function computeRolloutBucket(canonical: string): number
    local cached = rolloutBuckets[canonical]
    if cached ~= nil then
        return cached
    end

    local jobId = game.JobId
    if typeof(jobId) == "string" and jobId ~= "" then
        local source = string.format("%s:%s:%s", tostring(game.PlaceId), jobId, canonical)
        local hash = 2166136261
        for index = 1, #source do
            hash = bit32.band(bit32.bxor(hash, string.byte(source, index)) * 16777619, 0xFFFFFFFF)
        end

        local bucket = hash % 100
        rolloutBuckets[canonical] = bucket
        return bucket
    end

    local bucket = fallbackRandom:NextInteger(0, 99)
    rolloutBuckets[canonical] = bucket
    return bucket
end

local function evaluateRollout(entry: FlagEntry, baseValue: boolean): boolean
    if not baseValue then
        return false
    end

    local config = rolloutConfig[entry.canonical]
    if not config then
        return baseValue
    end

    local percentEntry = nil
    if config.percentCanonical then
        percentEntry = entries[config.percentCanonical]
    end

    local percentValue: any = 100
    if percentEntry then
        if percentEntry.valueType == "number" and typeof(percentEntry.current) == "number" then
            percentValue = percentEntry.current
        elseif percentEntry.valueType == "boolean" then
            percentValue = percentEntry.current == true and 100 or 0
        end
    end

    local percent = sanitizeRolloutPercent(percentValue)
    if percent <= 0 then
        return false
    end
    if percent >= 100 then
        return true
    end

    local bucket = computeRolloutBucket(entry.canonical)
    return bucket < percent
end

local function applyNumericConstraint(canonical: string, numeric: number): number
    local constraint = numericConstraints[canonical]
    if constraint then
        if constraint.min ~= nil and numeric < constraint.min then
            numeric = constraint.min
        end
        if constraint.max ~= nil and numeric > constraint.max then
            numeric = constraint.max
        end
    end
    return numeric
end

local rolloutDependencies: { [string]: { string } } = {}

local rolloutConfig: { [string]: { percentFlag: string, percentCanonical: string? } } = {}

local function coerceValueForEntry(entry: FlagEntry, value: any): FlagValue?
    if value == nil then
        return nil
    end

    if entry.valueType == "number" then
        local numeric = coerceToNumber(value)
        if numeric == nil then
            return nil
        end

        numeric = applyNumericConstraint(entry.canonical, numeric)
        return numeric
    end

    local booleanValue = coerceToBoolean(value)
    if booleanValue == nil then
        return nil
    end

    return booleanValue
end

local function registerFlag(flagName: string, defaultValue: FlagValue?): FlagEntry?
    local canonical = canonicalize(flagName)
    if not canonical then
        return nil
    end

    local existing = entries[canonical]
    if existing then
        if defaultValue ~= nil then
            local coerced = coerceValueForEntry(existing, defaultValue)
            if coerced ~= nil then
                existing.baseDefault = coerced
                if existing.default == nil then
                    existing.default = coerced
                    existing.current = coerced
                end
            end
        end
        return existing
    end

    local valueType: ValueType = "boolean"
    if defaultValue ~= nil and typeof(defaultValue) == "number" then
        valueType = "number"
    end

    local baseDefault: FlagValue
    if valueType == "number" then
        local coerced = if defaultValue ~= nil then coerceToNumber(defaultValue) else nil
        baseDefault = applyNumericConstraint(canonical, coerced or 0)
    else
        local coerced = if defaultValue ~= nil then coerceToBoolean(defaultValue) else nil
        baseDefault = if coerced ~= nil then coerced else false
    end

    local entry: FlagEntry = {
        name = flagName,
        canonical = canonical,
        valueType = valueType,
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

registerRollout("Obstacles", "CanaryPercent")
registerRollout("Tokens", "CanaryPercent")
registerRollout("Telemetry", "CanaryPercent")
registerRollout("Achievements", "CanaryPercent")

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
    if candidate == nil then
        candidate = entry.baseDefault
    end

    if entry.valueType == "number" then
        local numericCandidate: number?
        if typeof(candidate) == "number" then
            numericCandidate = candidate
        else
            numericCandidate = coerceToNumber(candidate)
        end

        if numericCandidate == nil then
            if typeof(entry.baseDefault) == "number" then
                numericCandidate = entry.baseDefault
            else
                numericCandidate = 0
            end
        end

        entry.current = applyNumericConstraint(entry.canonical, numericCandidate)
    else
        local booleanCandidate: boolean
        if typeof(candidate) == "boolean" then
            booleanCandidate = candidate
        else
            local coerced = coerceToBoolean(candidate)
            booleanCandidate = coerced == true
        end

        entry.current = evaluateRollout(entry, booleanCandidate)
    end

    updateAttribute(entry)

    if shouldNotify and previous ~= entry.current then
        fireWatchers(entry)
    end

    local dependents = rolloutDependencies[entry.canonical]
    if dependents then
        for _, canonicalName in ipairs(dependents) do
            local dependentEntry = entries[canonicalName]
            if dependentEntry then
                recompute(dependentEntry, true)
            end
        end
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
            local typedValue = coerceValueForEntry(entry, value)
            if typedValue ~= nil then
                entry.default = typedValue
                entry.override = nil
                recompute(entry, false)
            end
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
                local typedValue = coerceValueForEntry(entry, flagValue)
                if typedValue ~= nil then
                    entry.default = typedValue
                    if entry.override == nil then
                        recompute(entry, false)
                    end
                end
            end
        end
    end
end

local function snapshotDefaultFlags(): FlagSnapshot
    local snapshot: FlagSnapshot = {}
    for _, entry in pairs(entries) do
        local flagName = entry.name
        local value = entry.default
        snapshot[flagName] = value
        local canonical = canonicalize(flagName)
        if canonical and canonical ~= flagName then
            snapshot[canonical] = value
        end
    end
    return snapshot
end

local function snapshotPlaceOverrideTable(): { [string]: FlagSnapshot }
    local snapshot: { [string]: FlagSnapshot } = {}
    for key, overrides in pairs(placeOverrides) do
        local clone: FlagSnapshot = {}
        for flagName, value in pairs(overrides) do
            if typeof(value) == "boolean" or typeof(value) == "number" then
                clone[flagName] = value
                local canonical = canonicalize(flagName)
                if canonical and canonical ~= flagName then
                    clone[canonical] = value
                end
            end
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
    Flags = {
        Defaults = {},
        PlaceOverrides = {},
    },
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
        local sanitized = coerceValueForEntry(entry, value)
        if sanitized ~= nil then
            entry.current = sanitized
        end

        local okSignal, changedSignal = pcall(ReplicatedStorage.GetAttributeChangedSignal, ReplicatedStorage, attributeName)
        if okSignal and typeof(changedSignal) == "RBXScriptSignal" then
            (changedSignal :: RBXScriptSignal):Connect(function()
                local updated = ReplicatedStorage:GetAttribute(attributeName)
                local coerced = coerceValueForEntry(entry, updated)
                if coerced == nil then
                    return
                end

                local previous = entry.current
                entry.current = coerced
                if previous ~= entry.current then
                    fireWatchers(entry)
                end
            end)
        end
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

function Flags.Register(flagName: string, defaultValue: FlagValue?): boolean
    if typeof(flagName) ~= "string" or flagName == "" then
        return false
    end

    local entry = registerFlag(flagName, defaultValue)
    if not entry then
        return false
    end

    if defaultValue ~= nil then
        local typedValue = coerceValueForEntry(entry, defaultValue)
        if typedValue ~= nil then
            entry.default = typedValue
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

function Flags.IsEnabled(flagName: string): boolean
    local entry = ensureEntry(flagName)
    if not entry then
        return false
    end
    if entry.valueType == "number" then
        if typeof(entry.current) == "number" then
            return entry.current ~= 0
        end
        return false
    end

    return entry.current == true
end

function Flags.GetDefault(flagName: string): FlagValue?
    local entry = ensureEntry(flagName)
    if not entry then
        return nil
    end
    return entry.default
end

function Flags.Set(flagName: string, value: FlagValue?): (FlagValue, boolean)
    local entry = ensureEntry(flagName)
    if not entry then
        return false, false
    end

    if not isServer then
        warn(string.format("[Flags] Set for '%s' ignored on client", flagName))
        return entry.current, false
    end

    local overrideValue: FlagValue? = nil
    if value ~= nil then
        local coerced = coerceValueForEntry(entry, value)
        if coerced == nil then
            return entry.current, false
        end
        overrideValue = coerced
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
        Flags.Set(name, value)
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
