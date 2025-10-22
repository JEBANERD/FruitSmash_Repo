--!strict

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StatsService = game:GetService("Stats")
local WorkspaceService = game:GetService("Workspace")

local SAMPLE_INTERVAL = 1
local FRAME_MAX_BUDGET = 1 / 45 -- ~22ms
local FRAME_AVG_BUDGET = 1 / 58 -- ~17ms
local GC_DELTA_BUDGET_MB = 4
local PROJECTILE_PART_BUDGET = 350
local VFX_INSTANCE_BUDGET = 175
local WARNING_COOLDOWN = 10

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
        remotesFolder = Instance.new("Folder")
        remotesFolder.Name = "Remotes"
        remotesFolder.Parent = ReplicatedStorage
end

local perfEvent = remotesFolder:FindFirstChild("PerfHarnessUpdate")
if perfEvent and not perfEvent:IsA("RemoteEvent") then
        perfEvent:Destroy()
        perfEvent = nil
end
if not perfEvent then
        perfEvent = Instance.new("RemoteEvent")
        perfEvent.Name = "PerfHarnessUpdate"
        perfEvent.Parent = remotesFolder
end

local function safeGetDescendants(target: Instance): { Instance }
        local ok, result = pcall(function()
                return target:GetDescendants()
        end)
        if ok and type(result) == "table" then
                return result :: { Instance }
        end
        return {}
end

local function countProjectiles(descendants: { Instance }): number
        local total = 0
        for _, inst in ipairs(descendants) do
                if inst:IsA("BasePart") then
                        local nameLower = string.lower(inst.Name)
                        if string.find(nameLower, "projectile") then
                                total += 1
                        else
                                local parent = inst.Parent
                                if parent then
                                        local parentName = string.lower(parent.Name)
                                        if string.find(parentName, "projectile") then
                                                total += 1
                                        end
                                end
                        end
                end
        end
        return total
end

local function countVfx(): number
        local folder = WorkspaceService:FindFirstChild("VFXBusEffects")
        if not folder then
                return 0
        end
        local ok, result = pcall(function()
                return folder:GetDescendants()
        end)
        if ok and type(result) == "table" then
                return #result
        end
        return 0
end

type WarningTracker = { [string]: number }

local lastWarnings: WarningTracker = {}

local function pushWarning(kind: string, message: string, warnings: { string })
        table.insert(warnings, message)
        local now = os.clock()
        local last = lastWarnings[kind] or 0
        if now - last >= WARNING_COOLDOWN then
                warn(string.format("[PerfHarness] %s", message))
                lastWarnings[kind] = now
        end
end

local frameAccumulator = 0
local frameSamples = 0
local frameMax = 0
local lastSampleTime = os.clock()
local lastGcMb = collectgarbage("count") / 1024

local function getTotalInstanceCount(): number
        local statsValue = StatsService:FindFirstChild("InstanceCount")
        if statsValue and statsValue:IsA("IntValue") then
                return statsValue.Value
        end
        local altStats = StatsService:FindFirstChild("DataModelInstanceTreeCount")
        if altStats and altStats:IsA("IntValue") then
                return altStats.Value
        end
        local ok, descendants = pcall(function()
                return game:GetDescendants()
        end)
        if ok and type(descendants) == "table" then
                return #descendants
        end
        return 0
end

type PerfSample = {
        timestamp: number,
        dtAverage: number,
        dtMax: number,
        gcMb: number,
        gcDeltaMb: number,
        totalInstances: number,
        workspaceInstances: number,
        projectileParts: number,
        vfxInstances: number,
        totalMemoryMb: number?,
        warnings: { string },
        budgets: {
                frameMax: number,
                frameAverage: number,
                gcDelta: number,
                projectiles: number,
                vfx: number,
        },
}

local function emitSample(sample: PerfSample)
        perfEvent:FireAllClients(sample)
end

