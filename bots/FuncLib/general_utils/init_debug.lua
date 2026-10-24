-- Bot initialization, debug output, idle detection, ARDM support
local function Init(Fu)

local bDebugMode = ( 1 == 10 )

function Fu.SetUserHeroInit( nAbilityBuildList, nTalentBuildList, sBuyList, sSellList )
	local bot = GetBot()
	local botName = bot:GetUnitName()
	local sBotDir, tBotSet = "game/Customize/hero/" .. string.gsub(botName, "npc_dota_hero_", ""), nil
	-- Smart Bots: pcall instead of xpcall; a missing optional file made the engine print
	-- "Script Runtime Error: error in error handling" for every bot at game start.
	local status, res = pcall(require, sBotDir)
	tBotSet = status and res or nil
	if not (status and tBotSet) then
		sBotDir = GetScriptDirectory() .. "/Customize/hero/" .. string.gsub(botName, "npc_dota_hero_", "")
		status, res = pcall(require, sBotDir)
		tBotSet = status and res or nil
	end
	if status and tBotSet and tBotSet.Enable then
		nAbilityBuildList = tBotSet.AbilityUpgrade
		nTalentBuildList = Fu.GetTalentBuildList( tBotSet.Talent )
		sBuyList = tBotSet.PurchaseList
		sSellList = tBotSet.SellList
	end
	return nAbilityBuildList, nTalentBuildList, sBuyList, sSellList
end

