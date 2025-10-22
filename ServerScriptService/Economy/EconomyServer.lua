--!strict
-- EconomyServer.lua
-- Centralizes coin/point grants for fruit hits and round bonuses.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("FruitConfig"))
local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local RemotesModule = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))

local submitLeaderboardScore: ((Player, number) -> ())? = nil

do
        local dataFolder = ServerScriptService:FindFirstChild("Data")
        local leaderboardModule = dataFolder and dataFolder:FindFirstChild("LeaderboardServer")
        if leaderboardModule and leaderboardModule:IsA("ModuleScript") then
                local ok, moduleResult = pcall(require, leaderboardModule)
                if ok and typeof(moduleResult) == "table" then
                        local submitFn = (moduleResult :: any).SubmitScore
                        if typeof(submitFn) == "function" then
                                submitLeaderboardScore = function(player: Player, points: number)
                                        local success, err = pcall(submitFn, player, points)
                                        if not success then
                                                warn(string.format("[EconomyServer] Leaderboard SubmitScore failed: %s", tostring(err)))
                                        end
                                end
                        end
                else
                        warn(string.format("[EconomyServer] Failed to require LeaderboardServer: %s", tostring(moduleResult)))
                end
        end
end

local GameConfig = typeof(GameConfigModule.Get) == "function" and GameConfigModule.Get() or GameConfigModule
local EconomyConfig = GameConfig.Economy or {}

local coinPointRemote: RemoteEvent? = RemotesModule and RemotesModule.RE_CoinPointDelta or nil

export type Totals = { coins: number, points: number }
export type AwardSummary = {
        coinsDelta: number,
        pointsDelta: number,
        totals: Totals,
        metadata: { [string]: any }?,
}

type Wallet = { coins: number, points: number }

type BonusConfig = { Base: number?, PerLevel: number?, PointsBase: number?, PointsPerLevel: number?, Points: number? }

type Metadata = { [string]: any }

type MultiplierEntry = { value: number, expiresAt: number?, token: any, attributeName: string? }

local wallets: { [Player]: Wallet } = setmetatable({}, { __mode = "k" })
local multipliers: { [Player]: { [string]: MultiplierEntry } } = setmetatable({}, { __mode = "k" })

local multiplierAttributeMap: { [string]: string } = {
        coins = "CoinRewardMultiplier",
}

local function normalizeStatName(stat: any): string?
        if typeof(stat) ~= "string" then
                return nil
        end

        local lowered = string.lower(stat)
        if lowered == "coin" then
                lowered = "coins"
        end

        if multiplierAttributeMap[lowered] ~= nil then
                return lowered
        end

        if lowered == "coins" then
                return lowered
        end

        return nil
end

local EconomyServer = {}

local function toInteger(value: any): number?
        local numeric = tonumber(value)
        if numeric == nil then
                return nil
        end

        if numeric >= 0 then
                return math.floor(numeric + 0.5)
        end

        return -math.floor(-numeric + 0.5)
end

local function resolveNonNegative(value: any, fallback: any?): number
        local numeric = toInteger(value)
        if numeric == nil then
                numeric = toInteger(fallback)
        end
        if numeric == nil then
                return 0
        end
        if numeric < 0 then
                return 0
        end
        return numeric
end

local function ensureWallet(player: Player): Wallet
        local wallet = wallets[player]
        local coinsAttr = toInteger(player:GetAttribute("Coins"))
        local pointsAttr = toInteger(player:GetAttribute("Points"))

        if wallet then
                if coinsAttr ~= nil then
                        wallet.coins = math.max(0, coinsAttr)
                end
                if pointsAttr ~= nil then
                        wallet.points = math.max(0, pointsAttr)
                end
                return wallet
        end

        wallet = {
                coins = math.max(0, coinsAttr or 0),
                points = math.max(0, pointsAttr or 0),
        }

        wallets[player] = wallet
        return wallet
end

local function cleanupMultiplierState(player: Player, state: { [string]: MultiplierEntry }?)
        if not state then
                return
        end

        if next(state) == nil then
                multipliers[player] = nil
        end
end

