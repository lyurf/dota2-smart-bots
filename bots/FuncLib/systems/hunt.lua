--[[
Smart Bots (HATS) - hunting the enemy carry.

After the laning phase, bots look for the enemy's most farmed hero (estimated
position 1, then 2) when he is seen alone, away from his towers. The 3-4 healthy
bots closest to him go and kill him together, like a smoke gank.

Every bot runs in its own script, so there is no shared "team brain". Each bot
makes the same decision from the same information (where the target was seen,
where the allies are) and joins only if it is one of the chosen hunters, so the
whole group moves together without talking to each other.

Used by mode_team_roam_generic.lua: X.GetDesire(bot) and X.Think(bot).
--]]

local Fu = require(GetScriptDirectory()..'/FuncLib/func_utils')
local EnemyRoles = require(GetScriptDirectory()..'/FuncLib/hero/enemy_role_estimation')

local X = {}

local MAX_HUNTERS = 4
local MIN_HUNTERS = 3
local MAX_GATHER_DIST = 5000      -- hunters must be this close to the target to join
local ISOLATION_RADIUS = 1600     -- enemies around the target that count as help
local TOWER_SAFE_DIST = 1000      -- do not dive the target under a tower
local LAST_SEEN_START = 3.0       -- seconds: target must be seen this recently to start
local LAST_SEEN_KEEP = 6.0        -- ... and to keep hunting
local MAX_HUNT_TIME = 30          -- seconds, then give up
local HUNT_COOLDOWN = 15          -- seconds before the same bot starts another hunt
local MIN_HP_START = 0.55
local MIN_HP_KEEP = 0.35

local DESIRE_FAR = 0.62           -- beats farm (max 0.6) and push (0.525)
local DESIRE_NEAR = 0.66          -- keeps the focus on the target in the fight (Valve attack is 0.65)

local function Clock(t)
	return string.format('%d:%02d', math.floor(t / 60), math.floor(t % 60))
end

local function ShortName(unitName)
	return (string.gsub(unitName or '?', 'npc_dota_hero_', ''))
end

local function IsClone(unit)
	return unit:HasModifier('modifier_arc_warden_tempest_double') or Fu.IsMeepoClone(unit)
end

-- Visible enemy hero handle for a player ID (nil when in the fog).
local function GetVisibleEnemy(pid)
	for _, enemy in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES) or {}) do
		if enemy ~= nil and not enemy:IsNull() and enemy:IsAlive() and enemy:CanBeSeen()
		and enemy:GetPlayerID() == pid and not Fu.IsSuspiciousIllusion(enemy) then
			return enemy
		end
	end
	return nil
end

-- Where the enemy is (or was last seen) and how long ago.
local function GetEnemyLocation(pid)
	local enemy = GetVisibleEnemy(pid)
	if enemy ~= nil then return enemy:GetLocation(), 0, enemy end
	local info = GetHeroLastSeenInfo(pid)
	if info ~= nil and info[1] ~= nil and info[1].location ~= nil then
		return info[1].location, info[1].time_since_seen or 99, nil
	end
	return nil, 99, nil
end

-- Enemy heroes (other than the target) seen near a location in the last few seconds.
local function CountEnemyHelpers(targetPid, loc)
	local n = 0
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if pid ~= targetPid and IsHeroAlive(pid) then
			local eLoc, seenAgo = GetEnemyLocation(pid)
			if eLoc ~= nil and seenAgo <= 5.0 and Fu.GetLocationToLocationDistance(eLoc, loc) <= ISOLATION_RADIUS then
				n = n + 1
			end
		end
	end
	return n
end

