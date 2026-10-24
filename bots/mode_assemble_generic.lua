local bot = GetBot()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not string.find(bot:GetUnitName(), "hero") or bot:IsIllusion() then return end

local Fu = require( GetScriptDirectory()..'/FuncLib/func_utils' )
local Localization = require( GetScriptDirectory()..'/FuncLib/systems/localization' )
local HeroNames = require( GetScriptDirectory()..'/FuncLib/data/hero_names_locale' )

local function GetLocalizedHeroName(unit)
	if unit == nil then return '' end
	local unitName = unit:GetUnitName()
	local locale = Localization.GetLocale()
	local names = HeroNames[locale] or HeroNames['en']
	return names[unitName] or HeroNames['en'][unitName] or unitName
end

local function AnnounceWithTarget(locKey, target, cooldown)
	if bot.lastModeChatTime == nil then bot.lastModeChatTime = {} end
	local lastTime = bot.lastModeChatTime[locKey] or -999
	if GameTime() - lastTime < (cooldown or 30) then return end
	bot.lastModeChatTime[locKey] = GameTime()
	local msgs = Localization.Get(locKey)
	if msgs ~= nil and #msgs > 0 then
		local msg = msgs[RandomInt(1, #msgs)]
		if target then
			msg = string.gsub(msg, '{target}', GetLocalizedHeroName(target))
		end
		bot:ActionImmediate_Chat(msg, false)
	end
end

local PING_RECENCY = 8        -- respond to pings within this many seconds
local ASSEMBLE_DURATION = 5    -- stay in assemble mode for this long after ping
local ATTACK_DURATION = 6     -- longer duration when chasing an enemy target
-- Human ping assembly: 0.8 is intentionally above the 0.7 cap because
-- human commands should override all bot-computed modes.
local PING_ASSEMBLE_DESIRE = 0.8
local RE_GROUP_DESIRE = 0.4
local PING_ATTACK_DESIRE = 0.7 -- desire when pinged to actively chasing a kill target
local ATTACK_DESIRE = 0.4     -- desire when itself actively chasing a kill target
local ARRIVE_RADIUS = 50       -- close enough to ping location
local MAX_RESPOND_DIST = 2500  -- only respond if within this distance
local PING_ENEMY_RADIUS = 500  -- tight radius: only target enemy directly pinged
local CHASE_LEASH = 3000       -- give up chase if enemy gets this far from ping

local assembleLoc = nil
local assembleExpireTime = 0
local enemyTarget = nil
local pingOriginLoc = nil      -- original ping location (for leash check)
local regroupTarget = nil      -- ally hero handle we're regrouping toward

function GetDesire()
	if ShouldSkipBotThink(GetBot()) then return 0 end
	if not bot:IsAlive() then return BOT_MODE_DESIRE_NONE end

	-- Check for recent human normal pings (not danger pings)
	local human, ping = Fu.GetHumanPing()
	if human ~= nil and ping ~= nil
	and ping.normal_ping
	and ping.time ~= 0
	and GameTime() - ping.time < PING_RECENCY
	then
		local dist = GetUnitToLocationDistance(bot, ping.location)
		-- Only respond if we're not already very close and not too far away
		if dist > ARRIVE_RADIUS and dist < MAX_RESPOND_DIST then
			assembleLoc = ping.location
			pingOriginLoc = ping.location
			enemyTarget = FindEnemyAtPing()
			if enemyTarget ~= nil then
				assembleExpireTime = GameTime() + ATTACK_DURATION
				AnnounceWithTarget('say_assemble_attack', enemyTarget, ASSEMBLE_DURATION)
			else
				assembleExpireTime = GameTime() + ASSEMBLE_DURATION
				Fu.ModeAnnounce(bot, 'say_assemble', ASSEMBLE_DURATION)
			end
			-- Don't dive tower under level 6
			if bot:GetLevel() < 6 then
				local nearTowers = bot:GetNearbyTowers(1000, true)
				if nearTowers and #nearTowers >= 1 then
					return BOT_MODE_DESIRE_NONE
				end
			end
			local pingDesire = enemyTarget ~= nil and PING_ATTACK_DESIRE or PING_ASSEMBLE_DESIRE
			return pingDesire * RemapValClamped(Fu.GetHP(bot), 0, 0.6, 0, 1)
		end
	end

	-- Continue moving to assembly point if still active
	if assembleLoc ~= nil and GameTime() < assembleExpireTime then
		-- Re-validate enemy target
		if enemyTarget ~= nil then
			if not Fu.IsValidHero(enemyTarget) or not Fu.CanBeAttacked(enemyTarget) then
				enemyTarget = nil
				assembleExpireTime = math.min(assembleExpireTime, GameTime() + 2)
			else
				local enemyDist = pingOriginLoc and GetUnitToLocationDistance(enemyTarget, pingOriginLoc) or 0
				if enemyDist < CHASE_LEASH then
					assembleExpireTime = math.max(assembleExpireTime, GameTime() + 3)
				end
			end
		end

		-- Yield to critical situations: retreat when taking heavy damage
		if bot:WasRecentlyDamagedByAnyHero(2.0) and Fu.GetHP(bot) < 0.3 then
			assembleLoc = nil
			enemyTarget = nil
			return BOT_MODE_DESIRE_NONE
		end

		-- Regroup mode: use low desire so it doesn't override farm/push
		if regroupTarget ~= nil then
			return 0.1
		end

		-- Don't dive tower under level 6
		if bot:GetLevel() < 6 then
			local nearTowers = bot:GetNearbyTowers(1000, true)
			if nearTowers and #nearTowers >= 1 then
				return BOT_MODE_DESIRE_NONE
			end
		end
		local continueDesire = enemyTarget ~= nil and ATTACK_DESIRE or RE_GROUP_DESIRE
		return continueDesire * RemapValClamped(Fu.GetHP(bot), 0, 0.6, 0, 1)
	end

	assembleLoc = nil
	enemyTarget = nil
	pingOriginLoc = nil

	-- Regroup: if bot has no meaningful mode desire, move toward nearest ally group.
	-- This prevents bots from standing idle or wandering alone in mid/late game.
	if not Fu.IsInLaningPhase() and DotaTime() > 15 * 60
	and bot:GetActiveModeDesire() < 0.15
	and Fu.GetHP(bot) > 0.5
	and bot:DistanceFromFountain() > 3000
	then
		local bestAlly = nil
		local bestDist = 99999
		local bestCount = 0

		for i = 1, #GetTeamPlayers(GetTeam()) do
			local member = GetTeamMember(i)
			if member ~= nil and member:IsAlive() and member ~= bot and not member:IsIllusion() then
				local dist = GetUnitToLocationDistance(bot, member:GetLocation())
				-- Count how many allies are near this member
				local nearbyAllies = Fu.GetAlliesNearLoc(member:GetLocation(), 1600)
				local allyCount = 0
				for _, a in pairs(nearbyAllies) do
					if Fu.IsValidHero(a) and a ~= bot then allyCount = allyCount + 1 end
				end
				-- Prefer groups of 2+, then closest ally with meaningful desire
				local memberDesire = member:GetActiveModeDesire()
				if allyCount >= 2 and dist < bestDist then
					bestAlly = member
					bestDist = dist
					bestCount = allyCount
				elseif bestCount < 2 and memberDesire > 0.15 and dist < bestDist then
					bestAlly = member
					bestDist = dist
				end
			end
		end

		if bestAlly ~= nil and bestDist > 600 and bestDist < 8000 then
			regroupTarget = bestAlly
			assembleLoc = bestAlly:GetLocation()
			assembleExpireTime = GameTime() + 8
			return 0.1
		end
	end

	regroupTarget = nil

	-- Re-target: if bot is chasing a target out of attack range but has a better target nearby
	-- if bot:GetActiveMode() == BOT_MODE_ATTACK and Fu.GetHP(bot) > 0.5
	-- and not bot:WasRecentlyDamagedByTower(2.0)
	-- and Fu.WeAreStronger(bot, 1200)
	-- then
	-- 	local currentTarget = Fu.GetProperTarget(bot)
	-- 	local attackRange = bot:GetAttackRange() + 200
	-- 	if Fu.IsValidHero(currentTarget) and GetUnitToUnitDistance(bot, currentTarget) > attackRange then
	-- 		-- Current target is out of range, find a better one
	-- 		local bestTarget = nil
	-- 		local bestScore = 0

	-- 		-- Check ally targets first
	-- 		local nearbyAllies = bot:GetNearbyHeroes(1200, false, BOT_MODE_NONE) or {}
	-- 		for _, ally in pairs(nearbyAllies) do
	-- 			if ally ~= bot and Fu.IsValidHero(ally) and Fu.IsGoingOnSomeone(ally) then
	-- 				local allyTarget = Fu.GetProperTarget(ally)
	-- 				if Fu.IsValidHero(allyTarget) and Fu.CanBeAttacked(allyTarget)
	-- 				and GetUnitToUnitDistance(bot, allyTarget) <= attackRange
	-- 				and not Fu.IsSuspiciousIllusion(allyTarget) then
	-- 					local score = 2.0 / math.max(1, Fu.GetHP(allyTarget))
	-- 					if score > bestScore then
	-- 						bestTarget = allyTarget
	-- 						bestScore = score
	-- 					end
	-- 				end
	-- 			end
	-- 		end

	-- 		-- Prefer ally's attack target for focus fire (don't split targets)
	-- 		if bestTarget == nil then
	-- 			local nearbyAllies = bot:GetNearbyHeroes(1200, false, BOT_MODE_NONE) or {}
	-- 			for _, ally in pairs(nearbyAllies) do
	-- 				if Fu.IsValidHero(ally) and ally ~= bot
	-- 				and ally:GetActiveMode() == BOT_MODE_ATTACK then
	-- 					local allyTarget = ally:GetAttackTarget()
	-- 					if Fu.IsValidHero(allyTarget) and Fu.CanBeAttacked(allyTarget)
	-- 					and GetUnitToUnitDistance(bot, allyTarget) <= 1600 then
	-- 						bestTarget = allyTarget
	-- 						break
	-- 					end
	-- 				end
	-- 			end
	-- 		end

	-- 		-- Fallback: pick weakest enemy in range
	-- 		if bestTarget == nil then
	-- 			local nearbyEnemies = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE) or {}
	-- 			for _, enemy in pairs(nearbyEnemies) do
	-- 				if Fu.IsValidHero(enemy) and Fu.CanBeAttacked(enemy)
	-- 				and GetUnitToUnitDistance(bot, enemy) <= attackRange
	-- 				and not Fu.IsSuspiciousIllusion(enemy) then
	-- 					local score = 1.0 / math.max(1, Fu.GetHP(enemy))
	-- 					if score > bestScore then
	-- 						bestTarget = enemy
	-- 						bestScore = score
	-- 					end
	-- 				end
	-- 			end
	-- 		end

	-- 		if bestTarget ~= nil then
	-- 			enemyTarget = bestTarget
	-- 			assembleLoc = bestTarget:GetLocation()
	-- 			assembleExpireTime = GameTime() + 3
	-- 			bot:SetTarget(bestTarget)
	-- 			return RemapValClamped(Fu.GetHP(bot), 0.2, 0.8, 0, ATTACK_DESIRE)
	-- 		end
	-- 	end
	-- end

	-- Help nearby ally who is engaging an enemy hero, especially during laning
	if Fu.GetHP(bot) > 0.5
	and Fu.IsLaning(bot)
	and not Fu.IsRetreating(bot)
	and not bot:WasRecentlyDamagedByAnyHero(2.0)
	and not Fu.IsGoingOnSomeone(bot)
	and not (Fu.IsValidHero(Fu.GetProperTarget(bot)) and bot:GetActiveMode() == BOT_MODE_ATTACK)
	and not Fu.IsInTeamFight( bot, 1200 )
	then
		local nearbyAllies = bot:GetNearbyHeroes(1600, false, BOT_MODE_NONE) or {}
		for _, ally in pairs(nearbyAllies) do
			if ally ~= bot and Fu.IsValidHero(ally) and Fu.IsGoingOnSomeone(ally) then
				local allyTarget = Fu.GetProperTarget(ally)
				if Fu.IsValidHero(allyTarget) and Fu.CanBeAttacked(allyTarget)
				and not Fu.IsSuspiciousIllusion(allyTarget)
				and GetUnitToUnitDistance(bot, allyTarget) < 1200
				and Fu.WeAreStronger(bot, 1200)
				then
					enemyTarget = allyTarget
					assembleLoc = allyTarget:GetLocation()
					assembleExpireTime = GameTime() + 3
					bot:SetTarget(allyTarget)
					return RemapValClamped(Fu.GetHP(bot), 0.2, 0.8, 0, ATTACK_DESIRE)
				end
			end
		end
	end

	return BOT_MODE_DESIRE_NONE
