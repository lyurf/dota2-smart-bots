local Utils = require( GetScriptDirectory()..'/FuncLib/systems/utils')
local Fu = require( GetScriptDirectory()..'/FuncLib/func_utils')

local Version      = require(GetScriptDirectory()..'/FuncLib/systems/version')
local Localization = require(GetScriptDirectory()..'/FuncLib/systems/localization')


local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

if bot.isInLanePhase == nil then bot.isInLanePhase = false end

local local_mode_laning_generic = nil
local nAllyCreeps = nil
local nEnemyCreeps = nil
local nFurthestEnemyAttackRange = 0
local nInRangeEnemy = nil
local botAssignedLane = nil
local botAttackRange = bot:GetAttackRange()
local attackDamage = bot:GetAttackDamage()
local nH, enemyBots = Fu.Utils.NumHumanBotPlayersInTeam(GetOpposingTeam())
local teamHumans, teamBots = Fu.Utils.NumHumanBotPlayersInTeam(GetTeam())

-- Announcer state
local hasPickedOneAnnouncer      = false
local lastAnnouncePrintedTime    = 0
local numberAnnouncePrinted      = 1
local announcementGapSeconds     = 6
local isChangePosMessageDone     = false

if Utils.BuggyHeroesDueToValveTooLazy[botName] then local_mode_laning_generic = dofile( GetScriptDirectory().."/FuncLib/systems/override_generic/mode_laning_generic" ) end

-- Smart Bots: our own laning (last hits, getting ready for the next last hit, denies, support
-- discipline) for every hero instead of Valve's built-in laning, which only reached 22-33 last
-- hits at 10:00 for core bots in tests. Set Customize.Smart_Laning = false to use Valve's laning.
local bSmartLaning = not (Fu.Customize and Fu.Customize.Smart_Laning == false)

function GetDesire()
	if ShouldSkipBotThink(GetBot()) then return 0 end
	return GetDesireRaw()
end

