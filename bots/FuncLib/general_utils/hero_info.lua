-- Hero role, position, and team member queries
local function Init(Fu)

function Fu.IsCore(bot)
	return Fu.GetPosition(bot) <= 3
end

local PosXHuman = {}
function Fu.IsPosxHuman(x)
	if PosXHuman[x] ~= nil then return PosXHuman[x] end
	for _, ally in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES))
	do
		if Fu.IsValidHero(ally) and Fu.GetPosition(ally) == x and not ally:IsBot()
		then
			PosXHuman[x] = true
			return true
		end
	end
	PosXHuman[x] = false
	return false
end

-- returns 1, 2, 3, 4, or 5 as the position of the hero in the team
function Fu.GetPosition(bot)
	if bot.isBear then
		return Fu.GetPosition(Fu.Utils.GetLoneDruid(bot).hero)
	end
	local role = Fu.Role.GetPosition(bot)
	if role == nil then
		role = 2
	end
	return role
end

-- Stable lane derivation that matches mode_laning_generic.
-- LAN: trust engine GetAssignedLane (sandbox !pos swaps propagate there).
-- Online: position-based (Valve's dynamic balancer can flip GetAssignedLane
-- mid-game, causing defend/push to TP bots to the wrong lane during laning).
function Fu.GetExpectedLane(bot)
	if IsLanMode and IsLanMode() then
		local assigned = bot:GetAssignedLane()
		if assigned == LANE_TOP or assigned == LANE_MID or assigned == LANE_BOT then
			return assigned
		end
	end
	local pos = Fu.GetPosition(bot)
	local team = bot:GetTeam()
	if team == TEAM_RADIANT then
		if pos == 2 then return LANE_MID
		elseif pos == 1 or pos == 5 then return LANE_BOT
		elseif pos == 3 or pos == 4 then return LANE_TOP
		end
	else
		if pos == 2 then return LANE_MID
		elseif pos == 1 or pos == 5 then return LANE_TOP
		elseif pos == 3 or pos == 4 then return LANE_BOT
		end
	end
	return bot:GetAssignedLane() or LANE_MID
end

function Fu.IsNotSelf(bot, ally)
	if bot:GetUnitName() ~= ally:GetUnitName()
	then
		return true
	end
	return false
end

function Fu.IsThereNonSelfCoreNearby(nRadius)
	local selfBot = GetBot()
    local nAllyHeroes = Fu.GetNearbyHeroes(selfBot, nRadius, false, BOT_MODE_NONE)
    for _, ally in pairs(nAllyHeroes) do
        if Fu.IsCore(ally) and selfBot ~= ally
        then
            return true
        end
    end
    return false
end

-- Smart Bots: use the allied hero list instead of GetTeamMember(), which only returns the bot
-- itself in per-bot sandboxes (so this always returned false and supports took cores' farm).
function Fu.IsThereCoreNearby(nRadius)
	local selfBot = GetBot()
	for _, allyHero in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES))
	do
		if allyHero ~= nil
		and allyHero ~= selfBot
		and Fu.IsValidHero(allyHero)
		and not allyHero:IsIllusion()
		and Fu.IsCore(allyHero)
		and Fu.IsInRange(selfBot, allyHero, nRadius)
		then
			return true
		end
	end
    return false
end

function Fu.GetClosestCore(bot, nRadius)
	for i = 1, #GetTeamPlayers( GetTeam() )
	do
		local member = GetTeamMember(i)
		if  member ~= nil
		and member:IsAlive()
		and member ~= bot
		and Fu.IsCore(bot)
		and GetUnitToUnitDistance(bot, member) <= nRadius
		and not Fu.IsSuspiciousIllusion(member)
		then
			return member
		end
	end
	return nil
end

function Fu.GetClosestAlly(bot, nRadius)
	for i = 1, #GetTeamPlayers( GetTeam() )
	do
		local member = GetTeamMember(i)
		if member ~= nil
		and member:IsAlive()
		and member ~= bot
		and GetUnitToUnitDistance(bot, member) <= nRadius
		and not Fu.IsSuspiciousIllusion(member)
		then
			return member
		end
	end
	return nil
end

function Fu.GetLanePartner(bot)
	if bot:GetAssignedLane() == LANE_MID
	then
		return nil
	end
	for i = 1, #GetTeamPlayers( GetTeam() )
	do
		local member = GetTeamMember(i)
		if member ~= nil
		and member:IsAlive()
		and member ~= bot
		and member:GetAssignedLane() == bot:GetAssignedLane()
		then
			return member
		end
	end
	return nil
end

function Fu.GetFirstBotInTeam()
	for i = 1, #GetTeamPlayers( GetTeam() )
	do
		local ally = GetTeamMember(i)
		if ally ~= nil
		and ally:IsBot()
		then
			return ally
		end
	end
end

function Fu.GetClosestTeamLane(unit)
	local v_top_lane = GetLocationAlongLane(LANE_TOP, GetLaneFrontAmount(GetTeam(), LANE_TOP, false))
	local v_mid_lane = GetLocationAlongLane(LANE_MID, GetLaneFrontAmount(GetTeam(), LANE_MID, false))
	local v_bot_lane = GetLocationAlongLane(LANE_BOT, GetLaneFrontAmount(GetTeam(), LANE_BOT, false))
	local dist_from_top = GetUnitToLocationDistance(unit, v_top_lane)
	local dist_from_mid = GetUnitToLocationDistance(unit, v_mid_lane)
	local dist_from_bot = GetUnitToLocationDistance(unit, v_bot_lane)
	if dist_from_top < dist_from_mid and dist_from_top < dist_from_bot
	then
		return v_top_lane
	elseif dist_from_mid < dist_from_top and dist_from_mid < dist_from_bot
	then
		return v_mid_lane
	elseif dist_from_bot < dist_from_top and dist_from_bot < dist_from_mid
	then
		return v_bot_lane
	end
	return v_mid_lane
