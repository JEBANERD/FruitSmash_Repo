--!strict
-- ProfileServer
-- Session-scoped profile storage for coins, points, melee inventory, and consumable tokens.
-- Provides a thin facade while persistence is under development.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local typesFolder = sharedFolder:WaitForChild("Types")
local systemsFolder = sharedFolder:WaitForChild("Systems")
local Localizer = require(systemsFolder:WaitForChild("Localizer"))

local function safeRequire(moduleScript: Instance?): any?
    if not moduleScript or not moduleScript:IsA("ModuleScript") then
        return nil
    end

    local ok, result = pcall(require, moduleScript)
    if not ok then
        warn(string.format("[ProfileServer] Failed to require %s: %s", moduleScript:GetFullName(), tostring(result)))
        return nil
    end

    return result
end

local function findFirstChildPath(root: Instance?, parts: {string}): Instance?
    local current: Instance? = root
    for _, name in ipairs(parts) do
        if not current then
            return nil
        end
        current = current:FindFirstChild(name)
    end
    return current
end

local saveServiceModule = script.Parent:FindFirstChild("SaveService")
local SaveService = if saveServiceModule then safeRequire(saveServiceModule) else nil
local saveServiceLoadAsync = if SaveService and typeof((SaveService :: any).LoadAsync) == "function" then (SaveService :: any).LoadAsync else nil
local saveServiceSaveAsync = if SaveService and typeof((SaveService :: any).SaveAsync) == "function" then (SaveService :: any).SaveAsync else nil
local saveServiceUpdateAsync = if SaveService and typeof((SaveService :: any).UpdateAsync) == "function" then (SaveService :: any).UpdateAsync else nil
local saveServiceRegisterCheckpoint = if SaveService and typeof((SaveService :: any).RegisterCheckpointProvider) == "function"
    then (SaveService :: any).RegisterCheckpointProvider
    else nil

local SaveSchemaModule = safeRequire(typesFolder:FindFirstChild("SaveSchema"))
local ShopConfigModule = safeRequire(configFolder:FindFirstChild("ShopConfig"))

local saveDefaults = if type(SaveSchemaModule) == "table" and type(SaveSchemaModule.Defaults) == "table"
    then SaveSchemaModule.Defaults
    else {}

local shopItems = (typeof(ShopConfigModule) == "table" and typeof((ShopConfigModule :: any).All) == "function"
        and (ShopConfigModule :: any).All())
    or (typeof(ShopConfigModule) == "table" and (ShopConfigModule :: any).Items)
    or {}

local GameConfigModule = safeRequire(configFolder:FindFirstChild("GameConfig"))
local GameConfig = if typeof(GameConfigModule) == "table" and typeof((GameConfigModule :: any).Get) == "function"
        then (GameConfigModule :: any).Get()
        else GameConfigModule

local playerSection = if typeof(GameConfig) == "table" then (GameConfig :: any).Player else nil
local settingsConfig = if typeof(playerSection) == "table" then (playerSection :: any).Settings else nil
local settingsDefaultsConfig = if typeof(settingsConfig) == "table" then (settingsConfig :: any).Defaults else nil
local settingsLimitsConfig = if typeof(settingsConfig) == "table" then (settingsConfig :: any).Limits else nil
local settingsPalettesConfig = if typeof(settingsConfig) == "table" then (settingsConfig :: any).ColorblindPalettes else nil

local paletteIds: {string} = {}
local paletteLookup: {[string]: string} = {}

local TUTORIAL_STAT_KEY = "TutorialCompleted"

type TokenCounts = { [string]: number }
type OwnedMeleeMap = { [string]: boolean }

type PlayerSettings = {
        SprintToggle: boolean,
        AimAssistWindow: number,
        CameraShakeStrength: number,
        ColorblindPalette: string,
        TextScale: number,
        Locale: string,
}

type Inventory = {
    MeleeLoadout: {string},
    ActiveMelee: string?,
    TokenCounts: TokenCounts,
    UtilityQueue: {string},
    OwnedMelee: OwnedMeleeMap,
}

type ProfileData = {
    Coins: number,
    Stats: { [string]: any },
    Inventory: Inventory,
    Settings: PlayerSettings,
}

type Profile = {
    Player: Player,
    UserId: number,
    Data: ProfileData,
}

type SaveContainer = {[string]: any}

type MigrationContext = {
    player: Player?,
    userId: number,
    fromVersion: number,
    toVersion: number,
}

type MigrationHandler = (SaveContainer, MigrationContext) -> ()

local DEFAULT_SCHEMA_VERSION = 1
local CURRENT_SCHEMA_VERSION = DEFAULT_SCHEMA_VERSION

local schemaMigrations: {[number]: MigrationHandler} = {}
local migrationInfoLogged: {[number]: boolean} = {}
local migrationWarnLogged: {[number]: boolean} = {}

local function normalizeSchemaVersion(value: any): number?
    if typeof(value) == "number" then
        if value ~= value then
            return nil
        end
        return math.floor(value)
    elseif typeof(value) == "string" and value ~= "" then
        local numeric = tonumber(value)
        if typeof(numeric) == "number" then
            return math.floor(numeric)
        end
    end

    return nil
