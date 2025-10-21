-- DebugServer.server.lua
-- Dev-only debug utilities wired via bindable events when GameConfig.Debug.Enabled is true.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local function safeRequire(instance, name)
	if not instance then
		warn(string.format("[DebugServer] %s module missing", name))
		return nil
	end

	local ok, result = pcall(require, instance)
	if not ok then
		warn(string.format("[DebugServer] Failed to require %s: %s", name, result))
		return nil
	end

	return result
end

local function safeWaitForChild(parent, childName)
	local ok, result = pcall(function()
		return parent:WaitForChild(childName)
	end)

	if ok then
		return result
	end

	return nil
end

local sharedFolder = safeWaitForChild(ReplicatedStorage, "Shared")
local configFolder = sharedFolder and sharedFolder:FindFirstChild("Config")
local gameConfigModule = configFolder and configFolder:FindFirstChild("GameConfig")

local gameConfig
if gameConfigModule then
	local ok, result = pcall(require, gameConfigModule)
	if ok then
		gameConfig = typeof(result.Get) == "function" and result.Get() or result
	else
		warn(string.format("[DebugServer] Failed to load GameConfig: %s", result))
	end
else
	warn("[DebugServer] GameConfig module missing")
end

if not gameConfig then
	return
end

local debugConfig = gameConfig.Debug
if not (debugConfig and debugConfig.Enabled) then
	return
end

local gameServerFolder = script.Parent
local debugFolder = gameServerFolder:FindFirstChild("Debug")
if not debugFolder then
	debugFolder = Instance.new("Folder")
	debugFolder.Name = "Debug"
	debugFolder.Parent = gameServerFolder
end

local function ensureEvent(name)
	local event = debugFolder:FindFirstChild(name)
	if not event then
		event = Instance.new("BindableEvent")
		event.Name = name
		event.Parent = debugFolder
	end

	return event
end

local economyFolder = gameServerFolder:FindFirstChild("Economy")
local economyModule = economyFolder and economyFolder:FindFirstChild("EconomyServer")
local EconomyServer = safeRequire(economyModule, "EconomyServer")

local FruitSpawnerServer = safeRequire(gameServerFolder:FindFirstChild("FruitSpawnerServer"), "FruitSpawnerServer")
local RoundDirectorServer = safeRequire(gameServerFolder:FindFirstChild("RoundDirectorServer"), "RoundDirectorServer")
local ArenaServer = safeRequire(gameServerFolder:FindFirstChild("ArenaServer"), "ArenaServer")

local fruitConfigModule = configFolder and configFolder:FindFirstChild("FruitConfig")
local FruitConfig
if fruitConfigModule then
	local ok, result = pcall(require, fruitConfigModule)
	if ok then
		FruitConfig = result
	else
		warn(string.format("[DebugServer] Failed to load FruitConfig: %s", result))
	end
else
	warn("[DebugServer] FruitConfig module missing")
end

local economyConfig = (gameConfig and gameConfig.Economy) or {}
local coinOverride = economyConfig.CoinsPerFruitOverride

local fruitDenominations = {}
if FruitConfig and typeof(FruitConfig.All) == "function" then
	local roster = FruitConfig.All()
	if type(roster) == "table" then
		for id, data in pairs(roster) do
			local coinValue = coinOverride
			if coinValue == nil then
				coinValue = type(data) == "table" and data.Coins or nil
			end

			if type(coinValue) == "number" and coinValue > 0 then
				local fruitId = data.Id or id
				table.insert(fruitDenominations, {
					id = fruitId,
					coins = coinValue,
				})
			end
		end
	end
end

table.sort(fruitDenominations, function(a, b)
	return a.coins > b.coins
end)

local giveCoinsEvent = ensureEvent("GiveCoins")
local spawnFruitEvent = ensureEvent("SpawnFruit")
local fastPrepEvent = ensureEvent("FastPrep")

