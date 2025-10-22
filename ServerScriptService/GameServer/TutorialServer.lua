--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local remoteBootstrap = require(remotesFolder:WaitForChild("RemoteBootstrap"))

local tutorialRemote: RemoteFunction? = remoteBootstrap and remoteBootstrap.RF_Tutorial or nil

local dataFolder = ServerScriptService:FindFirstChild("Data")
local profileModule = dataFolder and dataFolder:FindFirstChild("ProfileServer")

local ProfileServer: any = nil
if profileModule and profileModule:IsA("ModuleScript") then
    local ok, result = pcall(require, profileModule)
    if ok and typeof(result) == "table" then
        ProfileServer = result
    else
        warn("[TutorialServer] Failed to require ProfileServer:", result)
    end
else
    warn("[TutorialServer] ProfileServer module missing")
end

local TutorialServer = {}

local TUTORIAL_ATTR_NAME = "TutorialCompleted"

local profileUnavailableWarned = false
local function ensureProfileServer(): any?
    if ProfileServer then
        return ProfileServer
    end
    if not profileUnavailableWarned then
        profileUnavailableWarned = true
        warn("[TutorialServer] ProfileServer unavailable; tutorial state changes will not persist.")
    end
    return nil
end

local function readCompleted(player: Player): boolean
    local server = ensureProfileServer()
    if server and typeof(server.GetTutorialCompleted) == "function" then
        local ok, result = pcall(server.GetTutorialCompleted, player)
        if ok and typeof(result) == "boolean" then
            return result
        elseif not ok then
            warn(string.format("[TutorialServer] GetTutorialCompleted failed for %s: %s", player.Name, tostring(result)))
        end
    end

    local attr = player:GetAttribute(TUTORIAL_ATTR_NAME)
    return attr == true
end

local function setCompleted(player: Player, completed: boolean): boolean
    local server = ensureProfileServer()
    if server and typeof(server.SetTutorialCompleted) == "function" then
        local ok, result = pcall(server.SetTutorialCompleted, player, completed)
        if ok and typeof(result) == "boolean" then
            return result
        elseif not ok then
            warn(string.format("[TutorialServer] SetTutorialCompleted failed for %s: %s", player.Name, tostring(result)))
        end
    end

    local flag = completed == true
    player:SetAttribute(TUTORIAL_ATTR_NAME, flag)
    return flag
end

if tutorialRemote then
    tutorialRemote.OnServerInvoke = function(player: Player, payload: any?)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
            return { success = false, error = "InvalidPlayer" }
        end

        local action = "status"
        local desired: boolean? = nil
        if typeof(payload) == "table" then
            local rawAction = (payload :: any).action or (payload :: any).Action or (payload :: any).mode
            if typeof(rawAction) == "string" and rawAction ~= "" then
                action = string.lower(rawAction)
            end
            local completedValue = (payload :: any).completed or (payload :: any).Completed or (payload :: any).state
            if completedValue ~= nil then
                if typeof(completedValue) == "boolean" then
                    desired = completedValue
                elseif completedValue == 1 or completedValue == "true" then
                    desired = true
                elseif completedValue == 0 or completedValue == "false" then
                    desired = false
                end
            end
        elseif typeof(payload) == "string" then
            action = string.lower(payload)
        end

        local completed: boolean
        if action == "complete" or action == "finish" or action == "skip" then
            completed = setCompleted(player, true)
        elseif action == "reset" or action == "restart" then
            completed = setCompleted(player, false)
        elseif action == "set" and desired ~= nil then
            completed = setCompleted(player, desired)
        else
            completed = readCompleted(player)
        end

        return {
            success = true,
            completed = completed,
            action = action,
        }
    end
else
    warn("[TutorialServer] RF_Tutorial remote missing; tutorial progress cannot sync.")
end

Players.PlayerAdded:Connect(function(player)
    task.defer(function()
        readCompleted(player)
    end)
end)

for _, player in ipairs(Players:GetPlayers()) do
    task.defer(function()
        readCompleted(player)
    end)
end

return TutorialServer
