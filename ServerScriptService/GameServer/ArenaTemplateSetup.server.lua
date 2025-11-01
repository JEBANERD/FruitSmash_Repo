--!strict

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TAG = "[ArenaTemplateSetup]"

local function getNoticeRemote(): RemoteEvent?
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if remotesFolder == nil then
		return nil
	end

	local notice = remotesFolder:FindFirstChild("RE_Notice")
	if notice and notice:IsA("RemoteEvent") then
		return notice
	end

	return nil
end

local noticeRemote = getNoticeRemote()

local function sendNotice(message: string)
	if noticeRemote == nil then
		return
	end

	local payload = {
		msg = message,
		kind = "warning",
	}

	noticeRemote:FireAllClients(payload)
end

local function reportInfo(message: string)
	print(string.format("%s %s", TAG, message))
end

local function reportWarning(message: string)
	local formatted = string.format("%s WARNING: %s", TAG, message)
	print(formatted)
	sendNotice(formatted)
end

local arenaTemplates = ServerStorage:FindFirstChild("ArenaTemplates")
if arenaTemplates == nil or not arenaTemplates:IsA("Folder") then
	reportInfo("ServerStorage/ArenaTemplates missing; skipping template checks.")
	return
end

local baseArena = arenaTemplates:FindFirstChild("BaseArena")
if baseArena == nil then
	reportInfo("ServerStorage/ArenaTemplates/BaseArena missing; skipping template checks.")
	return
end

local requiredFolders = { "Lanes", "Targets", "Turrets", "Gutters", "WorldScreens" }
local folderRefs: { [string]: Folder } = {}
local missingFolders = {}
local invalidFolders = {}

for _, name in ipairs(requiredFolders) do
	local child = baseArena:FindFirstChild(name)
	if child == nil then
		table.insert(missingFolders, name)
	elseif not child:IsA("Folder") then
		table.insert(invalidFolders, string.format("%s (found %s)", name, child.ClassName))
	else
		folderRefs[name] = child
	end
end

if #missingFolders == 0 and #invalidFolders == 0 then
	reportInfo("Folder check OK (Lanes, Targets, Turrets, Gutters, WorldScreens present).")
else
	local issues = {}
	if #missingFolders > 0 then
		table.insert(issues, "missing: " .. table.concat(missingFolders, ", "))
	end
	if #invalidFolders > 0 then
		table.insert(issues, "invalid type: " .. table.concat(invalidFolders, ", "))
	end
	reportWarning("Folder check issues - " .. table.concat(issues, "; "))
end

local lanesFolder = folderRefs["Lanes"]
local laneIndices: { [number]: boolean } = {}
local invalidLaneIndices = {}
local highestLaneIndex = 0

if lanesFolder then
	for _, child in ipairs(lanesFolder:GetChildren()) do
		local numericSuffix = string.match(child.Name, "^Lane(%d+)$")
		if numericSuffix then
			local index = tonumber(numericSuffix)
			if index then
				laneIndices[index] = true
				if index > highestLaneIndex then
					highestLaneIndex = index
				end
				if index > 8 then
					table.insert(invalidLaneIndices, string.format("Lane%d", index))
				end
			end
		end
	end
end

local requiredLaneMissing = {}
for laneIndex = 1, 4 do
	if not laneIndices[laneIndex] then
		table.insert(requiredLaneMissing, string.format("Lane%d", laneIndex))
	end
end

local laneGaps = {}
if highestLaneIndex > 0 then
	for laneIndex = 1, highestLaneIndex do
		if laneIndices[laneIndex] ~= true then
			table.insert(laneGaps, string.format("Lane%d", laneIndex))
		end
	end
end

local laneCount = 0
for _ in pairs(laneIndices) do
	laneCount = laneCount + 1
end

local expectedLaneCount = math.max(highestLaneIndex, 4)
if expectedLaneCount == 0 then
	expectedLaneCount = 4
end

if lanesFolder == nil then
	reportWarning("Lane check skipped; Lanes folder missing or invalid.")
else
	local issues = {}
	if #requiredLaneMissing > 0 then
		table.insert(issues, "missing required lanes: " .. table.concat(requiredLaneMissing, ", "))
	end
	if #laneGaps > #requiredLaneMissing then
		local gapsOnly = {}
		for _, laneName in ipairs(laneGaps) do
			local numericSuffix = string.match(laneName, "Lane(%d+)")
			local index = tonumber(numericSuffix)
			if index and index > 4 then
				table.insert(gapsOnly, laneName)
			end
		end
		if #gapsOnly > 0 then
			table.insert(issues, "gaps in optional lanes: " .. table.concat(gapsOnly, ", "))
		end
	end
	if #invalidLaneIndices > 0 then
		table.insert(issues, "unsupported lane indices: " .. table.concat(invalidLaneIndices, ", "))
	end

	if #issues == 0 then
		reportInfo(string.format("Lanes OK (%d lanes found, highest Lane%d).", laneCount, expectedLaneCount))
	else
		reportWarning("Lane check issues - " .. table.concat(issues, "; "))
	end
end

local function checkSequence(folder: Folder?, prefix: string, expectedCount: number, label: string)
	if not folder then
		reportWarning(string.format("%s check skipped; %s folder missing or invalid.", label, label))
		return
	end

	local missingEntries = {}
	for index = 1, expectedCount do
		local name = string.format("%s%d", prefix, index)
		if folder:FindFirstChild(name) == nil then
			table.insert(missingEntries, name)
		end
	end

	local extras = {}
	for _, child in ipairs(folder:GetChildren()) do
		local numericSuffix = string.match(child.Name, "^" .. prefix .. "(%d+)$")
		local index = numericSuffix and tonumber(numericSuffix) or nil
		if index == nil or index > expectedCount then
			table.insert(extras, child.Name)
		end
	end

	if #missingEntries == 0 and #extras == 0 then
		reportInfo(string.format("%s OK (%s1-%s%d present).", label, prefix, prefix, expectedCount))
	else
		local issues = {}
		if #missingEntries > 0 then
			table.insert(issues, "missing: " .. table.concat(missingEntries, ", "))
		end
		if #extras > 0 then
			table.insert(issues, "unexpected: " .. table.concat(extras, ", "))
		end
		reportWarning(string.format("%s check issues - %s", label, table.concat(issues, "; ")))
	end
end

checkSequence(folderRefs["Targets"], "Target", expectedLaneCount, "Targets")
checkSequence(folderRefs["Turrets"], "Turret", expectedLaneCount, "Turrets")

local worldScreensFolder = folderRefs["WorldScreens"]
if not worldScreensFolder then
	reportWarning("WorldScreens check skipped; WorldScreens folder missing or invalid.")
else
	local waveTimer = worldScreensFolder:FindFirstChild("WS_WaveTimer")
	local roundTimer = worldScreensFolder:FindFirstChild("WS_RoundTimer")

	local issues = {}
	if waveTimer == nil or not waveTimer:IsA("SurfaceGui") then
		table.insert(issues, "WS_WaveTimer missing or not a SurfaceGui")
	end
	if roundTimer == nil or not roundTimer:IsA("SurfaceGui") then
		table.insert(issues, "WS_RoundTimer missing or not a SurfaceGui")
	end

	if #issues == 0 then
		reportInfo("WorldScreens OK (WS_WaveTimer and WS_RoundTimer present).")
	else
		reportWarning("WorldScreens check issues - " .. table.concat(issues, "; "))
	end
end

reportInfo("Arena template verification complete.")
