-- AutoFire (round-aware, lane-safe, hard-gated by GameActive)
-- Supports shielded targets (ShieldActive + TargetShieldActive): damage blocked and self-syncs flags.

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local Modules = RS:WaitForChild("Modules")
local ShieldState = require(Modules:WaitForChild("ShieldState"))

local Motion = require(RS:WaitForChild("ProjectileMotion"))
local Presets = require(RS:WaitForChild("ProjectilePresets"))

local _connections = {}
local function track(conn)
        table.insert(_connections, conn)
        return conn
end

local function cleanupConnections()
        for i = #_connections, 1, -1 do
                local conn = _connections[i]
                if conn then
                        local ok, err = pcall(function()
                                if conn.Disconnect then
                                        conn:Disconnect()
                                end
                        end)
                        if not ok then
                                warn("[AutoFire] Failed to disconnect connection:", err)
                        end
                end
                _connections[i] = nil
        end
end

local Remotes = RS:FindFirstChild("Remotes")
local GameOverEvent = Remotes and Remotes:FindFirstChild("GameOverEvent")
local GameActive = RS:WaitForChild("GameActive")

-- Optional round intensity
local RoundState = RS:FindFirstChild("RoundState")
local RoundIntensity = RoundState and RoundState:FindFirstChild("RoundIntensity")

-- Projectiles container
local ProjectilesFolder = RS:WaitForChild("Projectiles")
local ActiveProjectiles = Workspace:FindFirstChild("ActiveProjectiles") or Instance.new("Folder", Workspace)
ActiveProjectiles.Name = "ActiveProjectiles"

-- ===== Tunables =====
local DEBUG_TURRET = false

local FIRE_INTERVAL_BASE = 3.0
local FIRE_INTERVAL_RANDOMNESS = 0.6
local FRUITS = { "Apple", "Banana", "Orange", "Grape", "Pineapple" }
local BARREL_SPAWN_BACKOFF = 1.0
local INVERT_FORWARD = false

local FIRE_COOLDOWN_BASE = 0.6
local FIRE_COOLDOWN_MIN = 0.15

-- Flight / lifetime
local MAXTIME_MULT = 1.35
local MAXTIME_PAD  = 0.75
local MAXTIME_MIN  = 3
local MAXTIME_MAX  = 60
local CLEANUP_PAD  = 2.0
local CLEANUP_MIN  = 5
local CLEANUP_MAX  = 90

-- Visual
local DAMAGE_FLASH_COLOR = Color3.fromRGB(255, 90, 90)
local DAMAGE_FLASH_TIME  = 0.10
local SHIELD_FLASH_COLOR = Color3.fromRGB(0, 200, 255)
local SHIELD_FLASH_TIME  = 0.20
local PROX_HIT_TOLERANCE = 12

-- ===== Helpers =====
local function intensityFactor()
	local i = (RoundIntensity and RoundIntensity.Value) or 1
	return math.clamp(1.0 + 0.25 * (i - 1), 0.5, 2.0)
end

local turret = script.Parent
if not turret or not turret:IsDescendantOf(Workspace) then return end

local function normalizePath(s)
	if not s then return "linear" end
	s = string.lower(s)
	if s == "linear" or s == "bezier" or s == "zigzag" or s == "bounce" then return s end
	return "linear"
end

local function ensurePrimaryPart(m)
	if m.PrimaryPart then return end
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			m.PrimaryPart = d
			return
		end
	end
end

local function buildIgnoreList(extra)
	local ignore = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then table.insert(ignore, plr.Character) end
	end
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Tool") then table.insert(ignore, inst) end
	end
	if extra then for _, v in ipairs(extra) do table.insert(ignore, v) end end
	return ignore
end

local function addCommonIgnores(ignore)
	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate then table.insert(ignore, baseplate) end
	if Workspace:FindFirstChild("Terrain") then table.insert(ignore, Workspace.Terrain) end
	local ap = Workspace:FindFirstChild("ActiveProjectiles")
	if ap then table.insert(ignore, ap) end
end

local function addAttributeIgnores(ignore)
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:GetAttribute("ProjectileIgnore") then
			table.insert(ignore, inst)
		end
	end
end

-- === SHIELD UTILITIES ===
local TargetShieldGlobal = RS:FindFirstChild("TargetShieldActive")
local SHIELD_DURATION = 15 -- must match PowerupEffects

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

-- Ensures both local and global flags toggle off after duration
local function verifyShieldExpiry()
	task.delay(SHIELD_DURATION + 0.25, function()
		local activeFound = false
	for _, t in ipairs(getAllTargets()) do
                        if ShieldState.Get(t) then
                                activeFound = true
                                break
                        end
                end
                if not activeFound and TargetShieldGlobal and TargetShieldGlobal.Value then
                        TargetShieldGlobal.Value = false
                        print("[AutoFire] ✅ Shield auto-cleared (global flag reset).")
                end
        end)
end

