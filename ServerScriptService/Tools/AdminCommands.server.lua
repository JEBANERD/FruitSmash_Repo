--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
        remotesFolder = Instance.new("Folder")
        remotesFolder.Name = "Remotes"
        remotesFolder.Parent = ReplicatedStorage
end

local remoteFunction = remotesFolder:FindFirstChild("RF_QAAdminCommand")
if not remoteFunction then
        remoteFunction = Instance.new("RemoteFunction")
        remoteFunction.Name = "RF_QAAdminCommand"
        remoteFunction.Parent = remotesFolder
end

local Guard = require(ServerScriptService:WaitForChild("Moderation"):WaitForChild("GuardServer"))
local gameServerFolder = ServerScriptService:WaitForChild("GameServer")
local RoundDirectorServer = require(gameServerFolder:WaitForChild("RoundDirectorServer"))
local TurretControllerServer = require(gameServerFolder:WaitForChild("TurretControllerServer"))
local obstaclesFolder = gameServerFolder:WaitForChild("Obstacles")
local SawbladeServer = require(obstaclesFolder:WaitForChild("SawbladeServer"))
local ProfileServer = require(ServerScriptService:WaitForChild("Data"):WaitForChild("ProfileServer"))
local FruitSpawnerServer = require(gameServerFolder:WaitForChild("FruitSpawnerServer"))
local TargetHealthServer = require(gameServerFolder:WaitForChild("TargetHealthServer"))
local ArenaServer = require(gameServerFolder:WaitForChild("ArenaServer"))
local combatFolder = ServerScriptService:WaitForChild("Combat")
local CombatProjectileServer = require(combatFolder:WaitForChild("ProjectileServer"))
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local FruitConfigModule = configFolder:WaitForChild("FruitConfig")
local ShopConfigModule = configFolder:WaitForChild("ShopConfig")

local telemetryTrack: ((string, {[string]: any}?) -> ())? = nil
local TELEMETRY_EVENT_NAME = "qa_admin_action"

do
        local analyticsFolder = ServerScriptService:FindFirstChild("Analytics")
        local telemetryModule = analyticsFolder and analyticsFolder:FindFirstChild("TelemetryServer")
        if telemetryModule and telemetryModule:IsA("ModuleScript") then
                local ok, telemetry = pcall(require, telemetryModule)
                if ok and telemetry then
                        local trackFn = (telemetry :: any).Track
                        if typeof(trackFn) == "function" then
                                telemetryTrack = function(eventName: string, payload: {[string]: any}?)
                                        local success, err = pcall(trackFn, eventName, payload)
                                        if not success then
                                                warn(string.format("[AdminCommands] Telemetry.Track failed: %s", tostring(err)))
                                        end
                                end
                        end
                else
                        warn(string.format("[AdminCommands] Failed to require TelemetryServer: %s", tostring(telemetry)))
                end
        end
end

local shopItems: {[string]: any} = {}
do
        local ok, shopModule = pcall(require, ShopConfigModule)
        if ok and shopModule then
                local candidate
                if typeof(shopModule.All) == "function" then
                        local okAll, result = pcall(shopModule.All)
                        if okAll and typeof(result) == "table" then
                                candidate = result
                        end
                end
                if not candidate and typeof(shopModule.Items) == "table" then
                        candidate = shopModule.Items
                end
                if typeof(candidate) == "table" then
                        shopItems = candidate :: {[string]: any}
                end
        else
                warn(string.format("[AdminCommands] Failed to require ShopConfig: %s", tostring(shopModule)))
        end
end

local stressFruitIds: {string} = {}
do
        local ok, fruitModule = pcall(require, FruitConfigModule)
        if ok and fruitModule then
                        local roster
                        if typeof(fruitModule.All) == "function" then
                                local okRoster, result = pcall(fruitModule.All)
                                if okRoster and typeof(result) == "table" then
                                        roster = result
                                end
                        end
                        if not roster and typeof(fruitModule.Roster) == "table" then
                                roster = fruitModule.Roster
                        end
                        if typeof(roster) == "table" then
                                for id in pairs(roster) do
                                        if typeof(id) == "string" then
                                                table.insert(stressFruitIds, id)
                                        end
                                end
                        end
        else
                warn(string.format("[AdminCommands] Failed to require FruitConfig: %s", tostring(fruitModule)))
        end
end
if #stressFruitIds == 0 then
        stressFruitIds = { "Apple", "Banana", "Orange", "GrapeBundle", "Pineapple" }
end
table.sort(stressFruitIds)

