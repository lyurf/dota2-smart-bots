-- Team Alerts: tactical team-only chat notifications (missings, Roshan death).
-- Runs from ability_item_usage_generic.ItemUsageThink; internally throttled.

local TeamAlerts = {}

local nLastUpdate = -100
local nLastChatAt = -100
local tFreshSeenAt = {} -- enemy player id -> DotaTime when last confirmed visible
local tMissAlertAt = {} -- enemy player id -> DotaTime of last miss alert
local nKnownRoshanKillTime = 0

local MISS_AFTER_SEEN = 12      -- seconds after visibility loss before a miss call
local MISS_REMIND_EVERY = 45    -- don't repeat the same miss within this window
local CHAT_COOLDOWN = 8         -- min seconds between any two alerts from this system
local LANING_ONLY_UNTIL = 15 * 60

local function GetLaneName(vLoc)
	local tLaneFronts = {
		{ GetLaneFrontLocation(GetOpposingTeam(), LANE_TOP, 0), "top" },
		{ GetLaneFrontLocation(GetOpposingTeam(), LANE_MID, 0), "mid" },
		{ GetLaneFrontLocation(GetOpposingTeam(), LANE_BOT, 0), "bot" },
	}
	local sBest, nBestDist = "somewhere", math.huge
	for _, t in pairs(tLaneFronts) do
		local nDist = GetLocationToLocationDistance(vLoc, t[1])
		if nDist < nBestDist then
			nBestDist = nDist
			sBest = t[2]
		end
	end
	return sBest
end

local function IsTeamReporter(hBot)
	-- Exactly one bot per team reports: the alive member with the smallest player id
	local nMyID = hBot:GetPlayerID()
	for i = 1, 5 do
		local hAlly = GetTeamMember(GetTeam(), i)
		if hAlly ~= nil and hAlly:IsHero() and hAlly:IsAlive() and not hAlly:IsIllusion()
		and hAlly:GetPlayerID() < nMyID
		then
			return false
		end
	end
	return true
end

function TeamAlerts.Update(hBot)
	local now = DotaTime()
	if now < 0 or now - nLastUpdate < 3 then return end
	nLastUpdate = now

	if not hBot:IsAlive() or not IsTeamReporter(hBot) then return end

	-- Roshan death alert (any game stage)
	local nRoshanKill = GetRoshanKillTime()
	if nRoshanKill > 0 and nRoshanKill ~= nKnownRoshanKillTime then
		nKnownRoshanKillTime = nRoshanKill
		if now - nLastChatAt > CHAT_COOLDOWN then
			nLastChatAt = now
			hBot:ActionImmediate_Chat("Roshan is down, aegis is out!", true)
		end
	end

	-- Missing alerts: only meaningful while heroes are assigned to lanes
	if now > LANING_ONLY_UNTIL then return end

	for i = 1, 5 do
		local hEnemy = GetTeamMember(GetOpposingTeam(), i)
		if hEnemy ~= nil and hEnemy:IsHero() and hEnemy:IsAlive() and not hEnemy:IsIllusion() then
			local nID = hEnemy:GetPlayerID()
			local tInfo = GetHeroLastSeenInfo(nID)
			if tInfo ~= nil and tInfo[1] ~= nil then
				if tInfo[1].time_since_seen < 5 then
					tFreshSeenAt[nID] = now
				end
				local nFreshSeen = tFreshSeenAt[nID]
				if nFreshSeen ~= nil
				and now - nFreshSeen > MISS_AFTER_SEEN
				and (tMissAlertAt[nID] == nil or now - tMissAlertAt[nID] > MISS_REMIND_EVERY)
				and now - nLastChatAt > CHAT_COOLDOWN
				then
					tMissAlertAt[nID] = now
					nLastChatAt = now
					local sName = string.gsub(hEnemy:GetUnitName(), "npc_dota_hero_", "")
					hBot:ActionImmediate_Chat("Care: " .. sName .. " missing from " .. GetLaneName(tInfo[1].location) .. "!", true)
				end
			end
		end
	end
end

return TeamAlerts