-- Real-time sync listener: ensures all turrets match global state immediately
if TargetShieldGlobal then
        track(TargetShieldGlobal:GetPropertyChangedSignal("Value"):Connect(function()
                local newVal = TargetShieldGlobal.Value
                if newVal then
                        print("[AutoFire] 🛡️ Global shield active — syncing local flags.")
                        for _, t in ipairs(getAllTargets()) do
                                ShieldState.Set(t, true)
                        end
                        verifyShieldExpiry()
                else
                        print("[AutoFire] 🔓 Global shield deactivated — clearing all lanes.")
                        for _, t in ipairs(getAllTargets()) do
                                ShieldState.Set(t, false)
                        end
                end
        end))
end

-- === Lane-aware target (fallback to Workspace.Target)
local function getLaneAndTarget()
        local lanes = Workspace:FindFirstChild("Lanes")
	local lane = turret:FindFirstAncestorWhichIsA("Folder")
	if lanes and lane and lane.Parent == lanes then
		local t = lane:FindFirstChild("Target")
		if t and t:IsA("Model") then
			local hitbox = t:FindFirstChild("Hitbox")
			local health = t:FindFirstChild("Health")
			if hitbox and hitbox:IsA("BasePart") and health and health:IsA("NumberValue") then
				return lane, t, hitbox, health
			end
		end
	end
	local t = Workspace:FindFirstChild("Target")
	if t and t:IsA("Model") then
		local hitbox = t:FindFirstChild("Hitbox")
		local health = t:FindFirstChild("Health")
		if hitbox and hitbox:IsA("BasePart") and health and health:IsA("NumberValue") then
			return nil, t, hitbox, health
		end
	end
	return nil
end

local function getMuzzleCF()
	local model = turret:IsA("Model") and turret or turret:FindFirstAncestorOfClass("Model")
	if not model then return nil end
	local barrel = model:FindFirstChild("Barrel")
	if not (barrel and barrel:IsA("BasePart")) then return nil end
	local muzzle = barrel:FindFirstChild("MuzzleAttachment")
	local cf = (muzzle and muzzle:IsA("Attachment")) and muzzle.WorldCFrame or barrel.CFrame
	local fwd = cf.LookVector
	if INVERT_FORWARD then fwd = -fwd end
	return CFrame.new(cf.Position + fwd * BARREL_SPAWN_BACKOFF, cf.Position + fwd * 2)
end

