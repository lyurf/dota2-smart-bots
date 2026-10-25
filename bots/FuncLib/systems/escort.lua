--[[
Smart Bots (HATS) - bots that help their human teammates.

Two triggers, so the bot does not wander around a farming core for nothing:

1. The human goes on someone: an allied human hero is fighting a visible enemy hero,
   or (after 10 min) walks into the enemy half next to visible enemy heroes, and the
   fight is not hopeless. Supports (pos 4/5) come from
   up to 4500 away, any other bot joins if it is already close (1800). They attack
   the human's target, or the enemy closest to the human.

2. The human pings the map (alt + click, normal ping, not the danger ping): supports
   within 6000 and any bot within 2500 go to the ping for up to 15 seconds and fight
   what they find there.

Used by mode_team_roam_generic.lua: X.GetDesire(bot) and X.Think(bot).
--]]

local Fu = require(GetScriptDirectory()..'/FuncLib/func_utils')

local X = {}

local SUPPORT_JOIN_DIST = 4500
local CORE_JOIN_DIST = 1800
local PING_SUPPORT_DIST = 6000
local PING_CORE_DIST = 2500
local PING_FRESH_SEC = 5
local PING_FOLLOW_SEC = 15
local FIGHT_RADIUS = 1400
local MAX_ESCORT_SEC = 20
local MIN_BOT_HP = 0.45

local DESIRE_ESCORT = 0.63 -- above farm (0.6), laning and push; below retreat at low HP

local function Clock(t)
	return string.format('%d:%02d', math.floor(t / 60), math.floor(t % 60))
end

local function ShortName(unit)
	return (string.gsub(unit:GetUnitName() or '?', 'npc_dota_hero_', ''))
end

local function IsHumanAlly(unit)
	return unit ~= nil and not unit:IsNull() and unit:IsAlive() and not unit:IsIllusion()
		and not IsPlayerBot(unit:GetPlayerID())
end

local function VisibleEnemiesNear(loc, radius)
	local list = {}
	for _, enemy in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES) or {}) do
		if enemy ~= nil and not enemy:IsNull() and enemy:IsAlive() and enemy:CanBeSeen()
		and not Fu.IsSuspiciousIllusion(enemy)
		and Fu.GetLocationToLocationDistance(enemy:GetLocation(), loc) <= radius then
			table.insert(list, enemy)
		end
	end
	return list
end

local function AlliesNear(loc, radius)
	local n = 0
	for _, ally in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES) or {}) do
		if ally ~= nil and ally:IsAlive() and not ally:IsIllusion()
		and GetUnitToLocationDistance(ally, loc) <= radius then
			n = n + 1
		end
	end
	return n
end

local function IsSupport(bot)
	local pos = Fu.GetPosition(bot)
	return pos == 4 or pos == 5
end

local function ClosestEnemyTo(unit, enemies)
	local best, bestDist = nil, math.huge
	for _, e in ipairs(enemies) do
		local d = GetUnitToUnitDistance(unit, e)
		if d < bestDist then best, bestDist = e, d end
	end
	return best
end

-- An allied human is fighting (or walking into) visible enemy heroes, and we would not be
-- throwing ourselves into a hopeless fight by joining.
local function FindHumanFight(bot)
	local joinDist = IsSupport(bot) and SUPPORT_JOIN_DIST or CORE_JOIN_DIST
	for _, human in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES) or {}) do
		if IsHumanAlly(human) and Fu.GetHP(human) > 0.3 and GetUnitToUnitDistance(bot, human) <= joinDist then
			local enemies = VisibleEnemiesNear(human:GetLocation(), FIGHT_RADIUS)
			if #enemies > 0 then
				local target = human:GetAttackTarget()
				local fighting = (target ~= nil and not target:IsNull() and target:IsHero() and target:GetTeam() ~= bot:GetTeam())
					or human:WasRecentlyDamagedByAnyHero(2.0)
				-- After the laning phase: a healthy human walking into the enemy half next to visible
				-- enemy heroes is going for a gank, so supports come before the fight starts.
				if not fighting and DotaTime() > 10 * 60 and Fu.GetHP(human) > 0.5 then
					local ownAncient, enemyAncient = GetAncient(GetTeam()), GetAncient(GetOpposingTeam())
					if ownAncient ~= nil and enemyAncient ~= nil
					and GetUnitToUnitDistance(human, enemyAncient) < GetUnitToUnitDistance(human, ownAncient) then
						fighting = true
					end
				end
				local allies = AlliesNear(human:GetLocation(), FIGHT_RADIUS) + 1 -- +1: this bot coming
				if fighting and #enemies <= allies + 1 then
					return human, enemies
				end
			end
		end
	end
	return nil, nil
end