function GetDesireRaw()
	PickOneAnnouncer()
	AnnounceMessages()

	-- Default to not laning; set true below only when actively in lane
	bot.isInLanePhase = false
	local botLV = bot:GetLevel()
	local currentTime = DotaTime()

	botAttackRange = bot:GetAttackRange()
	nAllyCreeps = bot:GetNearbyLaneCreeps(1200, false)
	nEnemyCreeps = bot:GetNearbyLaneCreeps(800, true)
	nInRangeEnemy = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
	nFurthestEnemyAttackRange = GetFurthestEnemyAttackRange(nInRangeEnemy)
	if local_mode_laning_generic then
		botAssignedLane = local_mode_laning_generic.GetBotTargetLane()
	else
		-- Online (shared scope): derive lane from position. Fu.GetPosition
		-- already sees !pos updates via the shared RoleAssignment, and Valve's
		-- dynamic balancer (especially in turbo) can flip bot:GetAssignedLane()
		-- mid-game, which made non-swapped bots walk to the wrong lane and
		-- bounce back. LAN sandboxes keep GetAssignedLane as the source of
		-- truth since RoleAssignment mutations don't cross sandbox boundaries.
		if IsLanMode and IsLanMode() then
			botAssignedLane = bot:GetAssignedLane()
		else
			local pos = Fu.GetPosition(bot)
			if GetTeam() == TEAM_RADIANT then
				if pos == 2 then botAssignedLane = LANE_MID
				elseif pos == 1 or pos == 5 then botAssignedLane = LANE_BOT
				elseif pos == 3 or pos == 4 then botAssignedLane = LANE_TOP
				end
			else
				if pos == 2 then botAssignedLane = LANE_MID
				elseif pos == 1 or pos == 5 then botAssignedLane = LANE_TOP
				elseif pos == 3 or pos == 4 then botAssignedLane = LANE_BOT
				end
			end
			if botAssignedLane == nil then
				botAssignedLane = bot:GetAssignedLane() or LANE_MID
			end
		end
	end
	attackDamage = bot:GetAttackDamage()
	if bot:GetItemSlotType(bot:FindItemSlot("item_quelling_blade")) == ITEM_SLOT_TYPE_MAIN then
		if bot:GetAttackRange() > 310 or bot:GetUnitName() == "npc_dota_hero_templar_assassin" then
			attackDamage = attackDamage + 4
		else
			attackDamage = attackDamage + 8
		end
	end

	if currentTime < 0 then return BOT_ACTION_DESIRE_NONE end

	-- Smart Bots: lane report in the console at 5:00 and 10:00 (last hits / denies / level),
	-- so laning changes can be compared between test games.
	for _, reportMin in ipairs({5, 10}) do
		if currentTime >= reportMin * 60 and not bot['_laneReport'..reportMin] then
			bot['_laneReport'..reportMin] = true
			local okLH, lh = pcall(function() return bot:GetLastHits() end)
			local okDN, dn = pcall(function() return bot:GetDenies() end)
			local nObs = 0
			for _, w in pairs(GetUnitList(UNIT_LIST_ALLIED_WARDS) or {}) do
				if w ~= nil and w:GetUnitName() == 'npc_dota_observer_wards' then nObs = nObs + 1 end
			end
			print(string.format('[LANE %d:00] %s pos %d: LH %s / DN %s, level %d, nw %d, team observers on map %d', reportMin, botName, Fu.GetPosition(bot),
				okLH and tostring(lh) or '?', okDN and tostring(dn) or '?', bot:GetLevel(), bot:GetNetWorth(), nObs))
		end
	end

	-- if DotaTime() > 20 and DotaTime() - skipLaningState.lastCheckTime < skipLaningState.checkGap then
	-- 	if skipLaningState.count > 6 then
	-- 		print('[WARN] Bot ' ..botName.. ' switching modes too often, now stop it for laning to avoid conflicts.')
	-- 		return 0
	-- 	end
	-- else
	-- 	skipLaningState.lastCheckTime = DotaTime()
	-- 	skipLaningState.count = 0
	-- end

	if Fu.GetEnemiesAroundAncient(bot, 3200) > 0 then
		return BOT_MODE_DESIRE_NONE
	end

	-- if Fu.GetDistanceFromAncient( bot, true ) < 6900 then
	-- 	return BOT_MODE_DESIRE_NONE
	-- end

	-- If being pressured AND low HP, reduce laning so retreat can take over
	-- Don't zero laning desire — that leaves the bot with no mode and it dies idle
	if bot:WasRecentlyDamagedByAnyHero(3)
	and #Fu.Utils.GetLastSeenEnemyIdsNearLocation(bot:GetLocation(), 800) > 0 then
		if Fu.GetHP(bot) < 0.4 and not Fu.WeAreStronger(bot, 1200) then
			return BOT_MODE_DESIRE_VERYLOW -- let retreat win
		end
	end

	-- Fighting enemy heroes: only drop laning if committed to a fight
	-- (enemy far from lane / low HP chase), not during normal lane trading
	if nInRangeEnemy ~= nil and #nInRangeEnemy >= 1
	and (bot:WasRecentlyDamagedByAnyHero(2.0) or Fu.IsGoingOnSomeone(bot))
	then
		local closestEnemy = nInRangeEnemy[1]
		local closestDist = Fu.IsValidHero(closestEnemy) and GetUnitToUnitDistance(bot, closestEnemy) or -1
		if closestDist >= 0 and closestDist < 1000 and Fu.GetHP(closestEnemy) < 0.6 then
			return 0.1
		end
	end

	-- 如果在打高地 就别撤退去干别的
	if Fu.Utils.IsTeamPushingSecondTierOrHighGround(bot) then
		return BOT_MODE_DESIRE_NONE
	end
	-- if Fu.ShouldGoFarmDuringLaning(bot) then
	-- 	return 0.2
	-- end

	if local_mode_laning_generic or bSmartLaning or (Fu.GetPosition(bot) == 1 and Fu.IsPosxHuman(5)) then
		-- last hit priority during early laning
		if currentTime <= 9 * 60 then
			local hitCreep, _ = GetBestLastHitCreep(nEnemyCreeps)
			if Fu.IsValid(hitCreep) then
				if Fu.IsCore(bot) or not Fu.IsThereCoreNearby(1300) -- supports leave last hits to a core in the same lane
				then
					return 0.6
				end
			end
		end
	end
	if local_mode_laning_generic and local_mode_laning_generic.GetDesire ~= nil then return local_mode_laning_generic.GetDesire() end

	if GetGameMode() == GAMEMODE_1V1MID or GetGameMode() == GAMEMODE_MO then
		return 1
	end

	-- No point laning if enemy T2 is dead in this lane — push/farm instead
	local t2Map = { [LANE_TOP] = TOWER_TOP_2, [LANE_MID] = TOWER_MID_2, [LANE_BOT] = TOWER_BOT_2 }
	local t2Tower = t2Map[botAssignedLane] and GetTower(GetOpposingTeam(), t2Map[botAssignedLane])
	if t2Tower == nil or not t2Tower:IsAlive() then
		return 0
	end

	-- Scale laning desire by HP when enemies are nearby (unsafe lane)
	-- Safe lane (no enemies): full desire so bot stays to farm/regen
	local botHP = Fu.GetHP(bot)
	local bSafeLane = #nInRangeEnemy == 0 or bot:HasModifier('modifier_tower_aura_bonus')
	local hpScale = bSafeLane and 1 or RemapValClamped(botHP, 0, 0.7, 0, 1)

	if currentTime <= 10 then
		bot.isInLanePhase = true
		return 0.268 * hpScale
	end
	if currentTime <= 10 * 60 then
		bot.isInLanePhase = true

		if Fu.IsCore(bot)
			and bSafeLane
			and not bot:WasRecentlyDamagedByAnyHero(5.0)
			and not Fu.IsRetreating(bot)
		then
			return BOT_MODE_DESIRE_HIGH + 0.04
		end
		return (BOT_MODE_DESIRE_MODERATE - 0.05) * hpScale
	end

	if currentTime <= 12 * 60 and botLV <= 11 then return 0.2 * hpScale end

	-- Past early laning: farm and push should fully take over
	bot.isInLanePhase = false
	return BOT_MODE_DESIRE_NONE
