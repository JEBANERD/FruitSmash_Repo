--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local WorkspaceService = game:GetService("Workspace") :: Workspace
local ServerStorage = game:GetService("ServerStorage") :: ServerStorage

if not RunService:IsStudio() then
        return
end

local arenaTemplates = ServerStorage:FindFirstChild("ArenaTemplates") :: Folder?
if not arenaTemplates or not arenaTemplates:IsA("Folder") then
        warn("[DevTest_StartArena] ServerStorage/ArenaTemplates folder missing")
        return
end

local arenaTemplatesFolder = arenaTemplates :: Folder

local baseArenaModule = arenaTemplatesFolder:FindFirstChild("BaseArena")
if not baseArenaModule or not baseArenaModule:IsA("ModuleScript") then
        warn("[DevTest_StartArena] ArenaTemplates/BaseArena module missing")
        return
end

local okTemplate, template = pcall(require, baseArenaModule)
if not okTemplate then
        warn(string.format("[DevTest_StartArena] Failed to require BaseArena: %s", tostring(template)))
        return
end

if typeof(template) ~= "Instance" or not template:IsA("Model") then
        warn("[DevTest_StartArena] BaseArena module did not return a Model instance")
        return
end

local baseArenaTemplate = template :: Model

local arenasFolderInstance = WorkspaceService:FindFirstChild("Arenas")
if arenasFolderInstance and not arenasFolderInstance:IsA("Folder") then
        warn("[DevTest_StartArena] Workspace/Arenas exists but is not a Folder")
        return
end

local arenasFolder: Folder = if arenasFolderInstance then arenasFolderInstance :: Folder else (function()
        local folder = Instance.new("Folder")
        folder.Name = "Arenas"
        folder.Parent = WorkspaceService
        return folder
end)()

local COMMAND_KEYWORD = "!startarena"
local ARENA_TAG_ATTRIBUTE = "DevTestArena"

local function describeRequester(player: Player?): string
        if player == nil then
                return "server"
        end

        local name = player.Name
        local userId = player.UserId
        return string.format("%s (%d)", name, userId)
end

local function clearPreviousDevArenas()
        for _, child in ipairs(arenasFolder:GetChildren()) do
                if child:IsA("Model") and child:GetAttribute(ARENA_TAG_ATTRIBUTE) == true then
                        child:Destroy()
                end
        end
end

local function spawnDevArena(requester: Player?): Model
        clearPreviousDevArenas()

        local arenaClone = baseArenaTemplate:Clone()
        arenaClone.Name = "Arena_DevTest"
        arenaClone:SetAttribute(ARENA_TAG_ATTRIBUTE, true)
        arenaClone.Parent = arenasFolder

        print(string.format("[DevTest_StartArena] Spawned dev arena for %s", describeRequester(requester)))

        return arenaClone
end

local function trim(message: string): string
        return (message:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function onCommand(player: Player, message: string)
        local normalized = string.lower(trim(message))
        if normalized ~= COMMAND_KEYWORD then
                return
        end

        spawnDevArena(player)
end

local function connectPlayer(player: Player)
        player.Chatted:Connect(function(message: string)
                onCommand(player, message)
        end)
end

for _, player in ipairs(Players:GetPlayers()) do
        connectPlayer(player)
end

Players.PlayerAdded:Connect(function(player: Player)
        connectPlayer(player)
end)

local commandSignal = Instance.new("BindableEvent")
commandSignal.Name = "Trigger"
commandSignal.Parent = script

commandSignal.Event:Connect(function(requester: Player?)
        spawnDevArena(requester)
end)

print("[DevTest_StartArena] Ready. Type '!startarena' in chat or fire Trigger to spawn the base arena.")
