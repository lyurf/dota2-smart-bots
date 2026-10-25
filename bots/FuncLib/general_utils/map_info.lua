-- Map state: locations, game phase, objectives, areas
local function Init(Fu)

local RadiantFountain = Vector( -6619, -6336, 384 )
local DireFountain = Vector( 6928, 6372, 392 )
local DireBottomTormentorLoc = Vector(7714, -6016, 392)
local RadiantTopTormentorLoc = Vector(-7678, 6337, 392)


function Fu.GetTeamFountain()

	local Team = GetTeam()
	if Team == TEAM_DIRE
	then
		return DireFountain
	else
		return RadiantFountain
	end

end




function Fu.GetEnemyFountain()

	local Team = GetTeam()

	if Team == TEAM_DIRE
	then
		return RadiantFountain
	else
		return DireFountain
	end

end



function Fu.GetEscapeLoc()

	local bot = GetBot()
	local team = GetTeam()

	if bot:DistanceFromFountain() > 2500
	then
		return GetAncient( team ):GetLocation()
	else
		if team == TEAM_DIRE
		then
			return DireFountain
		else
			return RadiantFountain
		end
	end

end



--------------------------------------------------ew functions 2018.12.7

function Fu.GetDistanceFromEnemyFountain( bot )

	local EnemyFountain = Fu.GetEnemyFountain()
	local Distance = GetUnitToLocationDistance( bot, EnemyFountain )

	return Distance

end




function Fu.GetDistanceFromAllyFountain( bot )

	local OurFountain = Fu.GetTeamFountain()
	local Distance = GetUnitToLocationDistance( bot, OurFountain )

	return Distance

end




function Fu.GetDistanceFromAncient( bot, bEnemy )

	local targetAncient = GetAncient( GetTeam() )

	if bEnemy then targetAncient = GetAncient( GetOpposingTeam() ) end

	return GetUnitToUnitDistance( bot, targetAncient )

end




function Fu.IsRoshanCloseToChangingSides()
    return DotaTime() % 300 >= 300 - 30
end


function Fu.IsLocHaveTower( nRadius, bEnemy, nLoc )

	local nTeam = GetTeam()
	if bEnemy then nTeam = GetOpposingTeam() end

	if ( not bEnemy and Fu.GetLocationToLocationDistance( nLoc, Fu.GetTeamFountain() ) < 2500 )
		or ( bEnemy and Fu.GetLocationToLocationDistance( nLoc, Fu.GetEnemyFountain() ) < 2500 )
	then
		return true
	end

	for i = 0, 10
	do
		local tower = GetTower( nTeam, i )
		if tower ~= nil and GetUnitToLocationDistance( tower, nLoc ) <= nRadius
		then
			 return true
		end
	end

	return false

end




function Fu.GetNearbyLocationToTp( nLoc )

	local nTeam = GetTeam()
	local nFountain = Fu.GetTeamFountain()

	if Fu.GetLocationToLocationDistance( nLoc, nFountain ) <= 2500
	then
		return nLoc
	end

	local targetTower = nil
	local minDist = 99999
	for i=0, 10, 1 do
		local tower = GetTower( nTeam, i )
		if tower ~= nil
			and GetUnitToLocationDistance( tower, nLoc ) < minDist
		then
			 targetTower = tower
			 minDist = GetUnitToLocationDistance( tower, nLoc )
		end
	end

	local watchTowerList = Fu.Site.GetAllWatchTower()
	for _, watchTower in pairs( watchTowerList )
	do
		if watchTower ~= nil
			and watchTower:GetTeam() == nTeam
			and GetUnitToLocationDistance( watchTower, nLoc ) < minDist - 1300
			and ( not Fu.IsEnemyHeroAroundLocation( watchTower:GetLocation(), 600 )
					or Fu.IsAllyHeroAroundLocation( watchTower:GetLocation(), 600 ) )
		then
			 targetTower = watchTower
			 minDist = GetUnitToLocationDistance( watchTower, nLoc ) + 1300
		end
	end

	if targetTower ~= nil
	then
		return Fu.GetLocationTowardDistanceLocation( targetTower, nLoc, 575 )
	end

	return nFountain

end




function Fu.IsInAllyArea( bot )

	local hAllyAcient = GetAncient( GetTeam() )
	local hEnemyAcient = GetAncient( GetOpposingTeam() )
	
	if GetUnitToUnitDistance( bot, hAllyAcient ) + 768 < GetUnitToUnitDistance( bot, hEnemyAcient )
	then
		return true
	end
	
	return false

end




function Fu.IsInEnemyArea( bot )

	local hAllyAcient = GetAncient( GetTeam() )
	local hEnemyAcient = GetAncient( GetOpposingTeam() )
	
	if GetUnitToUnitDistance( bot, hEnemyAcient ) + 1280 < GetUnitToUnitDistance( bot, hAllyAcient )
	then
		return true
	end
	
	return false

end



