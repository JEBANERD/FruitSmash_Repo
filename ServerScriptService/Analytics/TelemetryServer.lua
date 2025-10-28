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
type AggregateState = {
	primaryKey: string,
	aliases: { [string]: boolean },
	waveCount: number,
	totalCoins: number,
	tokensUsed: number,
	deaths: number,
	startedAt: string?,
	lastArena: string?,
	lastParty: string?,
	lastMatch: string?,
	lastSession: string?,
	lastLevel: number?,
	lastOutcome: string?,
	lastReason: string?,
	lastTimestamp: string?,
	completed: boolean?,
}

local TelemetryServer = {}

local sinks: { (string, Dictionary) -> () } = {}
local aggregateStates: { [string]: AggregateState } = {}
local aggregateIndex: { [string]: AggregateState } = {}
local aggregateCompleted: { [string]: number } = {}

local AGGREGATE_COMPLETION_TTL = 60

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

local WAVE_COIN_KEYS = { "coins", "coinDelta", "coinsDelta", "coinsAwarded", "coinsEarned", "coinsGained" }

local function pruneAggregateCompletion()
	local now = os.clock()
	for key, timestamp in pairs(aggregateCompleted) do
		if typeof(timestamp) ~= "number" or now - timestamp > AGGREGATE_COMPLETION_TTL then
			aggregateCompleted[key] = nil
		end
	end
end

local function makeAggregateKey(kind: string, value: any): string?
	if value == nil then
		return nil
	end

	local valueType = typeof(value)
	if valueType == "string" then
		local trimmed = trimString(value)
		if trimmed == "" then
			return nil
		end
		return kind .. ":" .. trimmed
	elseif valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		return kind .. ":" .. tostring(value)
	elseif valueType == "boolean" then
		return kind .. ":" .. (value and "true" or "false")
	end

	return kind .. ":" .. tostring(value)
end

local function sanitizeIdentifierForSummary(value: any): string?
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
	elseif valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end

		if math.abs(value - math.floor(value)) < 1e-6 then
			if value >= 0 then
				return tostring(math.floor(value + 0.5))
			else
				return tostring(-math.floor(-value + 0.5))
			end
		end

		return tostring(value)
	elseif valueType == "boolean" then
		return value and "true" or "false"
	end

	return tostring(value)
end

local function registerAggregateAlias(state: AggregateState, key: string?)
	if not key then
		return
	end

	aggregateIndex[key] = state
	state.aliases[key] = true
end

local function clearAggregateAliases(state: AggregateState)
	for key in pairs(state.aliases) do
		if key ~= state.primaryKey then
			state.aliases[key] = nil
			if aggregateIndex[key] == state then
				aggregateIndex[key] = nil
			end
		end
	end

	aggregateIndex[state.primaryKey] = state
	state.aliases[state.primaryKey] = true
end

local function updateAggregateContext(state: AggregateState, payload: Dictionary?)
	if not payload then
		return
	end

	local timestamp = payload.timestamp
	if typeof(timestamp) == "string" and timestamp ~= "" then
		state.lastTimestamp = timestamp
	end

	local levelValue = payload.level
	local levelNumber = if typeof(levelValue) == "number" then levelValue else tonumber(levelValue)
	if levelNumber and levelNumber == levelNumber and levelNumber ~= math.huge and levelNumber ~= -math.huge then
		state.lastLevel = levelNumber
	end

	local outcomeValue = payload.outcome
	if typeof(outcomeValue) == "string" and outcomeValue ~= "" then
		state.lastOutcome = outcomeValue
	end

	local reasonValue = payload.reason
	if typeof(reasonValue) == "string" and reasonValue ~= "" then
		state.lastReason = reasonValue
	end

	local arenaKey = makeAggregateKey("arena", payload.arenaId)
	if arenaKey then
		registerAggregateAlias(state, arenaKey)
		state.lastArena = sanitizeIdentifierForSummary(payload.arenaId)
	end

	local partyKey = makeAggregateKey("party", payload.partyId)
	if partyKey then
		registerAggregateAlias(state, partyKey)
		state.lastParty = sanitizeIdentifierForSummary(payload.partyId)
	end

	local matchKey = makeAggregateKey("match", payload.matchId)
	if matchKey then
		registerAggregateAlias(state, matchKey)
		state.lastMatch = sanitizeIdentifierForSummary(payload.matchId)
	end

	local sessionKey = makeAggregateKey("session", payload.sessionId)
	if sessionKey then
		registerAggregateAlias(state, sessionKey)
		state.lastSession = sanitizeIdentifierForSummary(payload.sessionId)
	end
end

