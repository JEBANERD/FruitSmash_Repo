--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)
local ArenaServer = require(ServerScriptService.GameServer.ArenaServer)

type LaneState = {
    currentHP: number,
}

type ArenaState = {
    arenaId: string,
    laneCount: number,
    level: number,
    maxHP: number,
    lanes: { [number]: LaneState },
    shieldActive: boolean,
    shieldUntil: number?,
    shieldToken: any?,
    gameOver: boolean,
}

type InitializeOptions = {
    Level: number?,
    LaneCount: number?,
}

type GameOverCallback = (arenaId: string, laneId: number) -> ()

type TargetHealthServerModule = {
    GameOver: RBXScriptSignal,
    ClearArena: (arenaId: string) -> (),
    InitializeArena: (arenaId: string, options: InitializeOptions?) -> ArenaState,
    SetLaneCount: (arenaId: string, laneCount: number) -> (),
    ApplyDamage: (arenaId: string, laneId: number, damage: number | string) -> number?,
    SetShield: (arenaId: string, enabled: boolean, durationSeconds: number?) -> (),
    GetArenaState: (arenaId: string) -> ArenaState?,
    OnGameOver: (callback: GameOverCallback) -> RBXScriptConnection,
}

local TargetHealthServer = {} :: TargetHealthServerModule

local remote = Remotes.RE_TargetHP :: RemoteEvent?
local startHP = (GameConfig.Targets and GameConfig.Targets.StartHP) or 200
local scalePct = (GameConfig.Targets and GameConfig.Targets.TenLevelBandScalePct) or 0.10

local arenas: { [string]: ArenaState } = {}

local gameOverEvent = Instance.new("BindableEvent")
TargetHealthServer.GameOver = gameOverEvent.Event

local function computeMaxHP(level: number?): number
    local levelValue = math.max(level or 1, 1)
    local band = math.floor((levelValue - 1) / 10)
    local multiplier = 1 + band * scalePct
    local value = startHP * multiplier
    return math.max(1, math.floor(value + 0.5))
end

local function getLaneCountFromArena(arenaId: string?): (number?, number?)
    if not arenaId then
        return nil, nil
    end

    local arenaState = if ArenaServer.GetArenaState then (ArenaServer :: any).GetArenaState(arenaId) else nil
    if not arenaState then
        return nil, nil
    end

    local lanes = arenaState.lanes or {}
    local laneCount = #lanes
    local level = arenaState.level or 1

    return laneCount, level
end

local function getShieldStatus(state: ArenaState): (boolean, number?)
    if not state.shieldActive then
        return false, nil
    end

    local untilTime = state.shieldUntil
    if untilTime then
        local remaining = untilTime - os.clock()
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

local function snapshotState(state: ArenaState)
    local event = remote
    if not event then
        return
    end

    local shieldActive, remaining = getShieldStatus(state)
    local laneCount = state.laneCount
    for laneId in pairs(state.lanes) do
        if laneId > laneCount then
            laneCount = laneId
        end
    end

    local lanesPayload: { number } = {}
    for laneIndex = 1, laneCount do
        local laneState = state.lanes[laneIndex]
        lanesPayload[laneIndex] = if laneState then laneState.currentHP else 0
    end

    event:FireAllClients({
        ArenaId = state.arenaId,
        MaxHP = state.maxHP,
        Lanes = lanesPayload,
        ShieldActive = shieldActive,
        ShieldRemaining = remaining,
        GameOver = state.gameOver,
    })
end

local function ensureArena(arenaId: string): ArenaState
    local existing = arenas[arenaId]
    if existing then
        return existing
    end

    local laneCount, level = getLaneCountFromArena(arenaId)
    laneCount = laneCount or ((GameConfig.Lanes and GameConfig.Lanes.StartCount) or 0)
    level = level or 1

    local state: ArenaState = {
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

local function ensureLane(state: ArenaState, laneId: number?): LaneState?
    if not laneId or laneId < 1 then
        return nil
    end

    if laneId > state.laneCount then
        state.laneCount = laneId
    end

    local laneState = state.lanes[laneId]
    if not laneState then
        laneState = { currentHP = state.maxHP }
        state.lanes[laneId] = laneState
    end

    return laneState
end

function TargetHealthServer.ClearArena(arenaId: string)
    arenas[arenaId] = nil
end

function TargetHealthServer.InitializeArena(arenaId: string, options: InitializeOptions?): ArenaState
    assert(arenaId ~= nil, "arenaId is required")

    local state = ensureArena(arenaId)
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
        if laneState then
            laneState.currentHP = state.maxHP
        end
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

function TargetHealthServer.SetLaneCount(arenaId: string, laneCount: number)
    assert(arenaId ~= nil, "arenaId is required")
    assert(laneCount ~= nil, "laneCount is required")

    local state = ensureArena(arenaId)
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

function TargetHealthServer.ApplyDamage(arenaId: string, laneId: number, damage: number | string): number?
    assert(arenaId ~= nil, "arenaId is required")
    assert(laneId ~= nil, "laneId is required")

    local numericDamage = tonumber(damage) or 0
    if numericDamage <= 0 then
        return nil
    end

    local state = ensureArena(arenaId)
    if state.gameOver then
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

function TargetHealthServer.SetShield(arenaId: string, enabled: boolean, durationSeconds: number?)
    assert(arenaId ~= nil, "arenaId is required")

    local state = ensureArena(arenaId)

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

function TargetHealthServer.GetArenaState(arenaId: string): ArenaState?
    return arenas[arenaId]
end

function TargetHealthServer.OnGameOver(callback: GameOverCallback): RBXScriptConnection
    return gameOverEvent.Event:Connect(callback)
end

return TargetHealthServer
