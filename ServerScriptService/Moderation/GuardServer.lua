--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

export type RateLimitConfig = {
	maxCalls: number?,
	interval: number?,
	count: number?,
	window: number?,
	period: number?,
	seconds: number?,
}

export type GuardConfig = {
	rateLimit: RateLimitConfig?,
	validator: ((Player, ...any) -> (boolean, any?))?,
	remoteName: string?,
	rejectResponse: any?,
	handler: ((Player, any?) -> any?)?,
}

local Guard = {}

type RateBucket = { count: number, windowStart: number }

type RateBucketMap = { [Player]: RateBucket }

type RateState = { [Instance]: RateBucketMap }

local rateState: RateState = setmetatable({}, { __mode = "k" })

local function shallowCopy(tbl: { [any]: any }): { [any]: any }
	local copy = {}
	for key, value in pairs(tbl) do
		copy[key] = value
	end
	return copy
end

local function formatPlayer(player: any): string
	if typeof(player) == "Instance" and player:IsA("Player") then
		return string.format("%s (%d)", player.Name, player.UserId)
	end
	return tostring(player)
end

local function logDenial(remoteName: string, player: any, reason: string?, detail: any?)
	local message = string.format("[Guard] %s blocked %s: %s", remoteName, formatPlayer(player), reason or "Rejected")
	if detail ~= nil then
		message = message .. " :: " .. tostring(detail)
	end
	warn(message)
end

local function normalizeRateLimit(limit: RateLimitConfig?): { maxCalls: number, interval: number }?
	if typeof(limit) ~= "table" then
		return nil
	end

	local maxCalls = limit.maxCalls or limit.count or limit.max
	local interval = limit.interval or limit.window or limit.period or limit.seconds

	maxCalls = tonumber(maxCalls)
	interval = tonumber(interval)

	if not maxCalls or maxCalls <= 0 then
		return nil
	end
	if not interval or interval <= 0 then
		return nil
	end

	return {
		maxCalls = math.max(1, math.floor(maxCalls)),
		interval = math.max(interval, 0.01),
	}
end

local function ensureBucket(remote: Instance, player: Player): RateBucket
	local remoteBuckets = rateState[remote]
	if not remoteBuckets then
		remoteBuckets = setmetatable({}, { __mode = "k" })
		rateState[remote] = remoteBuckets
	end

	local bucket = remoteBuckets[player]
	if not bucket then
		bucket = { count = 0, windowStart = 0 }
		remoteBuckets[player] = bucket
	end

	return bucket
end

local function isThrottled(remote: Instance, player: Player, limit: { maxCalls: number, interval: number }?): boolean
	if not limit then
		return false
	end

	local bucket = ensureBucket(remote, player)
	local now = os.clock()

	if now - bucket.windowStart >= limit.interval then
		bucket.windowStart = now
		bucket.count = 0
	end

	if bucket.count >= limit.maxCalls then
		return true
	end

	bucket.count += 1
	return false
end

local function runValidator(remote: Instance, validator: (Player, ...any) -> (boolean, any?), player: Player, rawArgs: { any } & { n: number }): (boolean, any, any)
	local success, first, second, third = pcall(validator, player, table.unpack(rawArgs, 1, rawArgs.n))
	if not success then
		return false, "ValidatorError", first
	end
	if first == false then
		local reason = if typeof(second) == "string" then second else "InvalidPayload"
		return false, reason, third
	end
	if first == true then
		return true, second, third
	end
	return true, first, second
end

local function cloneRejectResponse(reject: any): any
	if typeof(reject) ~= "table" then
		return reject
	end
	return shallowCopy(reject)
end

local function makeRejectResponse(config: GuardConfig, reason: string?): any
	local reject = config.rejectResponse
	local finalReason = if typeof(reason) == "string" and reason ~= "" then reason else "Rejected"

	if typeof(reject) == "function" then
		local ok, result = pcall(reject, finalReason)
		if ok then
			return result
		end
	elseif reject ~= nil then
		local response = cloneRejectResponse(reject)
		if typeof(response) == "table" then
			response.err = finalReason
		end
		return response
	end

	return { ok = false, err = finalReason }