function Fu.IsAllyHeroAroundLocation( vLoc, nRadius )

	for i = 1, #GetTeamPlayers( GetTeam() )
	do
		local npcAlly = GetTeamMember( i )
		if npcAlly ~= nil
			and npcAlly:IsAlive()
			and GetUnitToLocationDistance( npcAlly, vLoc ) <= nRadius
		then
			return true
		end
	end

	return false

end




function Fu.IsEnemyHeroAroundLocation( vLoc, nRadius )
	-- local cacheKey = 'IsEnemyHeroAroundLocation'..tostring(Fu.ToNearest500(vLoc.x))..'-'..tostring(Fu.ToNearest500(vLoc.y))..'-'..tostring(nRadius)
	-- local cache = Fu.Utils.GetCachedVars(cacheKey, 0.5)
	-- if cache ~= nil then return cache end

	for i, id in pairs( GetTeamPlayers( GetOpposingTeam() ) )
	do
		if IsHeroAlive( id ) then
			local info = GetHeroLastSeenInfo( id )
			if info ~= nil then
				local dInfo = info[1]
				if dInfo ~= nil
					and Fu.GetLocationToLocationDistance( vLoc, dInfo.location ) <= nRadius
					and dInfo.time_since_seen < 2.0
				then
					-- Fu.Utils.SetCachedVars(cacheKey, true)
					return true
				end
			end
		end
	end

	-- Fu.Utils.SetCachedVars(cacheKey, false)
	return false

end


function Fu.IsEarlyGame()
	-- Turbo: < 7min, Normal: < 12min
	return DotaTime() < (Fu.IsModeTurbo() and 7 * 60 or 12 * 60)
end


function Fu.IsMidGame()
	-- Turbo: 7-20min, Normal: 12-26min
	local t = DotaTime()
	local earlyEnd = Fu.IsModeTurbo() and 7 * 60 or 12 * 60
	local lateStart = Fu.IsModeTurbo() and 20 * 60 or 26 * 60
	return t >= earlyEnd and t < lateStart
end


function Fu.IsLateGame()
	-- Turbo: 20min+, Normal: 26min+
	return DotaTime() >= (Fu.IsModeTurbo() and 20 * 60 or 26 * 60)
end


function Fu.IsModeTurbo()
	for _, u in pairs(GetUnitList(UNIT_LIST_ALLIES))
	do
		if u ~= nil
		and u:GetUnitName() == 'npc_dota_courier'
		then
			if u:GetCurrentMovementSpeed() == 1100
			then
				return true
			end
		end
	end

    return false
end


function Fu.CheckTimeOfDay()
    local cycle = 600
    local time = DotaTime() % cycle
    local night = 300

    if time < night then return "day", time
    else return "night", time
    end
end


local killTime = 0.0
function Fu.IsRoshanAlive()
	if GetRoshanKillTime() > killTime
    then
        killTime = GetRoshanKillTime()
    end

    if GetRoshanKillTime() == 0
	or DotaTime() - killTime > (Fu.IsModeTurbo() and (6 * 60) or (11 * 60))
    then
        return true
    end

    return false
end


function Fu.IsInLaningPhase()
	local bot = GetBot()
	if bot.isInLanePhase ~= nil and bot.isInLanePhase then return true end
	return false
end


function Fu.IsLocationInChrono(loc)
	for _, enemyHero in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES))
	do
		if Fu.IsValidHero(enemyHero)
		and not Fu.IsSuspiciousIllusion(enemyHero)
		and GetUnitToLocationDistance(enemyHero, loc) < 300
		and enemyHero:HasModifier('modifier_faceless_void_chronosphere_freeze')
		then
			return true
		end
	end

	for _, allyHero in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES))
	do
		if Fu.IsValidHero(allyHero)
		and not allyHero:IsIllusion()
		and GetUnitToLocationDistance(allyHero, loc) < 300
		and (allyHero:HasModifier('modifier_faceless_void_chronosphere_freeze'))
		then
			return true
		end
	end

	return false
end


function Fu.IsLocationInBlackHole(loc)
	for _, enemyHero in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES))
	do
		if Fu.IsValidHero(enemyHero)
		and not Fu.IsSuspiciousIllusion(enemyHero)
		and GetUnitToLocationDistance(enemyHero, loc) < 300
		and (enemyHero:HasModifier('modifier_enigma_black_hole_pull')
			or enemyHero:HasModifier('modifier_enigma_black_hole_pull_scepter'))
		then
			return true
		end
	end

	return false
end


function Fu.IsEnemyChronosphereInLocation(loc)
	local nRadius = 500

	for _, unit in pairs(GetUnitList(UNIT_LIST_ALLIES))
	do
		if Fu.IsValid(unit)
		and GetUnitToLocationDistance(unit, loc) <= nRadius
		and unit:HasModifier('modifier_faceless_void_chronosphere_freeze')
		then
			return true
		end
	end

	return false
end


