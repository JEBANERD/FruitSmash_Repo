local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HUDServer = require(script.Parent:WaitForChild("HUDServer"))
local ArenaServer = require(ServerScriptService.GameServer.ArenaServer)

local TargetHealthServer = {}
local startHP = (GameConfig.Targets and GameConfig.Targets.StartHP) or 200
local scalePct = (GameConfig.Targets and GameConfig.Targets.TenLevelBandScalePct) or 0.10

local arenas = {}

local gameOverEvent = Instance.new("BindableEvent")
TargetHealthServer.GameOver = gameOverEvent.Event

local function computeMaxHP(level)
    local levelValue = math.max(level or 1, 1)
    local band = math.floor((levelValue - 1) / 10)
    local multiplier = 1 + band * scalePct
    local value = startHP * multiplier
    return math.max(1, math.floor(value + 0.5))
end

local function getLaneCountFromArena(arenaId)
    local arenaState = ArenaServer.GetArenaState and ArenaServer.GetArenaState(arenaId)
    if not arenaState then
        return nil, nil
    end

    local lanes = arenaState.lanes or {}
    local laneCount = #lanes
    local level = arenaState.level or 1

    return laneCount, level
end

local function getShieldStatus(state)
    if not state.shieldActive then
        return false, nil
    end

    if state.shieldUntil then
        local remaining = state.shieldUntil - os.clock()
        if remaining <= 0 then
            state.shieldActive = false
            state.shieldUntil = nil
            state.shieldToken = nil
            return false, nil
        end

        return true, math.max(remaining, 0)
    end

    return true, nil
end

local function snapshotState(state)
    if not HUDServer or typeof(HUDServer.TargetHp) ~= "function" then
        return
    end

    local shieldActive, remaining = getShieldStatus(state)
    local laneCount = state.laneCount or 0
    for laneId in pairs(state.lanes) do
        if laneId > laneCount then
            laneCount = laneId
        end
    end

    local maxHP = state.maxHP or 0

    if laneCount <= 0 then
        local extras = {
            maxHp = maxHP,
            MaxHP = maxHP,
            currentHp = 0,
            CurrentHP = 0,
            laneCount = laneCount,
            LaneCount = laneCount,
            shieldActive = shieldActive,
            ShieldActive = shieldActive,
            shieldRemaining = remaining,
            ShieldRemaining = remaining,
            gameOver = state.gameOver,
            GameOver = state.gameOver,
        }

        HUDServer.TargetHp(state.arenaId, 0, nil, extras)
        return
    end

    for laneIndex = 1, laneCount do
        local laneState = state.lanes[laneIndex]
        local currentHP = laneState and laneState.currentHP or 0
        local percent = 0
        if maxHP > 0 then
            percent = math.clamp(currentHP / maxHP, 0, 1)
        end

        local extras = {
            maxHp = maxHP,
            MaxHP = maxHP,
            currentHp = currentHP,
            CurrentHP = currentHP,
            laneCount = laneCount,
            LaneCount = laneCount,
            shieldActive = shieldActive,
            ShieldActive = shieldActive,
            shieldRemaining = remaining,
            ShieldRemaining = remaining,
            gameOver = state.gameOver,
            GameOver = state.gameOver,
        }

        HUDServer.TargetHp(state.arenaId, laneIndex, percent, extras)
    end
end

local function ensureArena(arenaId)
    local state = arenas[arenaId]
    if state then
        return state
    end

    local laneCount, level = getLaneCountFromArena(arenaId)
    laneCount = laneCount or (GameConfig.Lanes and GameConfig.Lanes.StartCount) or 0
    level = level or 1

    state = {
        arenaId = arenaId,
        laneCount = laneCount,
        level = level,
        maxHP = computeMaxHP(level),
        lanes = {},
        shieldActive = false,
        shieldUntil = nil,
        shieldToken = nil,
        gameOver = false,
    }

    for index = 1, laneCount do
        state.lanes[index] = { currentHP = state.maxHP }
    end

    arenas[arenaId] = state
    snapshotState(state)

    return state
end

local function ensureLane(state, laneId)
    if laneId == nil then
        return nil
    end

    if laneId < 1 then
        return nil
    end

    if laneId > (state.laneCount or 0) then
        state.laneCount = laneId
    end

    local laneState = state.lanes[laneId]
    if not laneState then
        laneState = { currentHP = state.maxHP }
        state.lanes[laneId] = laneState
    end

    return laneState
end

function TargetHealthServer.ClearArena(arenaId)
    arenas[arenaId] = nil
end