local function IsNearEnemyTower(loc)
	local enemyTeam = GetOpposingTeam()
	local towers = {
		TOWER_TOP_1, TOWER_TOP_2, TOWER_TOP_3, TOWER_MID_1, TOWER_MID_2, TOWER_MID_3,
		TOWER_BOT_1, TOWER_BOT_2, TOWER_BOT_3, TOWER_BASE_1, TOWER_BASE_2,
	}
	for _, id in ipairs(towers) do
		local tower = GetTower(enemyTeam, id)
		if tower ~= nil and tower:IsAlive() and Fu.GetLocationToLocationDistance(tower:GetLocation(), loc) <= TOWER_SAFE_DIST then
			return true
		end
	end
	local ancient = GetAncient(enemyTeam)
	if ancient ~= nil and Fu.GetLocationToLocationDistance(ancient:GetLocation(), loc) <= 4000 then
		return true
	end
	return false
end

-- Allied bots that can join, closest first. The same list comes out in every bot's script.
local function GetHunters(targetLoc)
	local list = {}
	for _, ally in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES) or {}) do
		if ally ~= nil and not ally:IsNull() and ally:IsAlive() and not ally:IsIllusion()
		and not IsClone(ally) and IsPlayerBot(ally:GetPlayerID())
		and ally:GetLevel() >= 6
		and ally:GetHealth() / math.max(1, ally:GetMaxHealth()) >= MIN_HP_START
		and ally:GetActiveMode() ~= BOT_MODE_RETREAT
		and ally:GetActiveMode() ~= BOT_MODE_ROSHAN
		then
			local dist = GetUnitToLocationDistance(ally, targetLoc)
			if dist <= MAX_GATHER_DIST then
				table.insert(list, { unit = ally, dist = dist, pid = ally:GetPlayerID() })
			end
		end
	end
	table.sort(list, function(a, b)
		if math.abs(a.dist - b.dist) > 1 then return a.dist < b.dist end
		return a.pid < b.pid
	end)
	while #list > MAX_HUNTERS do table.remove(list) end
	return list
end

-- The enemy's carry: estimated position 1 first, then position 2.
local function GetTargetCandidates()
	EnemyRoles.UpdateEnemyHeroPositions()
	local byPos = {}
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		local pos = EnemyRoles.GetEnemyPosition(pid)
		if pos ~= nil and pos <= 2 and IsHeroAlive(pid) then
			table.insert(byPos, { pid = pid, pos = pos })
		end
	end
	table.sort(byPos, function(a, b) return a.pos < b.pos end)
	return byPos
end

local function IsDefenseNeeded()
	return math.max(GetDefendLaneDesire(LANE_TOP), GetDefendLaneDesire(LANE_MID), GetDefendLaneDesire(LANE_BOT)) > 0.55
end

local function StopHunt(bot, reason)
	local h = bot._smartHunt
	if h ~= nil and h.active then
		h.active = false
		h.cooldownUntil = DotaTime() + HUNT_COOLDOWN
		if h.leader then
			print(string.format('[HUNT %s] stop hunting %s: %s', Clock(DotaTime()), ShortName(h.targetName), reason))
		end
	end
end

local function TryStartHunt(bot, h)
	if Fu.IsInLaningPhase() or DotaTime() < 8 * 60 then return false end
	if bot:GetLevel() < 6 or Fu.GetHP(bot) < MIN_HP_START or IsClone(bot) then return false end
	if DotaTime() < (h.cooldownUntil or 0) then return false end
	if IsDefenseNeeded() then return false end
	if Fu.IsDoingRoshan(bot) or Fu.IsDoingTormentor(bot) then return false end

	for _, cand in ipairs(GetTargetCandidates()) do
		local loc, seenAgo, unit = GetEnemyLocation(cand.pid)
		if loc ~= nil and seenAgo <= LAST_SEEN_START and not IsNearEnemyTower(loc) then
			local helpers = CountEnemyHelpers(cand.pid, loc)
			local hunters = GetHunters(loc)
			local targetLow = unit ~= nil and Fu.GetHP(unit) < 0.45
			local need = math.max(targetLow and 2 or MIN_HUNTERS, helpers + 2)
			if helpers <= 1 and #hunters >= need then
				local isHunter, isLeader = false, false
				for i, entry in ipairs(hunters) do
					if entry.unit == bot then
						isHunter = true
						isLeader = (i == 1)
					end
				end
				if isHunter then
					h.active = true
					h.pid = cand.pid
					h.targetName = unit and unit:GetUnitName() or GetSelectedHeroName(cand.pid)
					h.startTime = DotaTime()
					h.lastLoc = loc
					h.unit = unit
					h.leader = isLeader
					if isLeader then
						local names = {}
						for _, entry in ipairs(hunters) do table.insert(names, ShortName(entry.unit:GetUnitName())) end
						print(string.format('[HUNT %s] %s go after %s (pos %d, %d enemies near him)',
							Clock(DotaTime()), table.concat(names, ', '), ShortName(h.targetName), cand.pos, helpers))
					end
					return true
				end
				return false -- someone else's hunt; this bot keeps doing its job
			end
		end
	end
	return false
