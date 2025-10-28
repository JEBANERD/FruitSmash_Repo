local ServerScriptService = game:GetService("ServerScriptService")

local ArenaServer = require(ServerScriptService:WaitForChild("GameServer"):WaitForChild("ArenaServer"))

local ArenaAdapter = {}

local arenas = {}
local removedEvent = Instance.new("BindableEvent")
ArenaAdapter.ArenaRemoved = removedEvent.Event

local function parseLaneId(instance)
	if not instance then
		return nil
	end

	local attribute = instance:GetAttribute("LaneId")
	if typeof(attribute) == "number" then
		return attribute
	end

	if typeof(attribute) == "string" then
		local numeric = tonumber(attribute)
		if numeric then
			return numeric
		end

		local digits = string.match(attribute, "%d+")
		if digits then
			return tonumber(digits)
		end
	end

	local nameDigits = string.match(instance.Name, "%d+")
	if nameDigits then
		return tonumber(nameDigits)
	end

	return nil
end

local function getWorldCFrame(instance)
	if not instance then
		return nil
	end

	if instance:IsA("BasePart") then
		return instance.CFrame
	end

	if instance:IsA("Model") then
		return instance:GetPivot()
	end

	if instance:IsA("Attachment") then
		return instance.WorldCFrame
	end

	local basePart = instance:FindFirstChildWhichIsA("BasePart")
	if basePart then
		return basePart.CFrame
	end

	return nil
end

local function gatherChildren(folder)
	local list = {}

	if not folder then
		return list
	end

	for _, child in ipairs(folder:GetChildren()) do
		table.insert(list, child)
	end

	table.sort(list, function(a, b)
		local aId = parseLaneId(a)
		local bId = parseLaneId(b)

		if aId and bId then
			if aId == bId then
				return a.Name < b.Name
			end
			return aId < bId
		elseif aId then
			return true
		elseif bId then
			return false
		end

		return a.Name < b.Name
	end)

	return list
end

local function normalizeLaneKey(laneId)
	if typeof(laneId) == "number" then
		return laneId
	end

	if typeof(laneId) == "string" then
		local numeric = tonumber(laneId)
		if numeric then
			return numeric
		end

		local digits = string.match(laneId, "%d+")
		if digits then
			return tonumber(digits)
		end

		return laneId
	end

	return laneId
end

local function refreshArenaEntry(arenaId, entry, arenaState)
	entry.level = arenaState.level or entry.level or 1
	entry.partyId = arenaState.partyId
	entry.instance = arenaState.instance or entry.instance

	entry.laneList = {}
	entry.lanesById = {}

	local lanes = arenaState.lanes

	if lanes then
		for index, lane in ipairs(lanes) do
			entry.laneList[index] = lane
			local laneId = parseLaneId(lane) or index
			if entry.lanesById[laneId] == nil then
				entry.lanesById[laneId] = lane
			end
		end
	else
		local lanesFolder = entry.instance and entry.instance:FindFirstChild("Lanes")
		if lanesFolder then
			local ordered = gatherChildren(lanesFolder)
			for index, lane in ipairs(ordered) do
				entry.laneList[index] = lane
				local laneId = parseLaneId(lane) or index
				if entry.lanesById[laneId] == nil then
					entry.lanesById[laneId] = lane
				end
			end
		end
	end

	entry.targetList = {}
	entry.targetsById = {}

	local targetsFolder = entry.instance and entry.instance:FindFirstChild("Targets")
	if targetsFolder then
		local orderedTargets = gatherChildren(targetsFolder)
		for index, target in ipairs(orderedTargets) do
			entry.targetList[index] = target
			local laneId = parseLaneId(target) or index
			if entry.targetsById[laneId] == nil then
				entry.targetsById[laneId] = target
			end
		end
	end
end

local function ensureArena(arenaId)
	if not arenaId then
		return nil
	end

	local arenaState = ArenaServer.GetArenaState and ArenaServer.GetArenaState(arenaId)
	if not arenaState then
		return nil
	end

	local entry = arenas[arenaId]
	if not entry then
		entry = {
			arenaId = arenaId,
			connections = {},
		}
		arenas[arenaId] = entry
	end

	if entry.instance ~= arenaState.instance then
		for _, connection in ipairs(entry.connections) do
			if connection then
				connection:Disconnect()
			end
		end

		entry.connections = {}
		entry.instance = arenaState.instance

		if entry.instance then
			local connection = entry.instance.AncestryChanged:Connect(function(_, parent)
				if parent == nil then
					ArenaAdapter.ClearArena(arenaId)
				end
			end)
			table.insert(entry.connections, connection)
		end
	end

	refreshArenaEntry(arenaId, entry, arenaState)

	return entry
end

function ArenaAdapter.ClearArena(arenaId)
	local entry = arenas[arenaId]
	if not entry then
		return
	end

	for _, connection in ipairs(entry.connections) do
		if connection then
			connection:Disconnect()
		end
	end

	arenas[arenaId] = nil
	removedEvent:Fire(arenaId)
end

function ArenaAdapter.GetArenaLevel(arenaId)
	local entry = ensureArena(arenaId)
	if not entry then
		return nil
	end

	return entry.level
end

function ArenaAdapter.GetLaneInfo(arenaId, laneId)
	local entry = ensureArena(arenaId)
	if not entry then
		return nil
	end

	local lookupKey = normalizeLaneKey(laneId)

	local lane = entry.lanesById and entry.lanesById[lookupKey]
	if not lane then
		lane = entry.laneList and entry.laneList[lookupKey]
	end

	local target = entry.targetsById and entry.targetsById[lookupKey]
	if not target then
		target = entry.targetList and entry.targetList[lookupKey]
	end

	local originCFrame = getWorldCFrame(lane)
	local targetCFrame = getWorldCFrame(target)

	return {
		arenaId = arenaId,
		laneId = laneId,
		lane = lane,
		target = target,
		originCFrame = originCFrame,
		targetCFrame = targetCFrame,
		targetPosition = targetCFrame and targetCFrame.Position or nil,
	}
end

local function gatherTargets(entry)
	local map = {}

	if entry.targetList then
		for _, target in ipairs(entry.targetList) do
			if target then
				map[target] = true
			end
		end
	end

	if entry.targetsById then
		for _, target in pairs(entry.targetsById) do
			if target then
				map[target] = true
			end
		end
	end

	local list = {}
	for target in pairs(map) do
		table.insert(list, target)
	end

	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)

	return list
end

function ArenaAdapter.GetTargets(arenaId)
	local entry = ensureArena(arenaId)
	if not entry then
		return {}
	end

	return gatherTargets(entry)
end

function ArenaAdapter.GetTargetsFolder(arenaId)
	local entry = ensureArena(arenaId)
	if not entry then
		return nil
	end

	local instance = entry.instance
	if not instance then
		return nil
	end

	return instance:FindFirstChild("Targets")
end

function ArenaAdapter.GetArenaInstance(arenaId)
	local entry = ensureArena(arenaId)
	if not entry then
		return nil
	end

	return entry.instance
end

return ArenaAdapter
