--!strict
--[=[
    BotLoad
    -------
    Utility helpers for cloning and spawning NPC bot models.
    Bots are authored as models inside `ServerStorage/EnemyProfiles`.
    This module exposes type-safe helpers that perform common
    validation, cloning and placement operations before the bot is
    parented into the world.
]=]

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local BotLoad = {}

type BotSpawnArgs = {
        profileId: string,
        parent: Instance?,
        spawnCFrame: CFrame?,
        arenaId: string?,
        attributes: { [string]: any }?,
        tags: { string }?,
}

export type BotSpawnArgs = BotSpawnArgs

local function resolveProfilesFolder(): Folder
    local folder = ServerStorage:FindFirstChild("EnemyProfiles")
    if folder and folder:IsA("Folder") then
        return folder
    end

    error("[BotLoad] EnemyProfiles folder is missing from ServerStorage")
end

local function resolveBotProfile(profileId: string): Model
    local folder = resolveProfilesFolder()
    local instance = folder:FindFirstChild(profileId)

    if not instance then
        error(string.format("[BotLoad] Enemy profile '%s' does not exist", profileId))
    end

    if not instance:IsA("Model") then
        error(string.format("[BotLoad] Enemy profile '%s' must be a Model", profileId))
    end

    return instance
end

local function cloneBotTemplate(template: Model): Model
    local clone = template:Clone()
    clone.Name = template.Name

    if not clone.PrimaryPart then
        local primary = clone:FindFirstChildWhichIsA("BasePart")
        if primary then
            clone.PrimaryPart = primary
        end
    end

    return clone
end

local function parentBot(bot: Model, parent: Instance?): Model
    bot.Parent = parent or Workspace
    return bot
end

local function applySpawnArgs(bot: Model, args: BotSpawnArgs)
    if args.arenaId and args.arenaId ~= "" then
        bot:SetAttribute("ArenaId", args.arenaId)
    end

    local attributes = args.attributes
    if attributes then
        for attributeName, value in pairs(attributes) do
            bot:SetAttribute(attributeName, value)
        end
    end

    local tags = args.tags
    if tags then
        for _, tag in ipairs(tags) do
            CollectionService:AddTag(bot, tag)
        end
    end

    local targetCFrame = args.spawnCFrame
    if targetCFrame then
        local ok, err = pcall(bot.PivotTo, bot, targetCFrame)
        if not ok then
            warn(string.format("[BotLoad] Failed to pivot bot '%s': %s", bot.Name, tostring(err)))
        end
    end
end

function BotLoad.CloneBot(profileId: string): Model
    local template = resolveBotProfile(profileId)
    return cloneBotTemplate(template)
end

function BotLoad.LoadBot(profileId: string, parent: Instance?): Model
    local clone = BotLoad.CloneBot(profileId)
    return parentBot(clone, parent)
end

function BotLoad.SpawnBot(args: BotSpawnArgs): Model
    assert(typeof(args) == "table", "Bot spawn args must be a table")
    assert(typeof(args.profileId) == "string" and args.profileId ~= "", "Bot spawn args must include a profileId")

    local bot = BotLoad.CloneBot(args.profileId)
    applySpawnArgs(bot, args)
    return parentBot(bot, args.parent)
end

return BotLoad