end

local function parseSchemaVersion(value: any): number
    local normalized = normalizeSchemaVersion(value)
    if normalized == nil then
        return 0
    end

    if normalized < 0 then
        return 0
    end

    return normalized
end

local function logMigrationStep(fromVersion: number, toVersion: number)
    if migrationInfoLogged[toVersion] then
        return
    end

    migrationInfoLogged[toVersion] = true
    print(string.format("[ProfileServer] Applying profile schema migration v%d -> v%d", fromVersion, toVersion))
end

local function warnMissingMigration(fromVersion: number, toVersion: number, userId: number)
    if migrationWarnLogged[toVersion] then
        return
    end

    migrationWarnLogged[toVersion] = true
    warn(string.format(
        "[ProfileServer] Missing profile schema migration v%d -> v%d; profile for user %d will reset to defaults.",
        fromVersion,
        toVersion,
        userId
    ))
end

local function registerMigrationInternal(versionValue: any, handler: any): (() -> ())?
    if typeof(handler) ~= "function" then
        return nil
    end

    local normalized = normalizeSchemaVersion(versionValue)
    if normalized == nil then
        return nil
    end

    if normalized < 0 then
        normalized = 0
    end

    schemaMigrations[normalized] = handler :: MigrationHandler

    return function()
        if schemaMigrations[normalized] == handler then
            schemaMigrations[normalized] = nil
        end
    end
end

if typeof(SaveSchemaModule) == "table" then
    local versionValue = (SaveSchemaModule :: any).SchemaVersion or (SaveSchemaModule :: any).Version
    local resolvedVersion = normalizeSchemaVersion(versionValue)
    if resolvedVersion then
        CURRENT_SCHEMA_VERSION = math.max(DEFAULT_SCHEMA_VERSION, resolvedVersion)
    end

    local migrationsValue = (SaveSchemaModule :: any).Migrations
    if typeof(migrationsValue) == "table" then
        for key, handler in pairs(migrationsValue) do
            registerMigrationInternal(key, handler)
        end
    end
end

local function hasProfileShape(payload: any): boolean
    if type(payload) ~= "table" then
        return false
    end

    if payload.Coins ~= nil then
        return true
    end

    if type(payload.Stats) == "table" then
        return true
    end

    if type(payload.Inventory) == "table" then
        return true
    end

    if type(payload.Settings) == "table" then
        return true
    end

    return false
end

local function resolveSerializedProfile(payload: any): ProfileData?
    if type(payload) ~= "table" then
        return nil
    end

    local embedded = (payload :: any).Profile
    if type(embedded) == "table" then
        return embedded
    end

    if hasProfileShape(payload) then
        return payload
    end

    return nil
end

local function ensureSaveContainer(payload: any): {[string]: any}
    if type(payload) ~= "table" then
        return {}
    end

    local cast = payload :: any
    if type(cast.Profile) == "table" or type(cast.DailyRewards) == "table" then
        return cast
    end

    if hasProfileShape(payload) then
        return { Profile = payload }
    end

    return cast
end

if typeof(settingsPalettesConfig) == "table" then
        for _, entry in ipairs(settingsPalettesConfig) do
                if typeof(entry) == "table" then
                        local idValue = (entry :: any).Id or (entry :: any).id or (entry :: any).Name or (entry :: any).name
                        if typeof(idValue) == "string" and idValue ~= "" then
                                local id = idValue
                                if not paletteLookup[id] then
                                        table.insert(paletteIds, id)
                                end
                                paletteLookup[id] = id
                                paletteLookup[string.lower(id)] = id
                        end
                end
        end
end

if #paletteIds == 0 then
        table.insert(paletteIds, "Off")
        paletteLookup["Off"] = "Off"
        paletteLookup[string.lower("Off")] = "Off"
end

local function resolveLimit(key: string): (number?, number?)
        if typeof(settingsLimitsConfig) ~= "table" then
                return nil, nil
        end

        local entry = (settingsLimitsConfig :: any)[key]
        if typeof(entry) ~= "table" then
                return nil, nil
        end

        local minValue = (entry :: any).Min
        local maxValue = (entry :: any).Max

        local minNumeric = if typeof(minValue) == "number" then minValue else tonumber(minValue)
        local maxNumeric = if typeof(maxValue) == "number" then maxValue else tonumber(maxValue)

        return minNumeric, maxNumeric
end

local function clampSettingNumeric(value: number, key: string, fallback: number): number
        local minValue, maxValue = resolveLimit(key)
        local numeric = value
        if typeof(numeric) ~= "number" then
                numeric = fallback
        end
        if minValue then
                numeric = math.max(minValue, numeric)
        end
        if maxValue then
                numeric = math.min(maxValue, numeric)
        end
        return numeric
end

local function resolveNumericDefault(value: any, key: string, fallback: number): number
        local numeric = if typeof(value) == "number" then value else tonumber(value)
        if typeof(numeric) ~= "number" then
                numeric = fallback
        end
        return clampSettingNumeric(numeric :: number, key, fallback)
end