local function resetAggregateState(state: AggregateState, payload: Dictionary?)
	clearAggregateAliases(state)

	state.waveCount = 0
	state.totalCoins = 0
	state.tokensUsed = 0
	state.deaths = 0
	state.startedAt = nil
	state.lastArena = nil
	state.lastParty = nil
	state.lastMatch = nil
	state.lastSession = nil
	state.lastLevel = nil
	state.lastOutcome = nil
	state.lastReason = nil
	state.lastTimestamp = nil
	state.completed = false

	if payload then
		local timestamp = payload.timestamp
		if typeof(timestamp) == "string" and timestamp ~= "" then
			state.startedAt = timestamp
			state.lastTimestamp = timestamp
		end
	end

	updateAggregateContext(state, payload)
end

local function findAggregateState(payload: Dictionary?): AggregateState?
	if not payload then
		return nil
	end

	local matchKey = makeAggregateKey("match", payload.matchId)
	if matchKey then
		local matchState = aggregateIndex[matchKey]
		if matchState then
			return matchState
		end
	end

	local arenaKey = makeAggregateKey("arena", payload.arenaId)
	if arenaKey then
		local arenaState = aggregateIndex[arenaKey]
		if arenaState then
			return arenaState
		end
	end

	local partyKey = makeAggregateKey("party", payload.partyId)
	if partyKey then
		local partyState = aggregateIndex[partyKey]
		if partyState then
			return partyState
		end
	end

	local sessionKey = makeAggregateKey("session", payload.sessionId)
	if sessionKey then
		return aggregateIndex[sessionKey]
	end

	return nil
end

local function resolvePrimaryKey(payload: Dictionary?): string?
	if not payload then
		return nil
	end

	local key = makeAggregateKey("match", payload.matchId)
	if key then
		return key
	end

	key = makeAggregateKey("arena", payload.arenaId)
	if key then
		return key
	end

	key = makeAggregateKey("party", payload.partyId)
	if key then
		return key
	end

	key = makeAggregateKey("session", payload.sessionId)
	if key then
		return key
	end

	return nil
end

local function clearCompletionForPayload(payload: Dictionary?)
	if not payload then
		return
	end

	local keys = {
		makeAggregateKey("match", payload.matchId),
		makeAggregateKey("arena", payload.arenaId),
		makeAggregateKey("party", payload.partyId),
		makeAggregateKey("session", payload.sessionId),
	}

	for _, key in ipairs(keys) do
		if key then
			aggregateCompleted[key] = nil
		end
	end
end

local function createAggregateState(payload: Dictionary?): AggregateState?
	if not payload then
		return nil
	end

	pruneAggregateCompletion()

	local primaryKey = resolvePrimaryKey(payload)
	if not primaryKey then
		return nil
	end

	if aggregateCompleted[primaryKey] ~= nil then
		return nil
	end

	local state: AggregateState = {
		primaryKey = primaryKey,
		aliases = {},
		waveCount = 0,
		totalCoins = 0,
		tokensUsed = 0,
		deaths = 0,
		startedAt = nil,
		lastArena = nil,
		lastParty = nil,
		lastMatch = nil,
		lastSession = nil,
		lastLevel = nil,
		lastOutcome = nil,
		lastReason = nil,
		lastTimestamp = nil,
		completed = false,
	}

	aggregateStates[primaryKey] = state
	state.aliases[primaryKey] = true
	aggregateIndex[primaryKey] = state

	resetAggregateState(state, payload)
	return state
end

local function markAggregateCompleted(state: AggregateState)
	pruneAggregateCompletion()

	local now = os.clock()
	for key in pairs(state.aliases) do
		aggregateCompleted[key] = now
	end
end

local function removeAggregateState(state: AggregateState)
	aggregateStates[state.primaryKey] = nil

	for key in pairs(state.aliases) do
		if aggregateIndex[key] == state then
			aggregateIndex[key] = nil
		end
	end
end

local function formatNumber(value: number): string
	if value ~= value or value == math.huge or value == -math.huge then
		return "0"
	end

	if math.abs(value - math.floor(value)) < 1e-6 then
		if value >= 0 then
			return tostring(math.floor(value + 0.5))
		else
			return tostring(-math.floor(-value + 0.5))
		end
	end

	local formatted = string.format("%.2f", value)
	formatted = string.gsub(formatted, "0+$", "")
	formatted = string.gsub(formatted, "%.$", "")
	if formatted == "" then
		return "0"
	end
	return formatted
end

local function formatSummaryEntry(key: string, value: any): string?
	if value == nil then
		return nil
	end

	local valueType = typeof(value)
	if valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		return string.format("\"%s\":%s", key, formatNumber(value))
	elseif valueType == "boolean" then
		return string.format("\"%s\":%s", key, value and "true" or "false")
	end

	local printable = sanitizeIdentifierForSummary(value)
	if not printable then
		return nil
	end

	local escaped = escapeJsonString(printable)
	return string.format("\"%s\":\"%s\"", key, escaped)
end

