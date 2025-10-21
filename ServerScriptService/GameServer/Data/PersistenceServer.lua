--!strict
-- PersistenceServer.lua
-- Robust ProfileService-backed persistence with schema defaults and strict typing.
-- Public API:
--   PersistenceServer:Load(player) -> profile?            -- loads (or returns existing)
--   PersistenceServer:GetProfile(player) -> profile?
--   PersistenceServer:GetData(player) -> table?
--   PersistenceServer:MarkDirty(playerOrUserId [, profile]) -> boolean
--   PersistenceServer:Save(playerOrUserId [, releaseAfter:boolean]) -> boolean

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

--// Types (loose on purpose, we don't assume exact ProfileService types)
type Profile = {
	Data: any,
	Reconcile: (Profile) -> (),
	Release: (Profile) -> (),
	Save: (Profile) -> (),
	ListenToRelease: (Profile, (any) -> ()) -> (),
	AddUserId: (Profile, number) -> (),
}

--==============================================================
-- Utils
--==============================================================
local function deepCopy(src: any): any
	if typeof(src) ~= "table" then
		return src
	end
	local out = {}
	for k, v in pairs(src) do
		out[k] = deepCopy(v)
	end
	return out
end

local function path(root: Instance, parts: {string}): Instance?
	local cur: Instance? = root
	for _, name in ipairs(parts) do
		if not cur then return nil end
		cur = cur:FindFirstChild(name)
	end
	return cur
end

local function playerStillInGame(player: Player?): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	if player.Parent == nil then
		return false
	end
	return Players:GetPlayerByUserId(player.UserId) == player
end

--==============================================================
-- Load Save Schema (Defaults)
--==============================================================
local SaveSchemaModule = ReplicatedStorage
	:WaitForChild("Shared")
	:WaitForChild("Types")
	:WaitForChild("SaveSchema")

local okSchema, SaveSchemaOrErr = pcall(require, SaveSchemaModule)
if not okSchema then
	warn("[PersistenceServer] SaveSchema require failed: ", SaveSchemaOrErr)
end

local templateSource = (okSchema and (SaveSchemaOrErr :: any).Defaults) or {}
if typeof(templateSource) ~= "table" then
	templateSource = {}
end
local DEFAULT_TEMPLATE = deepCopy(templateSource)

--==============================================================
-- Locate & require ProfileService (ModuleScript only)
--==============================================================
local function findProfileServiceModule(): ModuleScript?
	local candidates: {Instance?} = {
		path(ServerScriptService, {"GameServer","Libraries","ProfileService"}),
		ServerScriptService:FindFirstChild("ProfileService"),
		path(ReplicatedStorage, {"Packages","ProfileService"}),
		ReplicatedStorage:FindFirstChild("ProfileService"),
		ServerStorage:FindFirstChild("ProfileService"),
	}
	for _, inst in ipairs(candidates) do
		if inst and inst:IsA("ModuleScript") then
			return inst
		end
	end
	return nil
end

local ProfileServiceModule = findProfileServiceModule()
local ProfileService: any? = nil
if ProfileServiceModule then
	local okPS, result = pcall(require, ProfileServiceModule)
	if okPS then
		ProfileService = result
	else
		warn("[PersistenceServer] Failed to require ProfileService: ", result)
	end
else
	warn("[PersistenceServer] ProfileService module not found; data will not persist across servers (dev fallback).")
end

--==============================================================
-- Config
--==============================================================
local PROFILE_STORE_NAME = "PlayerData"     -- bump when schema changes
local MAX_LOAD_ATTEMPTS = 5
local BASE_RETRY_DELAY = 1
local MAX_RETRY_DELAY = 8
local LOAD_WAIT_INTERVAL = 0.10
local SAVE_RETRY_ATTEMPTS = 3
local SAVE_RETRY_DELAY = 0.50
local SHUTDOWN_TIMEOUT = 15

--==============================================================
-- Store / Runtime state
--==============================================================
local profileStore: any? = nil
if ProfileService and typeof(ProfileService.GetProfileStore) == "function" then
	profileStore = ProfileService.GetProfileStore(PROFILE_STORE_NAME, DEFAULT_TEMPLATE)
