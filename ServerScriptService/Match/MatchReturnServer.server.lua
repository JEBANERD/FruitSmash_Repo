--!strict
-- MatchReturnServer.server.lua
-- Lobby-side helper that surfaces match return summaries from teleport data.

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes: any = nil
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if remotesFolder and remotesFolder:IsA("Folder") then
    local bootstrap = remotesFolder:FindFirstChild("RemoteBootstrap")
    if bootstrap and bootstrap:IsA("ModuleScript") then
        local ok, result = pcall(require, bootstrap)
        if ok then
            Remotes = result
        else
            warn(string.format("[MatchReturnServer] Failed to require RemoteBootstrap: %s", tostring(result)))
        end
    end
end

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local systemsFolder = sharedFolder:WaitForChild("Systems")
local Localizer = require(systemsFolder:WaitForChild("Localizer"))

local MatchReturnService: any = nil
local serviceModule = script.Parent:FindFirstChild("MatchReturnService")
if serviceModule and serviceModule:IsA("ModuleScript") then
    local ok, result = pcall(require, serviceModule)
    if ok then
        MatchReturnService = result
    else
        warn(string.format("[MatchReturnServer] Failed to require MatchReturnService: %s", tostring(result)))
    end
end

local function resolveGameConfig()
    local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
    if not sharedFolder then
        return {}
    end

    local configFolder = sharedFolder:FindFirstChild("Config")
    if not configFolder then
        return {}
    end

    local gameConfigModule = configFolder:FindFirstChild("GameConfig")
    if not gameConfigModule or not gameConfigModule:IsA("ModuleScript") then
        return {}
    end

    local ok, config = pcall(require, gameConfigModule)
    if not ok then
        warn(string.format("[MatchReturnServer] Failed to require GameConfig: %s", tostring(config)))
        return {}
    end

    if typeof(config) == "table" and typeof(config.Get) == "function" then
        local okGet, result = pcall(config.Get)
        if okGet and typeof(result) == "table" then
            return result
        end
    end

    return if typeof(config) == "table" then config else {}
end

local GameConfig = resolveGameConfig()
local MatchConfig = GameConfig.Match or {}

local lobbyPlaceId = MatchConfig.LobbyPlaceId
if typeof(lobbyPlaceId) ~= "number" then
    lobbyPlaceId = game.PlaceId
end

if lobbyPlaceId ~= game.PlaceId then
    return
end

local function formatNotice(summary: any, locale: string?): (string, string?, { [string]: any }?)
    local resolvedLocale = Localizer.getDefaultLocale()
    if typeof(locale) == "string" and locale ~= "" then
        resolvedLocale = Localizer.normalizeLocale(locale)
    end

    local key: string? = nil
    local args: { [string]: any }? = nil

    if MatchReturnService then
        if typeof(MatchReturnService.GetNoticeTemplate) == "function" then
            local okTemplate, templateKey, templateArgs = pcall(MatchReturnService.GetNoticeTemplate, summary)
            if okTemplate and typeof(templateKey) == "string" and templateKey ~= "" then
                key = templateKey
                if typeof(templateArgs) == "table" then
                    args = templateArgs
                end
            end
        elseif typeof(MatchReturnService.FormatNotice) == "function" then
            local okFormat, result = pcall(MatchReturnService.FormatNotice, summary)
            if okFormat and typeof(result) == "string" and result ~= "" then
                return result, nil, nil
            end
        end
    end

    if key then
        local message = Localizer.t(key, args, resolvedLocale)
        return message, key, args
    end

    local fallbackKey = "notices.general.welcomeLobby"
    local fallbackArgs = nil

    if typeof(summary) == "table" then
        local reason = summary.reason
        local level = summary.level
        if typeof(reason) == "string" then
            reason = string.lower(reason)
        else
            reason = ""
        end

        if reason == "abort" or reason == "aborted" then
            if typeof(level) == "number" and level > 0 then
                fallbackKey = "notices.general.welcomeMatchAbortedLevel"
                fallbackArgs = { level = level }
            else
                fallbackKey = "notices.general.welcomeMatchAborted"
                fallbackArgs = nil
            end
        elseif typeof(level) == "number" and level > 0 then
            fallbackKey = "notices.general.welcomeLevelComplete"
            fallbackArgs = { level = level }
        end
    end

    local fallbackMessage = Localizer.t(fallbackKey, fallbackArgs, resolvedLocale)
    return fallbackMessage, fallbackKey, fallbackArgs
end

local function deliverNotice(player: Player)
    if not Remotes or not Remotes.RE_Notice then
        return
    end

    local ok, data = pcall(function()
        return TeleportService:GetPlayerTeleportData(player)
    end)

    if not ok or typeof(data) ~= "table" then
        return
    end

    local summary = nil
    if typeof(data.summary) == "table" then
        summary = data.summary
    elseif typeof(data.matchSummary) == "table" then
        summary = data.matchSummary
    end

    local locale = Localizer.getPlayerLocale(player)

    local key: string? = nil
    local args: { [string]: any }? = nil

    if typeof(data.noticeKey) == "string" and data.noticeKey ~= "" then
        key = data.noticeKey
        if typeof(data.noticeArgs) == "table" then
            args = data.noticeArgs
        end
    elseif typeof(summary) == "table" and typeof(summary.noticeKey) == "string" and summary.noticeKey ~= "" then
        key = summary.noticeKey
        if typeof(summary.noticeArgs) == "table" then
            args = summary.noticeArgs
        end
    end

    local message: string? = nil
    if key then
        message = Localizer.t(key, args, locale)
    end

    if (typeof(message) ~= "string" or message == "") and typeof(data.noticeMessage) == "string" and data.noticeMessage ~= "" then
        message = data.noticeMessage
    end

    if (typeof(message) ~= "string" or message == "") and typeof(data.message) == "string" and data.message ~= "" then
        message = data.message
    end

    if (typeof(message) ~= "string" or message == "") and typeof(summary) == "table" and typeof(summary.message) == "string" and summary.message ~= "" then
        message = summary.message
    end

    if typeof(message) ~= "string" or message == "" then
        local fallbackMessage, fallbackKey, fallbackArgs = formatNotice(summary, locale)
        message = fallbackMessage
        if key == nil then
            key = fallbackKey
            args = fallbackArgs
        end
    end

    if typeof(message) ~= "string" or message == "" then
        return
    end

    Remotes.RE_Notice:FireClient(player, {
        msg = message,
        kind = "info",
        summary = summary,
        teleportData = data,
        key = key,
        args = args,
        locale = locale,
    })
end

local function onPlayerAdded(player: Player)
    task.defer(deliverNotice, player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
    task.defer(deliverNotice, player)
end

print("[MatchReturnServer] Lobby return listener ready")