local function resolvePaletteId(value: any, fallback: string): string
        if typeof(value) == "string" and value ~= "" then
                local direct = paletteLookup[value]
                if direct then
                        return direct
                end
                local lowered = string.lower(value)
                local fromLower = paletteLookup[lowered]
                if fromLower then
                        return fromLower
                end
        end
        return fallback
end

local defaultPaletteId = if paletteLookup["Off"] then "Off" else paletteIds[1]
if typeof(settingsDefaultsConfig) == "table" then
        defaultPaletteId = resolvePaletteId((settingsDefaultsConfig :: any).ColorblindPalette, defaultPaletteId)
end
if not paletteLookup[defaultPaletteId] then
        defaultPaletteId = paletteIds[1]
end

local DEFAULT_PLAYER_SETTINGS: PlayerSettings = {
        SprintToggle = typeof(settingsDefaultsConfig) == "table" and (settingsDefaultsConfig :: any).SprintToggle == true or false,
        AimAssistWindow = resolveNumericDefault(
                typeof(settingsDefaultsConfig) == "table" and (settingsDefaultsConfig :: any).AimAssistWindow or nil,
                "AimAssistWindow",
                0.75
        ),
        CameraShakeStrength = resolveNumericDefault(
                typeof(settingsDefaultsConfig) == "table" and (settingsDefaultsConfig :: any).CameraShakeStrength or nil,
                "CameraShakeStrength",
                0.7
        ),
        ColorblindPalette = resolvePaletteId(
                typeof(settingsDefaultsConfig) == "table" and (settingsDefaultsConfig :: any).ColorblindPalette or nil,
                defaultPaletteId
        ),
        TextScale = resolveNumericDefault(
                typeof(settingsDefaultsConfig) == "table" and (settingsDefaultsConfig :: any).TextScale or nil,
                "TextScale",
                1
        ),
        Locale = Localizer.getDefaultLocale(),
}

local function copySettingsData(settings: PlayerSettings?): PlayerSettings
        local source = settings or DEFAULT_PLAYER_SETTINGS
        return {
                SprintToggle = source.SprintToggle,
                AimAssistWindow = source.AimAssistWindow,
                CameraShakeStrength = source.CameraShakeStrength,
                ColorblindPalette = source.ColorblindPalette,
                TextScale = source.TextScale,
                Locale = source.Locale,
        }
end

local function sanitizeSettingsData(raw: any): PlayerSettings
        local sanitized = copySettingsData(nil)
        if typeof(raw) ~= "table" then
                return sanitized
        end

        if raw.SprintToggle ~= nil then
                sanitized.SprintToggle = raw.SprintToggle == true
        end

        local aimValue = raw.AimAssistWindow or raw.AimAssist or raw.AimAssistRadius
        if aimValue ~= nil then
                sanitized.AimAssistWindow = resolveNumericDefault(aimValue, "AimAssistWindow", sanitized.AimAssistWindow)
        end

        local shakeValue = raw.CameraShakeStrength or raw.CameraShake
        if shakeValue ~= nil then
                sanitized.CameraShakeStrength = resolveNumericDefault(shakeValue, "CameraShakeStrength", sanitized.CameraShakeStrength)
        end

        local textScaleValue = raw.TextScale or raw.TextSize or raw.TextSizeScale
        if textScaleValue ~= nil then
                sanitized.TextScale = resolveNumericDefault(textScaleValue, "TextScale", sanitized.TextScale)
        end

        if raw.ColorblindPalette ~= nil then
                sanitized.ColorblindPalette = resolvePaletteId(raw.ColorblindPalette, sanitized.ColorblindPalette)
        end

        if raw.Locale ~= nil then
                sanitized.Locale = Localizer.normalizeLocale(raw.Locale)
        end

        return sanitized
end

local ProfileServer = {}

local profilesByPlayer: { [Player]: Profile } = {}
local profilesByUserId: { [number]: Profile } = {}

local function deepCopy(value: any, seen: {[any]: any}?): any
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy: {[any]: any} = {}
    seen[value] = copy

    for key, subValue in pairs(value) do
        copy[deepCopy(key, seen)] = deepCopy(subValue, seen)
    end

    return copy
end

local function sanitizeStringList(list: any): {string}
    local result: {string} = {}
    if type(list) ~= "table" then
        return result
    end

    for _, item in ipairs(list) do
        if type(item) == "string" and item ~= "" then
            table.insert(result, item)
        end
    end

    return result
end

local function sanitizeTokenCounts(map: any): TokenCounts
    local counts: TokenCounts = {}
    if type(map) ~= "table" then
        return counts
    end

    for tokenId, count in pairs(map) do
        if type(tokenId) == "string" and tokenId ~= "" then
            local numeric = if type(count) == "number" then count else tonumber(count)
            if type(numeric) == "number" then
                counts[tokenId] = math.max(0, math.floor(numeric + 0.5))
            end
        end
    end

    return counts
end

local function sanitizeOwnedMelee(map: any): OwnedMeleeMap
    local owned: OwnedMeleeMap = {}
    if type(map) ~= "table" then
        return owned
    end

    for meleeId, flag in pairs(map) do
        if type(meleeId) == "string" and meleeId ~= "" and flag then
            owned[meleeId] = true
        end
    end

    return owned
end