end

-- Weak map keyed by Player (strict-safe)
local profilesByPlayer: { [Player]: Profile } = {}
setmetatable(profilesByPlayer, { __mode = "k" })

-- Strong maps (these are fine as-is)
local profilesByUserId: { [number]: Profile } = {}
local loadingUsers: { [number]: boolean } = {}
local shuttingDown = false


--==============================================================
-- Core helpers
--==============================================================
local function registerProfile(player: Player, profile: Profile)
	profilesByPlayer[player] = profile
	profilesByUserId[player.UserId] = profile
end

local function unregisterProfile(player: Player?, userId: number?)
	if player then
		profilesByPlayer[player] = nil
		userId = userId or player.UserId
	end
	if userId then
		profilesByUserId[userId] = nil
	end
end

local function trySaveProfile(profile: Profile, userId: number?): boolean
	if typeof((profile :: any).Save) ~= "function" then
		return true
	end

	for attempt = 1, SAVE_RETRY_ATTEMPTS do
		local ok, err = pcall(function()
			(profile :: any):Save()
		end)
		if ok then
			return true
		end
		warn(("[PersistenceServer] profile:Save failed for %s (attempt %d): %s")
			:format(tostring(userId), attempt, tostring(err)))
		if attempt < SAVE_RETRY_ATTEMPTS then
			task.wait(math.min(SAVE_RETRY_DELAY * attempt, MAX_RETRY_DELAY))
		end
	end
	return false
end

local function safeRelease(player: Player?, userId: number?, profile: Profile?)
	if not profile then return end

	unregisterProfile(player, userId)

	-- Release (ignore if missing)
	if typeof((profile :: any).Release) == "function" then
		local ok, err = pcall(function()
			(profile :: any):Release()
		end)
		if not ok then
			warn(("[PersistenceServer] profile:Release failed for %s: %s")
				:format(tostring(userId), tostring(err)))
		end
	end
end

local function loadProfileWithRetries(player: Player, userId: number): Profile?
	if not profileStore then
		-- Fallback in-memory profile (session only)
		local p: Profile = {
			Data = deepCopy(DEFAULT_TEMPLATE),
			Reconcile = function() end,
			Release = function() end,
			Save = function() end,
			ListenToRelease = function() end,
			AddUserId = function() end,
		}
		return p
	end

	local profileKey = ("Player_%d"):format(userId)
	for attempt = 1, MAX_LOAD_ATTEMPTS do
		if not playerStillInGame(player) then
			return nil
		end

		local ok, result = pcall(function()
			return profileStore:LoadProfileAsync(profileKey, "ForceLoad")
		end)

		if ok then
			local profile = result :: Profile?
			if profile ~= nil then
				return profile
			else
				warn(("[PersistenceServer] LoadProfileAsync returned nil for %s (attempt %d)")
					:format(tostring(userId), attempt))
			end
		else
			warn(("[PersistenceServer] LoadProfileAsync failed for %s (attempt %d): %s")
				:format(tostring(userId), attempt, tostring(result)))
		end

		if attempt < MAX_LOAD_ATTEMPTS then
			local backoff = math.min(BASE_RETRY_DELAY * 2 ^ (attempt - 1), MAX_RETRY_DELAY)
			task.wait(backoff)
		end
	end

	return nil
end

--==============================================================
-- Public API
--==============================================================
local PersistenceServer = {}

function PersistenceServer:GetProfile(player: Player): Profile?
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end
	return profilesByPlayer[player]
end

function PersistenceServer:GetData(player: Player): any?
	local prof = self:GetProfile(player)
	return prof and prof.Data or nil
end