end

local function isValidPlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player")
end

local GameConfigModule: any = nil
do
	local ok, moduleInstance = pcall(function()
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local configFolder = shared and shared:FindFirstChild("Config")
		return configFolder and configFolder:FindFirstChild("GameConfig")
	end)
	if ok and moduleInstance and moduleInstance:IsA("ModuleScript") then
		local okRequire, result = pcall(require, moduleInstance)
		if okRequire then
			GameConfigModule = result
		else
			warn(string.format("[Guard] Failed to require GameConfig: %s", tostring(result)))
		end
	end
end

local GameConfig = GameConfigModule
if typeof(GameConfigModule) == "table" and typeof(GameConfigModule.Get) == "function" then
	local okGet, config = pcall(GameConfigModule.Get)
	if okGet and typeof(config) == "table" then
		GameConfig = config
	end
end
if typeof(GameConfig) ~= "table" then
	GameConfig = {}
end

local playerConfig = GameConfig.Player or {}
local sprintConfig = playerConfig.Sprint or {}
local powerUpsConfig = GameConfig.PowerUps or {}
local speedBoostConfig = powerUpsConfig.SpeedBoost or {}

local DEFAULT_BASE_WALK_SPEED = sprintConfig.BaseWalkSpeed or 16
local DEFAULT_BASE_SPRINT_SPEED = sprintConfig.BaseSprintSpeed or math.max(DEFAULT_BASE_WALK_SPEED * 1.25, DEFAULT_BASE_WALK_SPEED)
local DEFAULT_SPEEDBOOST_MULTIPLIER = speedBoostConfig.SpeedMultiplier or 1.35

local SWING_MIN_INTERVAL = 0.26
local SWING_WINDOW_SECONDS = 1.5
local SWING_MAX_PER_WINDOW = 5

local SPEED_TOLERANCE = 1.5
local MULTIPLIER_EPSILON = 0.05

local TELEPORT_DISTANCE_THRESHOLD = 80
local TELEPORT_TIME_THRESHOLD = 0.25

local COIN_SINGLE_THRESHOLD = 1500
local COIN_BURST_THRESHOLD = 2500
local COIN_BURST_WINDOW = 5

local telemetryResolved = false
local telemetryModule: any = nil

local function resolveTelemetry()
	if telemetryResolved then
		return telemetryModule
	end

	telemetryResolved = true

	local analyticsFolder = ServerScriptService:FindFirstChild("Analytics")
	local moduleInstance = analyticsFolder and analyticsFolder:FindFirstChild("TelemetryServer")

	if moduleInstance and moduleInstance:IsA("ModuleScript") then
		local ok, result = pcall(require, moduleInstance)
		if ok and result then
			telemetryModule = result
		else
			warn(string.format("[Guard] Failed to require TelemetryServer: %s", tostring(result)))
			telemetryModule = false
		end
	else
		telemetryModule = false
	end

	return telemetryModule
end

local function trackTelemetry(eventName: string, payload: any)
	if typeof(eventName) ~= "string" or eventName == "" then
		return
	end

	local module = resolveTelemetry()
	if not module or module == false then
		return
	end

	if typeof(module.Track) ~= "function" then
		return
	end

	local ok, err = pcall(module.Track, eventName, payload)
	if not ok then
		warn(string.format("[Guard] Telemetry.Track failed for %s: %s", eventName, tostring(err)))
	end
end

local guardConfig = {
	autoKickThreshold = 0,
	telemetryEventName = "guard_violation",
	softBanThreshold = 3,
}

