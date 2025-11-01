--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SUMMARY_INTERVAL_SECONDS = 120

local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local GameConfig = if typeof(GameConfigModule.Get) == "function" then GameConfigModule.Get() else GameConfigModule

type AnalyticsEntry = {
    Fruit: number,
    Waves: number,
    Levels: number,
    Continues: number,
    StartTime: number?,
    [string]: number?,
}

type AnalyticsModule = { [string]: AnalyticsEntry } & {
    InitArena: (arenaId: string) -> AnalyticsEntry?,
    Log: (arenaId: string?, key: string?, amount: number?) -> (),
    Get: (arenaId: string?) -> AnalyticsEntry?,
}

local Analytics = {} :: AnalyticsModule

local analyticsData: { [string]: AnalyticsEntry } = {}
local debugEnabled = (GameConfig :: any).Debug and (GameConfig :: any).Debug.Enabled

local function createEntry(): AnalyticsEntry
    return {
        Fruit = 0,
        Waves = 0,
        Levels = 0,
        Continues = 0,
        StartTime = os.clock(),
    }
end

local function ensureArena(arenaId: string?): AnalyticsEntry?
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
        local startTime = entry.StartTime
        if startTime then
            elapsed = os.clock() - startTime
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

function Analytics.InitArena(arenaId: string): AnalyticsEntry?
    return ensureArena(arenaId)
end

function Analytics.Log(arenaId: string?, key: string?, amount: number?)
    if not arenaId or not key then
        return
    end

    local entry = ensureArena(arenaId)
    if not entry then
        return
    end

    local delta: number
    if amount == nil then
        delta = 1
    elseif typeof(amount) == "number" then
        delta = amount
    else
        delta = tonumber(amount) or 0
    end

    local currentValue: any = entry[key]
    if typeof(currentValue) == "number" then
        entry[key] = currentValue + delta
    elseif currentValue == nil then
        entry[key] = delta
    else
        entry[key] = delta
    end
end

function Analytics.Get(arenaId: string?): AnalyticsEntry?
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