function PersistenceServer:Load(player: Player): Profile?
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end

	local existing = profilesByPlayer[player]
	if existing then
		return existing
	end

	if not playerStillInGame(player) then
		return nil
	end

	local userId = player.UserId
	if typeof(userId) ~= "number" or userId <= 0 then
		warn(("[PersistenceServer] Invalid userId for player %s"):format(player.Name))
		return nil
	end

	-- If another thread is loading the same user, wait briefly
	while loadingUsers[userId] do
		task.wait(LOAD_WAIT_INTERVAL)
		existing = profilesByUserId[userId]
		if existing then
			return existing
		end
		if not playerStillInGame(player) then
			return nil
		end
	end

	loadingUsers[userId] = true
	local profile = loadProfileWithRetries(player, userId)
	loadingUsers[userId] = false

	if not profile then
		return nil
	end

	if not playerStillInGame(player) then
		safeRelease(player, userId, profile)
		return nil
	end

	-- Standard Profile setup
	if typeof((profile :: any).AddUserId) == "function" then
		(profile :: any):AddUserId(userId)
	end

	if typeof(profile.Data) ~= "table" then
		(profile :: any).Data = deepCopy(DEFAULT_TEMPLATE)
	end

	if typeof((profile :: any).Reconcile) == "function" then
		(profile :: any):Reconcile()
	end

	registerProfile(player, profile)

	-- Kick if the session is stolen / released
	if typeof((profile :: any).ListenToRelease) == "function" then
		(profile :: any):ListenToRelease(function()
			unregisterProfile(player, userId)
			if shuttingDown then
				return
			end
			local stillHere = Players:GetPlayerByUserId(userId)
			if stillHere then
				task.defer(function()
					local again = Players:GetPlayerByUserId(userId)
					if again then
						again:Kick("Your data session has ended.")
					end
				end)
			end
		end)
	end

	return profile
end

-- Allows MarkDirty(playerInstance | userId [, profile])
function PersistenceServer:MarkDirty(who: Player | number | nil, profileArg: any?): boolean
	local profile: Profile? = nil
	local userId: number? = nil

	if profileArg ~= nil then
		profile = profileArg
		if typeof(who) == "Instance" and who:IsA("Player") then
			userId = who.UserId
		elseif typeof(who) == "number" then
			userId = who
		end
	else
		if typeof(who) == "Instance" and who:IsA("Player") then
			profile = profilesByPlayer[who]
			userId = who.UserId
		elseif typeof(who) == "number" then
			userId = who
			profile = profilesByUserId[who]
		end
	end

	if not profile then
		return false
	end

	return trySaveProfile(profile, userId)
end

-- Allows Save(playerInstance | userId [, releaseAfter:boolean])
function PersistenceServer:Save(who: Player | number | nil, releaseAfter: boolean?): boolean
	local profile: Profile? = nil
	local playerInstance: Player? = nil
	local userId: number? = nil

	if typeof(who) == "Instance" and who:IsA("Player") then
		playerInstance = who
		userId = who.UserId
		profile = profilesByPlayer[who]
	elseif typeof(who) == "number" then
		userId = who
		profile = profilesByUserId[who]
		playerInstance = Players:GetPlayerByUserId(who)
	else
		return false
	end

	if not profile then
		return false
	end

	local saved = self:MarkDirty(playerInstance or userId, profile)

	local shouldRelease = (releaseAfter == true) or shuttingDown or (not playerStillInGame(playerInstance))
	if shouldRelease then
		safeRelease(playerInstance, userId, profile)
	end

	return saved
end

--==============================================================
-- Wiring
--==============================================================
local function onPlayerAdded(player: Player)
	task.spawn(function()
		local prof = PersistenceServer:Load(player)
		if not prof then
			warn(("[PersistenceServer] Failed to load profile for %s"):format(player.Name))
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do
	onPlayerAdded(p)
end

Players.PlayerRemoving:Connect(function(p: Player)
	PersistenceServer:Save(p, true)
end)

game:BindToClose(function()
	shuttingDown = true

	for _, p in ipairs(Players:GetPlayers()) do
		PersistenceServer:Save(p, true)
	end

	local t0 = os.clock()
	while next(profilesByUserId) ~= nil and os.clock() - t0 < SHUTDOWN_TIMEOUT do
		task.wait(0.1)
	end

	-- Force release any stragglers
	for uid, prof in pairs(profilesByUserId) do
		safeRelease(nil, uid, prof)
	end
end)

return PersistenceServer
