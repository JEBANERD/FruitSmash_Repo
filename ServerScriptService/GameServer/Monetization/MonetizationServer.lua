--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--========================
-- Config
--========================
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = if typeof(GameConfigModule.Get) == "function" then GameConfigModule.Get() else GameConfigModule

local MonetizationConfig = GameConfig.Monetization or {}
local ContinueConfig = MonetizationConfig.Continue or {}
local RerollConfig = MonetizationConfig.Reroll or {}

local CONTINUE_CAP_PER_SESSION: number = (typeof(ContinueConfig.CapPerSession) == "number" and ContinueConfig.CapPerSession or 0)
local REROLL_CAP_PER_TEN_LEVELS: number = (typeof(RerollConfig.CapPerTenLevels) == "number" and RerollConfig.CapPerTenLevels or 0)

--========================
-- Remotes (strict-safe)
--========================
local RemotesFolder: Folder = (function()
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "Remotes"
	f.Parent = ReplicatedStorage
	return f
end)()

local function getOrCreateRemote(name: string, className: "RemoteEvent" | "RemoteFunction")
	local found = RemotesFolder:FindFirstChild(name)
	if found and found.ClassName == className then
		return found
	end
	if found then
		found:Destroy()
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = RemotesFolder
	return inst
end

local RF_RequestContinue = getOrCreateRemote("RF_RequestContinue", "RemoteFunction") :: RemoteFunction

--========================
-- Types
--========================
type RerollBandUsage = {
	total: number,
	tokens: number,
	fees: number,
}
type PlayerState = {
	continuesUsed: number,
	rerollBands: { [number]: RerollBandUsage }, -- 0-based bands of 10 levels each
}

--========================
-- State (weak by Player)
--========================
local playerState: { [Player]: PlayerState } = {}
setmetatable(playerState, { __mode = "k" })

local function ensurePlayerState(player: Player): PlayerState
	local state = playerState[player]
	if state then
		return state
	end
	local newState: PlayerState = {
		continuesUsed = 0,
		rerollBands = {},
	}
	playerState[player] = newState
	return newState
end

-- Level (1..∞) → band index (0..∞), each band spans 10 levels
local function levelToBand(levelValue: number?): number
	local lv: number = 1
	if typeof(levelValue) == "number" and levelValue > 0 then
		lv = levelValue
	end
	return math.floor((lv - 1) / 10)
end

local function ensureBandUsage(state: PlayerState, band: number): RerollBandUsage
	local usage = state.rerollBands[band]
	if usage then
		return usage
	end
	local newUsage: RerollBandUsage = { total = 0, tokens = 0, fees = 0 }
	state.rerollBands[band] = newUsage
	return newUsage
end

--========================
-- Placeholders for future flows
--========================
local function placeholderRobuxFlow(_player: Player): (boolean, string?)
	return false, "RobuxNotImplemented"
end

local function placeholderAdFlow(_player: Player): (boolean, string?)
	return false, "AdNotImplemented"
end

--========================
-- API
--========================
local MonetizationServer = {}

function MonetizationServer.GetRemainingContinues(player: Player): number
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return 0
	end
	if CONTINUE_CAP_PER_SESSION <= 0 then
		return 0
	end
	local state = ensurePlayerState(player)
	local remaining = CONTINUE_CAP_PER_SESSION - state.continuesUsed
	if remaining < 0 then remaining = 0 end
	return remaining
end

function MonetizationServer.CanUseContinue(player: Player): (boolean, number)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, 0
	end
	if CONTINUE_CAP_PER_SESSION <= 0 then
		return false, 0
	end
	local state = ensurePlayerState(player)
	local remaining = CONTINUE_CAP_PER_SESSION - state.continuesUsed
	if remaining <= 0 then
		return false, 0
	end
	return true, remaining
end

