local X = {}
local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not string.find(botName, "hero") or bot:IsIllusion() then return end
if not bot.frameProcessTime then bot.frameProcessTime = 0.1 end

local team = GetTeam()
local bDebugMode = ( 10 == 10 )

local Fu = require( GetScriptDirectory()..'/FuncLib/func_utils' )
local Utils = require( GetScriptDirectory()..'/FuncLib/systems/utils' )
local BotBuild = dofile( GetScriptDirectory().."/BotsLib/"..string.gsub( botName, "npc_dota_", "" ) )
local Localization = require( GetScriptDirectory()..'/FuncLib/systems/localization' )
local Customize = require(GetScriptDirectory()..'/FuncLib/systems/custom_loader')
Customize.ThinkLess = Customize.Enable and Customize.ThinkLess or 1
local okDispel, Dispel = pcall(require, GetScriptDirectory()..'/FuncLib/systems/dispel')
if not okDispel then Dispel = nil end
if GAMEMODE_TURBO == nil then GAMEMODE_TURBO = 23 end
if GAMEMODE_ARDM == nil then GAMEMODE_ARDM = 20 end

if BotBuild == nil then
	log('[ERROR] BotBuild is nil for %s - hero file failed to load. No items/abilities.', botName)
	return
end

local bDeafaultAbilityHero = BotBuild['bDeafaultAbility']
local bDeafaultItemHero = BotBuild['bDeafaultItem']
local sAbilityLevelUpList = BotBuild['sSkillList']

local RadiantFountain = Vector(-6619, -6336, 384)
local DireFountain = Vector(6928, 6372, 392)

local bNeedARDMReload = false
local nLastKnownPosition = nil  -- tracks bot's position for !pos swap detection

-- Generic bidirectional swap map for heroes with form-switching hidden abilities.
-- When a skill list entry refers to a hidden ability, we level its visible partner instead.
-- Both directions are listed so lookup is O(1) regardless of which form is active.
local tHiddenAbilitySwapMap = {
	-- Kez: Katana (Discipline 1) <-> Sai (Discipline 2)
	['kez_echo_slash']     = 'kez_falcon_rush',
	['kez_falcon_rush']    = 'kez_echo_slash',
	['kez_grappling_claw'] = 'kez_talon_toss',
	['kez_talon_toss']     = 'kez_grappling_claw',
	['kez_kazurai_katana'] = 'kez_shodo_sai',
	['kez_shodo_sai']      = 'kez_kazurai_katana',
	['kez_raptor_dance']   = 'kez_ravens_veil',
	['kez_ravens_veil']    = 'kez_raptor_dance',
}

