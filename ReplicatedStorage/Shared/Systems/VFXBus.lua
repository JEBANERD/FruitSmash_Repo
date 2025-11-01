--!strict
local VFXBus = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local WorkspaceService = game:GetService("Workspace")

local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
if not assetsFolder then
    error("[VFXBus] ReplicatedStorage.Assets folder is missing")
end

local vfxModule = assetsFolder:FindFirstChild("VFX")
if not vfxModule or not vfxModule:IsA("ModuleScript") then
    error("[VFXBus] ReplicatedStorage.Assets.VFX module is missing")
end

local VFXDefinitions = require(vfxModule)

local rng = Random.new()

local Pools = {}
local PREWARM_EFFECTS = {
    FruitPop = 12,
    CoinBurst = 10,
    ShieldBubble = 4,
    CritSparkle = 6,
}
local ActiveTokens = setmetatable({}, { __mode = "k" })
local ActiveTweens = setmetatable({}, { __mode = "k" })

local nextToken = 0

local worldPoolFolder = ReplicatedStorage:FindFirstChild("VFXBusPool")
if not worldPoolFolder then
    worldPoolFolder = Instance.new("Folder")
    worldPoolFolder.Name = "VFXBusPool"
    worldPoolFolder.Parent = ReplicatedStorage
end

local worldWorkspaceFolder = WorkspaceService:FindFirstChild("VFXBusEffects")
if not worldWorkspaceFolder then
    worldWorkspaceFolder = Instance.new("Folder")
    worldWorkspaceFolder.Name = "VFXBusEffects"
    worldWorkspaceFolder.Parent = WorkspaceService
end

local DEFAULT_UI_ANCHOR = Vector2.new(0.5, 0.5)

local function resolveDefinition(effectName)
    local definition = VFXDefinitions[effectName]
    if not definition then
        warn(('[VFXBus] Unknown effect "%s" requested'):format(tostring(effectName)))
        return nil
    end

    if typeof(definition.Factory) ~= "function" then
        warn(('[VFXBus] Effect "%s" is missing a Factory function'):format(tostring(effectName)))
        return nil
    end

    return definition
end

local function ensurePool(effectName)
    local pool = Pools[effectName]
    if not pool then
        pool = {}
        Pools[effectName] = pool
    end

    return pool
end

local function isDestroyed(instance)
    if not instance then
        return true
    end

    local success = pcall(function()
        return instance.Parent
    end)

    return not success
end

local function cleanupTweens(instance)
    local tween = ActiveTweens[instance]
    if tween then
        ActiveTweens[instance] = nil
        if tween.PlaybackState == Enum.PlaybackState.Playing then
            tween:Cancel()
        end
        tween:Destroy()
    end
end

local function disableEmitters(instance)
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("ParticleEmitter") then
            descendant.Enabled = false
        elseif descendant:IsA("Beam") then
            descendant.Enabled = false
        end
    end
end

local function safeSetParent(instance, parent)
    local success = pcall(function()
        instance.Parent = parent
    end)

    return success
end

local function resolveCountValue(value)
    if value == nil then
        return nil
    end

    local valueType = typeof(value)
    if valueType == "NumberRange" then
        local min = value.Min
        local max = value.Max
        if max < min then
            min, max = max, min
        end
        return math.max(0, math.floor(rng:NextNumber(min, max)))
    elseif valueType == "number" then
        return math.max(0, math.floor(value))
    elseif valueType == "table" then
        local min = value.Min or value[1]
        local max = value.Max or value[2] or min
        if min and max then
            local minNumber = tonumber(min)
            local maxNumber = tonumber(max)
            if minNumber and maxNumber then
                if maxNumber < minNumber then
                    minNumber, maxNumber = maxNumber, minNumber
                end
                return math.max(0, math.floor(rng:NextNumber(minNumber, maxNumber)))
            end
        end
    elseif valueType == "function" then
        local ok, result = pcall(value)
        if ok then
            return resolveCountValue(result)
        end
    end

    return nil
end

local function emitConfigured(definition, instance, options)
    local overrideCount = options and options.EmitCount
    if definition.Emitters then
        for _, emitterInfo in ipairs(definition.Emitters) do
            local emitter = instance:FindFirstChild(emitterInfo.Name, true)
            if emitter and emitter:IsA("ParticleEmitter") then
                local countValue = resolveCountValue(overrideCount or emitterInfo.Count)
                if countValue and countValue > 0 then
                    emitter:Emit(countValue)
                end
            end
        end
    else
        local countValue = resolveCountValue(overrideCount or definition.EmitCount)
        if countValue and countValue > 0 then
            for _, descendant in ipairs(instance:GetDescendants()) do
                if descendant:IsA("ParticleEmitter") then
                    descendant:Emit(countValue)
                end
            end
        end
    end
end

