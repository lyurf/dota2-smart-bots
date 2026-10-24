--[[
Smart Bots (HATS) - console reports for test games.

Prints to the console (always, not only in debug mode):
  [DEATH] every time a bot dies: game time, position, the mode it was in, HP a few
          seconds before, how many enemies and allies were near, and where it died.
  [GAME mm:00] at 15 / 20 / 25 / 30 / 40 / 50 min for every bot: last hits, denies,
          kills / deaths / assists, net worth, level and the share of time spent in each
          mode since the previous report (farm, push, attack, retreat...).

These lines make it possible to compare test games and see why bots die or farm poorly.
Call X.Update(bot) from a function that runs every frame for every bot.
--]]

local X = {}

local REPORT_MINUTES = { 15, 20, 25, 30, 40, 50 }
local SAMPLE_INTERVAL = 0.5 -- seconds between snapshots

local ModeNames = nil
local function ModeName(mode)
	if ModeNames == nil then
		ModeNames = {}
		local names = {
			'NONE', 'LANING', 'ATTACK', 'ROAM', 'RETREAT', 'SECRET_SHOP', 'SIDE_SHOP', 'RUNE',
			'PUSH_TOWER_TOP', 'PUSH_TOWER_MID', 'PUSH_TOWER_BOT',
			'DEFEND_TOWER_TOP', 'DEFEND_TOWER_MID', 'DEFEND_TOWER_BOT',
			'ASSEMBLE', 'ASSEMBLE_WITH_HUMANS', 'TEAM_ROAM', 'FARM', 'DEFEND_ALLY',
			'EVASIVE_MANEUVERS', 'ROSHAN', 'ITEM', 'WARD', 'OUTPOST', 'TORMENTOR',
		}
		for _, name in ipairs(names) do
			local value = _G['BOT_MODE_'..name]
			if value ~= nil then ModeNames[value] = string.lower(name) end
		end
	end
	return ModeNames[mode] or tostring(mode)
end

-- Groups for the time-share line (push/defend lanes merged).
local function ModeGroup(mode)
	local name = ModeName(mode)
	if string.find(name, 'push_tower', 1, true) then return 'push' end
	if string.find(name, 'defend_tower', 1, true) then return 'defend' end
	if name == 'secret_shop' or name == 'side_shop' or name == 'item' or name == 'outpost' then return 'shop/item' end
	return name
end

local function Clock(t)
	local sign = t < 0 and '-' or ''
	t = math.abs(t)
	return string.format('%s%d:%02d', sign, math.floor(t / 60), math.floor(t % 60))
end

local function ShortName(bot)
	return (string.gsub(bot:GetUnitName(), 'npc_dota_hero_', ''))
end

local function CountHeroes(bot, bEnemy, radius)
	local ok, list = pcall(function() return bot:GetNearbyHeroes(radius, bEnemy, BOT_MODE_NONE) end)
	if not ok or list == nil then return 0 end
	local n = 0
	for _, h in pairs(list) do
		-- IsIllusion() only works on teammates (on enemies it spams the console), so enemies are counted as is
		if h ~= nil and (bEnemy or not h:IsIllusion()) then n = n + 1 end
	end
	return n
end

local function Where(bot)
	local loc = bot:GetLocation()
	local ownFountain = GetTeam() == TEAM_RADIANT and Vector(-7000, -6500, 0) or Vector(7000, 6500, 0)
	local enemyFountain = GetTeam() == TEAM_RADIANT and Vector(7000, 6500, 0) or Vector(-7000, -6500, 0)
	local dOwn = (loc - ownFountain):Length2D()
	local dEnemy = (loc - enemyFountain):Length2D()
	local side = dOwn < dEnemy and 'our half' or 'enemy half'
	return string.format('%s (%d, %d)', side, math.floor(loc.x), math.floor(loc.y))
end

local function Stat(fn)
	local ok, v = pcall(fn)
	if ok and v ~= nil then return tostring(v) end
	return '?'
