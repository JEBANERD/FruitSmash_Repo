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

local function logUsage(player: Player, action: string, detail: string?)
        local suffix = detail and detail ~= "" and (" :: " .. detail) or ""
        print(string.format("[AdminCommands] %s -> %s%s", formatPlayer(player), action, suffix))
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
                local prepRemaining = getPrepRemaining(roundState)
                if prepRemaining ~= nil then
                        status.prepRemaining = prepRemaining
                end
        end
        status.obstaclesDisabled = getObstacleDisabled(arenaId)
        status.turretRate = getTurretMultiplier(arenaId)
        return status
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

        if not arenaId then
                return { ok = false, err = "NoArena" }
        end

        if action == "skipprep" then
                local ok, message = skipPrep(arenaId)
                logUsage(player, "SkipPrep", ok and "OK" or (message or "Failed"))
                return buildResponse(ok, message, arenaId)
        elseif action == "setlevel" then
                local levelValue = tonumber(request.level)
                if not levelValue then
                        return { ok = false, err = "InvalidLevel" }
                end
                local sanitizedLevel = math.max(1, math.floor(levelValue + 0.5))
                local ok, message = setLevel(arenaId, sanitizedLevel)
                local logDetail = string.format("level=%d %s", sanitizedLevel, ok and "OK" or (message or "Failed"))
                logUsage(player, "SetLevel", logDetail)
                return buildResponse(ok, message, arenaId)
        elseif action == "granttoken" then
                local tokenId = request.tokenId
                if typeof(tokenId) ~= "string" or tokenId == "" then
                        return { ok = false, err = "InvalidToken" }
                end
                local ok, message = grantToken(player, tokenId)
                local logDetail = string.format("token=%s %s", tokenId, ok and "OK" or (message or "Failed"))
                logUsage(player, "GrantToken", logDetail)
                return buildResponse(ok, message, arenaId)
        elseif action == "toggleobstacles" then
                local disabled = request.disabled == true
                local ok, message = setObstacles(arenaId, disabled)
                local logDetail = string.format("disabled=%s %s", tostring(disabled), ok and "OK" or (message or "Failed"))
                logUsage(player, "ToggleObstacles", logDetail)
                return buildResponse(ok, message, arenaId)
        elseif action == "setturretrate" then
                local multiplierValue = tonumber(request.multiplier)
                if not multiplierValue then
                        return { ok = false, err = "InvalidMultiplier" }
                end
                local ok, message = setTurretRate(arenaId, multiplierValue)
                local logDetail = string.format("multiplier=%.3f %s", multiplierValue, ok and "OK" or (message or "Failed"))
                logUsage(player, "SetTurretRate", logDetail)
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