local function clearMultiplier(player: Player, stat: string, stateOverride: { [string]: MultiplierEntry }?, entryOverride: MultiplierEntry?)
        local state = stateOverride or multipliers[player]
        if not state then
                return
        end

        local entry = entryOverride or state[stat]
        if not entry then
                cleanupMultiplierState(player, state)
                return
        end

        local attrName = entry.attributeName or multiplierAttributeMap[stat]
        if attrName then
                local attr = player:GetAttribute(attrName)
                if attr ~= nil then
                        if typeof(attr) ~= "number" or entry.value == nil then
                                player:SetAttribute(attrName, nil)
                        elseif math.abs((attr :: number) - entry.value) < 1e-3 then
                                player:SetAttribute(attrName, nil)
                        end
                end
        end

        state[stat] = nil
        cleanupMultiplierState(player, state)
end

local function resolveMultiplier(player: Player, stat: string): number
        local state = multipliers[player]
        if not state then
                return 1
        end

        local entry = state[stat]
        if not entry then
                cleanupMultiplierState(player, state)
                return 1
        end

        local expiresAt = entry.expiresAt
        if expiresAt ~= nil and expiresAt <= os.clock() then
                clearMultiplier(player, stat, state, entry)
                return 1
        end

        local numeric = tonumber(entry.value)
        if numeric == nil or numeric <= 0 then
                clearMultiplier(player, stat, state, entry)
                return 1
        end

        return numeric
end

local function updateAttributes(player: Player, wallet: Wallet)
        if not player or player.Parent == nil then
                return
        end

        player:SetAttribute("Coins", wallet.coins)
        player:SetAttribute("Points", wallet.points)

        if submitLeaderboardScore then
                submitLeaderboardScore(player, wallet.points)
        end
end

local function formatLog(player: Player, coinsDelta: number, pointsDelta: number, wallet: Wallet, metadata: Metadata?)
        local pieces = {
                string.format("player=%s", player.Name),
                string.format("coinsDelta=%d", coinsDelta),
                string.format("pointsDelta=%d", pointsDelta),
                string.format("totalCoins=%d", wallet.coins),
                string.format("totalPoints=%d", wallet.points),
        }

        if metadata then
                local reason = metadata.reason or metadata.Reason
                if reason then
                        table.insert(pieces, string.format("reason=%s", tostring(reason)))
                end
        end

        return string.format("{ %s }", table.concat(pieces, ", "))
end

local function applyDelta(player: Player, coinsDeltaRaw: any, pointsDeltaRaw: any, metadata: Metadata?): AwardSummary?
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return nil
        end

        local coinsDelta = toInteger(coinsDeltaRaw) or 0
        local pointsDelta = toInteger(pointsDeltaRaw) or 0

        if coinsDelta == 0 and pointsDelta == 0 then
                return nil
        end

        if coinsDelta > 0 then
                local multiplier = resolveMultiplier(player, "coins")
                if multiplier > 0 and math.abs(multiplier - 1) > 1e-3 then
                        local scaled = toInteger(coinsDelta * multiplier)
                        if scaled and scaled > 0 then
                                coinsDelta = scaled
                        end
                end
        end

        local wallet = ensureWallet(player)
        wallet.coins = math.max(0, wallet.coins + coinsDelta)
        wallet.points = math.max(0, wallet.points + pointsDelta)

        updateAttributes(player, wallet)

        if coinPointRemote then
                coinPointRemote:FireClient(player, {
                        coins = coinsDelta,
                        points = pointsDelta,
                        totalCoins = wallet.coins,
                        totalPoints = wallet.points,
                        metadata = metadata,
                })
        end

        local summary: AwardSummary = {
                coinsDelta = coinsDelta,
                pointsDelta = pointsDelta,
                totals = {
                        coins = wallet.coins,
                        points = wallet.points,
                },
                metadata = metadata,
        }

        print(string.format("[EconomyServer] %s", formatLog(player, coinsDelta, pointsDelta, wallet, metadata)))

        return summary
end

local function computeBonus(config: BonusConfig?, level: number): (number, number)
        if type(config) ~= "table" then
                return 0, 0
        end

        local baseCoins = resolveNonNegative(config.Base, 0)
        local perLevelCoins = resolveNonNegative(config.PerLevel, 0)
        local safeLevel = math.max(0, math.floor(level or 0))

        local coins = baseCoins + perLevelCoins * safeLevel

        local basePoints = resolveNonNegative(config.PointsBase, config.Points)
        local perLevelPoints = resolveNonNegative(config.PointsPerLevel, 0)
        local points = basePoints + perLevelPoints * safeLevel

        return coins, points
end

