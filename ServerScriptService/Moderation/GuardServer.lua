--!strict

local Players = game:GetService("Players")

export type RateLimitConfig = {
        maxCalls: number?,
        interval: number?,
        count: number?,
        window: number?,
        period: number?,
        seconds: number?,
}

export type GuardConfig = {
        rateLimit: RateLimitConfig?,
        validator: ((Player, ...any) -> (boolean, any?))?,
        remoteName: string?,
        rejectResponse: any?,
        handler: ((Player, any?) -> any?)?,
}

local Guard = {}

type RateBucket = { count: number, windowStart: number }

type RateBucketMap = { [Player]: RateBucket }

type RateState = { [Instance]: RateBucketMap }

local rateState: RateState = setmetatable({}, { __mode = "k" })

local function shallowCopy(tbl: { [any]: any }): { [any]: any }
        local copy = {}
        for key, value in pairs(tbl) do
                copy[key] = value
        end
        return copy
end

local function formatPlayer(player: any): string
        if typeof(player) == "Instance" and player:IsA("Player") then
                return string.format("%s (%d)", player.Name, player.UserId)
        end
        return tostring(player)
end

local function logDenial(remoteName: string, player: any, reason: string?, detail: any?)
        local message = string.format("[Guard] %s blocked %s: %s", remoteName, formatPlayer(player), reason or "Rejected")
        if detail ~= nil then
                message = message .. " :: " .. tostring(detail)
        end
        warn(message)
end

local function normalizeRateLimit(limit: RateLimitConfig?): { maxCalls: number, interval: number }?
        if typeof(limit) ~= "table" then
                return nil
        end

        local maxCalls = limit.maxCalls or limit.count or limit.max
        local interval = limit.interval or limit.window or limit.period or limit.seconds

        maxCalls = tonumber(maxCalls)
        interval = tonumber(interval)

        if not maxCalls or maxCalls <= 0 then
                return nil
        end
        if not interval or interval <= 0 then
                return nil
        end

        return {
                maxCalls = math.max(1, math.floor(maxCalls)),
                interval = math.max(interval, 0.01),
        }
end

local function ensureBucket(remote: Instance, player: Player): RateBucket
        local remoteBuckets = rateState[remote]
        if not remoteBuckets then
                remoteBuckets = setmetatable({}, { __mode = "k" })
                rateState[remote] = remoteBuckets
        end

        local bucket = remoteBuckets[player]
        if not bucket then
                bucket = { count = 0, windowStart = 0 }
                remoteBuckets[player] = bucket
        end

        return bucket
end

local function isThrottled(remote: Instance, player: Player, limit: { maxCalls: number, interval: number }?): boolean
        if not limit then
                return false
        end

        local bucket = ensureBucket(remote, player)
        local now = os.clock()

        if now - bucket.windowStart >= limit.interval then
                bucket.windowStart = now
                bucket.count = 0
        end

        if bucket.count >= limit.maxCalls then
                return true
        end

        bucket.count += 1
        return false
end

local function runValidator(remote: Instance, validator: (Player, ...any) -> (boolean, any?), player: Player, rawArgs: { any } & { n: number }): (boolean, any, any)
        local success, first, second, third = pcall(validator, player, table.unpack(rawArgs, 1, rawArgs.n))
        if not success then
                return false, "ValidatorError", first
        end
        if first == false then
                local reason = if typeof(second) == "string" then second else "InvalidPayload"
                return false, reason, third
        end
        if first == true then
                return true, second, third
        end
        return true, first, second
end

local function cloneRejectResponse(reject: any): any
        if typeof(reject) ~= "table" then
                return reject
        end
        return shallowCopy(reject)
end

local function makeRejectResponse(config: GuardConfig, reason: string?): any
        local reject = config.rejectResponse
        local finalReason = if typeof(reason) == "string" and reason ~= "" then reason else "Rejected"

        if typeof(reject) == "function" then
                local ok, result = pcall(reject, finalReason)
                if ok then
                        return result
                end
        elseif reject ~= nil then
                local response = cloneRejectResponse(reject)
                if typeof(response) == "table" then
                        response.err = finalReason
                end
                return response
        end

        return { ok = false, err = finalReason }
end

local function isValidPlayer(player: any): boolean
        return typeof(player) == "Instance" and player:IsA("Player")
end

function Guard.WrapRemote(remote: Instance?, config: GuardConfig?, handler: ((Player, any?) -> any?)?)
        if remote == nil then
                warn("[Guard] Attempted to wrap a nil remote")
                return nil
        end

        if not remote:IsA("RemoteEvent") and not remote:IsA("RemoteFunction") then
                warn(string.format("[Guard] Unsupported remote type %s for %s", remote.ClassName, remote:GetFullName()))
                return nil
        end

        config = config or {}
        handler = handler or config.handler

        local remoteName = config.remoteName or remote.Name
        local rateLimit = normalizeRateLimit(config.rateLimit)
        local validator = config.validator

        if remote:IsA("RemoteEvent") then
                return remote.OnServerEvent:Connect(function(player: Player, ...)
                        if not isValidPlayer(player) then
                                logDenial(remoteName, player, "InvalidPlayer")
                                return
                        end

                        if isThrottled(remote, player, rateLimit) then
                                logDenial(remoteName, player, "RateLimit")
                                return
                        end

                        local rawArgs = table.pack(...)
                        local sanitized = if rawArgs.n > 0 then rawArgs[1] else nil

                        if validator then
                                local ok, value, detail = runValidator(remote, validator, player, rawArgs)
                                if not ok then
                                        logDenial(remoteName, player, value, detail)
                                        return
                                end
                                if value ~= nil then
                                        sanitized = value
                                end
                        end

                        if handler then
                                local success, err = pcall(handler, player, sanitized)
                                if not success then
                                        warn(string.format("[Guard] Handler error for %s: %s", remoteName, tostring(err)))
                                end
                        end
                end)
        end

        remote.OnServerInvoke = function(player: Player, ...)
                if not isValidPlayer(player) then
                        logDenial(remoteName, player, "InvalidPlayer")
                        return makeRejectResponse(config, "InvalidPlayer")
                end

                if isThrottled(remote, player, rateLimit) then
                        logDenial(remoteName, player, "RateLimit")
                        return makeRejectResponse(config, "RateLimit")
                end

                local rawArgs = table.pack(...)
                local sanitized = if rawArgs.n > 0 then rawArgs[1] else nil

                if validator then
                        local ok, value, detail = runValidator(remote, validator, player, rawArgs)
                        if not ok then
                                logDenial(remoteName, player, value, detail)
                                return makeRejectResponse(config, value)
                        end
                        if value ~= nil then
                                sanitized = value
                        end
                end

                if not handler then
                        return makeRejectResponse(config, "NoHandler")
                end

                local success, result = pcall(handler, player, sanitized)
                if not success then
                        warn(string.format("[Guard] Handler error for %s: %s", remoteName, tostring(result)))
                        return makeRejectResponse(config, "HandlerError")
                end

                return result
        end

        return remote.OnServerInvoke
end

Players.PlayerRemoving:Connect(function(player)
        for _, remoteBuckets in pairs(rateState) do
                remoteBuckets[player] = nil
        end
end)

return Guard
