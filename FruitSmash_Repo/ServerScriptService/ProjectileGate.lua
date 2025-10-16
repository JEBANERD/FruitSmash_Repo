-- ProjectileGate (SERVER)
-- Blocks any projectile spawned while GameActive=false and logs the culprit path.

local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameActive: BoolValue = RS:WaitForChild("GameActive") :: BoolValue
local ActiveProjectiles: Folder = Workspace:WaitForChild("ActiveProjectiles") :: Folder

local function isProjectile(inst: Instance): boolean
	-- Consider anything with FruitName attribute OR with any BasePart descendant as a projectile
	if inst:GetAttribute("FruitName") ~= nil then return true end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then return true end
	end
	return false
end

local function fullname(o: Instance?): string
	return o and o:GetFullName() or "nil"
end

-- Sweep existing when paused
local function sweepIfPaused()
	if GameActive.Value then return end
	for _, child in ipairs(ActiveProjectiles:GetChildren()) do
		if isProjectile(child) then
			warn("[ProjectileGate] Removing leftover projectile while paused:", fullname(child))
			child:Destroy()
		end
	end
end

-- Watch for new spawns during pause
ActiveProjectiles.ChildAdded:Connect(function(obj)
	if GameActive.Value then return end
	task.defer(function()
		if GameActive.Value then return end
		if obj and obj.Parent == ActiveProjectiles and isProjectile(obj) then
			warn("[ProjectileGate] BLOCKED spawn while GameActive=false  |  Object:",
				fullname(obj), "  Parent:", fullname(obj.Parent))
			obj:Destroy()
		end
	end)
end)

-- Sweep whenever we enter a paused phase
GameActive.Changed:Connect(function()
	if not GameActive.Value then
		sweepIfPaused()
	end
end)

-- Initial sweep on server start
sweepIfPaused()
print("[ProjectileGate] Guard active (will block fruit during countdown/intermission).")
