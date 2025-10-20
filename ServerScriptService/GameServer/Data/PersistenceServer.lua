--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local function deepCopy(value: any): any
    if typeof(value) ~= "table" then
        return value
    end

    local clone = {}
    for key, child in pairs(value) do
        clone[key] = deepCopy(child)
    end

    return clone
end

local saveSchemaModule = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"):WaitForChild("SaveSchema")
local SaveSchema = require(saveSchemaModule)
local templateSource = SaveSchema.Defaults
if typeof(templateSource) ~= "table" then
    templateSource = {}
end
local DEFAULT_TEMPLATE = deepCopy(templateSource)

local function findProfileServiceModule(): ModuleScript?
    local candidates = {
        ServerScriptService:FindFirstChild("ProfileService"),
        ServerScriptService:FindFirstChild("GameServer")
            and ServerScriptService.GameServer:FindFirstChild("Libraries")
            and ServerScriptService.GameServer.Libraries:FindFirstChild("ProfileService")
            or nil,
        ReplicatedStorage:FindFirstChild("ProfileService"),
        ReplicatedStorage:FindFirstChild("Packages")
            and ReplicatedStorage.Packages:FindFirstChild("ProfileService")
            or nil,
        ServerStorage:FindFirstChild("ProfileService"),
    }

    for _, candidate in ipairs(candidates) do
        if candidate and candidate:IsA("ModuleScript") then
            return candidate
        end
    end

    return nil
end

local profileServiceModule = findProfileServiceModule()
if not profileServiceModule then
    error("[PersistenceServer] ProfileService module not found")
end

local ProfileService = require(profileServiceModule)

local PROFILE_STORE_NAME = "PlayerData"
local MAX_LOAD_ATTEMPTS = 5
local BASE_RETRY_DELAY = 1
local MAX_RETRY_DELAY = 8
local LOAD_WAIT_INTERVAL = 0.1
local SAVE_RETRY_ATTEMPTS = 3
local SAVE_RETRY_DELAY = 0.5
local SHUTDOWN_TIMEOUT = 15

local profileStore = ProfileService.GetProfileStore(PROFILE_STORE_NAME, DEFAULT_TEMPLATE)

local base = {}
local profilesByPlayer = setmetatable({}, { __mode = "k" })
local profilesByUserId: { [number]: any } = {}
local loadingPlayers: { [number]: boolean } = {}
local shuttingDown = false

local PersistenceServer = setmetatable(base, {
    __index = function(_, key)
        if typeof(key) == "Instance" and key:IsA("Player") then
            return profilesByPlayer[key]
        elseif typeof(key) == "number" then
            return profilesByUserId[key]
        end

        return rawget(base, key)
    end,
    __newindex = function(_, key, value)
        rawset(base, key, value)
    end,
})

local function playerStillInGame(player: Player?): boolean
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return false
    end

    if player.Parent == nil then
        return false
    end

    local current = Players:GetPlayerByUserId(player.UserId)
    return current == player
end

local function registerProfile(player: Player, profile: any)
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

local function trySaveProfile(profile: any, userId: number?): boolean
    if typeof(profile.Save) ~= "function" then
        return true
    end

    local attempt = 0
    while attempt < SAVE_RETRY_ATTEMPTS do
        attempt += 1

        local ok, err = pcall(profile.Save, profile)
        if ok then
            return true
        end

        warn(string.format("[PersistenceServer] profile:Save failed for userId %s (attempt %d): %s", tostring(userId), attempt, tostring(err)))

        if attempt < SAVE_RETRY_ATTEMPTS then
            task.wait(math.min(SAVE_RETRY_DELAY * attempt, MAX_RETRY_DELAY))
        end
    end

    return false
end

local function safeRelease(player: Player?, userId: number?, profile: any)
    if not profile then
        return
    end

    unregisterProfile(player, userId)

    local isActive = true
    if typeof(profile.IsActive) == "function" then
        local ok, result = pcall(profile.IsActive, profile)
        if ok then
            isActive = result ~= false
        end
    end

    if not isActive then
        return
    end

    if typeof(profile.Release) == "function" then
        local ok, err = pcall(profile.Release, profile)
        if not ok then
            warn(string.format("[PersistenceServer] profile:Release failed for userId %s: %s", tostring(userId), tostring(err)))
        end
    end
end

