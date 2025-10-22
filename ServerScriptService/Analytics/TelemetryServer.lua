--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

type Dictionary = { [string]: any }
type FieldSpec = {
        name: string,
        source: string | { string }?,
        transform: ((any) -> any)?,
        default: any?,
}
type EventSpec = {
        name: string?,
        aliases: { string }?,
        fields: { FieldSpec }?,
        copyUnknownSimple: boolean?,
        extraLimit: number?,
        defaults: Dictionary?,
}

local TelemetryServer = {}

local sinks: { (string, Dictionary) -> () } = {}

local FlagsModule
do
    local ok, module = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Flags"))
    end)
    if ok and typeof(module) == "table" then
        FlagsModule = module
    end
end

local function resolveTelemetryFlag(): boolean
    if FlagsModule and typeof((FlagsModule :: any).IsEnabled) == "function" then
        local ok, result = pcall((FlagsModule :: any).IsEnabled, "Telemetry")
        if ok and typeof(result) == "boolean" then
            return result
        end
    end
    return true
end

local enabled = resolveTelemetryFlag()
local enabled = true
local printQueue: { Dictionary } = {}
local flushScheduled = false

local MAX_QUEUE_BEFORE_FLUSH = 6
local RESERVED_EXTRA_KEYS = {
        event = true,
        timestamp = true,
        v = true,
}

local function trimString(value: string): string
        local trimmed = string.gsub(value, "^%s+", "")
        trimmed = string.gsub(trimmed, "%s+$", "")
        return trimmed
end

local function escapeJsonString(value: string): string
        local escaped = string.gsub(value, "\\", "\\\\")
        escaped = string.gsub(escaped, "\"", "\\\"")
        escaped = string.gsub(escaped, "\n", "\\n")
        escaped = string.gsub(escaped, "\r", "\\r")
        escaped = string.gsub(escaped, "\t", "\\t")
        return escaped
end

local function coerceInteger(value: any): number?
        local numeric = tonumber(value)
        if numeric == nil then
                return nil
        end

        if numeric ~= numeric or numeric == math.huge or numeric == -math.huge then
                return nil
        end

        if numeric >= 0 then
                return math.floor(numeric + 0.5)
        end

        return -math.floor(-numeric + 0.5)
end

local function coerceNumber(value: any): number?
        local numeric = tonumber(value)
        if numeric == nil then
                return nil
        end

        if numeric ~= numeric or numeric == math.huge or numeric == -math.huge then
                return nil
        end

        return numeric
end

local function coerceSeconds(value: any): number?
        local numeric = coerceNumber(value)
        if numeric == nil then
                return nil
        end

        local scaled = numeric * 1000
        if numeric >= 0 then
                scaled = scaled + 0.5
        else
                scaled = scaled - 0.5
        end

        return math.floor(scaled) / 1000
end

local function coerceString(value: any): string?
        local valueType = typeof(value)
        if valueType == "string" then
                local trimmed = trimString(value)
                if trimmed == "" then
                        return nil
                end
                return trimmed
        elseif valueType == "number" then
                if value ~= value or value == math.huge or value == -math.huge then
                        return nil
                end
                return tostring(value)
        elseif valueType == "boolean" then
                return if value then "true" else "false"
        elseif valueType == "EnumItem" then
                return tostring(value)
        end

        return nil
end

local function coerceIdentifier(value: any): string?
        if value == nil then
                return nil
        end

        local valueType = typeof(value)
        if valueType == "string" then
                local trimmed = trimString(value)
                if trimmed == "" then
                        return nil
                end
                return trimmed
        end

        local integer = coerceInteger(value)
        if integer ~= nil then
                return tostring(integer)
        end

        if valueType == "EnumItem" then
                return tostring(value)
        end

        return nil
end

