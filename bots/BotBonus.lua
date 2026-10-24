--[[
Smart Bots (HATS) - optional small bonus for bots.

Every bot gets an extra 15% of the gold and experience it earned itself
(last hits, kills, passive gold, everything). Nothing else: no stats, no items,
no free levels. Humans get nothing.

The bonus is a share of what the bot really earned, so a bot that farms well gets
more and a bot that stands idle gets nothing.

How to start (once per game, during hero selection or later):
  lobby with "Enable Cheats" checked, then in the console:
    sv_cheats 1; script_reload_code bots/BotBonus
  Together with the neutral items:
    sv_cheats 1; script_reload_code bots/FairNeutrals; script_reload_code bots/BotBonus
--]]

local BONUS_SHARE = 0.15     -- 15% of the gold and experience the bot earned
local THINK_INTERVAL = 1.0   -- seconds
local REPORT_EVERY_MIN = 10  -- console summary interval

-- Always print (the shared log() only prints in debug mode).
local function report(fmt, ...) print(string.format(fmt, ...)) end

if not GameRules or GameRules:State_Get() < DOTA_GAMERULES_STATE_HERO_SELECTION then
	report('[BotBonus] Start a lobby game and run this after entering hero selection.')
	return
end

if BotBonus ~= nil and BotBonus.started then
	report('[BotBonus] Already running for this game.')
	return
end

BotBonus = { started = true }

-- playerID -> { gold = natural gold already paid on, xp = ..., ownGold = part of the
-- earned counter that came from this script, ownXp = ..., gaveGold, gaveXp, rest... }
local bots = {}
local nextReportMin = REPORT_EVERY_MIN

local function GameMinutes()
	return GameRules:GetDOTATime(false, false) / 60
end

local function Read(fn)
	local ok, v = pcall(fn)
	if ok and type(v) == 'number' then return v end
	return nil
end

local function RegisterBots()
	for team = DOTA_TEAM_GOODGUYS, DOTA_TEAM_BADGUYS do
		for i = 0, PlayerResource:GetPlayerCountForTeam(team) - 1 do
			local pid = PlayerResource:GetNthPlayerIDOnTeam(team, i)
			if pid and pid >= 0 and PlayerResource:IsFakeClient(pid) and bots[pid] == nil then
				local hero = PlayerResource:GetSelectedHeroEntity(pid)
				if hero then
					-- Pay only on income from now on (no lump sum when started late in the game).
					local startGold = Read(function() return PlayerResource:GetTotalEarnedGold(pid) end) or 0
					local startXp = Read(function() return PlayerResource:GetTotalEarnedXP(pid) end) or 0
					bots[pid] = {
						hero = hero,
						paidGold = startGold, paidXp = startXp, -- natural income the bonus was already paid on
						ownGold = 0, ownXp = 0,     -- bonus that the game counted as "earned"
						restGold = 0, restXp = 0,   -- fractions carried to the next tick
						gaveGold = 0, gaveXp = 0,   -- totals for the report
					}
				end
			end
		end
	end
end

local function PayGold(pid, b)
	local total = Read(function() return PlayerResource:GetTotalEarnedGold(pid) end)
	if total == nil then return false end
	local natural = total - b.ownGold
	local delta = natural - b.paidGold
	if delta <= 0 then return true end
	b.paidGold = natural
	local amount = delta * BONUS_SHARE + b.restGold
	local whole = math.floor(amount)
	b.restGold = amount - whole
	if whole > 0 then
		PlayerResource:ModifyGold(pid, whole, false, 0)
		-- If the game counts this as earned gold, remember it so we never pay a bonus on the bonus.
		local after = Read(function() return PlayerResource:GetTotalEarnedGold(pid) end)
		if after ~= nil and after > total then b.ownGold = b.ownGold + (after - total) end
		b.gaveGold = b.gaveGold + whole
	end
	return true
end

local function PayXp(pid, b)
	local hero = b.hero
	if hero == nil or hero:IsNull() then return false end
	local total = Read(function() return PlayerResource:GetTotalEarnedXP(pid) end)
	if total == nil then return false end
	local natural = total - b.ownXp
	local delta = natural - b.paidXp
	if delta <= 0 then return true end
	b.paidXp = natural
	if hero:GetLevel() >= 30 then return true end
	local amount = delta * BONUS_SHARE + b.restXp
	local whole = math.floor(amount)
	b.restXp = amount - whole
	if whole > 0 then
		hero:AddExperience(whole, 0, false, true)
		local after = Read(function() return PlayerResource:GetTotalEarnedXP(pid) end)
		if after ~= nil and after > total then b.ownXp = b.ownXp + (after - total) end
		b.gaveXp = b.gaveXp + whole
	end
	return true
end

local warned = false

function BotBonus:Think()
	local state = GameRules:State_Get()
	if state >= DOTA_GAMERULES_STATE_POST_GAME then return nil end
	if state < DOTA_GAMERULES_STATE_PRE_GAME then return THINK_INTERVAL end

	RegisterBots()
	for pid, b in pairs(bots) do
		local okGold = PayGold(pid, b)
		local okXp = PayXp(pid, b)
		if (not okGold or not okXp) and not warned then
			warned = true
			report('[BotBonus] Could not read earned gold/experience for player %d; bonus may be partial.', pid)
		end
	end

	local minutes = GameMinutes()
	if minutes >= nextReportMin then
		nextReportMin = nextReportMin + REPORT_EVERY_MIN
		for _, b in pairs(bots) do
			if b.hero and not b.hero:IsNull() then
				report('[BotBonus %d:00] %s: bonus gold %d, bonus experience %d',
					math.floor(minutes), (string.gsub(b.hero:GetUnitName(), 'npc_dota_hero_', '')), b.gaveGold, b.gaveXp)
			end
		end
	end
	return THINK_INTERVAL
end

local thinker = SpawnEntityFromTableSynchronous('info_target', { targetname = 'smart_bots_bot_bonus' })
thinker:SetThink('Think', BotBonus, 'bot_bonus', THINK_INTERVAL)

GameRules:SendCustomMessage(string.format('Smart Bots: bot bonus enabled (+%d%% gold and experience).', math.floor(BONUS_SHARE * 100 + 0.5)), 0, 0)
report('[BotBonus] Started: bots get +%d%% of the gold and experience they earn.', math.floor(BONUS_SHARE * 100 + 0.5))