local function resolveIntegerAttribute(name: string, defaultValue: number, minValue: number?): number
        local attributeValue = script:GetAttribute(name)
        local numeric: number?
        if typeof(attributeValue) == "number" then
                numeric = attributeValue
        elseif typeof(attributeValue) == "string" then
                numeric = tonumber(attributeValue)
        end
        if typeof(numeric) ~= "number" then
                return defaultValue
        end
        numeric = math.floor(numeric + 0.5)
        if minValue then
                numeric = math.max(minValue, numeric)
        end
        return numeric
end

local function resolveNumberAttribute(name: string, defaultValue: number, minValue: number?): number
        local attributeValue = script:GetAttribute(name)
        local numeric: number?
        if typeof(attributeValue) == "number" then
                numeric = attributeValue
        elseif typeof(attributeValue) == "string" then
                numeric = tonumber(attributeValue)
        end
        if typeof(numeric) ~= "number" then
                return defaultValue
        end
        if minValue then
                numeric = math.max(minValue, numeric)
        end
        return numeric
end

local macroSetLevelTarget = resolveIntegerAttribute("MacroSetLevel", 25, 1)
local macroCoinAmount = resolveIntegerAttribute("MacroCoinAmount", 5000, 1)
local macroStressPerLane = resolveIntegerAttribute("MacroStressPerLane", 12, 1)
local macroStressDelay = resolveNumberAttribute("MacroStressDelay", 0.15, 0)

local function resolveTokenStackLimit(tokenId: string, fallback: number): number
        local entry = shopItems[tokenId]
        if typeof(entry) == "table" then
                local limitValue = entry.StackLimit or entry.stackLimit
                if typeof(limitValue) == "number" then
                        local numeric = math.floor(limitValue + 0.5)
                        if numeric > 0 then
                                return numeric
                        end
                end
        end
        return math.max(1, fallback)
end

local macroTokenTargets: { { id: string, target: number } } = {
        { id = "Token_SpeedBoost", target = resolveTokenStackLimit("Token_SpeedBoost", 3) },
        { id = "Token_DoubleCoins", target = resolveTokenStackLimit("Token_DoubleCoins", 2) },
        { id = "Token_Shield", target = resolveTokenStackLimit("Token_Shield", 2) },
        { id = "Token_BurstClear", target = resolveTokenStackLimit("Token_BurstClear", 1) },
}

local STUDIO_ONLY = RunService:IsStudio()

local staticWhitelist: {number} = {}
local whitelistLookup: {[number]: boolean} = {}

local function addUserId(id: number)
        if id <= 0 then
                return
        end
        whitelistLookup[id] = true
end

for _, userId in ipairs(staticWhitelist) do
        if typeof(userId) == "number" then
                addUserId(math.floor(userId + 0.5))
        end
end

local function parseWhitelistAttribute(value: any)
        if value == nil then
                return
        end
        if typeof(value) == "number" then
                addUserId(math.floor(value + 0.5))
                return
        end
        if typeof(value) ~= "string" then
                return
        end
        for numeric in string.gmatch(value, "%d+") do
                local userId = tonumber(numeric)
                if userId then
                        addUserId(math.floor(userId + 0.5))
                end
        end
end

parseWhitelistAttribute(script:GetAttribute("AdminUserIds"))

local function mergeModuleWhitelist(moduleScript: Instance?)
        if not moduleScript or not moduleScript:IsA("ModuleScript") then
                return
        end
        local ok, result = pcall(require, moduleScript)
        if not ok then
                warn(string.format("[AdminCommands] Failed to require %s: %s", moduleScript:GetFullName(), tostring(result)))
                return
        end
        if typeof(result) == "table" then
                for key, value in pairs(result) do
                        if typeof(value) == "boolean" then
                                if value and typeof(key) == "number" then
                                        addUserId(math.floor(key + 0.5))
                                end
                        elseif typeof(value) == "number" then
                                addUserId(math.floor(value + 0.5))
                        end
                end
                for _, entry in ipairs(result) do
                        if typeof(entry) == "number" then
                                addUserId(math.floor(entry + 0.5))
                        end
                end
        elseif typeof(result) == "number" then
                addUserId(math.floor(result + 0.5))
        end
end

mergeModuleWhitelist(script:FindFirstChild("Whitelist"))
mergeModuleWhitelist(script.Parent:FindFirstChild("AdminWhitelist"))

local function isAuthorized(player: Player): boolean
        if STUDIO_ONLY then
                return true
        end
        local userId = player.UserId
        if whitelistLookup[userId] then
                return true
        end
        return false
end

local function formatPlayer(player: Player): string
        return string.format("%s (%d)", player.Name, player.UserId)
end