local function coerceBoolean(value: any): boolean?
        if value == nil then
                return nil
        end

        local valueType = typeof(value)
        if valueType == "boolean" then
                return value
        elseif valueType == "number" then
                if value == 0 then
                        return false
                end
                return true
        elseif valueType == "string" then
                local trimmed = trimString(value)
                if trimmed == "" then
                        return nil
                end

                local lower = string.lower(trimmed)
                if lower == "true" or lower == "1" or lower == "yes" or lower == "y" then
                        return true
                elseif lower == "false" or lower == "0" or lower == "no" or lower == "n" then
                        return false
                end
        end

        return nil
end

local function makeField(name: string, source: string | { string }?, transform: ((any) -> any)?, defaultValue: any?): FieldSpec
        return {
                name = name,
                source = source,
                transform = transform,
                default = defaultValue,
        }
end

local function sanitizeValue(value: any, depth: number): any
        if depth > 4 then
                return "<max-depth>"
        end

        local valueType = typeof(value)
        if valueType == "table" then
                local copy: Dictionary = {}
                for key, item in pairs(value) do
                        local keyType = typeof(key)
                        local keyString = if keyType == "string" or keyType == "number"
                                then tostring(key)
                                else string.format("[%s]", keyType)
                        copy[keyString] = sanitizeValue(item, depth + 1)
                end
                return copy
        elseif valueType == "Instance" then
                local ok, result = pcall(function()
                        return value:GetFullName()
                end)
                return if ok then result else value.ClassName
        elseif valueType == "EnumItem" then
                return tostring(value)
        elseif valueType == "number" then
                if value ~= value or value == math.huge or value == -math.huge then
                        return 0
                end
                return value
        elseif valueType == "boolean" or valueType == "string" then
                return value
        elseif valueType == "DateTime" then
                local ok, iso = pcall(value.ToIsoDateTime, value)
                if ok then
                        return iso
                end
                return tostring(value)
        end

        return tostring(value)
end

local SESSION_PLAYER_SOURCES = { "player", "Player", "name", "Name", "username", "Username", "displayName", "DisplayName" }
local USER_ID_SOURCES = { "userId", "UserId" }
local ARENA_SOURCES = { "arenaId", "ArenaId" }
local PARTY_SOURCES = { "partyId", "PartyId", "partyID" }
local SESSION_ID_SOURCES = { "sessionId", "SessionId", "sessionID" }
local MATCH_ID_SOURCES = { "matchId", "MatchId" }
local LEVEL_SOURCES = { "level", "Level" }
local WAVE_SOURCES = { "wave", "Wave" }
local PHASE_SOURCES = { "phase", "Phase" }
local SUCCESS_SOURCES = { "success", "Success" }
local DURATION_SOURCES = { "duration", "Duration" }
local REASON_SOURCES = { "reason", "Reason" }
local OUTCOME_SOURCES = { "outcome", "Outcome", "result", "Result" }
local ITEM_ID_SOURCES = { "itemId", "ItemId", "id", "Id" }
local KIND_SOURCES = { "kind", "Kind", "category", "Category" }
local PRICE_SOURCES = { "price", "Price" }
local COINS_REMAINING_SOURCES = { "coinsRemaining", "CoinsRemaining", "coins", "Coins" }
local STOCK_REMAINING_SOURCES = { "stockRemaining", "StockRemaining" }
local STOCK_LIMIT_SOURCES = { "stockLimit", "StockLimit", "limit", "Limit" }
local TOKEN_ID_SOURCES = { "tokenId", "TokenId" }
local EFFECT_SOURCES = { "effect", "Effect" }
local REMAINING_SOURCES = { "remaining", "Remaining" }
local SLOT_SOURCES = { "slot", "Slot" }
local REFRESHED_SOURCES = { "refreshed", "Refreshed" }
local OBSTACLE_SOURCES = { "obstacle", "Obstacle" }
local DAMAGE_SOURCES = { "damage", "Damage" }
local SOURCE_PLACE_SOURCES = { "sourcePlaceId", "SourcePlaceId" }
local PLACE_SOURCES = { "placeId", "PlaceId" }
local DEVICE_SOURCES = { "device", "Device", "platform", "Platform" }
local FLAG_SOURCES = { "flag", "Flag", "code", "Code" }
local ACTION_SOURCES = { "action", "Action" }
local REMOTE_SOURCES = { "remote", "Remote", "remoteName", "RemoteName" }
local DETAIL_SOURCES = { "detail", "Detail", "description", "Description" }

