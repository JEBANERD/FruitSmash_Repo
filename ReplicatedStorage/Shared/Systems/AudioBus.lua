--!strict

-- AudioBus: central helper to play shared SFX events with lightweight pooling.
-- Supports optional positional playback by reusing pooled Sound emitters.

local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AudioBus = {}

local SOUND_FOLDER_NAME = "AudioBusSounds"
local EMITTER_FOLDER_NAME = "AudioBusEmitters"

local soundFolder = SoundService:FindFirstChild(SOUND_FOLDER_NAME)
if not soundFolder then
    soundFolder = Instance.new("Folder")
    soundFolder.Name = SOUND_FOLDER_NAME
    soundFolder.Parent = SoundService
end

local emitterFolder = Workspace:FindFirstChild(EMITTER_FOLDER_NAME)
if not emitterFolder then
    emitterFolder = Instance.new("Folder")
    emitterFolder.Name = EMITTER_FOLDER_NAME
    emitterFolder.Parent = Workspace
end

local sfxFolder: Instance? = nil do
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    if shared then
        local assets = shared:FindFirstChild("Assets")
        if assets then
            sfxFolder = assets:FindFirstChild("SFX")
        end
    end
end

local SOUND_PROPERTY_KEYS = {
    "SoundId",
    "Volume",
    "PlaybackSpeed",
    "RollOffMode",
    "RollOffMinDistance",
    "RollOffMaxDistance",
    "EmitterSize",
    "Looped",
    "PlayOnRemove",
    "SoundGroup",
}

local PREWARM_COUNTS = {
    swing = 8,
    hit = 8,
    spawn = 4,
    shield_on = 4,
    shop_open = 2,
    coin_burst = 6,
}

export type SoundDefinition = {
    SoundId: string?,
    Volume: number?,
    PlaybackSpeed: number?,
    RollOffMode: Enum.RollOffMode?,
    RollOffMinDistance: number?,
    RollOffMaxDistance: number?,
    EmitterSize: number?,
    Looped: boolean?,
    PlayOnRemove: boolean?,
    SoundGroup: SoundGroup?,
}

local SOUND_DEFINITIONS: { [string]: SoundDefinition } = {
    swing = {
        SoundId = "rbxassetid://9118822952",
        Volume = 0.55,
        PlaybackSpeed = 1.05,
        RollOffMode = Enum.RollOffMode.Inverse,
        RollOffMinDistance = 6,
        RollOffMaxDistance = 70,
        EmitterSize = 4,
    },
    hit = {
        SoundId = "rbxassetid://9118891509",
        Volume = 0.8,
        PlaybackSpeed = 1,
        RollOffMode = Enum.RollOffMode.Inverse,
        RollOffMinDistance = 4,
        RollOffMaxDistance = 65,
        EmitterSize = 5,
    },
    spawn = {
        SoundId = "rbxassetid://9119059776",
        Volume = 0.7,
        PlaybackSpeed = 1,
    },
    shield_on = {
        SoundId = "rbxassetid://304832329",
        Volume = 0.65,
        PlaybackSpeed = 1,
        RollOffMode = Enum.RollOffMode.Linear,
        RollOffMinDistance = 8,
        RollOffMaxDistance = 80,
        EmitterSize = 6,
    },
    shop_open = {
        SoundId = "rbxassetid://9119012695",
        Volume = 0.45,
        PlaybackSpeed = 1,
    },
    coin_burst = {
        SoundId = "rbxassetid://138081500",
        Volume = 0.7,
        PlaybackSpeed = 1.05,
        RollOffMode = Enum.RollOffMode.Inverse,
        RollOffMinDistance = 6,
        RollOffMaxDistance = 60,
        EmitterSize = 3,
    },
}

export type PoolEntry = {
    eventKey: string,
    sound: Sound,
    emitter: BasePart,
    release: () -> (),
    active: boolean?,
    destroyed: boolean?,
}

local pools: { [string]: { PoolEntry } } = {}

local function coerceEventKey(eventName: string): string
    local trimmed = string.gsub(eventName, "^%s*(.-)%s*$", "%1")
    trimmed = string.gsub(trimmed, "([%d%l])([A-Z])", "%1_%2")
    trimmed = string.gsub(trimmed, "[%s%-]+", "_")
    trimmed = string.gsub(trimmed, "__+", "_")
    return string.lower(trimmed)
end

local function coercePosition(position: any): Vector3?
    local positionType = typeof(position)
    if positionType == "Vector3" then
        return position
    elseif positionType == "CFrame" then
        return (position :: CFrame).Position
    elseif positionType == "Instance" then
        local instance = position :: Instance
        if instance:IsA("BasePart") then
            return instance.Position
        elseif instance:IsA("Attachment") then
            return instance.WorldPosition
        end
    end
    return nil
end