local function FindHumanPing(bot)
	for _, human in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES) or {}) do
		if IsHumanAlly(human) then
			local ok, ping = pcall(function() return human:GetMostRecentPing() end)
			if ok and ping ~= nil and ping.time ~= nil and ping.time ~= 0 and ping.normal_ping
			and GameTime() - ping.time <= PING_FRESH_SEC and ping.location ~= nil then
				local maxDist = IsSupport(bot) and PING_SUPPORT_DIST or PING_CORE_DIST
				if GetUnitToLocationDistance(bot, ping.location) <= maxDist then
					return human, ping
				end
			end
		end
	end
	return nil, nil
end

local function Stop(bot, reason)
	local e = bot._smartEscort
	if e ~= nil and e.active then
		e.active = false
		print(string.format('[ESCORT %s] %s stops helping %s: %s', Clock(DotaTime()), ShortName(bot),
			e.human and not e.human:IsNull() and ShortName(e.human) or '?', reason))
	end
end

function X.GetDesire(bot)
	local e = bot._smartEscort
	if e == nil then
		e = { active = false, lastPingTime = 0 }
		bot._smartEscort = e
	end
	if not bot:IsAlive() then return 0 end
	if Fu.GetHP(bot) < MIN_BOT_HP or DotaTime() < 60 then
		if e.active then Stop(bot, 'low HP') end
		return 0
	end
	if Fu.IsDoingRoshan(bot) or bot:IsChanneling() then return 0 end

	-- keep an escort going while it makes sense
	if e.active then
		local now = DotaTime()
		if now - e.startTime > (e.byPing and PING_FOLLOW_SEC or MAX_ESCORT_SEC) then Stop(bot, 'time is up') return 0 end
		if e.human == nil or e.human:IsNull() or not e.human:IsAlive() then Stop(bot, 'he died') return 0 end
		local center = e.byPing and e.pingLoc or e.human:GetLocation()
		local enemies = VisibleEnemiesNear(center, FIGHT_RADIUS)
		if #enemies > 0 then
			e.lastEnemySeen = now
			e.enemies = enemies
		elseif e.byPing then
			e.enemies = {}
			-- reached the ping and nothing is there
			if GetUnitToLocationDistance(bot, e.pingLoc) < 400 then Stop(bot, 'nothing at the ping') return 0 end
		elseif now - (e.lastEnemySeen or now) > 4 then
			Stop(bot, 'fight is over') return 0
		end
		return DESIRE_ESCORT
	end

	-- start a new escort
	local human, enemies = FindHumanFight(bot)
	if human ~= nil then
		e.active, e.byPing, e.human, e.enemies = true, false, human, enemies
		e.startTime, e.lastEnemySeen = DotaTime(), DotaTime()
		print(string.format('[ESCORT %s] %s goes to help %s (%d enemies)', Clock(DotaTime()), ShortName(bot), ShortName(human), #enemies))
		return DESIRE_ESCORT
	end
	local pinger, ping = FindHumanPing(bot)
	if pinger ~= nil and ping.time ~= e.lastPingTime then
		e.lastPingTime = ping.time
		e.active, e.byPing, e.human, e.pingLoc, e.enemies = true, true, pinger, ping.location, {}
		e.startTime, e.lastEnemySeen = DotaTime(), DotaTime()
		print(string.format('[ESCORT %s] %s goes to the ping of %s', Clock(DotaTime()), ShortName(bot), ShortName(pinger)))
		return DESIRE_ESCORT
	end
	return 0
end

function X.IsEscorting(bot)
	return bot._smartEscort ~= nil and bot._smartEscort.active
end

function X.Think(bot)
	local e = bot._smartEscort
	if e == nil or not e.active then return false end

	-- 1) the human's own target, 2) the enemy closest to the human / ping, 3) walk there
	local target = nil
	if e.human ~= nil and not e.human:IsNull() and e.human:IsAlive() then
		local t = e.human:GetAttackTarget()
		if t ~= nil and not t:IsNull() and t:IsAlive() and t:IsHero() and t:GetTeam() ~= bot:GetTeam() and t:CanBeSeen() then
			target = t
		end
	end
	if target == nil and e.enemies ~= nil and #e.enemies > 0 then
		target = ClosestEnemyTo(e.byPing and bot or e.human, e.enemies)
	end
	if target ~= nil and not target:IsNull() and target:IsAlive() and target:CanBeSeen() and Fu.CanBeAttacked(target) then
		bot:SetTarget(target)
		bot:Action_AttackUnit(target, false)
		return true
	end

	local dest = e.byPing and e.pingLoc or (e.human ~= nil and not e.human:IsNull() and e.human:GetLocation()) or nil
	if dest ~= nil then
		bot:Action_MoveToLocation(dest)
		return true
	end
	return false
end

return X
