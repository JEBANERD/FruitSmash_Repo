--!strict

-- SettingsServer
-- Central authority for gameplay & accessibility settings. Persists to ProfileServer
-- when available and mirrors settings to clients via remotes + player attributes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local remotesModule = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))
local saveRemote: RemoteFunction? = remotesModule and remotesModule.RF_SaveSettings or nil
local pushRemote: RemoteEvent? = remotesModule and remotesModule.RE_SettingsPushed or nil

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = if typeof((GameConfigModule :: any).Get) == "function" then (GameConfigModule :: any).Get() else GameConfigModule

local playerConfig = if typeof(GameConfig) == "table" then (GameConfig :: any).Player else nil
local settingsConfig = if typeof(playerConfig) == "table" then (playerConfig :: any).Settings else nil
local defaultsConfig = if typeof(settingsConfig) == "table" then (settingsConfig :: any).Defaults else nil
local limitsConfig = if typeof(settingsConfig) == "table" then (settingsConfig :: any).Limits else nil
local palettesConfig = if typeof(settingsConfig) == "table" then (settingsConfig :: any).ColorblindPalettes else nil

type Settings = {
    SprintToggle: boolean,
    AimAssistWindow: number,
    CameraShakeStrength: number,
    ColorblindPalette: string,
    TextScale: number,
}

type ApplyOptions = {
    persist: boolean?,
    broadcast: boolean?,
}

local function deepCopy(value: any): any
    if typeof(value) ~= "table" then
        return value
    end

    local copy: {[any]: any} = {}
    for key, subValue in pairs(value) do
        copy[deepCopy(key)] = deepCopy(subValue)
    end
    return copy
end

local colorblindPalettes: {{ [string]: any }} = {}
local colorblindLookup: {[string]: any} = {}

if typeof(palettesConfig) == "table" then
    for _, entry in ipairs(palettesConfig) do
        if typeof(entry) == "table" then
            local idValue = (entry :: any).Id or (entry :: any).id or (entry :: any).Name or (entry :: any).name
            if typeof(idValue) == "string" and idValue ~= "" then
                local palette = {
                    Id = idValue,
                    Name = typeof((entry :: any).Name) == "string" and (entry :: any).Name or idValue,
                    TintColor = (entry :: any).TintColor,
                    Saturation = typeof((entry :: any).Saturation) == "number" and (entry :: any).Saturation or 0,
                    Contrast = typeof((entry :: any).Contrast) == "number" and (entry :: any).Contrast or 0,
                    Brightness = typeof((entry :: any).Brightness) == "number" and (entry :: any).Brightness or 0,
                }
                table.insert(colorblindPalettes, palette)
                colorblindLookup[idValue] = palette
            end
        end
    end
end

if #colorblindPalettes == 0 then
    local fallbackPalette = {
        Id = "Off",
        Name = "Off",
        TintColor = Color3.new(1, 1, 1),
        Saturation = 0,
        Contrast = 0,
        Brightness = 0,
    }
    table.insert(colorblindPalettes, fallbackPalette)
    colorblindLookup[fallbackPalette.Id] = fallbackPalette
end

local function resolveNumericLimit(key: string): (number?, number?)
    if typeof(limitsConfig) ~= "table" then
        return nil, nil
    end

    local entry = (limitsConfig :: any)[key]
    if typeof(entry) ~= "table" then
        return nil, nil
    end

    local minValue = (entry :: any).Min
    local maxValue = (entry :: any).Max

    return typeof(minValue) == "number" and minValue or tonumber(minValue), typeof(maxValue) == "number" and maxValue or tonumber(maxValue)
end

local function clampToLimits(value: number, key: string, fallback: number): number
    local minValue, maxValue = resolveNumericLimit(key)
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

local defaultPaletteId = "Off"
if typeof(defaultsConfig) == "table" and typeof((defaultsConfig :: any).ColorblindPalette) == "string" then
    local candidate = (defaultsConfig :: any).ColorblindPalette
    if candidate and colorblindLookup[candidate] then
        defaultPaletteId = candidate
    end
