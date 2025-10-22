--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local systemsFolder = sharedFolder:WaitForChild("Systems")

local okAudioBus, AudioBusModule = pcall(function()
    return require(systemsFolder:WaitForChild("AudioBus"))
end)
if not okAudioBus then
    warn(string.format("[AudioController] Failed to load AudioBus: %s", tostring(AudioBusModule)))
    return
end

local AudioBus = AudioBusModule :: { Play: (string, any?) -> Sound? }

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
    return
end

local okRemotes, remotesModule = pcall(function()
    return require(remotesFolder:WaitForChild("RemoteBootstrap"))
end)
if not okRemotes then
    warn(string.format("[AudioController] Failed to load Remotes: %s", tostring(remotesModule)))
    return
end

local Remotes = remotesModule :: any

local function parseNumber(value: any): number?
    if typeof(value) == "number" then
        return value
    end
    local numeric = tonumber(value)
    if numeric then
        return numeric
    end
    return nil
end

local function parseBoolean(value: any): boolean?
    if typeof(value) == "boolean" then
        return value
    end
    if typeof(value) == "number" then
        if value == 0 then
            return false
        elseif value == 1 then
            return true
        end
        return nil
    end
    if typeof(value) == "string" then
        local lower = string.lower(value)
        if lower == "true" or lower == "1" or lower == "yes" then
            return true
        elseif lower == "false" or lower == "0" or lower == "no" then
            return false
        end
    end
    return nil
end

type LaneState = {
    initialized: boolean,
    hp: number?,
}

type ArenaState = {
    shieldActive: boolean?,
    lanes: { [number]: LaneState },
}

local arenaStates: { [string]: ArenaState } = {}
local lastWaveByArena: { [string]: number } = {}
local shopStateByArena: { [string]: boolean } = {}

local function keyForArena(arenaId: any): string
    if arenaId == nil then
        return "__global"
    end
    if typeof(arenaId) == "string" then
        return arenaId
    end
    return tostring(arenaId)
end

local function handleWaveChanged(payload: any)
    local arenaId = nil
    local waveValue: any = payload

    if typeof(payload) == "table" then
        arenaId = payload.arenaId or payload.ArenaId
        waveValue = payload.wave or payload.Wave or payload.currentWave or payload.CurrentWave or payload[1]
    end

    local waveNumber = parseNumber(waveValue)
    if not waveNumber then
        return
    end

    local key = keyForArena(arenaId)
    local previous = lastWaveByArena[key]
    if previous ~= nil then
        if (previous <= 0 and waveNumber > 0) or (waveNumber > previous) then
            AudioBus.Play("spawn")
        end
    end
    lastWaveByArena[key] = waveNumber
end

local function handleShopOpen(payload: any)
    if typeof(payload) ~= "table" then
        return
    end

    local arenaId = payload.arenaId or payload.ArenaId
    local openValue = payload.open
    if openValue == nil then
        openValue = payload.Open
    end

    local isOpen = parseBoolean(openValue)
    if isOpen == nil then
        return
    end

    local key = keyForArena(arenaId)
    local previous = shopStateByArena[key]
    shopStateByArena[key] = isOpen

    if isOpen and not previous then
        AudioBus.Play("shop_open")
    end
end

local function handleTargetUpdate(payload: any)
    if typeof(payload) ~= "table" then
        return
    end

    local arenaId = payload.arenaId or payload.ArenaId
    local laneValue = payload.lane or payload.Lane or payload.LaneId
    local shieldValue = payload.shieldActive
    if shieldValue == nil then
        shieldValue = payload.ShieldActive
    end

    local key = keyForArena(arenaId)
    local state = arenaStates[key]
    if not state then
        state = { shieldActive = nil, lanes = {} }
        arenaStates[key] = state
    end

    local shieldActive = parseBoolean(shieldValue)
    if shieldActive ~= nil then
        local previousShield = state.shieldActive
        if previousShield ~= nil then
            if not previousShield and shieldActive then
                AudioBus.Play("shield_on")
            end
        end
        state.shieldActive = shieldActive
    end

    local laneNumber = parseNumber(laneValue)
    if not laneNumber then
        return
    end

    laneNumber = math.floor(laneNumber + 0.5)
    if laneNumber < 1 then
        return
    end

    local currentHpValue = payload.currentHp or payload.CurrentHP
    local percentValue = payload.pct or payload.Pct or payload.percent or payload.Percent
    local maxHpValue = payload.maxHp or payload.MaxHP

    local currentHp = parseNumber(currentHpValue)
    if currentHp == nil then
        local percent = parseNumber(percentValue)
        local maxHp = parseNumber(maxHpValue)
        if percent and maxHp then
            currentHp = percent * maxHp
        end
    end

    local lanes = state.lanes
    local laneState = lanes[laneNumber]
    if not laneState then
        laneState = { initialized = false, hp = nil }
        lanes[laneNumber] = laneState
    end

    if not laneState.initialized then
        laneState.hp = currentHp
        if currentHp ~= nil then
            laneState.initialized = true
        end
        return
    end

    if currentHp ~= nil and laneState.hp ~= nil then
        if currentHp < laneState.hp - 0.5 then
            AudioBus.Play("hit")
        end
    end

    if currentHp ~= nil then
        laneState.hp = currentHp
    end
end

local waveRemote: RemoteEvent? = Remotes and Remotes.RE_WaveChanged or nil
if waveRemote then
    waveRemote.OnClientEvent:Connect(handleWaveChanged)
end

local shopRemote: RemoteEvent? = Remotes and Remotes.ShopOpen or nil
if shopRemote then
    shopRemote.OnClientEvent:Connect(handleShopOpen)
end

local targetRemote: RemoteEvent? = Remotes and Remotes.RE_TargetHP or nil
if targetRemote then
    targetRemote.OnClientEvent:Connect(handleTargetUpdate)
end

return
