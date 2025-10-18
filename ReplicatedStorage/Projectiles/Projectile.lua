-- ReplicatedStorage/Projectiles/<Fruit>/ProjectileBehavior
-- Handles collisions with targets, shields, and self-destruction.

local Debris = game:GetService("Debris")

local projectile = script.Parent
local hasHit = false

-- Helper: find a Model that owns "Health" NumberValue
local function findDamageableModel(part: BasePart): Model?
	local ancestor = part and part.Parent
	while ancestor do
		if ancestor:IsA("Model") and ancestor:FindFirstChild("Health") then
			return ancestor
		end
		ancestor = ancestor.Parent
	end
	return nil
end

-- Connect Touched on ALL BaseParts of this projectile (Part or Model)
local function connectTouches(root: Instance)
	local parts = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	elseif root:IsA("Model") then
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
	end

	for _, p in ipairs(parts) do
		p.Touched:Connect(function(hit: BasePart)
			if hasHit then return end
			if not hit or not hit:IsA("BasePart") then return end
			if projectile:IsAncestorOf(hit) then return end

			-- 🛡️ NEW: instantly destroy if it hits a shield bubble
			if hit.Name == "TargetShieldBubble" then
				hasHit = true
				projectile:Destroy()
				return
			end

			local target = findDamageableModel(hit)
			if not target then return end

			-- Read damage from root attributes (set by turret)
			local damage = projectile:GetAttribute("Damage") or 10

			local healthVal = target:FindFirstChild("Health")
			if healthVal and healthVal:IsA("NumberValue") then
				hasHit = true
				healthVal.Value = math.max(0, healthVal.Value - damage)
				projectile:Destroy()
			end
		end)
	end
end

-- Start listening once the projectile is in Workspace
task.defer(function()
	connectTouches(projectile)

	-- Safety cleanup using attribute set by Turret
	local lifetime = projectile:GetAttribute("Lifetime") or 500
	Debris:AddItem(projectile, lifetime)
end)