end

function GetFurthestEnemyAttackRange(enemyList)
	local attackRange = 0
	for _, enemy in pairs(enemyList) do
		if Fu.IsValidHero(enemy) and not Fu.IsSuspiciousIllusion(enemy) then
			local enemyAttackRange = enemy:GetAttackRange()
			if enemyAttackRange > attackRange then
				attackRange = enemyAttackRange
			end
		end
	end

	return attackRange
end

-- Score a creep by value: ranged > flagbearer > melee
local function GetCreepScore(creep)
	local name = creep:GetUnitName()
	if string.find(name, 'ranged') then return 3 end
	if string.find(name, 'flagbearer') then return 2 end
	return 1
end

function GetBestLastHitCreep(hCreepList)
	-- Use attackDamage - 3 as safety margin for guaranteed kills
	local safeDamage = attackDamage - 3

	local bestCreep = nil
	local bestScore = 0
	for _, creep in pairs(hCreepList) do
		if Fu.IsValid(creep) and Fu.CanBeAttacked(creep) then
			local nDelay = Fu.GetAttackProDelayTime(bot, creep)
			local score = GetCreepScore(creep)
			if Fu.WillKillTarget(creep, safeDamage, DAMAGE_TYPE_PHYSICAL, nDelay) then
				if score > bestScore then
					bestScore = score
					bestCreep = creep
				end
			end
		end
	end

	return bestCreep
end

function GetBestDenyCreep(hCreepList)
	local bestDeny = nil
	local bestScore = 0
	for _, creep in pairs(hCreepList)
	do
		if Fu.IsValid(creep)
		and Fu.GetHP(creep) < 0.49
		and Fu.CanBeAttacked(creep)
		and creep:GetHealth() <= attackDamage
		and Fu.IsInRange(bot, creep, botAttackRange + 150)
		then
			local score = GetCreepScore(creep)
			if score > bestScore then
				bestScore = score
				bestDeny = creep
			end
		end
	end

	return bestDeny
