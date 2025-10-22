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

local function formatNotice(summary: any): string
    if MatchReturnService and typeof(MatchReturnService.FormatNotice) == "function" then
        local ok, result = pcall(MatchReturnService.FormatNotice, summary)
        if ok and typeof(result) == "string" then
            return result
        end
    end

    if typeof(summary) ~= "table" then
        return "Welcome back to the lobby!"
    end

    local reason = summary.reason
    local level = summary.level
    if typeof(reason) == "string" then
        reason = string.lower(reason)
    else
        reason = ""
    end

    if reason == "abort" or reason == "aborted" then
        if typeof(level) == "number" and level > 0 then
            return string.format("Match aborted during level %d. Welcome back to the lobby!", level)
        end
        return "Match aborted. Welcome back to the lobby!"
    end

    if typeof(level) == "number" and level > 0 then
        return string.format("Level %d complete! Welcome back to the lobby!", level)
    end

    return "Welcome back to the lobby!"
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

    local message: string? = nil
    if typeof(data.noticeMessage) == "string" then
        message = data.noticeMessage
    elseif typeof(data.message) == "string" then
        message = data.message
    end

    if message == nil then
        message = formatNotice(summary)
    end

    if typeof(message) ~= "string" or message == "" then
        return
    end

    Remotes.RE_Notice:FireClient(player, {
        msg = message,
        kind = "info",
        summary = summary,
        teleportData = data,
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