local function computeWorldCFrame(target, options)
    local targetType = typeof(target)
    local cframe

    if targetType == "CFrame" then
        cframe = target
    elseif targetType == "Vector3" then
        cframe = CFrame.new(target)
    elseif targetType == "Instance" then
        if target:IsA("Attachment") then
            cframe = target.WorldCFrame
        elseif target:IsA("BasePart") then
            cframe = target.CFrame
        elseif target:IsA("Model") then
            local primary = target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart")
            if primary then
                cframe = primary.CFrame
            end
        elseif target:IsA("PVInstance") and target.GetPivot then
            cframe = target:GetPivot()
        end
    elseif targetType == "table" then
        local position = target.Position or target.position or target.pos
        if position then
            local positionType = typeof(position)
            if positionType == "Vector3" then
                cframe = CFrame.new(position)
            elseif positionType == "CFrame" then
                cframe = position
            end
        end
    end

    if not cframe and options then
        local fallback = options.CFrame or options.Position
        if fallback then
            local fallbackType = typeof(fallback)
            if fallbackType == "CFrame" then
                cframe = fallback
            elseif fallbackType == "Vector3" then
                cframe = CFrame.new(fallback)
            end
        end
    end

    if not cframe then
        return nil
    end

    if options then
        local offset = options.Offset
        if offset then
            local offsetType = typeof(offset)
            if offsetType == "Vector3" then
                cframe = cframe * CFrame.new(offset)
            elseif offsetType == "CFrame" then
                cframe = cframe * offset
            end
        end
    end

    return cframe
end

