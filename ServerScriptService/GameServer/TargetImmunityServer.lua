--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TargetImmunityServer = {}

local function safeRequire(instance)
	if not instance then
		return nil
	end

	local ok, result = pcall(require, instance)
	if not ok then
		warn(string.format("[TargetImmunity] Failed to require %s: %s", instance:GetFullName(), tostring(result)))
		return nil
	end

	return result
end

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = typeof(GameConfigModule.Get) == "function" and GameConfigModule.Get() or GameConfigModule
local TargetsConfig = GameConfig.Targets or {}

local shieldTag = TargetsConfig.ShieldFXTag
local hasShieldTag = typeof(shieldTag) == "string" and shieldTag ~= ""

local combatFolder = ServerScriptService:FindFirstChild("Combat")
local ArenaAdapter = safeRequire(combatFolder and combatFolder:FindFirstChild("ArenaAdapter"))

local active = {}

type ArenaState = {
	token: any,
	expiresAt: number?,
	tagged: {[Instance]: boolean},
	targetConnections: {[Instance]: {RBXScriptConnection}},
	connections: {RBXScriptConnection},
}

local function newArenaState(): ArenaState
	return {
		token = nil,
		expiresAt = nil,
		tagged = setmetatable({}, { __mode = "k" }),
		targetConnections = setmetatable({}, { __mode = "k" }),
		connections = {},
	}
end

local function disconnectConnection(connection: RBXScriptConnection?)
	if connection then
		connection:Disconnect()
	end
end

local function disconnectConnectionList(list)
	if not list then
		return
	end

	for _, connection in ipairs(list) do
		disconnectConnection(connection)
	end
end

local function shouldTag(instance: Instance): boolean
	if not hasShieldTag then
		return false
	end

	return instance:IsA("BasePart") or instance:IsA("Model")
end

local function addTag(instance: Instance, state: ArenaState)
	if not hasShieldTag then
		return
	end

	if not shouldTag(instance) then
		return
	end

	if state.tagged[instance] then
		return
	end

	local ok, err = pcall(CollectionService.AddTag, CollectionService, instance, shieldTag)
	if not ok then
		warn(string.format("[TargetImmunity] Failed to add tag '%s' to %s: %s", tostring(shieldTag), instance:GetFullName(), tostring(err)))
		return
	end

	state.tagged[instance] = true
end

local function removeTag(instance: Instance, state: ArenaState)
	if not hasShieldTag then
		return
	end

	if not state.tagged[instance] then
		return
	end

	state.tagged[instance] = nil

	local ok, err = pcall(CollectionService.RemoveTag, CollectionService, instance, shieldTag)
	if not ok then
		warn(string.format("[TargetImmunity] Failed to remove tag '%s' from %s: %s", tostring(shieldTag), instance:GetFullName(), tostring(err)))
	end
end

local function removeTagsForTarget(state: ArenaState, target: Instance)
	if not hasShieldTag then
		return
	end

	local removalList = {}

	for instance in pairs(state.tagged) do
		if instance == target then
			table.insert(removalList, instance)
		elseif instance:IsDescendantOf(target) then
			table.insert(removalList, instance)
		end
	end

	for _, instance in ipairs(removalList) do
		removeTag(instance, state)
	end
end

local function getTargetsForArena(arenaId)
	if not ArenaAdapter then
		return {}
	end

	local getTargets = ArenaAdapter.GetTargets
	if typeof(getTargets) ~= "function" then
		return {}
	end

	local ok, result = pcall(getTargets, arenaId)
	if not ok or typeof(result) ~= "table" then
		return {}
	end

	local targets = {}
	for _, target in ipairs(result) do
		if typeof(target) == "Instance" then
			table.insert(targets, target)
		end
	end

	return targets
end

local function getTargetsFolder(arenaId)
	if not ArenaAdapter then
		return nil
	end

	local getFolder = ArenaAdapter.GetTargetsFolder
	if typeof(getFolder) ~= "function" then
		return nil
	end

	local ok, folder = pcall(getFolder, arenaId)
	if not ok then
		return nil
	end

	if typeof(folder) == "Instance" then
		return folder
	end

	return nil
end