end

function OnEnd()
	assembleLoc = nil
	assembleExpireTime = 0
	enemyTarget = nil
	pingOriginLoc = nil
	regroupTarget = nil
end

-- Find enemy hero directly at ping location (tight radius = pinged ON the enemy)
function FindEnemyAtPing()
	if assembleLoc == nil then return nil end
	local nearPingEnemies = Fu.GetEnemiesNearLoc(assembleLoc, PING_ENEMY_RADIUS)
	for _, enemy in pairs(nearPingEnemies) do
		if Fu.IsValidHero(enemy) and Fu.CanBeAttacked(enemy) then
			return enemy
		end
	end
	return nil
end

function Think()
	if Fu.CanNotUseAction(bot) then return end
	if assembleLoc == nil then return end

	-- ATTACK: chasing a pinged enemy
	if enemyTarget ~= nil and Fu.IsValidHero(enemyTarget) and Fu.CanBeAttacked(enemyTarget) then
		assembleLoc = enemyTarget:GetLocation()
		local distToEnemy = GetUnitToUnitDistance(bot, enemyTarget)
		if distToEnemy <= bot:GetAttackRange() + 200 then
			bot:Action_AttackUnit(enemyTarget, true)
		else
			bot:Action_MoveToLocation(enemyTarget:GetLocation() + RandomVector(50))
		end
		return
	end

	-- Enemy died or became invalid, clear target
	enemyTarget = nil

	-- REGROUP: following a moving ally — keep updating location
	if regroupTarget ~= nil then
		if not Fu.IsValidHero(regroupTarget) or not regroupTarget:IsAlive() then
			regroupTarget = nil
			assembleLoc = nil
			return
		end
		assembleLoc = regroupTarget:GetLocation()
		local dist = GetUnitToUnitDistance(bot, regroupTarget)
		if dist <= 600 then
			-- Arrived near ally — stop assembling, let other modes take over
			regroupTarget = nil
			assembleLoc = nil
			return
		end
		-- Farm lane creeps on the way if convenient
		local creeps = bot:GetNearbyLaneCreeps(bot:GetAttackRange() + 200, true)
		if Fu.IsValid(creeps[1]) and Fu.CanBeAttacked(creeps[1])
		and Fu.CanKillTarget(creeps[1], bot:GetAttackDamage(), DAMAGE_TYPE_PHYSICAL) then
			bot:Action_AttackUnit(creeps[1], true)
			return
		end
		bot:Action_MoveToLocation(assembleLoc + RandomVector(50))
		return
	end

	-- PING: moving to a pinged location
	local dist = GetUnitToLocationDistance(bot, assembleLoc)
	if dist <= ARRIVE_RADIUS then
		assembleLoc = nil
		return
	end

	-- TP if far away and have TP scroll
	if dist > 4000 and not bot:IsChanneling() then
		local tpScroll = Fu.IsItemAvailable('item_tpscroll')
		if Fu.CanCastAbility(tpScroll) then
			-- Find nearest ally building to the target
			local bestBuilding = nil
			local bestDist = 99999
			for _, towerId in pairs({TOWER_TOP_1,TOWER_TOP_2,TOWER_TOP_3,TOWER_MID_1,TOWER_MID_2,TOWER_MID_3,TOWER_BOT_1,TOWER_BOT_2,TOWER_BOT_3}) do
				local tower = GetTower(GetTeam(), towerId)
				if tower ~= nil and tower:IsAlive() then
					local tDist = GetUnitToLocationDistance(tower, assembleLoc)
					if tDist < bestDist then
						bestDist = tDist
						bestBuilding = tower
					end
				end
			end
			if bestBuilding ~= nil and bestDist < 3000 then
				log('[TP] %s t=%.0f ASSEMBLE tp to building at (%.0f,%.0f)', bot:GetUnitName(), DotaTime(), bestBuilding:GetLocation().x, bestBuilding:GetLocation().y)
				bot:Action_UseAbilityOnLocation(tpScroll, bestBuilding:GetLocation())
				return
			end
		end
	end

	bot:Action_MoveToLocation(assembleLoc + RandomVector(50))
end

-- SafeCall wrapping for error protection
if SafeCall then
  local _origGetDesire = GetDesire
  local _origThink = Think
  if _origGetDesire then GetDesire = SafeCall(_origGetDesire, 0, 'ASSEMBLE_GetDesire') end
  if _origThink then Think = SafeCall(_origThink, nil, 'ASSEMBLE_Think') end
end