function Fu.IsEnemyBlackHoleInLocation(loc)
	local nRadius = 500

	for _, unit in pairs(GetUnitList(UNIT_LIST_ALLIES))
	do
		if Fu.IsValid(unit)
		and GetUnitToLocationDistance(unit, loc) <= nRadius
		and (unit:HasModifier('modifier_enigma_black_hole_pull') or unit:HasModifier('modifier_enigma_black_hole_pull_scepter'))
		then
			return true
		end
	end

	return false
end




function Fu.IsLocationInArena(loc, radius)
	for _, enemyHero in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES))
	do
		if Fu.IsValidHero(enemyHero)
		and not Fu.IsSuspiciousIllusion(enemyHero)
		and GetUnitToLocationDistance(enemyHero, loc) < radius
		and (enemyHero:HasModifier('modifier_mars_arena_of_blood_leash')
			or enemyHero:HasModifier('modifier_mars_arena_of_blood_animation'))
		then
			return true
		end
	end

	for _, allyHero in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES))
	do
		if Fu.IsValidHero(allyHero)
		and not allyHero:IsIllusion()
		and GetUnitToLocationDistance(allyHero, loc) < radius
		and (allyHero:HasModifier('modifier_mars_arena_of_blood_animation'))
		then
			return true
		end
	end

	return false
end


function Fu.IsHumanInLoc(vLoc, nRadius)
	for i = 1, #GetTeamPlayers( GetTeam() )
	do
		local member = GetTeamMember(i)

		if  member ~= nil and member:IsAlive() and not member:IsBot() and not member:IsIllusion()
		and not member:HasModifier("modifier_arc_warden_tempest_double")
		and not Fu.IsMeepoClone(member)
		and GetUnitToLocationDistance(member, vLoc) <= nRadius
		then
			return true
		end
	end

	return false
end


function Fu.GetCurrentRoshanLocation()
	-- Variable names are misleading — RadiantRoshanLoc is actually the TOP pit,
	-- DireRoshanLoc is the BOTTOM pit.
	--
	-- Roshan starts at top pit. First moves at 15:00.
	-- Day → top pit (our RadiantRoshanLoc). Night → bottom pit (our DireRoshanLoc).
	local topPit = Fu.Utils.RadiantRoshanLoc    -- (-2984, 2349) = top/northwest
	local bottomPit = Fu.Utils.DireRoshanLoc    -- (2980, -2816) = bottom/southeast

	if DotaTime() < 15 * 60 then
		return topPit
	end
	if Fu.CheckTimeOfDay() == 'day' then
		return topPit
	else
		return bottomPit
	end
end


function Fu.GetTormentorLocation(team)
	-- 7.41: Tormentor's spawn preference switched (day/night swap)
	if Fu.CheckTimeOfDay() == 'day'
	then
		return DireBottomTormentorLoc
	else
		return RadiantTopTormentorLoc
	end
end


-- Team-specific waiting positions near Tormentor (approach from safe side)
local vWaitRadiant_ForRadiant = Vector(7090, -7220, 256)
local vWaitRadiant_ForDire    = Vector(8280, -5350, 128)
local vWaitDire_ForRadiant    = Vector(-8130, 5450, 128)
local vWaitDire_ForDire       = Vector(-6970, 7330, 256)

function Fu.GetTormentorWaitingLocation(team)
	local timeOfDay = Fu.CheckTimeOfDay()
	if timeOfDay == 'day' then
		return GetTeam() == TEAM_RADIANT and vWaitRadiant_ForRadiant or vWaitRadiant_ForDire
	else
		return GetTeam() == TEAM_RADIANT and vWaitDire_ForRadiant or vWaitDire_ForDire
	end
end

local AllyPIDs = nil
function Fu.IsClosestToDustLocation(bot, loc)
	-- Smart Bots: allied heroes from the unit list. The old loop called GetTeamMember() with player
	-- IDs; in per-bot sandboxes it only ever returns the bot itself, so no one was "closest" and
	-- bots never used Dust on enemies that just went invisible.
	local closest = nil
	local closestDist = 100000

	for _, member in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES) or {})
	do
		if Fu.IsValidHero(member)
		and not member:IsIllusion()
		and member:FindItemSlot('item_dust') >= 0
		and member:GetItemSlotType(member:FindItemSlot('item_dust')) == ITEM_SLOT_TYPE_MAIN
		and member:GetItemInSlot(member:FindItemSlot('item_dust')) ~= nil
		and member:GetItemInSlot(member:FindItemSlot('item_dust')):IsFullyCastable()
		then
			local dist = GetUnitToLocationDistance(member, loc)

			if dist < closestDist
			then
				closest = member
				closestDist = dist
			end
		end
	end

	return closest ~= nil and closest == bot
end


function Fu.GetPushTPLocation(nLane)
	local laneFront = GetLaneFrontLocation(GetTeam(), nLane, 0)
	local bestTpLoc = Fu.GetNearbyLocationToTp(laneFront)
	if Fu.GetLocationToLocationDistance(laneFront, bestTpLoc) < 1600
	then
		return bestTpLoc
	end
end


function Fu.GetDefendTPLocation(nLane)
	return GetLaneFrontLocation(GetTeam(), nLane, -950)
end


end

return Init
