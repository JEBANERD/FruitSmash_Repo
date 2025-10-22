--!strict
-- DailyRewardsServer.lua
-- Handles daily login rewards with streak-based coin bonuses and a rotating token grant.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DAY_SECONDS = 24 * 60 * 60
local MAX_STREAK = 7
local COIN_BASE = 200
local COIN_STREAK_INCREMENT = 50
local COIN_STREAK_CAP = 600
local DAILY_SAVE_VERSION = 1

local dataFolder = ServerScriptService:WaitForChild("Data")
local economyFolder = script.Parent
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local function safeRequire(moduleScript: Instance?): any
    if not moduleScript or not moduleScript:IsA("ModuleScript") then
        return nil
    end

    local ok, result = pcall(require, moduleScript)
    if not ok then
        warn(string.format("[DailyRewards] Failed to require %s: %s", moduleScript:GetFullName(), tostring(result)))
        return nil
    end

    return result
end

local SaveService = safeRequire(dataFolder:FindFirstChild("SaveService"))
local ProfileServer = safeRequire(dataFolder:FindFirstChild("ProfileServer"))
local EconomyServer = safeRequire(economyFolder:FindFirstChild("EconomyServer"))
local ShopConfig = safeRequire(configFolder:FindFirstChild("ShopConfig"))

local saveServiceLoadAsync = if SaveService and typeof((SaveService :: any).LoadAsync) == "function" then (SaveService :: any).LoadAsync else nil
local saveServiceUpdateAsync = if SaveService and typeof((SaveService :: any).UpdateAsync) == "function" then (SaveService :: any).UpdateAsync else nil
local saveServiceGetCached = if SaveService and typeof((SaveService :: any).GetCached) == "function" then (SaveService :: any).GetCached else nil

local profileGrantItem = if ProfileServer and typeof((ProfileServer :: any).GrantItem) == "function" then (ProfileServer :: any).GrantItem else nil
local profileAddCoins = if ProfileServer and typeof((ProfileServer :: any).AddCoins) == "function" then (ProfileServer :: any).AddCoins else nil
local profileSerialize = if ProfileServer and typeof((ProfileServer :: any).Serialize) == "function" then (ProfileServer :: any).Serialize else nil

local economyGrantCoins = if EconomyServer and typeof((EconomyServer :: any).GrantCoins) == "function" then (EconomyServer :: any).GrantCoins else nil

local function coerceNumber(value: any): number?
    if typeof(value) == "number" then
        return value
    end
    if typeof(value) == "string" and value ~= "" then
        local numeric = tonumber(value)
        if typeof(numeric) == "number" then
            return numeric
        end
    end
    return nil
end

local function getShopItems(): { [string]: any }
    if typeof(ShopConfig) ~= "table" then
        return {}
    end

    local cast = ShopConfig :: any
    if typeof(cast.All) == "function" then
        local ok, result = pcall(cast.All)
        if ok and type(result) == "table" then
            return result
        end
    end

    if type(cast.Items) == "table" then
        return cast.Items
    end

    return {}
end

local function buildTokenRotation(): {string}
    local sortable: { { id: string, price: number } } = {}
    local items = getShopItems()
    for id, entry in pairs(items) do
        if typeof(id) == "string" and type(entry) == "table" then
            local kind = (entry :: any).Kind
            if typeof(kind) == "string" and string.lower(kind) == "token" then
                local priceValue = math.huge
                local price = coerceNumber((entry :: any).PriceCoins)
                if typeof(price) == "number" then
                    priceValue = price
                end
                table.insert(sortable, { id = id, price = priceValue })
            end
        end
    end

    table.sort(sortable, function(a, b)
        if a.price ~= b.price then
            return a.price < b.price
        end
        return a.id < b.id
    end)

    local rotation: {string} = {}
    for _, entry in ipairs(sortable) do
        table.insert(rotation, entry.id)
    end

    if #rotation == 0 then
        rotation = {
            "Token_SpeedBoost",
            "Token_DoubleCoins",
            "Token_Shield",
            "Token_BurstClear",
        }
    end

    return rotation
end

local ROTATING_TOKENS = buildTokenRotation()