local function acquire(effectName, definition)
    local pool = ensurePool(effectName)
    local instance = pool[#pool]
    if instance then
        pool[#pool] = nil
        return instance
    end

    local created = definition.Factory()
    if not created or not created:IsA("Instance") then
        warn(('[VFXBus] Factory for effect "%s" did not return an Instance'):format(tostring(effectName)))
        return nil
    end

    if definition.Type == "World" then
        safeSetParent(created, worldPoolFolder)
    else
        safeSetParent(created, nil)
    end

    return created
end

local function cleanupAndRecycle(effectName, instance, definition)
    if isDestroyed(instance) then
        ActiveTokens[instance] = nil
        cleanupTweens(instance)
        return
    end

    if definition.Type == "UI" then
        cleanupTweens(instance)
        if instance:IsA("GuiObject") then
            instance.Visible = false
            if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
                instance.ImageTransparency = 1
            elseif instance:IsA("Frame") then
                instance.BackgroundTransparency = 1
            elseif instance:IsA("TextLabel") or instance:IsA("TextButton") then
                instance.TextTransparency = 1
                instance.BackgroundTransparency = 1
            end
        end

        if definition.OnCleanup then
            definition.OnCleanup(instance)
        end

        if not safeSetParent(instance, nil) then
            ActiveTokens[instance] = nil
            return
        end
    else
        disableEmitters(instance)
        if definition.OnCleanup then
            definition.OnCleanup(instance)
        end

        if not safeSetParent(instance, worldPoolFolder) then
            ActiveTokens[instance] = nil
            cleanupTweens(instance)
            return
        end
    end

    ActiveTokens[instance] = nil

    local pool = ensurePool(effectName)
    table.insert(pool, instance)
end

local function scheduleCleanup(effectName, instance, definition, lifetime)
    nextToken += 1
    local token = nextToken
    ActiveTokens[instance] = token

    if lifetime <= 0 then
        task.defer(function()
            if ActiveTokens[instance] ~= token then
                return
            end
            cleanupAndRecycle(effectName, instance, definition)
        end)
        return
    end

    task.delay(lifetime, function()
        if ActiveTokens[instance] ~= token then
            return
        end
        cleanupAndRecycle(effectName, instance, definition)
    end)
end

local function applyWorldEffect(effectName, instance, definition, target, options)
    local cframe = computeWorldCFrame(target, options)
    if not cframe then
        warn(('[VFXBus] Unable to resolve world position for effect "%s"'):format(effectName))
        cleanupAndRecycle(effectName, instance, definition)
        return nil
    end

    local parentSuccess

    if options and options.Parent then
        local desiredParent = options.Parent
        if desiredParent and desiredParent:IsA("Attachment") then
            desiredParent = desiredParent.Parent
        end

        if desiredParent and desiredParent:IsDescendantOf(WorkspaceService) then
            parentSuccess = safeSetParent(instance, desiredParent)
        else
            warn("[VFXBus] Provided parent for world effect is not in Workspace")
            parentSuccess = safeSetParent(instance, worldWorkspaceFolder)
        end
    else
        parentSuccess = safeSetParent(instance, worldWorkspaceFolder)
    end

    if not parentSuccess then
        cleanupAndRecycle(effectName, instance, definition)
        return nil
    end

    if instance:IsA("BasePart") then
        instance.CFrame = cframe
    elseif instance:IsA("Attachment") then
        instance.CFrame = cframe
    elseif instance:IsA("Model") then
        instance:PivotTo(cframe)
    end

    if definition.Prepare then
        definition.Prepare(instance, target, options)
    end

    emitConfigured(definition, instance, options)

    if definition.OnEmit then
        definition.OnEmit(instance, target, options)
    end

    return instance
end

local function applyUIEffect(effectName, instance, definition, target, options)
    if typeof(target) ~= "Instance" or not target:IsA("GuiObject") then
        warn(('[VFXBus] UI effect "%s" requires a GuiObject target'):format(effectName))
        cleanupAndRecycle(effectName, instance, definition)
        return nil
    end

    local parent = target
    if options and options.Parent and options.Parent:IsA("GuiObject") then
        parent = options.Parent
    end

    cleanupTweens(instance)

    if not safeSetParent(instance, parent) then
        cleanupAndRecycle(effectName, instance, definition)
        return nil
    end

    if instance:IsA("GuiObject") then
        local anchorPoint = DEFAULT_UI_ANCHOR
        if options and options.AnchorPoint then
            anchorPoint = options.AnchorPoint
        elseif definition.AnchorPoint then
            anchorPoint = definition.AnchorPoint
        end
        instance.AnchorPoint = anchorPoint

        if options and options.Position then
            instance.Position = options.Position
        else
            instance.Position = UDim2.fromScale(0.5, 0.5)
        end

        if options and options.ZIndex then
            instance.ZIndex = options.ZIndex
        elseif definition.ZIndexOffset and parent.ZIndex then
            instance.ZIndex = parent.ZIndex + definition.ZIndexOffset
        end

        if definition.AllowRandomRotation and (not options or options.Rotation == nil) then
            instance.Rotation = rng:NextInteger(-25, 25)
        elseif options and options.Rotation then
            instance.Rotation = options.Rotation
        end

        local initialSize = (options and options.InitialSize) or definition.InitialSize
        if initialSize then
            instance.Size = initialSize
        end
    end

    if instance:IsA("GuiObject") then
        instance.Visible = true
    end

    local fadeProperty
    if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
        fadeProperty = "ImageTransparency"
    elseif instance:IsA("Frame") then
        fadeProperty = "BackgroundTransparency"
    elseif instance:IsA("TextLabel") or instance:IsA("TextButton") then
        fadeProperty = "TextTransparency"
    end

    if fadeProperty then
        local fadeFrom
        if options and options.FadeFrom ~= nil then
            fadeFrom = options.FadeFrom
        else
            fadeFrom = definition.FadeFrom
        end

        if fadeFrom ~= nil then
            instance[fadeProperty] = fadeFrom
        end
    end

    if definition.Prepare then
        definition.Prepare(instance, target, options)
    end

    if definition.OnEmit then
        definition.OnEmit(instance, target, options)
    end

    local tweenInfo = definition.TweenInfo
    if options and options.TweenInfo then
        tweenInfo = options.TweenInfo
    end

    local tweenGoals = {}
    local hasGoals = false

    local endSize = (options and options.EndSize) or definition.EndSize
    if endSize and instance:IsA("GuiObject") then
        tweenGoals.Size = endSize
        hasGoals = true
    end

    if fadeProperty then
        local fadeTo
        if options and options.FadeTo ~= nil then
            fadeTo = options.FadeTo
        else
            fadeTo = definition.FadeTo
        end

        if fadeTo ~= nil then
            tweenGoals[fadeProperty] = fadeTo
            hasGoals = true
        end
    end

    if hasGoals and tweenInfo then
        local tween = TweenService:Create(instance, tweenInfo, tweenGoals)
        tween:Play()
        ActiveTweens[instance] = tween
    else
        ActiveTweens[instance] = nil
    end

    return instance
end

function VFXBus.Emit(effectName, target, options)
    local definition = resolveDefinition(effectName)
    if not definition then
        return nil
    end

    options = options or {}

    local instance = acquire(effectName, definition)
    if not instance then
        return nil
    end

    local applied
    local effectType = definition.Type or "World"
    if effectType == "UI" then
        applied = applyUIEffect(effectName, instance, definition, target, options)
    elseif effectType == "World" then
        applied = applyWorldEffect(effectName, instance, definition, target, options)
    else
        warn(('[VFXBus] Effect "%s" has unsupported type "%s"'):format(effectName, tostring(effectType)))
        cleanupAndRecycle(effectName, instance, definition)
        return nil
    end

    if not applied then
        return nil
    end

    local lifetime = options.Lifetime or definition.Lifetime or 0.5
    scheduleCleanup(effectName, instance, definition, lifetime)

    return instance
end

function VFXBus.Warm(effectName, count)
    local definition = resolveDefinition(effectName)
    if not definition then
        return
    end

    count = math.max(0, math.floor(count or 1))
    local pool = ensurePool(effectName)

    for _ = 1, count do
        local instance = definition.Factory()
        if instance and instance:IsA("Instance") then
            if definition.Type == "World" then
                safeSetParent(instance, worldPoolFolder)
                disableEmitters(instance)
            else
                safeSetParent(instance, nil)
                cleanupTweens(instance)
            end
            if definition.OnCleanup then
                definition.OnCleanup(instance)
            end
            table.insert(pool, instance)
        end
    end
end

function VFXBus.WarmMany(targets)
    if typeof(targets) ~= "table" then
        return
    end

    for effectName, amount in pairs(targets) do
        VFXBus.Warm(effectName, amount)
    end
end

do
    VFXBus.WarmMany(PREWARM_EFFECTS)
end

return VFXBus