type PlayerAuditState = {
	violations: { [string]: number },
	totalViolations: number,
	lastReport: { [string]: number },
	connections: { RBXScriptConnection },
	charConnections: { RBXScriptConnection },
	humanoidConnections: { RBXScriptConnection },
	humanoid: Humanoid?,
	swing: { lastAt: number, windowStart: number, count: number },
	coins: { lastTotal: number?, windowStart: number, accumulated: number },
	teleport: { lastPosition: Vector3?, lastTimestamp: number },
	kicked: boolean?,
	softBanned: boolean?,
	softBanAt: number?,
	softBanReason: string?,
	softBanDetail: any?,
	softBanLastLog: number?,
}

local playerAuditStates: { [Player]: PlayerAuditState } = setmetatable({}, { __mode = "k" })

local function softBanPlayer(player: Player, state: PlayerAuditState, violationType: string, detail: any)
	if not isValidPlayer(player) then
		return
	end

	if state.softBanned then
		return
	end

	state.softBanned = true
	state.softBanAt = os.clock()
	state.softBanReason = violationType
	state.softBanDetail = detail
	state.softBanLastLog = state.softBanAt

	warn(string.format("[Guard] Soft-banned %s for %s", formatPlayer(player), violationType))

	trackTelemetry("ExploitFlag", {
		userId = player.UserId,
		player = player.Name,
		violation = violationType,
		detail = detail,
		strikes = state.totalViolations,
		perType = shallowCopy(state.violations),
		timestamp = state.softBanAt,
	})
end

local function disconnectConnections(connections: { RBXScriptConnection }?)
	if not connections then
		return
	end
	for index = #connections, 1, -1 do
		local connection = connections[index]
		if connection and typeof(connection) == "RBXScriptConnection" then
			connection:Disconnect()
		elseif connection and connection.Disconnect then
			connection:Disconnect()
		end
		connections[index] = nil
	end
end

local function formatDetail(detail: any): string
	if detail == nil then
		return "Violation"
	end

	if typeof(detail) == "table" then
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, detail)
		if ok then
			return encoded
		end
	end

	return tostring(detail)
end

local function ensureAuditState(player: Player): PlayerAuditState
	local state = playerAuditStates[player]
	if state then
		return state
	end

	local now = os.clock()
	state = {
		violations = {},
		totalViolations = 0,
		lastReport = {},
		connections = {},
		charConnections = {},
		humanoidConnections = {},
		humanoid = nil,
		swing = { lastAt = -math.huge, windowStart = now, count = 0 },
		coins = { lastTotal = nil, windowStart = now, accumulated = 0 },
		teleport = { lastPosition = nil, lastTimestamp = now },
		kicked = false,
		softBanned = false,
		softBanAt = nil,
		softBanReason = nil,
		softBanDetail = nil,
		softBanLastLog = nil,
	}
	playerAuditStates[player] = state
	return state
end

local function cleanupAuditState(player: Player)
	local state = playerAuditStates[player]
	if not state then
		return
	end

	disconnectConnections(state.connections)
	disconnectConnections(state.charConnections)
	disconnectConnections(state.humanoidConnections)

	playerAuditStates[player] = nil
end

