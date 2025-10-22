--!strict
-- MatchReturnService
-- Handles returning arena participants to the lobby with a summary payload.

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes: any = nil
local remotesModule = ReplicatedStorage:FindFirstChild("Remotes")
if remotesModule and remotesModule:IsA("Folder") then
    local bootstrap = remotesModule:FindFirstChild("RemoteBootstrap")
    if bootstrap and bootstrap:IsA("ModuleScript") then
        local ok, result = pcall(require, bootstrap)
        if ok then
            Remotes = result
        else
            warn(string.format("[MatchReturn] Failed to require RemoteBootstrap: %s", tostring(result)))
        end
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
        warn(string.format("[MatchReturn] Failed to require GameConfig: %s", tostring(config)))
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

local lobbyPlaceIdValue = MatchConfig.LobbyPlaceId
if typeof(lobbyPlaceIdValue) ~= "number" then
    lobbyPlaceIdValue = game.PlaceId
end

local ArenaServer: any = nil
local gameServerFolder = ServerScriptService:FindFirstChild("GameServer")
if gameServerFolder then
    local arenaModule = gameServerFolder:FindFirstChild("ArenaServer")
    if arenaModule and arenaModule:IsA("ModuleScript") then
        local ok, result = pcall(require, arenaModule)
        if ok then
            ArenaServer = result
        else
            warn(string.format("[MatchReturn] Failed to require ArenaServer: %s", tostring(result)))
        end
    end
end

local MatchReturnService = {}

local function extractPlayer(entry: any): Player?
    if typeof(entry) == "Instance" and entry:IsA("Player") then
        if entry.Parent == Players then
            return entry
        end
        return nil
    end

    if typeof(entry) ~= "table" then
        return nil
    end

    local candidate = entry.player or entry.Player or entry.owner or entry.Owner or entry.user
    if typeof(candidate) == "Instance" and candidate:IsA("Player") and candidate.Parent == Players then
        return candidate
    end

    return nil
end

local function gatherArenaPlayers(arenaId: any): ({ Player }, any)
    local recipients: { Player } = {}
    local seen: { [Player]: boolean } = {}
    local arenaState: any = nil

    if ArenaServer and typeof(ArenaServer.GetArenaState) == "function" then
        local ok, state = pcall(ArenaServer.GetArenaState, arenaId)
        if ok and typeof(state) == "table" then
            arenaState = state

            local statePlayers = state.players
            if typeof(statePlayers) == "table" then
                for _, entry in pairs(statePlayers) do
                    local player = extractPlayer(entry)
                    if player and not seen[player] then
                        table.insert(recipients, player)
                        seen[player] = true
                    end
                end
            end
        end
    end

    local partyId: any = nil
    if arenaState then
        partyId = arenaState.partyId or arenaState.PartyId or arenaState.partyID
        if not partyId then
            local instance = arenaState.instance
            if typeof(instance) == "Instance" then
                local attr = instance:GetAttribute("PartyId")
                if attr ~= nil then
                    partyId = attr
                end
            end
        end
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if not seen[player] then
            local matchesArena = false
            local attrArena = player:GetAttribute("ArenaId")
            if attrArena ~= nil then
                matchesArena = tostring(attrArena) == tostring(arenaId)
            end

            if not matchesArena and partyId ~= nil then
                local attrParty = player:GetAttribute("PartyId")
                if attrParty ~= nil then
                    matchesArena = tostring(attrParty) == tostring(partyId)
                end
            end

            if matchesArena then
                table.insert(recipients, player)
                seen[player] = true
            end
        end
    end

    return recipients, arenaState
end

local function formatNotice(summary: any): string
    if typeof(summary) ~= "table" then
        return "Returning to lobby."
    end

    local reason = summary.reason
    if typeof(reason) == "string" then
        reason = string.lower(reason)
    else
        reason = ""
    end

    local level = summary.level
    local wave = summary.wave

    if reason == "abort" or reason == "aborted" then
        if typeof(level) == "number" and level > 0 then
            return string.format("Match aborted during level %d. Returning to lobby.", level)
        end
        return "Match aborted. Returning to lobby."
    end

    if typeof(level) == "number" and level > 0 then
        local message = string.format("Level %d complete! Returning to lobby.", level)
        if typeof(wave) == "number" and wave > 0 then
            message = string.format("%s Final wave: %d.", message, wave)
        end
        return message
    end

    return "Returning to lobby."
