local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HUDServer = require(script.Parent:WaitForChild("HUDServer"))
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local telemetryTrack: ((string, { [string]: any }?) -> ())? = nil
do
    local analyticsFolder = ServerScriptService:FindFirstChild("Analytics")
    local telemetryModule = analyticsFolder and analyticsFolder:FindFirstChild("TelemetryServer")
    if telemetryModule and telemetryModule:IsA("ModuleScript") then
        local ok, telemetry = pcall(require, telemetryModule)
        if not ok then
            warn(string.format("[RoundDirectorServer] Failed to require TelemetryServer: %s", tostring(telemetry)))
        else
            local trackFn = (telemetry :: any).Track
            if typeof(trackFn) == "function" then
                telemetryTrack = function(eventName: string, payload: { [string]: any }?)
                    local success, err = pcall(trackFn, eventName, payload)
                    if not success then
                        warn(string.format("[RoundDirectorServer] Telemetry.Track failed: %s", tostring(err)))
                    end
                end
            end
        end
    end
end

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))
local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local GameConfig = typeof(GameConfigModule.Get) == "function" and GameConfigModule.Get() or GameConfigModule

local FlagsModule
do
    local ok, module = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Flags"))
    end)
    if ok and typeof(module) == "table" then
        FlagsModule = module
    end
end

local function resolveObstaclesFlag(): boolean
    if FlagsModule and typeof((FlagsModule :: any).IsEnabled) == "function" then
        local ok, result = pcall((FlagsModule :: any).IsEnabled, "Obstacles")
        if ok and typeof(result) == "boolean" then
            return result
        end
    end
    return true
end

local ArenaServer = require(script.Parent:WaitForChild("ArenaServer"))
local TargetHealthServer = require(script.Parent:WaitForChild("TargetHealthServer"))
local RoundSummaryServer = require(script.Parent:WaitForChild("RoundSummaryServer"))

local AchievementServer
do
    local achievementModule = script.Parent:FindFirstChild("AchievementServer")
    if achievementModule and achievementModule:IsA("ModuleScript") then
        local ok, result = pcall(require, achievementModule)
        if ok then
            AchievementServer = result
        else
            warn(string.format("[RoundDirectorServer] Failed to require AchievementServer: %s", tostring(result)))
        end
    end
end

local MatchReturnService
do
    local matchFolder = ServerScriptService:FindFirstChild("Match")
    if matchFolder then
        local returnModule = matchFolder:FindFirstChild("MatchReturnService")
        if returnModule and returnModule:IsA("ModuleScript") then
            local ok, result = pcall(require, returnModule)
            if ok then
                MatchReturnService = result
            else
                warn(string.format("[RoundDirectorServer] Failed to require MatchReturnService: %s", tostring(result)))
            end
        end
    end
end

local EconomyServer
do
    local economyFolder = ServerScriptService:FindFirstChild("Economy")
    local economyModule = economyFolder and economyFolder:FindFirstChild("EconomyServer")
    if economyModule then
        local ok, result = pcall(require, economyModule)
        if ok then
            EconomyServer = result
        else
            warn(string.format("[RoundDirectorServer] Failed to require EconomyServer: %s", tostring(result)))
        end
    end
end

local TurretController
local turretModule = script.Parent:FindFirstChild("TurretControllerServer")
if turretModule then
    local ok, result = pcall(require, turretModule)
    if ok then
        TurretController = result
    else
        warn(string.format("[RoundDirectorServer] Failed to require TurretControllerServer: %s", result))
    end
end

local SawbladeServer
do
    local obstaclesFolder = script.Parent:FindFirstChild("Obstacles")
    local sawbladeModule = obstaclesFolder and obstaclesFolder:FindFirstChild("SawbladeServer")
    if sawbladeModule then
        local ok, result = pcall(require, sawbladeModule)
        if ok then
            SawbladeServer = result
        else
            warn(string.format("[RoundDirectorServer] Failed to require SawbladeServer: %s", tostring(result)))
        end
    end
end

local roundSettings = GameConfig.Rounds or {}
local DEFAULT_PREP_SECONDS = roundSettings.PrepSeconds or 30
local SKIP_PREP_SECONDS = roundSettings.PrepFloorButtonSeconds or 3
local INTER_WAVE_SECONDS = roundSettings.InterWaveSeconds or 0
local WAVE_DURATION_SECONDS = roundSettings.WaveDurationSeconds or 45
local WAVES_PER_LEVEL = roundSettings.WavesPerLevel or 5
local SHOP_SECONDS = roundSettings.ShopSeconds or 30

local LaneConfig = GameConfig.Lanes or {}
local ObstacleConfig = GameConfig.Obstacles or {}

local LANE_START_COUNT = math.max(0, math.floor((LaneConfig.StartCount or 0) + 0.5))
local LANE_MAX_COUNT = tonumber(LaneConfig.MaxCount)
if typeof(LANE_MAX_COUNT) == "number" then
    LANE_MAX_COUNT = math.max(LANE_START_COUNT, math.floor(LANE_MAX_COUNT + 0.5))
else
    LANE_MAX_COUNT = nil
end

local laneUnlockLevels = {}
if typeof(LaneConfig.UnlockAt) == "table" then
    for _, unlock in ipairs(LaneConfig.UnlockAt) do
        if typeof(unlock) == "number" then
            table.insert(laneUnlockLevels, math.max(1, math.floor(unlock + 0.5)))
        end
    end
    table.sort(laneUnlockLevels)
end

local LANE_SMOOTHING_LEVELS = math.max(tonumber(LaneConfig.ExpansionSmoothingLevels) or 0, 0)
local LANE_EXPANSION_PENALTY = math.clamp(tonumber(LaneConfig.ExpansionTemporaryRatePenalty) or 0, 0, 0.95)
local OBSTACLE_ENABLE_LEVEL = tonumber(ObstacleConfig.EnableAtLevel) or math.huge