local function recordViolation(player: Player, violationType: string, detail: any)
	if not isValidPlayer(player) then
		return
	end

	local state = ensureAuditState(player)
	state.totalViolations += 1
	state.violations[violationType] = (state.violations[violationType] or 0) + 1

	local now = os.clock()
	local lastReport = state.lastReport[violationType]
	local shouldReport = lastReport == nil or (now - lastReport) >= 2

	if shouldReport then
		state.lastReport[violationType] = now
		warn(string.format("[Guard] %s flagged %s: %s", violationType, formatPlayer(player), formatDetail(detail)))

		trackTelemetry(guardConfig.telemetryEventName, {
			userId = player.UserId,
			player = player.Name,
			violation = violationType,
			detail = detail,
			count = state.violations[violationType],
			total = state.totalViolations,
			arenaId = player:GetAttribute("ArenaId"),
		})
	end

	local threshold = guardConfig.autoKickThreshold
	if threshold and threshold > 0 and not state.kicked and state.totalViolations >= threshold then
		state.kicked = true
		local reason = string.format("Guard violation: %s", violationType)
		local ok, err = pcall(function()
			player:Kick(reason)
		end)
		if not ok then
			warn(string.format("[Guard] Failed to kick %s: %s", formatPlayer(player), tostring(err)))
		else
			trackTelemetry(guardConfig.telemetryEventName, {
				userId = player.UserId,
				player = player.Name,
				violation = violationType,
				total = state.totalViolations,
				kicked = true,
				reason = reason,
			})
		end
	end

	local softBanThreshold = guardConfig.softBanThreshold
	if softBanThreshold and softBanThreshold > 0 and state.totalViolations >= softBanThreshold then
		softBanPlayer(player, state, violationType, detail)
	end
end

local function readSpeedBoostMultiplierFrom(instance: Instance?): number
	if instance == nil then
		return 1
	end

	local multiplier = 1
	local hadExplicit = false

	local attrMult = instance:GetAttribute("SpeedBoostMultiplier")
	if typeof(attrMult) == "number" and attrMult > 0 then
		multiplier *= attrMult
		hadExplicit = true
	end

	local valueObject = instance:FindFirstChild("SpeedBoostMultiplier")
	if valueObject and valueObject:IsA("NumberValue") and valueObject.Value > 0 then
		multiplier *= valueObject.Value
		hadExplicit = true
	end

	if not hadExplicit then
		local attrActive = instance:GetAttribute("SpeedBoostActive")
		local active = attrActive == true
		if not active then
			local boolValue = instance:FindFirstChild("SpeedBoostActive")
			if boolValue and boolValue:IsA("BoolValue") and boolValue.Value then
				active = true
			end
		end
		if active then
			multiplier *= DEFAULT_SPEEDBOOST_MULTIPLIER
		end
	end

	if multiplier < 0.01 then
		multiplier = 0.01
	end

	return multiplier
end

local function getTotalSpeedMultiplier(player: Player, character: Model?, humanoid: Humanoid?): number
	local total = 1
	total *= readSpeedBoostMultiplierFrom(player)
	total *= readSpeedBoostMultiplierFrom(character)
	total *= readSpeedBoostMultiplierFrom(humanoid)
	if total < 0.01 then
		total = 0.01
	end
	return total
end

local function resolveBaseSpeeds(player: Player, character: Model?, humanoid: Humanoid?): (number, number)
	local walk = DEFAULT_BASE_WALK_SPEED
	local sprint = DEFAULT_BASE_SPRINT_SPEED

	local function apply(instance: Instance?)
		if not instance then
			return
		end

		local baseWalk = instance:GetAttribute("BaseWalkSpeed")
		if typeof(baseWalk) == "number" and baseWalk >= 0 then
			walk = baseWalk
		end

		local baseSprint = instance:GetAttribute("BaseSprintSpeed")
		if typeof(baseSprint) == "number" and baseSprint >= 0 then
			sprint = baseSprint
		end
	end

	apply(player)
	apply(character)
	apply(humanoid)

	if sprint < walk then
		sprint = walk
	end

	return walk, sprint
end

local function computeAllowedWalkSpeed(player: Player, humanoid: Humanoid?): (number, number, number)
	if not humanoid then
		local baseline = math.max(DEFAULT_BASE_WALK_SPEED, DEFAULT_BASE_SPRINT_SPEED)
		return baseline, 1, baseline
	end

	local character = humanoid.Parent
	local model = if character and character:IsA("Model") then character else nil
	local walk, sprint = resolveBaseSpeeds(player, model, humanoid)
	local baseline = math.max(walk, sprint)
	local multiplier = getTotalSpeedMultiplier(player, model, humanoid)
	local allowed = baseline * multiplier

	return allowed, multiplier, baseline