end
if not colorblindLookup[defaultPaletteId] then
    if colorblindLookup["Off"] then
        defaultPaletteId = "Off"
    else
        defaultPaletteId = colorblindPalettes[1].Id
    end
end

local function resolvePaletteId(value: any): string
    if typeof(value) == "string" and value ~= "" then
        if colorblindLookup[value] then
            return value
        end
        local lowered = string.lower(value)
        for id in pairs(colorblindLookup) do
            if string.lower(id) == lowered then
                return id
            end
        end
    end
    return defaultPaletteId
end

local DEFAULT_SETTINGS: Settings = {
    SprintToggle = typeof(defaultsConfig) == "table" and (defaultsConfig :: any).SprintToggle == true or false,
    AimAssistWindow = clampToLimits(
        typeof(defaultsConfig) == "table" and typeof((defaultsConfig :: any).AimAssistWindow) == "number" and (defaultsConfig :: any).AimAssistWindow or 0.75,
        "AimAssistWindow",
        0.75
    ),
    CameraShakeStrength = clampToLimits(
        typeof(defaultsConfig) == "table" and typeof((defaultsConfig :: any).CameraShakeStrength) == "number" and (defaultsConfig :: any).CameraShakeStrength or 0.7,
        "CameraShakeStrength",
        0.7
    ),
    ColorblindPalette = resolvePaletteId(typeof(defaultsConfig) == "table" and (defaultsConfig :: any).ColorblindPalette or nil),
    TextScale = clampToLimits(
        typeof(defaultsConfig) == "table" and typeof((defaultsConfig :: any).TextScale) == "number" and (defaultsConfig :: any).TextScale or 1,
        "TextScale",
        1
    ),
}

local function sanitizeSettings(raw: any): Settings
    local sanitized = deepCopy(DEFAULT_SETTINGS)
    if typeof(raw) ~= "table" then
        return sanitized
    end

    if raw.SprintToggle ~= nil then
        sanitized.SprintToggle = raw.SprintToggle == true
    end

    local aimAssist = raw.AimAssistWindow or raw.AimAssist or raw.AimAssistRadius
    if aimAssist ~= nil then
        local numeric = tonumber(aimAssist)
        if typeof(numeric) == "number" then
            sanitized.AimAssistWindow = clampToLimits(numeric, "AimAssistWindow", sanitized.AimAssistWindow)
        end
    end

    local shake = raw.CameraShakeStrength or raw.CameraShake
    if shake ~= nil then
        local numeric = tonumber(shake)
        if typeof(numeric) == "number" then
            sanitized.CameraShakeStrength = clampToLimits(numeric, "CameraShakeStrength", sanitized.CameraShakeStrength)
        end
    end

    local textScale = raw.TextScale or raw.TextSize or raw.TextSizeScale
    if textScale ~= nil then
        local numeric = tonumber(textScale)
        if typeof(numeric) == "number" then
            sanitized.TextScale = clampToLimits(numeric, "TextScale", sanitized.TextScale)
        end
    end

    if raw.ColorblindPalette ~= nil then
        sanitized.ColorblindPalette = resolvePaletteId(raw.ColorblindPalette)
    end

    return sanitized
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

local function safeRequire(moduleScript: Instance?): any?
    if not moduleScript or not moduleScript:IsA("ModuleScript") then
        return nil
    end

    local ok, result = pcall(require, moduleScript)
    if not ok then
        warn(string.format("[SettingsServer] Failed to require %s: %s", moduleScript:GetFullName(), tostring(result)))
        return nil
    end

    return result
end

local profileServer: any? = nil
local profileCandidates = {
    {"GameServer", "Data", "ProfileServer"},
    {"GameServer", "ProfileServer"},
    {"Data", "ProfileServer"},
}
for _, path in ipairs(profileCandidates) do
    local candidate = findFirstChildPath(ServerScriptService, path)
    local module = safeRequire(candidate)
    if module then
        profileServer = module
        break
    end
end

local function callProfileServer(methodName: string, player: Player): any
    if not profileServer then
        return nil
    end

    local method = (profileServer :: any)[methodName]
    if typeof(method) ~= "function" then
        return nil
    end

    local ok, r1 = pcall(method, profileServer, player)
    if ok then
        return r1
    end

    ok, r1 = pcall(method, player)
    if ok then
        return r1
    end

    warn(string.format("[SettingsServer] ProfileServer.%s failed: %s", methodName, tostring(r1)))
    return nil