local function buildDefaultData(): ProfileData
    local data: ProfileData = {
        Coins = 0,
        Stats = {},
        Inventory = {
            MeleeLoadout = {},
            ActiveMelee = nil,
            TokenCounts = {},
            UtilityQueue = {},
            OwnedMelee = {},
        },
        Settings = copySettingsData(nil),
    }

    if type(saveDefaults) == "table" then
        local cloned = deepCopy(saveDefaults)
        if type(cloned.Coins) == "number" then
            data.Coins = cloned.Coins
        end

        if type(cloned.Stats) == "table" then
            data.Stats = cloned.Stats
        end

        if type(cloned.Inventory) == "table" then
            local inventory = cloned.Inventory
            data.Inventory.MeleeLoadout = sanitizeStringList(inventory.MeleeLoadout)
            data.Inventory.ActiveMelee = if type(inventory.ActiveMelee) == "string" then inventory.ActiveMelee else nil
            data.Inventory.TokenCounts = sanitizeTokenCounts(inventory.TokenCounts)
            data.Inventory.UtilityQueue = sanitizeStringList(inventory.UtilityQueue)
            data.Inventory.OwnedMelee = sanitizeOwnedMelee(inventory.OwnedMelee)
        end
        if type(cloned.Settings) == "table" then
            data.Settings = sanitizeSettingsData(cloned.Settings)
        end
    end

    local stats = data.Stats
    if type(stats) ~= "table" then
        stats = {}
        data.Stats = stats
    end
    if type(stats.TotalPoints) ~= "number" then
        stats.TotalPoints = 0
    end

    if stats[TUTORIAL_STAT_KEY] ~= true then
        stats[TUTORIAL_STAT_KEY] = false
    end

    local inventory = data.Inventory
    inventory.MeleeLoadout = inventory.MeleeLoadout or {}
    inventory.TokenCounts = inventory.TokenCounts or {}
    inventory.UtilityQueue = inventory.UtilityQueue or {}
    inventory.OwnedMelee = inventory.OwnedMelee or {}

    data.Settings = sanitizeSettingsData(data.Settings)

    return data
end

local function runSchemaMigrations(container: SaveContainer, player: Player?, userId: number): SaveContainer
    if typeof(container) ~= "table" then
        container = {}
    end

    local targetVersion = CURRENT_SCHEMA_VERSION
    local currentVersion = parseSchemaVersion((container :: any).SchemaVersion)

    if currentVersion >= targetVersion then
        (container :: any).SchemaVersion = targetVersion
        return container
    end

    local context: MigrationContext = {
        player = player,
        userId = userId,
        fromVersion = currentVersion,
        toVersion = currentVersion,
    }

    local version = currentVersion
    while version < targetVersion do
        local nextVersion = version + 1
        local handler = schemaMigrations[version]
        if handler then
            logMigrationStep(version, nextVersion)
            context.fromVersion = version
            context.toVersion = nextVersion
            local ok, err = pcall(handler, container, context)
            if not ok then
                warn(string.format(
                    "[ProfileServer] Migration v%d -> v%d failed for user %d: %s",
                    version,
                    nextVersion,
                    userId,
                    tostring(err)
                ))
                break
            end
        else
            if version >= DEFAULT_SCHEMA_VERSION then
                warnMissingMigration(version, nextVersion, userId);
                (container :: any).Profile = buildDefaultData()
            end
        end
        version = nextVersion
    end

    if version >= targetVersion then
        (container :: any).SchemaVersion = targetVersion
    else
        (container :: any).SchemaVersion = version
    end

    return container
end

local function ensureTutorialStat(stats: { [string]: any }?): boolean
    if type(stats) ~= "table" then
        return false
    end

    local completed = stats[TUTORIAL_STAT_KEY] == true
    stats[TUTORIAL_STAT_KEY] = completed
    return completed
end

local function ensureStats(data: ProfileData): { [string]: any }
    local stats = data.Stats
    if type(stats) ~= "table" then
        stats = {}
        data.Stats = stats
    end

    if type(stats.TotalPoints) ~= "number" then
        stats.TotalPoints = 0
    end

    ensureTutorialStat(stats)

    return stats
end

local tutorialAttrWarned = false

local function syncTutorialAttribute(player: Player?, data: ProfileData?): boolean
    local stats: { [string]: any }? = nil
    if type(data) == "table" then
        stats = ensureStats(data)
    end

    local completed = false
    if stats then
        completed = ensureTutorialStat(stats)
    end

    if player and player:IsA("Player") then
        local ok, err = pcall(function()
            player:SetAttribute(TUTORIAL_STAT_KEY, completed)
        end)
        if not ok and not tutorialAttrWarned then
            tutorialAttrWarned = true
            warn(string.format("[ProfileServer] Failed to set %s attribute for %s: %s", TUTORIAL_STAT_KEY, player.Name, tostring(err)))
        end
    end

    return completed
end

local function ensureInventory(data: ProfileData): Inventory
    if type(data.Inventory) ~= "table" then
        data.Inventory = buildDefaultData().Inventory
    end

    local inventory = data.Inventory
    if type(inventory.MeleeLoadout) ~= "table" then
        inventory.MeleeLoadout = {}
    end
    if type(inventory.TokenCounts) ~= "table" then
        inventory.TokenCounts = {}
    end
    if type(inventory.UtilityQueue) ~= "table" then
        inventory.UtilityQueue = {}
    end
    if type(inventory.OwnedMelee) ~= "table" then
        inventory.OwnedMelee = {}
    end

    return inventory