export type DailyState = {
    streak: number,
    lastClaimUtcDay: number?,
    lastClaimTimestamp: number?,
    lastTokenIndex: number?,
}

local sessionState: { [number]: DailyState } = {}
local saveUnavailableWarned = false

local function coerceNonNegativeInteger(value: any): number?
    local numeric = coerceNumber(value)
    if numeric == nil then
        return nil
    end
    if numeric < 0 then
        numeric = 0
    end
    if numeric >= 0 then
        numeric = math.floor(numeric + 0.5)
    end
    if numeric < 0 then
        numeric = 0
    end
    return numeric
end

local function sanitizeState(raw: any): DailyState
    local state: DailyState = {
        streak = 0,
        lastClaimUtcDay = nil,
        lastClaimTimestamp = nil,
        lastTokenIndex = nil,
    }

    if type(raw) ~= "table" then
        return state
    end

    local streakValue = coerceNonNegativeInteger((raw :: any).streak or (raw :: any).Streak)
    if streakValue ~= nil then
        state.streak = streakValue
    end

    local dayValue = coerceNonNegativeInteger((raw :: any).lastClaimUtcDay or (raw :: any).LastClaimUtcDay or (raw :: any).lastClaimDay or (raw :: any).LastClaimDay)
    if dayValue ~= nil then
        state.lastClaimUtcDay = dayValue
    end

    local timestampValue = coerceNonNegativeInteger((raw :: any).lastClaimTimestamp or (raw :: any).LastClaimTimestamp or (raw :: any).lastClaim or (raw :: any).LastClaim)
    if timestampValue ~= nil then
        state.lastClaimTimestamp = timestampValue
    end

    local tokenIndexValue = coerceNonNegativeInteger((raw :: any).lastTokenIndex or (raw :: any).LastTokenIndex)
    if tokenIndexValue ~= nil then
        state.lastTokenIndex = tokenIndexValue
    end

    return state
end

local function getUtcDay(timestamp: number): number
    return math.floor(timestamp / DAY_SECONDS)
end

local function getNumericUserId(player: Player): number
    local userId = player.UserId
    if typeof(userId) == "number" then
        return userId
    end
    local numeric = tonumber(userId)
    if typeof(numeric) == "number" then
        return numeric
    end
    return 0
end

local function readPayload(userId: number): any
    if saveServiceGetCached then
        local cached = saveServiceGetCached(userId)
        if cached ~= nil then
            return cached
        end
    end

    if not saveServiceLoadAsync then
        return nil
    end

    local ok, payload, loadErr = pcall(saveServiceLoadAsync, userId)
    if not ok then
        warn(string.format("[DailyRewards] Load error for %d: %s", userId, tostring(payload)))
        return nil
    end

    if loadErr then
        warn(string.format("[DailyRewards] Load failed for %d: %s", userId, tostring(loadErr)))
    end

    return payload
end

local function hasProfileShape(payload: any): boolean
    if type(payload) ~= "table" then
        return false
    end

    local cast = payload :: any
    if cast.Coins ~= nil then
        return true
    end
    if type(cast.Stats) == "table" then
        return true
    end
    if type(cast.Inventory) == "table" then
        return true
    end
    if type(cast.Settings) == "table" then
        return true
    end

    return false
end

local function normalizePayload(payload: any, player: Player?): {[string]: any}
    local container = if type(payload) == "table" then payload else {}
    local cast = container :: any

    if type(cast.Profile) ~= "table" then
        if hasProfileShape(container) then
            container = { Profile = container }
            cast = container :: any
        elseif profileSerialize and player then
            local ok, serialized = pcall(profileSerialize, player)
            if ok and type(serialized) == "table" then
                cast.Profile = serialized
            end
        end
    end

    return container
end

local function getOrCreateState(userId: number): DailyState
    local existing = sessionState[userId]
    if existing then
        return existing
    end

    local payload = readPayload(userId)
    local rawState: any = nil
    if type(payload) == "table" then
        local cast = payload :: any
        if type(cast.DailyRewards) == "table" then
            rawState = cast.DailyRewards
        elseif type(cast.Profile) == "table" then
            local profileData = cast.Profile
            if type(profileData) == "table" then
                local stats = (profileData :: any).Stats
                if type(stats) == "table" and type((stats :: any).DailyRewards) == "table" then
                    rawState = (stats :: any).DailyRewards
                end
            end
        elseif type(cast.Stats) == "table" and type((cast.Stats :: any).DailyRewards) == "table" then
            rawState = (cast.Stats :: any).DailyRewards
        end
    end

    local state = sanitizeState(rawState)
    sessionState[userId] = state
    return state
