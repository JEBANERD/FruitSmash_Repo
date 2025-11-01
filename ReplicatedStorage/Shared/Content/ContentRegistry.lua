--!strict

local ContentRegistry = {} :: {
    GetAsset: (id: string) -> any,
    Preload: (ids: { any } | { [any]: any } | string | nil) -> (),
}

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local isServer = RunService:IsServer()

local ServerStorage: ServerStorage?
do
    local ok, service = pcall(game.GetService, game, "ServerStorage")
    if ok then
        ServerStorage = service
    end
end

type ResolverTable = {
    Instance: Instance?,
    Factory: (() -> any)?,
    Resolve: (() -> any)?,
    Builder: (() -> any)?,
    Create: (() -> any)?,
    Value: any?,
    ServerOnly: boolean?,
    Optional: boolean?,
}

type AssetResolver = Instance | (() -> any) | ResolverTable

local assetResolvers: { [string]: AssetResolver } = {}
local assetCache: { [string]: Instance | false | any } = {}
local warningCache: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
    if warningCache[key] then
        return
    end

    warningCache[key] = true
    warn(message)
end

local function describeInstance(instance: Instance?): string
    if not instance then
        return "<nil>"
    end

    local ok, fullName = pcall(instance.GetFullName, instance)
    if ok then
        return fullName
    end

    local name = instance.Name
    if name then
        return name
    end

    return tostring(instance)
end

local function safeRequire(moduleScript: Instance?, warnKey: string, contextName: string): any
    if not moduleScript or not moduleScript:IsA("ModuleScript") then
        return nil
    end

    local ok, result = pcall(require, moduleScript)
    if not ok then
        warnOnce(warnKey, string.format(
            "[ContentRegistry] Failed to require %s: %s",
            contextName or describeInstance(moduleScript),
            tostring(result)
        ))
        return nil
    end

    return result
end

local function resolveInstanceDefinition(entry: any): (AssetResolver?, string?)
    local entryType = typeof(entry)

    if entryType == "Instance" or entryType == "function" then
        return entry :: AssetResolver, entryType
    end

    if entryType ~= "table" then
        return nil, entryType
    end

    if typeof(entry.Instance) == "Instance" then
        if entry.ServerOnly ~= nil or entry.Optional ~= nil then
            return {
                Instance = entry.Instance,
                ServerOnly = entry.ServerOnly,
                Optional = entry.Optional,
            }, "table"
        end

        return entry.Instance, "Instance"
    end

    if typeof(entry.Factory) == "function" or typeof(entry.Resolve) == "function" then
        return entry :: AssetResolver, "table"
    end

    if typeof(entry.Builder) == "function" then
        return {
            Factory = entry.Builder,
            ServerOnly = entry.ServerOnly,
            Optional = entry.Optional,
        }, "table"
    end

    if typeof(entry.Create) == "function" then
        return {
            Factory = entry.Create,
            ServerOnly = entry.ServerOnly,
            Optional = entry.Optional,
        }, "table"
    end

    if entry.Value ~= nil then
        local valueType = typeof(entry.Value)
        if valueType == "Instance" then
            return entry.Value, "Instance"
        elseif valueType == "function" then
            return {
                Factory = entry.Value,
                ServerOnly = entry.ServerOnly,
                Optional = entry.Optional,
            }, "table"
        elseif valueType == "table" then
            return entry.Value, "table"
        end
    end

    return nil, entryType
end