end

local cachedQuickbar: any? = nil
local quickbarWarned = false
local function getQuickbarServer(): any?
    if cachedQuickbar ~= nil then
        return cachedQuickbar
    end

    local gameServerFolder = ServerScriptService:FindFirstChild("GameServer")
    if not gameServerFolder then
        return nil
    end

    local moduleScript = gameServerFolder:FindFirstChild("QuickbarServer")
    if not moduleScript or not moduleScript:IsA("ModuleScript") then
        return nil
    end

    local ok, quickbar = pcall(require, moduleScript)
    if ok then
        cachedQuickbar = quickbar
        return quickbar
    else
        if not quickbarWarned then
            warn(string.format("[ProfileServer] Failed to require QuickbarServer: %s", tostring(quickbar)))
            quickbarWarned = true
        end
        return nil
    end
end

local function refreshQuickbar(player: Player, data: ProfileData?, inventory: Inventory?)
    local quickbar = getQuickbarServer()
    if not quickbar then
        return
    end

    local refresh = (quickbar :: any).Refresh
    if type(refresh) ~= "function" then
        return
    end

    local ok, err = pcall(function()
        refresh(player, data, inventory)
    end)
    if not ok then
        warn(string.format("[ProfileServer] Quickbar refresh failed: %s", tostring(err)))
    end
end

local economyCandidates = {
    { "Economy", "EconomyServer" },
    { "GameServer", "Economy", "EconomyServer" },
    { "EconomyServer" },
}

local cachedEconomy: any? = nil
local attemptedEconomy = false
local function getEconomyServer(): any?
    if cachedEconomy ~= nil then
        return cachedEconomy
    end

    if attemptedEconomy then
        return nil
    end

    attemptedEconomy = true

    for _, parts in ipairs(economyCandidates) do
        local instance = findFirstChildPath(ServerScriptService, parts)
        local module = safeRequire(instance)
        if module then
            cachedEconomy = module
            attemptedEconomy = false
            return cachedEconomy
        end
    end

    attemptedEconomy = false
    return nil
end

local function coerceWholeNumber(value: any): number?
    local numeric = if type(value) == "number" then value else tonumber(value)
    if type(numeric) ~= "number" then
        return nil
    end

    if numeric ~= numeric then -- NaN guard
        return nil
    end

    local integer = math.floor(numeric + 0.5)
    if integer < 0 then
        integer = 0
    end

    return integer
end

local attributeConnections: { [Player]: { Coins: RBXScriptConnection?, Points: RBXScriptConnection? } } = {}

local function disconnectAttributeConnections(player: Player)
    local connections = attributeConnections[player]
    if not connections then
        return
    end

    if connections.Coins then
        connections.Coins:Disconnect()
    end
    if connections.Points then
        connections.Points:Disconnect()
    end

    attributeConnections[player] = nil
end

local function applyCoinsFromValue(data: ProfileData, value: any): boolean
    local numeric = coerceWholeNumber(value)
    if numeric == nil then
        return false
    end

    if type(data.Coins) ~= "number" or data.Coins ~= numeric then
        data.Coins = numeric
        return true
    end

    return false
end

local function applyPointsFromValue(data: ProfileData, value: any): boolean
    local numeric = coerceWholeNumber(value)
    if numeric == nil then
        return false
    end

    local stats = ensureStats(data)
    if stats.TotalPoints ~= numeric then
        stats.TotalPoints = numeric
        return true
    end

    return false
end

local function applyEconomySnapshot(player: Player, data: ProfileData)
    local coinsChanged = false
    local pointsChanged = false

    local economyServer = getEconomyServer()
    if economyServer then
        local totalsFn = (economyServer :: any).Totals
        if type(totalsFn) == "function" then
            local ok, totals = pcall(totalsFn, economyServer, player)
            if not ok then
                ok, totals = pcall(totalsFn, player)
            end
            if ok and type(totals) == "table" then
                coinsChanged = applyCoinsFromValue(data, totals.coins) or coinsChanged
                pointsChanged = applyPointsFromValue(data, totals.points) or pointsChanged
            end
        end
    end

    coinsChanged = applyCoinsFromValue(data, player:GetAttribute("Coins")) or coinsChanged
    pointsChanged = applyPointsFromValue(data, player:GetAttribute("Points")) or pointsChanged

    if coinsChanged then
        refreshQuickbar(player, data, ensureInventory(data))
    end

end

