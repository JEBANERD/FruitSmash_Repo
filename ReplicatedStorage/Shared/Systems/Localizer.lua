--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local localeFolder = sharedFolder:WaitForChild("Locale")
local stringsModule = localeFolder:WaitForChild("Strings")

local Strings: { [string]: any } = require(stringsModule)

local DEFAULT_LOCALE = "en"

local Localizer = {}

local supportedLocales: { string } = {}
local supportedLookup: { [string]: boolean } = {}

for locale in pairs(Strings) do
    if typeof(locale) == "string" then
        table.insert(supportedLocales, locale)
        supportedLookup[locale] = true
    end
end

table.sort(supportedLocales)

local function getLocaleTable(locale: string?): any
    if not locale then
        return nil
    end

    local entry = Strings[locale]
    if typeof(entry) == "table" then
        return entry
    end

    return nil
end

local function renderTemplate(text: string, args: { [string]: any }?): string
    if not args then
        return text
    end

    local function replacer(token: string)
        local value = args[token]
        if value == nil then
            return ""
        end
        return tostring(value)
    end

    return string.gsub(text, "{{(%w+)}}", replacer)
end

local function splitKey(key: string): { string }
    local parts: { string } = {}
    for segment in string.gmatch(key, "[^%.]+") do
        table.insert(parts, segment)
    end
    return parts
end

local function resolveValue(locale: string, parts: { string }): any
    local current = getLocaleTable(locale)
    for _, part in ipairs(parts) do
        if typeof(current) ~= "table" then
            return nil
        end
        current = current[part]
    end
    return current
end

function Localizer.getDefaultLocale(): string
    return DEFAULT_LOCALE
end

function Localizer.getSupportedLocales(): { string }
    local copy: { string } = {}
    for _, locale in ipairs(supportedLocales) do
        table.insert(copy, locale)
    end
    return copy
end

function Localizer.normalizeLocale(locale: any): string
    if typeof(locale) ~= "string" then
        return DEFAULT_LOCALE
    end

    local candidate = string.lower(locale)
    for _, supported in ipairs(supportedLocales) do
        if string.lower(supported) == candidate then
            return supported
        end
    end

    return supportedLookup[locale] and locale or DEFAULT_LOCALE
end

function Localizer.getLocaleDisplayName(locale: string, targetLocale: string?): string
    local resolvedTarget = Localizer.normalizeLocale(targetLocale)
    local localeTable = getLocaleTable(resolvedTarget)
    if typeof(localeTable) == "table" then
        local localesTable = localeTable.locales
        if typeof(localesTable) == "table" then
            local entry = localesTable[locale]
            if typeof(entry) == "string" and entry ~= "" then
                return entry
            end
        end
    end

    if locale == "en" then
        return "English"
    elseif locale == "es" then
        return "Español"
    end

    return locale
end

function Localizer.getPlayerLocale(player: Player?): string
    if typeof(player) == "Instance" and player:IsA("Player") then
        local attribute = player:GetAttribute("Locale")
        if typeof(attribute) == "string" then
            return Localizer.normalizeLocale(attribute)
        end
    end
    return DEFAULT_LOCALE
end

function Localizer.getLocalPlayerLocale(): string
    if RunService:IsClient() then
        local Players = game:GetService("Players")
        local localPlayer = Players.LocalPlayer
        if localPlayer then
            return Localizer.getPlayerLocale(localPlayer)
        end
    end
    return DEFAULT_LOCALE
end

function Localizer.t(key: string?, args: { [string]: any }?, locale: string?): string
    if typeof(key) ~= "string" or key == "" then
        return ""
    end

    local resolvedLocale = if locale and locale ~= "" then Localizer.normalizeLocale(locale) else DEFAULT_LOCALE
    local parts = splitKey(key)

    local value = resolveValue(resolvedLocale, parts)
    if typeof(value) ~= "string" then
        if resolvedLocale ~= DEFAULT_LOCALE then
            value = resolveValue(DEFAULT_LOCALE, parts)
        end
    end

    if typeof(value) ~= "string" then
        return key
    end

    return renderTemplate(value, args)
end

return Localizer