local function logUsage(player: Player, action: string, detail: string?, extra: {[string]: any}?)
        local suffix = detail and detail ~= "" and (" :: " .. detail) or ""
        print(string.format("[AdminCommands] %s -> %s%s", formatPlayer(player), action, suffix))
        if telemetryTrack then
                local payload: {[string]: any} = {
                        userId = player.UserId,
                        player = player.Name,
                        action = action,
                        studio = STUDIO_ONLY,
                }
                if detail and detail ~= "" then
                        payload.detail = detail
                end
                if extra then
                        for key, value in pairs(extra) do
                                local valueType = typeof(value)
                                if valueType == "string" or valueType == "number" or valueType == "boolean" then
                                        payload[key] = value
                                end
                        end
                end
                telemetryTrack(TELEMETRY_EVENT_NAME, payload)
        end
end

local function resolveArenaId(player: Player, arenaId: any): string?
        if typeof(arenaId) == "string" and arenaId ~= "" then
                return arenaId
        end
        if typeof(arenaId) == "number" then
                return tostring(arenaId)
        end
        local attribute = player:GetAttribute("ArenaId")
        if typeof(attribute) == "string" and attribute ~= "" then
                return attribute
        end
        if typeof(attribute) == "number" then
                return tostring(attribute)
        end
        return nil
end

local function getRoundState(arenaId: string)
        if typeof(RoundDirectorServer) ~= "table" then
                return nil
        end
        local state
        if typeof((RoundDirectorServer :: any)._debugGetInternalState) == "function" then
                local ok, result = pcall((RoundDirectorServer :: any)._debugGetInternalState, arenaId)
                if ok and typeof(result) == "table" then
                        state = result
                end
        end
        if not state and typeof((RoundDirectorServer :: any).GetState) == "function" then
                local ok, result = pcall((RoundDirectorServer :: any).GetState, arenaId)
                if ok and typeof(result) == "table" then
                        state = result
                end
        end
        return state
end

local function getPrepRemaining(roundState: any): number?
        if typeof(roundState) ~= "table" then
                return nil
        end
        local phase = roundState.phase or roundState.Phase
        if phase ~= "Prep" then
                return nil
        end
        local prepEnd = roundState.prepEndTime or roundState.PrepEndTime
        if typeof(prepEnd) ~= "number" then
                return nil
        end
        local remaining = math.ceil(prepEnd - os.clock())
        if remaining < 0 then
                remaining = 0
        end
        return remaining
end

local function getTurretMultiplier(arenaId: string): number
        if typeof(TurretControllerServer) ~= "table" then
                return 1
        end
        local getter = (TurretControllerServer :: any).GetRateMultiplier
        if typeof(getter) ~= "function" then
                return 1
        end
        local ok, result = pcall(getter, TurretControllerServer, arenaId)
        if ok and typeof(result) == "number" then
                return result
        end
        return 1
end

local function getObstacleDisabled(arenaId: string): boolean
        if typeof(SawbladeServer) ~= "table" then
                return false
        end
        local getter = (SawbladeServer :: any).IsQADisabled
        if typeof(getter) ~= "function" then
                return false
        end
        local ok, result = pcall(getter, SawbladeServer, arenaId)
        if ok then
                return result == true
        end
        return false
end

local function buildArenaStatus(arenaId: string): {[string]: any}
        local status: {[string]: any} = { arenaId = arenaId }
        local roundState = getRoundState(arenaId)
        if typeof(roundState) == "table" then
                local level = roundState.level or roundState.Level
                if typeof(level) == "number" then
                        status.level = level
                end
                local wave = roundState.wave or roundState.Wave
                if typeof(wave) == "number" then
                        status.wave = wave
                end
                local phase = roundState.phase or roundState.Phase
                if typeof(phase) == "string" then
                        status.phase = phase
                end
                local laneCountValue = roundState.laneCount or roundState.LaneCount
                if typeof(laneCountValue) == "number" then
                        status.laneCount = math.max(0, math.floor(laneCountValue + 0.5))
                end
                local prepRemaining = getPrepRemaining(roundState)
                if prepRemaining ~= nil then
                        status.prepRemaining = prepRemaining
                end
        end
        status.obstaclesDisabled = getObstacleDisabled(arenaId)
        status.turretRate = getTurretMultiplier(arenaId)
        return status
end

local function toNonNegativeInteger(value: any): number?
        if typeof(value) == "number" then
                if value ~= value then
                        return nil
                end
                if value < 0 then
                        return 0
                end
                return math.floor(value + 0.5)
        elseif typeof(value) == "string" then
                local numeric = tonumber(value)
                if numeric and numeric >= 0 then
                        return math.floor(numeric + 0.5)
                end
        end
        return nil
end