local function loadProfileWithRetries(player: Player, userId: number)
    local profileKey = string.format("Player_%d", userId)
    local attempt = 0
    local profile: any?

    while attempt < MAX_LOAD_ATTEMPTS do
        attempt += 1

        if not playerStillInGame(player) then
            break
        end

        local success, result = pcall(function()
            return profileStore:LoadProfileAsync(profileKey, "ForceLoad")
        end)

        if success then
            profile = result
            if profile ~= nil then
                break
            end

            warn(string.format("[PersistenceServer] LoadProfileAsync returned nil for %s (attempt %d)", tostring(userId), attempt))
        else
            warn(string.format("[PersistenceServer] LoadProfileAsync failed for %s (attempt %d): %s", tostring(userId), attempt, tostring(result)))
        end

        if attempt < MAX_LOAD_ATTEMPTS then
            task.wait(math.min(BASE_RETRY_DELAY * 2 ^ (attempt - 1), MAX_RETRY_DELAY))
        end
    end

    return profile
end

function PersistenceServer:GetProfile(player: Player)
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return nil
    end

    return profilesByPlayer[player]
end

function PersistenceServer:Load(player: Player)
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
        warn(string.format("[PersistenceServer] Invalid userId for player %s", player.Name))
        return nil
    end

    while loadingPlayers[userId] do
        task.wait(LOAD_WAIT_INTERVAL)

        existing = profilesByPlayer[player]
        if existing then
            return existing
        end

        if not playerStillInGame(player) then
            return nil
        end
    end

    loadingPlayers[userId] = true
    local profile = loadProfileWithRetries(player, userId)
    loadingPlayers[userId] = nil

    if not profile then
        return nil
    end

    if not playerStillInGame(player) then
        safeRelease(player, userId, profile)
        return nil
    end

    if typeof(profile.AddUserId) == "function" then
        profile:AddUserId(userId)
    end

    if typeof(profile.Data) ~= "table" then
        profile.Data = deepCopy(DEFAULT_TEMPLATE)
    end

    if typeof(profile.Reconcile) == "function" then
        profile:Reconcile()
    end

    registerProfile(player, profile)

    if typeof(profile.ListenToRelease) == "function" then
        profile:ListenToRelease(function()
            unregisterProfile(player, userId)

            if shuttingDown then
                return
            end

            local current = Players:GetPlayerByUserId(userId)
            if current then
                task.defer(function()
                    local stillPresent = Players:GetPlayerByUserId(userId)
                    if stillPresent then
                        stillPresent:Kick("Your data session has ended.")
                    end
                end)
            end
        end)
    end

    return profile
end

function PersistenceServer:MarkDirty(player: Player | number | nil, profile: any?)
    local resolvedProfile = profile
    local userId: number?

    if resolvedProfile == nil then
        if typeof(player) == "Instance" and player:IsA("Player") then
            resolvedProfile = profilesByPlayer[player]
            userId = player.UserId
        elseif typeof(player) == "number" then
            resolvedProfile = profilesByUserId[player]
            userId = player
        end
    else
        if typeof(player) == "Instance" and player:IsA("Player") then
            userId = player.UserId
        elseif typeof(player) == "number" then
            userId = player
        end
    end

    if resolvedProfile == nil then
        return false
    end

    return trySaveProfile(resolvedProfile, userId)
end

function PersistenceServer:Save(player: Player | number | nil, releaseAfter: boolean?)
    local targetProfile: any
    local playerInstance: Player?
    local userId: number?

    if typeof(player) == "Instance" and player:IsA("Player") then
        playerInstance = player
        targetProfile = profilesByPlayer[player]
        userId = player.UserId
    elseif typeof(player) == "number" then
        userId = player
        targetProfile = profilesByUserId[player]
        playerInstance = Players:GetPlayerByUserId(player)
    else
        return false
    end

    if targetProfile == nil then
        return false
    end

    local saved = self:MarkDirty(playerInstance or userId, targetProfile)

    local shouldRelease = releaseAfter == true or shuttingDown or not playerStillInGame(playerInstance)
    if shouldRelease then
        safeRelease(playerInstance, userId, targetProfile)
    end

    return saved
end

local function onPlayerAdded(player: Player)
    task.spawn(function()
        local profile = PersistenceServer:Load(player)
        if not profile then
            warn(string.format("[PersistenceServer] Failed to load profile for %s", player.Name))
        end
    end)
end

Players.PlayerAdded:Connect(onPlayerAdded)

for _, player in ipairs(Players:GetPlayers()) do
    onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
    PersistenceServer:Save(player, true)
end)

game:BindToClose(function()
    shuttingDown = true

    local players = Players:GetPlayers()
    for _, player in ipairs(players) do
        PersistenceServer:Save(player, true)
    end

    local startTime = os.clock()
    while next(profilesByUserId) ~= nil and os.clock() - startTime < SHUTDOWN_TIMEOUT do
        task.wait(0.1)
    end

    for userId, profile in pairs(profilesByUserId) do
        safeRelease(nil, userId, profile)
    end
end)

return PersistenceServer