end

function Fu.GetCoresAverageNetworth()
	-- Bounded key: 1 value per bot
	local bot = GetBot()
	if bot._coreNWCache and DotaTime() - bot._coreNWCache[1] <= 2.0 then
		return bot._coreNWCache[2]
	end

	local totalNetWorth = 0
	local coreCount = 0
	for i = 1, #GetTeamPlayers( GetTeam() )
	do
		local member = GetTeamMember(i)
		if Fu.IsValidHero(member)
		and Fu.IsCore(member)
		then
			totalNetWorth = totalNetWorth + member:GetNetWorth()
			coreCount = coreCount + 1
		end
	end
	local result = totalNetWorth / coreCount
	bot._coreNWCache = { DotaTime(), result }
	return result
end

function Fu.IsHaveAegis( bot )
	return bot:FindItemSlot( "item_aegis" ) >= 0
end

function Fu.DoesTeamHaveAegis()
	-- Bounded key: 1 value per bot
	local bot = GetBot()
	if bot._aegisCache and DotaTime() - bot._aegisCache[1] <= 2.0 then
		return bot._aegisCache[2]
	end

	local numPlayer = GetTeamPlayers( GetTeam() )
	for i = 1, #numPlayer
	do
		local member = GetTeamMember(i)
		if Fu.IsValidHero(member)
		and Fu.IsHaveAegis(member)
		then
			bot._aegisCache = { DotaTime(), true }
			return true
		end
	end
	bot._aegisCache = { DotaTime(), false }
	return false
end

function Fu.IsOtherAllysTarget( unit )
	local bot = GetBot()
	local hAllyList = Fu.GetNearbyHeroes(bot, 800, false, BOT_MODE_NONE )
	if #hAllyList <= 1 then return false end
	for _, ally in pairs( hAllyList )
	do
		if Fu.IsValid( ally )
			and ally ~= bot
			and not ally:IsIllusion()
			and ( Fu.GetProperTarget( ally ) == unit
					or ( not ally:IsBot() and ally:IsFacingLocation( unit:GetLocation(), 20 ) ) )
		then
			return true
		end
	end
	return false
end

function Fu.IsAllysTarget( unit )
	local bot = GetBot()
	local hAllyList = Fu.GetNearbyHeroes(bot, 800, false, BOT_MODE_NONE )
	for _, ally in pairs( hAllyList )
	do
		if Fu.IsValid( ally )
			and not ally:IsIllusion()
			and ( Fu.GetProperTarget( ally ) == unit
					or ( not ally:IsBot() and ally:IsFacingLocation( unit:GetLocation(), 12 ) ) )
		then
			return true
		end
	end
	return false
end

function Fu.IsEnemyFacingUnit( bot, nRadius, nDegrees )
	local nLoc = bot:GetLocation()
	if nRadius > 1600 then nRadius = 1600 end
	local nEnemyHeroes = Fu.GetNearbyHeroes(bot, nRadius, true, BOT_MODE_NONE )
	for _, enemy in pairs( nEnemyHeroes )
	do
		if Fu.IsValid( enemy )
			and enemy:IsFacingLocation( nLoc, nDegrees )
		then
			return true
		end
	end
	return false
end

function Fu.IsEnemyTargetUnit( nUnit, nRadius )
	if nRadius > 1600 then nRadius = 1600 end
	local nEnemyHeroes = Fu.GetNearbyHeroes(GetBot(), nRadius, true, BOT_MODE_NONE )
	for _, enemy in pairs( nEnemyHeroes )
	do
		if Fu.IsValid( enemy )
			and Fu.GetProperTarget( enemy ) == nUnit
		then
			return true
		end
	end
	return false
end

function Fu.CheckLoneDruid()
	local ld = {hero=nil,bear=nil}
	for _, unit in pairs(GetUnitList(UNIT_LIST_ALL)) do
		if Fu.IsValid(unit) and not Fu.IsSuspiciousIllusion(unit) then
			local unitName = unit:GetUnitName()
			if unitName == 'npc_dota_hero_lone_druid' then
				ld.hero = unit
			elseif unitName == 'npc_dota_hero_lone_druid_bear' then
				ld.bear = unit
			end
		end
	end
	return ld
end

function Fu.GetHumanPing()
	local ping = nil
	for i = 1, #GetTeamPlayers( GetTeam() )
	do
		local member = GetTeamMember(i)
		if  member ~= nil
		and not member:IsBot()
		then
			return member, member:GetMostRecentPing()
		end
	end
	return nil, ping
end

function Fu.FindEnemyUnit(name)
	for _, unit in pairs(GetUnitList(UNIT_LIST_ENEMIES))
	do
		if Fu.IsValid(unit)
		then
			if string.find(unit:GetUnitName(), name) then
				return unit
			end
		end
	end
	return nil
end

function Fu.HasEnemyIceSpireNearby(bot, nRange)
	for _, enemy in pairs(GetUnitList(UNIT_LIST_ENEMIES)) do
        if Fu.IsValid(enemy)
		and enemy:GetUnitName() == "npc_dota_lich_ice_spire"
		and Fu.IsInRange(bot, enemy, nRange) then
			return enemy
		end
	end
	return false
end

function Fu.AnyAllyAffectedByChainFrost(bot, nRange)
	for _, ally in pairs(GetUnitList(UNIT_LIST_ALLIES))
	do
        if Fu.IsValid(ally)
        and Fu.IsInRange(bot, ally, nRange)
		and ally ~= bot
        and ally:HasModifier('modifier_lich_chainfrost_slow') then
            return true
        end
    end
	return false
end

end

return Init
