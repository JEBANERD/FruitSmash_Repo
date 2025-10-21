--!strict
-- ShopServer (Task 18)
-- Handles coin-based purchases for melee, tokens, and utility items.
-- Preserves public API:
--   Init(), GetProfileAndInventory(), MarkProfileDirty(), UpdateQuickbarForPlayer(),
--   ApplyMeleeToInventory(), BuildQuickbarState()



local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- ---------- Utilities ----------

local function safeRequire(instance: Instance?): any?
	if instance == nil then
		return nil
	end
	local ok, result = pcall(require, instance)
	if not ok then
		warn(string.format("[ShopServer] Failed to require %s: %s", instance:GetFullName(), tostring(result)))
		return nil
	end
	return result
end

local function findFirstChildPath(root: Instance, path: {string}): Instance?
	local cur: Instance? = root
	for _, name in ipairs(path) do
		cur = cur and cur:FindFirstChild(name)
		if not cur then return nil end
	end
	return cur
end

-- ---------- Config ----------

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local ShopConfig = require(configFolder:WaitForChild("ShopConfig"))
local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = GameConfigModule.Get()

local QuickbarConfig = (GameConfig.UI and GameConfig.UI.Quickbar) or {}
local MELEE_SLOTS = QuickbarConfig.MeleeSlots or 2
local TOKEN_SLOTS = QuickbarConfig.TokenSlots or 3

-- ---------- PersistenceServer resolution (robust across layouts) ----------

-- Try common locations from the tasks doc:
--   ServerScriptService/GameServer/Data/PersistenceServer.lua
--   ServerScriptService/GameServer/PersistenceServer.lua
--   ServerScriptService/Data/PersistenceServer.lua
local PersistenceServer: any? = nil do
	local candidates = {
		{"GameServer", "Data", "PersistenceServer"},
		{"GameServer", "PersistenceServer"},
		{"Data", "PersistenceServer"},
	}
	for _, parts in ipairs(candidates) do
		local inst = findFirstChildPath(ServerScriptService, parts)
		if inst and inst:IsA("ModuleScript") then
			PersistenceServer = safeRequire(inst)
			if PersistenceServer then break end
		end
	end
end

-- ---------- Remotes (idempotent get-or-create) ----------

-- Remotes (strict-safe, idempotent)
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Ensure we have a concrete Folder (not Instance?) in strict mode
local RemotesFolder: Folder = (function()
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "Remotes"
	f.Parent = ReplicatedStorage
	return f
end)()

local function getOrCreateRemote(name: string, className: "RemoteEvent" | "RemoteFunction")
	-- Now RemotesFolder is guaranteed a Folder, so no warnings here
	local found = RemotesFolder:FindFirstChild(name)
	if found and found.ClassName == className then
		return found
	end
	if found then
		found:Destroy()
	end

	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = RemotesFolder
	return remote
end

-- Example uses:
local RF_RequestPurchase = getOrCreateRemote("RF_RequestPurchase", "RemoteFunction") :: RemoteFunction
local RE_QuickbarUpdate = getOrCreateRemote("RE_QuickbarUpdate", "RemoteEvent") :: RemoteEvent
local RE_Notice         = getOrCreateRemote("RE_Notice", "RemoteEvent") :: RemoteEvent

-- ---------- Fallback profiles (when PersistenceServer is absent) ----------

local FALLBACK_DEFAULTS = {
	Coins = 0,
	Inventory = {
		MeleeLoadout = {} :: {string},
		ActiveMelee = nil :: string?,
		TokenCounts = {} :: {[string]: number},
		UtilityQueue = {} :: {any},
	},
}
local fallbackProfiles: {[number]: { Data: any }} = {}

local function cloneDefaults(): any
	return {
		Coins = FALLBACK_DEFAULTS.Coins,
		Inventory = {
			MeleeLoadout = {},
			ActiveMelee = nil,
			TokenCounts = {},
			UtilityQueue = {},
		},
	}
end

local function ensureFallbackProfile(player: Player)
	local uid = player.UserId
	local profile = fallbackProfiles[uid]
	if not profile then
		profile = { Data = cloneDefaults() }
		fallbackProfiles[uid] = profile
	end
	return profile
end

-- ---------- Shop data ----------

local ShopItems = (type(ShopConfig.All) == "function" and ShopConfig.All()) or ShopConfig.Items or {}

-- ---------- Persistence helpers ----------

-- Some ProfileService wrappers use ":" (self), some expose free functions.
-- Use pcall with direct function refs (no vararg closures) to avoid vararg-capture glitches.
local function callPersistence(methodName: string, player: Player, ...: any): any?
	if not PersistenceServer then return nil end

	local method = (PersistenceServer :: any)[methodName]
	if type(method) ~= "function" then return nil end

	-- Try method as a colon-style member: method(self, player, ...)
	local ok, result = pcall(method, PersistenceServer, player, ...)
	if ok and result ~= nil then
		return result
	end

	-- Try as a free function: method(player, ...)
	ok, result = pcall(method, player, ...)
	if ok and result ~= nil then
		return result
	end

	if not ok and result ~= nil then
		warn(string.format("[ShopServer] Persistence '%s' failed: %s", methodName, tostring(result)))
	end
	return nil
