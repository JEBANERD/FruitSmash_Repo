-- HealthController (SERVER)
-- Blocks and reverts damage while ShieldState reports ShieldActive = true.
-- Syncs with global TargetShieldActive flag. Cleans up shield bubbles when off.
-- Updates health bar UI and triggers GameOver when HP <= 0.

local target: Instance = script.Parent
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Modules = RS:WaitForChild("Modules")
local ShieldState = require(Modules:WaitForChild("ShieldState"))

local DEBUG_SHIELD = false

local function debugShield(...)
        if DEBUG_SHIELD then
                print("[HealthController]", ...)
        end
end

-- Required children
local hitbox: BasePart = target:WaitForChild("Hitbox")
local maxHealth: NumberValue = target:WaitForChild("MaxHealth")
local health: NumberValue = target:WaitForChild("Health")

-- Optional global pause
local Remotes = RS:FindFirstChild("Remotes")
local GameOverEvent = Remotes and Remotes:FindFirstChild("GameOverEvent")
local GameActive: BoolValue? = RS:FindFirstChild("GameActive") :: BoolValue?

-- ========= GLOBAL SHIELD FLAG =========
-- This is the master toggle shared across all lanes and turrets.
local TargetShieldFlag: BoolValue = RS:FindFirstChild("TargetShieldActive") :: BoolValue
if not TargetShieldFlag then
        TargetShieldFlag = Instance.new("BoolValue")
        TargetShieldFlag.Name = "TargetShieldActive"
        TargetShieldFlag.Value = false
        TargetShieldFlag.Parent = RS
end

-- ========= OPTIONAL UI =========
local gui = hitbox:FindFirstChild("HealthGui")
local barBg = gui and gui:FindFirstChild("BarBg")
local barFill = barBg and barBg:FindFirstChild("BarFill")
local label = barBg and barBg:FindFirstChild("HPLabel")

-- ========= HELPERS =========
local function updateBar()
        if barFill and barFill:IsA("Frame") then
                local ratio = math.clamp(health.Value / math.max(1e-6, maxHealth.Value), 0, 1)
                barFill.Size = UDim2.fromScale(ratio, 1)
                barFill.BackgroundColor3 = Color3.new(1 - ratio, ratio, 0)
        end
        if label and label:IsA("TextLabel") then
                label.Text = string.format("%d / %d", math.floor(health.Value + 0.5), maxHealth.Value)
        end
end

local function flash(color: Color3, dur: number)
        local original = hitbox.Color
        hitbox.Color = color
        TweenService:Create(hitbox, TweenInfo.new(math.max(0.05, dur or 0.15)), {Color = original}):Play()
end

-- Removes any existing shield bubbles for this target
local function destroyShieldBubbles()
        for _, d in ipairs(target:GetChildren()) do
                if d:IsA("BasePart") and d.Name == "TargetShieldBubble" then
                        d:Destroy()
                end
        end
end

local function ensureShieldAttribute()
        if target:GetAttribute("ShieldActive") == nil then
                ShieldState.Set(target, false)
        end
end

-- ========= INIT =========
ensureShieldAttribute()
if health.Value <= 0 then
        health.Value = maxHealth.Value
end
hitbox.Transparency = 0.99
updateBar()

-- Track last valid health
local lastSafe = health.Value
local reverting = false

-- ========= GLOBAL → LOCAL MIRROR =========
TargetShieldFlag.Changed:Connect(function()
        if TargetShieldFlag.Value then
                ShieldState.Set(target, true)
                debugShield("Global shield ON →", target.Name)
        else
                ShieldState.Set(target, false)
                destroyShieldBubbles()
                debugShield("Global shield OFF →", target.Name)
        end
end)

-- ========= ATTRIBUTE LISTENER =========
target:GetAttributeChangedSignal("ShieldActive"):Connect(function()
        if ShieldState.Get(target) then
                debugShield("Shield attribute active for", target.Name)
        else
                destroyShieldBubbles()
                debugShield("Shield attribute cleared for", target.Name)
        end
end)

-- ========= CORE DAMAGE LOGIC =========
health:GetPropertyChangedSignal("Value"):Connect(function()
        if reverting then return end

        -- Clamp upper bound
        if health.Value > maxHealth.Value then
                reverting = true
                health.Value = maxHealth.Value
                reverting = false
        end

        -- Recheck current shield state
        local shieldUp = ShieldState.Get(target)
        if shieldUp and health.Value < lastSafe then
                flash(Color3.fromRGB(0, 180, 255), 0.20)
                reverting = true
                health.Value = lastSafe
                reverting = false
                updateBar()
                return
        end

        lastSafe = health.Value
        updateBar()

        -- Game Over condition
        if health.Value <= 0 then
                TweenService:Create(hitbox, TweenInfo.new(0.25), {Transparency = 1}):Play()
                if GameOverEvent and GameOverEvent:IsA("RemoteEvent") then
                        GameOverEvent:FireAllClients()
                end
                if GameActive then
                        GameActive.Value = false
                end
        end
end)

-- ========= SAFETY MONITOR =========
task.spawn(function()
        while target.Parent do
                if not TargetShieldFlag.Value and ShieldState.Get(target) then
                        ShieldState.Set(target, false)
                        destroyShieldBubbles()
                        debugShield("🔧 Auto-corrected lingering shield for", target.Name)
                end
                ensureShieldAttribute()
                task.wait(5)
        end
end)