end

local function getRotationIndex(dayIndex: number): number
    local count = #ROTATING_TOKENS
    if count <= 0 then
        return 0
    end

    local modValue = dayIndex % count
    if modValue < 0 then
        modValue += count
    end

    return modValue + 1
end

local function getTokenForDay(dayIndex: number): (string?, number)
    local index = getRotationIndex(dayIndex)
    if index <= 0 then
        return nil, index
    end

    return ROTATING_TOKENS[index], index
end

local function updatePlayerAttributes(player: Player, state: DailyState, dayIndex: number, tokenId: string?)
    if not player or player.Parent == nil then
        return
    end

    player:SetAttribute("DailyRewardStreak", state.streak)
    player:SetAttribute("DailyRewardAvailable", state.lastClaimUtcDay ~= dayIndex)

    if state.lastClaimTimestamp then
        player:SetAttribute("DailyRewardLastClaim", state.lastClaimTimestamp)
    else
        player:SetAttribute("DailyRewardLastClaim", nil)
    end

    player:SetAttribute("DailyRewardNextUtc", (dayIndex + 1) * DAY_SECONDS)

    if tokenId then
        player:SetAttribute("DailyRewardTokenId", tokenId)
    else
        player:SetAttribute("DailyRewardTokenId", nil)
    end
end

local function persistState(player: Player, state: DailyState): boolean
    if not saveServiceUpdateAsync then
        if not saveUnavailableWarned then
            warn("[DailyRewards] SaveService.UpdateAsync unavailable; daily reward progress will not persist.")
            saveUnavailableWarned = true
        end
        return false
    end

    local userId = getNumericUserId(player)
    if userId <= 0 then
        return false
    end

    local ok, updatedPayload, saveErr = pcall(saveServiceUpdateAsync, userId, function(payload)
        local container = normalizePayload(payload, player)
        (container :: any).DailyRewards = {
            streak = state.streak,
            lastClaimUtcDay = state.lastClaimUtcDay,
            lastClaimTimestamp = state.lastClaimTimestamp,
            lastTokenIndex = state.lastTokenIndex,
            version = DAILY_SAVE_VERSION,
        }
        return container
    end)

    if not ok then
        warn(string.format("[DailyRewards] Save update error for %s (%d): %s", player.Name, userId, tostring(updatedPayload)))
        return false
    end

    if saveErr then
        warn(string.format("[DailyRewards] Save update failed for %s (%d): %s", player.Name, userId, tostring(saveErr)))
        return false
    end

    return true
end

local function refreshPlayer(player: Player)
    local userId = getNumericUserId(player)
    if userId <= 0 then
        return
    end

    local state = getOrCreateState(userId)
    local now = os.time()
    local dayIndex = getUtcDay(now)
    local tokenId = select(1, getTokenForDay(dayIndex))
    updatePlayerAttributes(player, state, dayIndex, tokenId)
end

local DailyRewardsServer = {}

export type ClaimReward = {
    coins: number,
    tokenId: string?,
    tokenGranted: boolean?,
    tokenError: string?,
    nextClaimUtc: number,
    summary: any?,
    persisted: boolean?,
}

export type ClaimResult = {
    ok: boolean,
    streak: number,
    reward: ClaimReward?,
    err: string?,
    alreadyClaimed: boolean?,
}

function DailyRewardsServer.Status(player: Player)
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return {
            ok = false,
            err = "InvalidPlayer",
        }
    end

    local userId = getNumericUserId(player)
    if userId <= 0 then
        return {
            ok = false,
            err = "InvalidUser",
        }
    end

    local state = getOrCreateState(userId)
    local now = os.time()
    local dayIndex = getUtcDay(now)
    local tokenId, rotationIndex = getTokenForDay(dayIndex)
    local nextUtc = (dayIndex + 1) * DAY_SECONDS
    local canClaim = state.lastClaimUtcDay ~= dayIndex

    updatePlayerAttributes(player, state, dayIndex, tokenId)

    return {
        ok = true,
        canClaim = canClaim,
        streak = state.streak,
        lastClaimUtcDay = state.lastClaimUtcDay,
        lastClaimTimestamp = state.lastClaimTimestamp,
        nextClaimUtc = nextUtc,
        tokenId = tokenId,
        rotationIndex = rotationIndex,
    }