end

local function buildSummary(arenaId: any, context: any, arenaState: any)
    local summary: { [string]: any } = {}

    if typeof(context) == "table" then
        for key, value in pairs(context) do
            if key ~= "players" and key ~= "arenaState" then
                summary[key] = value
            end
        end
    end

    summary.arenaId = summary.arenaId or arenaId

    if summary.reason == nil then
        summary.reason = "LevelComplete"
    end

    if summary.level == nil and typeof(context) == "table" and typeof(context.level) == "number" then
        summary.level = context.level
    elseif summary.level == nil and typeof(arenaState) == "table" and typeof(arenaState.level) == "number" then
        summary.level = arenaState.level
    end

    if summary.wave == nil and typeof(context) == "table" and typeof(context.wave) == "number" then
        summary.wave = context.wave
    elseif summary.wave == nil and typeof(arenaState) == "table" and typeof(arenaState.wave) == "number" then
        summary.wave = arenaState.wave
    end

    summary.timestamp = summary.timestamp or os.time()
    summary.message = summary.message or formatNotice(summary)

    return summary
end

local function normalizePlayers(players: any): { Player }
    if typeof(players) ~= "table" then
        return {}
    end

    local result: { Player } = {}
    local seen: { [Player]: boolean } = {}

    for _, entry in pairs(players) do
        local player = extractPlayer(entry)
        if player and not seen[player] then
            table.insert(result, player)
            seen[player] = true
        end
    end

    return result
end

function MatchReturnService.GetLobbyPlaceId(): number
    return lobbyPlaceIdValue
end

function MatchReturnService.FormatNotice(summary: any): string
    return formatNotice(summary)
end

function MatchReturnService.ReturnArena(arenaId: any, context: any?): boolean
    if arenaId == nil then
        warn("[MatchReturn] ReturnArena called without arenaId")
        return false
    end

    local specifiedPlayers = nil
    if typeof(context) == "table" then
        specifiedPlayers = context.players or context.Players
    end

    local players: { Player }
    local arenaState: any = nil

    if specifiedPlayers then
        players = normalizePlayers(specifiedPlayers)
        if #players == 0 then
            players, arenaState = gatherArenaPlayers(arenaId)
        else
            _, arenaState = gatherArenaPlayers(arenaId)
        end
    else
        players, arenaState = gatherArenaPlayers(arenaId)
    end

    if #players == 0 then
        warn(string.format("[MatchReturn] No players to return for arena %s", tostring(arenaId)))
        return true
    end

    local summary = buildSummary(arenaId, context, arenaState)
    local message = summary.message

    local destination = lobbyPlaceIdValue
    local function notifyPlayers()
        if Remotes and Remotes.RE_Notice and typeof(message) == "string" then
            for _, player in ipairs(players) do
                Remotes.RE_Notice:FireClient(player, {
                    msg = message,
                    kind = "info",
                    summary = summary,
                })
            end
        end
    end

    if typeof(destination) ~= "number" or destination <= 0 then
        warn("[MatchReturn] Invalid LobbyPlaceId; cannot teleport players")
        notifyPlayers()
        return true
    end

    if destination == game.PlaceId then
        warn("[MatchReturn] LobbyPlaceId matches current place; skipping teleport")
        notifyPlayers()
        return true
    end

    local teleportData = {
        kind = "MatchReturn",
        version = 1,
        summary = summary,
        noticeMessage = message,
    }

    local ok, err = pcall(function()
        TeleportService:TeleportAsync(destination, players, teleportData)
    end)

    if not ok then
        warn(string.format("[MatchReturn] TeleportAsync failed for arena %s: %s", tostring(arenaId), tostring(err)))
        notifyPlayers()
        return true
    end

    return true
end

return MatchReturnService