local ROSTER_BANDS = {
    {
        minLevel = 1,
        roster = { "Apple", "Banana", "Orange", "GrapeBundle", "Pineapple" },
        weights = { Apple = 4, Banana = 3, Orange = 3, GrapeBundle = 2, Pineapple = 1 },
    },
    {
        minLevel = 20,
        roster = { "Apple", "Banana", "Orange", "GrapeBundle", "Pineapple", "Coconut" },
        weights = { Apple = 3, Banana = 3, Orange = 2, GrapeBundle = 1, Pineapple = 3, Coconut = 2 },
    },
    {
        minLevel = 30,
        roster = { "Apple", "Banana", "Orange", "GrapeBundle", "Pineapple", "Coconut", "Watermelon" },
        weights = { Apple = 2, Banana = 2, Orange = 1, GrapeBundle = 1, Pineapple = 3, Coconut = 3, Watermelon = 2 },
    },
}

local RoundDirectorServer = {}
local activeStates = {}

local obstaclesFlagEnabled = resolveObstaclesFlag()

local waveCompleteRemote = Remotes and Remotes.WaveComplete or nil
local levelCompleteRemote = Remotes and Remotes.LevelComplete or nil
local noticeRemote = Remotes and Remotes.RE_Notice or nil

local function toTelemetryId(value)
    local valueType = typeof(value)
    if valueType == "string" then
        if value == "" then
            return nil
        end
        return value
    elseif valueType == "number" or valueType == "boolean" then
        return tostring(value)
    end

    return nil
end

local function getPartyIdFromState(state)
    if typeof(state) ~= "table" then
        return nil
    end

    local arenaState = state.arenaState
    if typeof(arenaState) == "table" then
        local primary = arenaState.partyId or arenaState.PartyId or arenaState.partyID
        local converted = toTelemetryId(primary)
        if converted then
            return converted
        end

        local instance = arenaState.instance
        if typeof(instance) == "Instance" then
            local attribute = instance:GetAttribute("PartyId") or instance:GetAttribute("partyId")
            converted = toTelemetryId(attribute)
            if converted then
                return converted
            end
        end
    end

    return nil
end

local function shallowCopy(dictionary)
    if typeof(dictionary) ~= "table" then
        return nil
    end

    local copy = {}
    for key, value in pairs(dictionary) do
        copy[key] = value
    end

    return copy
end

local function cloneArray(array)
    if typeof(array) ~= "table" then
        return nil
    end

    local copy = {}
    for index, value in ipairs(array) do
        copy[index] = value
    end

    return copy
end

local function cloneWeights(weights)
    if typeof(weights) ~= "table" then
        return nil
    end

    local copy = {}
    local hasEntry = false
    for key, value in pairs(weights) do
        local numeric = tonumber(value)
        if numeric and numeric > 0 then
            copy[key] = numeric
            hasEntry = true
        end
    end

    if not hasEntry then
        return nil
    end

    return copy
end

local function computeLaneCountForLevel(level)
    local count = LANE_START_COUNT

    for _, unlockLevel in ipairs(laneUnlockLevels) do
        if level >= unlockLevel then
            count += 1
        end
    end

    if LANE_MAX_COUNT then
        count = math.min(count, LANE_MAX_COUNT)
    end

    return math.max(count, 0)
end

local function selectRosterBand(level)
    local selected = ROSTER_BANDS[1]

    for _, band in ipairs(ROSTER_BANDS) do
        if level >= band.minLevel then
            selected = band
        else
            break
        end
    end

    return selected
end

local function resolveLaneRateMultiplier(state, level)
    local data = state and state.lanePenaltyData
    if not data then
        return 1
    end

    local basePenalty = math.clamp(tonumber(data.basePenalty) or LANE_EXPANSION_PENALTY or 0, 0, 0.95)
    if basePenalty <= 0 then
        state.lanePenaltyData = nil
        return 1
    end

    local startLevel = tonumber(data.startLevel) or level
    local smoothing = math.max(tonumber(data.smoothingLevels) or LANE_SMOOTHING_LEVELS or 0, 0)

    if level < startLevel then
        return 1 - basePenalty
    end

    local delta = level - startLevel
    if smoothing <= 0 then
        if delta > 0 then
            state.lanePenaltyData = nil
            return 1
        end

        return 1 - basePenalty
    end

    if delta >= smoothing then
        state.lanePenaltyData = nil
        return 1
    end

    local fraction = 1 - (delta / smoothing)
    fraction = math.clamp(fraction, 0, 1)

    return 1 - basePenalty * fraction
end

local function applyDifficultyBands(state)
    if not state then
        return
    end

    local level = math.max(tonumber(state.level) or 1, 1)

    local desiredLaneCount = computeLaneCountForLevel(level)
    local previousLaneCount = state.activeLaneCount
    if previousLaneCount ~= desiredLaneCount then
        state.activeLaneCount = desiredLaneCount

        local arenaState = state.arenaState
        if typeof(arenaState) == "table" then
            arenaState.activeLanes = desiredLaneCount
            arenaState.laneCount = desiredLaneCount
        end

        if TargetHealthServer and typeof(TargetHealthServer.SetLaneCount) == "function" then
            local ok, err = pcall(TargetHealthServer.SetLaneCount, state.arenaId, desiredLaneCount)
            if not ok then
                warn(string.format("[RoundDirectorServer] Failed to update lane count for arena '%s': %s", tostring(state.arenaId), tostring(err)))
            end
        end

        if previousLaneCount and desiredLaneCount > previousLaneCount and LANE_EXPANSION_PENALTY > 0 then
            state.lanePenaltyData = {
                startLevel = level,
                basePenalty = LANE_EXPANSION_PENALTY,
                smoothingLevels = LANE_SMOOTHING_LEVELS,
            }
        elseif previousLaneCount and desiredLaneCount < previousLaneCount then
            state.lanePenaltyData = nil
        end
    elseif state.activeLaneCount == nil then
        state.activeLaneCount = desiredLaneCount
    end

    local multiplier = resolveLaneRateMultiplier(state, level)
    state.currentRateMultiplier = math.clamp(multiplier, 0, 1)

    local rosterBand = selectRosterBand(level)
    if state.activeRosterBand ~= rosterBand or state.fruitRosterIds == nil then
        state.activeRosterBand = rosterBand
        state.fruitRosterIds = cloneArray(rosterBand.roster) or {}
        state.fruitWeights = cloneWeights(rosterBand.weights)
    end

    state.obstaclesEnabled = level >= OBSTACLE_ENABLE_LEVEL
