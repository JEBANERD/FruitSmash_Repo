-- PowerupPickupManager (SERVER, no SFX, NO prompt, touch + overlap-based pickup)
-- Auto-wires power-ups that appear in Workspace. Collect by hitting/walking through.

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Debris    = game:GetService("Debris")
local RunService= game:GetService("RunService")
local SSS       = game:GetService("ServerScriptService")

-- Try to require PowerupEffects safely
local PowerupEffects do
	local m = SSS:FindFirstChild("PowerupEffects")
	if m and m:IsA("ModuleScript") then
		local ok, mod = pcall(require, m)
		PowerupEffects = ok and mod or nil
	end
	if not PowerupEffects then
		warn("[PowerupPickupManager] PowerupEffects missing; using no-op (pickup will still delete).")
		PowerupEffects = { ApplyPowerup = function() return true end }
	end
end

local KNOWN = { HealthPack = true, CoinBoost = true, Shield = true }

-- ---------- Helpers ----------
local function resolveType(inst: Instance): string?
	local t = inst:GetAttribute("PowerupType")
	if typeof(t) == "string" and #t > 0 then return t end
	local sv = inst:FindFirstChild("PowerupType")
	if sv and sv:IsA("StringValue") and #sv.Value > 0 then return sv.Value end
	if KNOWN[inst.Name] then return inst.Name end
	return nil
end

local function getAllParts(inst: Instance): {BasePart}
	local parts = {}
	if inst:IsA("BasePart") then
		table.insert(parts, inst)
	else
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then table.insert(parts, d) end
		end
	end
	return parts
end

local function getRootPart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then return inst end
	if inst:IsA("Model") then
		if inst.PrimaryPart then return inst.PrimaryPart end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then inst.PrimaryPart = d; return d end
		end
	end
	return nil
end

local function getPlayerFromPart(part: BasePart): Player?
	local char = part:FindFirstAncestorOfClass("Model")
	if not char then return nil end
	if not char:FindFirstChildOfClass("Humanoid") then return nil end
	return Players:GetPlayerFromCharacter(char)
end

-- Make an invisible hitbox around the powerup; we’ll scan overlaps reliably
local function createHitbox(inst: Instance): BasePart?
	local root = getRootPart(inst)
	if not root then return nil end

	local hb = Instance.new("Part")
	hb.Name = "PickupHitbox"
	hb.Anchored = true
	hb.CanCollide = false
	hb.CanTouch = false
	hb.CanQuery = true
	hb.Transparency = 1
	hb.Material = Enum.Material.ForceField -- cheap, always visible in wireframe if needed

	-- Size: cover the model extents with a little padding
	local size = Vector3.new(4, 4, 4)
	if inst:IsA("Model") then
		local cf, extents = inst:GetBoundingBox()
		size = extents + Vector3.new(2, 2, 2) -- padding
		hb.CFrame = cf
	else
		size = (root.Size or Vector3.new(2,2,2)) + Vector3.new(2,2,2)
		hb.CFrame = root.CFrame
	end
	-- Clamp to reasonable bounds
	size = Vector3.new(math.clamp(size.X, 2, 12), math.clamp(size.Y, 2, 12), math.clamp(size.Z, 2, 12))
	hb.Size = size
	hb.Parent = inst -- parent under the powerup so it deletes with it
	return hb
end

-- ---------- Core wiring ----------
local function wire(inst: Instance)
	if inst:GetAttribute("PickupWired") then return end
	local pType = resolveType(inst)
	if not pType then return end

	local parts = getAllParts(inst)
	if #parts == 0 then return end

	inst:SetAttribute("PickupWired", true)

	-- Ensure all visible parts are “touchable”
	for _, p in ipairs(parts) do
		p.CanQuery = true
		p.CanTouch = true
		p.CanCollide = false        -- walk-through pickup
		if p.CollisionGroupId ~= 0 then p.CollisionGroupId = 0 end -- Default group
	end

	local collected = false
	local function collect(plr: Player?)
		if collected then return end
		collected = true
		pcall(function()
			PowerupEffects.ApplyPowerup(pType, plr)
		end)
		Debris:AddItem(inst, 0) -- delete immediately
	end

	-- A) Traditional .Touched on every part (fast path)
	for _, p in ipairs(parts) do
		p.Touched:Connect(function(hit: BasePart)
			if collected then return end
			if not hit or not hit:IsA("BasePart") then return end
			local plr = getPlayerFromPart(hit)
			if not plr then return end
			collect(plr)
		end)
	end

	-- B) Overlap scanner (bulletproof fallback; works even if collision groups block touches)
	local hb = createHitbox(inst)
	if hb then
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		-- include all character models by filtering on players’ characters (we’ll refresh list on the fly)
		local function refreshFilter()
			local list = {}
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr.Character then table.insert(list, plr.Character) end
			end
			params.FilterDescendantsInstances = list
		end
		refreshFilter()

		local lastCF = hb.CFrame
		local heartbeatConn; heartbeatConn = RunService.Heartbeat:Connect(function()
			if collected or not inst.Parent then
				if heartbeatConn then heartbeatConn:Disconnect() end
				return
			end

			-- Keep hitbox with the item
			local root = getRootPart(inst)
			if root and (root.CFrame ~= lastCF) then
				lastCF = root.CFrame
				hb.CFrame = lastCF
			end

			-- Refresh filter occasionally (handles respawns/new players)
			if math.random() < 0.1 then refreshFilter() end

			local overlaps = Workspace:GetPartsInPart(hb, params)
			for _, part in ipairs(overlaps) do
				local plr = getPlayerFromPart(part)
				if plr then
					collect(plr)
					break
				end
			end
		end)

		inst.Destroying:Connect(function()
			if heartbeatConn then heartbeatConn:Disconnect() end
		end)
	end

	-- Safety auto-cleanup
	Debris:AddItem(inst, 60)
end

-- Wire existing items at start + future spawns
for _, d in ipairs(Workspace:GetDescendants()) do wire(d) end
Workspace.DescendantAdded:Connect(function(d) task.defer(function() wire(d) end) end)

print("[PowerupPickupManager] Loaded (hit-to-collect: touch + overlap).")
