-- FastStartRingSpawner (robust boot + state-driven)
-- Spawns a ring as soon as possible at server start, then whenever GameActive == false.
-- If template isn't ready yet, it retries until it is.

local RS          = game:GetService("ReplicatedStorage")
local Workspace   = game:GetService("Workspace")
local RunService  = game:GetService("RunService")

-- ========= CONFIG =========
local ASSETS_FOLDER_NAME       = "Assets"
local TEMPLATE_NAME            = "FastStartRingTemplate"

-- Spawn mode: "Fixed" or "SpawnPoints" (Workspace/FastStartSpawns)
local SPAWN_MODE               = "Fixed" -- change to "SpawnPoints" if you have spawn markers

-- Fixed placement (used if no spawn points or SPAWN_MODE == "Fixed")
local FIXED_POSITION           = Vector3.new(50, 2, 0)          -- edit me
local FIXED_ROTATION_DEGREES   = Vector3.new(90, 90, 0)         -- 90 on X for a flat cylinder/torus
local FIXED_EXTRA_Y_OFFSET     = 0.05

-- Clean the ring when gameplay starts
local CLEANUP_ON_ACTIVE        = true

-- Boot behavior
local FORCE_SPAWN_ON_BOOT      = true   -- <<< ensures a ring appears at startup
local BOOT_RETRY_INTERVAL      = 0.25   -- seconds between template checks
local BOOT_MAX_RETRIES         = 40     -- ~10s total

-- Live parent for neatness
local LIVE = Workspace:FindFirstChild("FastStartObjects") or Instance.new("Folder", Workspace)
LIVE.Name = "FastStartObjects"

-- ========= Helpers =========
local function radians(v3: Vector3)
	return Vector3.new(math.rad(v3.X), math.rad(v3.Y), math.rad(v3.Z))
end

local function getSpawnPoints(): {BasePart}
	local folder = Workspace:FindFirstChild("FastStartSpawns")
	if not folder or not folder:IsA("Folder") then return {} end
	local pts = {}
	for _, c in ipairs(folder:GetChildren()) do
		if c:IsA("BasePart") then table.insert(pts, c) end
	end
	return pts
end

local function chooseSpawnCFrame(): CFrame
	if SPAWN_MODE == "SpawnPoints" then
		local pts = getSpawnPoints()
		if #pts > 0 then
			local pick = pts[math.random(1, #pts)]
			local yaw   = (pick:GetAttribute("Yaw")   :: number) or 0
			local pitch = (pick:GetAttribute("Pitch") :: number) or 0
			local roll  = (pick:GetAttribute("Roll")  :: number) or 0
			local offY  = (pick:GetAttribute("OffsetY") :: number) or 0
			local pos   = pick.Position + Vector3.new(0, 0.05 + offY, 0)
			local r     = radians(Vector3.new(pitch, yaw, roll))
			return CFrame.new(pos) * CFrame.Angles(r.X, r.Y, r.Z)
		else
			warn("[FastStartRingSpawner] No spawn points in Workspace/FastStartSpawns; using Fixed.")
		end
	end

	local pos = FIXED_POSITION + Vector3.new(0, FIXED_EXTRA_Y_OFFSET, 0)
	local r   = radians(FIXED_ROTATION_DEGREES)
	return CFrame.new(pos) * CFrame.Angles(r.X, r.Y, r.Z)
end

local function ensurePrimaryPart(m: Model)
	if m.PrimaryPart then return end
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then m.PrimaryPart = d; return end
	end
end

local function findExistingRing(): Model?
	for _, c in ipairs(LIVE:GetChildren()) do
		if c:IsA("Model") and c:GetAttribute("IsFastStartRing") then
			return c
		end
	end
	return nil
end

-- Resolve template robustly (waits/retries on boot)
local function getTemplateBlocking(): Model?
	local assets = RS:FindFirstChild(ASSETS_FOLDER_NAME)
	local tries = 0
	while tries < BOOT_MAX_RETRIES do
		if not assets then assets = RS:FindFirstChild(ASSETS_FOLDER_NAME) end
		if assets and assets:IsA("Folder") then
			local tmpl = assets:FindFirstChild(TEMPLATE_NAME)
			if tmpl and tmpl:IsA("Model") then
				return tmpl
			end
		end
		tries += 1
		task.wait(BOOT_RETRY_INTERVAL)
	end
	warn(("[FastStartRingSpawner] Template '%s/%s' not found after retries.")
		:format(ASSETS_FOLDER_NAME, TEMPLATE_NAME))
	return nil
end

local function spawnRing()
	-- Avoid duplicates
	if findExistingRing() then return end

	local tmpl = getTemplateBlocking()
	if not tmpl then return end

	local ok, clone = pcall(function() return (tmpl :: Model):Clone() end)
	if not ok or not clone then
		warn("[FastStartRingSpawner] Failed to clone template.")
		return
	end

	local model: Model = clone
	model.Parent = LIVE
	model.Name = "FastStartRing"
	model:SetAttribute("IsFastStartRing", true)

	ensurePrimaryPart(model)
	local cf = chooseSpawnCFrame()
	if model.PrimaryPart then
		model:PivotTo(cf)
	else
		warn("[FastStartRingSpawner] Template has no BasePart; cannot position accurately.")
	end

	-- sanity for touch
	if model.PrimaryPart then
		model.PrimaryPart.Anchored = true
		model.PrimaryPart.CanCollide = false
		model.PrimaryPart.CanTouch = true
	end

	print("[FastStartRingSpawner] Spawned ring at:", cf.Position)
end

local function cleanupRing()
	local r = findExistingRing()
	if r and r.Parent then
		r:Destroy()
		print("[FastStartRingSpawner] Cleaned existing ring.")
	end
end

-- ========= State wiring =========
local Remotes = RS:WaitForChild("Remotes")
local GameActive: BoolValue = RS:WaitForChild("GameActive") :: BoolValue

-- Boot: force a spawn ASAP
local function bootSpawn()
	if FORCE_SPAWN_ON_BOOT then
		spawnRing()  -- try immediately (even if other scripts still starting)
	end
	-- safety: if nothing spawned yet and we are paused, try again shortly
	task.delay(0.3, function()
		if not GameActive.Value and not findExistingRing() then
			print("[FastStartRingSpawner] Late boot spawn retry.")
			spawnRing()
		end
	end)
end

if RunService:IsRunning() then
	task.defer(bootSpawn)
else
	bootSpawn()
end

-- React to GameActive flips
local last = GameActive.Value
GameActive:GetPropertyChangedSignal("Value"):Connect(function()
	local now = GameActive.Value
	if now == last then return end
	last = now

	if not now then
		-- pre-round: ensure ring exists
		if not findExistingRing() then spawnRing() end
	else
		-- round playing
		if CLEANUP_ON_ACTIVE then cleanupRing() end
	end
end)