end

local function sanitizeInteger(value)
    local numeric = tonumber(value)
    if numeric == nil then
        return 0
    end

    if numeric >= 0 then
        return math.floor(numeric + 0.5)
    end

    return -math.floor(-numeric + 0.5)
end

local function readPlayerKOs(player)
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return 0
    end

    local attr = player:GetAttribute("KOs")
    if typeof(attr) == "number" then
        return math.max(0, sanitizeInteger(attr))
    end

    local leaderstats = player:FindFirstChild("leaderstats")
    if leaderstats then
        for _, child in ipairs(leaderstats:GetChildren()) do
            if child:IsA("NumberValue") and string.lower(child.Name) == "kos" then
                return math.max(0, sanitizeInteger(child.Value))
            end
        end
    end

    return 0
end

local function describeDefeatReason(reason)
    if not reason then
        return nil
    end

    local reasonType = reason.type or reason.reason or reason.Kind or reason.kind
    if reasonType == "target" then
        if reason.lane then
            return string.format("Target destroyed (lane %s)", tostring(reason.lane))
        end

        return "Target destroyed"
    elseif reasonType == "timeout" then
        if reason.wave then
            return string.format("Wave %d timed out", tonumber(reason.wave) or reason.wave)
        end

        return "Time expired"
    elseif reasonType == "wave_failure" or reasonType == "wave" then
        if reason.wave then
            return string.format("Wave %d failed", tonumber(reason.wave) or reason.wave)
        end

        return "Wave failed"
    elseif reasonType == "manual" or reasonType == "abort" then
        if reason.message or reason.Message then
            return tostring(reason.message or reason.Message)
        end
        return "Round ended"
    end

    if typeof(reason) == "string" then
        return reason
    end

    if typeof(reason.Message) == "string" then
        return reason.Message
    end

    return nil
end

local function callSawblade(methodName, arenaId, ...)
    if not SawbladeServer then
        return
    end

    if methodName ~= "Stop" and not obstaclesFlagEnabled then
        return
    end

    local method = SawbladeServer[methodName]
    if typeof(method) ~= "function" then
        return
    end

    local ok, err = pcall(method, SawbladeServer, arenaId, ...)
    if not ok then
        warn(string.format("[RoundDirectorServer] SawbladeServer.%s failed: %s", tostring(methodName), tostring(err)))
    end
end

local function applyObstaclesFlag(isEnabled: boolean)
    obstaclesFlagEnabled = isEnabled and true or false
    if not obstaclesFlagEnabled then
        for arenaId in pairs(activeStates) do
            callSawblade("Stop", arenaId)
        end
        return
    end

    for arenaId, state in pairs(activeStates) do
        if typeof(state) == "table" then
            local context = {
                level = state.level,
                phase = state.phase,
                wave = state.wave,
            }

            if state.phase == "Wave" then
                callSawblade("Start", arenaId, context)
            else
                callSawblade("UpdateRoundState", arenaId, context)
            end
        end
    end
end

if FlagsModule and typeof((FlagsModule :: any).OnChanged) == "function" then
    (FlagsModule :: any).OnChanged("Obstacles", function(isEnabled)
        applyObstaclesFlag(isEnabled)
    end)
end

local function updateArenaStateSnapshot(state)
    if not ArenaServer or typeof(ArenaServer.GetArenaState) ~= "function" then
        return
    end

    if not state.arenaState then
        state.arenaState = ArenaServer.GetArenaState(state.arenaId)
    end

    if state.arenaState then
        state.arenaState.level = state.level
        state.arenaState.wave = state.wave
        state.arenaState.phase = state.phase
    end
end

local function logPhase(state)
    callSawblade("UpdateRoundState", state.arenaId, {
        level = state.level,
        phase = state.phase,
        wave = state.wave,
    })
    print(string.format("[RoundDirectorServer] arena=%s phase=%s level=%d wave=%d", state.arenaId, state.phase, state.level, state.wave))
    if telemetryTrack then
        local payload = {
            arenaId = state.arenaId,
            phase = state.phase,
            level = state.level,
            wave = state.wave,
        }

        local partyId = getPartyIdFromState(state)
        if partyId then
            payload.partyId = partyId
        end

        if state.phase == "Defeat" then
            local reason = describeDefeatReason(state.defeatReason)
            if reason then
                payload.reason = reason
            end
        end

        telemetryTrack("round_phase", payload)
    end
end

local function broadcastWaveChange(state)
    if not HUDServer or typeof(HUDServer.WaveChanged) ~= "function" then
        return
    end

    local waveValue = state.phase == "Wave" and state.wave or 0
    HUDServer.WaveChanged(state.arenaId, waveValue, state.level, state.phase)
end

