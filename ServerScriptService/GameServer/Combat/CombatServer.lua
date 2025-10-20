--!strict
--[=[
    CombatServer
    -------------
    Handles server-side validation for melee hit attempts fired by clients.
    Ensures remote throttling, distance checks, fruit health tracking and
    coin/point rewards when a fruit is destroyed.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))
local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("FruitConfig"))
local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))

local CombatServer = {}

local GameConfig = GameConfigModule.Get()

type PlayerState = { lastSwing: number }
type FruitState = { currentHP: number, maxHP: number }
type FruitStats = { [string]: any }

local MAX_MELEE_DISTANCE = 18
local HIT_POSITION_TOLERANCE = 6
local SWING_COOLDOWN_SECONDS = 0.35
local DEFAULT_FRUIT_HP = 20
local DEFAULT_DURABILITY_POOL = 100
local COIN_REASON = "FruitSmash"




local playerStates: { [Player]: PlayerState } = {}
setmetatable(playerStates, { __mode = "k" })

local fruitStates: { [BasePart]: FruitState } = {}
setmetatable(fruitStates, { __mode = "k" })

local dependencies = {
	EconomyServer = nil :: any?,
}

-- safer require that won't throw in strict; returns any? (optional)
local function safeRequire(instance: Instance?): any?
	if not instance then
		return nil
	end

	local ok, result = pcall(require, instance)
	if not ok then
		warn(string.format("[CombatServer] Failed to require %s: %s", instance:GetFullName(), tostring(result)))
		return nil
	end

	return result
end

-- Resolve EconomyServer module (keeps current search approach)
local function resolveEconomy(): any?
	if dependencies.EconomyServer ~= nil then
		return dependencies.EconomyServer
	end

	local gameServerFolder = script.Parent and script.Parent.Parent
	local economyFolder = gameServerFolder and gameServerFolder.Parent and gameServerFolder.Parent:FindFirstChild("Economy")
	local moduleInstance = economyFolder and economyFolder:FindFirstChild("EconomyServer")

	dependencies.EconomyServer = safeRequire(moduleInstance)
	return dependencies.EconomyServer
end

-- Return a definite PlayerState (strict-safe)
local function getPlayerState(player: Player): PlayerState
	local state: PlayerState? = playerStates[player]
	if state then
		return state
	end

	local newState: PlayerState = { lastSwing = -math.huge }
	playerStates[player] = newState
	return newState
end

local function cleanupFruitState(fruit: BasePart)
	fruitStates[fruit] = nil
end

local function resolveFruitPart(candidate: any): BasePart?
	if typeof(candidate) == "Instance" then
		if candidate:IsA("BasePart") then
			return candidate
		end

		if candidate:IsA("Model") then
			local primary = candidate.PrimaryPart or candidate:FindFirstChildWhichIsA("BasePart")
			if primary then
				return primary
			end
		end
	end

	return nil
end

local function determineFruitStats(fruit: BasePart): FruitStats?
	local fruitId = fruit:GetAttribute("FruitId")
	if not fruitId and fruit.Name ~= "" then
		fruitId = fruit.Name
	end

	local stats: FruitStats? = nil
	if typeof(fruitId) == "string" then
		stats = FruitConfig.Get(fruitId)
	end

	return stats
end

local function computeFruitMaxHP(fruit: BasePart, stats: FruitStats?): number
	local hpByClass = FruitConfig.HPByClass or {}
	local hpClass = fruit:GetAttribute("HPClass")

	if hpClass and hpByClass[hpClass] then
		return hpByClass[hpClass]
	end

	if stats and typeof(stats) == "table" then
		local hp = stats.HP or stats.MaxHP
		if typeof(hp) == "number" then
			return math.max(1, math.floor(hp + 0.5))
		end
	end

	return DEFAULT_FRUIT_HP
end