end

local function auditWalkSpeed(player: Player, state: PlayerAuditState, humanoid: Humanoid)
	local allowed, multiplier, baseline = computeAllowedWalkSpeed(player, humanoid)
	local current = tonumber(humanoid.WalkSpeed) or 0
	if allowed <= 0 then
		return
	end

	if current > allowed + SPEED_TOLERANCE then
		if current > allowed then
			humanoid.WalkSpeed = allowed
		end

		if multiplier <= 1 + MULTIPLIER_EPSILON then
			recordViolation(player, "ImpossibleSpeed", {
				observed = current,
				allowed = allowed,
				baseline = baseline,
			})
		end
	end
end

local function attachHumanoid(player: Player, state: PlayerAuditState, humanoid: Humanoid)
	if state.humanoid == humanoid then
		auditWalkSpeed(player, state, humanoid)
		return
	end

	disconnectConnections(state.humanoidConnections)
	state.humanoidConnections = {}
	state.humanoid = humanoid

	table.insert(state.humanoidConnections, humanoid.Destroying:Connect(function()
		if state.humanoid == humanoid then
			disconnectConnections(state.humanoidConnections)
			state.humanoidConnections = {}
			state.humanoid = nil
		end
	end))

	table.insert(state.humanoidConnections, humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		auditWalkSpeed(player, state, humanoid)
	end))

	table.insert(state.humanoidConnections, humanoid:GetPropertyChangedSignal("Parent"):Connect(function()
		if humanoid.Parent == nil and state.humanoid == humanoid then
			disconnectConnections(state.humanoidConnections)
			state.humanoidConnections = {}
			state.humanoid = nil
		end
	end))

	auditWalkSpeed(player, state, humanoid)
end

local function onCharacterAdded(player: Player, character: Model)
	local state = ensureAuditState(player)

	disconnectConnections(state.charConnections)
	state.charConnections = {}
	disconnectConnections(state.humanoidConnections)
	state.humanoidConnections = {}
	state.humanoid = nil

	state.teleport.lastPosition = nil
	state.teleport.lastTimestamp = os.clock()

	local function attemptAttach()
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			attachHumanoid(player, state, humanoid)
		end
	end

	attemptAttach()

	table.insert(state.charConnections, character.ChildAdded:Connect(function(child)
		if child:IsA("Humanoid") then
			attachHumanoid(player, state, child)
		end
	end))

	table.insert(state.charConnections, character:GetPropertyChangedSignal("Parent"):Connect(function()
		if character.Parent == nil then
			disconnectConnections(state.humanoidConnections)
			state.humanoidConnections = {}
			state.humanoid = nil
		end
	end))
end

local function onCoinsChanged(player: Player)
	local state = ensureAuditState(player)
	local now = os.clock()
	local attr = player:GetAttribute("Coins")
	local numeric = if attr ~= nil then tonumber(attr) else nil

	if numeric == nil then
		state.coins.lastTotal = nil
		state.coins.windowStart = now
		state.coins.accumulated = 0
		return
	end

	local last = state.coins.lastTotal
	state.coins.lastTotal = numeric

	if last == nil then
		state.coins.windowStart = now
		state.coins.accumulated = 0
		return
	end

	local delta = numeric - last
	if delta <= 0 then
		state.coins.windowStart = now
		state.coins.accumulated = 0
		return
	end

	if now - state.coins.windowStart > COIN_BURST_WINDOW then
		state.coins.windowStart = now
		state.coins.accumulated = 0
	end

	state.coins.accumulated += delta

	local multiplierAttr = player:GetAttribute("CoinRewardMultiplier")
	local multiplier = if multiplierAttr ~= nil then tonumber(multiplierAttr) else nil
	if multiplier and multiplier > 1 + MULTIPLIER_EPSILON then
		state.coins.windowStart = now
		state.coins.accumulated = 0
		return
	end

	if delta >= COIN_SINGLE_THRESHOLD or state.coins.accumulated >= COIN_BURST_THRESHOLD then
		recordViolation(player, "CoinBurst", {
			delta = delta,
			windowTotal = state.coins.accumulated,
			windowSeconds = now - state.coins.windowStart,
		})
		state.coins.windowStart = now
		state.coins.accumulated = 0
	end