local EVENT_SPECS: { [string]: EventSpec } = {
        SessionStart = {
                aliases = { "session_start", "sessionstart" },
                fields = {
                        makeField("player", SESSION_PLAYER_SOURCES, coerceString, nil),
                        makeField("userId", USER_ID_SOURCES, coerceInteger, nil),
                        makeField("sessionId", SESSION_ID_SOURCES, coerceIdentifier, nil),
                        makeField("partyId", PARTY_SOURCES, coerceIdentifier, nil),
                        makeField("arenaId", ARENA_SOURCES, coerceIdentifier, nil),
                        makeField("sourcePlaceId", SOURCE_PLACE_SOURCES, coerceInteger, nil),
                        makeField("placeId", PLACE_SOURCES, coerceInteger, nil),
                        makeField("device", DEVICE_SOURCES, coerceString, nil),
                },
                copyUnknownSimple = true,
                extraLimit = 4,
        },
        SessionEnd = {
                aliases = { "session_end", "sessionend" },
                fields = {
                        makeField("player", SESSION_PLAYER_SOURCES, coerceString, nil),
                        makeField("userId", USER_ID_SOURCES, coerceInteger, nil),
                        makeField("sessionId", SESSION_ID_SOURCES, coerceIdentifier, nil),
                        makeField("partyId", PARTY_SOURCES, coerceIdentifier, nil),
                        makeField("arenaId", ARENA_SOURCES, coerceIdentifier, nil),
                        makeField("duration", DURATION_SOURCES, coerceSeconds, nil),
                        makeField("result", OUTCOME_SOURCES, coerceString, nil),
                },
                copyUnknownSimple = true,
                extraLimit = 4,
        },
        MatchStart = {
                aliases = { "match_start", "matchstart" },
                fields = {
                        makeField("sessionId", SESSION_ID_SOURCES, coerceIdentifier, nil),
                        makeField("matchId", MATCH_ID_SOURCES, coerceIdentifier, nil),
                        makeField("arenaId", ARENA_SOURCES, coerceIdentifier, nil),
                        makeField("partyId", PARTY_SOURCES, coerceIdentifier, nil),
                        makeField("level", LEVEL_SOURCES, coerceInteger, nil),
                        makeField("playerCount", { "playerCount", "PlayerCount" }, coerceInteger, nil),
                },
                copyUnknownSimple = true,
                extraLimit = 4,
        },
        MatchEnd = {
                aliases = { "match_end", "matchend" },
                fields = {
                        makeField("sessionId", SESSION_ID_SOURCES, coerceIdentifier, nil),
                        makeField("matchId", MATCH_ID_SOURCES, coerceIdentifier, nil),
                        makeField("arenaId", ARENA_SOURCES, coerceIdentifier, nil),
                        makeField("partyId", PARTY_SOURCES, coerceIdentifier, nil),
                        makeField("level", LEVEL_SOURCES, coerceInteger, nil),
                        makeField("wave", WAVE_SOURCES, coerceInteger, nil),
                        makeField("outcome", OUTCOME_SOURCES, coerceString, nil),
                        makeField("duration", DURATION_SOURCES, coerceSeconds, nil),
                        makeField("reason", REASON_SOURCES, coerceString, nil),
                },
                copyUnknownSimple = true,
                extraLimit = 6,
        },
        Wave = {
                aliases = { "wave_complete", "wave" },
                fields = {
                        makeField("arenaId", ARENA_SOURCES, coerceIdentifier, nil),
                        makeField("partyId", PARTY_SOURCES, coerceIdentifier, nil),
                        makeField("level", LEVEL_SOURCES, coerceInteger, nil),
                        makeField("wave", WAVE_SOURCES, coerceInteger, nil),
                        makeField("success", SUCCESS_SOURCES, coerceBoolean, nil),
                        makeField("duration", DURATION_SOURCES, coerceSeconds, nil),
                        makeField("reason", REASON_SOURCES, coerceString, nil),
                },
                copyUnknownSimple = true,
                extraLimit = 6,
        },
        Purchase = {
                aliases = { "shop_purchase", "purchase" },
                fields = {
                        makeField("player", SESSION_PLAYER_SOURCES, coerceString, nil),
                        makeField("userId", USER_ID_SOURCES, coerceInteger, nil),
                        makeField("sessionId", SESSION_ID_SOURCES, coerceIdentifier, nil),
                        makeField("arenaId", ARENA_SOURCES, coerceIdentifier, nil),
                        makeField("partyId", PARTY_SOURCES, coerceIdentifier, nil),
                        makeField("itemId", ITEM_ID_SOURCES, coerceString, nil),
                        makeField("kind", KIND_SOURCES, coerceString, nil),
                        makeField("price", PRICE_SOURCES, coerceInteger, nil),
                        makeField("coinsRemaining", COINS_REMAINING_SOURCES, coerceInteger, nil),
                        makeField("stockRemaining", STOCK_REMAINING_SOURCES, coerceInteger, nil),
                        makeField("stockLimit", STOCK_LIMIT_SOURCES, coerceInteger, nil),
                },
                copyUnknownSimple = true,
                extraLimit = 3,
        },
        TokenUse = {
                aliases = { "token_used", "tokenuse" },
                fields = {
                        makeField("player", SESSION_PLAYER_SOURCES, coerceString, nil),
                        makeField("userId", USER_ID_SOURCES, coerceInteger, nil),
                        makeField("sessionId", SESSION_ID_SOURCES, coerceIdentifier, nil),
                        makeField("arenaId", ARENA_SOURCES, coerceIdentifier, nil),
                        makeField("partyId", PARTY_SOURCES, coerceIdentifier, nil),
                        makeField("tokenId", TOKEN_ID_SOURCES, coerceString, nil),
                        makeField("effect", EFFECT_SOURCES, coerceString, nil),
                        makeField("remaining", REMAINING_SOURCES, coerceInteger, nil),
                        makeField("slot", SLOT_SOURCES, coerceInteger, nil),
                        makeField("refreshed", REFRESHED_SOURCES, coerceBoolean, nil),
                },
                copyUnknownSimple = true,
                extraLimit = 3,
        },
        ObstacleHit = {
                aliases = { "obstaclehit", "obstacle_hit" },
                fields = {
                        makeField("player", SESSION_PLAYER_SOURCES, coerceString, nil),
                        makeField("userId", USER_ID_SOURCES, coerceInteger, nil),
                        makeField("sessionId", SESSION_ID_SOURCES, coerceIdentifier, nil),
                        makeField("arenaId", ARENA_SOURCES, coerceIdentifier, nil),
                        makeField("partyId", PARTY_SOURCES, coerceIdentifier, nil),
                        makeField("obstacle", OBSTACLE_SOURCES, coerceString, nil),
                        makeField("damage", DAMAGE_SOURCES, coerceNumber, nil),
                        makeField("level", LEVEL_SOURCES, coerceInteger, nil),
                        makeField("phase", PHASE_SOURCES, coerceString, nil),
                        makeField("wave", WAVE_SOURCES, coerceInteger, nil),
                        makeField("source", { "source", "Source" }, coerceString, nil),
                },
                copyUnknownSimple = true,
                extraLimit = 6,
        },
        ExploitFlag = {
                aliases = { "exploit_flag", "exploitflag", "guard_flag" },
                fields = {
                        makeField("player", SESSION_PLAYER_SOURCES, coerceString, nil),
                        makeField("userId", USER_ID_SOURCES, coerceInteger, nil),
                        makeField("sessionId", SESSION_ID_SOURCES, coerceIdentifier, nil),
                        makeField("flag", FLAG_SOURCES, coerceString, nil),
                        makeField("action", ACTION_SOURCES, coerceString, nil),
                        makeField("reason", REASON_SOURCES, coerceString, nil),
                        makeField("detail", DETAIL_SOURCES, coerceString, nil),
                        makeField("remote", REMOTE_SOURCES, coerceString, nil),
                        makeField("component", { "component", "Component" }, coerceString, nil),
                        makeField("subsystem", { "subsystem", "Subsystem" }, coerceString, nil),
                },
                copyUnknownSimple = true,
                extraLimit = 6,
        },
}

