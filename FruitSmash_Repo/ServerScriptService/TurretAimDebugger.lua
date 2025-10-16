-- TurretAimDebugger: confirms each turret finds a target and a muzzle
local Workspace = game:GetService("Workspace")

local function getMuzzleCF(turretModel: Model): CFrame?
	local barrel = turretModel:FindFirstChild("Barrel")
	if not (barrel and barrel:IsA("BasePart")) then return nil end
	local muzzle = barrel:FindFirstChild("MuzzleAttachment")
	return (muzzle and muzzle:IsA("Attachment")) and muzzle.WorldCFrame or barrel.CFrame
end

local lanes = Workspace:FindFirstChild("Lanes")
if not (lanes and lanes:IsA("Folder")) then
	warn("[TurretAimDebugger] No Workspace/Lanes folder; using single-target mode?")
	return
end

for _, lane in ipairs(lanes:GetChildren()) do
	if lane:IsA("Folder") then
		local turret = lane:FindFirstChild("Turret")
		local target = lane:FindFirstChild("Target")
		if turret and turret:IsA("Model") and target and target:IsA("Model") then
			local hb = target:FindFirstChild("Hitbox")
			local mu = getMuzzleCF(turret)
			print(("[TurretAimDebugger] %s -> Target:%s Hitbox:%s Muzzle:%s")
				:format(lane.Name, target.Name, hb and "OK" or "MISSING", mu and "OK" or "MISSING"))
		else
			warn(("[TurretAimDebugger] %s missing Turret or Target"):format(lane.Name))
		end
	end
end