end

local function auditSwing(player: Player)
	local state = ensureAuditState(player)
	local swingState = state.swing
	local now = os.clock()

	local flagged = false
	local delta = now - swingState.lastAt
	if swingState.lastAt > 0 and delta < SWING_MIN_INTERVAL then
		recordViolation(player, "SwingRate", { delta = delta })
		flagged = true
	end

	if now - swingState.windowStart > SWING_WINDOW_SECONDS then
		swingState.windowStart = now
		swingState.count = 0
	end

	swingState.count += 1
	if swingState.count > SWING_MAX_PER_WINDOW then
		if not flagged then
			recordViolation(player, "SwingRate", {
				count = swingState.count,
				windowSeconds = now - swingState.windowStart,
			})
		end
		swingState.count = 0
		swingState.windowStart = now
	end

        swingState.lastAt = now
end

type EnemyTarget = BasePart | Model

type EnemyBehaviorPayload = {
        fruit: EnemyTarget,
        fruitId: string?,
        position: Vector3?,
        hitPosition: Vector3?,
}

type EnemyHeuristic = (player: Player, payload: EnemyBehaviorPayload, rawArgs: { any }?) -> ()

local function toEnemyBehaviorPayload(value: any): EnemyBehaviorPayload?
        if typeof(value) ~= "table" then
                return nil
        end

        local data = value :: { [string]: any }
        local fruitCandidate = data.fruit
        if typeof(fruitCandidate) ~= "Instance" then
                return nil
        end

        local fruit: EnemyTarget?
        if fruitCandidate:IsA("BasePart") then
                fruit = fruitCandidate
        elseif fruitCandidate:IsA("Model") then
                fruit = fruitCandidate
        else
                return nil
        end

        local positionValue = data.position
        local hitPositionValue = data.hitPosition
        local normalizedPosition = if typeof(positionValue) == "Vector3" then positionValue
                elseif typeof(hitPositionValue) == "Vector3" then hitPositionValue
                else nil
        local normalizedHit = if typeof(hitPositionValue) == "Vector3" then hitPositionValue
                elseif typeof(positionValue) == "Vector3" then positionValue
                else nil

        local fruitIdValue = data.fruitId
        local fruitId = if typeof(fruitIdValue) == "string" and fruitIdValue ~= "" then fruitIdValue else nil

        return {
                fruit = fruit :: EnemyTarget,
                fruitId = fruitId,
                position = normalizedPosition,
                hitPosition = normalizedHit,
        }
end

local enemyBehaviorHeuristics: { [string]: EnemyHeuristic } = {
        RE_MeleeHitAttempt = function(player: Player, _payload: EnemyBehaviorPayload, _rawArgs: { any }?)
                auditSwing(player)
        end,
}

table.freeze(enemyBehaviorHeuristics)

local function auditTeleport(player: Player, state: PlayerAuditState, now: number)
	if not isValidPlayer(player) then
		return
	end

	local character = player.Character
	if not character or character.Parent == nil then
		state.teleport.lastPosition = nil
		state.teleport.lastTimestamp = now
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		state.teleport.lastPosition = nil
		state.teleport.lastTimestamp = now
		return
	end

	local previousPosition = state.teleport.lastPosition
	local previousTimestamp = state.teleport.lastTimestamp

	state.teleport.lastPosition = root.Position
	state.teleport.lastTimestamp = now

	if not previousPosition or not previousTimestamp then
		return
	end

	local arenaId = player:GetAttribute("ArenaId")
	if arenaId == nil then
		return
	end

	local deltaTime = now - previousTimestamp
	if deltaTime <= 0 or deltaTime > TELEPORT_TIME_THRESHOLD then
		return
	end

	local distance = (root.Position - previousPosition).Magnitude
	if distance >= TELEPORT_DISTANCE_THRESHOLD then
		recordViolation(player, "Teleport", {
			distance = distance,
			deltaTime = deltaTime,
			arenaId = arenaId,
		})
	end