end

function DailyRewardsServer.Refresh(player: Player)
    refreshPlayer(player)
end

function DailyRewardsServer.Claim(player: Player): ClaimResult
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        return {
            ok = false,
            streak = 0,
            reward = nil,
            err = "InvalidPlayer",
        }
    end

    local userId = getNumericUserId(player)
    if userId <= 0 then
        return {
            ok = false,
            streak = 0,
            reward = nil,
            err = "InvalidUser",
        }
    end

    local state = getOrCreateState(userId)
    local now = os.time()
    local dayIndex = getUtcDay(now)

    if state.lastClaimUtcDay == dayIndex then
        updatePlayerAttributes(player, state, dayIndex, select(1, getTokenForDay(dayIndex)))
        return {
            ok = false,
            streak = state.streak,
            reward = nil,
            err = "AlreadyClaimed",
            alreadyClaimed = true,
        }
    end

    local newStreak = if state.lastClaimUtcDay == (dayIndex - 1) then math.min(state.streak + 1, MAX_STREAK) else 1
    if newStreak < 1 then
        newStreak = 1
    end

    local streakForReward = math.clamp(newStreak, 1, MAX_STREAK)
    local coinsReward = COIN_BASE + (streakForReward - 1) * COIN_STREAK_INCREMENT
    coinsReward = math.clamp(coinsReward, 0, COIN_STREAK_CAP)

    local tokenId, tokenIndex = getTokenForDay(dayIndex)
    local tokenGranted = false
    local tokenError: string? = nil

    if tokenId and profileGrantItem then
        local ok, success, err = pcall(profileGrantItem, player, tokenId)
        if ok then
            tokenGranted = success == true
            if not success and err then
                tokenError = tostring(err)
            end
        else
            tokenError = tostring(success)
        end
    elseif tokenId then
        tokenError = "GrantUnavailable"
    end

    local summary: any = nil
    if coinsReward > 0 then
        if economyGrantCoins then
            local ok, result = pcall(economyGrantCoins, player, coinsReward, {
                reason = "DailyReward",
                streak = newStreak,
                dayIndex = dayIndex,
                tokenId = tokenId,
            })
            if ok then
                summary = result
            else
                warn(string.format("[DailyRewards] Coin grant failed for %s (%d): %s", player.Name, userId, tostring(result)))
                summary = nil
            end
        elseif profileAddCoins then
            local ok, err = pcall(profileAddCoins, player, coinsReward)
            if not ok then
                warn(string.format("[DailyRewards] Profile coin grant failed for %s (%d): %s", player.Name, userId, tostring(err)))
            end
        end
    end

    state.streak = newStreak
    state.lastClaimUtcDay = dayIndex
    state.lastClaimTimestamp = now
    state.lastTokenIndex = tokenIndex

    sessionState[userId] = state

    local persisted = persistState(player, state)

    updatePlayerAttributes(player, state, dayIndex, tokenId)

    local reward: ClaimReward = {
        coins = coinsReward,
        tokenId = tokenId,
        tokenGranted = tokenGranted,
        tokenError = tokenError,
        nextClaimUtc = (dayIndex + 1) * DAY_SECONDS,
        summary = summary,
        persisted = persisted,
    }

    return {
        ok = true,
        streak = state.streak,
        reward = reward,
    }
end

Players.PlayerAdded:Connect(function(player)
    task.defer(refreshPlayer, player)
end)

Players.PlayerRemoving:Connect(function(player)
    local userId = getNumericUserId(player)
    if userId ~= 0 then
        sessionState[userId] = nil
    end
end)

for _, player in ipairs(Players:GetPlayers()) do
    task.defer(refreshPlayer, player)
end

return DailyRewardsServer