function Fu.GetTalentBuildList( nLocalList )
	local sTargetList = {}
	for i = 1, #nLocalList
    do
		local rawTalent = nLocalList[i] == 'l' and 10 or 0
		if rawTalent == 10
		then
			sTargetList[#sTargetList + 1] = i * 2
		else
			sTargetList[#sTargetList + 1] = i * 2 - 1
		end
	end
	for i = 1, #nLocalList
    do
		local rawTalent = nLocalList[i] == 'r' and 10 or 0
		if rawTalent ~= 10
		then
			sTargetList[#sTargetList + 1] = i * 2
		else
			sTargetList[#sTargetList + 1] = i * 2 - 1
		end
	end
	return sTargetList
end

function Fu.SetBotPrint( sMessage, vLoc, bReport, bPing )
	local bot = GetBot()
	local nTime = Fu.GetOne( DotaTime() / 10 )* 10
	local sTime = ( Fu.GetOne( nTime / 600 )* 10 )..":"..( nTime%60 )
	local sTeam = GetTeam() == TEAM_DIRE and "夜魇" or "天辉"
	if bDebugMode
	then
		log( "%s%s %s %s", sTeam, sTime, Fu.Chat.GetNormName( bot ), sMessage )
		if bReport then bot:ActionImmediate_Chat( sTime.."_"..sMessage, true ) end
		if bPing then bot:ActionImmediate_Ping( vLoc.x, vLoc.y, false ) end
	end
end

function Fu.SetReportMotive( bDebugFile, sMotive )
	if bDebugMode and bDebugFile and sMotive ~= nil
	then
		local nTime = Fu.GetOne( DotaTime() / 10 ) * 10
		local sTime = ( Fu.GetOne( nTime / 600 ) * 10 )..":"..( nTime%60 )
		local sTeam = GetTeam() == TEAM_DIRE and "夜魇 " or "天辉 "
		GetBot():ActionImmediate_Chat( sTime.."_"..sMotive, true )
		log( "%s%s %s %s", sTeam, sTime, Fu.Chat.GetNormName( GetBot() ), sMotive )
	end
end

function Fu.IsStuck( bot )
	if bot.stuckLoc ~= nil and bot.stuckTime ~= nil and bot:CanBeSeen()
	then
		local attackTarget = bot:GetAttackTarget()
		local EAd = GetUnitToUnitDistance( bot, GetAncient( GetOpposingTeam() ) )
		local TAd = GetUnitToUnitDistance( bot, GetAncient( GetTeam() ) )
		local Et = bot:GetNearbyTowers( 450, true )
		local At = bot:GetNearbyTowers( 450, false )
		if bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO
			and attackTarget == nil and EAd > 2200 and TAd > 2200 and #Et == 0 and #At == 0
			and DotaTime() > bot.stuckTime + 5.0
			and GetUnitToLocationDistance( bot, bot.stuckLoc ) < 25
		then
			log( "%s is stuck", bot:GetUnitName() )
			return true
		end
	end
	return false
end

local botIdelStateTimeThreshold = 5
local deltaIdleDistance = 30
local botIdleStateTracker = { }

function Fu.CheckBotIdleState()
	if DotaTime() <= 0 then return false end
	local bot = GetBot()
	if not bot:IsAlive() then return false end
	local botName = bot:GetUnitName();
	local botId = bot:GetPlayerID();
	local botMode = bot:GetActiveMode();
	local botState = botIdleStateTracker[botId]
	if botState then
		if DotaTime() - botState.lastCheckTime >= botIdelStateTimeThreshold then
			local diffDistance = Fu.GetLocationToLocationDistance( botState.botLocation, bot:GetLocation())
			if not Fu.IsTryingtoUseAbility(bot)
			and not Fu.IsAttacking(bot)
			and diffDistance <= deltaIdleDistance
			then
				botState.idleCount = botState.idleCount + 1
				if bot:GetCurrentActionType() == BOT_ACTION_TYPE_IDLE
				or botMode == BOT_MODE_ITEM
				or botMode == BOT_MODE_FARM then
					local nActions = bot:NumQueuedActions()
					if nActions > 0 then
						for i=1, nActions do
							local aType = bot:GetQueuedActionType(i)
							log('Bot %s has enqueued actions i=%s, type=%s', botName, i, aType)
						end
					end
					bot:Action_ClearActions(true);
					local frontLoc = GetLaneFrontLocation(GetTeam(), bot:GetAssignedLane(), 0);
					bot:ActionQueue_AttackMove(frontLoc)
					log('[ERROR] Relocating the idle bot: %s. Sending it to the lane# it was originally assigned: %s', botName, bot:GetAssignedLane())
				else
					log('Bot %s is in idle state for unknown reasons. N/A.', botName)
				end
				return true
			else
				botState.idleCount = 0
			end
			botState.botLocation = bot:GetLocation()
			botState.lastCheckTime = DotaTime()
		end
	else
		local botIdleState = {
			botLocation = bot:GetLocation(),
			lastCheckTime = DotaTime(),
			idleCount = 0
		}
		botIdleStateTracker[botId] = botIdleState
	end
	return false
end

function Fu.IsStaleARDMHero(cachedBot, cachedName)
	if GetGameMode() ~= GAMEMODE_ARDM then
		return false, cachedBot, cachedName
	end
	local freshBot = GetBot()
	local freshName = freshBot:GetUnitName()
	local nPlayerID = cachedBot:GetPlayerID()
	if freshName ~= cachedName and freshBot ~= cachedBot then
		return true, freshBot, freshName
	end
	if nPlayerID >= 0 and IsHeroAlive(nPlayerID) and not cachedBot:IsAlive() then
		if freshName ~= cachedName then
			return true, freshBot, freshName
		end
	end
	return false, freshBot, freshName
end

function Fu.ModeAnnounce(bot, locKey, cooldown)
	local Localization = require( GetScriptDirectory()..'/FuncLib/systems/localization' )
	if bot.lastModeChatTime == nil then bot.lastModeChatTime = {} end
	local lastTime = bot.lastModeChatTime[locKey] or -999
	if GameTime() - lastTime < (cooldown or 30) then return end
	bot.lastModeChatTime[locKey] = GameTime()
	local msgs = Localization.Get(locKey)
	if msgs ~= nil and #msgs > 0 then
		bot:ActionImmediate_Chat(msgs[RandomInt(1, #msgs)], false)
	end
end

end

return Init
