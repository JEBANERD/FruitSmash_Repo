local ArenaAdapter = {}

local function safeRequire(instance)
	if not instance then
		return nil
	end

	local ok, result = pcall(require, instance)
	if not ok then
		warn(string.format("[ArenaAdapter] Failed to require %s: %s", instance:GetFullName(), tostring(result)))
		return nil
	end

	return result
end

local ArenaServer = safeRequire(script.Parent:FindFirstChild("ArenaServer"))

local function getArenaServer()
	if not ArenaServer then
		ArenaServer = safeRequire(script.Parent:FindFirstChild("ArenaServer"))
	end

	return ArenaServer
end

function ArenaAdapter.GetArenaState(arenaId)
	local arenaServer = getArenaServer()
	if not arenaServer or type(arenaServer.GetArenaState) ~= "function" then
		return nil
	end

	local ok, state = pcall(arenaServer.GetArenaState, arenaId)
	if not ok then
		warn(string.format("[ArenaAdapter] Failed to get arena state for '%s': %s", tostring(arenaId), tostring(state)))
		return nil
	end

	return state
end

function ArenaAdapter.GetArenaInstance(arenaId)
	local state = ArenaAdapter.GetArenaState(arenaId)
	return state and state.instance or nil
end

function ArenaAdapter.GetLaneIndex(arenaId, laneInstance)
	if not laneInstance then
		return nil
	end

	local state = ArenaAdapter.GetArenaState(arenaId)
	local lanes = state and state.lanes
	if type(lanes) ~= "table" then
		return nil
	end

	for index, lane in ipairs(lanes) do
		if lane == laneInstance then
			return index
		end
	end

	return nil
end

function ArenaAdapter.ResolveLane(arenaId, laneIdentifier)
	if typeof(laneIdentifier) == "Instance" then
		return laneIdentifier
	end

	-- Try from registered state
	local state = ArenaAdapter.GetArenaState(arenaId)
	local lanes = state and state.lanes

	if type(lanes) == "table" and #lanes > 0 then
		if typeof(laneIdentifier) == "number" then
			return lanes[laneIdentifier]
		end

		for _, lane in ipairs(lanes) do
			if lane == laneIdentifier then
				return lane
			end

			local laneId = lane:GetAttribute("LaneId")
			if laneId ~= nil and laneId == laneIdentifier then
				return lane
			end

			if typeof(laneIdentifier) == "string" and lane.Name == laneIdentifier then
				return lane
			end
		end
	end

	-- Fallback: Try direct search inside arena model
	local arena = ArenaAdapter.GetArenaInstance(arenaId)
	if not arena then return nil end

	local lanesFolder = arena:FindFirstChild("Lanes")
	if not lanesFolder then return nil end

	if typeof(laneIdentifier) == "number" then
		return lanesFolder:FindFirstChild("Lane_" .. tostring(laneIdentifier))
	end

	return lanesFolder:FindFirstChild(tostring(laneIdentifier))
end

return ArenaAdapter