local function copyPropertiesFromTemplate(sound: Sound, template: Sound)
    for _, propertyName in ipairs(SOUND_PROPERTY_KEYS) do
        local ok, value = pcall(function()
            return (template :: any)[propertyName]
        end)
        if ok and value ~= nil then
            local success, err = pcall(function()
                (sound :: any)[propertyName] = value
            end)
            if not success then
                warn(string.format("[AudioBus] Failed to copy property '%s' from template '%s': %s", propertyName, template.Name, tostring(err)))
            end
        end
    end

    for _, child in ipairs(template:GetChildren()) do
        if child:IsA("SoundEffect") then
            local cloned = child:Clone()
            cloned.Parent = sound
        end
    end
end

local function applyDefinition(sound: Sound, definition: SoundDefinition)
    for propertyName, value in pairs(definition) do
        if value ~= nil then
            local success, err = pcall(function()
                (sound :: any)[propertyName] = value
            end)
            if not success then
                warn(string.format("[AudioBus] Failed to assign property '%s' for '%s': %s", propertyName, sound.Name, tostring(err)))
            end
        end
    end
end

local function createEmitterPart(eventKey: string): BasePart
    local part = Instance.new("Part")
    part.Name = string.format("AudioBusEmitter_%s", eventKey)
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Transparency = 1
    part.Size = Vector3.new(0.2, 0.2, 0.2)
    part.Parent = emitterFolder
    return part
end

local function getOrCreatePool(eventKey: string): { PoolEntry }
    local pool = pools[eventKey]
    if not pool then
        pool = {}
        pools[eventKey] = pool
    end
    return pool
end

local function pushEntryToPool(entry: PoolEntry)
    if entry.destroyed then
        return
    end

    entry.active = false
    entry.sound.Parent = soundFolder
    entry.sound.TimePosition = 0
    entry.emitter.Parent = emitterFolder

    local pool = getOrCreatePool(entry.eventKey)
    pool[#pool + 1] = entry
end

local function createPoolEntry(eventKey: string): PoolEntry?
    local sound = Instance.new("Sound")
    sound.Name = string.format("AudioBus_%s", eventKey)

    local template: Sound? = nil
    if sfxFolder then
        local candidate = sfxFolder:FindFirstChild(eventKey)
        if candidate and candidate:IsA("Sound") then
            template = candidate
        end
    end

    if template then
        copyPropertiesFromTemplate(sound, template)
    else
        local definition = SOUND_DEFINITIONS[eventKey]
        if not definition then
            sound:Destroy()
            warn(string.format("[AudioBus] No sound definition for event '%s'", eventKey))
            return nil
        end
        applyDefinition(sound, definition)
    end

    if sound.SoundId == nil or sound.SoundId == "" then
        sound:Destroy()
        warn(string.format("[AudioBus] Sound definition for '%s' missing SoundId", eventKey))
        return nil
    end

    sound.Parent = soundFolder

    local emitter = createEmitterPart(eventKey)

    local entry: PoolEntry
    entry = {
        eventKey = eventKey,
        sound = sound,
        emitter = emitter,
        active = false,
        destroyed = false,
        release = function() end,
    }

    local function release()
        if entry.destroyed then
            return
        end
        if not entry.active then
            return
        end
        pushEntryToPool(entry)
    end

    entry.release = release

    sound.Ended:Connect(release)
    sound.Stopped:Connect(release)
    sound.Destroying:Connect(function()
        entry.destroyed = true
        entry.active = false
    end)

    return entry
end

local function acquireEntry(eventKey: string): PoolEntry?
    local pool = pools[eventKey]
    if pool then
        local entry = table.remove(pool)
        if entry then
            return entry
        end
    end

    return createPoolEntry(eventKey)
end

function AudioBus.Play(eventName: string, position: Vector3 | CFrame | BasePart | Attachment | nil): Sound?
    if typeof(eventName) ~= "string" then
        warn("[AudioBus] Play expected string event name")
        return nil
    end

    local eventKey = coerceEventKey(eventName)
    if eventKey == "" then
        return nil
    end

    local entry = acquireEntry(eventKey)
    if not entry then
        return nil
    end

    if entry.destroyed then
        return nil
    end

    local sound = entry.sound
    local emitter = entry.emitter

    local worldPosition = coercePosition(position)
    if worldPosition then
        emitter.CFrame = CFrame.new(worldPosition)
        sound.Parent = emitter
    else
        sound.Parent = soundFolder
    end

    sound.TimePosition = 0
    entry.active = true

    sound:Play()

    return sound
end

function AudioBus.Warm(eventName: string, count: number?)
    if typeof(eventName) ~= "string" then
        return
    end

    local eventKey = coerceEventKey(eventName)
    if eventKey == "" then
        return
    end

    local warmCount = math.max(0, math.floor(count or 1))
    if warmCount == 0 then
        return
    end

    local definition = SOUND_DEFINITIONS[eventKey]
    if not definition and not (sfxFolder and sfxFolder:FindFirstChild(eventKey)) then
        warn(string.format("[AudioBus] Unable to warm unknown event '%s'", eventKey))
        return
    end

    for _ = 1, warmCount do
        local entry = createPoolEntry(eventKey)
        if not entry then
            break
        end
        pushEntryToPool(entry)
    end
end

do
    for eventKey, count in pairs(PREWARM_COUNTS) do
        AudioBus.Warm(eventKey, count)
    end
end

return AudioBus