local function getTokenCount(player: Player, tokenId: string): number
        local getter = (ProfileServer :: any).GetProfileAndInventory
        if typeof(getter) ~= "function" then
                return 0
        end
        local ok, _, _, inventory = pcall(getter, player)
        if not ok or typeof(inventory) ~= "table" then
                return 0
        end
        local counts = inventory.TokenCounts
        if typeof(counts) ~= "table" then
                return 0
        end
        return toNonNegativeInteger(counts[tokenId]) or 0
end

local function gatherLaneIndices(arenaId: string): ({number}, number)
        local indices: {number} = {}
        local arenaGetter = (ArenaServer :: any).GetArenaState
        if typeof(arenaGetter) == "function" then
                local ok, arenaState = pcall(arenaGetter, arenaId)
                if ok and typeof(arenaState) == "table" then
                        local laneList = arenaState.lanes
                        if typeof(laneList) == "table" then
                                for index = 1, #laneList do
                                        table.insert(indices, index)
                                end
                        end
                end
        end
        local laneCount = #indices
        if laneCount == 0 then
                local roundState = getRoundState(arenaId)
                if typeof(roundState) == "table" then
                        local candidate = roundState.laneCount or roundState.LaneCount
                        if typeof(candidate) == "number" and candidate > 0 then
                                laneCount = math.max(0, math.floor(candidate + 0.5))
                                for index = 1, laneCount do
                                        table.insert(indices, index)
                                end
                        end
                end
        end
        return indices, laneCount
end

local function ensureTokenCount(player: Player, tokenId: string, targetCount: number): (number, string?, boolean)
        local desired = math.max(0, targetCount)
        local current = getTokenCount(player, tokenId)
        local maxAttempts = math.max(desired * 2, 4)
        local attempts = 0
        local warning: string? = nil
        local capped = false
        while current < desired and attempts < maxAttempts do
                attempts += 1
                local okGrant, err = grantToken(player, tokenId)
                if not okGrant then
                        if err == "StackLimit" then
                                capped = true
                                break
                        else
                                warning = err or "GrantFailed"
                                break
                        end
                end
                current = getTokenCount(player, tokenId)
        end
        if current < desired and not capped and warning == nil then
                warning = "Incomplete"
        end
        return current, warning, capped
end

local function getCoinTotal(player: Player): number
        local getter = (ProfileServer :: any).GetData
        if typeof(getter) ~= "function" then
                return 0
        end
        local ok, data = pcall(getter, player)
        if not ok or typeof(data) ~= "table" then
                return 0
        end
        return toNonNegativeInteger(data.Coins) or 0
end

type MacroTelemetry = { [string]: string | number | boolean }
type MacroResult = {
        ok: boolean,
        message: string?,
        detail: string?,
        arenaId: string?,
        telemetry: MacroTelemetry?,
}
type MacroHandler = (Player, string?) -> MacroResult

local macroHandlers: { [string]: MacroHandler } = {}

macroHandlers.skipprep = function(_player: Player, arenaId: string?)
        if not arenaId then
                return {
                        ok = false,
                        message = "No active arena",
                        detail = "NoArena",
                }
        end
        local okSkip, err = skipPrep(arenaId)
        local message = if okSkip then "Prep skip triggered" else (err or "Skip prep failed")
        return {
                ok = okSkip,
                message = message,
                detail = okSkip and "OK" or (err or "Failed"),
                arenaId = arenaId,
        }
end

macroHandlers.setlevel = function(_player: Player, arenaId: string?)
        if not arenaId then
                return {
                        ok = false,
                        message = "No active arena",
                        detail = "NoArena",
                }
        end
        local targetLevel = macroSetLevelTarget
        local okSet, err = setLevel(arenaId, targetLevel)
        local detail = string.format("level=%d %s", targetLevel, okSet and "OK" or (err or "Failed"))
        local message = if okSet then string.format("Level set to %d", targetLevel) else (err or "Set level failed")
        return {
                ok = okSet,
                message = message,
                detail = detail,
                arenaId = arenaId,
                telemetry = { level = targetLevel },
        }
end

macroHandlers.granttokens = function(player: Player, arenaId: string?)
        local detailParts = {}
        local warningParts = {}
        for _, entry in ipairs(macroTokenTargets) do
                local target = math.max(1, entry.target)
                local finalCount, warning, capped = ensureTokenCount(player, entry.id, target)
                local descriptor = string.format("%s=%d", entry.id, finalCount)
                if capped and finalCount < target then
                        descriptor = string.format("%s=%d(cap)", entry.id, finalCount)
                end
                table.insert(detailParts, descriptor)
                if warning and warning ~= "" then
                        table.insert(warningParts, string.format("%s:%s", entry.id, warning))
                end
        end
        local detail = table.concat(detailParts, "; ")
        local okTokens = #warningParts == 0
        local message = if okTokens then "Token loadout ready" else "Token loadout partial"
        local telemetry: MacroTelemetry = { tokens = detail }
        if #warningParts > 0 then
                        telemetry.warning = table.concat(warningParts, ",")
        end
        return {
                ok = okTokens,
                message = message,
                detail = detail,
                arenaId = arenaId,
                telemetry = telemetry,
        }