end

-- Smart Bots: enemy creep that will soon be killable (low HP and being hit by our creeps),
-- not under the enemy tower. Returns the lowest-HP one.
function GetCreepToPrepare(hCreepList, nEnemyTowers)
	local best, bestHP = nil, math.huge
	for _, creep in pairs(hCreepList) do
		if Fu.IsValid(creep) and Fu.CanBeAttacked(creep) then
			local hp = creep:GetHealth()
			local underTower = Fu.IsValidBuilding(nEnemyTowers and nEnemyTowers[1])
				and GetUnitToUnitDistance(creep, nEnemyTowers[1]) < 750
			if not underTower
			and hp <= attackDamage * 2.2
			and GetUnitToUnitDistance(bot, creep) <= botAttackRange + 450
			and hp < bestHP
			then
				best, bestHP = creep, hp
			end
		end
	end
	return best
end

local fNextMovementTime = 0
local fNextHarassTime = 0

-- Drop tower aggro by attacking a nearby ally creep
local function DropTowerAggro(nAllyCreepList)
	local nEnemyTowers = bot:GetNearbyTowers(900, true)
	if Fu.IsValidBuilding(nEnemyTowers[1]) and nEnemyTowers[1]:GetAttackTarget() == bot then
		for _, creep in pairs(nAllyCreepList) do
			if Fu.IsValid(creep) and Fu.IsInRange(bot, creep, botAttackRange + 100) then
				bot:Action_AttackUnit(creep, true)
				return true
			end
		end
	end
	return false
end