local function normalizeIds(ids: { any } | { [any]: any } | string | nil): { any }
    if ids == nil then
        return {}
    end

    if typeof(ids) ~= "table" then
        return { ids }
    end

    local ordered: { any } = {}

    for _, value in ipairs(ids) do
        ordered[#ordered + 1] = value
    end

    if #ordered > 0 then
        return ordered
    end

    for _, value in pairs(ids) do
        ordered[#ordered + 1] = value
    end

    return ordered
end

local function evaluateResolver(resolver: AssetResolver): (any, string?)
    if typeof(resolver) == "function" then
        return resolver(), nil
    end

    if typeof(resolver) == "Instance" then
        return resolver, nil
    end

    local resolverTable = resolver :: ResolverTable

    if resolverTable.ServerOnly and not isServer then
        return nil, "unavailable"
    end

    if typeof(resolverTable.Instance) == "Instance" then
        return resolverTable.Instance, nil
    end

    if typeof(resolverTable.Resolve) == "function" then
        return resolverTable.Resolve(), nil
    end

    if typeof(resolverTable.Factory) == "function" then
        return resolverTable.Factory(), nil
    end

    if resolverTable.Value ~= nil then
        return resolverTable.Value, nil
    end

    return resolverTable, nil
end

local function resolveAsset(id: string): (any, string?)
    local cached = assetCache[id]
    if cached ~= nil then
        if cached == false then
            return nil, "missing"
        end

        return cached, nil
    end

    local resolver = assetResolvers[id]
    if resolver == nil then
        warnOnce("resolver-missing:" .. id, string.format("[ContentRegistry] Unknown asset id '%s'", id))
        assetCache[id] = false
        return nil, "missing"
    end

    local options = typeof(resolver) == "table" and (resolver :: ResolverTable) or nil

    if options and options.ServerOnly and not isServer then
        return nil, "unavailable"
    end

    local ok, asset, reason = pcall(evaluateResolver, resolver)
    if not ok then
        warnOnce("resolver-error:" .. id, string.format("[ContentRegistry] Failed to resolve asset '%s': %s", id, tostring(asset)))
        assetCache[id] = false
        return nil, "error"
    end

    if reason == "unavailable" then
        return nil, "unavailable"
    end

    local resolved = asset
    if resolved == nil then
        if options and options.Optional then
            return nil, "optional"
        end

        warnOnce("resolver-nil:" .. id, string.format("[ContentRegistry] Asset '%s' resolved to nil", id))
        assetCache[id] = false
        return nil, "missing"
    end

    assetCache[id] = resolved
    return resolved, nil
end

function ContentRegistry.GetAsset(id: string): any
    assert(typeof(id) == "string", "Asset id must be a string")

    local asset = resolveAsset(id)
    if not asset then
        return nil
    end

    if typeof(asset) == "Instance" then
        local ok, cloneOrError = pcall((asset :: Instance).Clone, asset)
        if not ok then
            warnOnce("clone-failed:" .. id, string.format("[ContentRegistry] Failed to clone asset '%s': %s", id, tostring(cloneOrError)))
            return nil
        end

        return cloneOrError
    end

    return asset
end

function ContentRegistry.Preload(ids: { any } | { [any]: any } | string | nil)
    local ordered = normalizeIds(ids)
    if #ordered == 0 then
        return
    end

    local preloadTargets: { Instance } = {}

    for _, id in ipairs(ordered) do
        local asset = resolveAsset(id)
        if typeof(asset) == "Instance" then
            table.insert(preloadTargets, asset)
        end
    end

    if #preloadTargets == 0 then
        return
    end

    local ok, err = pcall(ContentProvider.PreloadAsync, ContentProvider, preloadTargets)
    if not ok then
        warnOnce("preload-failed", string.format("[ContentRegistry] PreloadAsync failed: %s", tostring(err)))
    end
end

local function registerAsset(id: string, resolver: AssetResolver)
    assetResolvers[id] = resolver
    assetCache[id] = nil
end

local function applyPhysicsDefaults(part: BasePart)
    part.Anchored = false
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.Massless = true
    part.CastShadow = false
end

local function createFruitPrototype(name: string, color: Color3, shape: Enum.PartType?): BasePart
    local part = Instance.new("Part")
    part.Name = string.format("%sPrototype", name)
    part.Material = Enum.Material.SmoothPlastic
    part.Color = color
    part.Size = Vector3.new(1, 1, 1)
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    applyPhysicsDefaults(part)

    if shape then
        part.Shape = shape
    else
        part.Shape = Enum.PartType.Ball
    end

    part:SetAttribute("AttachmentReferenceSize", part.Size)

    local attachments = {
        { Name = "RootAttachment", Offset = Vector3.new() },
        { Name = "ImpactAttachment", Offset = Vector3.new(0, 0, -0.5) },
        { Name = "TrailAttachment", Offset = Vector3.new(0, 0, 0.5) },
        { Name = "OverheadAttachment", Offset = Vector3.new(0, 0.5, 0) },
    }

    for _, attachmentInfo in ipairs(attachments) do
        local attachment = Instance.new("Attachment")
        attachment.Name = attachmentInfo.Name
        local offset = attachmentInfo.Offset or Vector3.new()
        attachment.Position = offset
        attachment:SetAttribute("Offset", offset)
        attachment.Parent = part
    end

    return part
end

local function registerFruitAssets()
    registerAsset("Fruit.Fallback", createFruitPrototype("FruitFallback", Color3.fromRGB(235, 235, 235), Enum.PartType.Ball))

    local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
    if not assetsFolder then
        warnOnce("assets-folder-missing", "[ContentRegistry] ReplicatedStorage.Assets folder is missing")
        return
    end

    local fruitModule = assetsFolder:FindFirstChild("Fruit")
    if not fruitModule or not fruitModule:IsA("ModuleScript") then
        warnOnce("fruit-module-missing", "[ContentRegistry] ReplicatedStorage.Assets.Fruit module is missing")
        return
    end

    local fruitDefinitions = safeRequire(fruitModule, "fruit-require-failed", "fruit asset definitions")
    if type(fruitDefinitions) ~= "table" then
        warnOnce("fruit-definitions-invalid", "[ContentRegistry] Fruit asset module must return a table")
        return
    end

    for fruitId, definition in pairs(fruitDefinitions) do
        local resolver, definitionType = resolveInstanceDefinition(definition)
        if resolver then
            registerAsset("Fruit." .. tostring(fruitId), resolver)
        else
            warnOnce(
                "fruit-definition-invalid:" .. tostring(fruitId),
                string.format(
                    "[ContentRegistry] Fruit asset '%s' has unsupported definition (type %s)",
                    tostring(fruitId),
                    definitionType or typeof(definition)
                )
            )
        end
    end
end

local function resolveArenaTemplate(name: string): (Instance?, string?)
    if not isServer or not ServerStorage then
        return nil, "unavailable"
    end

    local templates = ServerStorage:FindFirstChild("ArenaTemplates")
    if not templates then
        warnOnce("arena-templates-missing", "[ContentRegistry] Missing ServerStorage.ArenaTemplates folder")
        return nil
    end

    local template = templates:FindFirstChild(name)
    if not template then
        warnOnce("arena-template-missing:" .. name, string.format("[ContentRegistry] Missing arena template '%s'", name))
        return nil
    end

    if template:IsA("ModuleScript") then
        local definition = safeRequire(template, "arena-template-require:" .. name, string.format("arena template '%s'", name))
        if definition == nil then
            return nil
        end

        local resolver, definitionType = resolveInstanceDefinition(definition)
        if not resolver then
            warnOnce(
                "arena-template-invalid:" .. name,
                string.format(
                    "[ContentRegistry] Arena template '%s' returned unsupported definition (type %s)",
                    name,
                    definitionType or typeof(definition)
                )
            )
            return nil
        end

        if typeof(resolver) == "Instance" then
            return resolver
        end

        local ok, result = pcall(evaluateResolver, resolver)
        if not ok then
            warnOnce(
                "arena-template-evaluate:" .. name,
                string.format("[ContentRegistry] Failed to evaluate arena template '%s': %s", name, tostring(result))
            )
            return nil
        end

        if typeof(result) == "Instance" then
            return result
        end

        warnOnce(
            "arena-template-result-invalid:" .. name,
            string.format("[ContentRegistry] Arena template '%s' resolved to unsupported value (type %s)", name, typeof(result))
        )
        return nil
    end

    if template:IsA("Folder") then
        local primaryModel = template:FindFirstChildWhichIsA("Model")
        if primaryModel then
            return primaryModel
        end

        local pv = template:FindFirstChildWhichIsA("PVInstance")
        if pv then
            return pv
        end
    end

    return template
end

local function registerArenaAssets()
    registerAsset("Arena.BaseArena", {
        ServerOnly = true,
        Resolve = function()
            local instance = resolveArenaTemplate("BaseArena")
            if instance then
                return instance
            end
            return nil
        end,
    })
end

local function registerVFXAssets()
    local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
    if not assetsFolder then
        warnOnce("assets-folder-missing", "[ContentRegistry] ReplicatedStorage.Assets folder is missing")
        return
    end

    local vfxModule = assetsFolder:FindFirstChild("VFX")
    if not vfxModule or not vfxModule:IsA("ModuleScript") then
        warnOnce("vfx-module-missing", "[ContentRegistry] ReplicatedStorage.Assets.VFX module is missing")
        return
    end

    local definitions = safeRequire(vfxModule, "vfx-require-failed", "VFX definitions module")
    if type(definitions) ~= "table" then
        warnOnce("vfx-definitions-invalid", "[ContentRegistry] VFX definitions module must return a table")
        return
    end

    for effectName, definition in pairs(definitions) do
        local id = "VFX." .. tostring(effectName)
        if definition == nil then
            warnOnce(
                "vfx-definition-missing:" .. tostring(effectName),
                string.format("[ContentRegistry] VFX definition '%s' is nil", tostring(effectName))
            )
        else
            registerAsset(id, function()
                return definitions[effectName]
            end)
        end
    end
end

registerFruitAssets()
registerArenaAssets()
registerVFXAssets()

return ContentRegistry
