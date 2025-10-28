local FruitAssets = {}

local function applyPhysicsDefaults(part)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
end

local function resolveRelativeOffset(part, offset, relative)
	if not relative then
		return offset
	end

	local size = part.Size

	return Vector3.new(
		offset.X * (size.X ~= 0 and size.X or 1),
		offset.Y * (size.Y ~= 0 and size.Y or 1),
		offset.Z * (size.Z ~= 0 and size.Z or 1)
	)
end

local function createAttachment(part, info)
	local offset = info.Offset or info.Position or Vector3.new()
	local relative = info.Relative
	local resolvedOffset = resolveRelativeOffset(part, offset, relative)

	local attachment = Instance.new("Attachment")
	attachment.Name = info.Name or "Attachment"
	attachment.Position = resolvedOffset
	attachment:SetAttribute("Offset", resolvedOffset)

	if info.Axis then
		attachment.Axis = info.Axis
	end

	if info.SecondaryAxis then
		attachment.SecondaryAxis = info.SecondaryAxis
	end

	attachment.Parent = part

	return attachment
end

local function createFruitModel(options)
	assert(typeof(options) == "table", "Fruit asset options must be a table")
	assert(typeof(options.Name) == "string" and options.Name ~= "", "Fruit asset requires a Name")

	local size = options.Size or Vector3.new(1, 1, 1)
	local color = options.Color or Color3.fromRGB(255, 255, 255)

	local model = Instance.new("Model")
	model.Name = options.ModelName or options.Name

	local root = Instance.new("Part")
	root.Name = options.RootName or (options.Name .. "Root")
	root.Color = color
	root.Material = options.Material or Enum.Material.SmoothPlastic
	root.Size = size
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.CastShadow = options.CastShadow == true
	root.Parent = model

	if options.Shape then
		root.Shape = options.Shape
	else
		root.Shape = Enum.PartType.Ball
	end

	applyPhysicsDefaults(root)
	root:SetAttribute("AttachmentReferenceSize", root.Size)

	if options.MeshType or options.MeshId or options.TextureId or options.MeshScale or options.MeshOffset then
		local mesh = Instance.new("SpecialMesh")
		if options.MeshType then
			mesh.MeshType = options.MeshType
		end
		if options.MeshId then
			mesh.MeshId = options.MeshId
		end
		if options.TextureId then
			mesh.TextureId = options.TextureId
		end
		if options.MeshScale then
			mesh.Scale = options.MeshScale
		end
		if options.MeshOffset then
			mesh.Offset = options.MeshOffset
		end
		mesh.Parent = root
	end

	local defaultAttachments = options.DefaultAttachments
	if defaultAttachments == nil then
		defaultAttachments = {
			{ Name = "RootAttachment", Offset = Vector3.new(), Relative = false },
			{ Name = "ImpactAttachment", Offset = Vector3.new(0, 0, -0.5), Relative = true },
			{ Name = "TrailAttachment", Offset = Vector3.new(0, 0, 0.5), Relative = true },
			{ Name = "OverheadAttachment", Offset = Vector3.new(0, 0.5, 0), Relative = true },
		}
	end

	for _, info in ipairs(defaultAttachments) do
		createAttachment(root, info)
	end

	if options.Attachments then
		for _, info in ipairs(options.Attachments) do
			createAttachment(root, info)
		end
	end

	model.PrimaryPart = root

	return model
end

FruitAssets.Apple = createFruitModel({
	Name = "Apple",
	Color = Color3.fromRGB(229, 70, 70),
	Size = Vector3.new(1.2, 1.15, 1.2),
	MeshType = Enum.MeshType.Sphere,
	MeshScale = Vector3.new(1.03, 1.08, 1.03),
})

FruitAssets.Banana = createFruitModel({
	Name = "Banana",
	Color = Color3.fromRGB(250, 223, 89),
	Size = Vector3.new(0.65, 1.7, 0.65),
	Shape = Enum.PartType.Block,
	MeshType = Enum.MeshType.Cylinder,
	MeshScale = Vector3.new(0.5, 1.05, 0.9),
	DefaultAttachments = {
		{ Name = "RootAttachment", Offset = Vector3.new(), Relative = false },
		{ Name = "ImpactAttachment", Offset = Vector3.new(0, 0, -0.5), Relative = true },
		{ Name = "TrailAttachment", Offset = Vector3.new(0, 0, 0.5), Relative = true },
		{ Name = "OverheadAttachment", Offset = Vector3.new(0, 0.4, 0), Relative = true },
	},
})

FruitAssets.Orange = createFruitModel({
	Name = "Orange",
	Color = Color3.fromRGB(255, 170, 43),
	Size = Vector3.new(1.05, 1.05, 1.05),
	MeshType = Enum.MeshType.Sphere,
	MeshScale = Vector3.new(1, 1, 1),
})

FruitAssets.Pineapple = createFruitModel({
	Name = "Pineapple",
	Color = Color3.fromRGB(255, 219, 113),
	Size = Vector3.new(1.1, 1.6, 1.1),
	Shape = Enum.PartType.Block,
	MeshType = Enum.MeshType.Cylinder,
	MeshScale = Vector3.new(0.75, 1.2, 0.75),
	DefaultAttachments = {
		{ Name = "RootAttachment", Offset = Vector3.new(), Relative = false },
		{ Name = "ImpactAttachment", Offset = Vector3.new(0, 0, -0.5), Relative = true },
		{ Name = "TrailAttachment", Offset = Vector3.new(0, 0, 0.5), Relative = true },
		{ Name = "OverheadAttachment", Offset = Vector3.new(0, 0.55, 0), Relative = true },
	},
})

FruitAssets.Coconut = createFruitModel({
	Name = "Coconut",
	Color = Color3.fromRGB(168, 120, 78),
	Size = Vector3.new(1.25, 1.1, 1.25),
	MeshType = Enum.MeshType.Sphere,
	MeshScale = Vector3.new(1.05, 0.95, 1.05),
})

FruitAssets.Watermelon = createFruitModel({
	Name = "Watermelon",
	Color = Color3.fromRGB(96, 178, 109),
	Size = Vector3.new(1.45, 1.25, 1.45),
	MeshType = Enum.MeshType.Sphere,
	MeshScale = Vector3.new(1.08, 0.9, 1.08),
})

FruitAssets.GrapeBundle = createFruitModel({
	Name = "Grape",
	Color = Color3.fromRGB(142, 84, 201),
	Size = Vector3.new(0.55, 0.55, 0.55),
	MeshType = Enum.MeshType.Sphere,
	MeshScale = Vector3.new(1, 1, 1),
})

return FruitAssets