local function untrackTarget(arenaId, state: ArenaState, target: Instance)
	local connections = state.targetConnections[target]
	if connections then
		for _, connection in ipairs(connections) do
			disconnectConnection(connection)
		end
		state.targetConnections[target] = nil
	end

	removeTagsForTarget(state, target)
end

local function trackTarget(arenaId, state: ArenaState, target: Instance)
	if not target or state.targetConnections[target] then
		return
	end

	if hasShieldTag then
		addTag(target, state)
		for _, descendant in ipairs(target:GetDescendants()) do
			addTag(descendant, state)
		end
	end

	if not hasShieldTag then
		return
	end

	local connections = {}

	connections[1] = target.DescendantAdded:Connect(function(descendant)
		if active[arenaId] ~= state then
			return
		end

		addTag(descendant, state)
	end)

	connections[2] = target.AncestryChanged:Connect(function(_, parent)
		if active[arenaId] ~= state then
			return
		end

		if parent == nil then
			untrackTarget(arenaId, state, target)
		end
	end)

	state.targetConnections[target] = connections
end

local function attachFolderListener(arenaId, state: ArenaState)
	if not hasShieldTag then
		return
	end

	local folder = getTargetsFolder(arenaId)
	if not folder then
		return
	end

	disconnectConnectionList(state.connections)
	state.connections = {}

	local connection = folder.ChildAdded:Connect(function(child)
		if active[arenaId] ~= state then
			return
		end

		trackTarget(arenaId, state, child)
	end)

	table.insert(state.connections, connection)
end

local function releaseArena(arenaId, state: ArenaState?)
	state = state or active[arenaId]
	if not state then
		return
	end

	for target, connections in pairs(state.targetConnections) do
		untrackTarget(arenaId, state, target)
		if connections then
			for _, connection in ipairs(connections) do
				disconnectConnection(connection)
			end
		end
	end

	state.targetConnections = setmetatable({}, { __mode = "k" })

	disconnectConnectionList(state.connections)
	state.connections = {}

	if hasShieldTag then
		local removalList = {}
		for instance in pairs(state.tagged) do
			table.insert(removalList, instance)
		end

		for _, instance in ipairs(removalList) do
			removeTag(instance, state)
		end
	end

	state.tagged = setmetatable({}, { __mode = "k" })

	active[arenaId] = nil
end

local function ensureState(arenaId): ArenaState
	local state = active[arenaId]
	if not state then
		state = newArenaState()
		active[arenaId] = state
	end

	return state
end

function TargetImmunityServer.SetShield(arenaId, enabled, durationSeconds, token)
	if arenaId == nil then
		return
	end

	if not enabled then
		local state = active[arenaId]
		if not state then
			return
		end

		if token ~= nil and state.token ~= nil and state.token ~= token then
			return
		end

		releaseArena(arenaId, state)
		return
	end

	local state = ensureState(arenaId)

	if state.token ~= nil and token ~= nil and state.token ~= token then
		releaseArena(arenaId, state)
		state = ensureState(arenaId)
	end

	state.token = token or state.token or {}

	if typeof(durationSeconds) == "number" and durationSeconds > 0 then
		state.expiresAt = os.clock() + durationSeconds
	else
		state.expiresAt = nil
	end

	if hasShieldTag then
		for _, target in ipairs(getTargetsForArena(arenaId)) do
			trackTarget(arenaId, state, target)
		end

		attachFolderListener(arenaId, state)
	end
end

function TargetImmunityServer.IsShielded(arenaId)
	local state = active[arenaId]
	if not state then
		return false
	end

	if state.expiresAt and state.expiresAt <= os.clock() then
		releaseArena(arenaId, state)
		return false
	end

	return true
end

function TargetImmunityServer.Clear(arenaId)
	releaseArena(arenaId)
end

if ArenaAdapter and typeof(ArenaAdapter.ArenaRemoved) == "RBXScriptSignal" then
	ArenaAdapter.ArenaRemoved:Connect(function(arenaId)
		TargetImmunityServer.Clear(arenaId)
	end)
elseif ArenaAdapter and ArenaAdapter.ArenaRemoved and typeof(ArenaAdapter.ArenaRemoved.Connect) == "function" then
	ArenaAdapter.ArenaRemoved:Connect(function(arenaId)
		TargetImmunityServer.Clear(arenaId)
	end)
end

return TargetImmunityServer
