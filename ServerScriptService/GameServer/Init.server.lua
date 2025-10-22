-- Server bootstrap: wires remotes and spawns an arena when requested
local RS = game:GetService("ReplicatedStorage")
local SS = game:GetService("ServerStorage")
local Players = game:GetService("Players")

-- Require remotes table
local Remotes
local ok, err = pcall(function()
        Remotes = require(RS:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))
end)
if not ok or not Remotes then
        warn("[Init] Remotes not available:", err)
        return
end

do
        local settingsModule = script.Parent:FindFirstChild("SettingsServer")
        if settingsModule and settingsModule:IsA("ModuleScript") then
                local okSettings, result = pcall(require, settingsModule)
                if not okSettings then
                        warn("[Init] SettingsServer require failed:", result)
                elseif type(result) ~= "table" then
                        warn("[Init] SettingsServer returned unexpected type")
                end
        else
                warn("[Init] SettingsServer module missing")
        end
end

do
        local tutorialModule = script.Parent:FindFirstChild("TutorialServer")
        if tutorialModule and tutorialModule:IsA("ModuleScript") then
                local okTutorial, result = pcall(require, tutorialModule)
                if not okTutorial then
                        warn("[Init] TutorialServer require failed:", result)
                elseif type(result) ~= "table" then
                        warn("[Init] TutorialServer returned unexpected type")
                end
        else
                warn("[Init] TutorialServer module missing")
        end
end

do
        local shopFolder = script.Parent:FindFirstChild("Shop")
        local shopModule = shopFolder and shopFolder:FindFirstChild("ShopServer")
        if shopModule then
                local okShop, shopServer = pcall(require, shopModule)
                if okShop then
                        if type(shopServer) == "table" then
                                local initMethod = shopServer.Init
                                if type(initMethod) == "function" then
                                        local okInit, initErr = pcall(initMethod, shopServer)
                                        if not okInit then
                                                okInit, initErr = pcall(initMethod)
                                        end
                                        if not okInit then
                                                warn("[Init] ShopServer.Init failed:", initErr)
                                        end
                                end
                        end
                else
                        warn("[Init] Failed to require ShopServer:", shopServer)
                end
        end
end

do
        local sss = game:GetService("ServerScriptService")
        local combatFolder = sss and sss:FindFirstChild("Combat")
        local hitModule = combatFolder and combatFolder:FindFirstChild("HitValidationServer")
        if hitModule then
                local okCombat, hitServer = pcall(require, hitModule)
                if okCombat then
                        local initMethod = hitServer and hitServer.Init
                        if type(initMethod) == "function" then
                                local okInit, initErr = pcall(initMethod, hitServer)
                                if not okInit then
                                        okInit, initErr = pcall(initMethod)
                                end
                                if not okInit then
                                        warn("[Init] HitValidationServer.Init failed:", initErr)
                                end
                        end
                else
                        warn("[Init] Failed to require HitValidationServer:", hitServer)
                end
        else
                warn("[Init] Combat/HitValidationServer missing")
        end
end

-- Ensure Workspace/Arenas exists
local arenas = workspace:FindFirstChild("Arenas") or Instance.new("Folder", workspace)
arenas.Name = "Arenas"

local function spawnArena()
	local baseFolder = SS:FindFirstChild("ArenaTemplates")
	local base = baseFolder and baseFolder:FindFirstChild("BaseArena")
	if not base then
		warn("[Init] Missing ServerStorage/ArenaTemplates/BaseArena")
		return
	end
	-- Clear previous
	for _, c in ipairs(arenas:GetChildren()) do c:Destroy() end

	local inst = base:Clone()
	inst.Name = "Arena_1"
	inst.Parent = arenas
	print("[Init] Spawned Arena_1")
end

-- Start on GameStart remote (e.g., from your G key or floor button)
if Remotes.GameStart then
	Remotes.GameStart.OnServerEvent:Connect(function(player)
		print(("[Init] %s requested start"):format(player.Name))
		spawnArena()
	end)
else
	warn("[Init] Remotes.GameStart missing")
end

print("[Init] Boot complete; waiting for GameStart")