local function canonicalizeEventKey(eventName: string): string
        local trimmed = trimString(eventName)
        local lower = string.lower(trimmed)
        local canonical = string.gsub(lower, "[^%w]", "")
        if canonical == "" then
                return lower
        end
        return canonical
end

local EVENT_LOOKUP: { [string]: EventSpec } = {}
for eventName, spec in pairs(EVENT_SPECS) do
        spec.name = eventName

        local aliases = { eventName }
        if spec.aliases then
                for _, alias in ipairs(spec.aliases) do
                        aliases[#aliases + 1] = alias
                end
        end

        for _, alias in ipairs(aliases) do
                local key = canonicalizeEventKey(alias)
                if key ~= "" then
                        EVENT_LOOKUP[key] = spec
                end
        end
end

local function resolveEventSpec(eventName: string): EventSpec?
        local key = canonicalizeEventKey(eventName)
        if key == "" then
                return nil
        end

        return EVENT_LOOKUP[key]
end

local function pickSourceValue(source: Dictionary?, key: string | { string }?): any
        if source == nil or key == nil then
                return nil
        end

        if typeof(key) == "string" then
                return source[key]
        end

        if typeof(key) == "table" then
                for _, option in ipairs(key :: { string }) do
                        local value = source[option]
                        if value ~= nil then
                                return value
                        end
                end
        end

        return nil
end

local function applyFields(result: Dictionary, rawData: Dictionary?, fields: { FieldSpec }?)
        if not fields then
                return
        end

        for _, fieldSpec in ipairs(fields) do
                local name = fieldSpec.name
                if typeof(name) == "string" and name ~= "" then
                        local sourceKey = fieldSpec.source or name
                        local rawValue = pickSourceValue(rawData, sourceKey)
                        if rawValue == nil then
                                rawValue = fieldSpec.default
                        end

                        local transform = fieldSpec.transform
                        if rawValue ~= nil and transform then
                                local ok, transformed = pcall(transform, rawValue)
                                if ok then
                                        rawValue = transformed
                                else
                                        rawValue = nil
                                end
                        end

                        if rawValue ~= nil then
                                result[name] = rawValue
                        end
                end
        end
end

local function includeUnknownSimple(result: Dictionary, rawData: Dictionary?, spec: EventSpec)
        if not spec.copyUnknownSimple or rawData == nil then
                return
        end

        local limit = spec.extraLimit or 6
        local added = 0
        for key, value in pairs(rawData) do
                if typeof(key) == "string" and result[key] == nil and not RESERVED_EXTRA_KEYS[key] then
                        local valueType = typeof(value)
                        if valueType == "string" or valueType == "number" or valueType == "boolean" then
                                result[key] = value
                                added = added + 1
                                if added >= limit then
                                        break
                                end
                        end
                end
        end
end

local function normalizeEventData(eventName: string, data: any): (string, Dictionary)
        local spec = resolveEventSpec(eventName)
        local normalizedName = if spec and spec.name then spec.name else eventName
        local normalized: Dictionary = {}
        local rawData: Dictionary? = if typeof(data) == "table" then data :: Dictionary else nil

        if spec then
                applyFields(normalized, rawData, spec.fields)
                includeUnknownSimple(normalized, rawData, spec)
                if spec.defaults then
                        for key, value in pairs(spec.defaults) do
                                if normalized[key] == nil then
                                        normalized[key] = value
                                end
                        end
                end
        else
                if rawData then
                        for key, value in pairs(rawData) do
                                if typeof(key) == "string" then
                                        normalized[key] = value
                                end
                        end
                elseif data ~= nil then
                        normalized.value = data
                end
        end

        return normalizedName, normalized
end

local function buildPayload(eventName: string, data: any): Dictionary
        local normalizedName, normalizedData = normalizeEventData(eventName, data)
        local payload: Dictionary = {
                event = sanitizeValue(normalizedName, 1),
                timestamp = DateTime.now():ToIsoDateTime(),
                v = 2,
        }

        for key, value in pairs(normalizedData) do
                if typeof(key) == "string" and value ~= nil then
                        payload[key] = sanitizeValue(value, 1)
                end
        end

        return payload
end

local function emitPrint(payload: Dictionary)
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, payload)
        if ok then
                print(string.format("[Telemetry] %s", encoded))
                return
        end

        local fallbackPayload = {
                event = sanitizeValue(payload.event or "Unknown", 1),
                encodingError = tostring(encoded),
        }

        local fallbackOk, fallbackEncoded = pcall(HttpService.JSONEncode, HttpService, fallbackPayload)
        if fallbackOk then
                print(string.format("[Telemetry] %s", fallbackEncoded))
                return
        end

        local eventName = escapeJsonString(tostring(payload.event or "Unknown"))
        local message = escapeJsonString(tostring(encoded))
        print(string.format("[Telemetry] {\"event\":\"%s\",\"encodingError\":\"%s\"}", eventName, message))
