local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))
local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("FruitConfig"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig")).Get()

local economyConfig = GameConfig.Economy or {}
local coinsPerFruitOverride = economyConfig.CoinsPerFruitOverride
local pointsPerFruitOverride = economyConfig.PointsPerFruitOverride
local waveBonusConfig = economyConfig.WaveClearBonus or {}
local levelBonusConfig = economyConfig.LevelClearBonus or {}

local wallets = setmetatable({}, { __mode = "k" })

local EconomyServer = {}

local cachedArenaServer

local function getArenaServer()
    if cachedArenaServer ~= nil then
        return cachedArenaServer
    end

    local gameServerFolder = script.Parent.Parent
    if not gameServerFolder then
        cachedArenaServer = false
        return nil
    end

    local arenaModule = gameServerFolder:FindFirstChild("ArenaServer")
    if not arenaModule then
        cachedArenaServer = false
        return nil
    end

    local ok, arenaServer = pcall(require, arenaModule)
    if not ok then
        warn(string.format("[EconomyServer] Failed to require ArenaServer: %s", arenaServer))
        cachedArenaServer = false
        return nil
    end

    cachedArenaServer = arenaServer
    return cachedArenaServer
end

local function getWallet(player)
    local wallet = wallets[player]
    if wallet then
        return wallet
    end

    wallet = { Coins = player:GetAttribute("Coins") or 0, Points = player:GetAttribute("Points") or 0 }
    wallets[player] = wallet

    return wallet
end

local function updatePlayerAttributes(player, wallet)
    if not player then
        return
    end

    player:SetAttribute("Coins", wallet.Coins)
    player:SetAttribute("Points", wallet.Points)
end

local function fireDelta(player, coinsDelta, pointsDelta, metadata)
    if not Remotes or not Remotes.RE_CoinPointDelta then
        return
    end

    local payload = {
        coins = coinsDelta,
        points = pointsDelta,
        totalCoins = (wallets[player] and wallets[player].Coins) or 0,
        totalPoints = (wallets[player] and wallets[player].Points) or 0,
        metadata = metadata or {},
    }

    Remotes.RE_CoinPointDelta:FireClient(player, payload)
end

local function applyDelta(player, coinsDelta, pointsDelta, metadata)
    if not player or not player.Parent then
        return 0, 0
    end

    coinsDelta = coinsDelta or 0
    pointsDelta = pointsDelta or 0

    if coinsDelta == 0 and pointsDelta == 0 then
        return 0, 0
    end

    if coinsDelta > 0 then
        local multiplierAttr = player and player:GetAttribute("CoinRewardMultiplier")
        if typeof(multiplierAttr) == "number" and multiplierAttr > 0 then
            coinsDelta *= multiplierAttr
            if coinsDelta > 0 then
                coinsDelta = math.floor(coinsDelta + 0.5)
            end
        end
    end

    local wallet = getWallet(player)
    wallet.Coins += coinsDelta
    wallet.Points += pointsDelta

    updatePlayerAttributes(player, wallet)
    fireDelta(player, coinsDelta, pointsDelta, metadata)

    return coinsDelta, pointsDelta
end

local function playersForArena(arenaId)
    if not arenaId then
        return {}
    end

    local arenaServer = getArenaServer()
    local partyId

    if arenaServer and type(arenaServer.GetArenaState) == "function" then
        local ok, state = pcall(arenaServer.GetArenaState, arenaId)
        if ok and state then
            partyId = state.partyId or state.PartyId
            if not partyId and state.instance then
                partyId = state.instance:GetAttribute("PartyId")
            end
        end
    end

    local recipients = {}
    for _, player in ipairs(Players:GetPlayers()) do
        local playerArena = player:GetAttribute("ArenaId")
        local playerParty = player:GetAttribute("PartyId")
        local matchesArena = playerArena and playerArena == arenaId
        local matchesParty = partyId and playerParty == partyId

        if matchesArena or matchesParty then
            table.insert(recipients, player)
        end
    end

    return recipients
end

function EconomyServer.AwardFruit(player, fruitId)
    if not player or not fruitId then
        return 0, 0
    end

    local fruitStats = FruitConfig.Get and FruitConfig.Get(fruitId)
    if not fruitStats then
        fruitStats = FruitConfig.All and FruitConfig.All()[fruitId]
    end

    if not fruitStats then
        warn(string.format("[EconomyServer] Unknown fruit '%s'", tostring(fruitId)))
        return 0, 0
    end

    local coins = coinsPerFruitOverride or fruitStats.Coins or 0
    local points = pointsPerFruitOverride or fruitStats.Points or 0

    return applyDelta(player, coins, points, {
        reason = "Fruit",
        fruitId = fruitId,
    })
end

local function awardToArena(arenaId, level, bonusConfig, reason)
    local levelValue = math.max(level or 0, 0)
    local base = bonusConfig.Base or 0
    local perLevel = bonusConfig.PerLevel or 0
    local coins = base + perLevel * levelValue

    local pointsBase = bonusConfig.PointsBase or bonusConfig.Points or 0
    local pointsPerLevel = bonusConfig.PointsPerLevel or 0
    local points = pointsBase + pointsPerLevel * levelValue

    if coins == 0 and points == 0 then
        return {}
    end

    local awarded = {}
    for _, player in ipairs(playersForArena(arenaId)) do
        local coinsDelta, pointsDelta = applyDelta(player, coins, points, {
            reason = reason,
            arenaId = arenaId,
            level = level,
        })
        awarded[player] = {
            coins = coinsDelta,
            points = pointsDelta,
        }
    end

    return awarded
end

function EconomyServer.AwardWave(arenaId, level)
    return awardToArena(arenaId, level, waveBonusConfig, "Wave")
end

function EconomyServer.AwardLevel(arenaId, level)
    return awardToArena(arenaId, level, levelBonusConfig, "Level")
end

function EconomyServer.GetWallet(player)
    if not player then
        return nil
    end

    local wallet = getWallet(player)
    return { Coins = wallet.Coins, Points = wallet.Points }
end

Players.PlayerRemoving:Connect(function(player)
    wallets[player] = nil
end)

Players.PlayerAdded:Connect(function(player)
    local wallet = getWallet(player)
    updatePlayerAttributes(player, wallet)
end)

return EconomyServer

