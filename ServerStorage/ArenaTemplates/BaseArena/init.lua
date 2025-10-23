local function applyPartDefaults(part)
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
end

local function setAttachmentOffset(attachment, offset)
    attachment.Position = offset
    attachment:SetAttribute("Offset", offset)
end

local function createLane(index, cframe)
    local lane = Instance.new("Part")
    lane.Name = string.format("Lane%d", index)
    lane.Size = Vector3.new(4, 1, 6)
    lane.Material = Enum.Material.SmoothPlastic
    lane.Color = Color3.fromRGB(120, 182, 255)
    lane.Transparency = 0.65
    applyPartDefaults(lane)
    lane.CFrame = cframe
    lane:SetAttribute("LaneId", string.format("Lane%d", index))
    lane:SetAttribute("AttachmentReferenceSize", lane.Size)

    local centerAttachment = Instance.new("Attachment")
    centerAttachment.Name = "LaneCenter"
    setAttachmentOffset(centerAttachment, Vector3.new())
    centerAttachment.Parent = lane

    local entryAttachment = Instance.new("Attachment")
    entryAttachment.Name = "LaneEntry"
    setAttachmentOffset(entryAttachment, Vector3.new(0, 0, -0.5 * lane.Size.Z))
    entryAttachment.Parent = lane

    local exitAttachment = Instance.new("Attachment")
    exitAttachment.Name = "LaneExit"
    setAttachmentOffset(exitAttachment, Vector3.new(0, 0, 0.5 * lane.Size.Z))
    exitAttachment.Parent = lane

    return lane
end

local function createTarget(index, position)
    local target = Instance.new("Part")
    target.Name = string.format("Lane%dTarget", index)
    target.Size = Vector3.new(6, 8, 1)
    target.Material = Enum.Material.Neon
    target.Color = Color3.fromRGB(255, 196, 115)
    target.Transparency = 0.25
    applyPartDefaults(target)
    target.CFrame = position
    return target
end

local function createSpawnMarker(index, position)
    local marker = Instance.new("Part")
    marker.Name = string.format("Lane%dSpawn", index)
    marker.Size = Vector3.new(6, 1, 6)
    marker.Material = Enum.Material.SmoothPlastic
    marker.Color = Color3.fromRGB(255, 255, 255)
    marker.Transparency = 1
    applyPartDefaults(marker)
    marker.CFrame = position
    marker:SetAttribute("LaneId", string.format("Lane%d", index))
    return marker
end

local function createDecorColumn(name, cframe, height)
    local column = Instance.new("Part")
    column.Name = name
    column.Size = Vector3.new(2, height, 2)
    column.Material = Enum.Material.Slate
    column.Color = Color3.fromRGB(93, 125, 84)
    applyPartDefaults(column)
    column.CFrame = cframe
    return column
end

local function createBaseArena()
    local model = Instance.new("Model")
    model.Name = "BaseArena"

    local floor = Instance.new("Part")
    floor.Name = "ArenaFloor"
    floor.Size = Vector3.new(120, 1, 120)
    floor.Material = Enum.Material.SmoothPlastic
    floor.Color = Color3.fromRGB(38, 113, 64)
    applyPartDefaults(floor)
    floor.CFrame = CFrame.new(0, 0, 0)
    floor.Parent = model
    model.PrimaryPart = floor

    local bounds = Instance.new("Part")
    bounds.Name = "ArenaBounds"
    bounds.Size = Vector3.new(120, 40, 120)
    bounds.Transparency = 1
    bounds.CanQuery = true
    bounds.CanTouch = false
    bounds.CanCollide = false
    bounds.Anchored = true
    bounds.Parent = model

    local lanesFolder = Instance.new("Folder")
    lanesFolder.Name = "Lanes"
    lanesFolder.Parent = model

    local spawnFolder = Instance.new("Folder")
    spawnFolder.Name = "SpawnZones"
    spawnFolder.Parent = model

    local targetsFolder = Instance.new("Folder")
    targetsFolder.Name = "Targets"
    targetsFolder.Parent = model

    local decorFolder = Instance.new("Folder")
    decorFolder.Name = "Decor"
    decorFolder.Parent = model

    local laneOffsets = { -18, -6, 6, 18 }
    local laneZ = -42
    local targetZ = 46
    local spawnHeight = floor.CFrame.Y + floor.Size.Y * 0.5 + 0.5
    local targetHeight = floor.CFrame.Y + 4

    for index, offsetX in ipairs(laneOffsets) do
        local laneCFrame = CFrame.new(offsetX, spawnHeight, laneZ) * CFrame.Angles(0, math.pi, 0)
        local lane = createLane(index, laneCFrame)
        lane.Parent = lanesFolder

        local spawnMarker = createSpawnMarker(index, CFrame.new(offsetX, spawnHeight - 0.5, laneZ))
        spawnMarker.Parent = spawnFolder

        local target = createTarget(index, CFrame.new(offsetX, targetHeight, targetZ))
        target.Parent = targetsFolder
    end

    local columnHeight = 18
    local columnDistance = 50
    for _, direction in ipairs({ -1, 1 }) do
        local leftColumn = createDecorColumn(
            string.format("ColumnLeft%d", direction),
            CFrame.new(-40, columnHeight * 0.5, direction * columnDistance),
            columnHeight
        )
        leftColumn.Parent = decorFolder

        local rightColumn = createDecorColumn(
            string.format("ColumnRight%d", direction),
            CFrame.new(40, columnHeight * 0.5, direction * columnDistance),
            columnHeight
        )
        rightColumn.Parent = decorFolder
    end

    local lighting = Instance.new("PointLight")
    lighting.Name = "ArenaGlow"
    lighting.Range = 60
    lighting.Brightness = 1.5
    lighting.Color = Color3.fromRGB(255, 214, 170)
    lighting.Parent = floor

    return model
end

local prototype = createBaseArena()

return prototype
