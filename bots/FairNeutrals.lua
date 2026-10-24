--[[
Smart Bots (HATS) - fair neutral items for bots.

Valve does not let bots craft neutral items, so without help they never get one.
This server script crafts them for bots by the same rules a player follows, and
gives nothing else (no gold, experience, stats or early items):

  * Bots earn Madstone only by killing neutral creeps (and get a share when an
    ally clears a camp), starting from minute 5, limited by the same time caps
    as players.
  * A tier is crafted only when it is unlocked by game time AND the bot has
    collected enough Madstone for it.
  * Like a player, the bot sees 3 random artifacts and 3 random enchantments of
    that tier and picks the ones that suit its role and attack type.

Madstone per camp is approximated per creep, because the script sees creep
kills, not camp clears.

How to start (once per game, during hero selection or later):
  lobby with "Enable Cheats" checked, then in the console:
    sv_cheats 1; script_reload_code bots/FairNeutrals
--]]

-- Always print (the shared log() only prints in debug mode).
local function report(fmt, ...) print(string.format(fmt, ...)) end

if not GameRules or GameRules:State_Get() < DOTA_GAMERULES_STATE_HERO_SELECTION then
	report('[FairNeutrals] Start a lobby game and run this after entering hero selection.')
	return
end

if FairNeutrals ~= nil and FairNeutrals.started then
	report('[FairNeutrals] Already running for this game.')
	return
end

local Pool = require('bots.FuncLib.data.neutral_items')

FairNeutrals = { started = true }

-- Tier unlock times and Madstone needed, in minutes of game time (regular / turbo).
-- Madstone values are cumulative totals, same as the player's caps.
local TIER_UNLOCK_MIN       = { 5, 15, 25, 35, 60 }
local TIER_UNLOCK_MIN_TURBO = { 2.5, 7.5, 12.5, 17.5, 30 }
local TIER_MADSTONE_TOTAL   = { 5, 15, 25, 35, 45 }
local MADSTONE_START_MIN       = 5
local MADSTONE_START_MIN_TURBO = 2.5

-- Madstone per creep killed. A regular camp gives the killer 2 and a random ally 1,
-- an ancient camp 3 and 2; camps have about three creeps.
local MADSTONE_KILLER_REGULAR = 0.7
local MADSTONE_ALLY_REGULAR   = 0.35
local MADSTONE_KILLER_ANCIENT = 1.0
local MADSTONE_ALLY_ANCIENT   = 0.7

local OPTIONS_PER_CRAFT = 3
local NEUTRAL_SLOT = 16
local THINK_INTERVAL = 1.0

local bots = {}      -- playerID -> { hero, madstone, tier }
local isTurbo = nil

local function IsTurbo()
	if isTurbo ~= nil then return isTurbo end
	local courier = Entities:FindByName(nil, 'npc_dota_courier')
	if courier == nil then return false end
	isTurbo = courier:GetMoveSpeedModifier(courier:GetBaseMoveSpeed(), true) == 1100
	return isTurbo
end

local function GameMinutes()
	return GameRules:GetDOTATime(false, false) / 60
end

local function UnlockedTier(minutes)
	local unlock = IsTurbo() and TIER_UNLOCK_MIN_TURBO or TIER_UNLOCK_MIN
	local tier = 0
	for t = 1, #unlock do
		if minutes >= unlock[t] then tier = t end
	end
	return tier
end

-- Most Madstone a hero can hold at this time (excess is lost, like for players).
local function MadstoneCap(minutes)
	local tier = UnlockedTier(minutes)
	if tier == 0 then return 0 end
	if minutes >= (IsTurbo() and 35 or 70) then return math.huge end
	return TIER_MADSTONE_TOTAL[tier]
end

local function RegisterBots()
	for team = DOTA_TEAM_GOODGUYS, DOTA_TEAM_BADGUYS do
		for i = 0, PlayerResource:GetPlayerCountForTeam(team) - 1 do
			local pid = PlayerResource:GetNthPlayerIDOnTeam(team, i)
			if pid and pid >= 0 and PlayerResource:IsFakeClient(pid) and bots[pid] == nil then
				local hero = PlayerResource:GetSelectedHeroEntity(pid)
				if hero then
					bots[pid] = { hero = hero, madstone = 0, tier = 0 }
				end
			end
		end
	end
end

local function AddMadstone(pid, amount)
	local b = bots[pid]
	if b == nil then return end
	local minutes = GameMinutes()
	local cap = MadstoneCap(minutes)
	b.madstone = math.min(b.madstone + amount, cap)
end

-- Estimated position 1..5 inside the team: richest hero = 1, poorest = 5.
local function EstimatePosition(pid)
	local team = PlayerResource:GetTeam(pid)
	local myWorth = PlayerResource:GetNetWorth(pid)
	local pos = 1
	for i = 0, PlayerResource:GetPlayerCountForTeam(team) - 1 do
		local other = PlayerResource:GetNthPlayerIDOnTeam(team, i)
		if other and other >= 0 and other ~= pid and PlayerResource:GetNetWorth(other) > myWorth then
			pos = pos + 1
		end
	end
	return math.min(pos, 5)
end

