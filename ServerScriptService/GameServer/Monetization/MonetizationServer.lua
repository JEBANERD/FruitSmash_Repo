--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = if typeof(GameConfigModule.Get) == "function" then GameConfigModule.Get() else GameConfigModule

local MonetizationConfig = GameConfig.Monetization or {}
local ContinueConfig = MonetizationConfig.Continue or {}
local RerollConfig = MonetizationConfig.Reroll or {}

local CONTINUE_CAP_PER_SESSION = ContinueConfig.CapPerSession or 0
local REROLL_CAP_PER_TEN_LEVELS = RerollConfig.CapPerTenLevels or 0

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
remotesFolder.Name = "Remotes"
remotesFolder.Parent = ReplicatedStorage

local function getOrCreateRemote(name: string, className: string)
    local existing = remotesFolder:FindFirstChild(name)
    if existing and existing:IsA(className) then
        return existing
    end

    if existing then
        existing:Destroy()
    end

    local remote = Instance.new(className)
    remote.Name = name
    remote.Parent = remotesFolder
    return remote
end

local RF_RequestContinue = getOrCreateRemote("RF_RequestContinue", "RemoteFunction") :: RemoteFunction

type RerollBandUsage = {
    total: number,
    tokens: number,
    fees: number,
}

type PlayerState = {
    continuesUsed: number,
    rerollBands: {[number]: RerollBandUsage},
}

local playerState: {[Player]: PlayerState} = setmetatable({}, { __mode = "k" })

local function ensurePlayerState(player: Player): PlayerState
    local state = playerState[player]
    if state then
        return state
    end

    state = {
        continuesUsed = 0,
        rerollBands = {},
    }

    playerState[player] = state
    return state
end

local function levelToBand(levelValue: number?): number
    local numericLevel = tonumber(levelValue)
    if numericLevel == nil then
        numericLevel = 1
    end

    if numericLevel < 1 then
        numericLevel = 1
    end

    return math.floor((numericLevel - 1) / 10)
end

local function ensureBandUsage(state: PlayerState, band: number): RerollBandUsage
    local usage = state.rerollBands[band]
    if usage then
        return usage
    end

    usage = {
        total = 0,
        tokens = 0,
        fees = 0,
    }

    state.rerollBands[band] = usage
    return usage
end

local function placeholderRobuxFlow(_player: Player)
    -- Placeholder for future Robux purchase flow.
    return false, "RobuxNotImplemented"
end

local function placeholderAdFlow(_player: Player)
    -- Placeholder for future rewarded ad flow.
    return false, "AdNotImplemented"
end

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
    if remaining < 0 then
        remaining = 0
    end

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
    local canContinue, remaining = MonetizationServer.CanUseContinue(player)
    if not canContinue then
        return false, remaining, "CapReached"
    end

    local selectedMethod = string.lower(method or "token")
    if selectedMethod == "robux" then
        local success, reason = placeholderRobuxFlow(player)
        if not success then
            return false, MonetizationServer.GetRemainingContinues(player), reason
        end
    elseif selectedMethod == "ad" or selectedMethod == "advert" then
        local success, reason = placeholderAdFlow(player)
        if not success then
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
        local maybeMethod = payload.method or payload.Method
        if typeof(maybeMethod) == "string" then
            method = maybeMethod
        end
    elseif typeof(payload) == "string" then
        method = payload
    end

    return applyContinueUsage(player, method)
end

local function buildContinueResponse(allowed: boolean, remaining: number, reason: string?)
    local response = {
        allowed = allowed,
        remaining = remaining,
    }

    if reason then
        response.reason = reason
    end

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
    if remaining < 0 then
        remaining = 0
    end

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
        local methodValue = payload.method or payload.Method
        if typeof(methodValue) == "string" then
            return string.lower(methodValue)
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
    if remaining < 0 then
        remaining = 0
    end

    return true, remaining, nil
end

function MonetizationServer.ResetPlayer(player: Player)
    playerState[player] = nil
end

local initialized = false

function MonetizationServer.Init()
    if initialized then
        return
    end
    initialized = true

    RF_RequestContinue.OnServerInvoke = onRequestContinue

    Players.PlayerRemoving:Connect(function(player)
        MonetizationServer.ResetPlayer(player)
    end)

    print("[MonetizationServer] Initialized")
end

MonetizationServer.Init()

return MonetizationServer