end

local SettingsServer = {}

local sessionSettings: {[Player]: Settings} = {}

local function applyAttributes(player: Player, settings: Settings)
    player:SetAttribute("SprintToggle", settings.SprintToggle)
    player:SetAttribute("AimAssistWindow", settings.AimAssistWindow)
    player:SetAttribute("CameraShakeStrength", settings.CameraShakeStrength)
    player:SetAttribute("ColorblindPalette", settings.ColorblindPalette)
    player:SetAttribute("TextScale", settings.TextScale)
end

local function copySettings(settings: Settings?): Settings
    local copy: Settings = {
        SprintToggle = settings and settings.SprintToggle or DEFAULT_SETTINGS.SprintToggle,
        AimAssistWindow = settings and settings.AimAssistWindow or DEFAULT_SETTINGS.AimAssistWindow,
        CameraShakeStrength = settings and settings.CameraShakeStrength or DEFAULT_SETTINGS.CameraShakeStrength,
        ColorblindPalette = settings and settings.ColorblindPalette or DEFAULT_SETTINGS.ColorblindPalette,
        TextScale = settings and settings.TextScale or DEFAULT_SETTINGS.TextScale,
    }
    return copy
end

local function persistToProfile(player: Player, settings: Settings)
    local data = callProfileServer("GetData", player)
    if typeof(data) ~= "table" then
        return
    end

    local target = (data :: any).Settings
    if typeof(target) ~= "table" then
        target = {}
        (data :: any).Settings = target
    end

    for key in pairs(target) do
        if (settings :: any)[key] == nil then
            target[key] = nil
        end
    end

    for key, value in pairs(settings) do
        target[key] = value
    end
end

local function broadcastToClient(player: Player, settings: Settings)
    if not pushRemote then
        return
    end

    pushRemote:FireClient(player, copySettings(settings))
end

local function applyInternal(player: Player, payload: any, opts: ApplyOptions?): Settings
    local sanitized = sanitizeSettings(payload)
    sessionSettings[player] = copySettings(sanitized)
    applyAttributes(player, sanitized)

    if not opts or opts.broadcast ~= false then
        broadcastToClient(player, sanitized)
    end

    if (not opts or opts.persist ~= false) then
        persistToProfile(player, sanitized)
    end

    return copySettings(sanitized)
end

function SettingsServer.Get(player: Player): Settings
    return copySettings(sessionSettings[player])
end

function SettingsServer.GetDefault(_player: Player?): Settings
    return copySettings(DEFAULT_SETTINGS)
end

function SettingsServer.Apply(player: Player, payload: any): Settings
    return applyInternal(player, payload, nil)
end

local function pushProfileSettings(player: Player)
    if not profileServer then
        return
    end

    task.spawn(function()
        local attempts = 0
        while player.Parent do
            attempts += 1
            local data = callProfileServer("GetData", player)
            if typeof(data) == "table" then
                local raw = (data :: any).Settings
                if raw ~= nil then
                    applyInternal(player, raw, nil)
                else
                    applyInternal(player, DEFAULT_SETTINGS, nil)
                end
                return
            end

            if attempts >= 10 then
                applyInternal(player, DEFAULT_SETTINGS, nil)
                return
            end
            task.wait(0.5)
        end
    end)
end

Players.PlayerAdded:Connect(function(player)
    applyInternal(player, DEFAULT_SETTINGS, { persist = false })
    pushProfileSettings(player)
end)

Players.PlayerRemoving:Connect(function(player)
    sessionSettings[player] = nil
end)

if saveRemote then
    saveRemote.OnServerInvoke = function(player: Player, payload: any?)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
            return copySettings(DEFAULT_SETTINGS)
        end

        if payload == nil then
            return copySettings(sessionSettings[player])
        end

        return applyInternal(player, payload, nil)
    end
else
    warn("[SettingsServer] RF_SaveSettings remote missing")
end

print("[SettingsServer] Ready (player accessibility settings)")

return SettingsServer