local function extractNumberFromPayload(payload: Dictionary, keys: { string }): number?
	for _, key in ipairs(keys) do
		local rawValue = payload[key]
		if rawValue ~= nil then
			local valueType = typeof(rawValue)
			if valueType == "number" then
				if rawValue == rawValue and rawValue ~= math.huge and rawValue ~= -math.huge then
					return rawValue
				end
			elseif valueType == "string" then
				local numeric = tonumber(rawValue)
				if numeric and numeric == numeric and numeric ~= math.huge and numeric ~= -math.huge then
					return numeric
				end
			end
		end
	end

	return nil
end

local function emitAggregateSummary(state: AggregateState, payload: Dictionary?)
	local totalCoins = state.totalCoins
	if totalCoins ~= totalCoins or totalCoins == math.huge or totalCoins == -math.huge then
		totalCoins = 0
	end

	local waveCount = state.waveCount
	if waveCount < 0 then
		waveCount = 0
	end

	local avgCoins = 0
	if waveCount > 0 then
		avgCoins = totalCoins / waveCount
	end

	local pieces = {}

	local function addField(key: string, value: any)
		local entry = formatSummaryEntry(key, value)
		if entry then
			table.insert(pieces, entry)
		end
	end
	
	local formatted = DateTime.now():FormatUniversalTime("YYYY-MM‑DDTHH:mm:ssZ", "en-us")


	addField("event", "MatchSummary")
	addField("timestamp", DateTime.now().UnixTimestamp)
	addField("arena", state.lastArena)
	addField("party", state.lastParty)
	addField("match", state.lastMatch)
	addField("session", state.lastSession)
	addField("level", state.lastLevel)
	addField("outcome", state.lastOutcome or (payload and payload.outcome))
	addField("reason", state.lastReason or (payload and payload.reason))
	addField("waves", waveCount)
	addField("totalCoins", totalCoins)
	addField("avgCoinsPerWave", avgCoins)
	addField("tokensUsed", state.tokensUsed)
	addField("deaths", state.deaths)
	addField("startedAt", state.startedAt)
	addField("endedAt", state.lastTimestamp or (payload and payload.timestamp))

	print(string.format("[TelemetrySummary] {%s}", table.concat(pieces, ",")))
end

local function processAggregateEvent(payload: Dictionary)
	local eventValue = payload.event
	if typeof(eventValue) ~= "string" then
		return
	end

	local eventName = eventValue

	if eventName == "MatchStart" then
		clearCompletionForPayload(payload)

		local state = findAggregateState(payload)
		if not state then
			state = createAggregateState(payload)
		else
			resetAggregateState(state, payload)
		end

		if state then
			updateAggregateContext(state, payload)
		end

		return
	elseif eventName == "MatchEnd" then
		local state = findAggregateState(payload)
		if not state then
			state = createAggregateState(payload)
		end

		if not state then
			return
		end

		if state.completed then
			return
		end

		updateAggregateContext(state, payload)
		state.completed = true
		emitAggregateSummary(state, payload)
		markAggregateCompleted(state)
		removeAggregateState(state)
		return
	elseif eventName == "Wave" then
		local state = findAggregateState(payload)
		if not state then
			state = createAggregateState(payload)
		end

		if not state then
			return
		end

		state.waveCount += 1
		updateAggregateContext(state, payload)

		local coinsValue = extractNumberFromPayload(payload, WAVE_COIN_KEYS)
		if coinsValue then
			state.totalCoins += coinsValue
		end

		return
	elseif eventName == "TokenUse" then
		local state = findAggregateState(payload)
		if not state then
			state = createAggregateState(payload)
		end

		if not state then
			return
		end

		state.tokensUsed += 1
		updateAggregateContext(state, payload)
		return
	elseif eventName == "ObstacleHit" then
		local state = findAggregateState(payload)
		if not state then
			state = createAggregateState(payload)
		end

		if not state then
			return
		end

		state.deaths += 1
		updateAggregateContext(state, payload)
		return
	else
		local state = findAggregateState(payload)
		if state then
			updateAggregateContext(state, payload)
		end
	end
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
		timestamp = DateTime.now().UnixTimestamp,
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
	processAggregateEvent(payload)
	enqueuePrint(payload)

	local eventField = payload.event
	local eventName = if typeof(eventField) == "string" then eventField else tostring(eventField)

	for _, sink in ipairs(sinks) do
		local ok, err = pcall(function()
			sink(eventName, payload)
		end)
		if not ok then
			warn(string.format("[Telemetry] Sink failed for %s: %s", eventName, tostring(err)))
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

function TelemetryServer.Flush()
	flushPrintQueue()
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

TelemetryServer.SetEnabled(enabled)

if FlagsModule and typeof((FlagsModule :: any).OnChanged) == "function" then
	(FlagsModule :: any).OnChanged("Telemetry", function(isEnabled)
		TelemetryServer.SetEnabled(isEnabled)
	end)
end
end 
return TelemetryServer