end

macroHandlers.stressspawn = function(_player: Player, arenaId: string?)
        if not arenaId then
                return {
                        ok = false,
                        message = "No active arena",
                        detail = "NoArena",
                }
        end
        local queueFn = (FruitSpawnerServer :: any).Queue
        if typeof(queueFn) ~= "function" then
                return {
                        ok = false,
                        message = "Spawn unavailable",
                        detail = "QueueUnavailable",
                        arenaId = arenaId,
                }
        end
        local startWarning: string? = nil
        local startFn = (FruitSpawnerServer :: any).Start
        if typeof(startFn) == "function" then
                local okStart, errStart = pcall(startFn, arenaId)
                if not okStart then
                        startWarning = tostring(errStart)
                end
        end
        local lanes, laneCount = gatherLaneIndices(arenaId)
        if laneCount <= 0 then
                return {
                        ok = false,
                        message = "No lanes available",
                        detail = "NoLanes",
                        arenaId = arenaId,
                }
        end
        local fruitCount = #stressFruitIds
        if fruitCount == 0 then
                return {
                        ok = false,
                        message = "Fruit roster unavailable",
                        detail = "NoFruit",
                        arenaId = arenaId,
                }
        end
        local errors = {}
        local totalQueued = 0
        for _, lane in ipairs(lanes) do
                for spawnIndex = 1, macroStressPerLane do
                        local fruitId = stressFruitIds[((spawnIndex - 1) % fruitCount) + 1]
                        local delay = (spawnIndex - 1) * macroStressDelay
                        local payload = if delay > 0 then { FruitId = fruitId, Delay = delay } else { FruitId = fruitId }
                        local okQueue, errQueue = pcall(queueFn, arenaId, lane, payload)
                        if okQueue then
                                totalQueued += 1
                        else
                                table.insert(errors, tostring(errQueue))
                        end
                end
        end
        local okSpawn = #errors == 0
        local detailParts = {
                string.format("lanes=%d", laneCount),
                string.format("queued=%d", totalQueued),
        }
        if startWarning then
                table.insert(detailParts, "startwarn")
        end
        if not okSpawn then
                table.insert(detailParts, string.format("failures=%d", #errors))
        end
        local detail = table.concat(detailParts, " ")
        local message = if okSpawn then "Stress spawn queued" else "Stress spawn partial"
        local telemetry: MacroTelemetry = {
                lanes = laneCount,
                spawned = totalQueued,
        }
        if startWarning then
                telemetry.startWarn = startWarning
        end
        if not okSpawn then
                telemetry.failures = #errors
        end
        return {
                ok = okSpawn,
                message = message,
                detail = detail,
                arenaId = arenaId,
                telemetry = telemetry,
        }
end

macroHandlers.clearfruit = function(_player: Player, arenaId: string?)
        if not arenaId then
                return {
                        ok = false,
                        message = "No active arena",
                        detail = "NoArena",
                }
        end
        local warnings = {}
        local okClear = true
        local stopFn = (FruitSpawnerServer :: any).Stop
        if typeof(stopFn) == "function" then
                local okStop, errStop = pcall(stopFn, arenaId)
                if not okStop then
                        okClear = false
                        table.insert(warnings, string.format("Stop:%s", tostring(errStop)))
                end
        end
        local projectileClear = (CombatProjectileServer :: any).ClearArena
        if typeof(projectileClear) == "function" then
                local okProj, errProj = pcall(projectileClear, arenaId)
                if not okProj then
                        okClear = false
                        table.insert(warnings, string.format("Projectiles:%s", tostring(errProj)))
                end
        end
        local targetClear = (TargetHealthServer :: any).ClearArena
        if typeof(targetClear) == "function" then
                local okTarget, errTarget = pcall(targetClear, arenaId)
                if not okTarget then
                        okClear = false
                        table.insert(warnings, string.format("Target:%s", tostring(errTarget)))
                end
        end
        local _, laneCount = gatherLaneIndices(arenaId)
        local initFn = (TargetHealthServer :: any).InitializeArena
        if typeof(initFn) == "function" then
                local roundState = getRoundState(arenaId)
                local initOptions: {[string]: any} = {}
                if typeof(roundState) == "table" then
                        local levelValue = roundState.level or roundState.Level
                        if typeof(levelValue) == "number" then
                                initOptions.Level = math.max(1, math.floor(levelValue + 0.5))
                        end
                end
                if laneCount > 0 then
                        initOptions.LaneCount = laneCount
                end
                local okInit, errInit = pcall(initFn, arenaId, initOptions)
                if not okInit then
                        okClear = false
                        table.insert(warnings, string.format("TargetInit:%s", tostring(errInit)))
                end
        end
        local detailParts = {}
        if laneCount > 0 then
                table.insert(detailParts, string.format("lanes=%d", laneCount))
        end
        local detail = table.concat(detailParts, " ")
        if #warnings > 0 then
                local warningText = table.concat(warnings, ",")
                if detail ~= "" then
                        detail = detail .. " "
                end
                detail = detail .. "warn=" .. warningText
        end
        if detail == "" then
                detail = okClear and "Cleared" or "Warnings"
        end
        local telemetry: MacroTelemetry = {}
        if laneCount > 0 then
                telemetry.lanes = laneCount
        end
        if #warnings > 0 then
                telemetry.warning = table.concat(warnings, ";")
        end
        return {
                ok = okClear,
                message = if okClear then "Arena cleared" else "Arena cleared with warnings",
                detail = detail,
                arenaId = arenaId,
                telemetry = telemetry,
        }
end

macroHandlers.addcoins = function(player: Player, arenaId: string?)
        if macroCoinAmount <= 0 then
                return {
                        ok = false,
                        message = "Coin amount not configured",
                        detail = "CoinAmount=0",
                        arenaId = arenaId,
                }
        end
        local adder = (ProfileServer :: any).AddCoins
        if typeof(adder) ~= "function" then
                return {
                        ok = false,
                        message = "AddCoins unavailable",
                        detail = "AddCoinsUnavailable",
                        arenaId = arenaId,
                }
        end
        local okAdd, result = pcall(adder, player, macroCoinAmount)
        if not okAdd then
                return {
                        ok = false,
                        message = "Add coins failed",
                        detail = tostring(result),
                        arenaId = arenaId,
                }
        end
        local totalCoins = toNonNegativeInteger(result) or getCoinTotal(player)
        local message = string.format("Added %d coins", macroCoinAmount)
        local detail = string.format("added=%d total=%d", macroCoinAmount, totalCoins)
        local telemetry: MacroTelemetry = {
                coinsAdded = macroCoinAmount,
                coinsTotal = totalCoins,
        }
        return {
                ok = true,
                message = message,
                detail = detail,
                arenaId = arenaId,
                telemetry = telemetry,
        }
end

local function normalizeMacroId(value: string?): string?
        if typeof(value) ~= "string" then
                return nil
        end
        local sanitized = string.lower(value)
        sanitized = string.gsub(sanitized, "[^%w]", "")
        sanitized = string.gsub(sanitized, "_", "")
        if sanitized == "" then
                return nil
        end
        return sanitized
end

local function runMacro(player: Player, macroId: string, arenaId: string?): MacroResult
        local handler = macroHandlers[macroId]
        if not handler then
                return {
                        ok = false,
                        message = "Unknown macro",
                        detail = "InvalidMacro",
                        arenaId = arenaId,
                }
        end
        local okCall, result = pcall(handler, player, arenaId)
        if not okCall then
                return {
                        ok = false,
                        message = "Macro error",
                        detail = tostring(result),
                        arenaId = arenaId,
                }
        end
        if typeof(result) ~= "table" then
                return {
                        ok = false,
                        message = "Macro error",
                        detail = "InvalidResult",
                        arenaId = arenaId,
                }
        end
        if result.arenaId == nil then
                result.arenaId = arenaId
        elseif typeof(result.arenaId) == "number" then
                result.arenaId = tostring(result.arenaId)
        end
        if not result.detail or result.detail == "" then
                result.detail = result.ok and "OK" or (result.message or "Failed")
        end
        return result :: MacroResult
end

local function describeResult(ok: boolean, err: any?): string?
        if ok then
                return nil
        end
        if err == nil then
                return "UnknownError"
        end
        if typeof(err) == "string" then
                return err
        end
        return tostring(err)
end

local function skipPrep(arenaId: string): (boolean, string?)
        if typeof((RoundDirectorServer :: any).SkipPrep) ~= "function" then
                return false, "SkipPrepUnavailable"
        end
        local ok, result = pcall((RoundDirectorServer :: any).SkipPrep, arenaId)
        if not ok then
                warn(string.format("[AdminCommands] SkipPrep failed: %s", tostring(result)))
                return false, "SkipPrepError"
        end
        if result then
                return true, nil
        end
        return false, "SkipPrepDenied"
end

local function setLevel(arenaId: string, level: number): (boolean, string?)
        if typeof((RoundDirectorServer :: any).SetLevel) ~= "function" then
                return false, "SetLevelUnavailable"
        end
        local ok, result, message = pcall((RoundDirectorServer :: any).SetLevel, arenaId, level)
        if not ok then
                warn(string.format("[AdminCommands] SetLevel failed: %s", tostring(result)))
                return false, "SetLevelError"
        end
        if result then
                return true, if typeof(message) == "string" then message else nil
        end
        if typeof(message) == "string" then
                return false, message
        end
        return false, "SetLevelDenied"
end

local function grantToken(player: Player, tokenId: string): (boolean, string?)
        if typeof((ProfileServer :: any).GrantItem) ~= "function" then
                return false, "GrantUnavailable"
        end
        local ok, result, err = pcall((ProfileServer :: any).GrantItem, player, tokenId)
        if not ok then
                warn(string.format("[AdminCommands] GrantItem failed: %s", tostring(result)))
                return false, "GrantError"
        end
        if result then
                return true, nil
        end
        if typeof(err) == "string" then
                return false, err
        end
        return false, "GrantDenied"
end

local function setObstacles(arenaId: string, disabled: boolean): (boolean, string?)
        if typeof((SawbladeServer :: any).SetQADisabled) ~= "function" then
                return false, "ObstacleToggleUnavailable"
        end
        local ok, result = pcall((SawbladeServer :: any).SetQADisabled, arenaId, disabled)
        if not ok then
                warn(string.format("[AdminCommands] SetQADisabled failed: %s", tostring(result)))
                return false, "ObstacleToggleError"
        end
        if result ~= nil then
                return true, nil
        end
        return true, nil
end

local function setTurretRate(arenaId: string, multiplier: number): (boolean, string?)
        if typeof((TurretControllerServer :: any).SetRateMultiplier) ~= "function" then
                return false, "TurretRateUnavailable"
        end
        local ok, result, message = pcall((TurretControllerServer :: any).SetRateMultiplier, arenaId, multiplier)
        if not ok then
                warn(string.format("[AdminCommands] SetRateMultiplier failed: %s", tostring(result)))
                return false, "TurretRateError"
        end
        if result then
                return true, if typeof(message) == "string" then message else nil
        end
        if typeof(message) == "string" then
                return false, message
        end
        return false, "TurretRateDenied"
end

local VALID_ACTIONS = {
        getstate = true,
        skipprep = true,
        setlevel = true,
        granttoken = true,
        toggleobstacles = true,
        setturretrate = true,
        macro = true,
}

local function validatePayload(_player: Player, payload: any)
        if payload == nil then
                return false, "BadPayload"
        end
        if typeof(payload) ~= "table" then
                return false, "BadPayload"
        end
        local actionValue = payload.action or payload.Action
        if typeof(actionValue) ~= "string" or actionValue == "" then
                return false, "BadAction"
        end
        local action = string.lower(actionValue)
        if not VALID_ACTIONS[action] then
                return false, "UnsupportedAction"
        end
        local sanitized = { action = action }

        local arenaCandidate = payload.arenaId or payload.ArenaId
        if arenaCandidate ~= nil then
                if typeof(arenaCandidate) == "string" and arenaCandidate ~= "" then
                        sanitized.arenaId = arenaCandidate
                elseif typeof(arenaCandidate) == "number" then
                        sanitized.arenaId = tostring(arenaCandidate)
                end
        end

        if action == "setlevel" then
                local levelValue = payload.level or payload.Level
                if levelValue == nil then
                        return false, "MissingLevel"
                end
                local numeric = tonumber(levelValue)
                if not numeric then
                        return false, "InvalidLevel"
                end
                sanitized.level = numeric
        elseif action == "granttoken" then
                local tokenId = payload.tokenId or payload.TokenId or payload.token or payload.Token
                if typeof(tokenId) ~= "string" or tokenId == "" then
                        return false, "InvalidToken"
                end
                sanitized.tokenId = tokenId
        elseif action == "toggleobstacles" then
                local disabledValue = payload.disabled
                if typeof(disabledValue) ~= "boolean" then
                        if typeof(payload.enabled) == "boolean" then
                                disabledValue = not payload.enabled
                        elseif payload.disable ~= nil then
                                disabledValue = payload.disable and true or false
                        else
                                disabledValue = true
                        end
                end
                sanitized.disabled = disabledValue and true or false
        elseif action == "setturretrate" then
                local rateValue = payload.multiplier or payload.Multiplier or payload.rate or payload.Rate
                if rateValue == nil then
                        return false, "MissingMultiplier"
                end
                local numeric = tonumber(rateValue)
                if not numeric then
                        return false, "InvalidMultiplier"
                end
                sanitized.multiplier = numeric
        elseif action == "macro" then
                local macroValue = payload.macro or payload.Macro or payload.macroId or payload.MacroId
                local normalized = normalizeMacroId(macroValue)
                if not normalized then
                        return false, "InvalidMacro"
                end
                sanitized.macro = normalized
        end

        return true, sanitized
end

local function buildResponse(ok: boolean, message: string?, arenaId: string?): {[string]: any}
        local response: {[string]: any} = { ok = ok }
        if message and message ~= "" then
                response.message = message
        end
        if arenaId then
                response.state = buildArenaStatus(arenaId)
        end
        return response
end

local function handleRequest(player: Player, request: {[string]: any})
        if not isAuthorized(player) then
                return { ok = false, err = "NotAuthorized" }
        end

        local action = request.action
        local arenaId = resolveArenaId(player, request.arenaId)

        if action == "getstate" then
                if not arenaId then
                        return { ok = false, err = "NoArena" }
                end
                return buildResponse(true, nil, arenaId)
        end

        if action == "macro" then
                local macroId = request.macro
                if typeof(macroId) ~= "string" or macroId == "" then
                        return { ok = false, err = "InvalidMacro" }
                end
                local result = runMacro(player, macroId, arenaId)
                local extra: {[string]: any} = {
                        arenaId = result.arenaId,
                        macro = macroId,
                        ok = result.ok,
                }
                if result.message and result.message ~= "" then
                        extra.message = result.message
                end
                if result.telemetry then
                        for key, value in pairs(result.telemetry) do
                                local valueType = typeof(value)
                                if valueType == "string" or valueType == "number" or valueType == "boolean" then
                                        extra[key] = value
                                end
                        end
                end
                logUsage(player, "Macro/" .. macroId, result.detail, extra)
                return buildResponse(result.ok, result.message, result.arenaId)
        end

        if not arenaId then
                return { ok = false, err = "NoArena" }
        end

        if action == "skipprep" then
                local ok, message = skipPrep(arenaId)
                logUsage(player, "SkipPrep", ok and "OK" or (message or "Failed"), {
                        arenaId = arenaId,
                        ok = ok,
                })
                return buildResponse(ok, message, arenaId)
        elseif action == "setlevel" then
                local levelValue = tonumber(request.level)
                if not levelValue then
                        return { ok = false, err = "InvalidLevel" }
                end
                local sanitizedLevel = math.max(1, math.floor(levelValue + 0.5))
                local ok, message = setLevel(arenaId, sanitizedLevel)
                local logDetail = string.format("level=%d %s", sanitizedLevel, ok and "OK" or (message or "Failed"))
                logUsage(player, "SetLevel", logDetail, {
                        arenaId = arenaId,
                        ok = ok,
                        level = sanitizedLevel,
                })
                return buildResponse(ok, message, arenaId)
        elseif action == "granttoken" then
                local tokenId = request.tokenId
                if typeof(tokenId) ~= "string" or tokenId == "" then
                        return { ok = false, err = "InvalidToken" }
                end
                local ok, message = grantToken(player, tokenId)
                local logDetail = string.format("token=%s %s", tokenId, ok and "OK" or (message or "Failed"))
                logUsage(player, "GrantToken", logDetail, {
                        arenaId = arenaId,
                        ok = ok,
                        tokenId = tokenId,
                })
                return buildResponse(ok, message, arenaId)
        elseif action == "toggleobstacles" then
                local disabled = request.disabled == true
                local ok, message = setObstacles(arenaId, disabled)
                local logDetail = string.format("disabled=%s %s", tostring(disabled), ok and "OK" or (message or "Failed"))
                logUsage(player, "ToggleObstacles", logDetail, {
                        arenaId = arenaId,
                        ok = ok,
                        disabled = disabled,
                })
                return buildResponse(ok, message, arenaId)
        elseif action == "setturretrate" then
                local multiplierValue = tonumber(request.multiplier)
                if not multiplierValue then
                        return { ok = false, err = "InvalidMultiplier" }
                end
                local ok, message = setTurretRate(arenaId, multiplierValue)
                local logDetail = string.format("multiplier=%.3f %s", multiplierValue, ok and "OK" or (message or "Failed"))
                logUsage(player, "SetTurretRate", logDetail, {
                        arenaId = arenaId,
                        ok = ok,
                        multiplier = multiplierValue,
                })
                return buildResponse(ok, message, arenaId)
        end

        return { ok = false, err = "UnsupportedAction" }
end

Guard.WrapRemote(remoteFunction, {
        remoteName = "RF_QAAdminCommand",
        rateLimit = { maxCalls = 12, interval = 2 },
        validator = validatePayload,
        rejectResponse = function(reason)
                return { ok = false, err = reason }
        end,
}, handleRequest)

print("[AdminCommands] QA admin remote ready")