end

local function getProfile(player: Player)
	local profile = callPersistence("GetProfile", player)
	if profile then return profile end

	profile = callPersistence("GetProfileAsync", player)
	if profile then return profile end

	-- Some stubs store by index on the persistence table
	if PersistenceServer and type((PersistenceServer :: any)[player]) == "table" then
		return (PersistenceServer :: any)[player]
	end

	return ensureFallbackProfile(player)
end

local function markProfileDirty(player: Player, profile: any)
	if not PersistenceServer then return end

	-- Preferred pattern: PersistenceServer:MarkDirty(player, profile)
	if type((PersistenceServer :: any).MarkDirty) == "function" then
		local ok, err = pcall(function()
			return (PersistenceServer :: any):MarkDirty(player, profile)
		end)
		if not ok then
			ok, err = pcall(function()
				return (PersistenceServer :: any).MarkDirty(player, profile)
			end)
		end
		if not ok and err then
			warn(string.format("[ShopServer] MarkDirty failed: %s", tostring(err)))
		end
		return
	end

	-- Fallback: Call profile:MarkDirty() or profile:Save()
	if profile then
		if type(profile.MarkDirty) == "function" then
			local ok, err = pcall(function() profile:MarkDirty() end)
			if not ok then
				warn(string.format("[ShopServer] profile:MarkDirty failed: %s", tostring(err)))
			end
		elseif type(profile.Save) == "function" then
			local ok, err = pcall(function() profile:Save() end)
			if not ok then
				warn(string.format("[ShopServer] profile:Save failed: %s", tostring(err)))
			end
		end
	end
end

-- ---------- Inventory helpers ----------

local function ensureInventory(profile: any): (any?, any?)
	if type(profile) ~= "table" then
		return nil, nil
	end

	local data = profile.Data
	if type(data) ~= "table" then
		data = cloneDefaults()
		profile.Data = data
	end

	if type(data.Coins) ~= "number" then
		data.Coins = FALLBACK_DEFAULTS.Coins
	end

	local inventory = data.Inventory
	if type(inventory) ~= "table" then
		inventory = cloneDefaults().Inventory
		data.Inventory = inventory
	end

	inventory.MeleeLoadout = inventory.MeleeLoadout or {}
	inventory.TokenCounts = inventory.TokenCounts or {}
	inventory.UtilityQueue = inventory.UtilityQueue or {}

	return data, inventory
end

local function sendNotice(player: Player, message: string, kind: string)
	if RE_Notice then
		RE_Notice:FireClient(player, { msg = message, kind = kind })
	end
end

local function applyMeleePurchase(inventory: any, item: any): (boolean, string?)
	local loadout = inventory.MeleeLoadout
	if table.find(loadout, item.Id) then
		return false, "AlreadyOwned"
	end
	table.insert(loadout, item.Id)
	if inventory.ActiveMelee == nil then
		inventory.ActiveMelee = item.Id
	end
	return true, nil
end

local function applyTokenPurchase(inventory: any, item: any): (boolean, string?)
	local counts = inventory.TokenCounts
	local current = counts[item.Id] or 0
	local limit = item.StackLimit or math.huge
	if current >= limit then
		return false, "StackLimit"
	end
	counts[item.Id] = current + 1
	return true, nil
end

local function applyUtilityPurchase(inventory: any, item: any): (boolean, string?)
	table.insert(inventory.UtilityQueue, {
		Id = item.Id,
		Effect = item.Effect,
		Applied = false,
	})
	return true, nil
end

-- ---------- Quickbar ----------

local function buildQuickbarState(data: any, inventory: any)
	local state = {
		coins = data.Coins or 0,
		melee = {} :: { { Id: string, Active: boolean } },
		tokens = {} :: { { Id: string, Count: number, StackLimit: number? } },
		utility = {} :: { { Id: string, Effect: any?, Applied: boolean? } },
	}

	-- Active melee first
	if inventory.ActiveMelee then
		table.insert(state.melee, { Id = inventory.ActiveMelee, Active = true })
	end

	-- Fill remaining melee slots
	for _, id in ipairs(inventory.MeleeLoadout) do
		if id ~= inventory.ActiveMelee then
			table.insert(state.melee, { Id = id, Active = false })
		end
		if #state.melee >= MELEE_SLOTS then break end
	end

	-- Tokens: sort by Id for stable ordering
	local tokenEntries = {}
	for tokenId, count in pairs(inventory.TokenCounts) do
		if (count or 0) > 0 then
			table.insert(tokenEntries, {
				Id = tokenId,
				Count = count,
				StackLimit = (ShopItems[tokenId] and ShopItems[tokenId].StackLimit) or nil,
			})
		end
	end
	table.sort(tokenEntries, function(a, b) return a.Id < b.Id end)
	for _, entry in ipairs(tokenEntries) do
		table.insert(state.tokens, entry)
		if #state.tokens >= TOKEN_SLOTS then break end
	end

	-- Utility queue
	for _, entry in ipairs(inventory.UtilityQueue) do
		if typeof(entry) == "table" then
			table.insert(state.utility, { Id = entry.Id, Effect = entry.Effect, Applied = entry.Applied })
		else
			table.insert(state.utility, { Id = entry })
		end
	end

	return state