local function gatherArenaPlayers(state)
    local recipients = {}
    local seen = {}

    local arenaState = state and state.arenaState
    if type(arenaState) == "table" then
        local statePlayers = arenaState.players
        if type(statePlayers) == "table" then
            for _, entry in pairs(statePlayers) do
                local player = entry
                if typeof(entry) == "table" then
                    player = entry.player or entry.Player or entry.owner
                end

                if typeof(player) == "Instance" and player:IsA("Player") and not seen[player] then
                    table.insert(recipients, player)
                    seen[player] = true
                end
            end
        end
    end

    local arenaId = state and state.arenaId
    local partyId
    if type(arenaState) == "table" then
        partyId = arenaState.partyId or arenaState.PartyId or arenaState.partyID
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if not seen[player] then
            local matches = false
            if arenaId then
                local playerArena = player:GetAttribute("ArenaId")
                if playerArena and tostring(playerArena) == tostring(arenaId) then
                    matches = true
                end
            end

            if not matches and partyId then
                local playerParty = player:GetAttribute("PartyId")
                if playerParty and tostring(playerParty) == tostring(partyId) then
                    matches = true
                end
            end

            if matches then
                table.insert(recipients, player)
                seen[player] = true
            end
        end
    end

    if #recipients == 0 then
        for _, player in ipairs(Players:GetPlayers()) do
            table.insert(recipients, player)
        end
    end

    return recipients
end

local function ensureLevelSummary(state)
    if not state then
        return nil
    end

    local summary = state.currentLevelSummary
    if summary and summary.level == state.level then
        return summary
    end

    local baseline = {}
    for _, player in ipairs(gatherArenaPlayers(state)) do
        baseline[player] = readPlayerKOs(player)
    end

    summary = {
        level = state.level,
        perPlayer = {},
        startKOs = baseline,
        totalCoins = 0,
        totalPoints = 0,
        wavesCleared = 0,
        startedAt = os.clock(),
        roundSummarySent = false,
    }

    state.currentLevelSummary = summary

    if AchievementServer and typeof(AchievementServer.BeginLevel) == "function" then
        local players = gatherArenaPlayers(state)
        local okAchievement, achievementErr = pcall(AchievementServer.BeginLevel, state.arenaId, summary.level, players, summary.startedAt)
        if not okAchievement then
            warn(string.format("[RoundDirectorServer] AchievementServer.BeginLevel failed: %s", tostring(achievementErr)))
        end
    end

    if RoundSummaryServer and typeof(RoundSummaryServer.BeginLevel) == "function" then
        local ok, err = pcall(RoundSummaryServer.BeginLevel, state.arenaId, summary.level, summary.startKOs)
        if not ok then
            warn(string.format("[RoundDirectorServer] RoundSummaryServer.BeginLevel failed: %s", tostring(err)))
        end
    end

    return summary
end

local function accumulateLevelRewards(state, rewards)
    if not rewards or typeof(rewards) ~= "table" then
        return
    end

    local summary = ensureLevelSummary(state)
    if not summary then
        return
    end

    for player, reward in pairs(rewards) do
        if typeof(player) == "Instance" and player:IsA("Player") and typeof(reward) == "table" then
            local entry = summary.perPlayer[player]
            if not entry then
                entry = { coins = 0, points = 0 }
                summary.perPlayer[player] = entry
            end

            local coinsDelta = sanitizeInteger(reward.coinsDelta or reward.CoinsDelta or reward.coins or reward.Coins)
            local pointsDelta = sanitizeInteger(reward.pointsDelta or reward.PointsDelta or reward.points or reward.Points)

            entry.coins = (entry.coins or 0) + coinsDelta
            entry.points = (entry.points or 0) + pointsDelta
            summary.totalCoins = (summary.totalCoins or 0) + coinsDelta
            summary.totalPoints = (summary.totalPoints or 0) + pointsDelta

            if summary.startKOs[player] == nil then
                summary.startKOs[player] = readPlayerKOs(player)
            end
        end
    end
end

local function sendNoticeToPlayers(players, message, kind, extras)
    if typeof(message) ~= "string" then
        message = tostring(message)
    end

    if type(players) ~= "table" then
        players = {}
    end

    if noticeRemote then
        for _, player in ipairs(players) do
            if typeof(player) == "Instance" and player:IsA("Player") then
                local payload = { msg = message, kind = kind or "info" }
                if typeof(extras) == "table" then
                    for key, value in pairs(extras) do
                        payload[key] = value
                    end
                end
                noticeRemote:FireClient(player, payload)
            end
        end
    else
        print(string.format("[RoundDirectorServer] Notice(%s): %s", tostring(kind or "info"), message))
    end
end

local function fireWaveCompleteEvent(state, success, metadata)
    if not waveCompleteRemote or not state then
        return
    end

    local payload = {
        arenaId = state.arenaId,
        level = state.level,
        wave = state.wave,
        success = success,
    }

    if typeof(metadata) == "table" then
        for key, value in pairs(metadata) do
            payload[key] = value
        end
    end

    waveCompleteRemote:FireAllClients(payload)

    if telemetryTrack then
        telemetryTrack("wave_complete", payload)
    end
end

local function fireLevelCompleteEvent(state, metadata)
    if not levelCompleteRemote or not state then
        return
    end

    local payload = {
        arenaId = state.arenaId,
        level = state.level,
    }

    if typeof(metadata) == "table" then
        for key, value in pairs(metadata) do
            payload[key] = value
        end
    end

    levelCompleteRemote:FireAllClients(payload)
end

