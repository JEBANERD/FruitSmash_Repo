--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local playerGui: PlayerGui = localPlayer:WaitForChild("PlayerGui")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local perfEvent = remotesFolder:WaitForChild("PerfHarnessUpdate") :: RemoteEvent

local hud: ScreenGui = Instance.new("ScreenGui")
hud.Name = "PerfHUD"
hud.DisplayOrder = 9999
hud.ResetOnSpawn = false
hud.IgnoreGuiInset = false
hud.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
hud.Parent = playerGui

local container: Frame = Instance.new("Frame")
container.Name = "PerfContainer"
container.AnchorPoint = Vector2.new(0, 0)
container.Position = UDim2.new(0, 12, 0, 12)
container.Size = UDim2.new(0, 320, 0, 176)
container.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
container.BackgroundTransparency = 0.35
container.BorderSizePixel = 0
container.Parent = hud

local titleLabel: TextLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.BackgroundTransparency = 1
titleLabel.Position = UDim2.new(0, 8, 0, 6)
titleLabel.Size = UDim2.new(1, -16, 0, 20)
titleLabel.Font = Enum.Font.Code
titleLabel.Text = "Perf Harness"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.TextSize = 16
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = container

local metricsLabel: TextLabel = Instance.new("TextLabel")
metricsLabel.Name = "Metrics"
metricsLabel.BackgroundTransparency = 1
metricsLabel.Position = UDim2.new(0, 8, 0, 28)
metricsLabel.Size = UDim2.new(1, -16, 0, 80)
metricsLabel.Font = Enum.Font.Code
metricsLabel.Text = "Awaiting server sample..."
metricsLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
metricsLabel.TextSize = 14
metricsLabel.TextXAlignment = Enum.TextXAlignment.Left
metricsLabel.TextYAlignment = Enum.TextYAlignment.Top
metricsLabel.TextWrapped = true
metricsLabel.Parent = container

local warningLabel: TextLabel = Instance.new("TextLabel")
warningLabel.Name = "Warnings"
warningLabel.BackgroundTransparency = 1
warningLabel.Position = UDim2.new(0, 8, 0, 112)
warningLabel.Size = UDim2.new(1, -16, 0, 56)
warningLabel.Font = Enum.Font.Code
warningLabel.Text = "Warnings: none"
warningLabel.TextColor3 = Color3.fromRGB(255, 185, 100)
warningLabel.TextSize = 14
warningLabel.TextXAlignment = Enum.TextXAlignment.Left
warningLabel.TextYAlignment = Enum.TextYAlignment.Top
warningLabel.TextWrapped = true
warningLabel.Parent = container

local renderAccumulator = 0
local renderSamples = 0
local renderMax = 0
local lastRenderFlush = os.clock()

RunService.RenderStepped:Connect(function(dt: number)
        renderAccumulator += dt
        renderSamples += 1
        if dt > renderMax then
                renderMax = dt
        end
end)

type PerfBudgets = {
        frameMax: number?,
        frameAverage: number?,
        gcDelta: number?,
        projectiles: number?,
        vfx: number?,
}

type PerfSample = {
        timestamp: number?,
        dtAverage: number?,
        dtMax: number?,
        gcMb: number?,
        gcDeltaMb: number?,
        totalInstances: number?,
        workspaceInstances: number?,
        projectileParts: number?,
        vfxInstances: number?,
        totalMemoryMb: number?,
        warnings: { string }?,
        budgets: PerfBudgets?,
}

local lastServerSample: PerfSample = {}

local function ms(value: number?): string
        if not value then
                return "n/a"
        end
        return string.format("%.1f", value * 1000)
end

local function mb(value: number?): string
        if not value then
                return "n/a"
        end
        return string.format("%.1f", value)
end

local function formatInt(value: number?): string
        if not value then
                return "n/a"
        end
        return string.format("%d", value)
end

local function flushRenderStats()
        local now = os.clock()
        local average = if renderSamples > 0 then renderAccumulator / renderSamples else 0
        local maxDt = renderMax
        renderAccumulator = 0
        renderSamples = 0
        renderMax = 0
        lastRenderFlush = now
        return average, maxDt
end

local function applyWarningState(hasWarning: boolean)
        if hasWarning then
                container.BackgroundColor3 = Color3.fromRGB(90, 20, 20)
                container.BackgroundTransparency = 0.25
                warningLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
        else
                container.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
                container.BackgroundTransparency = 0.35
                warningLabel.TextColor3 = Color3.fromRGB(255, 185, 100)
        end
end

local function render(sample: PerfSample)
        local avgRender, maxRender = flushRenderStats()
        local serverMax = sample.dtMax or 0
        local gcDelta = sample.gcDeltaMb or 0
        local totalMemory = sample.totalMemoryMb
        local projectileParts = sample.projectileParts or 0
        local vfxInstances = sample.vfxInstances or 0
        local budgets = sample.budgets or {}

        local metricsText = table.concat({
                string.format(
                        "Srv Δt avg %sms (max %sms)",
                        ms(sample.dtAverage),
                        ms(sample.dtMax)
                ),
                string.format(
                        "Cli Δt avg %sms (max %sms)",
                        ms(avgRender),
                        ms(maxRender)
                ),
                string.format(
                        "GC Δ %s MB | total %s MB",
                        mb(sample.gcDeltaMb),
                        mb(totalMemory or sample.gcMb)
                ),
                string.format(
                        "Instances %s workspace=%s",
                        formatInt(sample.totalInstances),
                        formatInt(sample.workspaceInstances)
                ),
                string.format(
                        "Projectiles %d/%s | VFX %d/%s",
                        projectileParts,
                        budgets.projectiles and tostring(budgets.projectiles) or "-",
                        vfxInstances,
                        budgets.vfx and tostring(budgets.vfx) or "-"
                ),
        }, "\n")

        metricsLabel.Text = metricsText

        local warningsArray = sample.warnings or {}
        if #warningsArray == 0 then
                warningLabel.Text = "Warnings: none"
        else
                warningLabel.Text = "Warnings:\n" .. table.concat(warningsArray, "\n")
        end

        applyWarningState(#warningsArray > 0 or serverMax > (budgets.frameMax or math.huge) or gcDelta > (budgets.gcDelta or math.huge))
end

perfEvent.OnClientEvent:Connect(function(sample: PerfSample)
        lastServerSample = sample
        render(sample)
end)

-- If the server harness hasn't sent data yet, periodically render local metrics.
task.spawn(function()
        while true do
                task.wait(1)
                if next(lastServerSample) ~= nil then
                        render(lastServerSample)
                else
                        local avgRender, maxRender = flushRenderStats()
                        metricsLabel.Text = string.format(
                                "Cli Δt avg %sms (max %sms)\nWaiting for server...",
                                ms(avgRender),
                                ms(maxRender)
                        )
                end
        end
end)
