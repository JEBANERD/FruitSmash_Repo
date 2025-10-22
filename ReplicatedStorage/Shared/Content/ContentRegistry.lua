local ContentRegistry = {}

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local isServer = RunService:IsServer()

local ServerStorage do
    local ok, service = pcall(game.GetService, game, "ServerStorage")
    if ok then
        ServerStorage = service
    end
end

local assetResolvers = {}
local assetCache = {}
local warningCache = {}

local function warnOnce(key, message)
    if warningCache[key] then
        return
    end

    warningCache[key] = true
    warn(message)
end

local function normalizeIds(ids)
    if ids == nil then
        return {}
    end

    if typeof(ids) ~= "table" then
        return { ids }
    end

    local ordered = {}

    for index, value in ipairs(ids) do
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

local function evaluateResolver(resolver)
    if typeof(resolver) == "function" then
        return resolver()
    end

    if typeof(resolver) == "Instance" then
        return resolver
    end

    if typeof(resolver) == "table" then
        if resolver.ServerOnly and not isServer then
            return nil, "unavailable"
        end

        if typeof(resolver.Instance) == "Instance" then
            return resolver.Instance
        end

        if typeof(resolver.Resolve) == "function" then
            return resolver.Resolve()
        end

        if typeof(resolver.Factory) == "function" then
            return resolver.Factory()
        end

        if resolver.Value ~= nil then
            return resolver.Value
        end

        return resolver
    end

    return resolver
end

local function resolveAsset(id)
    if assetCache[id] ~= nil then
        local cached = assetCache[id]
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

    local options = typeof(resolver) == "table" and resolver or nil

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

function ContentRegistry.GetAsset(id)
    assert(typeof(id) == "string", "Asset id must be a string")

    local asset = resolveAsset(id)
    if not asset then
        return nil
    end

    if typeof(asset) == "Instance" then
        local ok, cloneOrError = pcall(asset.Clone, asset)
        if not ok then
            warnOnce("clone-failed:" .. id, string.format("[ContentRegistry] Failed to clone asset '%s': %s", id, tostring(cloneOrError)))
            return nil
        end

        return cloneOrError
    end

    return asset
end

function ContentRegistry.Preload(ids)
    local ordered = normalizeIds(ids)
    if #ordered == 0 then
        return
    end

    local preloadTargets = {}

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

local function registerAsset(id, resolver)
    assetResolvers[id] = resolver
    assetCache[id] = nil
end

local function applyPhysicsDefaults(part)
    part.Anchored = false
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.Massless = true
    part.CastShadow = false
end

local function createFruitPrototype(name, color, shape)
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

    return part
end

local function registerFruitAssets()
    local fruitDefinitions = {
        Apple = { Color = Color3.fromRGB(229, 70, 70), Shape = Enum.PartType.Ball },
        Banana = { Color = Color3.fromRGB(250, 223, 89), Shape = Enum.PartType.Cylinder },
        Orange = { Color = Color3.fromRGB(255, 170, 43), Shape = Enum.PartType.Ball },
        Pineapple = { Color = Color3.fromRGB(255, 219, 113), Shape = Enum.PartType.Block },
        Coconut = { Color = Color3.fromRGB(168, 120, 78), Shape = Enum.PartType.Ball },
        Watermelon = { Color = Color3.fromRGB(96, 178, 109), Shape = Enum.PartType.Ball },
    }

    for fruitId, definition in pairs(fruitDefinitions) do
        local prototype = createFruitPrototype(fruitId, definition.Color, definition.Shape)
        registerAsset("Fruit." .. fruitId, prototype)
    end

    registerAsset("Fruit.Fallback", createFruitPrototype("FruitFallback", Color3.fromRGB(235, 235, 235), Enum.PartType.Ball))
end

local function resolveArenaTemplate(name)
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

    return template
end

local function registerArenaAssets()
    registerAsset("Arena.BaseArena", {
        ServerOnly = true,
        Resolve = function()
            return resolveArenaTemplate("BaseArena")
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

    local ok, definitions = pcall(require, vfxModule)
    if not ok then
        warnOnce("vfx-require-failed", string.format("[ContentRegistry] Failed to require VFX definitions: %s", tostring(definitions)))
        return
    end

    for effectName in pairs(definitions) do
        local id = "VFX." .. tostring(effectName)
        registerAsset(id, function()
            return definitions[effectName]
        end)
    end
end

registerFruitAssets()
registerArenaAssets()
registerVFXAssets()

return ContentRegistry
