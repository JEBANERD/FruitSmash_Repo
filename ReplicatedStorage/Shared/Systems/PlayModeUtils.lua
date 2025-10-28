local Players = game:GetService("Players")

local PlayModeUtils = {}

function PlayModeUtils.IsDirectStudioTest(): boolean
	for _, player in ipairs(Players:GetPlayers()) do
		local joinData = player:GetJoinData()
		local tpData = joinData and joinData.TeleportData
		if tpData and tpData.partyId then
			return false
		end
	end
	return true
end

return PlayModeUtils