end

local function observePlayer(player: Player)
	if not isValidPlayer(player) then
		return
	end

	local state = ensureAuditState(player)
	onCoinsChanged(player)

	table.insert(state.connections, player:GetAttributeChangedSignal("Coins"):Connect(function()
		onCoinsChanged(player)
	end))

	table.insert(state.connections, player:GetAttributeChangedSignal("CoinRewardMultiplier"):Connect(function()
		state.coins.windowStart = os.clock()
		state.coins.accumulated = 0
	end))

	table.insert(state.connections, player.CharacterAdded:Connect(function(character)
		if character then
			onCharacterAdded(player, character)
		end
	end))

	table.insert(state.connections, player.CharacterRemoving:Connect(function()
		disconnectConnections(state.charConnections)
		disconnectConnections(state.humanoidConnections)
		state.humanoidConnections = {}
		state.charConnections = {}
		state.humanoid = nil
	end))

	local character = player.Character
	if character then
		onCharacterAdded(player, character)
	end
end

local function runRemoteHeuristics(remoteName: string, player: Player, sanitized: any, rawArgs: { any }?)
        local enemyHeuristic = enemyBehaviorHeuristics[remoteName]
        if enemyHeuristic then
                local payload = toEnemyBehaviorPayload(sanitized)
                if not payload then
                        recordViolation(player, "EnemyPayloadInvalid", { remote = remoteName })
                        return
                end

                enemyHeuristic(player, payload, rawArgs)
        end
end

function Guard.Configure(options: { [string]: any }?)
	if typeof(options) ~= "table" then
		return
	end

	if options.autoKickThreshold ~= nil then
		local numeric = tonumber(options.autoKickThreshold)
		if not numeric or numeric <= 0 then
			guardConfig.autoKickThreshold = 0
		else
			guardConfig.autoKickThreshold = math.floor(numeric + 0.5)
		end
	end

	if typeof(options.telemetryEventName) == "string" and options.telemetryEventName ~= "" then
		guardConfig.telemetryEventName = options.telemetryEventName
	end

	if options.softBanThreshold ~= nil then
		local numeric = tonumber(options.softBanThreshold)
		if not numeric or numeric <= 0 then
			guardConfig.softBanThreshold = 0
		else
			guardConfig.softBanThreshold = math.floor(numeric + 0.5)
		end
	end
end

function Guard.SetAutoKickThreshold(threshold: number?)
	if threshold == nil then
		guardConfig.autoKickThreshold = 0
		return
	end

	local numeric = tonumber(threshold)
	if not numeric or numeric <= 0 then
		guardConfig.autoKickThreshold = 0
	else
		guardConfig.autoKickThreshold = math.floor(numeric + 0.5)
	end
end

function Guard.SetSoftBanThreshold(threshold: number?)
	if threshold == nil then
		guardConfig.softBanThreshold = 0
		return
	end

	local numeric = tonumber(threshold)
	if not numeric or numeric <= 0 then
		guardConfig.softBanThreshold = 0
	else
		guardConfig.softBanThreshold = math.floor(numeric + 0.5)
	end
end

function Guard.IsSoftBanned(player: Player): boolean
	local state = playerAuditStates[player]
	if not state then
		return false
	end

	return state.softBanned == true
end

function Guard.GetViolationSummary(player: Player)
	local state = playerAuditStates[player]
	if not state then
		return nil
	end

	return {
		total = state.totalViolations,
		perType = shallowCopy(state.violations),
	}
end