-- Return a definite FruitState (strict-safe)
local function ensureFruitState(fruit: BasePart, stats: FruitStats?): FruitState
	local existing: FruitState? = fruitStates[fruit]
	if existing then
		return existing
	end

	local maxHP = computeFruitMaxHP(fruit, stats)
	local newState: FruitState = { currentHP = maxHP, maxHP = maxHP }
	fruitStates[fruit] = newState

	fruit.AncestryChanged:Connect(function(instance: Instance, parent: Instance?)
		if parent == nil and instance == fruit then
			cleanupFruitState(fruit)
		end
	end)

	return newState
end

local function resolveArenaOwnershipValid(fruit: BasePart, player: Player): boolean
	local ancestor: Instance? = fruit.Parent
	while ancestor do
		if ancestor:IsA("Model") then
			local arenaId = (ancestor :: Instance):GetAttribute("ArenaId")
			if arenaId then
				local playerArenaId = player:GetAttribute("ArenaId")
				if playerArenaId and playerArenaId ~= arenaId then
					return false
				end
				return true
			end
		end
		ancestor = ancestor.Parent
	end

	return true
end

local function resolveMeleeDamage(player: Player): number
	local damageAttr = player:GetAttribute("MeleeDamage")
	if typeof(damageAttr) == "number" then
		return math.max(0, damageAttr)
	end

	local meleeConfig = GameConfig.Melee or {}
	local baseDamage = meleeConfig.BaseDamage or 25
	return math.max(0, baseDamage)
end

local function resolveWearAmount(fruit: BasePart, stats: FruitStats?): number
	local wearAttr = fruit:GetAttribute("Wear")
	if typeof(wearAttr) == "number" then
		return math.max(0, wearAttr)
	end

	if stats and typeof(stats) == "table" and typeof(stats.Wear) == "number" then
		return math.max(0, stats.Wear)
	end

	return 1
end

local function computeReward(fruit: BasePart, stats: FruitStats?)
	local economyConfig = GameConfig.Economy or {}
	local coinsOverride = economyConfig.CoinsPerFruitOverride
	local pointsOverride = economyConfig.PointsPerFruitOverride

	local coins: number
	local points: number

	if typeof(coinsOverride) == "number" then
		coins = coinsOverride
	else
		local coinsAttr = fruit:GetAttribute("Coins")
		if typeof(coinsAttr) == "number" then
			coins = coinsAttr
		elseif stats and typeof(stats.Coins) == "number" then
			coins = stats.Coins
		else
			coins = 0
		end
	end

	if typeof(pointsOverride) == "number" then
		points = pointsOverride
	else
		local pointsAttr = fruit:GetAttribute("Points")
		if typeof(pointsAttr) == "number" then
			points = pointsAttr
		elseif stats and typeof(stats.Points) == "number" then
			points = stats.Points
		else
			points = 0
		end
	end

	return math.max(0, coins), math.max(0, points)
end

local function notifyEconomy(player: Player, coins: number, points: number, stats: FruitStats?)
	if coins == 0 and points == 0 then
		return
	end

	local economy = resolveEconomy()
	if economy then
		local handler = economy.AwardFruitSmash or economy.GrantFruitReward or economy.AwardFruitReward
		if typeof(handler) == "function" then
			local ok, err = pcall(handler, economy, player, coins, points, stats)
			if not ok then
				warn(string.format("[CombatServer] Economy reward failed: %s", tostring(err)))
			end
		end
	end

	local coinRemote = Remotes.RE_CoinPointDelta
	if coinRemote then
		coinRemote:FireClient(player, {
			coins = coins,
			points = points,
			reason = COIN_REASON,
		})
	end
end