end

local function KeepHunting(bot, h)
	if DotaTime() - h.startTime > MAX_HUNT_TIME then StopHunt(bot, 'took too long') return false end
	if Fu.GetHP(bot) < MIN_HP_KEEP then StopHunt(bot, 'low HP') return false end
	if not IsHeroAlive(h.pid) then StopHunt(bot, 'target dead') return false end
	if IsDefenseNeeded() then StopHunt(bot, 'base needs defending') return false end

	local loc, seenAgo, unit = GetEnemyLocation(h.pid)
	if loc == nil or seenAgo > LAST_SEEN_KEEP then StopHunt(bot, 'lost him in the fog') return false end
	h.lastLoc = loc
	h.unit = unit

	local targetLow = unit ~= nil and Fu.GetHP(unit) < 0.25
	if IsNearEnemyTower(loc) and not targetLow then StopHunt(bot, 'he ran under a tower') return false end

	-- Do not fight a losing battle: allies on the way (not retreating, within gathering range)
	-- must outnumber the enemies around him. The first seconds are for gathering.
	if DotaTime() - h.startTime > 4 then
		local helpers = CountEnemyHelpers(h.pid, loc)
		local allies = 0
		for _, ally in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES) or {}) do
			if ally ~= nil and ally:IsAlive() and not ally:IsIllusion()
			and ally:GetActiveMode() ~= BOT_MODE_RETREAT
			and GetUnitToLocationDistance(ally, loc) <= MAX_GATHER_DIST then
				allies = allies + 1
			end
		end
		if allies < helpers + 2 then StopHunt(bot, 'too many enemies came') return false end
	end
	return true
end

function X.GetDesire(bot)
	local h = bot._smartHunt
	if h == nil then
		h = { active = false, cooldownUntil = 0 }
		bot._smartHunt = h
	end
	if not bot:IsAlive() then
		if h.active then StopHunt(bot, 'I died') end
		return 0
	end

	if h.active then
		if not KeepHunting(bot, h) then return 0 end
	elseif not TryStartHunt(bot, h) then
		return 0
	end

	if h.unit ~= nil then bot:SetTarget(h.unit) end
	if GetUnitToLocationDistance(bot, h.lastLoc) <= 1600 then return DESIRE_NEAR end
	return DESIRE_FAR
end

function X.IsHunting(bot)
	return bot._smartHunt ~= nil and bot._smartHunt.active
end

function X.Think(bot)
	local h = bot._smartHunt
	if h == nil or not h.active then return false end
	local unit = h.unit
	if unit ~= nil and not unit:IsNull() and unit:IsAlive() and unit:CanBeSeen() and Fu.CanBeAttacked(unit) then
		bot:SetTarget(unit)
		bot:Action_AttackUnit(unit, false)
		return true
	end
	if h.lastLoc ~= nil then
		bot:Action_MoveToLocation(h.lastLoc)
		return true
	end
	return false
end

return X