local function grantBonus(players: { Player }?, level: number, config: BonusConfig?, metadata: Metadata)
        local coins, points = computeBonus(config, level)
        if coins == 0 and points == 0 then
                return {}
        end

        local awarded: { [Player]: AwardSummary } = {}
        if type(players) ~= "table" then
                return awarded
        end

        for _, player in ipairs(players) do
                if typeof(player) == "Instance" and player:IsA("Player") then
                        local summary = applyDelta(player, coins, points, metadata)
                        if summary then
                                awarded[player] = summary
                        end
                end
        end

        return awarded
end

local function resolveFruitStats(fruitId: string)
        if typeof(FruitConfig.Get) == "function" then
                local stats = FruitConfig.Get(fruitId)
                if stats then
                        return stats
                end
        end

        if typeof(FruitConfig.All) == "function" then
                local roster = FruitConfig.All()
                if type(roster) == "table" then
                        local entry = roster[fruitId]
                        if entry then
                                return entry
                        end
                end
        end

        local roster = (FruitConfig.Roster :: any)
        if type(roster) == "table" then
                return roster[fruitId]
        end

        return nil
end

function EconomyServer.SetMultiplier(player: Player, stat: string, value: any, durationSec: any?): boolean
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return false
        end

        local normalized = normalizeStatName(stat)
        if not normalized then
                return false
        end

        local numericValue = tonumber(value)
        if numericValue == nil or numericValue <= 0 then
                clearMultiplier(player, normalized)
                return true
        end

        local duration = tonumber(durationSec)
        if duration ~= nil and duration <= 0 then
                duration = nil
        end

        local state = multipliers[player]
        if not state then
                state = {}
                multipliers[player] = state
        end

        local entry: MultiplierEntry = {
                value = numericValue,
                expiresAt = duration and (os.clock() + duration) or nil,
                token = {},
                attributeName = multiplierAttributeMap[normalized],
        }

        local attrName = entry.attributeName
        if attrName then
                player:SetAttribute(attrName, numericValue)
        end

        state[normalized] = entry

        if duration then
                local token = entry.token
                task.delay(duration, function()
                        local currentState = multipliers[player]
                        local currentEntry = currentState and currentState[normalized]
                        if currentEntry ~= entry or currentEntry.token ~= token then
                                return
                        end

                        clearMultiplier(player, normalized, currentState, currentEntry)
                end)
        end

        return true
end

function EconomyServer.GrantFruit(player: Player, fruitId: string): AwardSummary?
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return nil
        end

        if typeof(fruitId) ~= "string" or fruitId == "" then
                warn(string.format("[EconomyServer] Invalid fruit id '%s'", tostring(fruitId)))
                return nil
        end

        local stats = resolveFruitStats(fruitId)
        if type(stats) ~= "table" then
                warn(string.format("[EconomyServer] Unknown fruit '%s'", fruitId))
                return nil
        end

        local coinsOverride = EconomyConfig.CoinsPerFruitOverride
        local pointsOverride = EconomyConfig.PointsPerFruitOverride

        local coins = resolveNonNegative(coinsOverride, stats.Coins)
        local points = resolveNonNegative(pointsOverride, stats.Points)

        if coins == 0 and points == 0 then
                return nil
        end

        return applyDelta(player, coins, points, {
                reason = "Fruit",
                fruitId = fruitId,
        })
end

function EconomyServer.GrantWaveClear(players: { Player }?, level: number): { [Player]: AwardSummary }
        return grantBonus(players, level, EconomyConfig.WaveClearBonus, {
                reason = "WaveClear",
                level = level,
        })
end

function EconomyServer.GrantLevelClear(players: { Player }?, level: number): { [Player]: AwardSummary }
        return grantBonus(players, level, EconomyConfig.LevelClearBonus, {
                reason = "LevelClear",
                level = level,
        })
end

function EconomyServer.Totals(player: Player): Totals
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return { coins = 0, points = 0 }
        end

        local wallet = ensureWallet(player)
        updateAttributes(player, wallet)

        return {
                coins = wallet.coins,
                points = wallet.points,
        }
end

local function hydratePlayer(player: Player)
        local wallet = ensureWallet(player)
        updateAttributes(player, wallet)
end

for _, player in ipairs(Players:GetPlayers()) do
        hydratePlayer(player)
end

Players.PlayerAdded:Connect(hydratePlayer)
Players.PlayerRemoving:Connect(function(player)
        wallets[player] = nil
        local state = multipliers[player]
        if state then
                local stats = {}
                for statName in pairs(state) do
                        table.insert(stats, statName)
                end
                for _, statName in ipairs(stats) do
                        clearMultiplier(player, statName, state)
                end
        end
end)

return EconomyServer