end

local function updateQuickbar(player: Player, data: any, inventory: any)
	if RE_QuickbarUpdate then
		RE_QuickbarUpdate:FireClient(player, buildQuickbarState(data, inventory))
	end
end

-- ---------- Purchasing ----------

local function processPurchase(player: Player, itemId: string)
	local response = { success = false, itemId = itemId }

	if typeof(itemId) ~= "string" or itemId == "" then
		sendNotice(player, "Invalid item selection.", "error")
		response["reason"] = "InvalidItem"
		return response
	end

	local item = (type(ShopConfig.Get) == "function" and ShopConfig.Get(itemId)) or ShopItems[itemId]
	if not item then
		sendNotice(player, "Item not available.", "error")
		response["reason"] = "UnknownItem"
		return response
	end

	local profile = getProfile(player)
	if not profile then
		sendNotice(player, "Could not access your save data.", "error")
		response["reason"] = "NoProfile"
		return response
	end

	local data, inventory = ensureInventory(profile)
	if not data or not inventory then
		sendNotice(player, "Unable to load inventory.", "error")
		response["reason"] = "InventoryUnavailable"
		return response
	end

	local price = tonumber(item.PriceCoins) or 0
	if (data.Coins or 0) < price then
		sendNotice(player, "Not enough coins for that purchase.", "warn")
		response["reason"] = "InsufficientFunds"
		response["coins"] = data.Coins
		return response
	end

	local kind = string.lower(item.Kind or "")
	local ok: boolean, failureReason: string? = false, nil
	if kind == "melee" then
		ok, failureReason = applyMeleePurchase(inventory, item)
	elseif kind == "token" then
		ok, failureReason = applyTokenPurchase(inventory, item)
	elseif kind == "utility" then
		ok, failureReason = applyUtilityPurchase(inventory, item)
	else
		sendNotice(player, "That item cannot be purchased right now.", "error")
		response["reason"] = "UnsupportedKind"
		return response
	end

	if not ok then
		if failureReason == "StackLimit" then
			sendNotice(player, "You are already holding the maximum amount of that item.", "warn")
		elseif failureReason == "AlreadyOwned" then
			sendNotice(player, "You already own that item.", "warn")
		else
			sendNotice(player, "Purchase failed.", "error")
		end
		response["reason"] = failureReason or "PurchaseFailed"
		return response
	end

	data.Coins = math.max((data.Coins or 0) - price, 0)
	markProfileDirty(player, profile)
	updateQuickbar(player, data, inventory)

	sendNotice(player, string.format("Purchased %s!", item.Name or item.Id), "info")
	response["success"] = true
	response["coins"] = data.Coins
	response["kind"] = item.Kind
	response["quickbar"] = buildQuickbarState(data, inventory)
	return response
end

local function handlePurchaseRequest(player: Player, payloadOrItemId: any)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return { success = false, reason = "InvalidPlayer" }
	end

	-- Accept either a string id or a payload { itemId = "..." }
	local itemId: string? = nil
	if typeof(payloadOrItemId) == "string" then
		itemId = payloadOrItemId
	elseif typeof(payloadOrItemId) == "table" then
		itemId = payloadOrItemId.itemId or payloadOrItemId.Id
	end
	if not itemId then
		return { success = false, reason = "InvalidItem" }
	end

	return processPurchase(player, itemId)
end

-- ---------- Public API ----------

local ShopServer = {}
local initialized = false

function ShopServer.Init()
	if initialized then return end
	initialized = true

	RF_RequestPurchase.OnServerInvoke = handlePurchaseRequest

	Players.PlayerRemoving:Connect(function(player)
		fallbackProfiles[player.UserId] = nil
	end)

	print("[ShopServer] Initialized")
end

ShopServer.Init()

function ShopServer.GetProfileAndInventory(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil, nil, nil
	end
	local profile = getProfile(player)
	if not profile then
		return nil, nil, nil
	end
	local data, inventory = ensureInventory(profile)
	if not data or not inventory then
		return nil, nil, nil
	end
	return profile, data, inventory
end

function ShopServer.MarkProfileDirty(player: Player, profile: any)
	markProfileDirty(player, profile)
end

function ShopServer.UpdateQuickbarForPlayer(player: Player, data: any, inventory: any)
	updateQuickbar(player, data, inventory)
end

function ShopServer.ApplyMeleeToInventory(inventory: any, item: any)
	return applyMeleePurchase(inventory, item)
end

function ShopServer.BuildQuickbarState(data: any, inventory: any)
	return buildQuickbarState(data, inventory)
end

return ShopServer