local function connectAttributeTracking(player: Player, profile: Profile)
    disconnectAttributeConnections(player)

    local connections = {
        Coins = player:GetAttributeChangedSignal("Coins"):Connect(function()
            local currentProfile = profilesByPlayer[player]
            if not currentProfile then
                return
            end

            local data = currentProfile.Data
            if type(data) ~= "table" then
                currentProfile.Data = buildDefaultData()
                data = currentProfile.Data
            end

            if applyCoinsFromValue(data, player:GetAttribute("Coins")) then
                refreshQuickbar(player, data, ensureInventory(data))
            end
        end),
        Points = player:GetAttributeChangedSignal("Points"):Connect(function()
            local currentProfile = profilesByPlayer[player]
            if not currentProfile then
                return
            end

            local data = currentProfile.Data
            if type(data) ~= "table" then
                currentProfile.Data = buildDefaultData()
                data = currentProfile.Data
            end

            applyPointsFromValue(data, player:GetAttribute("Points"))
        end),
    }

    attributeConnections[player] = connections

    local data = profile.Data
    if type(data) ~= "table" then
        profile.Data = buildDefaultData()
        data = profile.Data
    end

    applyEconomySnapshot(player, data)
end

local function ensureProfile(player: Player): Profile
    local existing = profilesByPlayer[player]
    if existing then
        if not attributeConnections[player] then
            connectAttributeTracking(player, existing)
        end
        syncTutorialAttribute(player, existing.Data)
        return existing
    end

    local data = buildDefaultData()
    local profile: Profile = {
        Player = player,
        UserId = player.UserId,
        Data = data,
    }

    profilesByPlayer[player] = profile
    profilesByUserId[player.UserId] = profile

    syncTutorialAttribute(player, data)

    connectAttributeTracking(player, profile)

    return profile
end

local function removeProfile(player: Player)
    profilesByPlayer[player] = nil
    local userId = player.UserId
    if userId ~= 0 then
        profilesByUserId[userId] = nil
    end

    disconnectAttributeConnections(player)
end

local function refreshQuickbarForPlayer(player: Player)
    local profile = ensureProfile(player)
    local data = profile.Data
    local inventory = ensureInventory(data)
    refreshQuickbar(player, data, inventory)
end

local function getTokenCounts(inventory: Inventory): TokenCounts
    if type(inventory.TokenCounts) ~= "table" then
        inventory.TokenCounts = {}
    end
    return inventory.TokenCounts
end

local function getOwnedMelee(inventory: Inventory): OwnedMeleeMap
    if type(inventory.OwnedMelee) ~= "table" then
        inventory.OwnedMelee = {}
    end
    return inventory.OwnedMelee
end

local function insertUniqueMelee(loadout: {string}, meleeId: string)
    for _, existing in ipairs(loadout) do
        if existing == meleeId then
            return
        end
    end
    table.insert(loadout, meleeId)
end

function ProfileServer.Get(player: Player): Profile
    assert(typeof(player) == "Instance" and player:IsA("Player"), "ProfileServer.Get expects a Player")
    return ensureProfile(player)
end

ProfileServer.GetProfile = ProfileServer.Get

function ProfileServer.GetData(player: Player): ProfileData
    return ProfileServer.Get(player).Data
end

function ProfileServer.GetInventory(player: Player): Inventory
    local profile = ProfileServer.Get(player)
    return ensureInventory(profile.Data)
end

function ProfileServer.GetProfileAndInventory(player: Player): (Profile, ProfileData, Inventory)
    local profile = ProfileServer.Get(player)
    local data = profile.Data
    local inventory = ensureInventory(data)
    return profile, data, inventory
end

function ProfileServer.AddCoins(player: Player, amount: number?): number
    local profile = ProfileServer.Get(player)
    local data = profile.Data
    local numeric = if type(amount) == "number" then amount else tonumber(amount)
    if type(numeric) ~= "number" then
        return data.Coins or 0
    end

    local delta = math.floor(numeric)
    if delta <= 0 then
        return data.Coins or 0
    end

    local current = if type(data.Coins) == "number" then data.Coins else 0
    local newTotal = current + delta
    data.Coins = math.max(0, newTotal)

    refreshQuickbar(player, data, ensureInventory(data))

    return data.Coins
end

function ProfileServer.SpendCoins(player: Player, amount: number?): (boolean, string?)
    local profile = ProfileServer.Get(player)
    local data = profile.Data
    local numeric = if type(amount) == "number" then amount else tonumber(amount)
    if type(numeric) ~= "number" then
        return false, "InvalidAmount"
    end

    local cost = math.floor(numeric)
    if cost <= 0 then
        return false, "InvalidAmount"
    end

    local current = if type(data.Coins) == "number" then data.Coins else 0
    if current < cost then
        return false, "NotEnough"
    end

    data.Coins = current - cost
    refreshQuickbar(player, data, ensureInventory(data))

    return true, nil
end

local function coerceCount(value: any): number
    if type(value) == "number" then
        return value
    end
    local numeric = tonumber(value)
    if type(numeric) == "number" then
        return numeric
    end
    return 0
end

