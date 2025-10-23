--[=[
    @module TargetHealthServer
    Central authority for arena target health, shields, and victory conditions.
    The server keeps an authoritative copy of lane health that other services
    consume via HUD snapshots and the GameOver bindable event.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HUDServer = require(script.Parent:WaitForChild("HUDServer"))
local ArenaServer = require(ServerScriptService.GameServer.ArenaServer)

local AchievementServer do
    local ok, result = pcall(function()
        return require(script.Parent:WaitForChild("AchievementServer"))
    end)

    if ok then
        AchievementServer = result
    elseif result ~= nil then
        warn(string.format("[TargetHealthServer] Failed to require AchievementServer: %s", tostring(result)))
    end
end

local TargetImmunityServer do
    local ok, result = pcall(function()
        return require(script.Parent:WaitForChild("TargetImmunityServer"))
    end)

    if ok then
        TargetImmunityServer = result
    else
        warn(string.format("[TargetHealthServer] Failed to require TargetImmunityServer: %s", tostring(result)))
    end
end

local TargetHealthServer = {}
local startHP = (GameConfig.Targets and GameConfig.Targets.StartHP) or 200
local scalePct = (GameConfig.Targets and GameConfig.Targets.TenLevelBandScalePct) or 0.10

local arenas = {}

local gameOverEvent = Instance.new("BindableEvent")
TargetHealthServer.GameOver = gameOverEvent.Event

--[=[
    Update the target immunity module if it is available.
    @param arenaId any -- Arena identifier the shield should affect.
    @param enabled boolean -- Whether the shield should be active.
    @param durationSeconds number? -- Optional lifetime of the shield.
    @param token any? -- Token used by TargetImmunityServer for idempotency.
]=]
local function updateTargetImmunity(arenaId, enabled, durationSeconds, token)
    local module = TargetImmunityServer
    if not module then
        return
    end

    local setter = module.SetShield
    if typeof(setter) ~= "function" then
        return
    end

    local ok, err = pcall(setter, arenaId, enabled, durationSeconds, token)
    if not ok then
        warn(string.format("[TargetHealthServer] Failed to update target immunity: %s", tostring(err)))
    end
end

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

--[=[
    Removes all cached data for an arena and clears any active shield state.
    @param arenaId any -- Unique arena identifier to reset.
]=]
function TargetHealthServer.ClearArena(arenaId)
    updateTargetImmunity(arenaId, false, nil, nil)
    arenas[arenaId] = nil
end

--[=[
    Initializes or reconfigures an arena with optional overrides.
    @param arenaId any -- Unique arena identifier to initialize.
    @param options table? -- Optional table of overrides such as Level or LaneCount.
    @return table? -- The mutable arena state table when initialization succeeds.
]=]
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

    updateTargetImmunity(arenaId, false, nil, nil)

    snapshotState(state)

    return state
end

--[=[
    Sets the number of active lanes tracked for an arena.
    @param arenaId any -- Unique arena identifier to mutate.
    @param laneCount number -- Desired lane count; values below zero clamp to zero.
]=]
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

--[=[
    Applies damage to a single lane if the arena is running and shields allow it.
    @param arenaId any -- Arena identifier that owns the lane.
    @param laneId number -- One-indexed lane identifier receiving damage.
    @param damage number -- Amount of health to subtract.
    @return number? -- The resulting lane health or nil if the request was rejected.
]=]
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

    local previousHP = laneState.currentHP
    laneState.currentHP = math.max(laneState.currentHP - numericDamage, 0)
    if laneState.currentHP < previousHP then
        if AchievementServer and typeof(AchievementServer.RecordLaneDamage) == "function" then
            local okRecord, errRecord = pcall(AchievementServer.RecordLaneDamage, arenaId, laneId)
            if not okRecord then
                warn(string.format("[TargetHealthServer] AchievementServer.RecordLaneDamage failed: %s", tostring(errRecord)))
            end
        end
    end
    if laneState.currentHP <= 0 then
        state.gameOver = true
        gameOverEvent:Fire(arenaId, laneId)
    end

    snapshotState(state)

    return laneState.currentHP
end

--[=[
    Toggles the arena-wide shield and optionally schedules an automatic timeout.
    @param arenaId any -- Arena identifier affected by the shield.
    @param enabled boolean -- Whether the shield should be enabled.
    @param durationSeconds number? -- Optional duration before the shield expires.
]=]
function TargetHealthServer.SetShield(arenaId, enabled, durationSeconds)
    assert(arenaId ~= nil, "arenaId is required")

    local state = ensureArena(arenaId)
    if not state then
        return
    end

    local duration = if typeof(durationSeconds) == "number" and durationSeconds > 0 then durationSeconds else nil

    if not enabled then
        local previousToken = state.shieldToken
        state.shieldActive = false
        state.shieldUntil = nil
        state.shieldToken = nil
        updateTargetImmunity(arenaId, false, nil, previousToken)
        snapshotState(state)
        return
    end

    state.shieldActive = true

    if duration then
        state.shieldUntil = os.clock() + duration
    else
        state.shieldUntil = nil
    end

    local token = {}
    state.shieldToken = token

    updateTargetImmunity(arenaId, true, duration, token)

    if duration then
        task.delay(duration, function()
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
            updateTargetImmunity(arenaId, false, nil, token)
            snapshotState(currentState)
        end)
    end

    snapshotState(state)
end

--[=[
    Boosts maximum health and/or heals lanes according to the provided percents.
    @param arenaId any -- Arena identifier to update.
    @param bonusPct number? -- Percentage increase applied to max health.
    @param healPct number? -- Percentage of the new max used to heal current HP.
    @return boolean -- Whether any change was applied to the arena state.
]=]
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

--[=[
    Returns the mutable arena state tracked for the supplied identifier.
    @param arenaId any -- Arena identifier to read.
    @return table? -- Arena state table or nil if the arena was never initialized.
]=]
function TargetHealthServer.GetArenaState(arenaId)
    return arenas[arenaId]
end

--[=[
    Connects a callback that fires when any lane reaches zero health.
    @param callback fun(arenaId: any, laneId: number) -- Handler invoked on defeat.
    @return RBXScriptConnection -- Connection for the provided handler.
]=]
function TargetHealthServer.OnGameOver(callback)
    return gameOverEvent.Event:Connect(callback)
end

return TargetHealthServer