function Guard.WrapRemote(remote: Instance?, config: GuardConfig?, handler: ((Player, any?) -> any?)?)
	if remote == nil then
		warn("[Guard] Attempted to wrap a nil remote")
		return nil
	end

	if not remote:IsA("RemoteEvent") and not remote:IsA("RemoteFunction") then
		warn(string.format("[Guard] Unsupported remote type %s for %s", remote.ClassName, remote:GetFullName()))
		return nil
	end

	config = config or {}
	handler = handler or config.handler

	local remoteName = config.remoteName or remote.Name
	local rateLimit = normalizeRateLimit(config.rateLimit)
	local validator = config.validator

	if remote:IsA("RemoteEvent") then
		return remote.OnServerEvent:Connect(function(player: Player, ...)
			if not isValidPlayer(player) then
				logDenial(remoteName, player, "InvalidPlayer")
				return
			end

			if isThrottled(remote, player, rateLimit) then
				logDenial(remoteName, player, "RateLimit")
				return
			end

			local state = ensureAuditState(player)
			if state.softBanned then
				local now = os.clock()
				if not state.softBanLastLog or (now - state.softBanLastLog) >= 1 then
					logDenial(remoteName, player, "SoftBanned", state.softBanReason)
					state.softBanLastLog = now
				end
				return
			end

			local rawArgs = table.pack(...)
			local sanitized = if rawArgs.n > 0 then rawArgs[1] else nil

			if validator then
				local ok, value, detail = runValidator(remote, validator, player, rawArgs)
				if not ok then
					logDenial(remoteName, player, value, detail)
					return
				end
				if value ~= nil then
					sanitized = value
				end
			end

			runRemoteHeuristics(remoteName, player, sanitized, rawArgs)

			if handler then
				local success, err = pcall(handler, player, sanitized)
				if not success then
					warn(string.format("[Guard] Handler error for %s: %s", remoteName, tostring(err)))
				end
			end
		end)
	end

	remote.OnServerInvoke = function(player: Player, ...)
		if not isValidPlayer(player) then
			logDenial(remoteName, player, "InvalidPlayer")
			return makeRejectResponse(config, "InvalidPlayer")
		end

		if isThrottled(remote, player, rateLimit) then
			logDenial(remoteName, player, "RateLimit")
			return makeRejectResponse(config, "RateLimit")
		end

		local state = ensureAuditState(player)
		if state.softBanned then
			local now = os.clock()
			if not state.softBanLastLog or (now - state.softBanLastLog) >= 1 then
				logDenial(remoteName, player, "SoftBanned", state.softBanReason)
				state.softBanLastLog = now
			end
			return makeRejectResponse(config, "SoftBanned")
		end

		local rawArgs = table.pack(...)
		local sanitized = if rawArgs.n > 0 then rawArgs[1] else nil

		if validator then
			local ok, value, detail = runValidator(remote, validator, player, rawArgs)
			if not ok then
				logDenial(remoteName, player, value, detail)
				return makeRejectResponse(config, value)
			end
			if value ~= nil then
				sanitized = value
			end
		end

		if not handler then
			return makeRejectResponse(config, "NoHandler")
		end

		local success, result = pcall(handler, player, sanitized)
		if not success then
			warn(string.format("[Guard] Handler error for %s: %s", remoteName, tostring(result)))
			return makeRejectResponse(config, "HandlerError")
		end

		return result
	end

	return remote.OnServerInvoke
end

for _, player in ipairs(Players:GetPlayers()) do
	observePlayer(player)
end

Players.PlayerAdded:Connect(observePlayer)

Players.PlayerRemoving:Connect(function(player)
	cleanupAuditState(player)
	for _, remoteBuckets in pairs(rateState) do
		remoteBuckets[player] = nil
	end
end)

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for player, state in pairs(playerAuditStates) do
		if state and player.Parent then
			auditTeleport(player, state, now)
		end
	end
end)

return Guard