RunService.Heartbeat:Connect(function(dt: number)
        frameAccumulator += dt
        frameSamples += 1
        if dt > frameMax then
                frameMax = dt
        end

        local now = os.clock()
        if now - lastSampleTime < SAMPLE_INTERVAL then
                return
        end

        local averageDt = if frameSamples > 0 then frameAccumulator / frameSamples else dt
        local workspaceDescendants = safeGetDescendants(WorkspaceService)
        local workspaceCount = #workspaceDescendants
        local projectileCount = countProjectiles(workspaceDescendants)
        local vfxCount = countVfx()
        local gcMb = collectgarbage("count") / 1024
        local gcDelta = gcMb - lastGcMb
        lastGcMb = gcMb

        local totalInstanceCount = getTotalInstanceCount()
        local warnings: { string } = {}
        local triggeredKinds: { [string]: boolean } = {}

        if frameMax > FRAME_MAX_BUDGET and not triggeredKinds.frame then
                triggeredKinds.frame = true
                pushWarning(
                        "frame",
                        string.format(
                                "Frame budget exceeded: max %.1f ms (avg %.1f ms). Investigate projectile load (parts=%d).",
                                frameMax * 1000,
                                averageDt * 1000,
                                projectileCount
                        ),
                        warnings
                )
        elseif averageDt > FRAME_AVG_BUDGET and not triggeredKinds.frameAvg then
                triggeredKinds.frameAvg = true
                pushWarning(
                        "frameAvg",
                        string.format(
                                "Frame average high: %.1f ms (budget %.1f ms).",
                                averageDt * 1000,
                                FRAME_AVG_BUDGET * 1000
                        ),
                        warnings
                )
        end

        if gcDelta > GC_DELTA_BUDGET_MB and not triggeredKinds.gc then
                triggeredKinds.gc = true
                pushWarning(
                        "gc",
                        string.format(
                                "GC allocation %.1f MB in last %.1fs. Check lingering VFX (instances=%d).",
                                gcDelta,
                                SAMPLE_INTERVAL,
                                vfxCount
                        ),
                        warnings
                )
        end

        if projectileCount > PROJECTILE_PART_BUDGET and not triggeredKinds.projectile then
                triggeredKinds.projectile = true
                pushWarning(
                        "projectile",
                        string.format(
                                "Projectile part count %d over budget %d.",
                                projectileCount,
                                PROJECTILE_PART_BUDGET
                        ),
                        warnings
                )
        end

        if vfxCount > VFX_INSTANCE_BUDGET and not triggeredKinds.vfx then
                triggeredKinds.vfx = true
                pushWarning(
                        "vfx",
                        string.format(
                                "VFX instance count %d over budget %d.",
                                vfxCount,
                                VFX_INSTANCE_BUDGET
                        ),
                        warnings
                )
        end

        local totalMemoryMb = nil
        local okTotalMemory, totalMemoryResult = pcall(function()
                return StatsService:GetTotalMemoryUsageMb()
        end)
        if okTotalMemory and typeof(totalMemoryResult) == "number" then
                totalMemoryMb = totalMemoryResult
        end

        emitSample({
                timestamp = now,
                dtAverage = averageDt,
                dtMax = frameMax,
                gcMb = gcMb,
                gcDeltaMb = gcDelta,
                totalInstances = totalInstanceCount,
                workspaceInstances = workspaceCount,
                projectileParts = projectileCount,
                vfxInstances = vfxCount,
                totalMemoryMb = totalMemoryMb,
                warnings = warnings,
                budgets = {
                        frameMax = FRAME_MAX_BUDGET,
                        frameAverage = FRAME_AVG_BUDGET,
                        gcDelta = GC_DELTA_BUDGET_MB,
                        projectiles = PROJECTILE_PART_BUDGET,
                        vfx = VFX_INSTANCE_BUDGET,
                },
        })

        frameAccumulator = 0
        frameSamples = 0
        frameMax = 0
        lastSampleTime = now
end)