local function finalizeLevelSummary(state, outcome, reason)
    if not state then
        return
    end

    local summary = state.currentLevelSummary or ensureLevelSummary(state)
    if not summary or summary.dispatched then
        return
    end

    summary.dispatched = true

    local players = gatherArenaPlayers(state)
    local levelNumber = summary.level or state.level or 0
    local reasonText = describeDefeatReason(reason or state.defeatReason)
    local outcomeKind = outcome == "victory" and "success" or outcome == "defeat" and "warning" or "info"

    local levelEventPayload
    local perPlayerSummary: { [Player]: { coins: number, points: number, kos: number } } = {}
    local totalKoDelta = 0
    if outcome == "victory" then
        levelEventPayload = {
            totalCoins = sanitizeInteger(summary.totalCoins or 0),
            totalPoints = sanitizeInteger(summary.totalPoints or 0),
            wavesCleared = sanitizeInteger(summary.wavesCleared or 0),
            players = {},
        }
    end

    for _, player in ipairs(players) do
        local entry = summary.perPlayer[player]
        local coins = sanitizeInteger(entry and entry.coins or 0)
        local points = sanitizeInteger(entry and entry.points or 0)
        local currentKO = readPlayerKOs(player)
        local baselineKO = summary.startKOs and summary.startKOs[player]
        if baselineKO == nil then
            baselineKO = currentKO
            if summary.startKOs then
                summary.startKOs[player] = baselineKO
            end
        end
        local koDelta = math.max(0, currentKO - baselineKO)

        perPlayerSummary[player] = {
            coins = coins,
            points = points,
            kos = koDelta,
        }
        totalKoDelta += koDelta

        local message
        if outcome == "victory" then
            message = string.format("Level %d cleared! Coins +%d, Points +%d, KOs %d", levelNumber, coins, points, koDelta)
        elseif outcome == "defeat" then
            if reasonText then
                message = string.format("Level %d failed — %s. Coins +%d, Points +%d, KOs %d", levelNumber, reasonText, coins, points, koDelta)
            else
                message = string.format("Level %d failed. Coins +%d, Points +%d, KOs %d", levelNumber, coins, points, koDelta)
            end
        else
            message = string.format("Level %d summary: Coins +%d, Points +%d, KOs %d", levelNumber, coins, points, koDelta)
        end

        local metadata = {
            arenaId = state.arenaId,
            level = levelNumber,
            coins = coins,
            points = points,
            kos = koDelta,
            outcome = outcome,
        }

        if reasonText then
            metadata.reason = reasonText
        end

        if levelEventPayload then
            local userId = typeof(player.UserId) == "number" and player.UserId or player.Name
            levelEventPayload.players[userId] = {
                userId = typeof(player.UserId) == "number" and player.UserId or nil,
                name = player.Name,
                coins = coins,
                points = points,
                kos = koDelta,
            }
        end

        sendNoticeToPlayers({ player }, message, outcomeKind, metadata)
    end

    if not summary.roundSummarySent and RoundSummaryServer and typeof(RoundSummaryServer.Publish) == "function" then
        if #players > 0 then
            local publishPayload = {
                level = levelNumber,
                outcome = outcome,
                reason = reasonText,
                totals = {
                    coins = sanitizeInteger(summary.totalCoins or 0),
                    points = sanitizeInteger(summary.totalPoints or 0),
                    wavesCleared = sanitizeInteger(summary.wavesCleared or 0),
                    kos = sanitizeNonNegativeInteger(totalKoDelta),
                },
                players = perPlayerSummary,
                recipients = players,
            }

            local okPublish, publishErr = pcall(RoundSummaryServer.Publish, state.arenaId, publishPayload)
            if not okPublish then
                warn(string.format("[RoundDirectorServer] RoundSummaryServer.Publish failed: %s", tostring(publishErr)))
            else
                summary.roundSummarySent = true
            end
        end
    end

    local logPieces = {
        string.format("arena=%s", tostring(state.arenaId)),
        string.format("level=%d", levelNumber),
        string.format("outcome=%s", tostring(outcome or "summary")),
        string.format("coins=%d", sanitizeInteger(summary.totalCoins or 0)),
        string.format("points=%d", sanitizeInteger(summary.totalPoints or 0)),
        string.format("waves=%d", sanitizeInteger(summary.wavesCleared or 0)),
    }

    if reasonText then
        table.insert(logPieces, string.format("reason=%s", reasonText))
    end

    print(string.format("[RoundDirectorServer] Level summary :: %s", table.concat(logPieces, " ")))

    if levelEventPayload then
        fireLevelCompleteEvent(state, levelEventPayload)
    end

    local finishClock = os.clock()
    if AchievementServer and typeof(AchievementServer.HandleLevelComplete) == "function" then
        local levelInfo = {
            level = levelNumber,
            startedAt = summary.startedAt,
            finishedAt = finishClock,
            duration = summary.startedAt and math.max(0, finishClock - summary.startedAt) or nil,
            wavesCleared = sanitizeInteger(summary.wavesCleared or 0),
        }

        local okAchievement, achievementErr = pcall(AchievementServer.HandleLevelComplete, state.arenaId, outcome, players, perPlayerSummary, levelInfo)
        if not okAchievement then
            warn(string.format("[RoundDirectorServer] AchievementServer.HandleLevelComplete failed: %s", tostring(achievementErr)))
        end
    end

    state.currentLevelSummary = nil
end

local function handleLevelCompletePhase(state)
    if not state then
        return
    end

    state.phase = "LevelComplete"
    state.wave = 0
    updateArenaStateSnapshot(state)
    logPhase(state)
    broadcastWaveChange(state)

    local rewards = grantLevelBonus(state, state.level)
    if rewards then
        accumulateLevelRewards(state, rewards)
    end

    finalizeLevelSummary(state, "victory")
end

local function grantWaveBonus(state)
    if not EconomyServer or typeof(EconomyServer.GrantWaveClear) ~= "function" then
        return nil
    end

    local players = gatherArenaPlayers(state)
    if #players == 0 then
        return nil
    end

    local levelValue = state and state.level or 0
    local ok, result = pcall(EconomyServer.GrantWaveClear, players, levelValue)
    if not ok then
        warn(string.format("[RoundDirectorServer] GrantWaveClear failed: %s", tostring(result)))
        return nil
    end

    return result
end

local function grantLevelBonus(state, level)
    if not EconomyServer or typeof(EconomyServer.GrantLevelClear) ~= "function" then
        return nil
    end

    local players = gatherArenaPlayers(state)
    if #players == 0 then
        return nil
    end

    local levelValue = level or (state and state.level) or 0
    local ok, result = pcall(EconomyServer.GrantLevelClear, players, levelValue)
    if not ok then
        warn(string.format("[RoundDirectorServer] GrantLevelClear failed: %s", tostring(result)))
        return nil
    end

    return result
end

