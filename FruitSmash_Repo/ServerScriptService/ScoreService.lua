-- ScoreService: server-side scoring with leaderstats + ScoreUpdated + CoinsUpdated + CoinBoost support
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

-- === Ensure Remotes ===
local Remotes = RS:FindFirstChild("Remotes") or Instance.new("Folder")
Remotes.Name = "Remotes"
Remotes.Parent = RS

local ScoreUpdated = Remotes:FindFirstChild("ScoreUpdated") or Instance.new("RemoteEvent")
ScoreUpdated.Name = "ScoreUpdated"
ScoreUpdated.Parent = Remotes

local CoinsUpdated = Remotes:FindFirstChild("CoinsUpdated") or Instance.new("RemoteEvent")
CoinsUpdated.Name = "CoinsUpdated"
CoinsUpdated.Parent = Remotes

local ScoreDelta = Remotes:FindFirstChild("ScoreDelta")
if not ScoreDelta then
	ScoreDelta = Instance.new("BindableEvent")
	ScoreDelta.Name = "ScoreDelta"
	ScoreDelta.Parent = Remotes
end

-- === Global CoinBoost flag (set by PowerupDropService / PowerupEffects) ===
local CoinBoostFlag = RS:FindFirstChild("DoubleCoinsActive")
if not CoinBoostFlag then
	CoinBoostFlag = Instance.new("BoolValue")
	CoinBoostFlag.Name = "DoubleCoinsActive"
	CoinBoostFlag.Value = false
	CoinBoostFlag.Parent = RS
end

local ScoreService = {}

-- === Utility: ensure leaderstats ===
local function ensureLeaderstats(plr: Player): (IntValue, IntValue)
	local ls = plr:FindFirstChild("leaderstats")
	if not ls then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = plr
	end

	local score = ls:FindFirstChild("Score") :: IntValue?
	if not score then
		score = Instance.new("IntValue")
		score.Name = "Score"
		score.Value = 0
		score.Parent = ls
	end

	local coins = ls:FindFirstChild("Coins") :: IntValue?
	if not coins then
		coins = Instance.new("IntValue")
		coins.Name = "Coins"
		coins.Value = 0
		coins.Parent = ls
	end

	return score :: IntValue, coins :: IntValue
end

-- === Player Init ===
function ScoreService.InitPlayer(plr: Player)
	ensureLeaderstats(plr)
	-- Persistent attribute for per-player boosts
	if plr:GetAttribute("CoinsMultiplier") == nil then
		plr:SetAttribute("CoinsMultiplier", 1)
	end
end

-- === Reset ===
function ScoreService.ResetScore(plr: Player)
	local score, coins = ensureLeaderstats(plr)
	score.Value = 0
	-- optional coins reset: coins.Value = 0

	ScoreUpdated:FireClient(plr, { Score = score.Value, Delta = 0, Reason = "Reset" })
	CoinsUpdated:FireClient(plr, { Coins = coins.Value, Delta = 0, Reason = "Reset" })
end

-- === AddPoints ===
function ScoreService.AddPoints(plr: Player, amount: number, reason: string?)
	if not plr or (amount or 0) == 0 then return end

	local score, coins = ensureLeaderstats(plr)
	score.Value += amount

	ScoreUpdated:FireClient(plr, {
		Score = score.Value,
		Delta = amount,
		Reason = reason or "Fruit"
	})

	-- 💰 Coin multiplier = player attr × global CoinBoost flag
	local baseMult = math.max(1, plr:GetAttribute("CoinsMultiplier") or 1)
	local globalMult = (CoinBoostFlag and CoinBoostFlag.Value) and 2 or 1
	local totalMult = baseMult * globalMult

	local coinDelta = math.floor(amount * totalMult + 0.5)
	coins.Value += coinDelta

	CoinsUpdated:FireClient(plr, {
		Coins = coins.Value,
		Delta = coinDelta,
		Reason = reason or "Fruit"
	})

	ScoreDelta:Fire({ player = plr, delta = amount, reason = reason })
end

-- === AddCoins ===
function ScoreService.AddCoins(plr: Player, amount: number, reason: string?)
	if not plr or (amount or 0) == 0 then return end

	local _, coins = ensureLeaderstats(plr)

	local baseMult = math.max(1, plr:GetAttribute("CoinsMultiplier") or 1)
	local globalMult = (CoinBoostFlag and CoinBoostFlag.Value) and 2 or 1
	local totalMult = baseMult * globalMult

	local coinDelta = math.floor(amount * totalMult + 0.5)
	coins.Value += coinDelta

	CoinsUpdated:FireClient(plr, {
		Coins = coins.Value,
		Delta = coinDelta,
		Reason = reason or "Award"
	})
end

-- === Getter ===
function ScoreService.GetScore(plr: Player): number
	local ls = plr:FindFirstChild("leaderstats")
	local score = ls and ls:FindFirstChild("Score")
	return score and score.Value or 0
end

return ScoreService