local function applyContinueUsage(player: Player, method: string?): (boolean, number, string?)
	local can, remaining = MonetizationServer.CanUseContinue(player)
	if not can then
		return false, remaining, "CapReached"
	end

	local m = (typeof(method) == "string") and string.lower(method :: string) or "token"
	if m == "robux" then
		local ok, reason = placeholderRobuxFlow(player)
		if not ok then
			return false, MonetizationServer.GetRemainingContinues(player), reason
		end
	elseif m == "ad" or m == "advert" then
		local ok, reason = placeholderAdFlow(player)
		if not ok then
			return false, MonetizationServer.GetRemainingContinues(player), reason
		end
	end

	local state = ensurePlayerState(player)
	state.continuesUsed += 1
	local newRemaining = MonetizationServer.GetRemainingContinues(player)
	return true, newRemaining, nil
end

function MonetizationServer.TryUseContinue(player: Player, payload: any): (boolean, number, string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, 0, "InvalidPlayer"
	end
	local method: string? = nil
	if typeof(payload) == "table" then
		local m = payload.method or payload.Method
		if typeof(m) == "string" then method = m end
	elseif typeof(payload) == "string" then
		method = payload
	end
	return applyContinueUsage(player, method)
end

local function buildContinueResponse(allowed: boolean, remaining: number, reason: string?): {allowed: boolean, remaining: number, reason: string?}
	local response = { allowed = allowed, remaining = remaining, reason = reason }
	return response
end

local function onRequestContinue(player: Player, payload: any)
	local allowed, remaining, reason = MonetizationServer.TryUseContinue(player, payload)
	return buildContinueResponse(allowed, remaining, reason)
end

function MonetizationServer.GetRemainingRerolls(player: Player, levelValue: number?): number
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return 0
	end
	if REROLL_CAP_PER_TEN_LEVELS <= 0 then
		return math.huge
	end
	local state = ensurePlayerState(player)
	local band = levelToBand(levelValue)
	local usage = ensureBandUsage(state, band)
	local remaining = REROLL_CAP_PER_TEN_LEVELS - usage.total
	if remaining < 0 then remaining = 0 end
	return remaining
end

function MonetizationServer.CanReroll(player: Player, levelValue: number?): (boolean, number)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, 0
	end
	local remaining = MonetizationServer.GetRemainingRerolls(player, levelValue)
	if remaining <= 0 then
		return false, 0
	end
	return true, remaining
end

local function resolveRerollMethod(payload: any): string
	if typeof(payload) == "table" then
		local v = payload.method or payload.Method
		if typeof(v) == "string" then
			return string.lower(v)
		end
	elseif typeof(payload) == "string" then
		return string.lower(payload)
	end
	return "fee"
end

function MonetizationServer.TryConsumeReroll(player: Player, levelValue: number?, payload: any): (boolean, number, string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, 0, "InvalidPlayer"
	end

	if REROLL_CAP_PER_TEN_LEVELS <= 0 then
		return true, math.huge, nil
	end

	local state = ensurePlayerState(player)
	local band = levelToBand(levelValue)
	local usage = ensureBandUsage(state, band)

	if usage.total >= REROLL_CAP_PER_TEN_LEVELS then
		return false, 0, "RerollCapReached"
	end

	local method = resolveRerollMethod(payload)
	usage.total += 1
	if method == "token" then
		usage.tokens += 1
	else
		usage.fees += 1
	end

	local remaining = REROLL_CAP_PER_TEN_LEVELS - usage.total
	if remaining < 0 then remaining = 0 end
	return true, remaining, nil
end

function MonetizationServer.ResetPlayer(player: Player)
	playerState[player] = nil
end

--========================
-- Init / Wiring
--========================
local initialized = false
function MonetizationServer.Init()
	if initialized then return end
	initialized = true

	RF_RequestContinue.OnServerInvoke = onRequestContinue

	Players.PlayerRemoving:Connect(function(p)
		MonetizationServer.ResetPlayer(p)
	end)

	print("[MonetizationServer] Initialized")
end

MonetizationServer.Init()

return MonetizationServer