local function sendPrepTimer(state, seconds)
    if not HUDServer or typeof(HUDServer.BroadcastPrep) ~= "function" then
        return
    end

    HUDServer.BroadcastPrep(state.arenaId, seconds)
end

local function triggerDefeat(state, reason)
    if not state or state.defeat or state.aborted then
        return
    end

    state.defeat = true
    state.defeatReason = reason or state.defeatReason
    state.running = false
    state.phase = "Defeat"
    state.finalOutcome = "defeat"

    state.waveOutcome = { status = "failure", reason = state.defeatReason }
    state.waveDeadline = nil
    state.waveStartedAt = nil

    ensureLevelSummary(state)

    updateArenaStateSnapshot(state)
    logPhase(state)
    sendPrepTimer(state, 0)
    broadcastWaveChange(state)

    if state.wave and state.wave > 0 then
        local metadata = {
            arenaId = state.arenaId,
            level = state.level,
            wave = state.wave,
            reason = describeDefeatReason(state.defeatReason),
        }

        fireWaveCompleteEvent(state, false, metadata)
    end

    finalizeLevelSummary(state, "defeat", state.defeatReason)

    if telemetryTrack then
        local payload = {
            arenaId = state.arenaId,
            outcome = "defeat",
            level = state.level,
            wave = state.wave,
        }

        local partyId = getPartyIdFromState(state)
        if partyId then
            payload.partyId = partyId
        end

        local readableReason = describeDefeatReason(state.defeatReason)
        if readableReason then
            payload.reason = readableReason
        end

        if typeof(state.startedAt) == "number" then
            payload.duration = math.max(0, os.clock() - state.startedAt)
        end

        telemetryTrack("match_end", payload)
    end
end

if TargetHealthServer then
    local function onTargetGameOver(arenaId, laneId)
        if arenaId == nil then
            return
        end

        local state = activeStates[arenaId]
        if not state then
            return
        end

        triggerDefeat(state, { type = "target", lane = laneId })
    end

    if typeof(TargetHealthServer.OnGameOver) == "function" then
        TargetHealthServer.OnGameOver(onTargetGameOver)
    elseif TargetHealthServer.GameOver and typeof(TargetHealthServer.GameOver.Connect) == "function" then
        TargetHealthServer.GameOver:Connect(onTargetGameOver)
    end
end

local function scheduleWave(state)
    if not TurretController then
        return
    end

    local context = {
        arenaId = state.arenaId,
        level = state.level,
        wave = state.wave,
    }

    if typeof(state.activeLaneCount) == "number" then
        context.laneCount = state.activeLaneCount
    end

    if typeof(state.fruitRosterIds) == "table" and #state.fruitRosterIds > 0 then
        context.fruitRoster = state.fruitRosterIds
    end

    if typeof(state.fruitWeights) == "table" and next(state.fruitWeights) ~= nil then
        context.fruitWeights = state.fruitWeights
    end

    local rateMultiplier = state.currentRateMultiplier
    if typeof(rateMultiplier) == "number" and rateMultiplier >= 0 then
        context.fireRateMultiplier = rateMultiplier
    end

    if typeof(TurretController.ScheduleWave) == "function" then
        local ok, err = pcall(TurretController.ScheduleWave, TurretController, state.arenaId, context)
        if not ok then
            local okDirect, errDirect = pcall(TurretController.ScheduleWave, state.arenaId, context)
            if not okDirect then
                warn(string.format("[RoundDirectorServer] ScheduleWave failed: %s", errDirect))
            end
        end
        return
    end

    if typeof(TurretController.ScheduleWavePatterns) == "function" then
        local ok, err = pcall(TurretController.ScheduleWavePatterns, TurretController, state.arenaId, context)
        if not ok then
            local okDirect, errDirect = pcall(TurretController.ScheduleWavePatterns, state.arenaId, context)
            if not okDirect then
                warn(string.format("[RoundDirectorServer] ScheduleWavePatterns failed: %s", errDirect))
            end
        end
        return
    end

    if typeof(TurretController.SchedulePattern) == "function" then
        local ok, err = pcall(TurretController.SchedulePattern, TurretController, state.arenaId, state.level, state.wave)
        if not ok then
            local okDirect, errDirect = pcall(TurretController.SchedulePattern, state.arenaId, state.level, state.wave)
            if not okDirect then
                warn(string.format("[RoundDirectorServer] SchedulePattern failed: %s", errDirect))
            end
        end
    end
end

local function runPrep(state)
    state.phase = "Prep"
    state.wave = 0
    state.prepEndTime = os.clock() + DEFAULT_PREP_SECONDS

    updateArenaStateSnapshot(state)
    logPhase(state)

    sendPrepTimer(state, DEFAULT_PREP_SECONDS)

    while state.running do
        local remaining = state.prepEndTime - os.clock()
        if remaining <= 0 then
            break
        end

        task.wait(0.1)
    end

    if not state.running then
        return false
    end

    sendPrepTimer(state, 0)
    state.prepEndTime = nil

    return true
end

local function runInterWave(state)
    if INTER_WAVE_SECONDS <= 0 then
        return state.running
    end

    local endTime = os.clock() + INTER_WAVE_SECONDS

    while state.running and os.clock() < endTime do
        task.wait(0.1)
    end

    return state.running
end