function ProfileServer.GrantItem(player: Player, itemId: string): (boolean, string?)
    if type(itemId) ~= "string" or itemId == "" then
        return false, "InvalidItem"
    end

    local itemInfo = shopItems[itemId]
    if type(itemInfo) ~= "table" then
        return false, "UnknownItem"
    end

    local _, data, inventory = ProfileServer.GetProfileAndInventory(player)
    local kind = if type(itemInfo.Kind) == "string" then itemInfo.Kind else ""

    if kind == "Melee" then
        local owned = getOwnedMelee(inventory)
        if owned[itemId] then
            return false, "AlreadyOwned"
        end
        owned[itemId] = true
        insertUniqueMelee(inventory.MeleeLoadout, itemId)
        if type(inventory.ActiveMelee) ~= "string" or inventory.ActiveMelee == "" then
            inventory.ActiveMelee = itemId
        end
        refreshQuickbar(player, data, inventory)
        return true, nil
    elseif kind == "Token" then
        local counts = getTokenCounts(inventory)
        local current = math.max(0, math.floor(coerceCount(counts[itemId])))
        local increment = if type(itemInfo.Count) == "number" and itemInfo.Count > 0 then math.floor(itemInfo.Count) else 1
        if increment <= 0 then
            increment = 1
        end

        local stackLimit = if type(itemInfo.StackLimit) == "number" then math.max(0, math.floor(itemInfo.StackLimit)) else nil
        if stackLimit and current >= stackLimit then
            return false, "StackLimit"
        end

        local newCount = current + increment
        if stackLimit then
            newCount = math.clamp(newCount, 0, stackLimit)
        end
        counts[itemId] = newCount

        refreshQuickbar(player, data, inventory)
        return true, nil
    elseif kind == "Utility" then
        table.insert(inventory.UtilityQueue, itemId)
        refreshQuickbar(player, data, inventory)
        return true, nil
    end

    return false, "UnsupportedKind"
end

function ProfileServer.ConsumeToken(player: Player, itemId: string): (boolean, string?)
    if type(itemId) ~= "string" or itemId == "" then
        return false, "InvalidItem"
    end

    local _, data, inventory = ProfileServer.GetProfileAndInventory(player)
    local counts = getTokenCounts(inventory)
    local current = math.max(0, math.floor(coerceCount(counts[itemId])))
    if current <= 0 then
        return false, "NoToken"
    end

    local newCount = current - 1
    if newCount <= 0 then
        counts[itemId] = nil
    else
        counts[itemId] = newCount
    end

    refreshQuickbar(player, data, inventory)

    return true, nil
end

local function serializeProfileData(profile: Profile?): ProfileData?
    if typeof(profile) ~= "table" then
        return nil
    end

    local data = profile.Data
    if type(data) ~= "table" then
        return nil
    end

    local inventory = ensureInventory(data)
    local serialized: ProfileData = {
        Coins = if type(data.Coins) == "number" then data.Coins else 0,
        Stats = if type(data.Stats) == "table" then deepCopy(data.Stats) else {},
        Inventory = {
            MeleeLoadout = sanitizeStringList(inventory.MeleeLoadout),
            ActiveMelee = if type(inventory.ActiveMelee) == "string" and inventory.ActiveMelee ~= "" then inventory.ActiveMelee else nil,
            TokenCounts = sanitizeTokenCounts(inventory.TokenCounts),
            UtilityQueue = sanitizeStringList(inventory.UtilityQueue),
            OwnedMelee = sanitizeOwnedMelee(inventory.OwnedMelee),
        },
        Settings = copySettingsData(data.Settings),
    }

    return serialized
end

local function upsertSerializedProfile(payload: any, serialized: ProfileData): SaveContainer
    local container = ensureSaveContainer(payload)
    (container :: any).SchemaVersion = CURRENT_SCHEMA_VERSION
    (container :: any).Profile = serialized
    return container
end

function ProfileServer.Serialize(player: Player): ProfileData
    local profile = profilesByPlayer[player]
    local serialized = serializeProfileData(profile)
    if serialized then
        return serialized
    end

    return buildDefaultData()
end

function ProfileServer.LoadSerialized(player: Player, serialized: ProfileData?)
    local profile = ensureProfile(player)

    local userId = getNumericUserId(player)
    local container = ensureSaveContainer(serialized)
    container = runSchemaMigrations(container, player, userId)

    local data = buildDefaultData()
    local source = resolveSerializedProfile(container)
    if type(source) == "table" then
        if type(source.Coins) == "number" then
            data.Coins = source.Coins
        end

        if type(source.Stats) == "table" then
            local stats = data.Stats
            for key, value in pairs(source.Stats) do
                stats[key] = value
            end
        end

        if type(source.Inventory) == "table" then
            local inventory = source.Inventory
            local target = data.Inventory
            target.MeleeLoadout = sanitizeStringList(inventory.MeleeLoadout)
            target.ActiveMelee = if type(inventory.ActiveMelee) == "string" and inventory.ActiveMelee ~= "" then inventory.ActiveMelee else nil
            target.TokenCounts = sanitizeTokenCounts(inventory.TokenCounts)
            target.UtilityQueue = sanitizeStringList(inventory.UtilityQueue)
            target.OwnedMelee = sanitizeOwnedMelee(inventory.OwnedMelee)
        end
        if type(source.Settings) == "table" then
            data.Settings = sanitizeSettingsData(source.Settings)
        end
    end

    profile.Data = data

    syncTutorialAttribute(player, data)

    local inventory = ensureInventory(data)
    refreshQuickbar(player, data, inventory)

    return data
end

function ProfileServer.GetByUserId(userId: number): Profile?
    return profilesByUserId[userId]
end