function TargetHealthServer.InitializeArena(arenaId, options)
    assert(arenaId ~= nil, "arenaId is required")

    local state = ensureArena(arenaId)
    if not state then
        return nil
    end

    local overrides = options or {}
    if overrides.Level then
        state.level = overrides.Level
        state.maxHP = computeMaxHP(state.level)
    end

    if overrides.LaneCount then
        state.laneCount = math.max(0, overrides.LaneCount)
    end

    for laneId = 1, state.laneCount do
        local laneState = ensureLane(state, laneId)
        laneState.currentHP = state.maxHP
    end

    for laneId in pairs(state.lanes) do
        if laneId > state.laneCount then
            state.lanes[laneId] = nil
        end
    end

    state.gameOver = false
    state.shieldActive = false
    state.shieldUntil = nil
    state.shieldToken = nil

    snapshotState(state)

    return state
end

function TargetHealthServer.SetLaneCount(arenaId, laneCount)
    assert(arenaId ~= nil, "arenaId is required")
    assert(laneCount ~= nil, "laneCount is required")

    local state = ensureArena(arenaId)
    if not state then
        return
    end

    state.laneCount = math.max(0, laneCount)

    for laneId = 1, state.laneCount do
        local laneState = ensureLane(state, laneId)
        if laneState then
            laneState.currentHP = laneState.currentHP or state.maxHP
        end
    end

    for laneId in pairs(state.lanes) do
        if laneId > state.laneCount then
            state.lanes[laneId] = nil
        end
    end

    snapshotState(state)
end

function TargetHealthServer.ApplyDamage(arenaId, laneId, damage)
    assert(arenaId ~= nil, "arenaId is required")
    assert(laneId ~= nil, "laneId is required")

    local numericDamage = tonumber(damage) or 0
    if numericDamage <= 0 then
        return nil
    end

    local state = ensureArena(arenaId)
    if not state or state.gameOver then
        return nil
    end

    local laneState = ensureLane(state, laneId)
    if not laneState then
        return nil
    end

    local shieldActive = getShieldStatus(state)
    if shieldActive then
        return laneState.currentHP
    end

    laneState.currentHP = math.max(laneState.currentHP - numericDamage, 0)
    if laneState.currentHP <= 0 then
        state.gameOver = true
        gameOverEvent:Fire(arenaId, laneId)
    end

    snapshotState(state)

    return laneState.currentHP
end

function TargetHealthServer.SetShield(arenaId, enabled, durationSeconds)
    assert(arenaId ~= nil, "arenaId is required")

    local state = ensureArena(arenaId)
    if not state then
        return
    end

    if not enabled then
        state.shieldActive = false
        state.shieldUntil = nil
        state.shieldToken = nil
        snapshotState(state)
        return
    end

    state.shieldActive = true

    if durationSeconds and durationSeconds > 0 then
        local expireTime = os.clock() + durationSeconds
        state.shieldUntil = expireTime
        local token = {}
        state.shieldToken = token

        task.delay(durationSeconds, function()
            local currentState = arenas[arenaId]
            if not currentState or currentState ~= state then
                return
            end

            if currentState.shieldToken ~= token then
                return
            end

            currentState.shieldActive = false
            currentState.shieldUntil = nil
            currentState.shieldToken = nil
            snapshotState(currentState)
        end)
    else
        state.shieldUntil = nil
        state.shieldToken = nil
    end

    snapshotState(state)
end

function TargetHealthServer.ApplyHealthBoost(arenaId, bonusPct, healPct)
    assert(arenaId ~= nil, "arenaId is required")

    local state = ensureArena(arenaId)
    if not state or state.gameOver then
        return false
    end

    local numericBonus = if typeof(bonusPct) == "number" then bonusPct else 0
    local numericHeal = if typeof(healPct) == "number" then healPct else 0

    if numericBonus <= 0 and numericHeal <= 0 then
        return false
    end

    local currentMax = state.maxHP or computeMaxHP(state.level or 1)
    if currentMax <= 0 then
        currentMax = computeMaxHP(state.level or 1)
    end

    local newMax = currentMax
    if numericBonus > 0 then
        newMax = math.max(1, math.floor(currentMax * (1 + numericBonus) + 0.5))
        state.maxHP = newMax
    end

    local healAmount = 0
    if numericHeal > 0 then
        healAmount = math.floor(newMax * numericHeal + 0.5)
    end

    local laneCount = state.laneCount or 0
    for laneIndex = 1, laneCount do
        local laneState = ensureLane(state, laneIndex)
        if laneState then
            local currentHP = laneState.currentHP or newMax
            if healAmount > 0 then
                currentHP = math.min(newMax, currentHP + healAmount)
            else
                currentHP = math.min(newMax, currentHP)
            end
            laneState.currentHP = currentHP
        end
    end

    for laneIndex, laneState in pairs(state.lanes) do
        if laneIndex > laneCount and laneState then
            local currentHP = laneState.currentHP or newMax
            if healAmount > 0 then
                currentHP = math.min(newMax, currentHP + healAmount)
            end
            laneState.currentHP = math.min(newMax, currentHP)
        end
    end

    snapshotState(state)
    return true
end

function TargetHealthServer.GetArenaState(arenaId)
    return arenas[arenaId]
end

function TargetHealthServer.OnGameOver(callback)
    return gameOverEvent.Event:Connect(callback)
end

return TargetHealthServer