local function runWave(state, waveNumber)
    state.phase = "Wave"
    state.wave = waveNumber
    state.waveOutcome = nil
    state.waveStartedAt = os.clock()
    state.waveDeadline = state.waveStartedAt + WAVE_DURATION_SECONDS

    ensureLevelSummary(state)

    updateArenaStateSnapshot(state)
    logPhase(state)
    broadcastWaveChange(state)
    scheduleWave(state)

    while state.running do
        local outcome = state.waveOutcome
        if outcome then
            if outcome.status == "success" then
                break
            elseif outcome.status == "failure" then
                triggerDefeat(state, outcome.reason or { type = "wave_failure", wave = waveNumber })
                break
            end
        end

        local deadline = state.waveDeadline
        if deadline and os.clock() >= deadline then
            triggerDefeat(state, { type = "timeout", wave = waveNumber })
            break
        end

        task.wait(0.1)
    end

    state.waveDeadline = nil

    if not state.running then
        return false
    end

    local summary = ensureLevelSummary(state)
    if summary then
        summary.wavesCleared = (summary.wavesCleared or 0) + 1
    end

    local rewards = grantWaveBonus(state)
    if rewards then
        accumulateLevelRewards(state, rewards)
    end

    local metadata = state.waveOutcome and state.waveOutcome.metadata
    local eventPayload = {}
    if typeof(metadata) == "table" then
        for key, value in pairs(metadata) do
            eventPayload[key] = value
        end
    end

    if state.waveStartedAt then
        local duration = os.clock() - state.waveStartedAt
        if typeof(eventPayload.duration) ~= "number" or eventPayload.duration <= 0 then
            eventPayload.duration = duration
        end
    end

    fireWaveCompleteEvent(state, true, eventPayload)

    state.waveOutcome = nil
    state.waveStartedAt = nil

    return state.running
end

local function runShop(state)
    state.phase = "Shop"
    state.wave = 0

    updateArenaStateSnapshot(state)
    logPhase(state)
    broadcastWaveChange(state)

    local shopEnd = os.clock() + SHOP_SECONDS

    while state.running and os.clock() < shopEnd do
        task.wait(0.1)
    end

    if not state.running then
        return false
    end

    if MatchReturnService and typeof(MatchReturnService.ReturnArena) == "function" then
        local ok, shouldStop = pcall(MatchReturnService.ReturnArena, state.arenaId, {
            reason = "LevelComplete",
            level = state.level,
            wave = state.wave,
        })
        if not ok then
            warn(string.format("[RoundDirectorServer] MatchReturnService.ReturnArena failed: %s", tostring(shouldStop)))
        elseif shouldStop then
            local reportOutcome = false
            if state.finalOutcome == nil then
                state.finalOutcome = "victory"
                reportOutcome = true
            end
            state.running = false

            if telemetryTrack and reportOutcome then
                local payload = {
                    arenaId = state.arenaId,
                    outcome = "victory",
                    level = state.level,
                    wave = state.wave,
                }

                local partyId = getPartyIdFromState(state)
                if partyId then
                    payload.partyId = partyId
                end

                if typeof(state.startedAt) == "number" then
                    payload.duration = math.max(0, os.clock() - state.startedAt)
                end

                telemetryTrack("match_end", payload)
            end
            return false
        end
    end

    state.level += 1
    updateArenaStateSnapshot(state)
    broadcastWaveChange(state)

    return true
end

local function runLevel(state)
    applyDifficultyBands(state)
    ensureLevelSummary(state)

    if not runPrep(state) then
        return false
    end

    for waveNumber = 1, WAVES_PER_LEVEL do
        if not runWave(state, waveNumber) then
            return false
        end

        if waveNumber < WAVES_PER_LEVEL and not runInterWave(state) then
            return false
        end
    end

    handleLevelCompletePhase(state)

    if not runShop(state) then
        return false
    end

    return state.running
end

local function runLoop(state)
    while state.running do
        if not runLevel(state) then
            break
        end
    end

    if telemetryTrack and state.finalOutcome == nil then
        local payload = {
            arenaId = state.arenaId,
            outcome = "stopped",
            level = state.level,
            wave = state.wave,
        }

        local partyId = getPartyIdFromState(state)
        if partyId then
            payload.partyId = partyId
        end

        if typeof(state.startedAt) == "number" then
            payload.duration = math.max(0, os.clock() - state.startedAt)
        end

        telemetryTrack("match_end", payload)
    end
    callSawblade("Stop", state.arenaId)

    if activeStates[state.arenaId] == state then
        activeStates[state.arenaId] = nil
    end

    if AchievementServer and typeof(AchievementServer.ResetArena) == "function" then
        local okAchievementReset, achievementResetErr = pcall(AchievementServer.ResetArena, state.arenaId)
        if not okAchievementReset then
            warn(string.format("[RoundDirectorServer] AchievementServer.ResetArena failed: %s", tostring(achievementResetErr)))
        end
    end

    if RoundSummaryServer and typeof(RoundSummaryServer.Reset) == "function" then
        local okReset, resetErr = pcall(RoundSummaryServer.Reset, state.arenaId)
        if not okReset then
            warn(string.format("[RoundDirectorServer] RoundSummaryServer.Reset failed: %s", tostring(resetErr)))
        end
    end
end

function RoundDirectorServer.Start(arenaId, options)
    assert(arenaId ~= nil, "arenaId is required")

    if activeStates[arenaId] then
        RoundDirectorServer.Abort(arenaId)
    end

    local arenaState = ArenaServer.GetArenaState and ArenaServer.GetArenaState(arenaId) or nil

    local startLevel = 1
    if arenaState and typeof(arenaState.level) == "number" then
        startLevel = arenaState.level
    end

    if options and typeof(options.StartLevel) == "number" then
        startLevel = math.max(1, math.floor(options.StartLevel))
    end

    if arenaState then
        arenaState.level = startLevel
        arenaState.wave = 0
        arenaState.phase = "Prep"
    end

    local state = {
        arenaId = arenaId,
        level = startLevel,
        wave = 0,
        phase = "Prep",
        running = true,
        prepEndTime = nil,
        arenaState = arenaState,
        defeat = false,
        aborted = false,
        currentLevelSummary = nil,
        waveOutcome = nil,
        waveStartedAt = nil,
        waveDeadline = nil,
        defeatReason = nil,
        startedAt = os.clock(),
        finalOutcome = nil,
        activeLaneCount = nil,
        lanePenaltyData = nil,
        currentRateMultiplier = 1,
        fruitRosterIds = nil,
        fruitWeights = nil,
        activeRosterBand = nil,
        obstaclesEnabled = false,
    }

    activeStates[arenaId] = state

    applyDifficultyBands(state)

    if telemetryTrack then
        local payload = {
            arenaId = arenaId,
            level = startLevel,
        }

        local partyId = getPartyIdFromState(state)
        if partyId then
            payload.partyId = partyId
        end

        local players = gatherArenaPlayers(state)
        if type(players) == "table" then
            payload.playerCount = #players
        end

        telemetryTrack("match_start", payload)
    end
    callSawblade("Start", arenaId, {
        level = state.level,
        phase = state.phase,
        wave = state.wave,
    })

    task.spawn(runLoop, state)

    return state