local function flashTargetSkin(targetModel, color, dur)
	local skinFolder = targetModel:FindFirstChild("Skin")
	if not skinFolder then return end
	local recs = {}
	for _, d in ipairs(skinFolder:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(recs, {p=d, c=d.Color, m=d.Material})
			d.Color = color
			if d.Material ~= Enum.Material.Neon then d.Material = Enum.Material.Neon end
		end
	end
	task.delay(math.max(0.03, dur or 0.1), function()
		for _, r in ipairs(recs) do
			if r.p and r.p.Parent then
				r.p.Color = r.c
				r.p.Material = r.m
			end
		end
	end)
end

-- === DAMAGE APPLY (checks for ShieldActive and global)
local function applyDamageToTarget(target, health, dmg)
	if not target or not health then return end

	local shieldUp = ShieldState.Get(target)
    local globalActive = TargetShieldGlobal and TargetShieldGlobal.Value
    if shieldUp or globalActive then
            print("[AutoFire] 🔵 Hit blocked by active shield!")
            local hitbox = target:FindFirstChild("Hitbox")
            if hitbox then
                    local originalColor = hitbox.Color
			hitbox.Color = SHIELD_FLASH_COLOR
			task.delay(SHIELD_FLASH_TIME, function()
				if hitbox and hitbox.Parent then
					hitbox.Color = originalColor
				end
			end)
		end
		return
	end

	-- Normal damage path
	health.Value = math.max(0, (health.Value or 0) - math.max(0, dmg or 0))
	flashTargetSkin(target, DAMAGE_FLASH_COLOR, DAMAGE_FLASH_TIME)

	if health.Value <= 0 then
		if GameOverEvent and GameOverEvent:IsA("RemoteEvent") then
			GameOverEvent:FireAllClients("GAME OVER", "A lane was destroyed.")
		end
		if GameActive then GameActive.Value = false end
	end
end


-- ===== Fire Logic =====
local function chooseFruitName()
	if #FRUITS == 0 then return "Apple" end
	return FRUITS[math.random(1, #FRUITS)]
end

local function resolveTemplate(fruitName)
	local container = ProjectilesFolder:FindFirstChild(fruitName)
	if not container then return nil end
	if container:IsA("Folder") then
		return container:FindFirstChildWhichIsA("Model") or container:FindFirstChildWhichIsA("BasePart")
	end
	if container:IsA("Model") or container:IsA("BasePart") then
		return container
	end
	return nil
end

-- ===== One Shot =====
local function fireOnce()
        if not GameActive.Value then return false end

        local lane, target, hitbox, health = getLaneAndTarget()
        if not target or not hitbox or not health then return false end

        local muzzleCF = getMuzzleCF()
        if not muzzleCF then return false end

        local fruitName = chooseFruitName()
        local template = resolveTemplate(fruitName)
        if not template then return false end

        local proj = template:Clone()
        proj:SetAttribute("FruitName", fruitName)

        local preset = Presets[fruitName] or Presets._Default
        local damage = preset.Damage or 10
        proj:SetAttribute("Damage", damage)
        proj:SetAttribute("Lifetime", 60)

        if proj:IsA("Model") then ensurePrimaryPart(proj) end
        proj.Parent = ActiveProjectiles

        local startPos = muzzleCF.Position
        local endPos   = hitbox.Position

        local speed = preset.Speed or 10
        local path  = normalizePath(preset.Path or "Linear")

        local dist    = (endPos - startPos).Magnitude
        local raw     = dist / math.max(speed, 0.01)
        local maxTime = math.clamp(raw * MAXTIME_MULT + MAXTIME_PAD, MAXTIME_MIN, MAXTIME_MAX)
        local cleanup = math.clamp(maxTime + CLEANUP_PAD, CLEANUP_MIN, CLEANUP_MAX)

        local ignore = buildIgnoreList({proj})
        addCommonIgnores(ignore)
        addAttributeIgnores(ignore)

        local function onHit(hitInst)
                local isTargetHit = hitInst and hitInst:IsDescendantOf(target) or false
                if not isTargetHit then
                        local rootPart = proj:IsA("Model") and proj.PrimaryPart or (proj:IsA("BasePart") and proj or nil)
                        if rootPart then
                                local d = (rootPart.Position - hitbox.Position).Magnitude
                                if d <= PROX_HIT_TOLERANCE then
                                        isTargetHit = true
                                end
                        end
                end

                if isTargetHit then
                        applyDamageToTarget(target, health, damage)
                end

                Debris:AddItem(proj, 0)
        end

        Motion.Launch(proj, startPos, endPos, {
                Speed = speed,
                Path = path,
                ControlOffset = preset.ControlOffset,
                Amplitude = preset.Amplitude,
                Frequency = preset.Frequency,
                MaxTime = maxTime,
                IgnoreInstances = ignore,
                OnHit = onHit,
        })

        Debris:AddItem(proj, cleanup)
        return true
end

-- ===== Fire Modes =====
local fireTrigger = turret:FindFirstChild("FireTrigger")
if not fireTrigger then
        fireTrigger = Instance.new("BindableEvent")
        fireTrigger.Name = "FireTrigger"
        fireTrigger.Parent = turret
end

local nextFireTime = 0

local function computeCooldownSeconds()
        local baseAttr = turret:GetAttribute("FireCooldown")
        local base = (typeof(baseAttr) == "number" and baseAttr) or FIRE_COOLDOWN_BASE
        local scale = intensityFactor()
        local cooldown = base / math.max(scale, 0.5)
        return math.max(FIRE_COOLDOWN_MIN, cooldown)
end

local function setNextFireAttribute(value)
        if not turret then return end
        local ok, err = pcall(function()
                turret:SetAttribute("NextFireTime", value)
        end)
        if not ok and DEBUG_TURRET then
                warn("[AutoFire] Failed to set NextFireTime", err)
        end
end

local function beginCooldown()
        local cooldown = computeCooldownSeconds()
        nextFireTime = os.clock() + cooldown
        setNextFireAttribute(nextFireTime)
        if DEBUG_TURRET then
                print(string.format("[AutoFire] ⏳ cooldown %.2fs", cooldown))
        end
        return cooldown
end

local cleaned = false

local function clearCooldown()
        nextFireTime = 0
        setNextFireAttribute(nil)
end

local function cleanup()
    if cleaned then return end
        cleaned = true
        cleanupConnections()
        clearCooldown()
end    

if turret.Destroying then
        track(turret.Destroying:Connect(cleanup))
end

track(turret.AncestryChanged:Connect(function()
        if not turret:IsDescendantOf(Workspace) then
                cleanup()
        end
end))

track(GameActive.Changed:Connect(function()
        if not GameActive.Value then
                clearCooldown()
                if DEBUG_TURRET then
                        print("[AutoFire] 💤 cooldown cleared (round inactive)")
                end
        end
end))

track(fireTrigger.Event:Connect(function()
        if not GameActive.Value then return end
        local now = os.clock()
        if now < nextFireTime then
                if DEBUG_TURRET then
                        local remaining = math.max(0, nextFireTime - now)
                        print(string.format("[AutoFire] 🔁 trigger ignored (%.2fs remaining)", remaining))
                end
                return
        end

        if DEBUG_TURRET then
                print("[AutoFire] 🔔 trigger received")
        end

        beginCooldown()
        local fired = fireOnce()
        if not fired then
                        if DEBUG_TURRET then
                                print("[AutoFire] ⚠️ firing aborted, cooldown cleared")
                        end
                        clearCooldown()
        end
end))

if script.Destroying then
        track(script.Destroying:Connect(cleanup))
end