local function applyDurabilityWear(player: Player, amount: number, stats: FruitStats?)
	if amount <= 0 then
		return
	end

	local economy = resolveEconomy()
	if economy and typeof(economy.ApplyMeleeDurabilityWear) == "function" then
		local ok, err = pcall(economy.ApplyMeleeDurabilityWear, economy, player, amount, stats)
		if ok then
			return
		end
		warn(string.format("[CombatServer] ApplyMeleeDurabilityWear failed: %s", tostring(err)))
	end

	local durabilityAttr = player:GetAttribute("MeleeDurability")
	local currentDurability: number

	if typeof(durabilityAttr) == "number" then
		currentDurability = durabilityAttr
	else
		local maxAttr = player:GetAttribute("MeleeMaxDurability")
		if typeof(maxAttr) == "number" then
			currentDurability = maxAttr
		else
			currentDurability = DEFAULT_DURABILITY_POOL
		end
	end

	local nextDurability = math.max(0, currentDurability - amount)
	player:SetAttribute("MeleeDurability", nextDurability)
end

local function destroyFruitInstance(fruit: BasePart)
	if not fruit or not fruit:IsDescendantOf(Workspace) then
		return
	end

	local parentModel = fruit.Parent
	fruit:Destroy()

	if parentModel and parentModel:IsA("Model") and parentModel.Parent ~= nil then
		if #parentModel:GetChildren() == 0 then
			parentModel:Destroy()
		end
	end
end

local function processValidHit(player: Player, fruit: BasePart)
	local stats = determineFruitStats(fruit)
	local fruitState = ensureFruitState(fruit, stats)

	local damage = resolveMeleeDamage(player)
	if damage <= 0 then
		return
	end

	fruitState.currentHP = math.max(0, fruitState.currentHP - damage)

	local wear = resolveWearAmount(fruit, stats)
	applyDurabilityWear(player, wear, stats)

	if fruitState.currentHP <= 0 then
		local coins, points = computeReward(fruit, stats)
		notifyEconomy(player, coins, points, stats)
		cleanupFruitState(fruit)
		destroyFruitInstance(fruit)
	end
end

local function validateSwing(player: Player, payload: any)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if typeof(payload) ~= "table" then
		return
	end

	local fruitCandidate = payload.fruit or payload.fruitId or payload[1]
	local hitPosition = payload.position or payload.pos or payload.hitPosition or payload[2]

	local fruitPart = resolveFruitPart(fruitCandidate)
	if not fruitPart then
		return
	end
	if not fruitPart:IsDescendantOf(Workspace) then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local now = os.clock()
	local state = getPlayerState(player)
	if now - state.lastSwing < SWING_COOLDOWN_SECONDS then
		return
	end

	if not resolveArenaOwnershipValid(fruitPart, player) then
		return
	end

	local fruitPosition = fruitPart.Position
	local rootPosition = rootPart.Position
	local distanceToFruit = (rootPosition - fruitPosition).Magnitude

	if distanceToFruit > MAX_MELEE_DISTANCE then
		if typeof(hitPosition) == "Vector3" then
			local rootToHit = (rootPosition - hitPosition).Magnitude
			local hitToFruit = (hitPosition - fruitPosition).Magnitude
			if rootToHit > MAX_MELEE_DISTANCE or hitToFruit > HIT_POSITION_TOLERANCE then
				return
			end
		else
			return
		end
	elseif typeof(hitPosition) == "Vector3" then
		local hitToFruit = (hitPosition - fruitPosition).Magnitude
		if hitToFruit > HIT_POSITION_TOLERANCE then
			return
		end
	end

	state.lastSwing = now
	processValidHit(player, fruitPart)
end

function CombatServer.Start()
	local remote = Remotes.RE_MeleeHitAttempt
	if not remote then
		warn("[CombatServer] RE_MeleeHitAttempt remote missing")
		return
	end

	remote.OnServerEvent:Connect(validateSwing)
end

function CombatServer.SetDependencies(overrides)
	for key, value in pairs(overrides or {}) do
		dependencies[key] = value
	end
end

Players.PlayerRemoving:Connect(function(player: Player)
	playerStates[player] = nil
end)

CombatServer.Start()

return CombatServer