local function awardCoins(player, amount)
	if not EconomyServer or type(EconomyServer.AwardFruit) ~= "function" then
		warn("[DebugServer] EconomyServer.AwardFruit unavailable")
		return
	end

	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		warn("[DebugServer] GiveCoins expects a Player instance")
		return
	end

	local numericAmount = tonumber(amount)
	if not numericAmount then
		warn("[DebugServer] GiveCoins amount must be a number")
		return
	end

	numericAmount = math.floor(numericAmount)
	if numericAmount <= 0 then
		return
	end

	if #fruitDenominations == 0 then
		warn("[DebugServer] No fruit coin denominations available")
		return
	end

	local remaining = numericAmount
	local totalAwarded = 0

	for _, entry in ipairs(fruitDenominations) do
		if remaining <= 0 then
			break
		end

		local coinsPerFruit = math.max(entry.coins, 1)
		while remaining >= coinsPerFruit do
			local ok, coinsDelta = pcall(EconomyServer.AwardFruit, player, entry.id)
			if not ok then
				warn(string.format("[DebugServer] AwardFruit failed for %s: %s", entry.id, coinsDelta))
				break
			end

			coinsDelta = coinsDelta or 0
			if coinsDelta <= 0 then
				warn(string.format("[DebugServer] AwardFruit returned %d coins for %s", coinsDelta, entry.id))
				break
			end

			remaining -= coinsDelta
			totalAwarded += coinsDelta

			if remaining < coinsPerFruit then
				break
			end
		end
	end

	if remaining > 0 then
		warn(string.format(
			"[DebugServer] Unable to grant full amount. Remaining: %d coins (awarded %d)",
			remaining,
			totalAwarded
			))
	end
end

giveCoinsEvent.Event:Connect(awardCoins)

local function spawnFruit(arenaId, laneId, fruitId)
	if not FruitSpawnerServer or type(FruitSpawnerServer.SpawnFruit) ~= "function" then
		warn("[DebugServer] FruitSpawnerServer.SpawnFruit unavailable")
		return
	end

	local ok, result = pcall(FruitSpawnerServer.SpawnFruit, arenaId, laneId, fruitId)
	if not ok then
		warn(string.format("[DebugServer] SpawnFruit failed: %s", result))
	end
end

spawnFruitEvent.Event:Connect(spawnFruit)

local function fireSignal(signal)
	if not signal then
		return false
	end

	local signalType = typeof(signal)
	if signalType == "Instance" then
		if signal:IsA("BindableEvent") then
			signal:Fire()
			return true
		elseif signal:IsA("BindableFunction") then
			signal:Invoke()
			return true
		end
	elseif signalType == "table" then
		if type(signal.Fire) == "function" then
			signal:Fire()
			return true
		elseif type(signal.Invoke) == "function" then
			signal:Invoke()
			return true
		elseif type(signal.Trigger) == "function" then
			signal:Trigger()
			return true
		end
	elseif signalType == "function" then
		signal()
		return true
	end

	return false
end

local function gatherArenaIds()
	local arenaIds = {}
	local seen = {}

	if ArenaServer and type(ArenaServer.GetAllArenas) == "function" then
		local ok, arenas = pcall(ArenaServer.GetAllArenas)
		if ok and type(arenas) == "table" then
			for arenaId in pairs(arenas) do
				if arenaId and not seen[arenaId] then
					table.insert(arenaIds, arenaId)
					seen[arenaId] = true
				end
			end
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		local arenaId = player:GetAttribute("ArenaId")
		if arenaId and not seen[arenaId] then
			table.insert(arenaIds, arenaId)
			seen[arenaId] = true
		end
	end

	return arenaIds
end

local function triggerFastPrep()
	if not RoundDirectorServer or type(RoundDirectorServer.GetState) ~= "function" then
		warn("[DebugServer] RoundDirectorServer.GetState unavailable")
		return
	end

	local arenaIds = gatherArenaIds()
	if #arenaIds == 0 then
		warn("[DebugServer] FastPrep: no arenas found")
		return
	end

	local triggered = false

	for _, arenaId in ipairs(arenaIds) do
		local state = RoundDirectorServer.GetState(arenaId)
		if state then
			local candidates = {}
			if state.options and state.options.FloorButtonSignal then
				table.insert(candidates, state.options.FloorButtonSignal)
			end

			local dependencies = state.dependencies or {}
			local arenaServerDep = dependencies.ArenaServer
			if arenaServerDep and type(arenaServerDep.GetFloorButtonSignal) == "function" then
				local ok, signal = pcall(arenaServerDep.GetFloorButtonSignal, arenaServerDep, arenaId)
				if ok and signal then
					table.insert(candidates, signal)
				end
			end

			if ArenaServer and type(ArenaServer.GetFloorButtonSignal) == "function" then
				local ok, signal = pcall(ArenaServer.GetFloorButtonSignal, arenaId)
				if ok and signal then
					table.insert(candidates, signal)
				end
			end

			for _, candidate in ipairs(candidates) do
				if fireSignal(candidate) then
					triggered = true
					break
				end
			end
		end
	end

	if not triggered then
		warn("[DebugServer] FastPrep did not find a triggerable signal")
	end
end

fastPrepEvent.Event:Connect(triggerFastPrep)