end

function X.Update(bot, position)
	if bot == nil or not bot:IsHero() or bot:IsIllusion() then return end
	local ok, err = pcall(function()
		local now = DotaTime()
		local s = bot._smartReport
		if s == nil then
			s = { nextSample = 0, alive = true, history = {}, modeTime = {}, totalTime = 0, reported = {} }
			bot._smartReport = s
		end

		-- Death counter as a backup, in case this is not called while the bot is dead.
		local okD, deaths = pcall(function() return GetHeroDeaths(bot:GetPlayerID()) end)
		if not okD then deaths = nil end
		local missedDeath = deaths ~= nil and s.deaths ~= nil and deaths > s.deaths and s.alive
		if deaths ~= nil then s.deaths = deaths end

		if bot:IsAlive() and not missedDeath then
			if now >= s.nextSample then
				s.nextSample = now + SAMPLE_INTERVAL
				-- keep about 8 seconds of history for the death report
				table.insert(s.history, {
					time = now,
					hp = bot:GetHealth() / math.max(1, bot:GetMaxHealth()),
					mode = bot:GetActiveMode(),
					enemies = CountHeroes(bot, true, 1200),
					allies = CountHeroes(bot, false, 1200),
				})
				while #s.history > 16 do table.remove(s.history, 1) end
				if now > 0 then
					local group = ModeGroup(bot:GetActiveMode())
					s.modeTime[group] = (s.modeTime[group] or 0) + SAMPLE_INTERVAL
					s.totalTime = s.totalTime + SAMPLE_INTERVAL
				end
			end
			s.alive = true
		elseif s.alive then
			s.alive = bot:IsAlive() -- false, or true again when the death was only seen by the counter
			local last = s.history[#s.history]
			local before = s.history[1]
			local modes = {}
			local seen = {}
			for i = #s.history, 1, -1 do
				local name = ModeName(s.history[i].mode)
				if not seen[name] then seen[name] = true table.insert(modes, name) end
			end
			print(string.format('[DEATH %s] %s pos %s (level %d): modes before death %s, HP %d%% %.0fs before, enemies near %d, allies near %d, %s',
				Clock(now), ShortName(bot), tostring(position or '?'), bot:GetLevel(),
				#modes > 0 and table.concat(modes, ' <- ') or '?',
				before and math.floor(before.hp * 100) or -1,
				before and (now - before.time) or 0,
				last and last.enemies or -1, last and last.allies or -1,
				Where(bot)))
			s.history = {}
		end

		for _, minute in ipairs(REPORT_MINUTES) do
			if now >= minute * 60 and not s.reported[minute] then
				s.reported[minute] = true
				local pid = bot:GetPlayerID()
				local shares = {}
				for group, t in pairs(s.modeTime) do
					if s.totalTime > 0 and t / s.totalTime >= 0.03 then
						table.insert(shares, { group = group, share = t / s.totalTime })
					end
				end
				table.sort(shares, function(a, b) return a.share > b.share end)
				local parts = {}
				for _, e in ipairs(shares) do
					table.insert(parts, string.format('%s %d%%', e.group, math.floor(e.share * 100 + 0.5)))
				end
				print(string.format('[GAME %d:00] %s pos %s: LH %s / DN %s, K/D/A %s/%s/%s, nw %d, level %d, time: %s',
					minute, ShortName(bot), tostring(position or '?'),
					Stat(function() return bot:GetLastHits() end), Stat(function() return bot:GetDenies() end),
					Stat(function() return GetHeroKills(pid) end), Stat(function() return GetHeroDeaths(pid) end),
					Stat(function() return GetHeroAssists(pid) end),
					bot:GetNetWorth(), bot:GetLevel(), #parts > 0 and table.concat(parts, ', ') or '?'))
				s.modeTime = {}
				s.totalTime = 0
			end
		end
	end)
	if not ok and IsDebug then print('[match_report] '..tostring(err)) end
end

return X