if local_mode_laning_generic or bSmartLaning or (Fu.GetPosition(bot) == 1 and Fu.IsPosxHuman(5)) then
	function Think()
		local nEnemyTowers = bot:GetNearbyTowers(1200, true)

		-- Drop tower aggro first
		if DropTowerAggro(nAllyCreeps) then return end

		-- Back off from enemy tower if too close without enough creeps tanking
		if Fu.IsValidBuilding(nEnemyTowers[1]) then
			local distFromTower = GetUnitToUnitDistance(bot, nEnemyTowers[1])
			if distFromTower < 800 and #nEnemyCreeps < 3 then
				if DotaTime() >= fNextMovementTime then
					bot:Action_MoveToLocation(Fu.VectorAway(bot:GetLocation(), nEnemyTowers[1]:GetLocation(), 950) + RandomVector(75))
					fNextMovementTime = DotaTime() + RandomFloat(1, 3)
					return
				end
			end
		end

		-- Last hit
		local hitCreep = GetBestLastHitCreep(nEnemyCreeps)
		if Fu.IsValid(hitCreep) then
			-- Skip last-hits when creeps are under enemy tower and out of range
			-- but allow if we have enough ally creeps to tank
			if Fu.IsValidBuilding(nEnemyTowers[1])
			and Fu.IsValid(nEnemyCreeps[1])
			and GetUnitToUnitDistance(nEnemyCreeps[1], nEnemyTowers[1]) < 700
			and GetUnitToUnitDistance(nEnemyCreeps[1], bot) > botAttackRange then
				local nAllyCreepsNearTower = bot:FindAoELocation(false, false, nEnemyTowers[1]:GetLocation(), 0, 650, 0, 0)
				if nAllyCreepsNearTower.count <= 3 then
					goto skipLastHit
				end
			end

			-- Lane partner awareness: supports yield last hits to a core in the same lane
			if Fu.IsCore(bot) or not Fu.IsThereCoreNearby(1300)
			then
				local distToCreep = GetUnitToUnitDistance(bot, hitCreep)
				if distToCreep > botAttackRange then
					-- Move to attack range, stop at bounding radius distance
					local stopDist = botAttackRange - hitCreep:GetBoundingRadius()
					local moveTarget = Fu.GetXUnitsTowardsLocation2(hitCreep:GetLocation(), bot:GetLocation(), stopDist)
					bot:Action_MoveDirectly(moveTarget)
					return
				else
					bot:SetTarget(hitCreep)
					bot:Action_AttackUnit(hitCreep, false)
					return
				end
			end

			::skipLastHit::
		end

		-- Deny
		local denyCreep = GetBestDenyCreep(nAllyCreeps)
		if Fu.IsValid(denyCreep) then
			bot:SetTarget(denyCreep)
			bot:Action_AttackUnit(denyCreep, true)
			return
		end

		-- Smart Bots: creep aggro control. Hitting a hero pulls nearby enemy creeps onto us;
		-- when 2+ creeps are on us, step back behind our own wave so they lose interest.
		local creepsOnMe = 0
		for _, c in pairs(nEnemyCreeps) do
			if Fu.IsValid(c) and c:GetAttackTarget() == bot then
				creepsOnMe = creepsOnMe + 1
			end
		end
		if creepsOnMe >= 2 then
			bot:Action_MoveToLocation(Fu.AdjustLocationWithOffsetTowardsFountain(bot:GetLocation(), 350))
			return
		end

		-- Smart Bots: get ready for the next last hit - stand in attack range of the enemy creep
		-- that is about to die, instead of walking around until it is already killable.
		if Fu.IsCore(bot) or not Fu.IsThereCoreNearby(1300) then
			local prepCreep = GetCreepToPrepare(nEnemyCreeps, nEnemyTowers)
			if Fu.IsValid(prepCreep) then
				local standDist = math.max(botAttackRange - 60, 100)
				local standLoc = Fu.GetXUnitsTowardsLocation2(prepCreep:GetLocation(), bot:GetLocation(), standDist)
				if GetUnitToLocationDistance(bot, standLoc) > 60 then
					bot:Action_MoveToLocation(standLoc)
				else
					bot:Action_MoveToLocation(bot:GetLocation()) -- hold position, ready to strike
				end
				return
			end
		end

		if local_mode_laning_generic then
			local_mode_laning_generic.Think()
			return
		end

		-- Opportunistic tower hit when siege creep is tanking
		if Fu.IsValidBuilding(nEnemyTowers[1]) and Fu.CanBeAttacked(nEnemyTowers[1])
		and Fu.IsValid(nEnemyTowers[1]:GetAttackTarget()) and nEnemyTowers[1]:GetAttackTarget():IsCreep() then
			if #nAllyCreeps >= 3 then
				bot:Action_AttackUnit(nEnemyTowers[1], true)
				return
			end
		end

		-- Smart Bots: lane harass. Supports trade right-clicks actively (they have no last hits to
		-- take), cores harass when healthy. One hit at a time with a short pause, so the bot does
		-- not stand in the creep wave and keep the aggro. Prefer the lowest-HP enemy in range.
		if DotaTime() >= fNextHarassTime then
			local bIsCore = Fu.IsCore(bot)
			local fMinHP = bIsCore and 0.6 or 0.45
			local nExtraRange = bIsCore and 50 or 200
			if Fu.GetHP(bot) > fMinHP then
				local target, targetHP = nil, math.huge
				for _, enemy in pairs(nInRangeEnemy) do
					if Fu.IsValidHero(enemy)
					and Fu.CanBeAttacked(enemy)
					and not Fu.IsSuspiciousIllusion(enemy)
					and Fu.IsInRange(bot, enemy, botAttackRange + nExtraRange)
					and not (Fu.IsValidBuilding(nEnemyTowers[1]) and GetUnitToUnitDistance(enemy, nEnemyTowers[1]) < 800)
					then
						local hp = enemy:GetHealth()
						if hp < targetHP then target, targetHP = enemy, hp end
					end
				end
				if target ~= nil then
					bot:Action_AttackUnit(target, true)
					fNextHarassTime = DotaTime() + (bIsCore and RandomFloat(2.0, 3.5) or RandomFloat(1.2, 2.2))
					return
				end
			end
		end

		-- Move to lane front position with throttled timing
		local fLaneFrontAmount = GetLaneFrontAmount(GetTeam(), botAssignedLane, false)
		local fLaneFrontAmount_enemy = GetLaneFrontAmount(GetOpposingTeam(), botAssignedLane, false)
		local nLongestAttackRange = math.max(botAttackRange, 250, nFurthestEnemyAttackRange)
		-- Smart Bots: supports stand close enough to threaten the enemy laners instead of hiding
		-- behind the wave (they keep their own attack range, not the enemy's).
		if not Fu.IsCore(bot) and Fu.GetHP(bot) > 0.5 then
			nLongestAttackRange = math.max(botAttackRange * 0.8, 200)
		end

		local target_loc = GetLaneFrontLocation(GetTeam(), botAssignedLane, -nLongestAttackRange)
		if fLaneFrontAmount_enemy < fLaneFrontAmount then
			target_loc = GetLaneFrontLocation(GetOpposingTeam(), botAssignedLane, -nLongestAttackRange)
		end

		if DotaTime() >= fNextMovementTime then
			bot:Action_MoveToLocation(target_loc + RandomVector(100))
			fNextMovementTime = DotaTime() + RandomFloat(0.3, 0.9)
		end
	end
end


function PickOneAnnouncer()
	if hasPickedOneAnnouncer then return end
	-- Deterministic election via engine-backed PID queries. GetTeamMember()
	-- returns only self in LAN per-bot sandboxes, which made every bot elect
	-- itself. GetTeamForPlayer() and IsPlayerBot() are visible across
	-- sandboxes, so every bot's scan converges on the same lowest-PID bot.
	local myPid = bot:GetPlayerID()
	local myTeam = bot:GetTeam()
	local lowestBotPid = myPid
	for pid = 0, 63 do
		if pid ~= myPid then
			local ok1, isBot = pcall(IsPlayerBot, pid)
			local ok2, team = pcall(GetTeamForPlayer, pid)
			if ok1 and ok2 and isBot and team == myTeam and pid < lowestBotPid then
				lowestBotPid = pid
			end
		end
	end
	bot.isAnnouncer = (myPid == lowestBotPid)
	hasPickedOneAnnouncer = true
end

function AnnounceMessages()
	-- Only pre-game chatter
	if DotaTime() > 60 then return end

	local welcomeMessages = Localization.Get('welcome_msgs')
	local inTurbo         = Fu.IsModeTurbo()

	-- Staggered lines during negative DotaTime pre-game
	if ((inTurbo and DotaTime() > -50 + GetTeam() * 2) or (not inTurbo and DotaTime() > -75 + GetTeam() * 2))
	   and numberAnnouncePrinted < #welcomeMessages + 1
	   and bot.isAnnouncer
	   and DotaTime() < 0
	then
		if GameTime() - lastAnnouncePrintedTime >= announcementGapSeconds then
			local message      = welcomeMessages[numberAnnouncePrinted]
			local isFirstLine  = (numberAnnouncePrinted == 1)
			if message then
				-- Match original behavior: first line (or if no enemy bots) can be global
				bot:ActionImmediate_Chat(isFirstLine and (message .. Version.number) or message, enemyBots == 0 or isFirstLine)
			end
			numberAnnouncePrinted   = numberAnnouncePrinted + 1
			lastAnnouncePrintedTime = GameTime()
		end
	end

	-- Close position selection after horn if humans and bots mixed
	if GetGameMode() ~= GAMEMODE_1V1MID and not isChangePosMessageDone then
		if DotaTime() >= 0 and teamHumans > 0 and teamBots > 0 then
			bot:ActionImmediate_Chat(Localization.Get('pos_select_closed') .. ' (' .. tostring(Fu.GetPosition(bot)) .. ')', true)
			isChangePosMessageDone = true
		end
	end
end

-- SafeCall wrapping for error protection
if SafeCall then
  local _origGetDesire = GetDesire
  local _origThink = Think
  if _origGetDesire then GetDesire = SafeCall(_origGetDesire, 0, 'LANING_GetDesire') end
  if _origThink then Think = SafeCall(_origThink, nil, 'LANING_Think') end
end
