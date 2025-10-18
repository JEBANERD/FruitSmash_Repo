-- LaneValidator: prints missing parts per lane so you can fix quickly
local Workspace = game:GetService("Workspace")

local function checkTargetModel(target)
	local ok, problems = true, {}
	local hitbox = target and target:FindFirstChild("Hitbox")
	local health = target and target:FindFirstChild("Health")
	local max    = target and target:FindFirstChild("MaxHealth")

	if not (hitbox and hitbox:IsA("BasePart")) then ok=false; table.insert(problems,"Hitbox(BasePart)") end
	if not (health and health:IsA("NumberValue")) then ok=false; table.insert(problems,"Health(NumberValue)") end
	if not (max and max:IsA("NumberValue")) then ok=false; table.insert(problems,"MaxHealth(NumberValue)") end

	return ok, problems
end

local function scan()
	local lanes = Workspace:FindFirstChild("Lanes")
	if not (lanes and lanes:IsA("Folder")) then
		warn("[LaneValidator] Workspace/Lanes not found. Using single-target mode?")
		return
	end

	for _, lane in ipairs(lanes:GetChildren()) do
		if lane:IsA("Folder") then
			local turret = lane:FindFirstChild("Turret")
			local target = lane:FindFirstChild("Target")
			if not turret then
				warn(("[-] %s missing Turret model"):format(lane.Name))
			end
			if not target then
				warn(("[-] %s missing Target model"):format(lane.Name))
			else
				local ok, problems = checkTargetModel(target)
				if not ok then
					warn(("[-] %s Target missing: %s"):format(lane.Name, table.concat(problems,", ")))
				else
					print(("[+] %s Target OK"):format(lane.Name))
				end
			end
		end
	end
end

scan()