-- Reload BotBuild for the current hero+role (shared by ARDM swap and !pos swap)
local function ReloadBotBuild(reason)
	local heroFile = string.gsub(botName, "npc_dota_", "")
	log("[Reload] %s for %s, loading BotsLib/%s", reason, botName, heroFile)
	local ok, newBuild = pcall(dofile, GetScriptDirectory().."/BotsLib/"..heroFile)
	if ok and newBuild ~= nil then
		BotBuild = newBuild
		bDeafaultAbilityHero = BotBuild['bDeafaultAbility']
		bDeafaultItemHero = BotBuild['bDeafaultItem']
		if newBuild['sSkillList'] ~= nil and #newBuild['sSkillList'] > 0 then
			local fullList = newBuild['sSkillList']

			-- Strip entries from the front that the bot has already learned.
			-- The bot may have leveled abilities in a different order (old role),
			-- so entries at the front of the new list may reference abilities that
			-- are already at max level or can't be upgraded further.
			local botLevel = bot:GetLevel()
			local nPointsSpent = botLevel - bot:GetAbilityPoints()
			-- Remove the first N entries where N = ability points already spent
			-- This aligns the list with the bot's current level progression
			local trimmed = {}
			for i = nPointsSpent + 1, #fullList do
				table.insert(trimmed, fullList[i])
			end

			if #trimmed > 0 then
				sAbilityLevelUpList = trimmed
			else
				-- All entries consumed, fall back to generic
				sAbilityLevelUpList = Fu.Utils.CombineTablesUnique(
					Fu.Skill.GetTalentList(bot), Fu.Skill.GetAbilityList(bot))
			end
			log("[Reload] Skill list: %s entries remaining (spent %s points)", #sAbilityLevelUpList, nPointsSpent)
		end
	else
		log("[Reload] dofile FAILED for %s: %s", heroFile, newBuild)
	end
end

-- ARDM: Refresh the bot handle and detect stale hero instances.
-- Returns true if this script instance should do NOTHING (stale hero from a past life).
local function RefreshBotHandle()
	local isStale, freshBot, freshName = Fu.IsStaleARDMHero(bot, botName)
	if isStale then
		log("[ARDM] Stale ability script: this=%s, current=%s", botName, freshName)
		return true
	end

	-- Update handle/name if changed (hero swapped in place)
	if freshName ~= botName then
		log("[ARDM] Hero swap detected: %s -> %s", botName, freshName)
		bot = freshBot
		botName = freshName
		bNeedARDMReload = true
	elseif freshBot ~= bot then
		bot = freshBot
	end

	-- Reload BotsLib when hero changed and is alive (abilities initialized)
	if bNeedARDMReload and bot:IsAlive() then
		bNeedARDMReload = false
		local heroFile = string.gsub(botName, "npc_dota_", "")
		log("[ARDM] Loading BotsLib/%s.lua for %s", heroFile, botName)
		local ok, newBuild = pcall(dofile, GetScriptDirectory().."/BotsLib/"..heroFile)
		if not ok then
			log("[ARDM] dofile FAILED for %s: %s", heroFile, newBuild)
		end
		if ok and newBuild ~= nil and newBuild['sSkillList'] ~= nil and #newBuild['sSkillList'] > 0 then
			BotBuild = newBuild
			bDeafaultAbilityHero = BotBuild['bDeafaultAbility']
			bDeafaultItemHero = BotBuild['bDeafaultItem']
			sAbilityLevelUpList = BotBuild['sSkillList']
			log("[ARDM] Loaded BotsLib for %s with %s skill entries, first: %s", botName, #sAbilityLevelUpList, sAbilityLevelUpList[1])
		else
			local abilityList = Fu.Skill.GetAbilityList(bot)
			local talentList = Fu.Skill.GetTalentList(bot)
			log("[ARDM] BotsLib load failed or empty for %s, abilities: %s, talents: %s", botName, #abilityList, #talentList)
			if #abilityList > 0 then
				BotBuild = nil
				bDeafaultAbilityHero = false
				bDeafaultItemHero = false
				sAbilityLevelUpList = Fu.Utils.CombineTablesUnique(talentList, abilityList)
				log("[ARDM] Using generic build for %s with %s entries", botName, #sAbilityLevelUpList)
			else
				log("[ARDM] Abilities not ready for %s, retrying next frame", botName)
				bNeedARDMReload = true
			end
		end
	elseif bNeedARDMReload and not bot:IsAlive() then
		log("[ARDM] Waiting for %s to respawn", botName)
	end

	return false
end

local function AbilityLevelUpComplement()
	if GetGameState() ~= GAME_STATE_PRE_GAME
		and GetGameState() ~= GAME_STATE_GAME_IN_PROGRESS
	then
		return
	end

	if Fu.CanNotUseAbility(bot) then
		return
	end

	-- Single source of truth for "I will play position N" announcement:
	-- on initial detection (bot's first pos) announce during PRE_GAME, and
	-- on any subsequent change announce regardless of state. Previously
	-- mode_laning_generic also had an announce block, which caused
	-- double-announce races and missed late swaps; this path covers both
	-- windows in one place.
	local nCurrentPos = Fu.GetPosition(bot)
	if nLastKnownPosition == nil then
		nLastKnownPosition = nCurrentPos
		if bot.isBear == nil
		   and GetGameMode() ~= GAMEMODE_1V1MID
		   and GetGameState() == GAME_STATE_PRE_GAME
		   and bot.announcedRole ~= nCurrentPos then
			pcall(function()
				bot:ActionImmediate_Chat(Localization.Get('say_play_pos') .. tostring(nCurrentPos), false)
				bot.announcedRole = nCurrentPos
			end)
		end
	elseif nCurrentPos ~= nLastKnownPosition then
		log("[PosSwap] %s position changed: pos%s -> pos%s", botName, nLastKnownPosition, nCurrentPos)
		nLastKnownPosition = nCurrentPos
		ReloadBotBuild("Position swap to pos"..nCurrentPos)
		bot.needPurchaseRebuild = true
		if bot.isBear == nil and bot.announcedRole ~= nCurrentPos then
			pcall(function()
				bot:ActionImmediate_Chat(Localization.Get('say_play_pos') .. tostring(nCurrentPos), false)
				bot.announcedRole = nCurrentPos
			end)
		end
	end

	if bot:GetLevel() >= 30
		and botName == "npc_dota_hero_bloodseeker"
	then
		return
	end

	if DotaTime() < 15
	then
		bot.theRole = Fu.Role.GetCurrentSuitableRole( bot, botName )
	end

	local botLoc = bot:GetLocation()
	if bot:IsAlive()
		and DotaTime() > 90
		and bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO
		and not IsLocationPassable( botLoc )
	then
		if bot.stuckLoc == nil
		then
			bot.stuckLoc = botLoc
			bot.stuckTime = DotaTime()
		elseif bot.stuckLoc ~= botLoc
		then
			bot.stuckLoc = botLoc
			bot.stuckTime = DotaTime()
		end
	else
		bot.stuckTime = nil
		bot.stuckLoc = nil
	end

	if bot.needRefreshAbilitiesFor737 ~= nil and BotBuild ~= nil then
		sAbilityLevelUpList = BotBuild['sSkillList']
		if not bot.needRefreshAbilitiesFor737 then bot.needRefreshAbilitiesFor737 = nil end
	end

	local botLevel = bot:GetLevel()

	if GetGameMode() == GAMEMODE_ARDM and bot:GetAbilityPoints() > 0 then
		if #sAbilityLevelUpList > 0 then
			log("[ARDM] %s Lv%s has %s ability points, skill list has %s entries, next: %s",
				botName, botLevel, bot:GetAbilityPoints(), #sAbilityLevelUpList, sAbilityLevelUpList[1])
		else
			log("[ARDM] %s Lv%s has %s ability points, skill list has %s entries",
				botName, botLevel, bot:GetAbilityPoints(), #sAbilityLevelUpList)
		end
	end

	if #sAbilityLevelUpList >= 1
	and bot:GetAbilityPoints() > 0
	then
		if Fu.IsTryingtoUseAbility(bot) then return end
		local abilityName = sAbilityLevelUpList[1]

		-- Skip nil entries in skill list (can happen with broken talent mappings)
		if abilityName == nil then
			log("[WARN] Nil entry in sAbilityLevelUpList for %s, removing", botName)
			table.remove(sAbilityLevelUpList, 1)
			return
		end

		local abilityToLevelup = bot:GetAbilityByName( abilityName )

		-- ARDM: if the ability doesn't exist on this hero, the skill list may have been
		-- built when the hero was still sleeping/uninitialized. Try to rebuild it.
		if abilityToLevelup == nil and GetGameMode() == GAMEMODE_ARDM then
			local abilityList = Fu.Skill.GetAbilityList(bot)
			local talentList = Fu.Skill.GetTalentList(bot)
			if #abilityList >= 3 then
				log("[ARDM] Ability '%s' not found on %s, rebuilding skill list (abilities: %s, talents: %s)", abilityName, botName, #abilityList, #talentList)
				sAbilityLevelUpList = Fu.Utils.CombineTablesUnique(talentList, abilityList)
				return -- retry with fresh list next frame
			else
				log("[ARDM] Abilities not ready for %s (%s), waiting", botName, #abilityList)
				return
			end
		end

		-- Generic hidden ability swap: if the ability we want to level is hidden,
		-- check the swap map for a visible partner and level that instead.
		-- Works for Kez form-switching and any future heroes with similar mechanics.
		if abilityToLevelup ~= nil and abilityToLevelup:IsHidden() then
			local swapName = tHiddenAbilitySwapMap[abilityName]
			if swapName then
				local swapAbility = bot:GetAbilityByName(swapName)
				if swapAbility ~= nil and not swapAbility:IsHidden() then
					abilityToLevelup = swapAbility
					abilityName = swapName
				end
			end
		end

		-- fix phoenix_fire_spirits can't upgrade bug.
		if abilityName == 'phoenix_fire_spirits' then
			local hLaunchSpirit = bot:GetAbilityByName('phoenix_launch_fire_spirit')
			if hLaunchSpirit ~= nil and not hLaunchSpirit:IsHidden() then
				return
			end
		end

		-- fix 'alchemist_unstable_concoction can't upgrade bug.
		if abilityName == 'alchemist_unstable_concoction' then
			local hConcThrow = bot:GetAbilityByName('alchemist_unstable_concoction_throw')
			if hConcThrow ~= nil and not hConcThrow:IsHidden() then
				return
			end
		end

		-- ARDM: ability doesn't exist on this hero — skip it
		if abilityToLevelup == nil then
			log("[ARDM] Ability %s not found on %s, skipping", abilityName, botName)
			table.remove( sAbilityLevelUpList, 1 )
			return
		end

		if not abilityToLevelup:IsHidden()
		    and botLevel >= abilityToLevelup:GetHeroLevelRequiredToUpgrade()
			and abilityToLevelup:CanAbilityBeUpgraded()
			and abilityToLevelup:GetLevel() < abilityToLevelup:GetMaxLevel()
		then
			bot:ActionImmediate_LevelAbility(abilityToLevelup:GetName())
			table.remove( sAbilityLevelUpList, 1 )
		elseif abilityName == 'generic_hidden' then
			local nextAbility = sAbilityLevelUpList[2]
			log("[WARN] Level up ability %s for %s does not make sense. try to upgrade the next ability: %s", abilityName, botName, nextAbility)
			table.remove( sAbilityLevelUpList, 1 )
			if nextAbility then
				bot:ActionImmediate_LevelAbility(nextAbility)
			end
		elseif not abilityToLevelup:IsHidden() and botLevel >= abilityToLevelup:GetHeroLevelRequiredToUpgrade() then
			-- still try it
			log("[WARN] Level up ability %s for %s may fail because it was called on ability that's not available or can't get upgraded anymore.", abilityName, botName)
			bot:ActionImmediate_LevelAbility(abilityName)
			table.remove( sAbilityLevelUpList, 1 )
		else
			log("[WARN] Skipped to level up ability %s for %s for this time because it may fail.", abilityName, botName)
			if botLevel > 25 then
				log("[WARN] Ignore ability %s for %s because it may always fail.", abilityName, botName)
				table.remove( sAbilityLevelUpList, 1 )
			end
		end
	end

	if botLevel > 25 and botLevel < 30 and bot:GetAbilityPoints() >= 1 and #sAbilityLevelUpList <= 3 then
		sAbilityLevelUpList = Fu.Utils.CombineTablesUnique(Fu.Skill.GetTalentList( bot ), Fu.Skill.GetAbilityList( bot ))
	end

	-- ARDM fallback: if skill list is empty but we still have points, rebuild from current abilities
	if GetGameMode() == GAMEMODE_ARDM and #sAbilityLevelUpList == 0 and bot:GetAbilityPoints() > 0 then
		log("[ARDM] Skill list exhausted for %s at Lv%s with %s points, rebuilding", botName, botLevel, bot:GetAbilityPoints())
		sAbilityLevelUpList = Fu.Utils.CombineTablesUnique(Fu.Skill.GetTalentList(bot), Fu.Skill.GetAbilityList(bot))
	end
end

-- Map bot to its lane. Online (shared scope) sees !pos-updated
-- RoleAssignment through Fu.GetPosition, so position-derived lane is both
-- correct and stable (Valve's dynamic lane balancer, especially in turbo,
-- can flip bot:GetAssignedLane() mid-game which would bounce our TP
-- decisions). LAN per-bot sandboxes can't see RoleAssignment mutations, so
-- there we trust the engine-assigned lane (the only signal that reflects
-- the swap). IsLanMode() gates the distinction.
function X.GetLaneByPosition(bot)
	if IsLanMode and IsLanMode() then
		local assigned = bot:GetAssignedLane()
		if assigned == LANE_TOP or assigned == LANE_MID or assigned == LANE_BOT then
			return assigned
		end
	end
	local position = Fu.GetPosition(bot)
	if GetTeam() == TEAM_RADIANT then
		if position == 1 then return LANE_BOT
		elseif position == 2 then return LANE_MID
		elseif position == 3 or position == 4 then return LANE_TOP
		elseif position == 5 then return LANE_BOT
		end
	else
		if position == 1 then return LANE_TOP
		elseif position == 2 then return LANE_MID
		elseif position == 3 or position == 4 then return LANE_BOT
		elseif position == 5 then return LANE_TOP
		end
	end
	return bot:GetAssignedLane() or LANE_MID
end

function X.GetNumEnemyNearby( building )

	local nearbynum = 0
	for i, id in pairs( GetTeamPlayers( GetOpposingTeam() ) )
	do
		if IsHeroAlive( id )
		then
			local info = GetHeroLastSeenInfo( id )
			if info ~= nil
			then
				local dInfo = info[1]
				if dInfo ~= nil
					and GetUnitToLocationDistance( building, dInfo.location ) <= 3000
					and dInfo.time_since_seen < 1.0
				then
					nearbynum = nearbynum + 1
				end
			end
		end
	end

	return nearbynum

end

local fDeathTime = 0
function X.GetRemainingRespawnTime()

	if fDeathTime == 0
	then
		return 0
	else
		return bot:GetRespawnTime() - ( DotaTime() - fDeathTime )
	end

end

local nJiDiCount = RandomInt( 14, 20 )
local nTalkDelay = RandomInt( 19, 56 )/10
local nDeathReplyTime = -999
local nLastGold = 9999
local nLastKillCount = 999
local nLastDeathCount = 0
local nContinueKillCount = 0
local nReplyHumanCount = 0
local nMaxReplyCount = RandomInt( 5, 9 )
local bInstallChatCallbackDone = false
local nReplyHumanTime = nil
local sHumanString = nil
local bAllChat = false
function X.SetTalkMessage()

	local nBotID = bot:GetPlayerID()
	local nCurrentGold = bot:GetGold()
	local nCurrentKills = GetHeroKills( nBotID )
	local nCurrentDeaths = GetHeroDeaths( nBotID )
	local nRate = GetGameMode() == GAMEMODE_TURBO and 2.0 or 1.0

	--回复玩家的对话
	if nBotID == Fu.Role.GetReplyMemberID()
		and nReplyHumanCount <= nMaxReplyCount
	then
		if not bInstallChatCallbackDone and GetGameState() == GAME_STATE_GAME_IN_PROGRESS
		then
			bInstallChatCallbackDone = true
			--print(botName)
			InstallChatCallback( function( tChat ) X.SetReplyHumanTime( tChat ) end )
		end

		if sHumanString ~= nil
			and nReplyHumanTime ~= nil
			and DotaTime() > nReplyHumanTime + nTalkDelay
		then
			local chatString = Fu.Chat.GetReplyString( sHumanString, bAllChat )
			if chatString ~= nil
			then
				if nReplyHumanCount == nMaxReplyCount
				then chatString = Fu.Chat.GetStopReplyString() end

				bot:ActionImmediate_Chat( chatString, bAllChat )

				nReplyHumanCount = nReplyHumanCount + 1
				nTalkDelay = RandomInt( 6, 30 )/10
				if nTalkDelay > 2.0 then nTalkDelay = RandomInt( 6, 30 )/10 end
			end
			sHumanString = nil
			nReplyHumanTime = nil
		end
	end

	if Fu.Customize.Allow_Trash_Talk then
		--一血
		if DotaTime() < 600
			and bot:IsAlive()
			and nCurrentKills > nLastKillCount
			and Fu.GetNumOfTeamTotalKills( false ) == 1
			and Fu.GetNumOfTeamTotalKills( true ) == 0
			and RandomInt( 1, 9 ) > 4
		then
			local sTauntMark = Localization.Get('got_first_blood')[RandomInt( 1, #Localization.Get('got_first_blood') )]
			bot:ActionImmediate_Chat( sTauntMark, true )
		end

		--发问号
		if bot:IsAlive()
			and nCurrentGold > nLastGold + 300 * nRate
			and nCurrentKills > nLastKillCount
		then
			local sTauntMark = "?"
			if Fu.Customize.Trash_Talk_Level and Fu.Customize.Trash_Talk_Level >= 2 then
				if RandomInt( 1, 9 ) > 7 then sTauntMark = Localization.Get('got_a_kill')[RandomInt( 1, #Localization.Get('got_a_kill') )] end
				if nCurrentGold > nLastGold + 800 * nRate and RandomInt( 1, 9 ) > 4 then sTauntMark = Localization.Get('got_big_kill')[RandomInt( 1, #Localization.Get('got_big_kill') )] end
				if nCurrentGold > nLastGold + 1000 * nRate and RandomInt( 1, 9 ) > 3 then sTauntMark = Localization.Get('got_big_kill_2')[RandomInt( 1, #Localization.Get('got_big_kill_2') )] end
				if nCurrentGold > nLastGold + 1500 * nRate then sTauntMark = Localization.Get('got_big_kill_3')[RandomInt( 1, #Localization.Get('got_big_kill_3') )] end
			end
			if RandomInt( 1, 9 ) > 4 then bot:ActionImmediate_Chat( sTauntMark, true ) end
		end

		--发省略号
		if not bot:IsAlive()
		then
			if nContinueKillCount >= 8
				and nDeathReplyTime == -999
			then
				nDeathReplyTime = DotaTime()
				nContinueKillCount = 0
			end

			if nDeathReplyTime ~= -999
				and nDeathReplyTime < DotaTime() - nTalkDelay
			then
				bot:ActionImmediate_Chat( Localization.Get('kill_streak_ended')[RandomInt( 1, #Localization.Get('kill_streak_ended'))], true )
				nDeathReplyTime = -999
				nTalkDelay = RandomInt( 36, 49 )/10
			end
		end

		--发"jidi, xiayiba"
		if nCurrentKills == 0
			and nCurrentDeaths >= nJiDiCount
			and Fu.Role.NotSayJiDi()
		then
			bot:ActionImmediate_Chat( Localization.Get('say_end')[RandomInt( 1, #Localization.Get('say_end'))], true )
			Fu.Role['sayJiDi'] = true
		end
	end

	--计算连杀数量
	if nLastDeathCount == nCurrentDeaths
	then
		if nCurrentKills >= nLastKillCount + 1
		then
			nContinueKillCount = nContinueKillCount + 1
		end
	else
		nContinueKillCount = 0
	end

	nLastKillCount = GetHeroKills( nBotID )
	nLastDeathCount = GetHeroDeaths( nBotID )
	nLastGold = bot:GetGold()

end


function X.SetReplyHumanTime( tChat )

	local sChatString = tChat.string
	local nChatID = tChat.player_id

	if string.find(sChatString, "!sp") or string.find(sChatString, "!speak") then
		local action, target = Fu.Utils.TrimString(sChatString):match("^(%S+)%s+(.*)$")
		log("Set to speak: %s", target)
		Fu.Customize.Localization = target
		return
	end

	if sChatString ~= "-都来守家" or Fu.Role.IsAllyMemberID( nChatID )
	then
		Fu.Role.SetLastChatString( sChatString )
	end
		
	if not IsPlayerBot( nChatID )
		and ( tChat.team_only or Fu.Role.IsEnemyMemberID( nChatID ) )
	then
		sHumanString = sChatString
		nReplyHumanTime = DotaTime()
		bAllChat = not tChat.team_only
	end


end


local function BuybackUsageComplement()
	if Fu.IsMeepoClone(bot) then return end

	X.SetTalkMessage()

	if bot:GetLevel() <= 15
		or bot:HasModifier( 'modifier_arc_warden_tempest_double' )
		or not Fu.Role.ShouldBuyBack()
	then
		return
	end

	if bot:IsAlive() and fDeathTime ~= 0
	then
		fDeathTime = 0
	end

	if not bot:IsAlive()
	then
		if fDeathTime == 0 then fDeathTime = DotaTime() end
	end

	if bot:IsAlive() then return end

	if not bot:HasBuyback() then return end


	local ancient = GetAncient( GetTeam() )

	local nFullRespawnTime = bot:GetRespawnTime()
	local nRemainingRespawnTime = X.GetRemainingRespawnTime()

	if ancient ~= nil and ancient:GetHealth() < 0.8 then
		local nEnemyUnitsAroundAncient = Fu.GetEnemiesAroundLoc(ancient:GetLocation(), 1500)
		local nAllyUnitsAroundAncient = Fu.GetAlliesNearLoc(ancient:GetLocation(), 1500)
		if nEnemyUnitsAroundAncient > 1 and nAllyUnitsAroundAncient == 0 and nRemainingRespawnTime > 20 then
			Fu.Role['lastbbtime'] = DotaTime()
			bot:ActionImmediate_Buyback()
			return
		end
	end

	if nFullRespawnTime < 45 then
		return
	end

	if bot:GetLevel() > 24
		and nRemainingRespawnTime > 80
	then
		local nTeamFightLocation = Fu.GetTeamFightLocation( bot )
		if nTeamFightLocation ~= nil
		then
			Fu.Role['lastbbtime'] = DotaTime()
			bot:ActionImmediate_Buyback()
			return
		end
	end

	if nRemainingRespawnTime < 40
	then
		return
	end

	if ancient ~= nil
	then
		local nEnemyCount = X.GetNumEnemyNearby( ancient )
		local nAllyCount = Fu.GetNumOfAliveHeroes( false )
		if nEnemyCount > 0 and nEnemyCount >= nAllyCount
		then
			Fu.Role['lastbbtime'] = DotaTime()
			bot:ActionImmediate_Buyback()
			return
		end
	end

end


local nCourierLastActionTime = -90
local nCourierState = -1
bot.SShopUser = false
local nCourierReturnTime = -90
local nCourierDeliverTime = -90
local function CourierUsageComplement()

	if DotaTime() < -56
		or bot:HasModifier( "modifier_arc_warden_tempest_double" )
		or nCourierReturnTime + 5.0 > DotaTime()
	then
		return
	end

	if bot.theCourier == nil
	then
		bot.theCourier = X.GetBotCourier( bot )
		return
	end

	--------* * * * * * * ----------------* * * * * * * ----------------* * * * * * * --------
	local bDebugCourier = ( 10 == 10 )
	local npcCourier = bot.theCourier
	nCourierState = GetCourierState( npcCourier )
	local courierHP = npcCourier:GetHealth() / npcCourier:GetMaxHealth()
	local currentTime = DotaTime()
	local bAliveBot = bot:IsAlive()
	local botLV = bot:GetLevel()
	local useCourierCD = 2.3
	local protectCourierCD = 5.0
	--------* * * * * * * ----------------* * * * * * * ----------------* * * * * * * --------

	if nCourierState == COURIER_STATE_DEAD then return	end

	if X.IsCourierTargetedByUnit( npcCourier )
	then
		if currentTime > nCourierReturnTime + protectCourierCD
		then
			nCourierReturnTime = currentTime

			Fu.SetReportMotive( bDebugCourier, "信使可能会被攻击" )

			bot:ActionImmediate_Courier( npcCourier, COURIER_ACTION_RETURN_STASH_ITEMS )

			local abilityBurst = npcCourier:GetAbilityByName( 'courier_burst' )
			if abilityBurst and abilityBurst:IsFullyCastable()
			then
				bot:ActionImmediate_Courier( npcCourier, COURIER_ACTION_BURST )
			end

			return
		end
	end

	if bot.SShopUser
		and ( not bAliveBot or bot:GetActiveMode() == BOT_MODE_SECRET_SHOP or not bot.SecretShop )
	then
		bot.SShopUser = false
		Fu.SetReportMotive( bDebugCourier, "让信使返回基地避免被卡住" )
		bot:ActionImmediate_Courier( npcCourier, COURIER_ACTION_RETURN_STASH_ITEMS )
		return
	end


	if ( nCourierState == COURIER_STATE_RETURNING_TO_BASE
		or nCourierState == COURIER_STATE_AT_BASE
		or nCourierState == COURIER_STATE_IDLE )
		and currentTime > nCourierReturnTime + protectCourierCD
	then

		if nCourierState == COURIER_STATE_AT_BASE and courierHP < 0.8 
		then return	end

		if nCourierState == COURIER_STATE_IDLE and npcCourier:DistanceFromFountain() > 800
		then
			Fu.SetReportMotive( bDebugCourier, "让空闲的信使返回" )
			bot:ActionImmediate_Courier( npcCourier, COURIER_ACTION_RETURN_STASH_ITEMS )
			return
		end

		if bAliveBot
			and ( not X.IsInvFull( bot )
					or currentTime <= 5 * 60
					or ( bot.currBuyingBasicItemList ~= nil and #bot.currBuyingBasicItemList == 0 and bot.currBuyingItemInPurchaseList ~= 'item_travel_boots' ) )
			and ( nCourierState == COURIER_STATE_AT_BASE
					or ( nCourierState == COURIER_STATE_IDLE and npcCourier:DistanceFromFountain() < 800 ) )
		then
			local nMSlot = X.GetNumStashItem( bot )
			if nMSlot > 0
			-- and Utils.CountBackpackEmptySpace(bot) >= 1
			then
				if ( bot.currBuyingBasicItemList ~= nil and #bot.currBuyingBasicItemList == 0 )
					or ( bot.currBuyingBasicItem ~= nil
							and ( IsItemPurchasedFromSecretShop( bot.currBuyingBasicItem )
									or X.GetNumStashItem( bot ) == 6
									or bot:GetGold() + 80 < GetItemCost( bot.currBuyingBasicItem ) ) )
				then
					Fu.SetReportMotive( bDebugCourier, "信使取出物品并开始运输" )
					bot:ActionImmediate_Courier( npcCourier, COURIER_ACTION_TAKE_STASH_ITEMS )
					nCourierLastActionTime = currentTime

					if currentTime > nCourierDeliverTime + protectCourierCD
					then
						nCourierDeliverTime = currentTime
						local abilityBurst = npcCourier:GetAbilityByName( 'courier_burst' )
						if abilityBurst and abilityBurst:IsFullyCastable()
						then
							Fu.SetReportMotive( bDebugCourier, "信使加速配送" )
							bot:ActionImmediate_Courier( npcCourier, COURIER_ACTION_BURST )
						end
					end
				end
			end
		end

		if bAliveBot and bot.SecretShop
			and npcCourier:DistanceFromFountain() < 7000
			and Fu.Item.GetEmptyInventoryAmount( npcCourier ) >= 2
			and not X.IsEnemyHeroAroundSecretShop() -- 商店附近没有敌人
			and currentTime > nCourierLastActionTime + useCourierCD
		then
			Fu.SetReportMotive( bDebugCourier, "信使前往神秘商店购物" )
			bot:ActionImmediate_Courier( npcCourier, COURIER_ACTION_SECRET_SHOP )
			bot.SShopUser = true
			nCourierLastActionTime = currentTime
			return
		end

		if bAliveBot
			and bot:GetCourierValue() > 0
			and bot:GetStashValue() < 100
			and ( not X.IsInvFull( bot ) or ( X.GetNumStashItem( bot ) == 0 and bot.currBuyingBasicItemList ~= nil and #bot.currBuyingBasicItemList == 0 ) )
			and ( npcCourier:DistanceFromFountain() < 4000 + botLV * 200 or GetUnitToUnitDistance( bot, npcCourier ) < 1800 )
			and currentTime > nCourierLastActionTime + useCourierCD
			-- and Utils.CountBackpackEmptySpace(bot) >= 1
		then
			Fu.SetReportMotive( bDebugCourier, "信使运输背包中的东西" )
			bot:ActionImmediate_Courier( npcCourier, COURIER_ACTION_TRANSFER_ITEMS )
			nCourierLastActionTime = currentTime
			return
		end


	end

end


function X.GetBotCourier( bot )

	local nPlayerID = bot:GetPlayerID()

	for nCourierID = 0, 4
	do
		local courier = GetCourier( nCourierID )
		if courier:GetPlayerID() == nPlayerID
		then
			return courier
		end
	end

end


function X.GetNumStashItem( unit )

	local amount = 0
	for i = 9, 14
	do
		if unit:GetItemInSlot( i ) ~= nil
		then
			amount = amount + 1
		end
	end

	return amount

end

function X.IsThereRecipeInStash( unit )
	local amount = 0

	for i = 9, 14
	do
		local item = unit:GetItemInSlot(i)
		if item ~= nil
		then
			if string.find(item:GetName(), "item_recipe_")
			then
				amount = amount + 1
			end
		end
	end

	return amount > 0
end


function X.IsCourierTargetedByUnit( courier )
	if GetGameMode() == GAMEMODE_TURBO then return false end
	
	local botLV = bot:GetLevel()

	if Fu.GetHP( courier ) < 0.9
	then
		return true
	end

	if courier:DistanceFromFountain() < 900 then return false end

	for i = 0, 10
	do
		local tower = GetTower( GetOpposingTeam(), i )
		if tower ~= nil and tower:CanBeSeen()
		then
			local towerTarget = tower:GetAttackTarget()

			if towerTarget == courier
			then
				return true
			end

			if towerTarget == nil
				and GetUnitToUnitDistance( courier, tower ) < 999
			then
				return true
			end
		end
	end

	for i, id in pairs( GetTeamPlayers( GetOpposingTeam() ) )
	do
		if IsHeroAlive( id )
		then
			local info = GetHeroLastSeenInfo( id )
			if info ~= nil
			then
				local dInfo = info[1]
				if dInfo ~= nil
					and GetUnitToLocationDistance( courier, dInfo.location ) <= 800
					and dInfo.time_since_seen < 1.8
				then
					return true
				end
			end
		end
	end

	local nEnemysHeroesCanSeen = GetUnitList( UNIT_LIST_ENEMY_HEROES )
	for _, enemy in pairs( nEnemysHeroesCanSeen )
	do
		if GetUnitToUnitDistance( enemy, courier ) <= 700 + botLV * 15
		then
			local nNearCourierAllyList = Fu.GetAlliesNearLoc( enemy:GetLocation(), 600 )
			if #nNearCourierAllyList == 0
				or enemy:GetAttackTarget() == courier
			then
				return true
			end
		end

		if enemy:GetUnitName() == 'npc_dota_hero_sniper'
			and GetUnitToUnitDistance( enemy, courier ) <= 1100 + botLV * 30
		then
			return true
		end

		if GetUnitToUnitDistance( enemy, courier ) <= enemy:GetAttackRange() + 88
		then
			return true
		end
	end

	local nEnemysHeroes = Fu.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE )
	for _, enemy in pairs( nEnemysHeroes )
	do
		if enemy ~= nil and Fu.IsValidHero( enemy ) and GetUnitToUnitDistance( enemy, courier ) <= 700 + botLV * 15
		then
			local nNearCourierAllyList = Fu.GetAlliesNearLoc( enemy:GetLocation(), 800 )
			if #nNearCourierAllyList == 0
				or enemy:GetAttackTarget() == courier
			then
				return true
			end
		end

		if enemy ~= nil and Fu.IsValidHero( enemy ) and GetUnitToUnitDistance( enemy, courier ) <= enemy:GetAttackRange() + 100
		then
			return true
		end
	end

	local nAllEnemyCreeps = GetUnitList( UNIT_LIST_ENEMY_CREEPS )
	local nNearCourierAllyList = Fu.GetAlliesNearLoc( courier:GetLocation(), 1500 )
	local nNearCourierAllyCount = #nNearCourierAllyList
	for _, creep in pairs( nAllEnemyCreeps )
	do
		if GetUnitToUnitDistance( courier, creep ) <= 800
			and ( creep:GetAttackTarget() == courier or botLV > 10 )
			and ( nNearCourierAllyCount == 0 or creep:GetAttackTarget() == courier )
		then
			return true
		end
	end

	return false

end


function X.IsInvFull( bot )

	for i = 0, 8
	do
		if bot:GetItemInSlot( i ) == nil
		then
			return false
		end
	end

	return true

end


function X.IsEnemyHeroAroundSecretShop()

	local vRadiantShop = GetShopLocation( team, SHOP_SECRET )
	local vDireShop = GetShopLocation( team, SHOP_SECRET2 )
	local vTeamSecretShop = team == TEAM_DIRE and vDireShop or vRadiantShop

	local vCenterLocation = ( vTeamSecretShop + GetAncient( team ):GetLocation() ) * 0.5

	if Fu.IsEnemyHeroAroundLocation( vCenterLocation, 2000 )
	then
		return true
	end

	return false

end




local fLastStashItemTimeList = {}
local aetherRange = 0
local lastAmuletTime = 0
local thereBeMonkey = false
local lastSwitchPtTime = -90
local hNearbyEnemyHeroList = {}
local hNearbyEnemyTowerList = {}
local botTarget = nil
local nMode = -1
local function ItemUsageComplement()

	X.SetStashItemTimeUpdate()

	if not bot:IsAlive()
		or bot:IsMuted()
		or bot:IsHexed()
		or bot:IsStunned()
		or bot:IsChanneling()
		or bot:IsInvulnerable()
		or bot:IsUsingAbility()
		or bot:IsCastingAbility()
		or bot:NumQueuedActions() > 0
		or bot:HasModifier( 'modifier_teleporting' )
		or bot:HasModifier( 'modifier_doom_bringer_doom_aura_enemy' )
		or bot:HasModifier( 'modifier_phantom_lancer_phantom_edge_boost' )
		or bot:HasModifier( 'modifier_life_stealer_infest' )
		or ( bot:HasModifier( 'modifier_nyx_assassin_vendetta' ) and Fu.IsRealInvisible( bot ) )
		or X.WillBreakInvisible( bot )
	then return	BOT_ACTION_DESIRE_NONE end

	hNearbyEnemyHeroList = Fu.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE )
	hNearbyEnemyTowerList = bot:GetNearbyTowers( 888, true )
	botTarget = Fu.GetProperTarget( bot )
	nMode = bot:GetActiveMode()

	-- If bot is in a fight (regardless of mode), treat it as "going on someone"
	-- for item activation. Fixes items not used during laning/push/defend fights.
	if nMode ~= BOT_MODE_ATTACK and nMode ~= BOT_MODE_RETREAT then
		local inFight = false
		local attackTarget = bot:GetAttackTarget()
		-- Actively attacking a hero
		if attackTarget ~= nil and attackTarget:IsHero() then
			inFight = true
		-- Enemy heroes nearby and we're taking/dealing damage
		elseif #hNearbyEnemyHeroList > 0 and (bot:WasRecentlyDamagedByAnyHero(2.0) or Fu.IsAttacking(bot)) then
			inFight = true
		end
		if inFight then
			nMode = BOT_MODE_ATTACK
		end
	end

	-- -- Emergency: if taking heavy hero damage and HP dropping, force defensive items
	-- -- regardless of mode. This catches the "walking bot melted by 5 enemies" case.
	-- local botHP = Fu.GetHP(bot)
	-- if bot:WasRecentlyDamagedByAnyHero(1.5) and botHP < 0.6 and #hNearbyEnemyHeroList >= 1 then
	-- 	local emergencyItems = {
	-- 		'item_black_king_bar', 'item_glimmer_cape', 'item_ghost',
	-- 		'item_cyclone', 'item_wind_waker', 'item_pipe',
	-- 		'item_crimson_guard', 'item_blade_mail', 'item_mekansm',
	-- 		'item_guardian_greaves', 'item_holy_locket', 'item_magic_wand',
	-- 		'item_faerie_fire', 'item_cheese', 'item_flask',
	-- 		'item_famango', 'item_great_famango', 'item_greater_famango',
	-- 	}
	-- 	for _, itemName in pairs(emergencyItems) do
	-- 		local slot = bot:FindItemSlot(itemName)
	-- 		if slot >= 0 and slot <= 5 then
	-- 			local hItem = bot:GetItemInSlot(slot)
	-- 			if hItem and Fu.CanCastAbility(hItem) then
	-- 				-- Self-target items
	-- 				if itemName == 'item_black_king_bar' or itemName == 'item_blade_mail'
	-- 				or itemName == 'item_pipe' or itemName == 'item_crimson_guard'
	-- 				or itemName == 'item_mekansm' or itemName == 'item_guardian_greaves'
	-- 				or itemName == 'item_magic_wand' or itemName == 'item_faerie_fire'
	-- 				or itemName == 'item_cheese' or itemName == 'item_holy_locket'
	-- 				then
	-- 					bot:Action_UseAbility(hItem)
	-- 					return
	-- 				-- Self-cast unit-target items
	-- 				elseif itemName == 'item_glimmer_cape' then
	-- 					bot:Action_UseAbilityOnEntity(hItem, bot)
	-- 					return
	-- 				-- Location/no-target consumables
	-- 				elseif itemName == 'item_flask' or itemName == 'item_famango'
	-- 				or itemName == 'item_great_famango' or itemName == 'item_greater_famango' then
	-- 					bot:Action_UseAbilityOnEntity(hItem, bot)
	-- 					return
	-- 				-- Eul's on nearest enemy (escape)
	-- 				elseif (itemName == 'item_cyclone' or itemName == 'item_wind_waker') and botHP < 0.3 then
	-- 					bot:Action_UseAbility(hItem)
	-- 					return
	-- 				-- Ghost scepter
	-- 				elseif itemName == 'item_ghost' then
	-- 					bot:Action_UseAbility(hItem)
	-- 					return
	-- 				end
	-- 			end
	-- 		end
	-- 	end
	-- end

	local aether = Fu.IsItemAvailable( "item_aether_lens" )
	if aether ~= nil then aetherRange = 250 else aetherRange = 0 end

	local nItemSlot = { 0, 1, 2, 3, 4, 5, 15, 16 }

	for _, nSlot in pairs( nItemSlot )
	do
		local hItem = bot:GetItemInSlot( nSlot )
		if Fu.CanCastAbility(hItem)
		then
			local sItemName = hItem:GetName()
			if X.ConsiderItemDesire[sItemName] ~= nil and not X.IsItemInStash( sItemName ) then
				local nItemDesire, hItemTarget, sCastType = X.ConsiderItemDesire[sItemName]( hItem )
				if nItemDesire > 0 then
					X.SetUseItem( hItem, hItemTarget, sCastType )
				end
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

function X.SetUseItem( hItem, hItemTarget, sCastType )

	if sCastType == 'none'
	then
		bot:Action_UseAbility( hItem )
		return
	elseif sCastType == 'unit' and type(hItemTarget) == 'table'
	then
		bot:Action_UseAbilityOnEntity( hItem, hItemTarget )
		if string.find(hItem:GetName(), 'tango') then bot._lastTangoUseTime = DotaTime() end
		return
	elseif sCastType == 'ground' or (hItemTarget and type(hItemTarget) ~= 'number' and type(hItemTarget) ~= 'table' and hItemTarget.x ~= nil) -- in case target is a location
	then
		bot:Action_UseAbilityOnLocation( hItem, hItemTarget )
		return
	elseif sCastType == 'tree'
	then
		bot:Action_UseAbilityOnTree( hItem, hItemTarget )
		bot._lastTangoUseTime = DotaTime()
		return
	elseif sCastType == 'twice'
	then
		bot:Action_UseAbility( hItem )
		bot:ActionQueue_UseAbility( hItem )
		return
	end

end


function X.IsWithoutSpellShield( npcEnemy )

	return not npcEnemy:HasModifier( "modifier_item_sphere_target" )
			and not npcEnemy:HasModifier( "modifier_antimage_spell_shield" )
			and not npcEnemy:HasModifier( "modifier_item_lotus_orb_active" )

end


local lastDeleteTime = -90
function X.SetStashItemTimeUpdate()

	local currentTime = DotaTime()

	for i = 6, 8
	do
		local hItem = bot:GetItemInSlot( i )
		if hItem ~= nil
		then
			fLastStashItemTimeList[hItem:GetName()] = currentTime
		end
	end

	if currentTime > lastDeleteTime + 7.0
	then
		lastDeleteTime = currentTime
		for k, v in pairs( fLastStashItemTimeList )
		do
			if v ~= nil
				and v < currentTime - 7.0
			then
				fLastStashItemTimeList[k] = nil
			end
		end
	end

end


function X.IsItemInStash( sItemName )

	if fLastStashItemTimeList[sItemName] ~= nil
		and DotaTime() < fLastStashItemTimeList[sItemName] + 6.05
	then
		return true
	end

	return false

end


function X.WillBreakInvisible( bot )
	if not bot:IsInvisible() then return false end

	-- Heroes with permanent/semi-permanent invisibility should still use items
	local botName = botName
	if botName == "npc_dota_hero_riki"
	or botName == "npc_dota_hero_bounty_hunter"
	or botName == "npc_dota_hero_slark"
	then
		return false
	end

	-- PA blur doesn't break on item use
	if bot:HasModifier("modifier_phantom_assassin_blur_active") then return false end

	-- Glimmer Cape self-cast: don't block items — the invis is short and
	-- bots need to use items (wand, flask, BKB) during it
	if bot:HasModifier("modifier_item_glimmer_cape_fade") then return false end

	-- Shadow Amulet: intentional hiding, don't break
	if bot:HasModifier("modifier_item_shadow_amulet_fade") then return true end

	-- Shadow Blade / Silver Edge: intentional invis for initiation, don't use items
	if bot:HasModifier("modifier_item_invisibility_edge_windwalk")
	or bot:HasModifier("modifier_item_silver_edge_windwalk")
	then
		return true
	end

	-- Smoke: don't break
	if bot:HasModifier("modifier_smoke_of_deceit") then return true end

	-- Other invisibility (Mirana ult, ally abilities, etc.): allow item usage
	return false

end


X.ConsiderItemDesire = {}

--深渊
X.ConsiderItemDesire["item_abyssal_blade"] = function( hItem )

	local nCastRange = 620 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil

	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	for _, npcEnemy in pairs( nInRangeEnmyList )
	do

		if Fu.IsValid( npcEnemy )
			and Fu.CanCastOnNonMagicImmune( npcEnemy )
			and X.IsWithoutSpellShield( npcEnemy )
		then
			--打断
			if npcEnemy:IsChanneling() or npcEnemy:IsCastingAbility()
			then
				hEffectTarget = npcEnemy
				sCastMotive = "打断:"..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			--撤退
			if 	nMode == BOT_MODE_RETREAT
				and not Fu.IsDisabled( npcEnemy )
			then
				hEffectTarget = npcEnemy
				sCastMotive = "撤退:"..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end

	end

	--进攻
	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.IsInRange( bot, botTarget, nCastRange + 50 )
			and Fu.CanCastOnNonMagicImmune( botTarget ) --bug
			and X.IsWithoutSpellShield( botTarget )
			and not Fu.IsDisabled( botTarget )
		then
			hEffectTarget = botTarget
			sCastMotive = "进攻:"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--战鼓
X.ConsiderItemDesire["item_ancient_janggo"] = function( hItem )

	if ( hItem:GetCurrentCharges() <= 0 and hItem:GetName() == "item_ancient_janggo" )
	then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 680
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	if bot:HasModifier('modifier_nyx_assassin_vendetta')
	then
		return BOT_ACTION_DESIRE_NONE
	end

	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.CanCastOnMagicImmune( botTarget )
			and Fu.IsInRange( bot, botTarget, nCastRange )
		then
			hEffectTarget = botTarget
			sCastMotive = "进攻:"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--秘法
X.ConsiderItemDesire["item_arcane_boots"] = function( hItem )

	if bot:DistanceFromFountain() < 800 then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 1200
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	local hNearbyAllyList = Fu.GetAllyList( bot, nCastRange )

	if #hNearbyAllyList >= 2
		and bot:GetHealth() <= 120
		and bot:WasRecentlyDamagedByAnyHero( 3.0 )
	then
		sCastMotive = '死前为队友用'
		return BOT_ACTION_DESIRE_HIGH, hNearbyAllyList[2], sCastType, sCastMotive
	end

	local nNeedMPCount = 0
	for _, npcAlly in pairs( hNearbyAllyList )
	do
		if npcAlly ~= nil and npcAlly:IsAlive()
			and npcAlly:GetMaxMana()- npcAlly:GetMana() > 180
		then
			nNeedMPCount = nNeedMPCount + 1
		end

		if nNeedMPCount >= 2
		then
			sCastMotive = '团队回蓝'
			return BOT_ACTION_DESIRE_HIGH, hNearbyAllyList[2], sCastType, sCastMotive
		end
	end

	if bot:GetMana() / bot:GetMaxMana() < 0.65
	then
		sCastMotive = '自己补蓝'
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, sCastMotive
	end


	return BOT_ACTION_DESIRE_NONE

end


--臂章
X.ConsiderItemDesire["item_armlet"] = function( hItem )

	local bIsToggled = hItem:GetToggleState()

	if Fu.IsValid(botTarget)
	and Fu.CanBeAttacked(botTarget)
	and Fu.IsInRange(bot, botTarget, bot:GetAttackRange() + 300)
	and (not botTarget:IsBuilding() or not string.find(botTarget:GetUnitName(), 'OutpostName'))
	and not bot:IsDisarmed()
	then
		if not bIsToggled then
			return BOT_ACTION_DESIRE_HIGH, nil, 'none'
		else
			return BOT_ACTION_DESIRE_NONE
		end
	end

	if Fu.IsRetreating(bot) and not Fu.IsRealInvisible(bot) then
		if Fu.GetHP(bot) < 0.2 then
			if bot:WasRecentlyDamagedByAnyHero(2.0)
			or Fu.IsAttackProjectileIncoming(bot, 1200)
			or Fu.IsStunProjectileIncoming(bot, 550)
			then
				if not bIsToggled then
					return BOT_ACTION_DESIRE_HIGH, nil, 'none'
				else
					return BOT_ACTION_DESIRE_NONE
				end
			end
		end
	end

	if (Fu.GetAttackProjectileDamageByRange(bot, 600) > bot:GetHealth() * 2)
	or (Fu.IsStunProjectileIncoming(bot, 600) and Fu.GetHP(bot) < 0.25)
	then
		if not bIsToggled then
			return BOT_ACTION_DESIRE_HIGH, nil, 'none'
		else
			return BOT_ACTION_DESIRE_NONE
		end
	end

	if bIsToggled then
		return BOT_ACTION_DESIRE_HIGH, nil, 'none'
	end

	return BOT_ACTION_DESIRE_NONE

end


--狂战
X.ConsiderItemDesire["item_bfury"] = function( hItem )

	return X.ConsiderItemDesire["item_quelling_blade"]( hItem )

end


--BKB
X.ConsiderItemDesire["item_black_king_bar"] = function( hItem )
	if bot:HasModifier('modifier_dazzle_nothl_projection_soul_debuff') then
		return BOT_ACTION_DESIRE_NONE
	end

	local nCastRange = 1300
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if #nInRangeEnmyList > 0
		and not bot:IsMagicImmune()
		and not bot:IsInvulnerable()
		and not bot:HasModifier( 'modifier_item_lotus_orb_active' )
		and not bot:HasModifier( 'modifier_antimage_spell_shield' )
		and ( Fu.IsGoingOnSomeone( bot ) or Fu.IsRetreating( bot ) )
	then
		local nearEnemyCount = Fu.GetEnemyCount( bot, 600 )
		if bot:IsRooted()
		then
			sCastMotive = '解缠绕'
			return BOT_ACTION_DESIRE_HIGH, bot, sCastType, sCastMotive
		end

		if bot:IsSilenced()
			and bot:GetMana() > 100
			and not bot:HasModifier( "modifier_item_mask_of_madness_berserk" )
			and nearEnemyCount >= 2
		then
			sCastMotive = '解沉默'
			return BOT_ACTION_DESIRE_HIGH, bot, sCastType, sCastMotive
		end

		if Fu.IsNotAttackProjectileIncoming( bot, 350 )
		and nearEnemyCount >= 1
		then
			sCastMotive = '防御弹道'
			return BOT_ACTION_DESIRE_HIGH, bot, sCastType, sCastMotive
		end

		if Fu.IsWillBeCastUnitTargetSpell( bot, nCastRange )
		and nearEnemyCount >= 1
		then
			sCastMotive = '防御指向技能'
			return BOT_ACTION_DESIRE_HIGH, bot, sCastType, sCastMotive
		end

		if Fu.IsWillBeCastPointSpell( bot, nCastRange )
		and nearEnemyCount >= 1
		then
			sCastMotive = '防御地点技能'
			return BOT_ACTION_DESIRE_HIGH, bot, sCastType, sCastMotive
		end

		if Fu.GetEnemyCount( bot, 800 ) >= 3
		then
			sCastMotive = '先开BKB切入'
			return BOT_ACTION_DESIRE_HIGH, bot, sCastType, sCastMotive
		end

	end

	return BOT_ACTION_DESIRE_NONE

end


--刃甲
X.ConsiderItemDesire["item_blade_mail"] = function( hItem )

	local nCastRange = 800
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsNotAttackProjectileIncoming( bot, 366 )
		and #nInRangeEnmyList >= 1
	then
		hEffectTarget = bot
		sCastMotive = '反弹弹道'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	for _, npcEnemy in pairs( hNearbyEnemyHeroList )
	do
		if Fu.IsValidHero( npcEnemy )
			and Fu.CanCastOnNonMagicImmune( npcEnemy )
			and npcEnemy:GetAttackTarget() == bot
			and ( bot:WasRecentlyDamagedByHero( npcEnemy, 5.0 )
				 or Fu.IsAttackProjectileIncoming( bot, 1000 ) )
		then
			hEffectTarget = npcEnemy
			sCastMotive = '反弹敌人伤害:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--跳刀
X.ConsiderItemDesire["item_blink"] = function( hItem )
	local nCastRange = 1200
	if hItem:GetName() == 'item_arcane_blink' then
		nCastRange = 1400
	end

	nCastRange = nCastRange + aetherRange

	if Fu.HasItemInInventory('item_magnifying_monocle') then
		nCastRange = nCastRange + 100
	end

	if Fu.HasItemInInventory('item_enhancement_keen_eyed') then
		if DotaTime() >= (Fu.IsModeTurbo() and 7.5*60 or 15*60) then
			nCastRange = nCastRange + 125
		elseif DotaTime() >= (Fu.IsModeTurbo() and 12.5*60 or 25*60) then
			nCastRange = nCastRange + 135
		end
	end

	if Fu.HasItemInInventory('item_enhancement_mystical') then
		if DotaTime() >= (Fu.IsModeTurbo() and 17.5*60 or 35*60) then
			nCastRange = nCastRange + 100
		end
	end

	if Fu.HasItemInInventory('item_enhancement_boundless') then
		if DotaTime() >= (Fu.IsModeTurbo() and 30*60 or 60*60) then
			nCastRange = nCastRange + 350
		end
	end

	local botName = bot:GetUnitName()

	if bot:IsRooted()
	or bot:HasModifier('modifier_nyx_assassin_vendetta')
	then
		return BOT_ACTION_DESIRE_NONE
	end

	if Fu.IsStuck(bot)
	then
		local loc = Fu.GetLocationTowardDistanceLocation(bot, GetAncient(GetTeam()):GetLocation(), nCastRange)
		return BOT_ACTION_DESIRE_HIGH, loc, 'ground', nil
	end

	local nInRangeAlly = bot:GetNearbyHeroes(800, false, BOT_MODE_ATTACK)

	if  Fu.IsRetreating(bot)
	and not Fu.IsRealInvisible(bot)
	and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_MODERATE
	then
		local vLocation = Fu.GetLocationTowardDistanceLocation(bot, GetAncient(GetTeam()):GetLocation(), nCastRange)
		local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), 1200)

		if  bot:DistanceFromFountain() > 900
		and IsLocationPassable(vLocation)
		and (#nInRangeAlly <= 1
			or bot:GetActiveModeDesire() > BOT_MODE_DESIRE_VERYHIGH * 0.9)
		and nInRangeEnemy ~= nil and #nInRangeEnemy >= 1
		then
			return BOT_ACTION_DESIRE_HIGH, vLocation, 'ground', nil
		end
	end

	nInRangeAlly = bot:GetNearbyHeroes(1600, false, BOT_MODE_ATTACK)

	if #nInRangeAlly <= 1 and (botTarget == nil or not botTarget:IsHero())
	and Fu.IsFarming(bot)
	and not bot:WasRecentlyDamagedByAnyHero(3.1)
	and not Fu.IsPushing(bot)
	and not Fu.IsDefending(bot)
	then
		local nAOELocation = bot:FindAoELocation(true, false, bot:GetLocation(), nCastRange, 500, 0, 0)
		local nEnemyLaneCreeps = bot:GetNearbyLaneCreeps(1600, true)
		local nInRangeEnemy = Fu.GetEnemiesNearLoc(nAOELocation.targetloc, 1600)

		if  nEnemyLaneCreeps ~= nil and #nEnemyLaneCreeps >= 4
		and nInRangeEnemy ~= nil and #nInRangeEnemy == 0
		and nAOELocation.count >= 4
		then
			local bCenter = Fu.GetCenterOfUnits(nEnemyLaneCreeps)
			local bDist = GetUnitToLocationDistance(bot, bCenter)
			local vLocation = Fu.GetLocationTowardDistanceLocation(bot, bCenter, bDist + 550)
			local bLocation = Fu.GetLocationTowardDistanceLocation(bot, bCenter, bDist - 300)

			if bDist > nCastRange then bLocation = Fu.GetLocationTowardDistanceLocation(bot, bCenter, nCastRange) end

			if  IsLocationPassable(bLocation)
			and GetUnitToLocationDistance(bot, bLocation) > 600
			and IsLocationVisible(vLocation)
			and not Fu.IsLocHaveTower(700, true, bLocation)
			then
				return BOT_ACTION_DESIRE_HIGH, bLocation, 'ground', nil
			end
		end
	end

	if  Fu.IsProjectileIncoming(bot, 1200)
	and (botTarget == nil
		or not botTarget:IsHero()
		or not Fu.IsInRange(bot, botTarget, bot:GetAttackRange() + 100))
	then
		local loc = Fu.GetLocationTowardDistanceLocation(bot, GetAncient(GetTeam()):GetLocation(), 1199)
		return BOT_ACTION_DESIRE_HIGH, loc, 'ground', nil
	end

	if Fu.IsGoingOnSomeone(bot) then
		-- for their queued spell combos
		if  bot.shouldBlink ~= nil
		and bot.shouldBlink
		and (botName == 'npc_dota_hero_batrider'
			or botName == 'npc_dota_hero_beastmaster'
			or botName == 'npc_dota_hero_dark_seer'
			or botName == 'npc_dota_hero_earthshaker'
			or botName == 'npc_dota_hero_magnataur'
			or botName == 'npc_dota_hero_rubick'
			-- or botName == 'npc_dota_hero_tinker'
			or botName == 'npc_dota_hero_tiny'
			or botName == 'npc_dota_hero_treant')
		then
			return BOT_ACTION_DESIRE_NONE
		end

		if botName == 'npc_dota_hero_nevermore' then
			local RequiemOfSouls = bot:GetAbilityByName('nevermore_requiem')
			if Fu.CanCastAbility(RequiemOfSouls) then
				return BOT_ACTION_DESIRE_NONE
			end
		end

		if  Fu.IsValidTarget(botTarget)
		and Fu.IsInRange(bot, botTarget, nCastRange)
		and Fu.CanBeAttacked(botTarget)
		and not Fu.IsInRange(bot, botTarget, 500)
		and not botTarget:HasModifier('modifier_faceless_void_chronosphere_freeze')
		and not botTarget:HasModifier('modifier_enigma_black_hole_pull')
		then
			local nInRangeAlly = Fu.GetAlliesNearLoc(botTarget:GetLocation(), 1200)
			local nInRangeEnemy = Fu.GetEnemiesNearLoc(botTarget:GetLocation(), 1200)
			local bWeAreStronger = Fu.WeAreStronger(bot, 1200)
			local nNearbyEnemyHeroCount = 0
			for _, id in pairs(GetTeamPlayers(GetOpposingTeam())) do
				if IsHeroAlive(id) then
					local info = GetHeroLastSeenInfo(id)
					if info ~= nil then
						local dInfo = info[1]
						if dInfo ~= nil and dInfo.time_since_seen < 3.0 and GetUnitToLocationDistance(botTarget, dInfo.location) <= 1200 then
							nNearbyEnemyHeroCount = nNearbyEnemyHeroCount + 1
						end
					end
				end
			end

			if (#nInRangeAlly >= nNearbyEnemyHeroCount and bWeAreStronger) then
				local nDistance = Min(nCastRange, GetUnitToUnitDistance(bot, botTarget))
				local vLocation = Fu.GetUnitTowardDistanceLocation(bot, botTarget, nDistance) + RandomVector(150)
				if IsLocationPassable(vLocation) then
					return BOT_ACTION_DESIRE_HIGH, vLocation, 'ground', nil
				end
			end
		end
	end

	if Fu.IsDoingTormentor(bot) and not Fu.IsRealInvisible(bot) then
		local vTormentorLocation = Fu.GetTormentorLocation(GetTeam())
		if GetUnitToLocationDistance(bot, vTormentorLocation) > 2000 then
			local vLocation = Fu.VectorTowards(bot:GetLocation(), vTormentorLocation, nCastRange)
			local nInRangeEnemy = Fu.GetEnemiesNearLoc(vLocation, 1200)
			if IsLocationPassable(vLocation) and #nInRangeEnemy == 0 then
				return BOT_ACTION_DESIRE_HIGH, vLocation, 'ground', nil
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

--盛世闪光
X.ConsiderItemDesire["item_overwhelming_blink"] = function( hItem )

	return X.ConsiderItemDesire["item_blink"]( hItem )

end

--迅疾闪光
X.ConsiderItemDesire["item_swift_blink"] = function( hItem )

	return X.ConsiderItemDesire["item_blink"]( hItem )

end

--秘奥闪光
X.ConsiderItemDesire["item_arcane_blink"] = function( hItem )

	return X.ConsiderItemDesire["item_blink"]( hItem )

end


--奶酪
X.ConsiderItemDesire["item_cheese"] = function( hItem )

	if bot:DistanceFromFountain() < 1200 then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 800
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	local nLostHealth = bot:GetMaxHealth() - bot:GetHealth()
	local botHP = bot:GetHealth() / bot:GetMaxHealth()
	local nLostMana = bot:GetMaxMana() - bot:GetMana()
	local botMP = bot:GetMana() / bot:GetMaxMana()


	if ( nLostHealth > 2500 and nLostMana > 1500 )
		or ( nLostHealth > 2000 and nLostHealth + nLostMana > 3000 )
		or ( botHP < 0.4 and botMP < 0.4 )
		or ( botHP < 0.2 )
		or ( botMP < 0.06 )
	then
		if Fu.IsGoingOnSomeone( bot )
		then
			if Fu.IsValidHero( botTarget )
				and Fu.IsInRange( bot, botTarget, 2000 )
				and Fu.CanCastOnMagicImmune( botTarget )
			then
				hEffectTarget = bot
				sCastMotive = "进攻"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end

		if Fu.IsRetreating( bot )
			and bot:WasRecentlyDamagedByAnyHero( 4.0 )
		then
			hEffectTarget = bot
			sCastMotive = "撤退"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--血精石
-- 7.41: Bloodstone active (Blood Pact) - increases spell lifesteal to 60% for the duration, self-cast
X.ConsiderItemDesire["item_bloodstone"] = function( hItem )

	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE )

	-- Don't use when silenced or mana too low
	if bot:IsSilenced() or bot:GetMana() < hItem:GetManaCost() then
		return BOT_ACTION_DESIRE_NONE
	end

	-- Don't use when no enemies nearby (wasted)
	if #nInRangeEnmyList == 0 and not Fu.IsDoingRoshan(bot) and not Fu.IsDoingTormentor(bot) then
		return BOT_ACTION_DESIRE_NONE
	end

	-- Use in teamfights with enemies nearby
	if Fu.IsInTeamFight( bot, 1200 ) and #nInRangeEnmyList >= 2
	then
		hEffectTarget = bot
		sCastMotive = 'Bloodstone: teamfight spell lifesteal'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	-- Use when going on someone and enemies within 1200
	if Fu.IsGoingOnSomeone( bot ) and #nInRangeEnmyList >= 1
	then
		hEffectTarget = bot
		sCastMotive = 'Bloodstone: going on target with spell lifesteal'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	-- Use when doing Roshan/Tormentor for sustain
	if Fu.IsDoingRoshan(bot) or Fu.IsDoingTormentor(bot)
	then
		hEffectTarget = bot
		sCastMotive = 'Bloodstone: Roshan/Tormentor sustain'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end


--血棘
X.ConsiderItemDesire["item_bloodthorn"] = function( hItem )

	return X.ConsiderItemDesire["item_orchid"]( hItem )

end

--魔瓶
X.ConsiderItemDesire["item_bottle"] = function( hItem )

	if hItem:GetCurrentCharges() == 0
		or bot:HasModifier( "modifier_bottle_regeneration" )
	then return BOT_ACTION_DESIRE_NONE end

	if Fu.HasDamageOverTimeDebuff(bot) then
		return BOT_ACTION_DESIRE_NONE
	end

	local nCastRange = 400 + aetherRange
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nLostMana = bot:GetMaxMana() - bot:GetMana()
	local nLostHealth = bot:OriginalGetMaxHealth() - bot:OriginalGetHealth()


	--泉水喝
	if bot:HasModifier( "modifier_fountain_aura" )
	then
		hEffectTarget = bot
		sCastMotive = "在泉水里喝"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	--自己喝
	if not bot:WasRecentlyDamagedByAnyHero( 3.0 )
	then
		if nLostHealth > 150 and nLostMana > 90
		then
			hEffectTarget = bot
			sCastMotive = "补血补篮"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		if nLostHealth > 500 and Fu.GetHP( bot ) < 0.5
		then
			hEffectTarget = bot
			sCastMotive = "只补血"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		if nLostMana > 280 and Fu.GetMP( bot ) < 0.4
		then
			hEffectTarget = bot
			sCastMotive = "只补篮"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end


	return BOT_ACTION_DESIRE_NONE

end


--小净化
X.ConsiderItemDesire["item_clarity"] = function( hItem )

	if bot:DistanceFromFountain() < 2000 then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 800 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.GetMP( bot ) < 0.4
		and not bot:HasModifier( "modifier_clarity_potion" )
		and #nInRangeEnmyList == 0
		and not bot:WasRecentlyDamagedByAnyHero( 4.0 )
	then
		hEffectTarget = bot
		sCastMotive = '净化自己'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if #nInRangeEnmyList == 0 
	then
		local hAllyList = Fu.GetNearbyHeroes(bot, 600, false, BOT_MODE_NONE )
		local hNeedManaAlly = nil
		local nNeedManaAllyMana = 99999
		for _, npcAlly in pairs( hAllyList )
		do
			if Fu.IsValid( npcAlly )
				and npcAlly ~= bot
				and not npcAlly:IsIllusion()
				and not npcAlly:IsChanneling()
				and not npcAlly:HasModifier( "modifier_clarity_potion" )
				and not npcAlly:WasRecentlyDamagedByAnyHero( 4.0 )
				and npcAlly:GetMaxMana() - npcAlly:GetMana() > 350 
			then
				if( npcAlly:GetMana() < nNeedManaAllyMana )
				then
					hNeedManaAlly = npcAlly
					nNeedManaAllyMana = npcAlly:GetMana()
				end
			end
		end
		if( hNeedManaAlly ~= nil )
		then
			hEffectTarget = hNeedManaAlly
			sCastMotive = '净化队友:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--赤红甲
X.ConsiderItemDesire["item_crimson_guard"] = function( hItem )

	if bot:DistanceFromFountain() < 400 then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 1200
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	local hNearbyAllyList = Fu.GetAllyList( bot, nCastRange )

	for _, npcAlly in pairs( hNearbyAllyList )
	do
		if Fu.IsValid( npcAlly )
			and npcAlly:OriginalGetHealth() / npcAlly:OriginalGetMaxHealth() < 0.8
			and npcAlly:WasRecentlyDamagedByAnyHero( 2.0 )
			and not npcAlly:HasModifier( "modifier_item_crimson_guard_nostack" )
			and #hNearbyEnemyHeroList > 0
		then
			hEffectTarget = npcAlly
			sCastMotive = '救救队友:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end


	local nNearbyEnemyHeroes = Fu.GetNearbyHeroes(bot, 1000, true, BOT_MODE_NONE )
	local nNearbyEnemyTowers = bot:GetNearbyTowers( 800, true )
	if #hNearbyAllyList >= 2
		and ( #nNearbyEnemyHeroes + #nNearbyEnemyTowers >= 2 or #nNearbyEnemyHeroes >= 2 )
	then
		for _, npcAlly in pairs( hNearbyAllyList )
		do
			if npcAlly:WasRecentlyDamagedByAnyHero( 2.0 )
				and not npcAlly:HasModifier( "modifier_item_crimson_guard_nostack" )
			then
				hEffectTarget = npcAlly
				sCastMotive = '保护队友:'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end


	return BOT_ACTION_DESIRE_NONE

end


--吹风
X.ConsiderItemDesire["item_cyclone"] = function( hItem )

	local nCastRange = 650 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	if bot:HasModifier('modifier_nyx_assassin_vendetta')
	then
		return BOT_ACTION_DESIRE_NONE
	end

	if Fu.IsValid( botTarget )
		and Fu.CanCastOnNonMagicImmune( botTarget )
		and X.IsWithoutSpellShield( botTarget )
		and Fu.IsInRange( bot, botTarget, nCastRange + 200 )
	then
		---- Invoker combo with item_cyclone ----
		if botName == "npc_dota_hero_invoker" and Fu.IsGoingOnSomeone(bot) then
			if Fu.IsValidHero(botTarget)
			and not Fu.IsSuspiciousIllusion(botTarget)
			and Fu.GetMP(bot) > 0.5 then
				-- Should check if the target is already stuned etc.
				hEffectTarget = botTarget
				sCastMotive = '预设连招:'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end

		-- 别帮电脑减伤害/解状态
		if botTarget:HasModifier( 'modifier_invoker_cold_snap_freeze' ) 
		or botTarget:HasModifier('modifier_invoker_cold_snap') 
		or botTarget:HasModifier('modifier_invoker_chaos_meteor_burn') then
			return BOT_ACTION_DESIRE_NONE
		end

		---- Above for Invoker combo with item_cyclone ----


		if botTarget:HasModifier( 'modifier_teleporting' )
			 or botTarget:HasModifier( 'modifier_abaddon_borrowed_time' )
			 or botTarget:HasModifier( "modifier_ursa_enrage" )
			 or botTarget:HasModifier( "modifier_item_satanic_unholy" )
			 or botTarget:IsChanneling()
		then
			hEffectTarget = botTarget
			sCastMotive = '驱散Buff:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		if Fu.GetHP( botTarget ) > 0.49 and Fu.IsCastingUltimateAbility( botTarget )
		then
			hEffectTarget = botTarget
			sCastMotive = '打断大招:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		if Fu.IsRunning( botTarget ) and botTarget:GetCurrentMovementSpeed() > 440
		then
			hEffectTarget = botTarget
			sCastMotive = '阻止逃跑:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if Fu.CanCastOnNonMagicImmune( bot )
		and #hNearbyEnemyHeroList > 0
	then
		if Fu.GetHP(bot) < 0.2 and bot:WasRecentlyDamagedByAnyHero( 3.0 )
		then
			hEffectTarget = bot
			sCastMotive = '撤退:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		if bot:IsRooted()
			or ( bot:GetPrimaryAttribute() == ATTRIBUTE_INTELLECT and bot:IsSilenced() )
		then
			hEffectTarget = bot
			sCastMotive = '解缠绕:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		if Fu.IsUnitTargetProjectileIncoming( bot, 800 )
		then
			hEffectTarget = bot
			sCastMotive = '防御弹道:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--风之杖
X.ConsiderItemDesire["item_wind_waker"] = function( hItem )

	return X.ConsiderItemDesire["item_cyclone"]( hItem )

end


--大根
-- 7.41: Dagon no longer instakills non-ancient creeps and no longer heals the user.
-- Only target heroes with Dagon.
X.ConsiderItemDesire["item_dagon"] = function( hItem )

	local nCastRange = hItem:GetCastRange() + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange + 100, true, BOT_MODE_NONE )
	local nDamage = hItem:GetSpecialValueInt( "damage" )

	if bot:HasModifier('modifier_nyx_assassin_vendetta')
	then
		return BOT_ACTION_DESIRE_NONE
	end

	--击杀
	for _, npcEnemy in pairs( nInRangeEnmyList )
	do
		if Fu.IsValidHero( npcEnemy )
			and Fu.CanCastOnNonMagicImmune( npcEnemy )
			and X.IsWithoutSpellShield( npcEnemy )
			and Fu.CanKillTarget( npcEnemy, nDamage, DAMAGE_TYPE_MAGICAL )
		then
			hEffectTarget = npcEnemy
			sCastMotive = "击杀:"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	--攻击
	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and X.IsWithoutSpellShield( botTarget )
			and Fu.IsInRange( bot, botTarget, nCastRange )
		then
			hEffectTarget = botTarget
			sCastMotive = "进攻:"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

X.ConsiderItemDesire["item_dagon_2"] = function( hItem )

	return X.ConsiderItemDesire["item_dagon"]( hItem )

end

X.ConsiderItemDesire["item_dagon_3"] = function( hItem )

	return X.ConsiderItemDesire["item_dagon"]( hItem )

end

X.ConsiderItemDesire["item_dagon_4"] = function( hItem )

	return X.ConsiderItemDesire["item_dagon"]( hItem )

end

X.ConsiderItemDesire["item_dagon_5"] = function( hItem )

	return X.ConsiderItemDesire["item_dagon"]( hItem )

end

--散失
X.ConsiderItemDesire["item_diffusal_blade"] = function( hItem )

	local nCastRange = 630 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if( nMode == BOT_MODE_RETREAT )
	then
		for _, npcEnemy in pairs( hNearbyEnemyHeroList )
		do
			if Fu.IsValid( npcEnemy )
				and Fu.IsMoving( npcEnemy )
				and Fu.IsInRange( npcEnemy, bot, nCastRange )
				and bot:WasRecentlyDamagedByHero( npcEnemy, 4.0 )
				and npcEnemy:GetCurrentMovementSpeed() > 200
				and Fu.CanCastOnNonMagicImmune( npcEnemy )
				and X.IsWithoutSpellShield( npcEnemy )
				and not Fu.IsDisabled( npcEnemy ) 
			then
				hEffectTarget = npcEnemy
				sCastMotive = "撤退:"..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.IsMoving( botTarget )
			and botTarget:GetCurrentMovementSpeed() > 200
			and Fu.IsInRange( botTarget, bot, nCastRange )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and X.IsWithoutSpellShield( botTarget )
			and not Fu.IsDisabled( botTarget )
		then
			hEffectTarget = botTarget
			sCastMotive = "进攻:"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	-- Also use when attacking any hero in range (covers bear, laning, etc.)
	if Fu.IsValidHero( botTarget )
		and Fu.IsInRange( botTarget, bot, nCastRange )
		and Fu.CanCastOnNonMagicImmune( botTarget )
		and X.IsWithoutSpellShield( botTarget )
		and not Fu.IsDisabled( botTarget )
		and bot:GetAttackTarget() == botTarget
	then
		hEffectTarget = botTarget
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, 'diffusal: in combat'
	end

	local npcEnemy = hNearbyEnemyHeroList[1]
	if Fu.IsValidHero( npcEnemy )
		and Fu.IsInRange( bot, npcEnemy, nCastRange - 100 )
		and Fu.CanCastOnNonMagicImmune( npcEnemy )
		and X.IsWithoutSpellShield( npcEnemy )
		and not Fu.IsDisabled( npcEnemy )
		and Fu.IsMoving( npcEnemy )
		and Fu.IsRunning( npcEnemy )
		and npcEnemy:GetCurrentMovementSpeed() > bot:GetCurrentMovementSpeed() * 0.8
	then
		hEffectTarget = npcEnemy
		sCastMotive = '减速:'..Fu.Chat.GetNormName( hEffectTarget )
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end


--芒果
X.ConsiderItemDesire["item_enchanted_mango"] = function( hItem )

	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil

	if bot:GetMana() < 150
	then
		hEffectTarget = bot
		sCastMotive = '自己吃'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end


--虚灵
X.ConsiderItemDesire["item_ethereal_blade"] = function( hItem )

	local nCastRange = 800 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and Fu.CanCastOnTargetAdvanced( botTarget )
			and Fu.IsInRange( bot, botTarget, nCastRange )
		then
			hEffectTarget = botTarget
			sCastMotive = "进攻"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--心火
X.ConsiderItemDesire["item_faerie_fire"] = function( hItem )

	if bot:DistanceFromFountain() < 1800 then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 300 + aetherRange
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if nMode == BOT_MODE_RETREAT
		 and bot:GetActiveModeDesire() >= BOT_MODE_DESIRE_HIGH
		 and bot:WasRecentlyDamagedByAnyHero( 3.0 )
		 and bot:OriginalGetHealth() < 90
	then
		hEffectTarget = bot
		sCastMotive = "撤退"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	--攻击
	if Fu.IsGoingOnSomeone( bot )
		and Fu.GetHP( bot ) < 0.3
		and Fu.IsValidHero( botTarget )
		and bot:WasRecentlyDamagedByAnyHero( 3.0 )
	then
		hEffectTarget = bot
		sCastMotive = "进攻"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	--自己吃
	if DotaTime() > 10 * 60
		and hItem:GetName() == "item_faerie_fire"
		and bot:GetItemInSlot( 6 ) ~= nil
		and bot:GetMaxHealth() - bot:OriginalGetHealth() > 200
	then
		hEffectTarget = bot
		sCastMotive = '自己吃'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

--大药
X.ConsiderItemDesire["item_flask"] = function( hItem )

	if bot:DistanceFromFountain() < 3000 then return BOT_ACTION_DESIRE_NONE end

	if Fu.HasDamageOverTimeDebuff(bot) then
		return BOT_ACTION_DESIRE_NONE
	end

	local nCastRange = 900
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	-- Use HP ratio: 500 missing HP is nearly dead at lv1 but trivial at lv25
	local nSelfHPrate = Fu.GetHP(bot)
	if nSelfHPrate < 0.65
		and #nInRangeEnmyList == 0
		and not bot:WasRecentlyDamagedByAnyHero( 2.2 )
		and not bot:HasModifier( "modifier_filler_heal" )
		and not bot:HasModifier( "modifier_elixer_healing" )
		and not bot:HasModifier( "modifier_flask_healing" )
		and not bot:HasModifier( "modifier_juggernaut_healing_ward_heal" )
	then
		hEffectTarget = bot
		sCastMotive = '自己吃'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	local hAllyList = Fu.GetAlliesNearLoc( bot:GetLocation(), 700 )
	local hNeedHealAlly = nil
	local nNeedHealAllyHealth = 99999
	for _, npcAlly in pairs( hAllyList )
	do
		if Fu.IsValid( npcAlly ) and npcAlly ~= bot
			and not npcAlly:HasModifier( "modifier_filler_heal" )
			and not npcAlly:HasModifier( "modifier_elixer_healing" )
			and not npcAlly:HasModifier( "modifier_flask_healing" )
			and not npcAlly:HasModifier( "modifier_juggernaut_healing_ward_heal" )
			and not npcAlly:WasRecentlyDamagedByAnyHero( 3.0 )
			and not npcAlly:IsIllusion()
			and not npcAlly:IsChanneling()
			and Fu.GetHP(npcAlly) < 0.6
		then
			if( npcAlly:OriginalGetHealth() < nNeedHealAllyHealth )
			then
				hNeedHealAlly = npcAlly
				nNeedHealAllyHealth = npcAlly:OriginalGetHealth()
			end
		end
	end
	if hNeedHealAlly ~= nil and #nInRangeEnmyList == 0
	then
		hEffectTarget = hNeedHealAlly
		sCastMotive = '给队友贴:'..Fu.Chat.GetNormName( hEffectTarget )
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

-- Healing Lotus helper (item_famango / item_great_famango / item_greater_famango)
-- All three restore HP+mana and can target allies. Differ by thresholds and priority.
-- Thresholds use REMAINING ratios (0.0-1.0) not absolute missing values, because
-- a hero at 30% HP is critical regardless of their max HP pool.
local function ConsiderHealingLotus(hItem, sLabel, nSelfHPRatio, nSelfMPRatio, nAllyHPRatio, nFountainDist, bCoresDrop, bEmergency, bPrioritizeCores)
	if bot:DistanceFromFountain() < nFountainDist then return BOT_ACTION_DESIRE_NONE end

	local sCastType = 'unit'
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, 900, true, BOT_MODE_NONE)
	local botHP = Fu.GetHP(bot)
	local botMP = bot:GetMaxMana() > 0 and (bot:GetMana() / bot:GetMaxMana()) or 1

	-- Cores drop normal/great lotus after 30min (not worth the slot late game)
	if bCoresDrop and DotaTime() > 30 * 60 and Fu.IsCore(bot) then
		return BOT_ACTION_DESIRE_NONE
	end

	-- Emergency self-use in combat (greater lotus only)
	if bEmergency then
		if botHP < 0.35 or (botHP < 0.5 and botMP < 0.3) then
			if Fu.IsRetreating(bot) or Fu.IsGoingOnSomeone(bot) or #nInRangeEnmyList >= 1 then
				return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Emergency self ('..sLabel..')'
			end
		end
	end

	-- Use on self when safe and HP or mana is below threshold
	if (botHP < nSelfHPRatio or botMP < nSelfMPRatio)
		and #nInRangeEnmyList == 0
		and not bot:WasRecentlyDamagedByAnyHero(2.2)
		and not bot:HasModifier("modifier_flask_healing")
		and not bot:HasModifier("modifier_filler_heal")
	then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Self heal ('..sLabel..')'
	end

	-- Use on nearby ally who is low on HP
	local hAllyList = Fu.GetAlliesNearLoc(bot:GetLocation(), 700)
	local hBestAlly = nil
	local nBestScore = 0
	for _, npcAlly in pairs(hAllyList) do
		if Fu.IsValid(npcAlly) and npcAlly ~= bot
			and not npcAlly:IsIllusion()
			and not npcAlly:HasModifier("modifier_flask_healing")
			and not npcAlly:HasModifier("modifier_filler_heal")
			and (bEmergency or not npcAlly:WasRecentlyDamagedByAnyHero(3.0))
		then
			local nAllyHP = npcAlly:GetHealth() / npcAlly:GetMaxHealth()
			local nAllyMP = npcAlly:GetMaxMana() > 0 and (npcAlly:GetMana() / npcAlly:GetMaxMana()) or 1
			if nAllyHP < nAllyHPRatio or nAllyMP < nAllyHPRatio then
				-- Score: lower HP = higher priority. Cores get bonus.
				local nScore = (1 - nAllyHP) + (1 - nAllyMP) * 0.5
				if bPrioritizeCores and Fu.IsCore(npcAlly) then nScore = nScore * 1.5 end
				if nScore > nBestScore then
					hBestAlly = npcAlly
					nBestScore = nScore
				end
			end
		end
	end
	if hBestAlly ~= nil and (bEmergency or #nInRangeEnmyList == 0) then
		return BOT_ACTION_DESIRE_HIGH, hBestAlly, sCastType, 'Heal ally ('..sLabel..'): '..Fu.Chat.GetNormName(hBestAlly)
	end

	return BOT_ACTION_DESIRE_NONE
end

--[[
  Ally scoring uses (1 - HP%) + (1 - MP%) * 0.5 — a hero at 20% HP and 50% MP scores much higher than one at 80% HP and 10% MP, reflecting that HP is more critical than mana.
  ┌────────────────────────┬───────┬─────────────┬───────────────────────────────┐
  │                        │ Lotus │ Great Lotus │         Greater Lotus         │
  ├────────────────────────┼───────┼─────────────┼───────────────────────────────┤
  │ Self use when HP below │ 70%   │ 60%         │ 50%                           │
  ├────────────────────────┼───────┼─────────────┼───────────────────────────────┤
  │ Self use when MP below │ 50%   │ 40%         │ 30%                           │
  ├────────────────────────┼───────┼─────────────┼───────────────────────────────┤
  │ Ally use when HP below │ 60%   │ 50%         │ 50%                           │
  ├────────────────────────┼───────┼─────────────┼───────────────────────────────┤
  │ Emergency combat use   │ no    │ no          │ yes (HP<35% or HP<50%+MP<30%) │
  ├────────────────────────┼───────┼─────────────┼───────────────────────────────┤
  │ Prioritize cores       │ no    │ no          │ yes (1.5x score)              │
  ├────────────────────────┼───────┼─────────────┼───────────────────────────────┤
  │ Cores drop after 30min │ yes   │ yes         │ no                            │
  └────────────────────────┴───────┴─────────────┴───────────────────────────────┘
]]
X.ConsiderItemDesire["item_famango"]         = function(h) return ConsiderHealingLotus(h, "lotus",         0.7, 0.5, 0.6, 3000, true,  false, false) end
X.ConsiderItemDesire["item_great_famango"]   = function(h) return ConsiderHealingLotus(h, "great lotus",   0.6, 0.4, 0.5, 3000, true,  false, false) end
X.ConsiderItemDesire["item_greater_famango"] = function(h) return ConsiderHealingLotus(h, "greater lotus", 0.5, 0.3, 0.5, 1200, false, true,  true)  end

--推推
X.ConsiderItemDesire["item_force_staff"] = function( hItem )

	local nCastRange = 550 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	if bot:HasModifier('modifier_nyx_assassin_vendetta')
	then
		return BOT_ACTION_DESIRE_NONE
	end

	-- 解开先知的树框。bug: 因为先知的树不是正常的树。GetNearbyTrees 不会返回先知的树
	if bot:HasModifier('modifier_furion_sprout_damage') then
		hEffectTarget = bot
		sCastMotive = '解开先知的树框'..Fu.Chat.GetNormName( hEffectTarget )
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	local hAllyList = Fu.GetAlliesNearLoc( bot:GetLocation(), 600 )
	for _, npcAlly in pairs( hAllyList )
	do
		if npcAlly ~= nil and npcAlly:IsAlive()
			and Fu.CanCastOnNonMagicImmune( npcAlly )
		then
			local nNearAllysEnemyList = Fu.GetNearbyHeroes(npcAlly,  1200, true, BOT_MODE_NONE )
			if #nNearAllysEnemyList >= 1
				and not npcAlly:IsInvisible()
				and npcAlly:GetActiveMode() == BOT_MODE_RETREAT
				and npcAlly:IsFacingLocation( GetAncient( team ):GetLocation(), 30 )
				and npcAlly:DistanceFromFountain() > 600
				and npcAlly:WasRecentlyDamagedByAnyHero( 4.0 )
			then
				hEffectTarget = npcAlly
				sCastMotive = '帮队友撤退'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if Fu.IsGoingOnSomeone( npcAlly )
			then
				local hAllyTarget = Fu.GetProperTarget( npcAlly )
				if Fu.IsValidHero( hAllyTarget )
					and npcAlly:IsFacingLocation( hAllyTarget:GetLocation(), 15 )
					and Fu.CanCastOnNonMagicImmune( hAllyTarget )
					and GetUnitToUnitDistance( hAllyTarget, npcAlly ) > npcAlly:GetAttackRange() + 50
					and GetUnitToUnitDistance( hAllyTarget, npcAlly ) < npcAlly:GetAttackRange() + 700
					and not hAllyTarget:IsFacingLocation( npcAlly:GetLocation(), 40 )
					and Fu.GetEnemyCount( npcAlly, 1600 ) <= 3
				then
					hEffectTarget = npcAlly
					sCastMotive = '帮队友进攻'..Fu.Chat.GetNormName( hEffectTarget )
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
				end
			end

			if Fu.IsStuck( npcAlly ) or npcAlly:HasModifier('modifier_furion_sprout_damage')
			then
				hEffectTarget = npcAlly
				sCastMotive = '队友卡地形了'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end

	end

	for _, npcAlly in pairs( hAllyList )
	do
		if npcAlly ~= nil and npcAlly:IsAlive()
			and npcAlly:GetUnitName() == "npc_dota_hero_crystal_maiden"
			and Fu.CanCastOnNonMagicImmune( npcAlly )
			and ( npcAlly:IsInvisible() or npcAlly:GetHealth() / npcAlly:GetMaxHealth() > 0.8 )
			and ( npcAlly:IsChanneling() and not npcAlly:HasModifier( "modifier_teleporting" ) )
		then
			local enemyHeroesNearbyCM = Fu.GetNearbyHeroes(npcAlly,  1200, true, BOT_MODE_NONE )
			for _, npcEnemy in pairs( enemyHeroesNearbyCM )
			do
				if npcEnemy ~= nil and npcEnemy:IsAlive()
					and Fu.CanCastOnNonMagicImmune( npcEnemy )
					and GetUnitToUnitDistance( npcEnemy, npcAlly ) > 835
					and npcAlly:IsFacingLocation( npcEnemy:GetLocation(), 30 )
				then
					hEffectTarget = npcAlly
					sCastMotive = '推冰女'
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
				end
			end
		end
	end

	if bot:DistanceFromFountain() < 2600
	then
		for _, npcEnemy in pairs( hNearbyEnemyHeroList )
		do
			if Fu.IsValidHero( npcEnemy )
				and Fu.CanCastOnMagicImmune( npcEnemy )
				and npcEnemy:IsFacingLocation( GetAncient( team ):GetLocation(), 40 )
				and GetUnitToLocationDistance( npcEnemy, GetAncient( team ):GetLocation() ) < 1200
			then
				hEffectTarget = npcEnemy
				sCastMotive = '推人入泉'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end
	
	
	--推敌人靠近自己
	if Fu.IsGoingOnSomeone(bot) and #hAllyList >= 2
	then
		if Fu.IsValidHero( botTarget )
			and Fu.IsInRange( bot, botTarget, nCastRange )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and X.IsWithoutSpellShield( botTarget )
		then
			local allyCenterLocation = Fu.GetCenterOfUnits( hAllyList )
			if botTarget:IsFacingLocation( allyCenterLocation, 28 )
				and GetUnitToLocationDistance( bot, allyCenterLocation ) >= 500
			then
				hEffectTarget = botTarget
				sCastMotive = '推敌人靠近自己'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end			
		end
	end	

	return BOT_ACTION_DESIRE_NONE

end

--绿杖
X.ConsiderItemDesire["item_ghost"] = function( hItem )

	local nCastRange = 800
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if bot:GetAttackTarget() == nil
		or bot:GetHealth() < 500
	then
		for _, npcEnemy in pairs( hNearbyEnemyHeroList )
		do
			if Fu.IsValidHero( npcEnemy )
				and Fu.CanCastOnMagicImmune( npcEnemy )
				and Fu.IsInRange( bot, npcEnemy, npcEnemy:GetAttackRange() + 100 )
				and npcEnemy:GetAttackTarget() == bot
				and bot:WasRecentlyDamagedByHero( npcEnemy, 2.0 )
				and npcEnemy:GetAttackDamage() > bot:GetAttackDamage()
			then
				hEffectTarget = npcEnemy
				sCastMotive = "撤退"..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--克雷拉斯权杖 (Crellas's Crozier - self-cast ghost form)
X.ConsiderItemDesire["item_crellas_crozier"] = function( hItem )

	local nCastRange = 800
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil

	if bot:GetAttackTarget() == nil
		or bot:GetHealth() < 500
	then
		for _, npcEnemy in pairs( hNearbyEnemyHeroList )
		do
			if Fu.IsValidHero( npcEnemy )
				and Fu.CanCastOnMagicImmune( npcEnemy )
				and Fu.IsInRange( bot, npcEnemy, npcEnemy:GetAttackRange() + 100 )
				and npcEnemy:GetAttackTarget() == bot
				and bot:WasRecentlyDamagedByHero( npcEnemy, 2.0 )
				and npcEnemy:GetAttackDamage() > bot:GetAttackDamage()
			then
				hEffectTarget = npcEnemy
				sCastMotive = "撤退"..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--微光
X.ConsiderItemDesire["item_glimmer_cape"] = function( hItem )

	local nCastRange = 800 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil


	if	bot:DistanceFromFountain() > 600
		and #hNearbyEnemyTowerList == 0
		and not bot:HasModifier( 'modifier_item_dustofappearance' )
		and not bot:HasModifier( 'modifier_slardar_amplify_damage' )
		and not bot:HasModifier( 'modifier_item_glimmer_cape' )
		and not bot:IsInvulnerable()
		and not bot:IsMagicImmune()
	then

		if bot:IsSilenced() or bot:IsRooted() or Fu.IsStunProjectileIncoming( bot, 1000 )
		then
			hEffectTarget = bot
			sCastMotive = '自己被缠绕或沉默了'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		if ( Fu.IsRetreating( bot )
				and bot:GetActiveModeDesire() >= BOT_MODE_DESIRE_HIGH
				and not bot:HasModifier("modifier_fountain_aura") )
			 or ( botTarget == nil
					and #hNearbyEnemyHeroList > 0
					and Fu.GetHP( bot ) < 0.36 + ( 0.09 * #hNearbyEnemyHeroList ) )
		then
			hEffectTarget = bot
			sCastMotive = '自己撤退'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		--------------------
		--use at npcAlly target
		--------------------
		local hAllyList = Fu.GetNearbyHeroes(bot, nCastRange, false, BOT_MODE_NONE )
		for _, npcAlly in pairs( hAllyList )
		do
			if Fu.IsValid( npcAlly )
				and not npcAlly:IsIllusion()
				and not npcAlly:IsMagicImmune()
				and not npcAlly:IsInvulnerable()
				and not npcAlly:IsInvisible()
				and npcAlly:DistanceFromFountain() > 600
				and not npcAlly:HasModifier( 'modifier_item_glimmer_cape' )
				and not npcAlly:HasModifier( 'modifier_item_dustofappearance' )
				and not npcAlly:HasModifier( 'modifier_slardar_amplify_damage' )
				and not npcAlly:HasModifier( 'modifier_arc_warden_tempest_double' )
			then
				local nNearbyAllyEnemyTowers = npcAlly:GetNearbyTowers( 888, true )
				if #nNearbyAllyEnemyTowers == 0
				then
					--retreat
					if Fu.GetHP( npcAlly ) < 0.35 + ( 0.05 * #hNearbyEnemyHeroList )
						and Fu.IsRetreating( npcAlly )
						and npcAlly:WasRecentlyDamagedByAnyHero( 4.0 )
					then
						hEffectTarget = npcAlly
						sCastMotive = '保护队友撤退:'..Fu.Chat.GetNormName( hEffectTarget )
						return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
					end

					--Disable
					if Fu.IsDisabled( npcAlly ) --debug
						or Fu.IsStunProjectileIncoming( npcAlly, 1000 )
					then
						hEffectTarget = npcAlly
						sCastMotive = '保护被控队友:'..Fu.Chat.GetNormName( hEffectTarget )
						return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
					end
				end
			end
		end

	end

	return BOT_ACTION_DESIRE_NONE

end


X.ConsiderItemDesire["item_mekansm"] = function( hItem )
	local nCastRange = 1200
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil


	local hAllyList = Fu.GetAllyList( bot, nCastRange )
	for _, npcAlly in pairs( hAllyList ) 
	do
		if npcAlly ~= nil and npcAlly:IsAlive()
			and Fu.GetHP( npcAlly ) < 0.45
			and #hNearbyEnemyHeroList > 0
		then
			hEffectTarget = npcAlly
			sCastMotive = '治疗队友'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	local needHPCount = 0
	for _, npcAlly in pairs( hAllyList )
	do
		if npcAlly ~= nil
			and npcAlly:GetMaxHealth()- npcAlly:GetHealth() > 400
		then
			needHPCount = needHPCount + 1

			if needHPCount >= 2 and npcAlly:GetHealth() / npcAlly:GetMaxHealth() < 0.55
			then
				hEffectTarget = npcAlly
				sCastMotive = '治疗二队友:'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if needHPCount >= 3
			then
				hEffectTarget = npcAlly
				sCastMotive = '治疗多个队友:'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	if bot:GetHealth() / bot:GetMaxHealth() < 0.5
		or bot:IsSilenced()
		or bot:IsRooted()
		or bot:HasModifier( "modifier_item_urn_damage" )
		or bot:HasModifier( "modifier_item_spirit_vessel_damage" )
	then
		hEffectTarget = bot
		sCastMotive = '治疗自己:'..Fu.Chat.GetNormName( hEffectTarget )
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE
end

--大鞋
X.ConsiderItemDesire["item_guardian_greaves"] = function( hItem )

	local nCastRange = 1200
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil


	local hAllyList = Fu.GetAllyList( bot, nCastRange )
	for _, npcAlly in pairs( hAllyList ) 
	do
		if npcAlly ~= nil and npcAlly:IsAlive()
			and Fu.GetHP( npcAlly ) < 0.45
			and #hNearbyEnemyHeroList > 0
		then
			hEffectTarget = npcAlly
			sCastMotive = '治疗队友'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	local needHPCount = 0
	for _, npcAlly in pairs( hAllyList )
	do
		if npcAlly ~= nil
			and npcAlly:GetMaxHealth()- npcAlly:GetHealth() > 400
		then
			needHPCount = needHPCount + 1

			if needHPCount >= 2 and npcAlly:GetHealth() / npcAlly:GetMaxHealth() < 0.55
			then
				hEffectTarget = npcAlly
				sCastMotive = '治疗二队友:'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if needHPCount >= 3
			then
				hEffectTarget = npcAlly
				sCastMotive = '治疗多个队友:'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	if bot:GetHealth() / bot:GetMaxHealth() < 0.5
		or bot:IsSilenced()
		or bot:IsRooted()
		or bot:HasModifier( "modifier_item_urn_damage" )
		or bot:HasModifier( "modifier_item_spirit_vessel_damage" )
	then
		hEffectTarget = bot
		sCastMotive = '治疗自己:'..Fu.Chat.GetNormName( hEffectTarget )
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	local nNeedMPCount = 0
	for _, npcAlly in pairs( hAllyList )
	do
		if npcAlly ~= nil
			and npcAlly:GetMaxMana()- npcAlly:GetMana() > 400
		then
			nNeedMPCount = nNeedMPCount + 1
		end

		if nNeedMPCount >= 2 and bot:GetMana() / bot:GetMaxMana() < 0.2
		then
			hEffectTarget = npcAlly
			sCastMotive = '回蓝二队友:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		if nNeedMPCount >= 3
		then
			hEffectTarget = npcAlly
			sCastMotive = '回蓝多个队友:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

	end

	local laneCreepList = bot:GetNearbyLaneCreeps( 1200, false )
	if #laneCreepList >= 9
	then
		local nAOELocation = bot:FindAoELocation( false, false, bot:GetLocation(), 100, 1100 , 0, 200 )
		if nAOELocation.count >= 6
			and GetUnitToLocationDistance( bot, nAOELocation.targetloc ) <= 200
		then
			hEffectTarget = bot
			sCastMotive = '治疗小兵们:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--点金
X.ConsiderItemDesire["item_hand_of_midas"] = function( hItem )

	local nCastRange = 990 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil


	if #hNearbyEnemyHeroList >= 1 then nCastRange = 628 end
	local hNearbyCreepList = bot:GetNearbyCreeps( nCastRange, true )
	local targetCreep = nil
	local targetCreepLV = 0

	for _, creep in pairs( hNearbyCreepList )
	do
		if Fu.IsValid( creep )
		 and not creep:IsMagicImmune()
		 and not creep:IsAncientCreep()
		then
			if creep:GetLevel() > targetCreepLV
			then
				targetCreepLV = creep:GetLevel()
				targetCreep = creep
			end
		end

	end

	if targetCreep ~= nil
	then
		hEffectTarget = targetCreep
		sCastMotive = '点金小兵:'..hEffectTarget:GetUnitName()
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

--天堂
X.ConsiderItemDesire["item_heavens_halberd"] = function( hItem )

	local nCastRange = 700 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	local targetHero = nil
	local targetHeroDamage = 0
	for _, npcEnemy in pairs( nInRangeEnmyList )
	do
		if Fu.IsValidHero( npcEnemy )
			and not npcEnemy:IsDisarmed()
			and not Fu.IsDisabled( npcEnemy )
			and Fu.CanCastOnNonMagicImmune( npcEnemy )
			and X.IsWithoutSpellShield( npcEnemy )
			and npcEnemy:GetAttackTarget() ~= nil
			and ( npcEnemy:GetPrimaryAttribute() ~= ATTRIBUTE_INTELLECT or npcEnemy:GetAttackDamage() > 180 )
		then
			local nEnemyDamage = npcEnemy:GetEstimatedDamageToTarget( false, bot, 3.0, DAMAGE_TYPE_PHYSICAL )
			if ( nEnemyDamage > targetHeroDamage )
			then
				targetHeroDamage = nEnemyDamage
				targetHero = npcEnemy
			end
		end
	end
	if targetHero ~= nil
	then
		hEffectTarget = targetHero
		sCastMotive = '缴械敌人:'..Fu.Chat.GetNormName( hEffectTarget )
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if ( bot:GetActiveMode() == BOT_MODE_ROSHAN )
	then
		local botTarget = bot:GetAttackTarget()
		if Fu.IsRoshan( botTarget )
			and not Fu.IsDisabled( botTarget )
			and not botTarget:IsDisarmed()
		then
			hEffectTarget = botTarget
			sCastMotive = '缴械肉山'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--支配
X.ConsiderItemDesire["item_helm_of_the_dominator"] = function( hItem )

	local nCastRange = 1000 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil

	for _, unit in pairs(GetUnitList(UNIT_LIST_ALLIED_CREEPS))
	do
		if Fu.IsValid(unit)
		and unit:HasModifier('modifier_dominated')
		and unit:IsAncientCreep()
		then
			return BOT_ACTION_DESIRE_NONE, hEffectTarget, 'sCastType', sCastMotive
		end
	end

	local maxHP = 0
	local hCreep = nil
	local hNearbyCreepList = bot:GetNearbyCreeps( nCastRange, true )
	if #hNearbyCreepList >= 2
	then
		for _, creep in pairs( hNearbyCreepList )
		do
			if Fu.IsValid( creep )
			then
				local nCreepHP = creep:GetHealth()
				if nCreepHP > maxHP
					and ( creep:GetHealth() / creep:GetMaxHealth() ) > 0.75
					and ( not creep:IsAncientCreep() or hItem:GetName() == "item_helm_of_the_overlord" )
					and not Fu.IsKeyWordUnit( "siege", creep )
				then
					hCreep = creep
					maxHP = nCreepHP
				end
			end
		end
	end
	if hCreep ~= nil
	then
		hEffectTarget = hCreep
		sCastMotive = '支配:'..hEffectTarget:GetUnitName()
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end


--大支配
X.ConsiderItemDesire["item_helm_of_the_overlord"] = function( hItem )

	return X.ConsiderItemDesire["item_helm_of_the_dominator"]( hItem )

end


--挑战
X.ConsiderItemDesire["item_hood_of_defiance"] = function( hItem )

	if bot:HasModifier( 'modifier_item_pipe_barrier' )
		or Fu.GetHP( bot ) > 0.88
	then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 1000
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if #nInRangeEnmyList > 0
	then
		hEffectTarget = bot
		sCastMotive = '套盾'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end



--圣洁吊坠
X.ConsiderItemDesire["item_holy_locket"] = function( hItem )

	--给队友

	return X.ConsiderItemDesire["item_magic_wand"]( hItem )

end

--大推推
X.ConsiderItemDesire["item_hurricane_pike"] = function( hItem )

	local nCastRange = 800 + aetherRange
	local nNearRange = 450 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nNearRange, true, BOT_MODE_NONE )


	if ( nMode == BOT_MODE_RETREAT and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_HIGH )
	then
		for _, npcEnemy in pairs( hNearbyEnemyHeroList )
		do
			if ( Fu.IsInRange( bot, npcEnemy, nNearRange ) 
				and Fu.CanCastOnNonMagicImmune( npcEnemy ) )
			then
				hEffectTarget = npcEnemy
				sCastMotive = '撤退了推敌人'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end

		if bot:IsFacingLocation( GetAncient( team ):GetLocation(), 20 )
			and bot:DistanceFromFountain() > 600
			and #hNearbyEnemyHeroList >= 1
		then
			hEffectTarget = bot
			sCastMotive = '撤退了推自己'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and GetUnitToUnitDistance( botTarget, bot ) > bot:GetAttackRange() + 100
			and GetUnitToUnitDistance( botTarget, bot ) < bot:GetAttackRange() + 700
			and GetUnitToUnitDistance( botTarget, bot ) < GetUnitToLocationDistance( bot, Fu.GetCorrectLoc( botTarget, 1.0 ) ) - 100
			and bot:IsFacingLocation( botTarget:GetLocation(), 20 )
			and not botTarget:IsFacingLocation( bot:GetLocation(), 120 )
			and Fu.GetEnemyCount( bot, 1600 ) <= 2
		then
			hEffectTarget = bot
			sCastMotive = "进攻"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if Fu.HasItem(bot, "item_hurricane_pike")
	then
		for _, npcEnemy in pairs( hNearbyEnemyHeroList )
		do
			if npcEnemy ~= nil
				and Fu.CanCastOnNonMagicImmune( npcEnemy )
				and GetUnitToUnitDistance( npcEnemy, bot ) <= nNearRange
				and Fu.CanCastOnNonMagicImmune( npcEnemy )
			then
				bot:SetTarget( npcEnemy )
				hEffectTarget = npcEnemy
				sCastMotive = '推开'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	local hAllyList = Fu.GetNearbyHeroes(bot, nCastRange, false, BOT_MODE_NONE )
	for _, npcAlly in pairs( hAllyList )
	do
		if npcAlly ~= nil and npcAlly:IsAlive()
			and npcAlly:GetUnitName() == "npc_dota_hero_crystal_maiden"
			and Fu.CanCastOnNonMagicImmune( npcAlly )
			and X.IsWithoutSpellShield( npcAlly )
			and ( npcAlly:IsInvisible() or npcAlly:GetHealth() / npcAlly:GetMaxHealth() > 0.8 )
			and ( npcAlly:IsChanneling() and not npcAlly:HasModifier( "modifier_teleporting" ) )
		then
			local enemyHeroesNearbyCM = Fu.GetNearbyHeroes(npcAlly,  1200, true, BOT_MODE_NONE )
			for _, npcEnemy in pairs( enemyHeroesNearbyCM )
			do
				if npcEnemy ~= nil and npcEnemy:IsAlive()
					and Fu.CanCastOnNonMagicImmune( npcEnemy )
					and GetUnitToUnitDistance( npcEnemy, npcAlly ) > 835
					and npcAlly:IsFacingLocation( npcEnemy:GetLocation(), 30 )
				then
					hEffectTarget = npcAlly
					sCastMotive = '推CM'
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
				end
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--隐刀
X.ConsiderItemDesire["item_invis_sword"] = function( hItem )

	if bot:IsInvisible()
		or #hNearbyEnemyTowerList > 0
		or bot:HasModifier( "modifier_item_dustofappearance" )
		or bot:HasModifier( "modifier_slardar_amplify_damage" )
	then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 800
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsRetreating( bot )
		and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_MODERATE
		and #hNearbyEnemyHeroList > 0
	then
		hEffectTarget = bot
		sCastMotive = '撤退了'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if Fu.GetHP( bot ) < 0.166
		and ( #hNearbyEnemyHeroList > 0 or bot:WasRecentlyDamagedByAnyHero( 5.0 ) )
	then
		hEffectTarget = bot
		sCastMotive = '残血了'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if Fu.IsGoingOnSomeone( bot )
	then
		if 	Fu.IsValidHero( botTarget )
			and Fu.CanCastOnMagicImmune( botTarget )
			and not Fu.IsInRange( bot, botTarget, botTarget:GetCurrentVisionRange() )
			and Fu.IsInRange( bot, botTarget, 2600 )
		then
			local hEnemyCreepList = bot:GetNearbyLaneCreeps( 800, true )
			if #hEnemyCreepList == 0 and #hNearbyEnemyHeroList == 0
			then
				hEffectTarget = botTarget
				sCastMotive = "进攻:"..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--莲花
X.ConsiderItemDesire["item_lotus_orb"] = function( hItem )

	local nCastRange = 1000 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nNearAllyList = Fu.GetNearbyHeroes(bot, nCastRange, false, BOT_MODE_NONE )


	for _, npcAlly in pairs( nNearAllyList )
	do
		if Fu.IsValid( npcAlly )
			and not npcAlly:IsIllusion()
			and not npcAlly:IsMagicImmune()
			and not npcAlly:IsInvulnerable()
			and not npcAlly:HasModifier( 'modifier_item_lotus_orb_active' )
			and not npcAlly:HasModifier( 'modifier_antimage_spell_shield' )
		then

			if Fu.IsUnitTargetProjectileIncoming( npcAlly, 800 )
			then
				hEffectTarget = npcAlly
				sCastMotive = '反弹弹道'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if npcAlly:IsRooted()
				or ( npcAlly:IsSilenced() and not npcAlly:HasModifier( "modifier_item_mask_of_madness_berserk" ) )
				or ( npcAlly:IsDisarmed() and not npcAlly:HasModifier( "modifier_oracle_fates_edict" ) )
			then
				hEffectTarget = npcAlly
				sCastMotive = '驱散队友:'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if Fu.IsWillBeCastUnitTargetSpell( npcAlly, 1200 )
			then
				hEffectTarget = npcAlly
				sCastMotive = '给队友反弹技能:'..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--魔棒
X.ConsiderItemDesire["item_magic_stick"] = function( hItem )

	if hItem:GetCurrentCharges() <= 0 then return BOT_ACTION_DESIRE_NONE end

	local sCastType = 'none'
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE )

	local nEnemyCount = #nInRangeEnmyList
	local nHPrate = Fu.GetHP(bot)
	local nMPrate = Fu.GetMP(bot)
	local nCharges = hItem:GetCurrentCharges()

	-- Emergency: about to die
	if nHPrate < 0.25 and nCharges >= 1 then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Stick: emergency'
	end

	-- Retreating and hurt
	if Fu.IsRetreating(bot) and nHPrate < 0.6 and nCharges >= 2 then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Stick: retreat'
	end

	-- In fight and low resources
	if nEnemyCount >= 1 and nCharges >= 1 and (nHPrate < 0.6 or nMPrate < 0.35) then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Stick: fight'
	end

	-- Proactive heal: not in danger, but hurt with decent charges
	if nCharges >= 5 and nEnemyCount == 0 and (nHPrate < 0.7 or nMPrate < 0.5) then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Stick: proactive heal'
	end

	-- Max charges (10 for stick), use to not waste
	if nCharges >= 10 and (nHPrate < 0.85 or nMPrate < 0.75) then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Stick: max charges'
	end

	return BOT_ACTION_DESIRE_NONE

end

--魔杖
X.ConsiderItemDesire["item_magic_wand"] = function( hItem )

	if hItem:GetCurrentCharges() <= 0 then return BOT_ACTION_DESIRE_NONE end

	local sCastType = 'none'
	if hItem:GetName() == 'item_holy_locket' then sCastType = 'unit' end
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE )

	local nEnemyCount = #nInRangeEnmyList
	local nHPrate = Fu.GetHP(bot)
	local nMPrate = Fu.GetMP(bot)
	local nCharges = hItem:GetCurrentCharges()
	local bRetreating = Fu.IsRetreating(bot)

	-- EMERGENCY: about to die — use with ANY charges
	if nHPrate < 0.25 and nCharges >= 1 then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Wand: emergency'
	end

	-- RETREATING: use when being chased and hurt
	if bRetreating and nHPrate < 0.6 and nCharges >= 2 then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Wand: retreat'
	end

	-- FIGHTING: use when in combat and HP or mana is low
	if nEnemyCount >= 1 and nCharges >= 1 and (nHPrate < 0.6 or nMPrate < 0.3) then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Wand: fight'
	end

	-- PROACTIVE HEAL: out of combat with decent charges, don't sit on them
	if nCharges >= 5 and nEnemyCount == 0 and (nHPrate < 0.75 or nMPrate < 0.5) then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Wand: proactive heal'
	end

	-- HIGH CHARGES: use when reasonably hurt (no enemy requirement)
	if nCharges >= 10 and (nHPrate < 0.8 or nMPrate < 0.6) then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Wand: high charges'
	end

	-- MAX CHARGES: use when capped to not waste further charges
	if nCharges >= 20 and (nHPrate < 0.9 or nMPrate < 0.75) then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'Wand: max charges'
	end

	return BOT_ACTION_DESIRE_NONE

end

--分身
X.ConsiderItemDesire["item_manta"] = function( hItem )

	local nCastRange = 800
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	local nNearbyAttackingAlliedHeroes = Fu.GetNearbyHeroes(bot, 1000, false, BOT_MODE_ATTACK )
	local nNearbyEnemyHeroes = Fu.GetNearbyHeroes(bot, 1000, true, BOT_MODE_NONE )
	local nNearbyEnemyTowers = bot:GetNearbyTowers( 800, true )
	local nNearbyEnemyBarracks = bot:GetNearbyBarracks( 600, true )
	local nNearbyAlliedCreeps = bot:GetNearbyLaneCreeps( 1000, false )
	local nNearbyEnemyCreeps = bot:GetNearbyLaneCreeps( 800, true )

	if Fu.IsPushing( bot )
	then
		if ( #nNearbyEnemyTowers >= 1 or #nNearbyEnemyBarracks >= 1 )
			and #nNearbyAlliedCreeps >= 1
		then
			hEffectTarget = bot
			sCastMotive = '推进'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if Fu.IsGoingOnSomeone( bot )
		and Fu.IsValidHero( botTarget )
		and Fu.CanCastOnMagicImmune( botTarget )
		and Fu.IsInRange( bot, botTarget, bot:GetAttackRange() + 80 )
	then
		hEffectTarget = botTarget
		sCastMotive = '进攻:'..Fu.Chat.GetNormName( hEffectTarget )
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if bot:IsRooted()
		or ( bot:IsSilenced() and not bot:HasModifier( "modifier_item_mask_of_madness_berserk" ) )
		or bot:HasModifier( 'modifier_item_solar_crest_armor_reduction' )
		or bot:HasModifier( 'modifier_item_medallion_of_courage_armor_reduction' )
		or bot:HasModifier( 'modifier_item_spirit_vessel_damage' )
		or bot:HasModifier( 'modifier_dragonknight_breathefire_reduction' )
		or bot:HasModifier( 'modifier_slardar_amplify_damage' )
		or bot:HasModifier( 'modifier_item_dustofappearance' )
	then
		hEffectTarget = bot
		sCastMotive = '解Buff'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if not bot:IsMagicImmune()
		and not bot:HasModifier( "modifier_antimage_spell_shield" )
		and not bot:HasModifier( "modifier_item_sphere_target" )
		and not bot:HasModifier( "modifier_item_lotus_orb_active" )
		and Fu.IsNotAttackProjectileIncoming( bot, 70 )
	then
		hEffectTarget = bot
		sCastMotive = '躲弹道'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if Fu.IsRetreating( bot )
		and nNearbyEnemyHeroes[1] ~= nil
		and bot:DistanceFromFountain() > 600
	then
		hEffectTarget = bot
		sCastMotive = '撤退了'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if #nNearbyEnemyCreeps >= 8
	then
		hEffectTarget = bot
		sCastMotive = '刷小兵'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if bot:WasRecentlyDamagedByAnyHero( 5.0 )
		and bot:GetHealth() / bot:GetMaxHealth() < 0.18
		and bot:DistanceFromFountain() > 800
	then
		hEffectTarget = bot
		sCastMotive = '残血了'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

--大电锤
X.ConsiderItemDesire["item_mjollnir"] = function( hItem )

	local nCastRange = 800 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	local nNearbyAllyList = Fu.GetNearbyHeroes(bot, nCastRange + 100, false, BOT_MODE_NONE);

	--团战中对被攻击频率最高的用
	if Fu.IsInTeamFight( bot, 900 )
	then
		local targetAlly = nil
		local maxTargetCount = 1
		for _, npcAlly in pairs(nNearbyAllyList)
		do
			if Fu.IsValid( npcAlly )
				and not npcAlly:IsIllusion()
				and not npcAlly:HasModifier( "modifier_item_mjollnir_static" )
			then
				local nAllyCount = 0 ;
				local nEnemyHeroes = Fu.GetNearbyHeroes(npcAlly, 1400, true, BOT_MODE_NONE);
				local nEnemyCreeps = npcAlly:GetNearbyCreeps(1000, true);
				for _, unit in pairs(nEnemyHeroes)
				do
					if unit ~= nil and unit:IsAlive()
						and unit:GetAttackTarget() == npcAlly
					then
						nAllyCount = nAllyCount + 1
					end
				end
				for _, unit in pairs(nEnemyCreeps)
				do
					if unit ~= nil and unit:IsAlive()
						and unit:GetAttackTarget() == npcAlly
					then
						nAllyCount = nAllyCount + 1
					end
				end
				if nAllyCount > maxTargetCount
				then
					maxTargetCount = nAllyCount
					targetAlly = npcAlly
				end
			end
		end

		if targetAlly ~= nil
		then
			hEffectTarget = targetAlly
			sCastMotive = '团战中套电锤给队友:'..Fu.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if Fu.IsValidHero(botTarget)
	then
		local nAllies = Fu.GetAlliesNearLoc(botTarget:GetLocation(),1400)
		if Fu.IsValid(nAllies[1])
		then
			local targetAlly = nil
			local targetDis = 9999
			for _, npcAlly in pairs(nAllies)
			do
				if Fu.IsValid( npcAlly )
					and GetUnitToUnitDistance( bot, npcAlly ) < nCastRange + 200
					and GetUnitToUnitDistance( botTarget, npcAlly ) < targetDis
					and not npcAlly:HasModifier( "modifier_item_mjollnir_static" )
				then
					targetAlly = npcAlly
					targetDis = GetUnitToUnitDistance( botTarget, npcAlly )
				end
			end
			if targetAlly ~= nil
			then
				hEffectTarget = targetAlly
				sCastMotive = '攻击前套电锤给队友:'..Fu.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	if hNearbyEnemyHeroList[1] == nil
	then
		local nAllyCreeps = bot:GetNearbyLaneCreeps(1000,false);
		local nEnemyCreeps = bot:GetNearbyLaneCreeps(1000,true);
		if #nAllyCreeps >= 1 and #nEnemyCreeps == 0
		then
			local targetCreep = nil
			local targetDis = 0
			for _, creep in pairs(nAllyCreeps)
			do
				if Fu.IsValid(creep)
					and Fu.GetHP(creep) > 0.6
					and creep:DistanceFromFountain() > targetDis
				then
					targetCreep = creep;
					targetDis = creep:DistanceFromFountain();
				end
			end
			if targetCreep ~= nil
			then
				hEffectTarget = targetCreep
				sCastMotive = '给前排小兵套上'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end


	if Fu.IsValidHero(hNearbyEnemyHeroList[1])
	   and hNearbyEnemyHeroList[1]:GetAttackTarget() == bot
	then
		if not bot:HasModifier("modifier_item_mjollnir_static")
		then
			hEffectTarget = bot
			sCastMotive = '给自己套上'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end



--疯脸
X.ConsiderItemDesire["item_mask_of_madness"] = function( hItem )

	if botName == 'npc_dota_hero_drow_ranger' then return BOT_ACTION_DESIRE_NONE end

	local nAttackTarget = bot:GetAttackTarget()
	local nCastRange = bot:GetAttackRange() + 100
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	-- local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if ( Fu.IsValid( nAttackTarget ) or Fu.IsValidBuilding( nAttackTarget ) )
		and Fu.CanBeAttacked( nAttackTarget )
		and Fu.IsInRange( bot, nAttackTarget, nCastRange )
		and ( not Fu.CanKillTarget( nAttackTarget, bot:GetAttackDamage() * 2, DAMAGE_TYPE_PHYSICAL )
			 or Fu.GetAroundTargetEnemyUnitCount( bot, nCastRange ) >= 2 )
	then
		local nEnemyHeroInView = Fu.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE )
		if nAttackTarget:IsHero()
			or ( #nEnemyHeroInView == 0 and not bot:WasRecentlyDamagedByAnyHero( 2.0 ) )
		then
			if ( #nEnemyHeroInView == 0 )
			or ( botName ~= "npc_dota_hero_sniper"
				or botName ~= "npc_dota_hero_medusa"
				or botName ~= "npc_dota_hero_faceless_void" and Fu.GetUltimateAbility(bot):GetCooldown() > 0)
			then
				bot:SetTarget( nAttackTarget )
				hEffectTarget = nAttackTarget
				sCastMotive = '启动'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--勋章
X.ConsiderItemDesire["item_medallion_of_courage"] = function( hItem )

	local nCastRange = 900 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	-- local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and not botTarget:HasModifier( 'modifier_item_solar_crest_armor_reduction' )
			and not botTarget:HasModifier( 'modifier_item_medallion_of_courage_armor_reduction' )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and not botTarget:IsAncientCreep()
			and ( Fu.IsInRange( bot, botTarget, bot:GetAttackRange() + 150 )
				or ( Fu.IsInRange( bot, botTarget, 1000 )
					and Fu.GetAroundTargetOtherAllyHeroCount( bot, botTarget, 600 ) >= 1 ) )
		then
			hEffectTarget = botTarget
			sCastMotive = '进攻:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if #hNearbyEnemyHeroList == 0
	then
		if Fu.IsValid( botTarget )
			and not botTarget:HasModifier( 'modifier_item_solar_crest_armor_reduction' )
			and not botTarget:HasModifier( 'modifier_item_medallion_of_courage_armor_reduction' )
			and not botTarget:HasModifier( "modifier_fountain_glyph" )
			and not Fu.CanKillTarget( botTarget, bot:GetAttackDamage() * 2.38, DAMAGE_TYPE_PHYSICAL )
			and Fu.IsInRange( bot, botTarget, bot:GetAttackRange() + 150 )
		then
			hEffectTarget = botTarget
			sCastMotive = '刷小兵:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	--------
	local hAllyList = Fu.GetNearbyHeroes(bot, 1000, false, BOT_MODE_NONE )
	for _, npcAlly in pairs( hAllyList )
	do
		if npcAlly ~= bot
			and Fu.IsValidHero( npcAlly )
			and not npcAlly:IsIllusion()
			and Fu.CanCastOnNonMagicImmune( npcAlly )
			and not npcAlly:HasModifier( 'modifier_item_solar_crest_armor_addition' )
			and not npcAlly:HasModifier( 'modifier_item_medallion_of_courage_armor_addition' )
			and not npcAlly:HasModifier( "modifier_arc_warden_tempest_double" )
			and ( ( Fu.IsDisabled( npcAlly ) )
				or ( Fu.GetHP( npcAlly ) < 0.35 and #hNearbyEnemyHeroList > 0 and npcAlly:WasRecentlyDamagedByAnyHero( 2.0 ) )
				or ( Fu.IsValidHero( npcAlly:GetAttackTarget() ) and GetUnitToUnitDistance( npcAlly, npcAlly:GetAttackTarget() ) <= npcAlly:GetAttackRange() and #hNearbyEnemyHeroList == 0 ) )
		then
			hEffectTarget = npcAlly
			sCastMotive = '救队友:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--银月
X.ConsiderItemDesire["item_moon_shard"] = function( hItem )
	if bot:GetNetWorth() < 18000 or Utils.CountBackpackEmptySpace(bot) >= 3
	then
		return BOT_ACTION_DESIRE_NONE
	end

	local nCastRange = 2000
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil


	if not bot:HasModifier( "modifier_item_moon_shard_consumed" )
	then
		if bot.moonSharedTime == nil --添加使用延迟避免吃得过快以为没出
		then
			bot.moonSharedTime = DotaTime()
		elseif bot.moonSharedTime < DotaTime() - 2.0
		then
			bot.moonSharedTime = nil
			hEffectTarget = bot
			sCastMotive = "自己吃"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	local targetMember = nil
	local targetDamage = 0
	for i = 1, #GetTeamPlayers( GetTeam() )
	do
		local member = GetTeamMember( i )
		if member ~= nil and member:IsAlive()
		 and member:GetAttackDamage() > targetDamage
		 and not member:HasModifier( "modifier_item_moon_shard_consumed" )
		then
			targetMember = member
			targetDamage = member:GetAttackDamage()
		end
	end
	if targetMember ~= nil
	then
		if bot.moonSharedTime == nil
		then
			bot.moonSharedTime = DotaTime()
		elseif bot.moonSharedTime < DotaTime() - 3.0
		then
			bot.moonSharedTime = nil
			hEffectTarget = targetMember
			sCastMotive = "给队友"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end


	return BOT_ACTION_DESIRE_NONE

end

--死灵书
X.ConsiderItemDesire["item_necronomicon"] = function( hItem )

	local nCastRange = 750
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if botTarget ~= nil and botTarget:IsAlive()
		and Fu.IsInRange( bot, botTarget, 1000 )
	then
		hEffectTarget = botTarget
		sCastMotive = "进攻"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

X.ConsiderItemDesire["item_necronomicon_2"] = function( hItem )

	return X.ConsiderItemDesire["item_necronomicon"]( hItem )

end

X.ConsiderItemDesire["item_necronomicon_3"] = function( hItem )

	return X.ConsiderItemDesire["item_necronomicon"]( hItem )

end

--否决
X.ConsiderItemDesire["item_nullifier"] = function( hItem )

	local nCastRange = 800 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and Fu.CanCastOnTargetAdvanced( botTarget )
			and Fu.IsInRange( botTarget, bot, nCastRange )
			and not botTarget:HasModifier( "modifier_item_nullifier_mute" )
		then
			hEffectTarget = botTarget
			sCastMotive = '进攻:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--紫苑
X.ConsiderItemDesire["item_orchid"] = function( hItem )

	local nCastRange = 900 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	for _, npcEnemy in pairs( nInRangeEnmyList )
	do
		if Fu.IsValid( npcEnemy )
			and Fu.CanCastOnNonMagicImmune( npcEnemy )
			and X.IsWithoutSpellShield( npcEnemy )
		then
			if ( npcEnemy:IsChanneling() or npcEnemy:IsCastingAbility() )
			then
				hEffectTarget = npcEnemy
				sCastMotive = "打断:"..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if Fu.IsRetreating( bot )
			then
				if not Fu.IsDisabled( npcEnemy )
				then
					hEffectTarget = npcEnemy
					sCastMotive = "撤退:"..Fu.Chat.GetNormName( hEffectTarget )
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
				end
			end
		end
	end

	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.IsInRange( bot, botTarget, nCastRange )
			and not Fu.IsDisabled( botTarget )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and X.IsWithoutSpellShield( botTarget )
		then
			hEffectTarget = botTarget
			sCastMotive = "进攻:"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--相位
X.ConsiderItemDesire["item_phase_boots"] = function( hItem )

	local sCastType = 'none'
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, 800, true, BOT_MODE_NONE )

	-- Activate whenever moving — phase boots should be used on cooldown while walking
	local actionType = bot:GetCurrentActionType()
	if actionType == BOT_ACTION_TYPE_MOVE_TO
	or actionType == BOT_ACTION_TYPE_MOVE_TO_DIRECTLY
	or actionType == BOT_ACTION_TYPE_ATTACK_MOVE
	or Fu.IsRunning(bot)
	then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'phase: moving'
	end

	-- Activate when chasing someone
	if Fu.IsGoingOnSomeone(bot) then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'phase: chasing'
	end

	-- Activate when retreating from enemies
	if Fu.IsRetreating(bot) then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'phase: retreat'
	end

	-- Activate when near an enemy hero (fight/trade)
	if #nInRangeEnmyList > 0 then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, 'phase: near enemy'
	end

	return BOT_ACTION_DESIRE_NONE

end

--笛子
X.ConsiderItemDesire["item_pipe"] = function( hItem )

	local nCastRange = 1000
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )
	local hNearbyAllyList = Fu.GetNearbyHeroes(bot, 1200, false, BOT_MODE_NONE )

	for _, npcAlly in pairs( hNearbyAllyList )
	do
		if Fu.IsValid( npcAlly )
			and not npcAlly:IsIllusion()
			and npcAlly:GetHealth() / npcAlly:GetMaxHealth() < 0.4
			and #hNearbyEnemyHeroList > 0
		then
			hEffectTarget = npcAlly
			sCastMotive = '保护队友:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	local nNearbyAllyHeroes = Fu.GetNearbyHeroes(bot, 1200, false, BOT_MODE_NONE )
	local nNearbyEnemyHeroes = Fu.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE )
	local nNearbyAllyTowers = bot:GetNearbyTowers( 1200, true )
	if ( #nNearbyAllyHeroes >= 2 and #nNearbyEnemyHeroes >= 2 )
		or ( #nNearbyEnemyHeroes >= 2 and #nNearbyAllyHeroes + #nNearbyAllyTowers >= 2 )
	then
		hEffectTarget = bot
		sCastMotive = '保护团队'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

--假腿
X.ConsiderItemDesire["item_power_treads"] = function( hItem )

	if bDeafaultItemHero then return 0 end

	local nCurrentStat = hItem:GetPowerTreadsStat()

	if nCurrentStat == ATTRIBUTE_INTELLECT
	then
		nCurrentStat = ATTRIBUTE_AGILITY
	elseif nCurrentStat == ATTRIBUTE_AGILITY
	then
		nCurrentStat = ATTRIBUTE_INTELLECT
	end

	if ( bot:HasModifier( "modifier_flask_healing" )
		 or bot:HasModifier( "modifier_clarity_potion" )
		 or bot:HasModifier( "modifier_item_urn_heal" )
		 or bot:HasModifier( "modifier_item_spirit_vessel_heal" )
		 or bot:HasModifier( "modifier_bottle_regeneration" ) )
		and not Fu.IsGoingOnSomeone( bot )
		and not Fu.IsRetreating( bot )
		and not bot:WasRecentlyDamagedByAnyHero( 5.0 )
	then
		if nCurrentStat ~= ATTRIBUTE_AGILITY then
			lastSwitchPtTime = DotaTime()
			return BOT_ACTION_DESIRE_HIGH, nil, 'none'
		end
	elseif ( Fu.IsRetreating( bot ) and not Fu.IsRealInvisible( bot ) and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_MODERATE )
			or ( Fu.IsNotAttackProjectileIncoming( bot, 1200 ) )
			or ( nMode == BOT_MODE_EVASIVE_MANEUVERS )
			or ( bot:HasModifier( "modifier_sniper_assassinate" ) )
			or ( Fu.GetHP( bot ) < 0.2 )
			or ( nCurrentStat == ATTRIBUTE_STRENGTH and Fu.GetHP( bot ) < 0.3 )
		then
			if nCurrentStat ~= ATTRIBUTE_STRENGTH then
				lastSwitchPtTime = DotaTime()
				return BOT_ACTION_DESIRE_HIGH, nil, 'none'
			end
	elseif Fu.IsGoingOnSomeone( bot ) then
		if Fu.ShouldSwitchPTStat( bot, hItem ) and lastSwitchPtTime < DotaTime() - 0.2 then
			return BOT_ACTION_DESIRE_HIGH, nil, 'none'
		end
	elseif Fu.ShouldSwitchPTStat( bot, hItem ) and lastSwitchPtTime < DotaTime() - 0.2 then
		return BOT_ACTION_DESIRE_HIGH, nil, 'none'
	end

	return BOT_ACTION_DESIRE_NONE

end

--补刀斧
local lastQuellingBladeUseTime = 0
X.ConsiderItemDesire["item_quelling_blade"] = function( hItem )

	local nCastRange = 450 + aetherRange
	local sCastType = 'tree'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )
	
	-- 解开先知的树框
	if bot:HasModifier('modifier_furion_sprout_damage') then
		local nearbyTrees = bot:GetNearbyTrees( 280 )
		if nearbyTrees ~= nil and #nearbyTrees >= 8
			and IsLocationVisible( GetTreeLocation( nearbyTrees[1] ) )
			and IsLocationPassable( GetTreeLocation( nearbyTrees[1] ) )
		then
			hEffectTarget = nearbyTrees[1]
			sCastMotive = '吃先知的树'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if DotaTime() < 0 and not thereBeMonkey
	then
		for i, id in pairs( GetTeamPlayers( GetOpposingTeam() ) )
		do
			if GetSelectedHeroName( id ) == 'npc_dota_hero_monkey_king'
			then
				thereBeMonkey = true
			end
		end
	end

	if thereBeMonkey
	then
		local theMonkeyKing = nil
		for _, enemy in pairs( hNearbyEnemyHeroList )
		do
			if enemy:IsAlive()
				and enemy:GetUnitName() == "npc_dota_hero_monkey_king"
			then
				theMonkeyKing = enemy
				break
			end
		end

		if theMonkeyKing ~= nil
			and Fu.IsInRange( bot, theMonkeyKing, nCastRange )
		then
			local nTrees = bot:GetNearbyTrees( nCastRange )
			for _, tree in pairs( nTrees )
			do
				local treeLoc = GetTreeLocation( tree )
				if GetUnitToLocationDistance( theMonkeyKing, treeLoc ) < 30
				then
					sCastMotive = '砍大圣的树'
					return BOT_ACTION_DESIRE_HIGH, tree, sCastType, sCastMotive
				end
			end
		end
	end

	--开视野
	if DotaTime() > lastQuellingBladeUseTime + 0.8
		and ( Fu.IsGoingOnSomeone( bot ) or Fu.IsFarming( bot ) or Fu.IsRetreating( bot ) )
	then
		lastQuellingBladeUseTime = DotaTime()

		local nBladeRange = 350
		local nTrees = bot:GetNearbyTrees( nBladeRange )
		local nTreeCount = #nTrees
		if nTreeCount >= 1
		then
			for treeID = 1, nTreeCount
			do
				local tree = nTrees[treeID]
				if bot:IsFacingLocation( GetTreeLocation( tree ), 7 )
				then
					sCastMotive = '开视野'
					return BOT_ACTION_DESIRE_HIGH, tree, sCastType, sCastMotive
				end
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--刷新球
-- 7.41: Refresher Orb only refreshes ABILITIES, not items.
-- Do not add logic that chains Refresher with item re-use (e.g. BKB).
X.ConsiderItemDesire["item_refresher"] = function( hItem )

	local nCastRange = 1000
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = '刷新技能'
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	-- if bot has an overrided version of CanUseRefresherShard logic:
	if BotBuild ~= nil and BotBuild.CanUseRefresherShard ~= nil and BotBuild.CanUseRefresherShard() then
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if #nInRangeEnmyList > 0
		and ( Fu.IsGoingOnSomeone( bot ) or Fu.IsInTeamFight( bot ) )
		and Fu.CanUseRefresherShard( bot )
	then
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

--刷新碎片
X.ConsiderItemDesire["item_refresher_shard"] = function( hItem )

	return X.ConsiderItemDesire["item_refresher"]( hItem )

end


--肉山A杖
X.ConsiderItemDesire["item_ultimate_scepter_roshan"] = function( hItem )

	local nCastRange = 300
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	if hItem:IsFullyCastable()
	then
		hEffectTarget = bot
		sCastMotive = '吃A杖'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

--肉山魔晶
X.ConsiderItemDesire["item_aghanims_shard_roshan"] = function( hItem )

	local nCastRange = 300
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	if hItem:IsFullyCastable()
	then
		hEffectTarget = bot
		sCastMotive = '吃魔晶'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end


--阿托斯
X.ConsiderItemDesire["item_rod_of_atos"] = function( hItem )

	local nCastRange = 1100 + aetherRange
	local sCastType = 'unit'
	if hItem:GetName() == "item_gungir" then sCastType = 'ground' end
	local hEffectTarget = nil
	local sCastMotive = nil
	local nEnemysHerosInCastRange = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	for _, npcEnemy in pairs( nEnemysHerosInCastRange )
	do
		if Fu.IsValid( npcEnemy )
			and npcEnemy:IsChanneling()
			and npcEnemy:HasModifier( "modifier_teleporting" )
			and Fu.CanCastOnNonMagicImmune( npcEnemy )
			and Fu.CanCastOnTargetAdvanced( npcEnemy )
		then
			hEffectTarget = npcEnemy
			sCastMotive = '打断:'..Fu.Chat.GetNormName( hEffectTarget )
			
			if hItem:GetName() == "item_gungir" then hEffectTarget = hEffectTarget:GetLocation() end
			
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if nMode == BOT_MODE_RETREAT
		and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_MODERATE
		and	Fu.IsValid( nEnemysHerosInCastRange[1] )
		and Fu.CanCastOnNonMagicImmune( nEnemysHerosInCastRange[1] )
		and Fu.CanCastOnTargetAdvanced( nEnemysHerosInCastRange[1] )
		and not Fu.IsDisabled( nEnemysHerosInCastRange[1] )
	then
		hEffectTarget = nEnemysHerosInCastRange[1]
		sCastMotive = '撤退了'
		
		if hItem:GetName() == "item_gungir" then hEffectTarget = hEffectTarget:GetLocation() end
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and not Fu.IsDisabled( botTarget )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and Fu.CanCastOnTargetAdvanced( botTarget )
			and GetUnitToUnitDistance( botTarget, bot ) <= nCastRange
			and Fu.IsMoving( botTarget )
		then
			hEffectTarget = botTarget
			sCastMotive = '进攻:'..Fu.Chat.GetNormName( hEffectTarget )
			if hItem:GetName() == "item_gungir" then hEffectTarget = hEffectTarget:GetLocation() end
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--撒旦
X.ConsiderItemDesire["item_satanic"] = function( hItem )

	local nCastRange = bot:GetAttackRange() + 250
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if bot:OriginalGetHealth() / bot:OriginalGetMaxHealth() < 0.62
		and #nInRangeEnmyList > 0
		and ( Fu.IsValidHero( botTarget ) and Fu.IsInRange( bot, botTarget, nCastRange )
			 or ( Fu.IsValidHero( nInRangeEnmyList[1] ) and Fu.IsInRange( bot, nInRangeEnmyList[1], nCastRange) ) )
	then
		hEffectTarget = botTarget
		sCastMotive = '进攻'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

--护符
X.ConsiderItemDesire["item_shadow_amulet"] = function( hItem )

	local nCastRange = 600 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if not bot:HasModifier( 'modifier_invisible' )
		and not bot:HasModifier( 'modifier_item_glimmer_cape' )
		and not bot:HasModifier( 'modifier_item_shadow_amulet_fade' )
		and not bot:HasModifier( 'modifier_slardar_amplify_damage' )
		and not bot:HasModifier( 'modifier_item_dustofappearance' )
	then
		local nEnemyList = Fu.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE )
		for _, enemy in pairs( nEnemyList )
		do
			if enemy:IsAlive()
				and ( enemy:GetAttackTarget() == bot or enemy:IsFacingLocation( bot:GetLocation(), 16 ) )
			then
				local nNearbyEnemyTowers = bot:GetNearbyTowers( 888, true )
				if #nNearbyEnemyTowers == 0
					and lastAmuletTime < DotaTime() - 1.28
					and not Fu.IsGoingOnSomeone(bot)
				then
					lastAmuletTime = DotaTime()
					hEffectTarget = bot
					sCastMotive = '自己用'
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
				end
			end
		end

		if bot:IsRooted()
			or Fu.IsStunProjectileIncoming( bot, 1000 )
		then
			local nNearbyEnemyTowers = bot:GetNearbyTowers( 888, true )
			if #nNearbyEnemyTowers == 0
				and lastAmuletTime < DotaTime() - 1.28
			then
				lastAmuletTime = DotaTime()
				hEffectTarget = bot
				sCastMotive = '撤退了'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	local nNearAllyList = Fu.GetNearbyHeroes(bot, 849, false, BOT_MODE_NONE )
	for _, npcAlly in pairs( nNearAllyList )
	do
		if Fu.IsValid( npcAlly )
			and npcAlly ~= bot
			and not npcAlly:IsIllusion()
			and not npcAlly:IsMagicImmune()
			and not npcAlly:IsInvisible()
			and not npcAlly:HasModifier( 'modifier_invisible' )
			and not npcAlly:HasModifier( 'modifier_item_glimmer_cape' )
			and not npcAlly:HasModifier( 'modifier_item_shadow_amulet_fade' )
			and not npcAlly:HasModifier( 'modifier_slardar_amplify_damage' )
			and not npcAlly:HasModifier( 'modifier_item_dustofappearance' )
			and ( npcAlly:IsStunned()
					or npcAlly:IsRooted()
					or Fu.IsStunProjectileIncoming( npcAlly, 1000 ) )
		then
			local nNearbyAllyEnemyTowers = npcAlly:GetNearbyTowers( 888, true )
			if #nNearbyAllyEnemyTowers == 0
			then
				hEffectTarget = npcAlly
				sCastMotive = '帮助队友隐身'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--羊刀
X.ConsiderItemDesire["item_sheepstick"] = function( hItem )

	local nCastRange = 700 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	for _, npcEnemy in pairs( nInRangeEnmyList )
	do
		if Fu.IsValid( npcEnemy )
			and Fu.CanCastOnNonMagicImmune( npcEnemy )
			and X.IsWithoutSpellShield( npcEnemy )
		then
			if ( npcEnemy:IsChanneling() or npcEnemy:IsCastingAbility() )
			then
				hEffectTarget = npcEnemy
				sCastMotive = "打断:"..Fu.Chat.GetNormName( hEffectTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if Fu.IsRetreating( bot )
			then
				if not Fu.IsDisabled( npcEnemy )
					and not npcEnemy:IsDisarmed()
				then
					hEffectTarget = npcEnemy
					sCastMotive = "撤退:"..Fu.Chat.GetNormName( hEffectTarget )
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
				end
			end
		end
	end

	if Fu.IsGoingOnSomeone( bot )
	then
		if	Fu.IsValidHero( botTarget )
			and Fu.IsInRange( bot, botTarget, nCastRange )
			and not Fu.IsDisabled( botTarget )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and X.IsWithoutSpellShield( botTarget )
		then
			hEffectTarget = botTarget
			sCastMotive = "进攻:"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--希瓦
X.ConsiderItemDesire["item_shivas_guard"] = function( hItem )

	local nCastRange = 800
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange + 50, true, BOT_MODE_NONE )


	local hNearbyCreepList = bot:GetNearbyCreeps( nCastRange, true )
	if #hNearbyCreepList >= 6
		or #nInRangeEnmyList >= 1
	then
		hEffectTarget = bot
		sCastMotive = '启动希瓦'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

--大隐刀
X.ConsiderItemDesire["item_silver_edge"] = function( hItem )

	local nCastRange = 1600
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	--破被动
	if Fu.IsGoingOnSomeone( bot )
		and not bot:HasModifier( 'modifier_slardar_amplify_damage' )
		and not bot:HasModifier( 'modifier_item_dustofappearance' )
		and #hNearbyEnemyTowerList == 0
	then
		if Fu.IsValidHero( botTarget )
			and Fu.IsInRange( bot, botTarget, 2400 )
			and Fu.CanCastOnMagicImmune( botTarget )
		then
			local nearTargetTower = botTarget:GetNearbyTowers( 888, false )
			if #nearTargetTower == 0
			then
				hEffectTarget = botTarget
				sCastMotive = '破坏被动:'..Fu.Chat.GetNormName( botTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return X.ConsiderItemDesire["item_invis_sword"]( hItem )

end

--大勋章
X.ConsiderItemDesire["item_solar_crest"] = function( hItem )

	local nCastRange = 1000
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local hAllyList = Fu.GetAlliesNearLoc(bot:GetLocation(), 1000)

	for _, npcAlly in pairs(hAllyList)
	do
		if Fu.IsValidHero( npcAlly )
		and Fu.IsInRange( bot, npcAlly, nCastRange )
		and not npcAlly:HasModifier( 'modifier_legion_commander_press_the_attack' )
		and not npcAlly:IsMagicImmune()
		and not npcAlly:IsInvulnerable()
		and npcAlly:CanBeSeen()
		then
			if not npcAlly:IsBot()
			and npcAlly:GetAttackTarget() ~= nil
			and npcAlly:GetMaxHealth() - npcAlly:GetHealth() >= 120
			then
				hEffectTarget = npcAlly
				sCastMotive = 'Solar Crest'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if Fu.IsGoingOnSomeone(npcAlly)
			then
				local allyTarget = Fu.GetProperTarget(npcAlly)

				if Fu.IsValidHero(allyTarget)
				and npcAlly:IsFacingLocation( allyTarget:GetLocation(), 20)
				and Fu.IsInRange(npcAlly, allyTarget, npcAlly:GetAttackRange() + 100)
				then
					hEffectTarget = npcAlly
					sCastMotive = 'Solar Crest'
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
				end
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--林肯
X.ConsiderItemDesire["item_sphere"] = function( hItem )

	local nCastRange = 700 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )
	local nNearAllyList = Fu.GetNearbyHeroes(bot, nCastRange, false, BOT_MODE_NONE )


	--对可能被作为敌方目标的队友使用
	for _, npcAlly in pairs( nNearAllyList )
	do
		if Fu.IsValidHero( npcAlly )
			and npcAlly ~= bot
			and not npcAlly:IsMagicImmune()
			and not npcAlly:IsInvulnerable()
			and not npcAlly:IsIllusion()
			and not npcAlly:HasModifier( "modifier_item_sphere_target" )
			and not npcAlly:HasModifier( 'modifier_antimage_spell_shield' )
			and ( Fu.IsUnitTargetProjectileIncoming( npcAlly, 800 )
				 or Fu.IsWillBeCastUnitTargetSpell( npcAlly, 1200 )
				 or bot:GetHealth() < 150 )
		then
			hEffectTarget = npcAlly
			sCastMotive = '帮助队友'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end


	if Fu.IsValidHero( botTarget )
		and Fu.IsInRange( bot, botTarget, 2400 )
		and not Fu.IsInRange( bot, botTarget, 800 )
	then
		if #nNearAllyList >= 2
		then
			local targetAlly = nil
			local targetDistance = 9999
			for _, npcAlly in pairs( nNearAllyList )
			do
				if npcAlly ~= bot
					and not npcAlly:IsIllusion()
					and Fu.IsInRange( npcAlly, botTarget, targetDistance )
					and not npcAlly:HasModifier( "modifier_item_sphere_target" )
					and not npcAlly:HasModifier( 'modifier_antimage_spell_shield' )
				then
					targetAlly = npcAlly
					targetDistance = GetUnitToUnitDistance( botTarget, npcAlly )
					if Fu.IsHumanPlayer( npcAlly ) then break end
				end
			end
			if targetAlly ~= nil
			then
				hEffectTarget = targetAlly
				sCastMotive = '先给前排套上'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--大骨灰
X.ConsiderItemDesire["item_spirit_vessel"] = function( hItem )

	return X.ConsiderItemDesire["item_urn_of_shadows"]( hItem )

end


--精华蒸馏器
X.ConsiderItemDesire["item_essence_distiller"] = function( hItem )

	if hItem:GetCurrentCharges() == 0 then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 950 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget ) and
			((Fu.CanCastOnNonMagicImmune( botTarget )
				and Fu.IsInRange( bot, botTarget, nCastRange )
				and not botTarget:HasModifier( "modifier_item_urn_damage" )
				and not botTarget:HasModifier( "modifier_item_spirit_vessel_damage" )
				and not botTarget:HasModifier( "modifier_item_essence_distiller_damage" )
				and not botTarget:HasModifier( "modifier_arc_warden_tempest_double" )
				and ( Fu.GetHP( botTarget ) < 0.95 or Fu.IsInRange( bot, botTarget, 700 ) ))
			or botTarget:HasModifier( "modifier_invoker_cold_snap_freeze" )
		) then
			hEffectTarget = botTarget
			sCastMotive = "进攻:"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if bot:GetActiveMode() ~= BOT_MODE_ROSHAN
	then
		local hAllyList = Fu.GetNearbyHeroes(bot, nCastRange + 80, false, BOT_MODE_NONE )
		local hNeedHealAlly = nil
		local nNeedHealAllyHealth = 99999
		for _, npcAlly in pairs( hAllyList )
		do
			if Fu.IsValid( npcAlly )
				and not npcAlly:IsIllusion()
				and npcAlly:DistanceFromFountain() > 800
				and Fu.CanCastOnNonMagicImmune( npcAlly )
				and not npcAlly:WasRecentlyDamagedByAnyHero( 3.1 )
				and not npcAlly:HasModifier( "modifier_item_spirit_vessel_heal" )
				and not npcAlly:HasModifier( "modifier_item_urn_heal" )
				and not npcAlly:HasModifier( "modifier_item_essence_distiller_heal" )
				and not npcAlly:HasModifier( "modifier_fountain_aura" )
				and not npcAlly:HasModifier( "modifier_arc_warden_tempest_double" )
				and npcAlly:OriginalGetMaxHealth() - npcAlly:OriginalGetHealth() > 450
				and #hNearbyEnemyHeroList == 0
			then
				if( npcAlly:OriginalGetHealth() < nNeedHealAllyHealth )
				then
					hNeedHealAlly = npcAlly
					nNeedHealAllyHealth = npcAlly:OriginalGetHealth()
				end
			end
		end

		if( hNeedHealAlly ~= nil )
		then
			hEffectTarget = hNeedHealAlly
			sCastMotive = '治疗:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--吃树
X.ConsiderItemDesire["item_tango"] = function( hItem )
	if bot:DistanceFromFountain() < 3300 or bot:HasModifier( "modifier_tango_heal" ) then return BOT_ACTION_DESIRE_NONE end
	if bot._lastTangoUseTime and DotaTime() - bot._lastTangoUseTime < 16 then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 300 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil


	--share tango
	local tCharge = hItem:GetCurrentCharges()
	if	bot:GetLevel() <= 12
			and ( #hNearbyEnemyHeroList == 0 or nMode == BOT_MODE_LANING )
			and tCharge >= 1
			and DotaTime() > 10
			and DotaTime() > Fu.Role['fLastGiveTangoTime'] + 40.0
		then
			local hAllyList = Fu.GetNearbyHeroes(bot, 800, false, BOT_MODE_NONE )
			for _, npcAlly in pairs( hAllyList )
			do
				if npcAlly ~= bot
				then
					local tangoSlot = npcAlly:FindItemSlot( 'item_tango' )
					if tangoSlot == -1
						and not npcAlly:IsIllusion()
						and npcAlly:OriginalGetMaxHealth() - npcAlly:OriginalGetHealth() > 200
						and not npcAlly:HasModifier( "modifier_tango_heal" )
						and not npcAlly:HasModifier( "modifier_arc_warden_tempest_double" )
						and not Fu.IsMeepoClone(bot)
						and not Fu.IsMeepoClone(npcAlly)
						and Fu.Item.GetItemCount( npcAlly, "item_tango_single" ) == 0
						and Fu.Item.GetEmptyInventoryAmount( npcAlly ) >= 4
					then
						Fu.Role['fLastGiveTangoTime'] = DotaTime()
						hEffectTarget = npcAlly
						sCastMotive = '分享队友吃树'
						return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
					end
				end
			end
	end

	local hTangoSingle = Fu.IsItemAvailable( 'item_tango_single' )
	if hTangoSingle ~= nil and hTangoSingle:IsFullyCastable() then return 0 end

	return X.ConsiderItemDesire["item_tango_single"]( hItem )

end

X.ConsiderItemDesire["item_tango_single"] = function( hItem )

	if bot:DistanceFromFountain() < 3300 or bot:HasModifier( "modifier_tango_heal" ) then return 0 end
	if bot._lastTangoUseTime and DotaTime() - bot._lastTangoUseTime < 16 then return 0 end

	local nCastRange = 300 + aetherRange
	local sCastType = 'tree'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nUseTangoLostHealth = ( hItem:GetName() == 'item_tango' ) and 200 or 160
	local nLostHealth = bot:OriginalGetMaxHealth() - bot:OriginalGetHealth()

	-- 解开先知的树框。bug: 因为先知的树不是正常的树。GetNearbyTrees 不会返回先知的树，此方式行不通
	if bot:HasModifier('modifier_furion_sprout_damage') then
		local nearbyTrees = bot:GetNearbyTrees( 280 )
		if nearbyTrees ~= nil and #nearbyTrees >= 8
			and IsLocationVisible( GetTreeLocation( nearbyTrees[1] ) )
			and IsLocationPassable( GetTreeLocation( nearbyTrees[1] ) )
		then
			hEffectTarget = nearbyTrees[1]
			sCastMotive = '吃先知的树'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end
	
	-- Allow tango use even with a target — only skip if flask/ward heal is active
	if not bot:HasModifier( "modifier_flask_healing" )
		and not bot:HasModifier( "modifier_juggernaut_healing_ward_heal" )
	then
		local trees = bot:GetNearbyTrees( 800 )
		local targetTree = trees[1]
		local nearEnemyList = Fu.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE )
		local nearestEnemy = nearEnemyList[1]
		local nearTowerList = bot:GetNearbyTowers( 1400, true )
		local nearestTower = nearTowerList[1]
		-- Use HP ratio for early game (200 missing HP = nearly dead at lv1)
		local nHPrate = Fu.GetHP(bot)
		local bSafeToEat = #nearEnemyList == 0 or (nearestEnemy ~= nil and not Fu.IsInRange( bot, nearestEnemy, 400 ))

		-- Proactive heal: eat a tree when missing 350+ HP
		if targetTree ~= nil and nLostHealth >= 350 and bSafeToEat then
			local targetTreeLoc = GetTreeLocation( targetTree )
			if IsLocationVisible( targetTreeLoc )
				and IsLocationPassable( targetTreeLoc )
				and ( #nearTowerList == 0 or GetUnitToLocationDistance( nearestTower, targetTreeLoc ) > 920 )
			then
				hEffectTarget = targetTree
				sCastMotive = 'proactive heal'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end

		-- Standard eat: missing enough flat HP and safe
		if targetTree ~= nil
		then
			local targetTreeLoc = GetTreeLocation( targetTree )
			if nLostHealth > nUseTangoLostHealth
				and IsLocationVisible( targetTreeLoc )
				and IsLocationPassable( targetTreeLoc )
				and ( #nearEnemyList == 0 or not Fu.IsInRange( bot, nearestEnemy, 800 ) )
				and ( #nearEnemyList == 0 or GetUnitToLocationDistance( bot, targetTreeLoc ) * 1.6 < GetUnitToUnitDistance( bot, nearestEnemy ) )
				and ( #nearTowerList == 0 or GetUnitToLocationDistance( nearestTower, targetTreeLoc ) > 920 )
			then
				hEffectTarget = targetTree
				sCastMotive = '800码内的树'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end


		-- Eat under allied tower
		local nAllyTowerList = bot:GetNearbyTowers( 1100, false )
		if #nAllyTowerList >= 1
			and nLostHealth > nUseTangoLostHealth + 20
		then
			local nAllyTower = nAllyTowerList[1]
			if nAllyTower ~= nil
			then
				local nFindTreeDistance = 1100 - GetUnitToUnitDistance( bot, nAllyTower )
				local nearTowerTrees = bot:GetNearbyTrees( nFindTreeDistance )
				local targetTree = nearTowerTrees[1]

				if targetTree ~= nil
				then
					local targetTreeLoc = GetTreeLocation( targetTree )
					if IsLocationVisible( targetTreeLoc )
						and IsLocationPassable( targetTreeLoc )
					then
						hEffectTarget = targetTree
						sCastMotive = '吃塔下的树'
						return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
					end
				end
			end
		end


		-- Eat nearby tree (close range)
		local nearbyTrees = bot:GetNearbyTrees( 280 )
		if nearbyTrees[1] ~= nil
			and IsLocationVisible( GetTreeLocation( nearbyTrees[1] ) )
			and IsLocationPassable( GetTreeLocation( nearbyTrees[1] ) )
		then
			if nLostHealth > nUseTangoLostHealth
			then
				hEffectTarget = nearbyTrees[1]
				sCastMotive = '近处的树'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if nLostHealth > nUseTangoLostHealth * 0.38
				and bot:WasRecentlyDamagedByAnyHero( 2.0 )
			then
				hEffectTarget = nearbyTrees[1]
				sCastMotive = '提前吃树'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	if DotaTime() > 4 * 60 + 30 and botTarget == nil
		and hItem:GetName() == 'item_tango_single'
		and bot:DistanceFromFountain() > 3000
		and nMode ~= BOT_MODE_RUNE
	then
		local tCount = Fu.Item.GetItemCount( bot, "item_tango_single" )
		local hNearbyEnemyHeroList = Fu.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE )
		if tCount >= 2
		then
			local trees = bot:GetNearbyTrees( 1200 )
			if trees[1] ~= nil
				and IsLocationVisible( GetTreeLocation( trees[1] ) )
				and IsLocationPassable( GetTreeLocation( trees[1] ) )
				and #hNearbyEnemyHeroList == 0
			then
				hEffectTarget = trees[1]
				sCastMotive = '消耗共享吃树'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end

		if DotaTime() > 7 * 60 + 30
		then
			local trees = bot:GetNearbyTrees( 1200 )
			if trees[1] ~= nil
				and IsLocationVisible( GetTreeLocation( trees[1] ) )
				and IsLocationPassable( GetTreeLocation( trees[1] ) )
				and nLostHealth > 60
				and #hNearbyEnemyHeroList == 0
			then
				hEffectTarget = trees[1]
				sCastMotive = '用掉共享吃树'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end

	end

	return BOT_ACTION_DESIRE_NONE

end

--经验书
X.ConsiderItemDesire["item_tome_of_knowledge"] = function( hItem )

	local nCastRange = 300
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	if hItem:IsFullyCastable()
	then
		hEffectTarget = bot
		sCastMotive = '读书'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end


function X.GetLaningTPLocation( bot, nMinTPDistance, botLocation )

	-- overridding for mid only modes
	if GetGameMode() == GAMEMODE_1V1MID or GetGameMode() == GAMEMODE_MO then
		return nil, false
	end

	local laneToTP
	local tp = false
	-- LAN: engine-assigned lane (reflects !pos swaps in sandbox where
	-- RoleAssignment doesn't propagate). Online: position-derived lane
	-- (stable; Valve's dynamic balancer flips GetAssignedLane in turbo).
	if IsLanMode and IsLanMode() then
		local assigned = bot:GetAssignedLane()
		if assigned == LANE_TOP or assigned == LANE_MID or assigned == LANE_BOT then
			laneToTP = assigned
		end
	end
	if laneToTP == nil then
		local position = Fu.GetPosition(bot)
		if team == TEAM_RADIANT then
			if position == 1 then
				laneToTP = LANE_BOT
			elseif position == 2 then
				laneToTP = LANE_MID
			elseif position == 3 or position == 4 then
				laneToTP = LANE_TOP
			elseif position == 5 then
				laneToTP = LANE_BOT
			end
		elseif team == TEAM_DIRE then
			if position == 1 then
				laneToTP = LANE_TOP
			elseif position == 2 then
				laneToTP = LANE_MID
			elseif position == 3 or position == 4 then
				laneToTP = LANE_BOT
			elseif position == 5 then
				laneToTP = LANE_TOP
			end
		end
	end

	local botAmount = GetAmountAlongLane(laneToTP, botLocation)
	local laneFront = GetLaneFrontAmount(team, laneToTP, false)
	if botAmount.distance > nMinTPDistance
	or botAmount.amount < laneFront / 5
	then
		tp = true
	end

	local _ln = {[LANE_TOP]='top',[LANE_MID]='mid',[LANE_BOT]='bot'}
	if tp then
		log('[TP-DIAG laning] %s pos=%s assigned=%s chose=%s lan=%s',
			bot:GetUnitName(), tostring(Fu.GetPosition(bot)),
			tostring(_ln[bot:GetAssignedLane()] or bot:GetAssignedLane()),
			tostring(_ln[laneToTP] or laneToTP),
			tostring(IsLanMode and IsLanMode()))
	end
	return GetLaneFrontLocation(team, laneToTP, 100), tp
end

function X.GetDefendTPLocation( nLane )

	return GetLaneFrontLocation( team, nLane, -950 )

end

function X.GetPushTPLocation( nLane )

	local laneFront = GetLaneFrontLocation( team, nLane, 0 )
	local bestTpLoc = Fu.GetNearbyLocationToTp( laneFront )
	if Fu.GetLocationToLocationDistance( laneFront, bestTpLoc ) < 2000
	then
		return bestTpLoc
	end

end


function X.CanJuke()

	local allyTowers = bot:GetNearbyTowers( 350, false )

	if allyTowers[1] ~= nil
		and allyTowers[1]:DistanceFromFountain() > bot:DistanceFromFountain() + 100
		and Fu.GetEnemyCount( bot, 700 ) == 0
	then return true end

	if Fu.GetModifierTime(bot, 'modifier_dazzle_shallow_grave') > 3.0
		or Fu.GetModifierTime(bot, 'modifier_oracle_false_promise_timer') > 3.0
	then return true end

	local enemyPids = GetTeamPlayers( GetOpposingTeam() )

	local heroHG = GetHeightLevel( bot:GetLocation() )
	for i = 1, #enemyPids
	do
		local info = GetHeroLastSeenInfo( enemyPids[i] )
		if info ~= nil then
			local dInfo = info[1]
			if dInfo ~= nil
				and dInfo.time_since_seen < 2.0
			then
				if GetUnitToLocationDistance( bot, dInfo.location ) < 1300
					and GetHeightLevel( dInfo.location ) < heroHG
				then
					return false
				end

				if GetUnitToLocationDistance( bot, dInfo.location ) < 600
				then
					local hNearbyEnemyHeroList = Fu.GetNearbyHeroes(bot, 600, true, BOT_MODE_NONE )
					if #hNearbyEnemyHeroList == 0
					then
						return false
					end
				end
			end
		end
	end

	local totalDamage = 0
	local nEnemies = Fu.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE )
	for _, enemy in pairs( nEnemies )
	do
		local enemyDamage = enemy:GetEstimatedDamageToTarget( true, bot, 4.0, DAMAGE_TYPE_ALL )
		totalDamage = totalDamage + enemyDamage
		if bot:OriginalGetHealth() <= totalDamage
		then
			return false
		end
	end

	return true

end


function X.GetNumHeroWithinRange( nRange )

	local enemyPids = GetTeamPlayers( GetOpposingTeam() )

	local cHeroes = 0
	for i = 1, #enemyPids
	do
		local info = GetHeroLastSeenInfo( enemyPids[i] )
		if info ~= nil then
			local dInfo = info[1]
			if dInfo ~= nil and dInfo.time_since_seen < 2.0
				and GetUnitToLocationDistance( bot, dInfo.location ) < nRange
			then
				cHeroes = cHeroes + 1
			end
		end
	end

	return cHeroes

end


function X.IsFarmingAlways( bot )

	local nTarget = bot:GetAttackTarget()
	if Fu.IsValid( nTarget )
		and nTarget:GetTeam() == TEAM_NEUTRAL
		and not Fu.IsRoshan( nTarget )
		and not Fu.IsKeyWordUnit( "warlock", nTarget )
		and X.GetNumEnemyNearby( GetAncient( team ) ) >= 2
	then
		return true
	end

	local nNearAllyList = Fu.GetNearbyHeroes(bot, 800, false, BOT_MODE_NONE )
	if Fu.IsValid( nTarget )
		and nTarget:IsAncientCreep()
		and not Fu.IsRoshan( nTarget )
		and not Fu.IsKeyWordUnit( "warlock", nTarget )
		and bot:GetPrimaryAttribute() == ATTRIBUTE_INTELLECT
		and botName ~= 'npc_dota_hero_ogre_magi'
		and #nNearAllyList < 2
	then
		return true
	end

	if X.GetNumEnemyNearby( GetAncient( team ) ) >= 4
		and bot:DistanceFromFountain() >= 4800
		and #nNearAllyList < 2
	then
		return true
	end

	return false
end

function X.IsBaseTowerDestroyed()

	for i = 9, 10, 1
	do
		local tower = GetTower( team, i )
		if tower == nil
			or tower:GetHealth() / tower:GetMaxHealth() < 0.99
		then
			return true
		end
	end

	return false

end

--TP
if bot.useProphetTP == nil then bot.useProphetTP = false end
if bot.ProphetTPLocation == nil then bot.ProphetTPLocation = bot:GetLocation() end
X.ConsiderItemDesire["item_tpscroll"] = function( hItem )

	if nMode == BOT_MODE_RUNE
		or ( bot:IsRooted() )
		or ( bot:HasModifier( "modifier_item_armlet_unholy_strength" ) )
		or ( bot:HasModifier( "modifier_kunkka_x_marks_the_spot" ) )
		or ( bot:HasModifier( "modifier_teleporting" ) )
		or ( bot:HasModifier( "modifier_sniper_assassinate" ) )
		or ( bot:HasModifier( "modifier_viper_nethertoxin" ) )
		or ( bot:HasModifier( "modifier_oracle_false_promise_timer" ) and Fu.GetModifierTime( bot, "modifier_oracle_false_promise_timer" ) <= 3.2 )
		or ( bot:HasModifier( "modifier_jakiro_macropyre_burn" ) and Fu.GetModifierTime( bot, "modifier_jakiro_macropyre_burn" ) >= 1.4 )
		or ( bot:HasModifier( "modifier_arc_warden_tempest_double" ) and bot:GetRemainingLifespan() < 3.3 )
		or (Fu.IsDoingRoshan(bot) and GetUnitToLocationDistance(bot, Fu.GetCurrentRoshanLocation()) <= 2800)
		or (bot._roshDipActive and bot:IsAlive() and GetUnitToLocationDistance(bot, Fu.GetCurrentRoshanLocation()) <= 3000)
		or (Fu.IsDoingTormentor(bot) and GetUnitToLocationDistance(bot, Fu.GetTormentorLocation(GetTeam())) <= 2800)
	then return BOT_ACTION_DESIRE_NONE end

	if bot:GetHealth() < 240
	then
		local nProDamage = Fu.GetAttackProjectileDamageByRange( bot, 1600 ) * 2
		if bot:GetHealth() < bot:GetActualIncomingDamage( nProDamage, DAMAGE_TYPE_PHYSICAL )
		then return BOT_ACTION_DESIRE_NONE end
	end

	if bot:HasModifier('modifier_spirit_breaker_charge_of_darkness')
	or bot.healInBase
	then
		return BOT_ACTION_DESIRE_NONE
	end

	local nNearbyEnemyTowers = bot:GetNearbyTowers( 888, true )
	if #nNearbyEnemyTowers > 0 then return BOT_ACTION_DESIRE_NONE end

	local tpLoc = nil
	local sCastType = 'ground'
	local hEffectTarget = nil
	local sCastMotive = nil

	local nMinTPDistance = 5500
	local nMode = bot:GetActiveMode()
	local nModeDesire = bot:GetActiveModeDesire()
	local botLocation = bot:GetLocation()
	local botHP = Fu.GetHP( bot )
	local botMP = Fu.GetMP( bot )
	local nEnemyCount = X.GetNumHeroWithinRange( 1600 )
	local nAllyCount = Fu.GetAllyCount( bot, 1600 )
	local itemFlask = Fu.IsItemAvailable( "item_flask" )

	if bot:GetLevel() > 12 and bot:DistanceFromFountain() < 600 then nMinTPDistance = nMinTPDistance + 600 end

	-- Universal fountain TP: after respawn or healing, TP to assigned lane/push lane.
	-- This catches cases where no specific mode triggers TP (low desire, idle, etc.)
	-- Safety: check enemies at TP destination to avoid TPing into a death trap.
	if bot:DistanceFromFountain() < 1500
	and botHP > 0.75
	and nEnemyCount == 0
	and not bot:HasModifier("modifier_teleporting")
	and DotaTime() > 15
	then
		-- Early game (<10min): always TP to role-based lane — don't cross-lane
		-- bot:GetAssignedLane() is unreliable (Valve reassigns), so use position/role
		-- After 10min: pick TP lane based on active mode
		local tpLane = X.GetLaneByPosition(bot)

		if not Fu.IsInLaningPhase() and DotaTime() > 10 * 60 then
			if nMode == BOT_MODE_DEFEND_TOWER_TOP then tpLane = LANE_TOP
			elseif nMode == BOT_MODE_DEFEND_TOWER_MID then tpLane = LANE_MID
			elseif nMode == BOT_MODE_DEFEND_TOWER_BOT then tpLane = LANE_BOT
			elseif nMode == BOT_MODE_PUSH_TOWER_TOP then tpLane = LANE_TOP
			elseif nMode == BOT_MODE_PUSH_TOWER_MID then tpLane = LANE_MID
			elseif nMode == BOT_MODE_PUSH_TOWER_BOT then tpLane = LANE_BOT
			elseif bot.laneToDefend ~= nil then tpLane = bot.laneToDefend
			else
				-- No mode set — find lane with most enemy presence
				local bestEnemies = 0
				for _, checkLane in pairs({LANE_TOP, LANE_MID, LANE_BOT}) do
					local laneFront = GetLaneFrontLocation(GetOpposingTeam(), checkLane, 0)
					local enemiesAtLane = Fu.GetLastSeenEnemiesNearLoc(laneFront, 800)
					if #enemiesAtLane > bestEnemies then
						bestEnemies = #enemiesAtLane
						tpLane = checkLane
					end
				end
			end
		end

		local tpTarget = GetLaneFrontLocation(GetTeam(), tpLane, -500)
		local _laneNames = {[LANE_TOP]='top',[LANE_MID]='mid',[LANE_BOT]='bot'}
		log('[TP-DIAG fountain] %s pos=%s assigned=%s chose=%s mode=%s lan=%s',
			botName, tostring(Fu.GetPosition(bot)),
			tostring(_laneNames[bot:GetAssignedLane()] or bot:GetAssignedLane()),
			tostring(_laneNames[tpLane] or tpLane),
			tostring(nMode), tostring(IsLanMode and IsLanMode()))
		if tpTarget ~= nil and GetUnitToLocationDistance(bot, tpTarget) > 3500 then

			local laneNames = {[LANE_TOP] = 'top', [LANE_MID] = 'mid', [LANE_BOT] = 'bot'}
			-- log('[TP] ' .. botName .. ' fountain TP to ' .. (laneNames[tpLane] or '?') .. ' (pos: ' .. tostring(Fu.GetPosition(bot)) .. ', assigned: ' .. (laneNames[bot:GetAssignedLane()] or '?') .. ', mode: ' .. tostring(nMode) .. ', laning: ' .. tostring(Fu.IsInLaningPhase()) .. ')')

			local enemiesAtDest = Fu.GetLastSeenEnemiesNearLoc(tpTarget, 1600)
			local alliesAtDest = Fu.GetAlliesNearLoc(tpTarget, 1600)
			if #enemiesAtDest <= 1 or #alliesAtDest >= #enemiesAtDest then
				return BOT_ACTION_DESIRE_HIGH, tpTarget, sCastType, 'fountain TP out'
			end
			-- Destination dangerous — TP further back
			local safeLoc = GetLaneFrontLocation(GetTeam(), tpLane, -1500)
			if GetUnitToLocationDistance(bot, safeLoc) > 3500 then
				return BOT_ACTION_DESIRE_HIGH, safeLoc, sCastType, 'fountain TP safe'
			end
		end
	end

	if nMode == BOT_MODE_LANING
	then
		hEffectTarget, shouldTp = X.GetLaningTPLocation(bot, nMinTPDistance, botLocation)
		sCastMotive = '出去发育'
		if shouldTp
		then
			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	-- Go complete items
	if X.IsInvFull(bot) and X.GetNumStashItem(bot) >= 1
	and ((bot:GetStashValue() >= 1200 and X.IsThereRecipeInStash(bot)) or (bot:GetStashValue() >= 2000 and bot:GetGold() > 1100))
	and not Fu.IsPushing(bot) and bot:GetActiveMode() ~= BOT_MODE_ATTACK
	and not Fu.IsInTeamFight(bot, 1200)
	and not Fu.Utils.IsTeamPushingSecondTierOrHighGround(bot)
	and nEnemyCount == 0
	then
		hEffectTarget = Fu.GetTeamFountain()
		sCastMotive = '撤退:1'

		if botName == 'npc_dota_hero_furion'
		then
			local Teleportation = bot:GetAbilityByName('furion_teleportation')
			if Teleportation:IsTrained()
			and Teleportation:IsFullyCastable()
			then
				bot.useProphetTP = true
				bot.ProphetTPLocation = hEffectTarget
				return BOT_ACTION_DESIRE_NONE
			end
		end

		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	-- Roshan
	if Fu.IsDoingRoshan(bot)
	and nEnemyCount == 0
	and not Fu.IsRoshanCloseToChangingSides()
	then
		local roshanLoc = Fu.GetCurrentRoshanLocation()
		local targetLoc = Fu.GetNearbyLocationToTp(roshanLoc)

		local tpLocDist = GetUnitToLocationDistance(bot, targetLoc)
		local roshanLocDist = GetUnitToLocationDistance(bot, roshanLoc)

		if tpLocDist > 8000
		and roshanLocDist > 8000
		and roshanLocDist > tpLocDist
		then
			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = targetLoc
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_HIGH, targetLoc, 'ground', 'tp_roshan'
		end
	end

	--Tormentor
	if (bot:GetActiveMode() == BOT_MODE_SIDE_SHOP or bot:GetActiveMode() == BOT_MODE_WATCHER)
	and nEnemyCount == 0
	and (not Fu.IsInTeamFight(bot, 1200)
		or not Fu.IsGoingOnSomeone(bot)
		or not Fu.IsDefending(bot))
	then
		local torLoc = Fu.GetTormentorLocation(team)
		if GetUnitToLocationDistance(bot, torLoc) > 8000 then
			hEffectTarget = Fu.GetNearbyLocationToTp(torLoc)
			sCastMotive = 'tormentor'
			if Fu.GetLocationToLocationDistance(bot:GetLocation(), hEffectTarget) > 4400
			then
				if botName == 'npc_dota_hero_furion'
				then
					local Teleportation = bot:GetAbilityByName('furion_teleportation')
					if Teleportation:IsTrained()
					and Teleportation:IsFullyCastable()
					then
						bot.useProphetTP = true
						bot.ProphetTPLocation = hEffectTarget
						return BOT_ACTION_DESIRE_NONE
					end
				end
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	--守塔
	if Fu.IsDefending( bot )
		and nModeDesire > BOT_MODE_DESIRE_LOW
		and nEnemyCount == 0
	then
		local nDefendLane, sLane = LANE_MID, 'tower_mid'
		if nMode == BOT_MODE_DEFEND_TOWER_TOP then nDefendLane, sLane = LANE_TOP, 'tower_top' end
		if nMode == BOT_MODE_DEFEND_TOWER_BOT then nDefendLane, sLane = LANE_BOT, 'tower_bot' end

		local botAmount = GetAmountAlongLane( nDefendLane, botLocation )
		local laneFront = GetLaneFrontAmount( team, nDefendLane, false )
		if botAmount.distance > nMinTPDistance
			or botAmount.amount < laneFront / 5
		then
			tpLoc = X.GetDefendTPLocation( nDefendLane )
		end

		if tpLoc ~= nil
			and GetUnitToLocationDistance( bot, tpLoc ) > nMinTPDistance - 500
		then
			hEffectTarget = tpLoc
			sCastMotive = '前往守塔:'..sLane

			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_ABSOLUTE, hEffectTarget, sCastType, sCastMotive
		end
	end


	--推塔
	if Fu.IsPushing( bot )
		and nModeDesire >= BOT_MODE_DESIRE_LOW
		and nEnemyCount == 0
	then
		local nPushLane, sLane = LANE_MID, 'tower_mid'
		if nMode == BOT_MODE_PUSH_TOWER_TOP then nPushLane, sLane = LANE_TOP, 'tower_top' end
		if nMode == BOT_MODE_PUSH_TOWER_BOT then nPushLane, sLane = LANE_BOT, 'tower_bot' end

		local botAmount = GetAmountAlongLane( nPushLane, botLocation )
		local laneFront = GetLaneFrontAmount( team, nPushLane, false )
		-- Only TP to push if bot is actually BEHIND our lane front.
		-- Without this, bots deep in enemy base (off the lane curve, high perp distance)
		-- were TPing back to friendly-side lane front when our wave died.
		if botAmount.amount < laneFront - 0.05
			and (botAmount.distance > nMinTPDistance or botAmount.amount < laneFront / 5)
		then
			tpLoc = X.GetPushTPLocation( nPushLane )
		end

		if tpLoc ~= nil
			and GetUnitToLocationDistance( bot, tpLoc ) > nMinTPDistance - 600
			and GetAmountAlongLane( nPushLane, tpLoc ).amount > botAmount.amount
		then
			hEffectTarget = tpLoc
			sCastMotive = '前往推塔:'..sLane

			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end


	--保人
	if nMode == BOT_MODE_DEFEND_ALLY
		and nModeDesire >= BOT_MODE_DESIRE_LOW
		and Fu.Role.CanBeSupport( botName )
		and nEnemyCount == 0
	then
		local target = bot:GetTarget()
		if target ~= nil
			and target:IsHero()
			and GetUnitToUnitDistance( bot, target ) > nMinTPDistance
		then
			local bestTpLoc = Fu.GetNearbyLocationToTp( target:GetLocation() )
			if bestTpLoc ~= nil
				and GetUnitToLocationDistance( bot, bestTpLoc ) > nMinTPDistance - 800
			then
				tpLoc = bestTpLoc
			end
		end

		if tpLoc ~= nil
		then
			hEffectTarget = tpLoc
			sCastMotive = '支援队友:'..Fu.Chat.GetNormName( target )

			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end


	--塔下保人



	--撤退
	if nMode == BOT_MODE_RETREAT
		and nModeDesire >= BOT_MODE_DESIRE_LOW
		and bot:GetLevel() >= 3
		and not bot:HasModifier( "modifier_arc_warden_tempest_double" )
	then

		--第一种情况:无敌人无大药回家恢复
		if botHP < 0.19
			and ( bot:WasRecentlyDamagedByAnyHero( 8.0 ) or botHP < 0.12 )
			and botName ~= 'npc_dota_hero_huskar'
			and ( botName ~= 'npc_dota_hero_slark' or bot:GetLevel() <= 5 )
			and nEnemyCount == 0
			and itemFlask == nil
			and not bot:HasModifier( "modifier_tango_heal" )
			and not bot:HasModifier( "modifier_flask_healing" )
			and not bot:HasModifier( "modifier_juggernaut_healing_ward_heal" )
			and not bot:HasModifier( "modifier_item_urn_heal" )
			and not bot:HasModifier( "modifier_item_spirit_vessel_heal" )
			and bot:DistanceFromFountain() > nMinTPDistance
		then
			tpLoc = Fu.GetTeamFountain()
			sCastMotive = '撤退:1'

			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_HIGH, tpLoc, sCastType, sCastMotive
		end


		--第二种情况:有多个敌人但可以卡视野TP
		local nAttackAllyList = Fu.GetNearbyHeroes(bot, 1500, false, BOT_MODE_ATTACK )
		if botHP < ( 0.15 + 0.24 * nEnemyCount )
			and #nAttackAllyList == 0
			and bot:WasRecentlyDamagedByAnyHero( 6.0 )
			and X.CanJuke()
			and nEnemyCount <= ( botHP < 0.4 and 2 or 3 )
			and nAllyCount <= 2
			and itemFlask == nil
			and not bot:HasModifier( "modifier_tango_heal" )
			and not bot:HasModifier( "modifier_flask_healing" )
			and not bot:HasModifier( "modifier_item_urn_heal" )
			and not bot:HasModifier( "modifier_item_spirit_vessel_heal" )
			and not bot:HasModifier( "modifier_juggernaut_healing_ward_heal" )
			and bot:DistanceFromFountain() > nMinTPDistance - 600
		then
			tpLoc = Fu.GetTeamFountain()
			sCastMotive = '撤退:2'

			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_HIGH, tpLoc, sCastType, sCastMotive
		end


		--第三种情况:只有一个敌人直接T回家
		if ( botHP < 0.34 or botHP + botMP < 0.43 )
			and #nAttackAllyList == 0
			and bot:GetLevel() >= 9
			and X.CanJuke()
			and nEnemyCount <= 1
			and nAllyCount <= 2
			and itemFlask == nil
			and bot:GetAttackTarget() == nil
			and botName ~= 'npc_dota_hero_huskar'
			and botName ~= 'npc_dota_hero_slark'
			and not bot:HasModifier( "modifier_flask_healing" )
			and not bot:HasModifier( "modifier_clarity_potion" )
			and not bot:HasModifier( "modifier_filler_heal" )
			and not bot:HasModifier( "modifier_item_urn_heal" )
			and not bot:HasModifier( "modifier_item_spirit_vessel_heal" )
			and not bot:HasModifier( "modifier_juggernaut_healing_ward_heal" )
			and not bot:HasModifier( "modifier_bottle_regeneration" )
			and not bot:HasModifier( "modifier_tango_heal" )
			and bot:DistanceFromFountain() > nMinTPDistance - 600
		then
			tpLoc = Fu.GetTeamFountain()
			sCastMotive = '撤退:3'

			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_HIGH, tpLoc, sCastType, sCastMotive
		end
	end


	--TP出去发育
	if nMode == BOT_MODE_FARM
		and bot:DistanceFromFountain() < 800
		and not X.IsBaseTowerDestroyed()
		and botHP > 0.9
		and botMP > 0.8
	then
		local mostFarmDesireLane, mostFarmDesire = Fu.GetMostFarmLaneDesire(bot)

		if mostFarmDesire > 0.1
		then
			farmTpLoc = GetLaneFrontLocation( team, mostFarmDesireLane, 0 )
			local bestTpLoc = Fu.GetNearbyLocationToTp( farmTpLoc )
			if bestTpLoc ~= nil and farmTpLoc ~= nil
				and Fu.IsLocHaveTower( 2000, false, farmTpLoc )
				and GetUnitToLocationDistance( bot, bestTpLoc ) > nMinTPDistance
			then
				tpLoc = farmTpLoc
			end
		end

		if tpLoc ~= nil
		then
			hEffectTarget = tpLoc
			sCastMotive = '出去发育'

			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_ABSOLUTE, hEffectTarget, sCastType, sCastMotive
		end

	end


	--TP发育带线
	if bot:GetLevel() >= 10
		and nMode ~= BOT_MODE_ROSHAN
		and not X.IsBaseTowerDestroyed()
		and Fu.GetAllyCount( bot, 1600 ) <= 2
		and Fu.Role.ShouldTpToFarm()
		and not Fu.Role.IsAllyHaveAegis()
		and not Fu.Role.CanBeSupport( botName )
		and not Fu.IsEnemyHeroAroundLocation( GetAncient( team ):GetLocation(), 3300 )
	then
		local nAttackAllyList = Fu.GetNearbyHeroes(bot, 1600, false, BOT_MODE_ATTACK )
		local nNearEnemyList = Fu.GetNearbyHeroes(bot, 1400, true, BOT_MODE_NONE )
		local nCreeps= bot:GetNearbyCreeps( 1600, true )
		local mostFarmDesireLane, mostFarmDesire = Fu.GetMostFarmLaneDesire(bot)
		
		local isTravelBootsAvailable = false
		if Fu.IsItemAvailable( "item_travel_boots" )
			or Fu.IsItemAvailable( "item_travel_boots_2" )
		then
			isTravelBootsAvailable = true
		end

		if mostFarmDesire > ( isTravelBootsAvailable and 0.7 or 0.8 )
			and #nNearEnemyList == 0
			and #nCreeps == 0
			and #nAttackAllyList == 0
		then

			if isTravelBootsAvailable
			then
				tpLoc = GetLaneFrontLocation( team, mostFarmDesireLane, - 600 )
				local nNearAllyList = Fu.GetAlliesNearLoc( tpLoc, 1600 )
				if GetUnitToLocationDistance( bot, tpLoc ) > nMinTPDistance - 1500
					and #nNearAllyList == 0
				then
					Fu.Role['lastFarmTpTime'] = DotaTime()
					sCastMotive = '飞鞋带线'

					if botName == 'npc_dota_hero_furion'
					then
						local Teleportation = bot:GetAbilityByName('furion_teleportation')
						if Teleportation:IsTrained()
						and Teleportation:IsFullyCastable()
						then
							bot.useProphetTP = true
							bot.ProphetTPLocation = tpLoc
							return BOT_ACTION_DESIRE_NONE
						end
					end

					return BOT_ACTION_DESIRE_HIGH, tpLoc, sCastType, sCastMotive
				end
			end

			tpLoc = GetLaneFrontLocation( team, mostFarmDesireLane, 0 )
			local bestTpLoc = Fu.GetNearbyLocationToTp( tpLoc )
			local nNearAllyList = Fu.GetAlliesNearLoc( tpLoc, 1600 )
			if bestTpLoc ~= nil
				and Fu.IsLocHaveTower( 1850, false, tpLoc )
				and GetUnitToLocationDistance( bot, bestTpLoc ) > nMinTPDistance - 800
				and #nNearAllyList == 0
			then
				Fu.Role['lastFarmTpTime'] = DotaTime()
				sCastMotive = '线上打钱'

				if botName == 'npc_dota_hero_furion'
				then
					local Teleportation = bot:GetAbilityByName('furion_teleportation')
					if Teleportation:IsTrained()
					and Teleportation:IsFullyCastable()
					then
						bot.useProphetTP = true
						bot.ProphetTPLocation = bestTpLoc
						return BOT_ACTION_DESIRE_NONE
					end
				end

				return BOT_ACTION_DESIRE_HIGH, bestTpLoc, sCastType, sCastMotive
			end
		end
	end


	--支援团战和守家
	if bot:GetLevel() > 10
		and nMode ~= BOT_MODE_SECRET_SHOP
		and nMode ~= BOT_MODE_ROSHAN
		and nMode ~= BOT_MODE_ATTACK
		and ( botTarget == nil or not botTarget:IsHero() )
		--and Fu.GetAllyCount( bot, 1600 ) <= 3 --守护遗迹bug
	then
		local nNearEnemyList = Fu.GetNearbyHeroes(bot, 1400, true, BOT_MODE_NONE )
		local nTeamFightLocation = Fu.GetTeamFightLocation( bot )
		local isTravelBootsAvailable = false
		if Fu.IsItemAvailable( "item_travel_boots" )
			or Fu.IsItemAvailable( "item_travel_boots_2" )
		then
			isTravelBootsAvailable = true
		end

		if botName == 'npc_dota_hero_spectre'
		then
			local ShadowStep = bot:GetAbilityByName('spectre_shadow_step')
			local Haunt = bot:GetAbilityByName('spectre_haunt')

			if (ShadowStep:IsFullyCastable())
			or (Haunt:IsTrained() and Haunt:IsFullyCastable())
			then
				return BOT_ACTION_DESIRE_NONE
			end
		end
		
		if #nNearEnemyList == 0
			and nTeamFightLocation ~= nil
			and GetUnitToLocationDistance( bot, nTeamFightLocation ) > nMinTPDistance - 1200
		then

			if isTravelBootsAvailable
			then
				sCastMotive = '飞鞋支援团战距离:'..GetUnitToLocationDistance( bot, nTeamFightLocation )

				if botName == 'npc_dota_hero_furion'
				then
					local Teleportation = bot:GetAbilityByName('furion_teleportation')
					if Teleportation:IsTrained()
					and Teleportation:IsFullyCastable()
					then
						bot.useProphetTP = true
						bot.ProphetTPLocation = nTeamFightLocation
						return BOT_ACTION_DESIRE_NONE
					end
				end

				return BOT_ACTION_DESIRE_HIGH, nTeamFightLocation, sCastType, sCastMotive
			end

			local bestTpLoc = Fu.GetNearbyLocationToTp( nTeamFightLocation )
			if bestTpLoc ~= nil
				and Fu.GetLocationToLocationDistance( bestTpLoc, nTeamFightLocation ) < 1800
				and GetUnitToLocationDistance( bot, bestTpLoc ) > nMinTPDistance - 1200
			then
				sCastMotive = '支援团战:'..GetUnitToLocationDistance( bot, nTeamFightLocation )

				if botName == 'npc_dota_hero_furion'
				then
					local Teleportation = bot:GetAbilityByName('furion_teleportation')
					if Teleportation:IsTrained()
					and Teleportation:IsFullyCastable()
					then
						bot.useProphetTP = true
						bot.ProphetTPLocation = bestTpLoc
						return BOT_ACTION_DESIRE_NONE
					end
				end

				return BOT_ACTION_DESIRE_HIGH, bestTpLoc, sCastType, sCastMotive
			end
		end

		--守护遗迹
		local nAncient = GetAncient( team )
		if bot:GetLevel() >= 15	
			and #nNearEnemyList == 0
			and Fu.Role.ShouldTpToFarm()
			and bot:DistanceFromFountain() > 2000
			and GetUnitToUnitDistance( bot, nAncient ) > nMinTPDistance - 200
			and Fu.GetAroundTargetAllyHeroCount( nAncient, 1400 ) == 0
		then
			local nEnemyLaneFront = Fu.GetNearestLaneFrontLocation( nAncient:GetLocation(), true, 400 )
			if nEnemyLaneFront ~= nil
				and GetUnitToLocationDistance( nAncient, nEnemyLaneFront ) <= 1600
			then

				Fu.Role['lastFarmTpTime'] = DotaTime()
				sCastMotive = '守护遗迹'

				if botName == 'npc_dota_hero_furion'
				then
					local Teleportation = bot:GetAbilityByName('furion_teleportation')
					if Teleportation:IsTrained()
					and Teleportation:IsFullyCastable()
					then
						bot.useProphetTP = true
						bot.ProphetTPLocation = nAncient:GetLocation()
						return BOT_ACTION_DESIRE_NONE
					end
				end

				return BOT_ACTION_DESIRE_HIGH, nAncient:GetLocation(), sCastType, sCastMotive
			end
			
			local ancientTower1 = GetTower(team, 9)
			local ancientTower2 = GetTower(team, 10)
			if ancientTower1 == nil and ancientTower2 == nil
--				and nAncient:WasRecentlyDamagedByCreep( 5.0 )
			then
				local nAllEnemyCreeps = GetUnitList( UNIT_LIST_ENEMY_CREEPS )
				for _, creep in pairs( nAllEnemyCreeps )
				do
					if Fu.IsValid(creep)
					and GetUnitToUnitDistance( nAncient, creep ) <= 800
					and ( creep:GetAttackTarget() == nAncient or bot:GetLevel() >= 15 )
					then
						Fu.Role['lastFarmTpTime'] = DotaTime()
						sCastMotive = '保护遗迹'

						if botName == 'npc_dota_hero_furion'
						then
							local Teleportation = bot:GetAbilityByName('furion_teleportation')
							if Teleportation:IsTrained()
							and Teleportation:IsFullyCastable()
							then
								bot.useProphetTP = true
								bot.ProphetTPLocation = nAncient:GetLocation()
								return BOT_ACTION_DESIRE_NONE
							end
						end

						return BOT_ACTION_DESIRE_HIGH, nAncient:GetLocation(), sCastType, sCastMotive
					end
				end
			end
			
		end

	end

	--回复状态
	if ( botHP + botMP < 0.3 or botHP < 0.2 )
		and bot:GetLevel() >= 6
		and botName ~= 'npc_dota_hero_huskar'
		and botName ~= 'npc_dota_hero_slark'
		and not bot:HasModifier( "modifier_arc_warden_tempest_double" )
	then
		if	X.CanJuke()
			and bot:DistanceFromFountain() > nMinTPDistance + 200
			and nEnemyCount <= 1 and nAllyCount <= 1
			and Fu.GetProperTarget( bot ) == nil
			and itemFlask == nil
			and bot:GetAttackTarget() == nil
			and not bot:HasModifier( "modifier_flask_healing" )
			and not bot:HasModifier( "modifier_clarity_potion" )
			and not bot:HasModifier( "modifier_filler_heal" )
			and not bot:HasModifier( "modifier_item_urn_heal" )
			and not bot:HasModifier( "modifier_item_spirit_vessel_heal" )
			and not bot:HasModifier( "modifier_juggernaut_healing_ward_heal" )
			and not bot:HasModifier( "modifier_bottle_regeneration" )
			and not bot:HasModifier( "modifier_tango_heal" )
		then
			tpLoc = Fu.GetTeamFountain()
		end

		if tpLoc ~= nil
		then
			hEffectTarget = tpLoc
			sCastMotive = '回复状态'

			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	--血魔大
	if bot:HasModifier( 'modifier_bloodseeker_rupture' ) and nEnemyCount <= 1
		and Fu.GetModifierTime( bot, "modifier_bloodseeker_rupture" ) >= 3.1
	then
		local nAllyCount = Fu.GetNearbyHeroes(bot, 1000, false, BOT_MODE_NONE )
		if #nAllyCount <= 1 and X.CanJuke()
		then
			tpLoc = Fu.GetTeamFountain()
		end

		if tpLoc ~= nil
		then
			hEffectTarget = tpLoc
			sCastMotive = '躲血魔大'

			if botName == 'npc_dota_hero_furion'
			then
				local Teleportation = bot:GetAbilityByName('furion_teleportation')
				if Teleportation:IsTrained()
				and Teleportation:IsFullyCastable()
				then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end

			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	--处理特殊情况一
	if X.IsFarmingAlways( bot )
	then
		tpLoc = GetAncient( team ):GetLocation()
		sCastMotive = '处理特殊情况一'

		if botName == 'npc_dota_hero_furion'
		then
			local Teleportation = bot:GetAbilityByName('furion_teleportation')
			if Teleportation:IsTrained()
			and Teleportation:IsFullyCastable()
			then
				bot.useProphetTP = true
				bot.ProphetTPLocation = tpLoc
				return BOT_ACTION_DESIRE_NONE
			end
		end

		return BOT_ACTION_DESIRE_HIGH, tpLoc, sCastType, sCastMotive
	end

	--处理特殊情况二
	if Fu.IsStuck( bot ) --and nEnemyCount == 0
	then
		tpLoc = GetAncient( team ):GetLocation()
		sCastMotive = '处理特殊情况二'

		if botName == 'npc_dota_hero_furion'
		then
			local Teleportation = bot:GetAbilityByName('furion_teleportation')
			if Teleportation:IsTrained()
			and Teleportation:IsFullyCastable()
			then
				bot.useProphetTP = true
				bot.ProphetTPLocation = tpLoc
				return BOT_ACTION_DESIRE_NONE
			end
		end

		return BOT_ACTION_DESIRE_HIGH, tpLoc, sCastType, sCastMotive
	end
	
	if Fu.Role.ShouldTpToDefend()
	and bot:DistanceFromFountain() > 3800
	then
		tpLoc = GetAncient( team ):GetLocation()
		sCastMotive = '立即TP守家'
		return BOT_ACTION_DESIRE_HIGH, tpLoc, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end


--骨灰
X.ConsiderItemDesire["item_urn_of_shadows"] = function( hItem )

	if hItem:GetCurrentCharges() == 0 then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 950 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget ) and 
			((Fu.CanCastOnNonMagicImmune( botTarget )
				and Fu.IsInRange( bot, botTarget, nCastRange )
				and not botTarget:HasModifier( "modifier_item_urn_damage" )
				and not botTarget:HasModifier( "modifier_item_spirit_vessel_damage" )
				and not botTarget:HasModifier( "modifier_arc_warden_tempest_double" )
				and ( Fu.GetHP( botTarget ) < 0.95 or Fu.IsInRange( bot, botTarget, 700 ) ))
			or botTarget:HasModifier( "modifier_invoker_cold_snap_freeze" ) -- 配合急速冷却
		) then
			hEffectTarget = botTarget
			sCastMotive = "进攻:"..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if bot:GetActiveMode() ~= BOT_MODE_ROSHAN
	then
		local hAllyList = Fu.GetNearbyHeroes(bot, nCastRange + 80, false, BOT_MODE_NONE )
		local hNeedHealAlly = nil
		local nNeedHealAllyHealth = 99999
		for _, npcAlly in pairs( hAllyList )
		do
			if Fu.IsValid( npcAlly )
				and not npcAlly:IsIllusion()
				and npcAlly:DistanceFromFountain() > 800
				and Fu.CanCastOnNonMagicImmune( npcAlly )
				and not npcAlly:WasRecentlyDamagedByAnyHero( 3.1 )
				and not npcAlly:HasModifier( "modifier_item_spirit_vessel_heal" )
				and not npcAlly:HasModifier( "modifier_item_urn_heal" )
				and not npcAlly:HasModifier( "modifier_fountain_aura" )
				and not npcAlly:HasModifier( "modifier_arc_warden_tempest_double" )
				and npcAlly:OriginalGetMaxHealth() - npcAlly:OriginalGetHealth() > 450
				and #hNearbyEnemyHeroList == 0 
			then
				if( npcAlly:OriginalGetHealth() < nNeedHealAllyHealth )
				then
					hNeedHealAlly = npcAlly
					nNeedHealAllyHealth = npcAlly:OriginalGetHealth()
				end
			end
		end

		if( hNeedHealAlly ~= nil )
		then
			hEffectTarget = hNeedHealAlly
			sCastMotive = '治疗:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--纷争
X.ConsiderItemDesire["item_veil_of_discord"] = function( hItem )

	local nCastRange = 900
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange + 50, true, BOT_MODE_NONE )

	local hNearbyCreepList = bot:GetNearbyCreeps( nCastRange, true )
	if #hNearbyCreepList >= 6
		or #nInRangeEnmyList >= 1
	then
		hEffectTarget = bot
		sCastMotive = '启动希瓦'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end



--真眼
local nLastCheckSentryTime = 0
X.ConsiderItemDesire["item_ward_sentry"] = function( hItem )

	local nCastRange = 500 + aetherRange
	local sCastType = 'ground'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE )
	local nAllyTowerList = bot:GetNearbyTowers( 1200, false )


	--进攻时对拥有隐身能力的敌人使用
	if Fu.IsGoingOnSomeone( bot )
		and #nInRangeEnmyList >= 1
	then
		local targetHero = nil
		for _, npcEnemy in pairs( nInRangeEnmyList )
		do
			if Fu.IsValidHero( npcEnemy )
				and Fu.IsInRange( bot, npcEnemy, 900 )
				and Fu.CanCastOnMagicImmune( npcEnemy )
				and Fu.HasInvisibilityOrItem( npcEnemy )
				and not npcEnemy:HasModifier( "modifier_slardar_amplify_damage" )
				and not npcEnemy:HasModifier( "modifier_item_dustofappearance" )
				and not Fu.Site.IsLocationHaveTrueSight( npcEnemy:GetLocation() )
			then
				hEffectTarget = Fu.GetUnitTowardDistanceLocation( bot, npcEnemy, nCastRange )
				sCastMotive = '插真眼针对:'..Fu.Chat.GetNormName( npcEnemy )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end

	end


	return BOT_ACTION_DESIRE_NONE

end


--GG树
local lastKACount = -1
X.ConsiderItemDesire["item_ironwood_tree"] = function( hItem )

	local nCastRange = 600
	local sCastType = 'ground'
	local hEffectTarget = nil
	local sCastMotive = nil

	if lastKACount == -1 then lastKACount = GetHeroKills( bot:GetPlayerID() ) + GetHeroAssists( bot:GetPlayerID() ) end

	if lastKACount < GetHeroKills( bot:GetPlayerID() ) + GetHeroAssists( bot:GetPlayerID() )
	then
		lastKACount = -1
		hEffectTarget = Fu.GetFaceTowardDistanceLocation( bot, nCastRange )
		sCastMotive = 'GG'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

--精华指环
X.ConsiderItemDesire["item_essence_ring"] = function( hItem )

	if bot:DistanceFromFountain() < 1000 then return 0 end

	local nCastRange = 600
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, 1400, true, BOT_MODE_NONE )

	if bot:GetMaxHealth() - bot:GetHealth() > 600
		and Fu.IsAllowedToSpam( bot, 200 )
	then
		hEffectTarget = bot
		sCastMotive = '治疗自己'
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return X.ConsiderItemDesire["item_faerie_fire"]( hItem )

end

X.ConsiderItemDesire["item_ash_legion_shield"] = function( hItem )
	local nRadius = hItem:GetSpecialValueInt('block_radius')
	local unitList = GetUnitList(UNIT_LIST_ALLIES)

	local countControlledCreep = 0
	local countControlledHero = 0

	for _, unit in pairs(unitList) do
		if Fu.IsValid(unit) and Fu.IsInRange(bot, unit, nRadius) then
			local sUnitName = unit:GetUnitName()

			if unit:IsHero() and (unit:IsIllusion() or string.find(sUnitName, 'bear')) then
				countControlledHero = countControlledHero + 1
			end

			if string.find(sUnitName, 'golem') then
				return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
			end

			if string.find(sUnitName, 'spiderlings')
			or string.find(sUnitName, 'forge_spirit')
			or string.find(sUnitName, 'golem')
			or string.find(sUnitName, 'boar')
			or string.find(sUnitName, 'furion_treant')
			or string.find(sUnitName, 'familiars')
			or unit:IsDominated()
			or unit:HasModifier('modifier_chen_holy_persuasion')
			then
				countControlledCreep = countControlledCreep + 1
			end
		end
	end

	if Fu.IsGoingOnSomeone(bot) then
		if bot:WasRecentlyDamagedByAnyHero(2.0) and (countControlledCreep >= 2 or countControlledHero >= 2) then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

X.ConsiderItemDesire["item_flayers_bota"] = function( hItem )

	if Fu.IsGoingOnSomeone(bot) then
		if  Fu.IsValidHero(botTarget)
		and Fu.CanBeAttacked(botTarget)
		and not Fu.IsSuspiciousIllusion(botTarget)
		and bAttacking
		then
			return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
		end
	end

	if Fu.IsDoingRoshan(bot) then
		if Fu.IsRoshan(botTarget)
		and Fu.CanBeAttacked(botTarget)
		and Fu.IsInRange(bot, botTarget, botAttackRange + 150)
		and #nEnemyHeroes == 0
		and bAttacking
		then
			return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
		end
	end

	if Fu.IsDoingTormentor(bot) then
		if Fu.IsTormentor(botTarget)
		and Fu.IsInRange(bot, botTarget, botAttackRange + 150)
		and #nEnemyHeroes == 0
		and bAttacking
		then
			return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

X.ConsiderItemDesire["item_idol_of_screeauk"] = function( hItem )

	if Fu.IsGoingOnSomeone(bot) then
		if bot:WasRecentlyDamagedByAnyHero(2.0) and Fu.IsRunning(bot) then
			return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

X.ConsiderItemDesire["item_jidi_pollen_bag"] = function( hItem )

	local nRadius = hItem:GetSpecialValueInt('debuff_radius')

	local nInRangeEnemy = Fu.GetEnemiesNearLoc(botLocation, nRadius)

	if Fu.IsInTeamFight(bot, 1200) then
        if #nInRangeEnemy >= 2 then
            local count = 0
            for _, enemyHero in pairs(nInRangeEnemy) do
                if Fu.IsValidHero(enemyHero)
                and Fu.CanBeAttacked(enemyHero)
                and Fu.CanCastOnNonMagicImmune(enemyHero)
				and not enemyHero:HasModifier('modifier_doom_bringer_doom_aura_enemy')
				and not enemyHero:HasModifier('modifier_necrolyte_reapers_scythe')
				and not enemyHero:HasModifier('modifier_ice_blast')
				and not enemyHero:HasModifier('modifier_item_spirit_vessel_damage')
                then
                    count = count + 1
                end
            end

            if count >= 2 then
                return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
            end
        end
    end

    if Fu.IsGoingOnSomeone(bot) then
        if  Fu.IsValidHero(botTarget)
        and Fu.CanBeAttacked(botTarget)
        and Fu.IsInRange(bot, botTarget, nRadius)
        and Fu.CanCastOnNonMagicImmune(botTarget)
        and not botTarget:HasModifier('modifier_doom_bringer_doom_aura_enemy')
		and not botTarget:HasModifier('modifier_necrolyte_reapers_scythe')
		and not botTarget:HasModifier('modifier_ice_blast')
		and not botTarget:HasModifier('modifier_item_spirit_vessel_damage')
        then
			return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
        end
	end

	return BOT_ACTION_DESIRE_NONE
end

X.ConsiderItemDesire["item_metamorphic_mandible"] = function( hItem )

	local nDuration = hItem:GetSpecialValueInt('duration')

	if Fu.IsGoingOnSomeone(bot) then
		if bot:WasRecentlyDamagedByAnyHero(2.0) then
			local enemyDamage = 0
			for _, enemyHero in pairs(nEnemyHeroes) do
				if  Fu.IsValidHero(enemyHero)
				and not Fu.IsSuspiciousIllusion(enemyHero)
				and not enemyHero:HasModifier('modifier_necrolyte_reapers_scythe')
				and not enemyHero:IsChanneling()
				then
					if enemyHero:GetAttackTarget() == bot
					or Fu.IsChasingTarget(enemyHero, bot)
					or enemyHero:IsFacingLocation(bot:GetLocation(), 15)
					or bot:WasRecentlyDamagedByHero(enemyHero, 3.0)
					then
						enemyDamage = enemyDamage + (enemyHero:GetAttackDamage() * enemyHero:GetAttackSpeed() * nDuration)
					end
				end
			end

			if bot:GetActualIncomingDamage(enemyDamage * 1.5, DAMAGE_TYPE_PHYSICAL) < bot:GetHealth() then
				return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

X.ConsiderItemDesire["item_riftshadow_prism"] = function( hItem )
	local fHealthCostPct = hItem:GetSpecialValueInt('health_cost')

	if Fu.IsGoingOnSomeone(bot) then
		if bot:WasRecentlyDamagedByAnyHero(2.0) and Fu.GetHealthAfter(bot:GetHealth() * fHealthCostPct) > 0.2 then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

--网虫腿
X.ConsiderItemDesire["item_spider_legs"] = function( hItem )

	return X.ConsiderItemDesire["item_phase_boots"]( hItem )

end


--闪灵
X.ConsiderItemDesire["item_flicker"] = function( hItem )

	if bot:DistanceFromFountain() < 600 or bot:IsRooted() then return BOT_ACTION_DESIRE_NONE end

	local nCastRange = 600
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, 800, true, BOT_MODE_NONE )

	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and ( bot:IsSilenced() or bot:IsRooted() )
		then
			hEffectTarget = bot
			sCastMotive = '驱散沉默或缠绕'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end


	if Fu.IsRetreating( bot )
		and bot:WasRecentlyDamagedByAnyHero( 3.0 )
		and #nInRangeEnmyList >= 1
	then
		hEffectTarget = bot
		sCastMotive = "撤退"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end


	return BOT_ACTION_DESIRE_NONE

end

--幻术师披风
X.ConsiderItemDesire["item_illusionsts_cape"] = function( hItem )

	local nCastRange = 800
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil

	if Fu.IsValid( botTarget )
		and Fu.IsInRange( bot, botTarget, nCastRange )
	then
		hEffectTarget = botTarget
		sCastMotive = "辅助攻击"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return X.ConsiderItemDesire["item_manta"]( hItem )

end

--灵犀角
-- X.ConsiderItemDesire["item_minotaur_horn"] = function( hItem )

-- 	return X.ConsiderItemDesire["item_black_king_bar"]( hItem )

-- end

--林地神行靴
X.ConsiderItemDesire["item_woodland_striders"] = function( hItem )

	if bot:DistanceFromFountain() < 600 then return 0 end

	local nCastRange = 800
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil

	if Fu.IsRetreating( bot )
		and bot:WasRecentlyDamagedByAnyHero( 4.0 )
	then
		hEffectTarget = bot
		sCastMotive = "撤退"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end

--堕天斧
X.ConsiderItemDesire["item_fallen_sky"] = function( hItem )

	local nCastRange = 1600
	local sCastType = 'ground'
	local nRadius = 315
	local nCastDelay = 0.5
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE )


	if Fu.IsGoingOnSomeone( bot )
	then
		local nAoeLocation = Fu.GetAoeEnemyHeroLocation( bot, nCastRange, nRadius, 2 )
		if nAoeLocation ~= nil
		then
			hEffectTarget = nAoeLocation
			sCastMotive = 'Aoe'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		if Fu.IsValidHero( botTarget )
			and Fu.CanCastOnNonMagicImmune( botTarget )
			and Fu.IsInRange( bot, botTarget, nCastRange )
		then
			local nCastLocation = Fu.GetDelayCastLocation( bot, botTarget, nCastRange, nRadius, nCastDelay )
			if nCastLocation ~= nil
			then
				hEffectTarget = nCastLocation
				sCastMotive = "进攻"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	if Fu.IsRetreating( bot )
		and bot:WasRecentlyDamagedByAnyHero( 3.0 )
	then
		local bLocation = Fu.GetLocationTowardDistanceLocation( bot, GetAncient( team ):GetLocation(), 1600 )
		local nAttackAllyList = Fu.GetNearbyHeroes(bot, 800, false, BOT_MODE_ATTACK )
		if bot:DistanceFromFountain() > 800
			and IsLocationPassable( bLocation )
			and ( #nAttackAllyList == 0 or bot:GetActiveModeDesire() > BOT_MODE_DESIRE_VERYHIGH * 0.9 )
			and #nInRangeEnmyList >= 1
		then
			hEffectTarget = bLocation
			sCastMotive = "撤退"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--机械之心
X.ConsiderItemDesire["item_ex_machina"] = function( hItem )

	local nCastRange = 800
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
		then
			local nSoltList = { 0, 1, 2, 3, 4, 5 }
			local nRemainTime = 0
			for _, nSlot in pairs( nSoltList )
			do
				local hItem = bot:GetItemInSlot( nSlot )
				if hItem ~= nil and hItem:GetName() ~= 'item_refresher'
				then
					local nCooldownTime = hItem:GetCooldownTimeRemaining()
					nRemainTime = nRemainTime + nCooldownTime
				end
			end

			if nRemainTime >= 30
			then
				hEffectTarget = botTarget
				sCastMotive = "刷新CD"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--风暴宝器
X.ConsiderItemDesire["item_stormcrafter"] = function( hItem )

	local nCastRange = 300 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE )


	if Fu.CanCastOnNonMagicImmune( bot )
		and #nInRangeEnmyList > 0
	then
		if bot:IsRooted()
			or ( bot:GetPrimaryAttribute() == ATTRIBUTE_INTELLECT and bot:IsSilenced() )
		then
			hEffectTarget = bot
			sCastMotive = '解缠绕:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		if Fu.IsUnitTargetProjectileIncoming( bot, 400 )
		then
			hEffectTarget = bot
			sCastMotive = '防御弹道:'..Fu.Chat.GetNormName( hEffectTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

--缚灵索
X.ConsiderItemDesire["item_gungir"] = function( hItem )
	local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), 1000)
	for _, enemyHero in pairs(nInRangeEnemy)
	do
		if Fu.IsValidTarget(enemyHero)
		and Fu.IsUnitWillGoInvisible(enemyHero)
		and Fu.IsClosestToDustLocation(bot, enemyHero:GetLocation())
		and not Fu.HasInvisCounterBuff(enemyHero)
		and not Fu.IsSuspiciousIllusion(enemyHero)
		then
			if hItem:GetName() == "item_gungir" then hEffectTarget = enemyHero:GetLocation() end
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, 'unit', 'Stop invis'
		end	
	end	

	return X.ConsiderItemDesire["item_rod_of_atos"]( hItem )

end

--杂技玩具
X.ConsiderItemDesire["item_pogo_stick"] = function( hItem )

	local nCastRange = 1000
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	--追击敌人
	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.IsInRange( bot, botTarget, bot:GetAttackRange() + 400 )
			and Fu.CanCastOnMagicImmune( botTarget )
			and Fu.IsChasingTarget( bot, botTarget )
		then
			hEffectTarget = botTarget
			sCastMotive = "进攻:"..Fu.Chat.GetNormName( botTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end
	
	--撤退了推自己
	if ( nMode == BOT_MODE_RETREAT and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_HIGH )
	then
		
		if bot:IsFacingLocation( GetAncient( team ):GetLocation(), 20 )
			and bot:DistanceFromFountain() > 600
			and #nInRangeEnmyList >= 1
		then
			hEffectTarget = bot
			sCastMotive = '撤退了推自己'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--仙灵榴弹
X.ConsiderItemDesire["item_paintball"] = function( hItem )

	local nCastRange = 900 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsValidHero( botTarget )
		and Fu.CanCastOnNonMagicImmune( botTarget )
		and Fu.CanCastOnTargetAdvanced( botTarget )
		and Fu.IsInRange( botTarget, bot, nCastRange )
	then
		hEffectTarget = botTarget
		sCastMotive = '仙灵榴弹:'..Fu.Chat.GetNormName( hEffectTarget )
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE

end


--行巫之祸
X.ConsiderItemDesire["item_heavy_blade"] = function( hItem )

	local nCastRange = 500
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	--驱散友军
	for i = 1, #GetTeamPlayers( GetTeam() )
	do 
		local npcAlly = GetTeamMember( i )
		if Fu.IsValidHero( npcAlly )
			and Fu.IsInRange( bot, npcAlly, nCastRange + 100 )
		then
			if ( Fu.IsGoingOnSomeone( npcAlly ) or Fu.IsRetreating( npcAlly ) )
				and npcAlly:WasRecentlyDamagedByAnyHero( 2.0 )
				and Fu.GetHP( npcAlly ) < 0.85
			then
				local nEnemyList = Fu.GetNearbyHeroes(npcAlly,  300, true, BOT_MODE_NONE )
				local npcEnemy = nEnemyList[1]
				if Fu.IsValidHero( npcEnemy )
					and Fu.CanCastOnMagicImmune( npcEnemy )
				then
					hEffectTarget = npcAlly
					sCastMotive = "行巫之祸驱散友军:"..Fu.Chat.GetNormName( npcAlly )
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
				end
			end
		end	
	end
	
		
	--驱散敌军
	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.IsInRange( bot, botTarget, nCastRange )
			and Fu.CanCastOnNonMagicImmune( botTarget )
		then
			-- if botTarget:HasModifier("")
				-- or botTarget:HasModifier("")
			if botTarget:WasRecentlyDamagedByAnyHero( 3.0 )
				and Fu.GetHP( botTarget ) < 0.7
			then
				hEffectTarget = botTarget
				sCastMotive = "行巫之祸驱散敌军:"..Fu.Chat.GetNormName( botTarget )
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end
	

	return BOT_ACTION_DESIRE_NONE

end

--亡魂胸针
X.ConsiderItemDesire["item_revenants_brooch"] = function( hItem )

	local nCastRange = bot:GetAttackRange() + 100
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and Fu.IsInRange( bot, botTarget, nCastRange )
		then
			hEffectTarget = bot
			sCastMotive = "亡魂胸针进攻:"..Fu.Chat.GetNormName( botTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--怨灵之契
X.ConsiderItemDesire["item_wraith_pact"] = function( hItem )

	local nCastRange = 200 + aetherRange
	local sCastType = 'ground'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
			and botTarget:GetAttackTarget() ~= nil
			and Fu.IsInRange( bot, botTarget, 900 )
			and Fu.CanCastOnNonMagicImmune( botTarget )
		then
			hEffectTarget = Fu.GetFaceTowardDistanceLocation( bot, 200 )
			sCastMotive = "怨灵之契进攻:"..Fu.Chat.GetNormName( botTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end


--宽容之鞋
X.ConsiderItemDesire["item_boots_of_bearing"] = function( hItem )

	return X.ConsiderItemDesire["item_ancient_janggo"]( hItem )

end


--新物品
X.ConsiderItemDesire["item_new"] = function( hItem )

	local nCastRange = 300 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )


	if Fu.IsGoingOnSomeone( bot )
	then
		if Fu.IsValidHero( botTarget )
		then
			hEffectTarget = botTarget
			sCastMotive = "进攻:"..Fu.Chat.GetNormName( botTarget )
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	return BOT_ACTION_DESIRE_NONE

end

-- ADDED EXISTING ITEMS FUNCTIONALITY

--item_soul_ring
X.ConsiderItemDesire['item_soul_ring'] = function(item)

	local sCastType = 'none'
	local hEffectTarget = bot
	local sCastMotive = nil
	local aMode = bot:GetActiveMode()

	local currMana = bot:GetMana() / bot:GetMaxMana()
	local currHealth = bot:OriginalGetHealth() / bot:OriginalGetMaxHealth()

	if (aMode == BOT_MODE_FARM or aMode == BOT_MODE_LANING)
	and currHealth > 0.5 and currMana < 0.5
	then
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	return BOT_ACTION_DESIRE_NONE
end

-- 7.33 New Items
X.ConsiderItemDesire['item_pavise'] = function(item)
	local nCastRange = 1000 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )
	local nNearAllyList = Fu.GetNearbyHeroes(bot, nCastRange, false, BOT_MODE_NONE )
	local health = bot:OriginalGetHealth() / bot:OriginalGetMaxHealth()

	--对可能被作为敌方目标的队友使用
	for _, npcAlly in pairs( nNearAllyList )
	do
		if Fu.IsValidHero( npcAlly )
			and npcAlly ~= bot
			and not npcAlly:IsMagicImmune()
			and not npcAlly:IsInvulnerable()
			and not npcAlly:IsIllusion()
			and not npcAlly:HasModifier( "modifier_item_pavise_shield" )
			and not npcAlly:HasModifier( 'modifier_antimage_spell_shield' )
			and ( Fu.IsUnitTargetProjectileIncoming( npcAlly, 800 )
				 or Fu.IsWillBeCastUnitTargetSpell( npcAlly, 1200 )
				 or health < 0.2 )
		then
			hEffectTarget = npcAlly
			sCastMotive = '帮助队友'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end


	if Fu.IsValidHero( botTarget )
		and Fu.IsInRange( bot, botTarget, 2400 )
		and not Fu.IsInRange( bot, botTarget, 800 )
	then
		if #nNearAllyList >= 2
		then
			local targetAlly = nil
			local targetDistance = 9999
			for _, npcAlly in pairs( nNearAllyList )
			do
				if npcAlly ~= bot
					and not npcAlly:IsIllusion()
					and Fu.IsInRange( npcAlly, botTarget, targetDistance )
					and not npcAlly:HasModifier( "modifier_item_pavise_shield" )
					and not npcAlly:HasModifier( 'modifier_antimage_spell_shield' )
				then
					targetAlly = npcAlly
					targetDistance = GetUnitToUnitDistance( botTarget, npcAlly )
					if Fu.IsHumanPlayer( npcAlly ) then break end
				end
			end
			if targetAlly ~= nil
			then
				hEffectTarget = targetAlly
				sCastMotive = '先给前排套上'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

X.ConsiderItemDesire['item_harpoon'] = function(item)
	local nCastRange = 700 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil

	local nAttackRange = bot:GetAttackRange()
	local botTarget = Fu.GetProperTarget(bot)

	if Fu.IsGoingOnSomeone(bot)
	then
		if Fu.IsValidTarget(botTarget)
		and Fu.IsInRange(bot, botTarget, nCastRange + nAttackRange)
		and not Fu.IsInRange(bot, botTarget, nCastRange / 2)
		and not Fu.IsSuspiciousIllusion(botTarget)
		then
			hEffectTarget = botTarget
			sCastMotive = 'Harpoon'

			if Fu.WeAreStronger(bot, nCastRange + nAttackRange)
			then
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			else
				return BOT_ACTION_DESIRE_MODERATE, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

X.ConsiderItemDesire['item_disperser'] = function(item)
	local nCastRange = 600 + aetherRange
	local sCastType = 'unit'
	local hEffectTarget = nil
	local sCastMotive = nil

	local nAttackRange = bot:GetAttackRange()
	local botTarget = Fu.GetProperTarget(bot)
	local nAllyHeroes = Fu.GetNearbyHeroes(bot,nCastRange, false, BOT_MODE_NONE)
	local nEnemyHeroes = Fu.GetNearbyHeroes(bot,nCastRange + nAttackRange, true, BOT_MODE_NONE)

	if Fu.IsDisabled(bot)
	then
		if nEnemyHeroes ~= nil and #nEnemyHeroes >= 1
		then
			hEffectTarget = bot
			sCastMotive = 'Disperser'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	for _, allyHero in pairs(nAllyHeroes)
	do
		if nEnemyHeroes ~= nil and #nEnemyHeroes >= 1
		and allyHero:WasRecentlyDamagedByAnyHero(2)
		and not Fu.IsSuspiciousIllusion(allyHero)
		then
			hEffectTarget = allyHero
			sCastMotive = 'Disperser'

			if Fu.IsDisabled(allyHero)
			then
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if allyHero:GetActiveMode() == BOT_MODE_RETREAT
			and Fu.GetHP(allyHero) < 0.42
			then
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	if Fu.IsGoingOnSomeone(bot)
	then
		if Fu.IsValidTarget(botTarget)
		and Fu.CanCastOnNonMagicImmune(botTarget)
		and Fu.IsInRange(bot, botTarget, nCastRange)
		and not Fu.IsSuspiciousIllusion(botTarget)
		and not Fu.IsDisabled(botTarget)
		then
			if botTarget:GetCurrentMovementSpeed() > bot:GetCurrentMovementSpeed()
			and bot:IsFacingLocation(botTarget:GetLocation(), 30)
			and not botTarget:IsFacingLocation(bot:GetLocation(), 30)
			then
				hEffectTarget = RandomInt(1, 100) > 20 and botTarget or bot -- 20% ourself, more fun
				sCastMotive = 'Disperser'

				if Fu.WeAreStronger(bot, nCastRange + nAttackRange)
				then
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
				else
					return BOT_ACTION_DESIRE_MODERATE, hEffectTarget, sCastType, sCastMotive
				end
			end
		end
	end

	if Fu.IsInTeamFight(bot, nCastRange + nAttackRange)
	then
		local nNearbyAllies = Fu.GetAlliesNearLoc(bot:GetLocation(), nCastRange)

		if nNearbyAllies ~= nil and #nNearbyAllies >= 1
		and nEnemyHeroes ~= nil and #nEnemyHeroes >= 2
		then
			hEffectTarget = bot
			sCastMotive = 'Disperser'
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
	end

	if Fu.IsRetreating(bot)
	then
		if nEnemyHeroes ~= nil and #nEnemyHeroes >= 1
		then
			if not Fu.WeAreStronger(bot, nCastRange + nAttackRange)
			or Fu.GetHP(bot) < 0.33
			then
				hEffectTarget = RandomInt(1, 100) > 10 and bot or botTarget -- 90% ourself, more fun
				sCastMotive = 'Disperser'
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

X.ConsiderItemDesire['item_blood_grenade'] = function(item)
	local nCastRange = 900
	local nRadius = 300
	local nHealth = bot:GetHealth()
	local nHealthCost = 75
	local nImpactDamage = 50
	local nDPS = 15
	local nDuration = 5
	local nEnemyHeroes = Fu.GetNearbyHeroes(bot,nCastRange, true, BOT_MODE_NONE)
	local totalDmg = nImpactDamage + (nDPS * nDuration)

	for _, enemyHero in pairs(nEnemyHeroes)
	do
		local canKillTarget = Fu.CanKillTarget(enemyHero, totalDmg, DAMAGE_TYPE_MAGICAL)
		if Fu.IsInRange(bot, enemyHero, bot:GetAttackRange()) and bot:IsFacingLocation(enemyHero:GetLocation(), 15) then
			canKillTarget = canKillTarget or Fu.CanKillTarget(enemyHero, totalDmg + 150, DAMAGE_TYPE_MAGICAL)
		end

		if Fu.IsValidHero(enemyHero)
		and Fu.CanCastOnNonMagicImmune(enemyHero)
		and canKillTarget
		and not Fu.IsSuspiciousIllusion(enemyHero)
		and nHealth > nHealthCost * 2
		then
			local nInRangeEnemy = Fu.GetEnemiesNearLoc(enemyHero:GetLocation(), nRadius)

            if nInRangeEnemy ~= nil and #nInRangeEnemy >= 1
            then
                return BOT_ACTION_DESIRE_HIGH, Fu.GetCenterOfUnits(nInRangeEnemy), 'ground', 'Blood Grenade'
            end

            return BOT_ACTION_DESIRE_HIGH, enemyHero:GetLocation(), 'ground', 'Blood Grenade'
		end
	end

	if Fu.IsGoingOnSomeone(bot)
	then
		for _, enemyHero in pairs(nEnemyHeroes)
		do
			if Fu.IsValidHero(enemyHero)
			and Fu.CanCastOnNonMagicImmune(enemyHero)
			and Fu.IsChasingTarget(bot, enemyHero)
			and not Fu.IsSuspiciousIllusion(enemyHero)
			and nHealth > nHealthCost * 2
			then
				local nInRangeAlly = Fu.GetNearbyHeroes(enemyHero, 1200, true, BOT_MODE_NONE)
				local nInRangeEnemy = Fu.GetNearbyHeroes(enemyHero, 1200, false, BOT_MODE_NONE)
				
				if nInRangeAlly ~= nil and nInRangeEnemy ~= nil
				and #nInRangeAlly >= #nInRangeEnemy
				and #nInRangeAlly >= 1
					and Fu.IsGoingOnSomeone(nInRangeAlly[1])
					and nInRangeAlly[1]:GetAttackTarget() == enemyHero
					and Fu.IsChasingTarget(nInRangeAlly[1], enemyHero)
					and not nInRangeAlly[1]:IsIllusion()
				and Fu.GetTotalEstimatedDamageToTarget(nInRangeAlly, enemyHero) >= enemyHero:GetHealth()
				then
					local nTargetInRangeAlly = Fu.GetEnemiesNearLoc(enemyHero:GetLocation(), nRadius)

					if nTargetInRangeAlly ~= nil and #nTargetInRangeAlly >= 1
					then
						return BOT_ACTION_DESIRE_HIGH, Fu.GetCenterOfUnits(nTargetInRangeAlly), 'ground', 'Blood Grenade'
					end
		
					return BOT_ACTION_DESIRE_HIGH, enemyHero:GetLocation(), 'ground', 'Blood Grenade'
				end
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE, 0
end

local roshDeathTime = 0
X.ConsiderItemDesire['item_smoke_of_deceit'] = function(item)
	local nRadius = 1200
	local sCastType = 'none'
	local hEffectTarget = nil
	local sCastMotive = 'Smoke Of Deceit'

	local isThereEnemyNearby = false
	local nInRangeAlly = Fu.GetAllyList(bot, nRadius)
	local nInRangeEnemy = Fu.GetNearbyHeroes(bot,nRadius, true, BOT_MODE_NONE)
	local nInRangeTower = bot:GetNearbyTowers(nRadius, true)

	if DotaTime() < 0 and DotaTime() > -60
	then
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
	end

	if (nInRangeEnemy ~= nil and #nInRangeEnemy == 0)
	or (nInRangeTower ~= nil and #nInRangeTower == 0)
	then
		for _, allyHero in pairs(nInRangeAlly)
		do
			if Fu.IsValidHero(allyHero)
			then
				local nAllyInRangeEnemy = Fu.GetNearbyHeroes(allyHero, nRadius, true, BOT_MODE_NONE)
				local nAllyInRangeTower = allyHero:GetNearbyTowers(nRadius, true)

				if (nAllyInRangeEnemy ~= nil and #nAllyInRangeEnemy >= 1)
				or (nAllyInRangeTower ~= nil and #nAllyInRangeTower >= 1)
				then
					isThereEnemyNearby = true
					break
				end
			end
		end
	end

	if not isThereEnemyNearby
	then
		local nMode = bot:GetActiveMode()
		local timeOfDay = Fu.CheckTimeOfDay()
		hEffectTarget = bot

		if #nInRangeAlly >= 2
		and (nMode == BOT_MODE_ROAM
			or nMode == BOT_MODE_GANK)
		then
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end

		-- Smart Bots: smoke up on the way to a group gank of the enemy carry (FuncLib/systems/hunt.lua),
		-- while still far from him so the enemy cannot see the group coming.
		local hunt = bot._smartHunt
		if #nInRangeAlly >= 2
		and nMode == BOT_MODE_TEAM_ROAM
		and hunt ~= nil and hunt.active and hunt.lastLoc ~= nil
		and GetUnitToLocationDistance(bot, hunt.lastLoc) > 2000
		then
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
		end
		
		if (timeOfDay == 'day' and GetUnitToLocationDistance(bot, Fu.Utils.RadiantRoshanLoc) < 600)
		or (timeOfDay == 'night' and GetUnitToLocationDistance(bot, Fu.Utils.DireRoshanLoc) < 600)
		then
			if GetRoshanKillTime() > roshDeathTime
			then
				roshDeathTime = GetRoshanKillTime()
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end

		if nMode == BOT_MODE_ROSHAN
		and nInRangeAlly ~= nil and #nInRangeAlly >= 2
		then
			if timeOfDay == 'day'
			and GetUnitToLocationDistance(bot, Fu.Utils.RadiantRoshanLoc) > 3000
			then
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end

			if timeOfDay == 'night'
			and GetUnitToLocationDistance(bot, Fu.Utils.DireRoshanLoc) > 3000
			then
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, sCastType, sCastMotive
			end
		end
	end
	
	return BOT_ACTION_DESIRE_NONE
end

-- Dust of Appearance
local EnemyPIDs = nil
X.ConsiderItemDesire['item_dust'] = function(item)
	local nRadius = 1050

	if EnemyPIDs == nil then EnemyPIDs = GetTeamPlayers(GetOpposingTeam()) end

	local trees = bot:GetNearbyTrees(500)
	if #trees < 5 then
		for _, id in pairs(EnemyPIDs)
		do
			local info = GetHeroLastSeenInfo(id)

			if IsHeroAlive(id)
			and info ~= nil
			then
				local dInfo = info[1]

				if dInfo ~= nil
				and dInfo.time_since_seen > 0.2
				and dInfo.time_since_seen < 0.5
				and GetUnitToLocationDistance(bot, dInfo.location) < nRadius - 450
				and Fu.IsClosestToDustLocation(bot, dInfo.location)
				then
					local loc = Fu.GetXUnitsTowardsLocation2(dInfo.location, DireFountain, 200)
					if team == TEAM_DIRE
					then
						loc = Fu.GetXUnitsTowardsLocation2(dInfo.location, RadiantFountain, 200)
					end

					if IsLocationVisible(loc)
					and IsLocationPassable(loc)
					then
						return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
					end
				end
			end
		end
	end

	if bot:HasModifier('modifier_sandking_sand_storm_slow')
	or bot:HasModifier('modifier_sandking_sand_storm_slow_aura_thinker')
	then
		return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
	end

	local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), nRadius)
	if nInRangeEnemy ~= nil and #nInRangeEnemy == 0
	then
		if bot:HasModifier('modifier_item_radiance_debuff')
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end

		for _, id in pairs(EnemyPIDs)
		do
			if IsHeroAlive(id)
			and bot:WasRecentlyDamagedByPlayer(id, 0.5)
			then
				local info = GetHeroLastSeenInfo(id)

				if info ~= nil
				then
					local dInfo = info[1]
					if dInfo ~= nil
					and GetUnitToLocationDistance(bot, dInfo.location) < nRadius
					then
						return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
					end
				end
			end
		end
	else
		for _, enemyHero in pairs(nInRangeEnemy)
		do
			if Fu.IsValidTarget(enemyHero)
			and Fu.IsUnitWillGoInvisible(enemyHero)
			and Fu.IsClosestToDustLocation(bot, enemyHero:GetLocation())
			and not Fu.HasInvisCounterBuff(enemyHero)
			and not Fu.IsSuspiciousIllusion(enemyHero)
			then
				local nEnemyTowers = enemyHero:GetNearbyTowers(700, true)
				if nEnemyTowers == nil or #nEnemyTowers == 0
				then
					return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
				end
			end	
		end	
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Neutral Items

-- TIER 1

-- Trusty Shovel
X.ConsiderItemDesire["item_trusty_shovel"] = function(hItem)
	if GetTeamMember(1):IsBot() then return BOT_ACTION_DESIRE_NONE end

	local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), 1000)

	if nInRangeEnemy ~= nil and #nInRangeEnemy == 0
	then
		return BOT_ACTION_DESIRE_HIGH, bot:GetLocation(), 'ground', nil
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Arcane Ring
X.ConsiderItemDesire["item_arcane_ring"] = function(hItem)
	return X.ConsiderItemDesire["item_arcane_boots"](hItem)
end

-- Pig Pole
X.ConsiderItemDesire["item_unstable_wand"] = function(hItem)
	local nCastRange = 1600
	local nInRangeEnemy = Fu.GetNearbyHeroes(bot,nCastRange, true, BOT_MODE_NONE)

	if nInRangeEnemy ~= nil and #nInRangeEnemy == 0
	and Fu.GetMP(bot) > 0.5
	and (Fu.IsRetreating(bot) or Fu.IsGoingOnSomeone(bot))
	then
		return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Seeds of Serenity
X.ConsiderItemDesire["item_seeds_of_serenity"] = function(hItem)
	local nRadius = 400
	local nInRangeEnemy = Fu.GetNearbyHeroes(bot,nRadius, true, BOT_MODE_NONE)
	local nInRangeTower = bot:GetNearbyTowers(700, true)

	if Fu.IsFarming(bot)
	then	
		if Fu.IsAttacking(bot)
		then
			local nNeutralCreeps = bot:GetNearbyNeutralCreeps(nRadius)
			if nNeutralCreeps ~= nil
			and ((#nNeutralCreeps >= 3)
				or (#nNeutralCreeps >= 2 and nNeutralCreeps[1]:IsAncientCreep()))
			then
				return BOT_ACTION_DESIRE_HIGH, bot:GetLocation()
			end

			local nEnemyLaneCreeps = bot:GetNearbyLaneCreeps(nRadius, true)
			if nEnemyLaneCreeps ~= nil and #nEnemyLaneCreeps >= 3
			then
				return BOT_ACTION_DESIRE_HIGH, bot:GetLocation()
			end
		end
	end

	if Fu.IsPushing(bot)
	then
		if nInRangeTower ~= nil and #nInRangeTower >= 1
		and Fu.IsValidBuilding(botTarget)
		and Fu.IsValidBuilding(nInRangeTower[1])
		and Fu.IsAttacking(bot)
		and botTarget == nInRangeTower[1]
		then
			return BOT_ACTION_DESIRE_HIGH, bot:GetLocation(), 'ground', nil
		end
	end

	if Fu.IsDoingRoshan(bot)
    then
        if Fu.IsRoshan(botTarget)
        and Fu.IsInRange(bot, botTarget, nRadius)
        and Fu.IsAttacking(bot)
        then
            return BOT_ACTION_DESIRE_HIGH, bot:GetLocation(), 'ground', nil
        end
    end

    if Fu.IsDoingTormentor(bot)
    then
        if Fu.IsTormentor(botTarget)
        and Fu.IsInRange(bot, botTarget, nRadius)
        and Fu.IsAttacking(bot)
        then
            return BOT_ACTION_DESIRE_HIGH, bot:GetLocation(), 'ground', nil
        end
    end

	return BOT_ACTION_DESIRE_NONE
end

-- 7.41 Neutral Items

-- Dagger of Ristul: self-cast, consume 100 HP for +25 damage for 8s, 30s CD
X.ConsiderItemDesire["item_dagger_of_ristul"] = function(hItem)
	local sCastType = 'none'

	-- Don't use when low HP (costs 100 HP)
	if Fu.GetHP(bot) < 0.4 then return BOT_ACTION_DESIRE_NONE end

	-- Use when going on someone and have enough HP
	if Fu.IsGoingOnSomeone(bot)
	then
		if Fu.IsValidTarget(botTarget)
		and Fu.IsInRange(bot, botTarget, 800)
		and Fu.GetHP(bot) > 0.5
		then
			return BOT_ACTION_DESIRE_HIGH, bot, sCastType, nil
		end
	end

	-- Use when farming neutrals and healthy
	if Fu.IsFarming(bot) and Fu.IsAttacking(bot)
	and Fu.GetHP(bot) > 0.7
	then
		local nNeutralCreeps = bot:GetNearbyNeutralCreeps(600)
		if nNeutralCreeps ~= nil and #nNeutralCreeps >= 2
		then
			return BOT_ACTION_DESIRE_HIGH, bot, sCastType, nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Stonefeather Satchel: toggle between Feathers (MS) and Rocks (armor), 6s CD
X.ConsiderItemDesire["item_stonefeather_satchel"] = function(hItem)
	local sCastType = 'none'
	local nEnemyHeroes = Fu.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE)

	-- Toggle to Rocks (armor) mode when in danger
	if #nEnemyHeroes >= 1
	and (Fu.IsRetreating(bot) or Fu.GetHP(bot) < 0.5)
	and not bot:HasModifier('modifier_item_stonefeather_satchel_rocks')
	then
		return BOT_ACTION_DESIRE_HIGH, bot, sCastType, nil
	end

	-- Toggle to Feathers (MS) mode when safe
	if #nEnemyHeroes == 0
	and not bot:HasModifier('modifier_item_stonefeather_satchel_feathers')
	then
		return BOT_ACTION_DESIRE_MODERATE, bot, sCastType, nil
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Royal Jelly
local royalJellyTime = nil
X.ConsiderItemDesire["item_royal_jelly"] = function(hItem)
	if royalJellyTime == nil
	then
		royalJellyTime = DotaTime()
	else
		if royalJellyTime < DotaTime() - 2.0
		then
			local targetAlly = nil

			for i = 1, #GetTeamPlayers( GetTeam() )
			do
				local allyHero = GetTeamMember(i)

				if Fu.IsValidHero(allyHero)
				and Fu.IsCore(allyHero)
				and not allyHero:IsIllusion()
				and not allyHero:HasModifier('modifier_royal_jelly')
				then
					targetAlly = allyHero
				end
			end

			if targetAlly ~= nil
			then
				royalJellyTime = nil
				return BOT_ACTION_DESIRE_HIGH, targetAlly, 'unit', nil
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- TIER 2

-- Vambrace
-- X.ConsiderItemDesire["item_vambrace"] = function(hItem)
-- 	return X.ConsiderItemDesire["item_power_treads"](hItem)
-- end

-- Bullwhip
X.ConsiderItemDesire["item_bullwhip"] = function(hItem)
	local nCastRange = 850 + aetherRange

	if Fu.IsGoingOnSomeone(bot)
	then
		if Fu.IsValidHero(botTarget)
		and Fu.CanCastOnNonMagicImmune(botTarget)
		and Fu.IsChasingTarget(bot, botTarget)
		and not Fu.IsDisabled(botTarget)
		then
			return BOT_ACTION_DESIRE_HIGH, botTarget, 'unit', nil
		end
	end

	local nInRangeAlly = Fu.GetAlliesNearLoc(bot:GetLocation(), nCastRange)
	for _, allyHero in pairs(nInRangeAlly)
	do
		if Fu.IsValidHero(allyHero)
		and Fu.CanCastOnNonMagicImmune(allyHero)
		then
			local nAllyInRangeEnemy = Fu.GetNearbyHeroes(allyHero, 1200, true, BOT_MODE_NONE)

			if nAllyInRangeEnemy ~= nil and #nAllyInRangeEnemy >= 1
			and Fu.IsRetreating(allyHero)
			and allyHero:DistanceFromFountain() > 1200
			and not Fu.IsRealInvisible(allyHero)
			and not Fu.IsDisabled(allyHero)
			then
				return BOT_ACTION_DESIRE_HIGH, allyHero, 'unit', nil
			end
		end
	end

	if hItem:IsFullyCastable()
	then
		return BOT_ACTION_DESIRE_HIGH, bot, 'unit', nil
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Light Collector
X.ConsiderItemDesire["item_light_collector"] = function(hItem)
	local nRadius = 325
	local nInRangeTrees = bot:GetNearbyTrees(nRadius)

	if Fu.IsGoingOnSomeone(bot)
	then
		if nInRangeTrees ~= nil and #nInRangeTrees >= 3
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Iron Talon
X.ConsiderItemDesire["item_iron_talon"] = function(hItem)
	local nCastRange = 350

	-- Only use it for creeps
	if Fu.IsFarming(bot)
	then
		local nCreep = bot:GetNearbyNeutralCreeps(nCastRange)
		if #nCreep <= 0 then return 0 end

		local creepTarget = Fu.GetMostHpUnit(nCreep)
		if Fu.CanBeAttacked(creepTarget)
		and Fu.GetHP(creepTarget) > 0.5
		then
			return BOT_ACTION_DESIRE_HIGH, creepTarget, 'unit', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- TIER 3

-- Craggy Coat
X.ConsiderItemDesire["item_craggy_coat"] = function(hItem)
	local nRadius = 1200

	if Fu.IsInTeamFight(bot)
	then
		local realEnemyCount = Fu.GetEnemiesNearLoc(bot:GetLocation(), nRadius)

        if realEnemyCount ~= nil and #realEnemyCount >= 2
		and bot:WasRecentlyDamagedByAnyHero(1.5)
        then
            return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
        end
	end

    if Fu.IsGoingOnSomeone(bot)
	then
		local nInRangeAlly = Fu.GetNearbyHeroes(bot,1200, false, BOT_MODE_NONE)

        if Fu.IsValidTarget(botTarget)
        and Fu.IsAttacking(botTarget)
		and bot:WasRecentlyDamagedByAnyHero(1.3)
        and Fu.IsInRange(bot, botTarget, 600)
        and not Fu.IsSuspiciousIllusion(botTarget)
        then
            local nTargetInRangeAlly = Fu.GetNearbyHeroes(botTarget, 1200, false, BOT_MODE_NONE)

            if nInRangeAlly ~= nil and nTargetInRangeAlly ~= nil
            and #nInRangeAlly >= #nTargetInRangeAlly
            then
                return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
            end
        end
	end

	if Fu.IsDoingRoshan(bot)
    then
        if Fu.IsRoshan(botTarget)
        and Fu.IsInRange(bot, botTarget, 500)
        and Fu.IsAttacking(bot)
        then
            return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
        end
    end

    if Fu.IsDoingTormentor(bot)
    then
        if Fu.IsTormentor(botTarget)
        and Fu.IsInRange(bot, botTarget, 500)
        and Fu.IsAttacking(bot)
        then
            return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
        end
    end

	return BOT_ACTION_DESIRE_NONE
end

-- Psychic Headband
X.ConsiderItemDesire["item_psychic_headband"] = function(hItem)
	local nCastRange = 600 + aetherRange
	local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), nCastRange)

	if Fu.IsRetreating(bot)
	then	
		if Fu.IsValidHero(nInRangeEnemy[1])
		and Fu.CanCastOnNonMagicImmune(nInRangeEnemy[1])
		and Fu.IsRunning(nInRangeEnemy[1])
		and nInRangeEnemy[1]:IsFacingLocation(bot:GetLocation(), 30)
		and not Fu.IsSuspiciousIllusion(nInRangeEnemy[1])
		and not Fu.IsDisabled(nInRangeEnemy[1])
		then
			return BOT_ACTION_DESIRE_HIGH, nInRangeEnemy[1], 'unit', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Ogre Seal Totem
X.ConsiderItemDesire["item_ogre_seal_totem"] = function(hItem)
	local nFlopRadius = 275
	local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), nFlopRadius * 2)

	if Fu.IsGoingOnSomeone(bot)
	then
		local nInRangeAlly = Fu.GetNearbyHeroes(bot,1000, false, BOT_MODE_NONE)

		if Fu.IsValidTarget(botTarget)
		and Fu.CanCastOnNonMagicImmune(botTarget)
		and bot:IsFacingLocation(botTarget:GetLocation(), 5)
		and Fu.IsInRange(bot, botTarget, nFlopRadius * 2)
		and not Fu.IsInRange(bot, botTarget, nFlopRadius - 75)
		and not Fu.IsSuspiciousIllusion(botTarget)
		and not bot:HasModifier('modifier_abaddon_borrowed_time')
		and not bot:HasModifier('modifier_necrolyte_reapers_scythe')
		and not Fu.IsLocationInChrono(botTarget:GetLocation())
		and not Fu.IsLocationInBlackHole(botTarget:GetLocation())
		then
			local nTargetInRangeAlly = Fu.GetNearbyHeroes(botTarget, 1000, false, BOT_MODE_NONE)

			if nInRangeAlly ~= nil and nTargetInRangeAlly ~= nil
			and #nInRangeAlly >= #nTargetInRangeAlly
			then
				return BOT_ACTION_DESIRE_HIGH, bot, 'unit', nil
			end
		end
	end

	if Fu.IsRetreating(bot)
	then	
		if Fu.IsValidHero(nInRangeEnemy[1])
		and Fu.IsRunning(nInRangeEnemy[1])
		and bot:IsFacingLocation(Fu.GetEscapeLoc(), 15)
		and nInRangeEnemy[1]:IsFacingLocation(bot:GetLocation(), 30)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Doubloon
local currState = 'health'
X.ConsiderItemDesire["item_doubloon"] = function(hItem)
	local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), 1000)

	if Fu.IsGoingOnSomeone(bot)
	then
		local nInRangeAlly = Fu.GetNearbyHeroes(bot,1000, false, BOT_MODE_NONE)

		if Fu.IsValidTarget(botTarget)
		and Fu.IsInRange(bot, botTarget, 1000)
		and Fu.GetHP(bot) > 0.8
		and Fu.GetMP(bot) < 0.5
		and currState == 'mana'
		and not Fu.IsSuspiciousIllusion(botTarget)
		then
			currState = 'health'
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	if Fu.IsRetreating(bot)
	then	
		if Fu.IsValidHero(nInRangeEnemy[1])
		and Fu.IsRunning(nInRangeEnemy[1])
		and nInRangeEnemy[1]:IsFacingLocation(bot:GetLocation(), 30)
		and bot:WasRecentlyDamagedByAnyHero(1.5)
		and Fu.GetHP(bot) < 0.5
		and Fu.GetMP(bot) > 0.75
		and currState == 'health'
		then
			currState = 'mana'
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- TIER 4

-- Ninja Gear
X.ConsiderItemDesire["item_ninja_gear"] = function(hItem)
	local nCastRange = 1600

	if Fu.IsGoingOnSomeone(bot)
	then
		if Fu.IsValidTarget(botTarget)
		and Fu.CanCastOnMagicImmune(botTarget)
		and Fu.IsInRange(bot, botTarget, 2800)
		and not Fu.IsInRange(bot, botTarget, botTarget:GetCurrentVisionRange() + 200)
		and not Fu.IsSuspiciousIllusion(botTarget)
		then
			local nEnemyLaneCreeps = bot:GetNearbyLaneCreeps(800, true)
			local nEnemyTowers = bot:GetNearbyTowers(700, true)

			if nEnemyLaneCreeps ~= nil and #nEnemyLaneCreeps == 0
			and nEnemyTowers ~= nil and #nEnemyTowers == 0
			then
				return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
			end
		end
	end

	if Fu.IsDefending(bot)
	then
		local nMode = bot:GetActiveMode()
		local nLane = LANE_MID

		if nMode == BOT_MODE_PUSH_TOWER_TOP then nLane = LANE_TOP end
		if nMode == BOT_MODE_PUSH_TOWER_BOT then nLane = LANE_BOT end

		local nPushLoc = GetLaneFrontLocation(team, nLane, 0)
		if GetUnitToLocationDistance(bot, nPushLoc) > 3200
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	if Fu.IsDoingRoshan(bot)
    then
        if Fu.CheckTimeOfDay() == 'day'
        and GetUnitToLocationDistance(bot, Fu.Utils.RadiantRoshanLoc) > 3200
        then
            return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end

		if Fu.CheckTimeOfDay() == 'night'
        and GetUnitToLocationDistance(bot, Fu.Utils.DireRoshanLoc) > 3200
        then
            return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
        end
    end

	if Fu.IsDoingTormentor(bot)
	and GetUnitToLocationDistance(bot, Fu.GetTormentorLocation(GetTeam())) > 3200
	then
		return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Trickster Cloak
X.ConsiderItemDesire["item_trickster_cloak"] = function(hItem)
	return X.ConsiderItemDesire["item_invis_sword"](hItem)
end

-- Havoc Hammer
X.ConsiderItemDesire["item_havoc_hammer"] = function(hItem)
	local nRadius = 400
	local nDamage = 175 + bot:GetAttributeValue(ATTRIBUTE_STRENGTH) * 1.5

	local nEnemyHeroes = Fu.GetNearbyHeroes(bot,nRadius, true, BOT_MODE_NONE)
    for _, enemyHero in pairs(nEnemyHeroes)
    do
        if Fu.IsValidHero(enemyHero)
        and Fu.CanCastOnNonMagicImmune(enemyHero)
        and Fu.CanKillTarget(enemyHero, nDamage, DAMAGE_TYPE_MAGICAL)
        and not Fu.IsSuspiciousIllusion(enemyHero)
        and not enemyHero:HasModifier('modifier_abaddon_borrowed_time')
        and not enemyHero:HasModifier('modifier_dazzle_shallow_grave')
        and not enemyHero:HasModifier('modifier_oracle_false_promise_timer')
        and not enemyHero:HasModifier('modifier_templar_assassin_refraction_absorb')
        then
            return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
        end
    end

	if Fu.IsInTeamFight(bot, 1200)
	then
		local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), 1000)

		if nInRangeEnemy ~= nil and #nInRangeEnemy >= 2
        then
            local realEnemyCount = Fu.GetEnemiesNearLoc(bot:GetLocation(), nRadius)

            if realEnemyCount ~= nil and #realEnemyCount >= 2
            and not Fu.IsLocationInChrono(nInRangeEnemy[1]:GetLocation())
            and not Fu.IsLocationInBlackHole(nInRangeEnemy[1]:GetLocation())
            then
                return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
            end
		end
	end

	if Fu.IsGoingOnSomeone(bot)
	then
		local nInRangeAlly = Fu.GetNearbyHeroes(bot,1000, false, BOT_MODE_NONE)

		if Fu.IsValidTarget(botTarget)
		and Fu.CanCastOnNonMagicImmune(botTarget)
		and Fu.IsInRange(bot, botTarget, nRadius)
		and Fu.IsRunning(botTarget)
		and bot:IsFacingLocation(botTarget:GetLocation(), 30)
		and not botTarget:IsFacingLocation(bot:GetLocation(), 90)
		and not Fu.IsSuspiciousIllusion(botTarget)
		and not Fu.IsDisabled(botTarget)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	if Fu.IsDoingRoshan(bot)
    then
        if Fu.IsRoshan(botTarget)
        and Fu.IsInRange(bot, botTarget, nRadius)
        and Fu.IsAttacking(bot)
        then
            return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
        end
    end

    if Fu.IsDoingTormentor(bot)
    then
        if Fu.IsTormentor(botTarget)
        and Fu.IsInRange(bot, botTarget, nRadius)
        and Fu.IsAttacking(bot)
        then
            return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
        end
    end

	return BOT_ACTION_DESIRE_NONE
end

-- Martyrdom
X.ConsiderItemDesire["item_martyrs_plate"] = function(hItem)
	local nRadius = 900

	if Fu.IsInTeamFight(bot)
	then
		local nInRangeAlly = Fu.GetAlliesNearLoc(bot:GetLocation(), nRadius)
		local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), nRadius)

		if nInRangeEnemy ~= nil and #nInRangeEnemy >= 2
		then
			if Fu.IsValidHero(nInRangeEnemy[1])
			and Fu.IsValidHero(nInRangeEnemy[2])
			and Fu.IsAttacking(nInRangeEnemy[1])
			and Fu.IsAttacking(nInRangeEnemy[2])
			and Fu.GetHP(bot) > 0.88
			and bot:GetHealth() >= 3800
			and not bot:WasRecentlyDamagedByAnyHero(0.8)
			then
				return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- TIER 5

-- Force Boots
X.ConsiderItemDesire["item_force_boots"] = function( hItem )
	local nCastRange = 700 + aetherRange
	local nInRangeEnemy = Fu.GetNearbyHeroes(bot,nCastRange, true, BOT_MODE_NONE)

	if Fu.IsStuck(bot)
	then
		return BOT_ACTION_DESIRE_HIGH, bot, 'unit', nil
	end

	if Fu.IsGoingOnSomeone(bot)
	then
		if Fu.IsValidTarget(botTarget)
		and Fu.IsInRange(bot, botTarget, 900)
		and X.IsWithoutSpellShield(botTarget)
		and not Fu.IsSuspiciousIllusion(botTarget)
		and not Fu.IsLocationInChrono(botTarget:GetLocation())
		and not Fu.IsLocationInBlackHole(botTarget:GetLocation())
		and not botTarget:HasModifier('modifier_necrolyte_reapers_scythe')
		then
			local nInRangeAlly = Fu.GetNearbyHeroes(bot,1200, false, BOT_MODE_NONE)
			local nTargetInRangeAlly = Fu.GetNearbyHeroes(botTarget, 1200, false, BOT_MODE_NONE)

			if nInRangeAlly ~= nil and nTargetInRangeAlly ~= nil
			and #nInRangeAlly >= #nTargetInRangeAlly
			then
				if bot:IsFacingLocation(botTarget:GetLocation(), 15)
				and #nInRangeAlly >= #nTargetInRangeAlly + 1
				then
					return BOT_ACTION_DESIRE_HIGH, bot, 'unit', nil
				end

				local allyCenterLocation = Fu.GetCenterOfUnits(nInRangeAlly)
				if botTarget:IsFacingLocation(allyCenterLocation, 15)
				and GetUnitToLocationDistance(bot, allyCenterLocation ) >= 750
				then
					return BOT_ACTION_DESIRE_HIGH, botTarget, 'unit', nil
				end	
			end		
		end
	end

	if Fu.IsRetreating(bot)
	then
		if nInRangeEnemy ~= nil and #nInRangeEnemy >= 1
		and bot:IsFacingLocation(Fu.GetEscapeLoc(), 30)
		and bot:DistanceFromFountain() > 600
		and not Fu.IsRealInvisible(bot)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'unit', nil
		end
	end

	local nInRangeAlly = Fu.GetAlliesNearLoc(bot:GetLocation(), nCastRange)
	for _, allyHero in pairs(nInRangeAlly)
	do
		if Fu.IsValidHero(allyHero)
		and Fu.CanCastOnNonMagicImmune(allyHero)
		then
			local nAllyInRangeEnemy = Fu.GetNearbyHeroes(allyHero, 1200, true, BOT_MODE_NONE)

			if nAllyInRangeEnemy ~= nil and #nAllyInRangeEnemy >= 1
			and Fu.IsRetreating(allyHero)
			and allyHero:IsFacingLocation(Fu.GetEscapeLoc(), 30)
			and allyHero:DistanceFromFountain() > 600
			and allyHero:WasRecentlyDamagedByAnyHero(2.2)
			and not Fu.IsRealInvisible(allyHero)
			then
				return BOT_ACTION_DESIRE_HIGH, allyHero, 'unit', nil
			end

			if Fu.IsGoingOnSomeone(allyHero)
			then
				local allyTarget = Fu.GetProperTarget(allyHero)

				if Fu.IsValidHero(allyTarget)
				and Fu.CanCastOnNonMagicImmune(allyTarget)
				and allyHero:IsFacingLocation(allyTarget:GetLocation(), 15 )
				and GetUnitToUnitDistance(allyHero, allyTarget) > allyHero:GetAttackRange() + 50
				and GetUnitToUnitDistance(allyHero, allyTarget) < allyHero:GetAttackRange() + 700
				and Fu.IsRunning(allyTarget)
				and Fu.GetEnemyCount(allyHero, 1600) <= 3
				and not allyTarget:IsFacingLocation(allyHero:GetLocation(), 40)
				and not Fu.IsSuspiciousIllusion(allyTarget)
				then
					return BOT_ACTION_DESIRE_HIGH, allyHero, 'unit', nil
				end
			end

			if Fu.IsStuck(allyHero)
			then
				return BOT_ACTION_DESIRE_HIGH, allyHero, 'unit', nil
			end
		end

	end

	if bot:DistanceFromFountain() < 2800
	then
		for _, enemyHero in pairs(nInRangeEnemy)
		do
			if Fu.IsValidHero(enemyHero)
			and Fu.CanCastOnMagicImmune(enemyHero)
			and enemyHero:IsFacingLocation(GetAncient(team):GetLocation(), 30)
			and GetUnitToLocationDistance(enemyHero, GetAncient(team):GetLocation()) < 1600
			and not Fu.IsSuspiciousIllusion(enemyHero)
			then
				local nInRangeAlly = Fu.GetNearbyHeroes(bot,1000, false, BOT_MODE_NONE)
				local nTargetInRangeAlly = Fu.GetNearbyHeroes(enemyHero, 1000, false, BOT_MODE_NONE)

				if nInRangeAlly ~= nil and nTargetInRangeAlly ~= nil
				and #nInRangeAlly >= #nTargetInRangeAlly
				then
					return BOT_ACTION_DESIRE_HIGH, enemyHero, 'unit', nil
				end
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Seer Stone
X.ConsiderItemDesire["item_seer_stone"] = function(hItem)
	local nRadius = 800

	-- In Fights
	if Fu.IsGoingOnSomeone(bot)
	then
		local nLocationAoE = bot:FindAoELocation(true, true, bot:GetLocation(), 1600, nRadius, 0, 0)
		local nInRangeEnemy = Fu.GetEnemiesNearLoc(nLocationAoE.targetloc, nRadius)

		local targetHero = nil
		for _, enemyHero in pairs(nInRangeEnemy)
		do
			if Fu.IsValidHero(enemyHero)
			and Fu.IsInRange(bot, enemyHero, nRadius)
			and Fu.CanCastOnMagicImmune(enemyHero)
			and Fu.HasInvisibilityOrItem(enemyHero)
			and not enemyHero:HasModifier('modifier_slardar_amplify_damage')
			and not enemyHero:HasModifier('modifier_item_dustofappearance')
			and not Fu.Site.IsLocationHaveTrueSight(enemyHero:GetLocation())
			then
				return BOT_ACTION_DESIRE_HIGH, nLocationAoE.targetloc, 'ground', nil
			end
		end

	end

	-- For Roshan Scout
	local nInSightEnemy = 0
	for _, enemyHero in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES))
	do
		if Fu.IsValidHero(enemyHero)
		and not Fu.IsSuspiciousIllusion(enemyHero)
		then
			nInSightEnemy = nInSightEnemy + 1
		end
	end

	if Fu.IsRoshanAlive()
	and nInSightEnemy == 0
	then
		if Fu.CheckTimeOfDay() == 'day'
		and GetUnitToLocationDistance(bot, Fu.Utils.RadiantRoshanLoc) > 1600
		then
			return BOT_ACTION_DESIRE_HIGH, Fu.Utils.RadiantRoshanLoc, 'ground', nil
		end

		if Fu.CheckTimeOfDay() == 'night'
		and GetUnitToLocationDistance(bot, Fu.Utils.DireRoshanLoc) > 1600
		then
			return BOT_ACTION_DESIRE_HIGH, Fu.Utils.DireRoshanLoc, 'ground', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Book of the Dead
X.ConsiderItemDesire["item_demonicon"] = function(hItem)
	local nCastRange = 750
	local nInRangeEnmyList = Fu.GetNearbyHeroes(bot, nCastRange, true, BOT_MODE_NONE )

	if Fu.IsPushing(bot)
	then
		local nEnemyTowers = bot:GetNearbyTowers(900, true)
		local nLaneCreeps = bot:GetNearbyLaneCreeps(900, false)

		if nEnemyTowers ~= nil and #nEnemyTowers >= 1
		and nLaneCreeps ~= nil and #nLaneCreeps >= 3
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	if Fu.IsValidTarget(botTarget)
	and Fu.IsInRange(bot, botTarget, 1000)
	and not botTarget:HasModifier('modifier_abaddon_borrowed_time')
	then
		local nTargetInRangeAlly = Fu.GetNearbyHeroes(botTarget, 1000, false, BOT_MODE_NONE)

		if nTargetInRangeAlly ~= nil
		then
			if #nTargetInRangeAlly == 0
			-- and Fu.IsCore(botTarget)
			then
				return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
			end

			if #nTargetInRangeAlly >= 1
			then
				return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Arcanist's Armor
X.ConsiderItemDesire["item_force_field"] = function(hItem)
	local nRadius = 1200
	local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), nRadius)


	for _, enemyHero in pairs(nInRangeEnemy)
	do
		if Fu.IsValidHero(enemyHero)
		and enemyHero:GetAttackTarget() == bot
		and (bot:WasRecentlyDamagedByHero(enemyHero, 5)
			or Fu.IsAttackProjectileIncoming(bot, 500))
		and not Fu.IsSuspiciousIllusion(enemyHero)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Pirate Hat
X.ConsiderItemDesire['item_pirate_hat'] = function(hItem)
	return X.ConsiderItemDesire["item_trusty_shovel"](hItem)
end

-- Mana Draught
X.ConsiderItemDesire["item_mana_draught"] = function( hItem )
	local nEnemyHeroes = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)

	if #nEnemyHeroes == 0
	or (Fu.IsValidHero(nEnemyHeroes[1]) and not Fu.IsInRange(bot, nEnemyHeroes[1], 800) and not bot:WasRecentlyDamagedByAnyHero(5.0))
	then
		if Fu.GetMP(bot) < 0.5 then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Pollywog Charm
X.ConsiderItemDesire["item_polliwog_charm"] = function( hItem )
	local nCastRange = 1000

	if bot:GetMana() < 75 + 40 then
		return BOT_ACTION_DESIRE_NONE
	end

	local nAllyHeroes = Fu.GetAlliesNearLoc(bot:GetLocation(), nCastRange)
	local hNeedHealAlly = nil
	local nNeedHealAllyHealth = 99999
	for _, allyHero in pairs(nAllyHeroes) do
		if Fu.IsValidHero(allyHero)
		and not allyHero:IsIllusion()
		and not allyHero:HasModifier("modifier_abaddon_borrowed_time")
		and not allyHero:HasModifier("modifier_necrolyte_reapers_scythe")
		and not allyHero:HasModifier("modifier_filler_heal")
		and not allyHero:HasModifier("modifier_elixer_healing")
		and not allyHero:HasModifier("modifier_flask_healing")
		and not allyHero:HasModifier("modifier_juggernaut_healing_ward_heal")
		and not allyHero:HasModifier("modifier_juggernaut_healing_ward_heal")
		and not allyHero:IsChanneling()
		and (allyHero:GetMaxHealth() - allyHero:GetHealth() > 100)
		then
			if allyHero:GetHealth() < nNeedHealAllyHealth then
				hNeedHealAlly = allyHero
				nNeedHealAllyHealth = allyHero:GetHealth()
			end
		end
	end

	if hNeedHealAlly ~= nil then
		return BOT_ACTION_DESIRE_HIGH, hNeedHealAlly, 'unit', nil
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Ripper's Lash
X.ConsiderItemDesire["item_rippers_lash"] = function( hItem )
	local nCastRange = 700
	local nRadius = 200

	local nAllyHeroes = Fu.GetAlliesNearLoc(bot:GetLocation(), nCastRange)
	for _, allyHero in pairs(nAllyHeroes) do
		if Fu.IsValidHero(allyHero) and not allyHero:IsIllusion() then
			local hAllyTarget = allyHero:GetAttackTarget()
			if Fu.IsGoingOnSomeone(allyHero) and Fu.IsAttacking(allyHero) then
				if Fu.IsValidHero(hAllyTarget)
				and Fu.CanBeAttacked(hAllyTarget)
				and Fu.IsInRange(allyHero, hAllyTarget, allyHero:GetAttackRange() + 50)
				and Fu.IsInRange(bot, hAllyTarget, nCastRange)
				and not Fu.IsSuspiciousIllusion(hAllyTarget)
				and not hAllyTarget:HasModifier('modifier_abaddon_borrowed_time')
				and not hAllyTarget:HasModifier('modifier_necrolyte_reapers_scythe')
				and not hAllyTarget:HasModifier('modifier_dazzle_shallow_grave')
				then
					local nLocationAoE = bot:FindAoELocation(true, true, hAllyTarget:GetLocation(), 0, nRadius, 0, 0)
					if nLocationAoE.count >= 2 then
						return BOT_ACTION_DESIRE_HIGH, nLocationAoE.targetloc, 'point', nil
					else
						return BOT_ACTION_DESIRE_HIGH, hAllyTarget:GetLocation(), 'point', nil
					end
				end
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Gale Guard
X.ConsiderItemDesire["item_gale_guard"] = function( hItem )
    local nAllyHeroes = bot:GetNearbyHeroes(1600, false, BOT_MODE_NONE)
    local nEnemyHeroes = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)

	if bot:HasModifier('modifier_abaddon_aphotic_shield') or not Fu.CanBeAttacked(bot) then
		return BOT_ACTION_DESIRE_NONE
	end

	if bot:IsRooted() and #nEnemyHeroes > 0 then
		return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
	end

	if Fu.IsGoingOnSomeone(bot) then
		if Fu.IsValidHero(botTarget)
		and Fu.IsInRange(bot, botTarget, bot:GetAttackRange() + 300)
		and (Fu.GetHP(bot) < 0.65 and bot:WasRecentlyDamagedByAnyHero(3.0))
		and not Fu.IsSuspiciousIllusion(botTarget)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

	if Fu.IsRetreating(bot) and not Fu.IsRealInvisible(bot) then
		for _, enemyHero in pairs(nEnemyHeroes) do
            if Fu.IsValidHero(enemyHero)
            and Fu.IsInRange(bot, enemyHero, 800)
            and Fu.IsChasingTarget(enemyHero, bot)
			and not Fu.IsSuspiciousIllusion(enemyHero)
            then
                if #nEnemyHeroes > #nAllyHeroes or (Fu.GetHP(bot) < 0.55 and bot:WasRecentlyDamagedByAnyHero(3.0)) then
                    return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
                end
            end
        end
	end

    if Fu.IsFarming(bot) then
        local nEnemyCreeps = bot:GetNearbyCreeps(1600, true)
		if nEnemyCreeps then
			if  Fu.IsValid(nEnemyCreeps[1])
			and Fu.CanBeAttacked(nEnemyCreeps[1])
			and Fu.GetHP(bot) < 0.25
			and Fu.IsAttacking(bot)
			then
				return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
			end
		end
    end

    if Fu.IsDoingRoshan(bot) then
        if  Fu.IsRoshan(botTarget)
		and Fu.CanBeAttacked(botTarget)
        and Fu.IsInRange(bot, botTarget, 500)
        and Fu.IsAttacking(bot)
		and Fu.GetHP(bot) < 0.5
        then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
        end
    end

    if Fu.IsDoingTormentor(bot) then
        if  Fu.IsTormentor(botTarget)
        and Fu.IsInRange(bot, botTarget, 400)
        and Fu.IsAttacking(bot)
		and Fu.GetHP(bot) < 0.5
        then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
        end
    end

	return BOT_ACTION_DESIRE_NONE
end

-- Crippling Crossbow
X.ConsiderItemDesire["item_crippling_crossbow"] = function( hItem )
	local nCastRange = Fu.GetProperCastRange(false, bot, hItem:GetCastRange())
	local nDamage = hItem:GetSpecialValueInt('damage')

	local nAllyHeroes = bot:GetNearbyHeroes(1600, false, BOT_MODE_NONE)
    local nEnemyHeroes = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)

	for _, enemyHero in pairs(nEnemyHeroes) do
        if  Fu.IsValidHero(enemyHero)
        and Fu.IsInRange(bot, enemyHero, nCastRange)
		and not Fu.IsInRange(bot, enemyHero, nCastRange / 2)
        and Fu.CanCastOnNonMagicImmune(enemyHero)
        and Fu.CanCastOnTargetAdvanced(enemyHero)
        then
            if  Fu.CanKillTarget(enemyHero, nDamage, DAMAGE_TYPE_MAGICAL)
            and not enemyHero:HasModifier('modifier_abaddon_borrowed_time')
            and not enemyHero:HasModifier('modifier_dazzle_shallow_grave')
            and not enemyHero:HasModifier('modifier_necrolyte_reapers_scythe')
            and not enemyHero:HasModifier('modifier_oracle_false_promise_timer')
            then
                return BOT_ACTION_DESIRE_HIGH, enemyHero, 'unit', nil
            end
        end
    end

	if Fu.IsGoingOnSomeone(bot) then
		if Fu.IsValidHero(botTarget)
		and Fu.CanBeAttacked(botTarget)
		and Fu.CanCastOnNonMagicImmune(botTarget)
		and Fu.CanCastOnTargetAdvanced(botTarget)
		and Fu.IsInRange(bot, botTarget, nCastRange)
		and not Fu.IsInRange(bot, botTarget, nCastRange / 2)
		and Fu.IsChasingTarget(bot, botTarget)
		then
			return BOT_ACTION_DESIRE_HIGH, botTarget, 'unit', nil
		end
	end

	if Fu.IsRetreating(bot) and not Fu.IsRealInvisible(bot) then
		for _, enemyHero in pairs(nEnemyHeroes) do
            if  Fu.IsValidHero(enemyHero)
            and Fu.IsInRange(bot, enemyHero, nCastRange)
            and Fu.CanCastOnNonMagicImmune(enemyHero)
            and Fu.CanCastOnTargetAdvanced(enemyHero)
            and Fu.IsChasingTarget(enemyHero, bot)
            and not Fu.IsDisabled(enemyHero)
            then
                if #nEnemyHeroes > #nAllyHeroes or (Fu.GetHP(bot) < 0.55 and bot:WasRecentlyDamagedByAnyHero(3.0)) then
                    return BOT_ACTION_DESIRE_HIGH, enemyHero, 'unit', nil
                end
            end
        end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Pyrrhic Cloak
X.ConsiderItemDesire["item_pyrrhic_cloak"] = function( hItem )
	local nCastRange = Fu.GetProperCastRange(false, bot, hItem:GetCastRange())

    local nEnemyHeroes = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)

	if Fu.IsNotAttackProjectileIncoming(bot, 400)
	and Fu.IsValidHero(nEnemyHeroes[1])
	and Fu.IsInRange(bot, nEnemyHeroes[1], nCastRange)
	and Fu.CanCastOnNonMagicImmune(nEnemyHeroes[1])
	and Fu.CanCastOnTargetAdvanced(nEnemyHeroes[1])
	then
		return BOT_ACTION_DESIRE_HIGH, nEnemyHeroes[1], 'unit', nil
	end

	for _, enemyHero in pairs(nEnemyHeroes)do
		if Fu.IsValidHero(enemyHero)
		and Fu.IsInRange(bot, enemyHero, nCastRange)
		and Fu.CanCastOnNonMagicImmune(enemyHero)
		and Fu.CanCastOnTargetAdvanced(enemyHero)
		and (enemyHero:GetAttackTarget() == bot)
		and (bot:WasRecentlyDamagedByHero(enemyHero, 3.0) or Fu.IsAttackProjectileIncoming(bot, 1000))
		then
			return BOT_ACTION_DESIRE_HIGH, enemyHero, 'unit', nil
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

-- Minotaur Horn
X.ConsiderItemDesire["item_minotaur_horn"] = function( hItem )
	if bot:IsMagicImmune()
	or not Fu.CanBeAttacked(bot)
	or not bot:HasModifier('modifier_item_lotus_orb_active')
    or not bot:HasModifier('modifier_antimage_spell_shield')
	then
        return BOT_ACTION_DESIRE_NONE
    end

    local nEnemyHeroes = Fu.GetEnemiesNearLoc(bot:GetLocation(), 1200)

	if (Fu.IsGoingOnSomeone(bot) or (Fu.IsRetreating(bot) and not Fu.IsRealInvisible(bot)))
    and #nEnemyHeroes > 0
	then
		if bot:IsRooted() then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end

        nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), 600)
		if bot:IsSilenced()
        and #nInRangeEnemy >= 2
        and not bot:HasModifier('modifier_item_mask_of_madness_berserk')
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end

		if Fu.IsNotAttackProjectileIncoming(bot, 300)
		or Fu.IsWillBeCastUnitTargetSpell(bot, 300)
		or Fu.IsWillBeCastPointSpell(bot, 300)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end

        nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), 1200)
		if #nInRangeEnemy > #nAllyHeroes
        and Fu.GetHP(bot) < 0.6
        and Fu.IsValidHero(nInRangeEnemy[1])
        and (Fu.IsChasingTarget(nInRangeEnemy[1], bot) or nInRangeEnemy[1]:GetAttackTarget() == bot)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
		end
	end

    if bot:HasModifier('modifier_jakiro_macropyre_burn')
    or bot:HasModifier('modifier_lich_chainfrost_slow')
    or bot:HasModifier('modifier_crystal_maiden_freezing_field_slow')
    or bot:HasModifier('modifier_puck_coiled')
    or bot:HasModifier('modifier_skywrath_mystic_flare_aura_effect')
    or bot:HasModifier('modifier_snapfire_magma_burn_slow')
    or bot:HasModifier('modifier_sand_king_epicenter_slow')
    then
        return BOT_ACTION_DESIRE_HIGH, bot, 'none', nil
    end

	return BOT_ACTION_DESIRE_NONE
end

-- Book of Shadows
X.ConsiderItemDesire["item_book_of_shadows"] = function( hItem )
	local nCastRange = 700 + aetherRange
	local nInRangeAlly = Fu.GetAlliesNearLoc(bot:GetLocation(), nCastRange)
	local nInRangeEnemy = Fu.GetEnemiesNearLoc(bot:GetLocation(), 1200)

	for _, allyHero in pairs(nInRangeAlly)
	do
		if Fu.IsValidHero(allyHero)
		and Fu.CanCastOnNonMagicImmune(allyHero)
		and allyHero:WasRecentlyDamagedByAnyHero(3)
		then
			local nAllyInRangeEnemy = Fu.GetNearbyHeroes(allyHero, 1200, true, BOT_MODE_NONE)

			if nAllyInRangeEnemy ~= nil and #nAllyInRangeEnemy >= 1
			and Fu.IsRetreating(allyHero)
			and not Fu.IsRealInvisible(allyHero)
			and not Fu.IsDisabled(allyHero)
			and allyHero:DistanceFromFountain() > 1200
			then
				return BOT_ACTION_DESIRE_HIGH, allyHero, 'unit', nil
			end
		end
	end

	return BOT_ACTION_DESIRE_NONE
end

function X.IsTargetedByEnemy( building )

	local heroList = GetUnitList( UNIT_LIST_ENEMY_HEROES )
	for _, hero in pairs( heroList )
	do
		if Fu.IsValidHero(hero) then
			if ( GetUnitToUnitDistance( building, hero ) <= hero:GetAttackRange() + 200
				and hero:GetAttackTarget() == building )
			then
				return true
			end
		end
	end

	return false

end

local function UseGlyph()

	if GetGlyphCooldown( ) > 0
		or DotaTime() < 60
		or bot ~= GetTeamMember( 1 )
		or not GetTeamMember( 2 ):IsBot()
		or not GetTeamMember( 3 ):IsBot()
		or not GetTeamMember( 4 ):IsBot()
		or not GetTeamMember( 5 ):IsBot()
	then
		return
	end

	local T1 = {
		TOWER_TOP_1,
		TOWER_MID_1,
		TOWER_BOT_1,
		TOWER_TOP_2,
		TOWER_MID_2,
		TOWER_BOT_2,
		TOWER_TOP_3,
		TOWER_MID_3,
		TOWER_BOT_3,
		TOWER_BASE_1,
		TOWER_BASE_2
	}

	for _, t in pairs( T1 )
	do
		local tower = GetTower( team, t )
		if tower ~= nil and tower:GetHealth() > 0
			and tower:GetHealth() / tower:GetMaxHealth() < 0.36
			and tower:CanBeSeen()
			and X.IsTargetedByEnemy(tower)
		then
			bot:ActionImmediate_Glyph( )
			return
		end
	end


	local MeleeBarrack = {
		BARRACKS_TOP_MELEE,
		BARRACKS_MID_MELEE,
		BARRACKS_BOT_MELEE
	}

	for _, b in pairs( MeleeBarrack )
	do
		local barrack = GetBarracks( team, b )
		if barrack ~= nil and barrack:GetHealth() > 0
			and barrack:GetHealth() / barrack:GetMaxHealth() < 0.5
			and X.IsTargetedByEnemy( barrack )
		then
			bot:ActionImmediate_Glyph( )
			return
		end
	end

	local Ancient = GetAncient( team )
	if Ancient ~= nil and Ancient:GetHealth() > 0
		and Ancient:GetHealth() / Ancient:GetMaxHealth() < 0.5
		and X.IsTargetedByEnemy( Ancient )
	then
		bot:ActionImmediate_Glyph( )
		return
	end

end

-- ============================================================================
-- Smart Bots: human-like reaction delay for spells and items.
-- When a new enemy hero appears within 1600 range, the bot waits Min..Max seconds
-- before casting anything. After finishing a cast, it waits Between_Min..Between_Max.
-- Configure via Customize.Reaction_Delay in Customize/general.lua.
-- ============================================================================
local ReactionDelayCfg = Customize.Reaction_Delay or {}
local bReactionDelayOn = Customize.Enable ~= false and ReactionDelayCfg.Enable ~= false
local fReactionReadyAt = 0
local tSeenEnemyIds = {}
local bWasCasting = false

local function IsReactionReady()
	if not bReactionDelayOn then return true end
	local now = DotaTime()

	local tCurrent = {}
	local bNewEnemy = false
	for _, enemy in pairs(bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE) or {}) do
		if enemy ~= nil and not enemy:IsNull() then
			local id = enemy:GetPlayerID()
			tCurrent[id] = true
			if not tSeenEnemyIds[id] then bNewEnemy = true end
		end
	end
	tSeenEnemyIds = tCurrent
	if bNewEnemy then
		fReactionReadyAt = math.max(fReactionReadyAt, now + RandomFloat(ReactionDelayCfg.Min or 0.25, ReactionDelayCfg.Max or 0.45))
	end

	local bCasting = bot:IsCastingAbility() or bot:IsUsingAbility() or bot:IsChanneling()
	if bWasCasting and not bCasting then
		fReactionReadyAt = math.max(fReactionReadyAt, now + RandomFloat(ReactionDelayCfg.Between_Min or 0.10, ReactionDelayCfg.Between_Max or 0.30))
	end
	bWasCasting = bCasting

	return now >= fReactionReadyAt
end

function ItemUsageThink()
	if not IsReactionReady() then return end
	if bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

	if not Fu.IsNoItemIllution(bot) then ItemUsageComplement() end

	-- Run ability usage in same frame as items to prevent
	-- item actions from clearing queued ability casts between frames
	if BotBuild ~= nil and not Fu.IsNoAbilityIllution(bot) then
		local ok, err = pcall(BotBuild.SkillsComplement)
		if not ok then log('[ERROR] %s SkillsComplement: %s', botName, tostring(err)) end
	end

	-- Dispel check: use dispel items when under dangerous debuffs
	if Dispel and not bot:IsChanneling() then
		-- Manta projectile dodge (highest priority — time-critical)
		local mantaDodgeSlot = Dispel.ShouldMantaDodge(bot)
		if mantaDodgeSlot >= 0 then
			local hItem = bot:GetItemInSlot(mantaDodgeSlot)
			if hItem then
				bot:Action_UseAbility(hItem)
				return
			end
		end

		-- Self-dispel with items (BKB, Manta, Eul's, etc.)
		local selfDispelSlot = Dispel.ShouldUseSelfDispelItem(bot)
		if selfDispelSlot >= 0 then
			local hItem = bot:GetItemInSlot(selfDispelSlot)
			if hItem then
				bot:Action_UseAbility(hItem)
				return
			end
		end

		-- Ally-dispel with Lotus Orb (includes preemptive usage)
		local allyDispelSlot, allyTarget = Dispel.ShouldUseAllyDispelItem(bot)
		if allyDispelSlot >= 0 and allyTarget then
			local hItem = bot:GetItemInSlot(allyDispelSlot)
			if hItem then
				bot:Action_UseAbilityOnEntity(hItem, allyTarget)
				return
			end
		end
	end

	-- Move famango from backpack to main inventory if empty slot available.
	-- Backpack items have cooldown and can't be used — famango needs to be ready.
	for backpackSlot = 6, 8 do
		local bpItem = bot:GetItemInSlot(backpackSlot)
		if bpItem ~= nil then
			local name = bpItem:GetName()
			if name == 'item_famango' or name == 'item_great_famango' or name == 'item_greater_famango' then
				for mainSlot = 0, 5 do
					if bot:GetItemInSlot(mainSlot) == nil then
						bot:ActionImmediate_SwapItems(backpackSlot, mainSlot)
						break
					end
				end
				break
			end
		end
	end
end

function AbilityUsageThink()
	-- Abilities now run inside ItemUsageThink (same frame, after items) to prevent
	-- item actions from clearing queued ability casts.
	HandleIdleBotState(bot)
end

-- End-game chat: only say once per game, randomly 2-3 out of 5 bots
local ggSaid = false
local ggEligible = nil
local ggTriggerTime = 0
local winSaid = false
local winEligible = nil
local winTriggerTime = 0
local EndGameLocalization = nil
local function GetEndGameMsg(key)
	if EndGameLocalization == nil then
		local ok, loc = pcall(require, GetScriptDirectory()..'/FuncLib/systems/localization')
		EndGameLocalization = ok and loc or false
	end
	if EndGameLocalization and EndGameLocalization.Get then
		local msgs = EndGameLocalization.Get(key)
		if msgs and type(msgs) == 'table' and #msgs > 0 then
			return msgs[RandomInt(1, #msgs)]
		end
		if msgs and type(msgs) == 'string' then return msgs end
	end
	-- fallback
	if key == 'say_gg_lose' then
		local fb = { 'gg', 'ggwp', 'GG' }
		return fb[RandomInt(1, #fb)]
	end
	local fb = { 'ez', 'gg ez', 'EZ' }
	return fb[RandomInt(1, #fb)]
end

function BuybackUsageThink()
	if RefreshBotHandle() then return end
	if bot.lastBuybackFrameProcessTime == nil then bot.lastBuybackFrameProcessTime = DotaTime() end
	if DotaTime() > 30 and (DotaTime() - bot.lastBuybackFrameProcessTime < 2) then return end
	bot.lastBuybackFrameProcessTime = DotaTime()
	if not bot:IsIllusion() then BuybackUsageComplement() end
	if not bot:IsIllusion() then UseGlyph() end

	-- Say gg when about to lose
	if not ggSaid and not bot:IsIllusion() and DotaTime() > 10 * 60 then
		local ancient = GetAncient(GetTeam())
		if ancient ~= nil and Fu.GetHP(ancient) < 0.2 and Fu.CanBeAttacked(ancient) then
			local aliveCount = Fu.GetNumOfAliveHeroes(false)
			if aliveCount <= 2 then
				if ggEligible == nil then
					ggEligible = RandomInt(1, 5) <= 3
					ggTriggerTime = DotaTime() + RandomFloat(1, 5)
				end
				if ggEligible and DotaTime() >= ggTriggerTime then
					bot:ActionImmediate_Chat(GetEndGameMsg('say_gg_lose'), true)
					ggSaid = true
				end
			end
		end
	end

	-- Say ez/gl when about to win
	if not winSaid and not bot:IsIllusion() and DotaTime() > 10 * 60 then
		local enemyAncient = GetAncient(GetOpposingTeam())
		if enemyAncient ~= nil and Fu.GetHP(enemyAncient) < 0.2 and Fu.CanBeAttacked(enemyAncient) then
			local aliveCount = Fu.GetNumOfAliveHeroes(false)
			if aliveCount >= 3 then
				if winEligible == nil then
					winEligible = RandomInt(1, 5) <= 3
					winTriggerTime = DotaTime() + RandomFloat(1, 5)
				end
				if winEligible and DotaTime() >= winTriggerTime then
					bot:ActionImmediate_Chat(GetEndGameMsg('say_gg_win'), true)
					winSaid = true
				end
			end
		end
	end
end

function CourierUsageThink()
	if RefreshBotHandle() then return end
	if bot.lastCourierFrameProcessTime == nil then bot.lastCourierFrameProcessTime = DotaTime() end
	if DotaTime() > 30 and (DotaTime() - bot.lastCourierFrameProcessTime < 0.5) then return end
	bot.lastCourierFrameProcessTime = DotaTime()
	if not bot:IsIllusion() then CourierUsageComplement() end
end

function AbilityLevelUpThink()
	if RefreshBotHandle() then return end
	if bot.lastLevelUpFrameProcessTime == nil then bot.lastLevelUpFrameProcessTime = DotaTime() end
	if DotaTime() > 30 and (DotaTime() - bot.lastLevelUpFrameProcessTime < 1) then return end
	bot.lastLevelUpFrameProcessTime = DotaTime()
	if not bot:IsIllusion() then AbilityLevelUpComplement() end
end

function X.SetAbilityItemList(heroAbility, items, abilityLvlup)
	bDeafaultAbilityHero = heroAbility
	bDeafaultItemHero = items
	sAbilityLevelUpList = abilityLvlup
end

X.AbilityLevelUpThink = AbilityLevelUpThink
X.BuybackUsageThink = BuybackUsageThink
X.AbilityUsageThink = AbilityUsageThink
X.ItemUsageThink = ItemUsageThink

return X