local function PickRandom(list, count)
	local copy = {}
	for i = 1, #list do copy[i] = list[i] end
	local picked = {}
	while #picked < count and #copy > 0 do
		local idx = RandomInt(1, #copy)
		table.insert(picked, copy[idx])
		table.remove(copy, idx)
	end
	return picked
end

local function BestOption(options, pos, isRanged)
	local best, bestScore = nil, -math.huge
	for _, item in ipairs(options) do
		local score = (item.roles and item.roles[pos]) or 1
		if item.ranged ~= nil and item.melee ~= nil then
			score = score * (isRanged and item.ranged or item.melee)
		end
		score = score + RandomFloat(0, 0.5) -- small tie breaker
		if score > bestScore then best, bestScore = item, score end
	end
	return best
end

local function ItemsOfTier(list, tier)
	local result = {}
	for _, item in ipairs(list) do
		if item.tier == tier then table.insert(result, item) end
	end
	return result
end

local function RemoveCurrentNeutral(hero)
	local current = hero:GetItemInSlot(NEUTRAL_SLOT)
	if current then hero:RemoveItem(current) end
	for slot = 0, 20 do
		local item = hero:GetItemInSlot(slot)
		if item and string.find(item:GetName(), 'item_enhancement') then
			hero:RemoveItem(item)
			return
		end
	end
end

local function GiveItem(hero, name)
	local item = CreateItem(name, hero, hero)
	if item == nil then return false end
	item:SetPurchaseTime(0)
	hero:AddItem(item)
	return true
end

local function Craft(pid, tier)
	local b = bots[pid]
	local hero = b.hero
	local pos = EstimatePosition(pid)
	local isRanged = hero:GetAttackCapability() == DOTA_UNIT_CAP_RANGED_ATTACK

	local artifact = BestOption(PickRandom(ItemsOfTier(Pool.items, tier), OPTIONS_PER_CRAFT), pos, isRanged)
	local enchant = BestOption(PickRandom(ItemsOfTier(Pool.enhancements, tier), OPTIONS_PER_CRAFT), pos, isRanged)
	if artifact == nil then
		b.tier = tier -- nothing in the pool for this tier; skip it
		return
	end

	RemoveCurrentNeutral(hero)
	GiveItem(hero, artifact.name)
	if enchant then GiveItem(hero, enchant.name) end
	b.tier = tier
	report('[FairNeutrals] %s (pos %d) crafted tier %d: %s + %s at %.1f min, madstone %.1f',
		hero:GetUnitName(), pos, tier, artifact.name, enchant and enchant.name or '-', GameMinutes(), b.madstone)
end

function FairNeutrals:OnEntityKilled(event)
	local victim = event.entindex_killed and EntIndexToHScript(event.entindex_killed)
	local attacker = event.entindex_attacker and EntIndexToHScript(event.entindex_attacker)
	if victim == nil or attacker == nil then return end
	if victim:GetTeamNumber() ~= DOTA_TEAM_NEUTRALS then return end
	if not (victim.IsNeutralUnitType and victim:IsNeutralUnitType()) then return end
	local victimName = victim:GetUnitName() or ''
	if string.find(victimName, 'roshan') or string.find(victimName, 'miniboss') then return end -- Roshan, Tormentor

	local minutes = GameMinutes()
	if minutes < (IsTurbo() and MADSTONE_START_MIN_TURBO or MADSTONE_START_MIN) then return end

	local killerPid = attacker.GetPlayerOwnerID and attacker:GetPlayerOwnerID() or -1
	if killerPid == nil or killerPid < 0 then return end

	local ancient = victim.IsAncient and victim:IsAncient()
	AddMadstone(killerPid, ancient and MADSTONE_KILLER_ANCIENT or MADSTONE_KILLER_REGULAR)

	-- Share for one random ally of the killer
	local team = PlayerResource:GetTeam(killerPid)
	local allies = {}
	for i = 0, PlayerResource:GetPlayerCountForTeam(team) - 1 do
		local pid = PlayerResource:GetNthPlayerIDOnTeam(team, i)
		if pid and pid >= 0 and pid ~= killerPid then table.insert(allies, pid) end
	end
	if #allies > 0 then
		AddMadstone(allies[RandomInt(1, #allies)], ancient and MADSTONE_ALLY_ANCIENT or MADSTONE_ALLY_REGULAR)
	end
end

function FairNeutrals:Think()
	local state = GameRules:State_Get()
	if state >= DOTA_GAMERULES_STATE_POST_GAME then return nil end
	if state < DOTA_GAMERULES_STATE_PRE_GAME then return THINK_INTERVAL end

	RegisterBots()
	local unlocked = UnlockedTier(GameMinutes())
	for pid, b in pairs(bots) do
		local nextTier = b.tier + 1
		if nextTier <= unlocked and nextTier <= #TIER_MADSTONE_TOTAL
			and b.madstone >= TIER_MADSTONE_TOTAL[nextTier]
			and b.hero and not b.hero:IsNull() and b.hero:IsAlive() then
			Craft(pid, nextTier)
		end
	end
	return THINK_INTERVAL
end

ListenToGameEvent('entity_killed', Dynamic_Wrap(FairNeutrals, 'OnEntityKilled'), FairNeutrals)
local thinker = SpawnEntityFromTableSynchronous('info_target', { targetname = 'smart_bots_fair_neutrals' })
thinker:SetThink('Think', FairNeutrals, 'fair_neutrals', THINK_INTERVAL)

GameRules:SendCustomMessage('Smart Bots: fair neutral items enabled. Bots craft neutrals by the same rules as players.', 0, 0)
report('[FairNeutrals] Started.')
