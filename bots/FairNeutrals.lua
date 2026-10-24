--[[
Smart Bots (HATS) - neutral items for bots.

Valve does not let bots craft neutral items, so without help they never get one.
This server script gives every bot a neutral item as soon as each tier becomes
available (5 / 15 / 25 / 35 / 60 min, Turbo twice as fast), with a small random
delay of up to 45 seconds so not everyone gets it in the same second. It gives
nothing else (no gold, experience or stats).

Like a player, the bot sees 3 random artifacts and 3 random enchantments of the
tier and picks the ones that suit its role and attack type.

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

-- Tier unlock times in minutes of game time (regular / turbo).
local TIER_UNLOCK_MIN       = { 5, 15, 25, 35, 60 }
local TIER_UNLOCK_MIN_TURBO = { 2.5, 7.5, 12.5, 17.5, 30 }
local MAX_DELAY_SEC = 45 -- random per bot and tier (halved in Turbo)

local OPTIONS_PER_CRAFT = 3
local NEUTRAL_SLOT = 16
local THINK_INTERVAL = 1.0

local bots = {}      -- playerID -> { hero, tier, readyAt }
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

local function RegisterBots()
	for team = DOTA_TEAM_GOODGUYS, DOTA_TEAM_BADGUYS do
		for i = 0, PlayerResource:GetPlayerCountForTeam(team) - 1 do
			local pid = PlayerResource:GetNthPlayerIDOnTeam(team, i)
			if pid and pid >= 0 and PlayerResource:IsFakeClient(pid) and bots[pid] == nil then
				local hero = PlayerResource:GetSelectedHeroEntity(pid)
				if hero then
					bots[pid] = { hero = hero, tier = 0, readyAt = nil }
				end
			end
		end
	end
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
	report('[FairNeutrals] %s (pos %d) got tier %d: %s + %s at %.1f min',
		hero:GetUnitName(), pos, tier, artifact.name, enchant and enchant.name or '-', GameMinutes())
end

function FairNeutrals:Think()
	local state = GameRules:State_Get()
	if state >= DOTA_GAMERULES_STATE_POST_GAME then return nil end
	if state < DOTA_GAMERULES_STATE_PRE_GAME then return THINK_INTERVAL end

	RegisterBots()
	local minutes = GameMinutes()
	local unlocked = UnlockedTier(minutes)
	for pid, b in pairs(bots) do
		local nextTier = b.tier + 1
		if nextTier <= unlocked and nextTier <= #TIER_UNLOCK_MIN then
			if b.readyAt == nil then
				local maxDelay = IsTurbo() and MAX_DELAY_SEC / 2 or MAX_DELAY_SEC
				b.readyAt = minutes + RandomFloat(0, maxDelay) / 60
			end
			if minutes >= b.readyAt and b.hero and not b.hero:IsNull() and b.hero:IsAlive() then
				Craft(pid, nextTier)
				b.readyAt = nil
			end
		end
	end
	return THINK_INTERVAL
end

local thinker = SpawnEntityFromTableSynchronous('info_target', { targetname = 'smart_bots_fair_neutrals' })
thinker:SetThink('Think', FairNeutrals, 'fair_neutrals', THINK_INTERVAL)

GameRules:SendCustomMessage('Smart Bots: neutral items enabled. Bots get each tier when it unlocks.', 0, 0)
report('[FairNeutrals] Started.')