end

function RoundDirectorServer.Abort(arenaId)
    local state = activeStates[arenaId]
    if not state then
        return
    end

    state.aborted = true
    state.running = false
    local reportOutcome = false
    if state.finalOutcome == nil then
        state.finalOutcome = "aborted"
        reportOutcome = true
    end

    if MatchReturnService and typeof(MatchReturnService.ReturnArena) == "function" then
        local ok, result = pcall(MatchReturnService.ReturnArena, arenaId, {
            reason = "Abort",
            level = state.level,
            wave = state.wave,
        })
        if not ok then
            warn(string.format("[RoundDirectorServer] MatchReturnService.ReturnArena (abort) failed: %s", tostring(result)))
        end
    end

    state.phase = "Aborted"
    updateArenaStateSnapshot(state)
    broadcastWaveChange(state)
    callSawblade("UpdateRoundState", arenaId, {
        level = state.level,
        phase = state.phase,
        wave = state.wave,
    })
    callSawblade("Stop", arenaId)
    activeStates[arenaId] = nil
    sendPrepTimer(state, 0)

    if AchievementServer and typeof(AchievementServer.ResetArena) == "function" then
        local okAchievementReset, achievementResetErr = pcall(AchievementServer.ResetArena, arenaId)
        if not okAchievementReset then
            warn(string.format("[RoundDirectorServer] AchievementServer.ResetArena failed: %s", tostring(achievementResetErr)))
        end
    end

    if RoundSummaryServer and typeof(RoundSummaryServer.Reset) == "function" then
        local okReset, resetErr = pcall(RoundSummaryServer.Reset, arenaId)
        if not okReset then
            warn(string.format("[RoundDirectorServer] RoundSummaryServer.Reset failed: %s", tostring(resetErr)))
        end
    end

    if telemetryTrack and reportOutcome then
        local payload = {
            arenaId = arenaId,
            outcome = "aborted",
            level = state.level,
            wave = state.wave,
        }

        local partyId = getPartyIdFromState(state)
        if partyId then
            payload.partyId = partyId
        end

        if typeof(state.startedAt) == "number" then
            payload.duration = math.max(0, os.clock() - state.startedAt)
        end

        telemetryTrack("match_end", payload)
    end
end

function RoundDirectorServer.SetLevel(arenaId, level)
    local state = activeStates[arenaId]
    if not state or not state.running then
        return false, "NoArena"
    end

    local numeric = tonumber(level)
    if not numeric then
        return false, "InvalidLevel"
    end

    numeric = math.max(1, math.floor(numeric + 0.5))
    state.level = numeric
    state.wave = 0
    state.currentLevelSummary = nil
    state.waveOutcome = nil
    state.waveStartedAt = nil
    state.waveDeadline = nil

    updateArenaStateSnapshot(state)
    broadcastWaveChange(state)
    callSawblade("UpdateRoundState", state.arenaId, {
        level = state.level,
        phase = state.phase,
        wave = state.wave,
    })

    return true
end

function RoundDirectorServer.SkipPrep(arenaId)
    local state = activeStates[arenaId]
    if not state or not state.running or state.phase ~= "Prep" or not state.prepEndTime then
        return false
    end

    local newEndTime = os.clock() + SKIP_PREP_SECONDS
    if newEndTime >= state.prepEndTime then
        return false
    end

    state.prepEndTime = newEndTime

    local remaining = math.max(0, math.ceil(state.prepEndTime - os.clock()))
    sendPrepTimer(state, remaining)
    print(string.format("[RoundDirectorServer] arena=%s prep skipped; remaining=%d", state.arenaId, remaining))

    return true
end

function RoundDirectorServer.ReportWaveComplete(arenaId, metadata)
    local state = activeStates[arenaId]
    if not state or not state.running or state.phase ~= "Wave" then
        return false
    end

    local existing = state.waveOutcome
    if existing and existing.status == "failure" then
        return false
    end

    local storedMetadata = shallowCopy(metadata) or metadata

    if existing and existing.status == "success" then
        existing.metadata = storedMetadata
        return true
    end

    state.waveOutcome = {
        status = "success",
        metadata = storedMetadata,
    }

    return true
end

function RoundDirectorServer.ReportWaveFailed(arenaId, reason)
    local state = activeStates[arenaId]
    if not state or not state.running or state.phase ~= "Wave" then
        return false
    end

    state.waveOutcome = {
        status = "failure",
        reason = shallowCopy(reason) or reason,
    }

    return true
end

function RoundDirectorServer.GetState(arenaId)
    local state = activeStates[arenaId]
    if not state then
        return nil
    end

    local rosterCopy
    if typeof(state.fruitRosterIds) == "table" then
        rosterCopy = cloneArray(state.fruitRosterIds)
    end

    local weightCopy
    if typeof(state.fruitWeights) == "table" then
        weightCopy = shallowCopy(state.fruitWeights)
    end

    return {
        phase = state.phase,
        level = state.level,
        wave = state.wave,
        laneCount = state.activeLaneCount,
        fruitRoster = rosterCopy,
        fruitWeights = weightCopy,
        fireRateMultiplier = state.currentRateMultiplier,
        obstaclesEnabled = state.obstaclesEnabled,
    }
end

function RoundDirectorServer._debugGetInternalState(arenaId)
    return activeStates[arenaId]
end

return RoundDirectorServer