function ProfileServer.Reset(player: Player)
    local profile = profilesByPlayer[player]
    if not profile then
        return
    end

    profile.Data = buildDefaultData()
    syncTutorialAttribute(player, profile.Data)
    connectAttributeTracking(player, profile)
    refreshQuickbar(player, profile.Data, profile.Data.Inventory)
end

function ProfileServer.GetTutorialCompleted(player: Player): boolean
    local profile = ProfileServer.Get(player)
    return syncTutorialAttribute(player, profile.Data)
end

function ProfileServer.SetTutorialCompleted(player: Player, completed: boolean?): boolean
    local profile = ProfileServer.Get(player)
    local data = profile.Data
    local stats = ensureStats(data)
    stats[TUTORIAL_STAT_KEY] = completed == true
    return syncTutorialAttribute(player, data)
end

function ProfileServer.RegisterMigration(fromVersion: number, handler: MigrationHandler): () -> ()
    local disconnect = registerMigrationInternal(fromVersion, handler)
    if disconnect == nil then
        return function() end
    end

    local disconnected = false
    return function()
        if disconnected then
            return
        end
        disconnected = true
        disconnect()
    end
end

local saveServiceLoadWarned = false
local saveServiceSaveWarned = false

local function warnLoadUnavailable()
    if not saveServiceLoadWarned then
        warn("[ProfileServer] SaveService.LoadAsync unavailable; using default data.")
        saveServiceLoadWarned = true
    end
end

local function warnSaveUnavailable()
    if not saveServiceSaveWarned then
        warn("[ProfileServer] SaveService.SaveAsync unavailable; progress will not persist.")
        saveServiceSaveWarned = true
    end
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

local function handlePlayerAdded(player: Player)
    local profile = ensureProfile(player)
    local data = profile.Data
    local inventory = ensureInventory(data)
    refreshQuickbar(player, data, inventory)

    if not saveServiceLoadAsync then
        warnLoadUnavailable()
        return
    end

    local userId = getNumericUserId(player)

    task.spawn(function()
        local ok, payload, loadErr = pcall(saveServiceLoadAsync, userId)
        if not ok then
            warn(string.format("[ProfileServer] Load error for %s (%d): %s", player.Name, userId, tostring(payload)))
            return
        end

        if loadErr then
            warn(string.format("[ProfileServer] Load failed for %s (%d): %s", player.Name, userId, tostring(loadErr)))
            return
        end

        if player.Parent == nil or not profilesByPlayer[player] then
            return
        end

        if payload ~= nil then
            local applyOk, applyErr = pcall(ProfileServer.LoadSerialized, player, payload)
            if not applyOk then
                warn(string.format("[ProfileServer] Apply failed for %s (%d): %s", player.Name, userId, tostring(applyErr)))
                refreshQuickbarForPlayer(player)
            end
        else
            refreshQuickbarForPlayer(player)
        end
    end)
end

local function handlePlayerRemoving(player: Player)
    local serialized = ProfileServer.Serialize(player)

    local userId = getNumericUserId(player)

    local function legacySave()
        if saveServiceSaveAsync then
            local container = upsertSerializedProfile(nil, serialized)
            local ok, saveSuccess, saveErr = pcall(saveServiceSaveAsync, userId, container)
            if not ok then
                warn(string.format("[ProfileServer] Save error for %s (%d): %s", player.Name, userId, tostring(saveSuccess)))
            elseif not saveSuccess then
                local message = if saveErr then tostring(saveErr) else "Unknown error"
                warn(string.format("[ProfileServer] Save failed for %s (%d): %s", player.Name, userId, message))
            end
        else
            warnSaveUnavailable()
        end
    end

    if saveServiceUpdateAsync then
        local ok, updatedPayload, saveErr = pcall(saveServiceUpdateAsync, userId, function(payload)
            return upsertSerializedProfile(payload, serialized)
        end)

        if not ok then
            warn(string.format("[ProfileServer] Update save error for %s (%d): %s", player.Name, userId, tostring(updatedPayload)))
            legacySave()
        elseif saveErr then
            warn(string.format("[ProfileServer] Update save failed for %s (%d): %s", player.Name, userId, tostring(saveErr)))
            legacySave()
        end
    else
        legacySave()
    end

    removeProfile(player)
end

Players.PlayerAdded:Connect(function(player)
    handlePlayerAdded(player)
end)

Players.PlayerRemoving:Connect(function(player)
    handlePlayerRemoving(player)
end)

for _, player in ipairs(Players:GetPlayers()) do
    task.defer(handlePlayerAdded, player)
end

if saveServiceRegisterCheckpoint then
    saveServiceRegisterCheckpoint(function(player: Player?, userId: number, payload: any?): any?
        local profile: Profile? = nil
        if player then
            profile = profilesByPlayer[player]
        end

        if not profile and typeof(userId) == "number" and userId ~= 0 then
            profile = profilesByUserId[userId]
        end

        if not profile then
            return payload
        end

        local serialized = serializeProfileData(profile)
        if not serialized then
            return payload
        end

        return upsertSerializedProfile(payload, serialized)
    end)
end

ProfileServer.SchemaVersion = CURRENT_SCHEMA_VERSION

return ProfileServer

