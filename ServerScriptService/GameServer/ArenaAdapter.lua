--!strict
local ArenaAdapter = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local arenaModule = ServerScriptService:WaitForChild("GameServer"):FindFirstChild("ArenaServer")
local ArenaServer = arenaModule and require(arenaModule)

local LaneConfig = GameConfig.Lanes or {}


local function copyArray<T>(array: { T }): { T }
	local result = {}
	for i, v in ipairs(array) do
		result[i] = v
	end
	return result
end

local function copyDictionary<K, V>(dict: { [K]: V }): { [K]: V }
	local result = {}
	for k, v in pairs(dict) do
		result[k] = v
	end
	return result
end

local function freezeTable<T>(t: T): T
	return table.freeze(t)
end

local function getArenaState(arenaId)
	if not ArenaServer or type(ArenaServer.GetArenaState) ~= "function" then
		return nil
	end

	local ok, state = pcall(ArenaServer.GetArenaState, arenaId)
	if ok then
		return state
	end

	return nil
end

function ArenaAdapter.GetLevel(arenaId)
	local state = getArenaState(arenaId)
	if state then
		if typeof(state.level) == "number" then
			return state.level
		end
		if typeof(state.Level) == "number" then
			return state.Level
		end
	end

	return 1
end

local function resolveLaneCountFromState(state)
	local arenaServerModule = script.Parent:FindFirstChild("ArenaServer")
	if not arenaServerModule then
		error("[ArenaAdapter] ArenaServer module is missing")
	end

	local ArenaServer = require(arenaServerModule)

	local function freezeTable(tbl)
		if table.freeze then
			table.freeze(tbl)
		end

		return tbl
	end

	local function copyDictionary(source)
		local result = {}

		for key, value in pairs(source) do
			result[key] = value
		end

		return result
	end

	local function copyArray(source)
		local result = {}

		for index, value in ipairs(source) do
			result[index] = value
		end

		return result
	end

	local function snapshotTable(value)
		if type(value) ~= "table" then
			return nil
		end

		local snapshot = copyDictionary(value)

		if type(snapshot.lanes) == "table" then
			snapshot.lanes = freezeTable(copyArray(snapshot.lanes))
		end

		if type(snapshot.targets) == "table" then
			snapshot.targets = freezeTable(copyDictionary(snapshot.targets))
		end

		if type(snapshot.players) == "table" then
			local players = {}

			for key, entry in pairs(snapshot.players) do
				players[key] = entry
			end

			snapshot.players = freezeTable(players)
		end

		return freezeTable(snapshot)
	end

	local function getArenaState(arenaId)
		if arenaId == nil then
			return nil
		end

		local getState = ArenaServer and ArenaServer.GetArenaState
		if type(getState) ~= "function" then
			return nil
		end

		local ok, state = pcall(getState, arenaId)
		if not ok then
			warn(string.format("[ArenaAdapter] Failed to fetch arena '%s': %s", tostring(arenaId), tostring(state)))
			return nil
		end

		if type(state) ~= "table" then
			return nil
		end

		return state
	end

	function ArenaAdapter.GetState(arenaId)
		local state = getArenaState(arenaId)
		if not state then
			return nil
		end

		return snapshotTable(state)
	end

	function ArenaAdapter.GetModel(arenaId)
		local state = getArenaState(arenaId)
		if not state then
			return nil
		end

		if typeof(state.activeLanes) == "number" then
			return state.activeLanes
		end

		if typeof(state.laneCount) == "number" then
			return state.laneCount
		end

		local lanes = state.lanes
		if typeof(lanes) == "table" then
			local count = 0
			for _, lane in pairs(lanes) do
				if lane ~= nil then
					count += 1
				end
			end
			if count > 0 then
				return count
			end
		end

		return nil
	end

	function ArenaAdapter.GetLaneCount(arenaId)
		local state = getArenaState(arenaId)
		local count = resolveLaneCountFromState(state)

		if typeof(count) ~= "number" then
			count = LaneConfig.StartCount or 0
		end

		return math.max(count, 0)
	end

	function ArenaAdapter.GetLaneIds(arenaId)
		local laneCount = ArenaAdapter.GetLaneCount(arenaId)
		local lanes = table.create(laneCount)

		for index = 1, laneCount do
			lanes[index] = index
		end

		return lanes
	end

	
	
	return state.instance or state.model or state.arena
end

function ArenaAdapter.GetLanes(arenaId)
	local state = getArenaState(arenaId)
	if not state then
		return nil
	end

	local lanes = state.lanes
	if type(lanes) ~= "table" then
		return nil
	end

	return freezeTable(copyArray(lanes))
end

function ArenaAdapter.GetTargets(arenaId)
	local state = getArenaState(arenaId)
	if not state then
		return nil
	end

	local targets = state.targets
	if type(targets) ~= "table" then
		return nil
	end

	return freezeTable(copyDictionary(targets))
end

function ArenaAdapter.GetPlayers(arenaId)
	local state = getArenaState(arenaId)
	if not state then
		return nil
	end

	local players = state.players
	if type(players) ~= "table" then
		return nil
	end

	local isArray = (#players > 0)

	if isArray then
		return freezeTable(copyArray(players))
	end

	local snapshot = {}
	for key, value in pairs(players) do
		snapshot[key] = value
	end

	return freezeTable(snapshot)
end
function ArenaAdapter.StartLocalRun(players: { Player }, config: { [string]: any }?)
	if not ArenaServer then
		warn("[ArenaAdapter] ArenaServer not loaded")
		return false
	end

	if typeof(ArenaServer.Start) ~= "function" then
		warn("[ArenaAdapter] ArenaServer missing Start()")
		return false
	end

	local ok, result = pcall(function()
		return ArenaServer.Start(players, config or {})
	end)

	if not ok then
		warn("[ArenaAdapter] Failed to start local run:", result)
		return false
	end

	return result == true
end


return ArenaAdapter

