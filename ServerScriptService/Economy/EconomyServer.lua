--!strict
-- EconomyServer.lua
-- Centralizes coin/point grants for fruit hits and round bonuses.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("FruitConfig"))
local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local RemotesModule = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))

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

local wallets: { [Player]: Wallet } = setmetatable({}, { __mode = "k" })

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

local function updateAttributes(player: Player, wallet: Wallet)
        if not player or player.Parent == nil then
                return
        end

        player:SetAttribute("Coins", wallet.coins)
        player:SetAttribute("Points", wallet.points)
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
end)

return EconomyServer
