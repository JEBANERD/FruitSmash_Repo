-- ShieldWatchdog (SERVER) - Enforces global->local shield consistency
local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Modules = RS:WaitForChild("Modules")
local ShieldState = require(Modules:WaitForChild("ShieldState"))

local TargetShieldFlag: BoolValue = RS:FindFirstChild("TargetShieldActive") :: BoolValue
if not TargetShieldFlag then
        TargetShieldFlag = Instance.new("BoolValue")
        TargetShieldFlag.Name = "TargetShieldActive"
        TargetShieldFlag.Value = false
        TargetShieldFlag.Parent = RS
end

local DEBUG_SHIELD = false

local function debugShield(...)
        if DEBUG_SHIELD then
                print("[ShieldWatchdog]", ...)
        end
end

local playerSessions: { [Player]: {
        charAddedConn: RBXScriptConnection?,
        charRemovingConn: RBXScriptConnection?,
        characterConn: RBXScriptConnection?,
} } = {}

local function resetPlayerShield(player: Player)
        ShieldState.Set(player, false)
        debugShield("Player shield reset →", player.Name)
end

local function bindCharacter(player: Player, character: Model?)
        local session = playerSessions[player]
        if not session then
                session = {}
                playerSessions[player] = session
        end

        if session.characterConn then
                session.characterConn:Disconnect()
                session.characterConn = nil
        end

        resetPlayerShield(player)

        if character then
                session.characterConn = character.AncestryChanged:Connect(function(_, parent)
                        if not parent then
                                resetPlayerShield(player)
                        end
                end)
        end
end

local function bindPlayer(player: Player)
        local session = playerSessions[player]
        if not session then
                session = {}
                playerSessions[player] = session
        end

        resetPlayerShield(player)

        if session.charAddedConn then
                session.charAddedConn:Disconnect()
        end
        if session.charRemovingConn then
                session.charRemovingConn:Disconnect()
        end

        session.charAddedConn = player.CharacterAdded:Connect(function(character)
                bindCharacter(player, character)
        end)

        session.charRemovingConn = player.CharacterRemoving:Connect(function()
                resetPlayerShield(player)
        end)

        if player.Character then
                bindCharacter(player, player.Character)
        end
end

local function unbindPlayer(player: Player)
        local session = playerSessions[player]
        if session then
                if session.charAddedConn then
                        session.charAddedConn:Disconnect()
                end
                if session.charRemovingConn then
                        session.charRemovingConn:Disconnect()
                end
                if session.characterConn then
                        session.characterConn:Disconnect()
                end
                playerSessions[player] = nil
        end
        resetPlayerShield(player)
end

Players.PlayerAdded:Connect(bindPlayer)
Players.PlayerRemoving:Connect(unbindPlayer)
for _, player in ipairs(Players:GetPlayers()) do
        bindPlayer(player)
end

local function getAllTargets()
        local out = {}
        local lanes = Workspace:FindFirstChild("Lanes")
        if lanes then
                for _, lane in ipairs(lanes:GetChildren()) do
                        local t = lane:FindFirstChild("Target")
                        if t then table.insert(out, t) end
                end
        end
        local single = Workspace:FindFirstChild("Target")
        if single then table.insert(out, single) end
        return out
end

local function hardClean()
        if TargetShieldFlag.Value then return end -- only enforce when global is OFF
        for _, t in ipairs(getAllTargets()) do
                if ShieldState.Get(t) then
                        ShieldState.Set(t, false)
                end
                for _, d in ipairs(t:GetChildren()) do
                        if d:IsA("BasePart") and d.Name == "TargetShieldBubble" then
                                d:Destroy()
                        end
                end
        end
end

-- Light heartbeat (twice a second)
task.spawn(function()
        while true do
                task.wait(0.5)
                hardClean()
        end
end)
