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
