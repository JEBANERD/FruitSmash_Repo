local Analytics = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SUMMARY_INTERVAL_SECONDS = 120

local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local GameConfig = typeof(GameConfigModule.Get) == "function" and GameConfigModule.Get() or GameConfigModule

local analyticsData = {}
local debugEnabled = GameConfig.Debug and GameConfig.Debug.Enabled

local function createEntry()
    return {
        Fruit = 0,
        Waves = 0,
        Levels = 0,
        Continues = 0,
        StartTime = os.clock(),
    }
end

local function ensureArena(arenaId)
    if not arenaId then
        return nil
    end

    local entry = analyticsData[arenaId]
    if not entry then
        entry = createEntry()
        analyticsData[arenaId] = entry
        Analytics[arenaId] = entry
    end

    return entry
end

local function printSummary()
    local hasData = false

    for arenaId, entry in pairs(analyticsData) do
        hasData = true

        local elapsed = 0
        if entry.StartTime then
            elapsed = os.clock() - entry.StartTime
        end

        print(string.format(
            "[Analytics] Arena %s :: Fruit=%s Waves=%s Levels=%s Continues=%s Runtime=%.2fs",
            arenaId,
            tostring(entry.Fruit or 0),
            tostring(entry.Waves or 0),
            tostring(entry.Levels or 0),
            tostring(entry.Continues or 0),
            elapsed
        ))
    end

    if not hasData then
        print("[Analytics] No arenas currently tracked")
    end
end

function Analytics.InitArena(arenaId)
    return ensureArena(arenaId)
end

function Analytics.Log(arenaId, key, amount)
    if not arenaId or not key then
        return
    end

    local entry = ensureArena(arenaId)
    if not entry then
        return
    end

    local delta = amount
    if delta == nil then
        delta = 1
    elseif typeof(delta) ~= "number" then
        delta = tonumber(delta) or 0
    end

    local currentValue = entry[key]
    if typeof(currentValue) == "number" then
        entry[key] = currentValue + delta
    elseif currentValue == nil then
        entry[key] = delta
    else
        entry[key] = delta
    end
end

function Analytics.Get(arenaId)
    if not arenaId then
        return nil
    end

    return analyticsData[arenaId]
end

if debugEnabled then
    task.spawn(function()
        while true do
            task.wait(SUMMARY_INTERVAL_SECONDS)
            printSummary()
        end
    end)
end

return Analytics