end

local function flushPrintQueue()
        flushScheduled = false
        if #printQueue == 0 then
                return
        end

        if not enabled then
                table.clear(printQueue)
                return
        end

        for index = 1, #printQueue do
                local payload = printQueue[index]
                if payload then
                        emitPrint(payload)
                end
                printQueue[index] = nil
        end
        table.clear(printQueue)
end

local function enqueuePrint(payload: Dictionary)
        printQueue[#printQueue + 1] = payload
        if #printQueue >= MAX_QUEUE_BEFORE_FLUSH then
                flushPrintQueue()
                return
        end

        if not flushScheduled then
                flushScheduled = true
                task.defer(flushPrintQueue)
        end
end

local function dispatch(payload: Dictionary)
        enqueuePrint(payload)

        local eventField = payload.event
        local eventName = if typeof(eventField) == "string" then eventField else tostring(eventField)

        for _, sink in ipairs(sinks) do
                local ok, err = pcall(sink, eventName, payload)
                if not ok then
                        warn(string.format("[Telemetry] Sink failed for %s: %s", eventName, tostring(err)))
                end
        end
end

function TelemetryServer.Track(eventName: string, data: any?)
        if not enabled then
                return
        end

        if typeof(eventName) ~= "string" then
                return
        end

        local trimmed = trimString(eventName)
        if trimmed == "" then
                return
        end

        local payload = buildPayload(trimmed, data)
        dispatch(payload)
end

function TelemetryServer.AddSink(callback: (string, Dictionary) -> ())
        if typeof(callback) ~= "function" then
                return
        end

        table.insert(sinks, callback)
end

function TelemetryServer.SetEnabled(isEnabled: boolean)
        enabled = isEnabled and true or false
        if not enabled then
                table.clear(printQueue)
                flushScheduled = false
        end
end

function TelemetryServer.IsEnabled(): boolean
        return enabled
end

if FlagsModule and typeof((FlagsModule :: any).OnChanged) == "function" then
        (FlagsModule :: any).OnChanged("Telemetry", function(isEnabled)
                TelemetryServer.SetEnabled(isEnabled)
        end)
end

return TelemetryServer
