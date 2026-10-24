local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

if GAMEMODE_ARDM == nil then GAMEMODE_ARDM = 20 end
local Item = require( GetScriptDirectory()..'/FuncLib/systems/item' )
local Role = require( GetScriptDirectory()..'/FuncLib/systems/role' )
local Fu = require( GetScriptDirectory()..'/FuncLib/func_utils')
local Utils = require( GetScriptDirectory()..'/FuncLib/systems/utils')

local X = {}

if bot:IsInvulnerable()
	or not bot:IsHero()
	or bot:IsIllusion()
then
	return
end

local BotBuild = require( GetScriptDirectory() .. "/BotsLib/" .. string.gsub( botName, "npc_dota_", "" ) )

if BotBuild == nil then return end

bot.purchaseListInReverseOrder = {}
bot.currBuyingItemInPurchaseList = nil
bot.currBuyingBasicItem = nil
bot.currBuyingBasicItemList = {}
bot.currBuyingBasicItemRefList = {}

-- track required counts of components to avoid overbuying and to allow re-buying only when missing
bot.currBuyingRequiredCounts = nil         -- map[item_name] = required_count for the current target item
bot._lastPurchaseAttempt = { name = nil, t = -999 }

bot.rebuildCount = 0
bot.SecretShop = false

local sPurchaseList = BotBuild['sBuyList']
local sItemSellList = BotBuild['sSellList']


if sPurchaseList == nil then
	log("[ERROR] Can't load purchase list for: %s", botName)
	log("Stack Trace:", debug.traceback())
	return
end

log("[Purchase] %s loaded %d items: %s -> %s", botName, #sPurchaseList, sPurchaseList[1] or "nil", sPurchaseList[#sPurchaseList] or "nil")

for i = 1, #sPurchaseList
 do
	bot.purchaseListInReverseOrder[i] = sPurchaseList[#sPurchaseList - i + 1]
end

bot.sell_time = -90
local check_time = -90

bot.countInvCheck = 0

bot.lastItemToBuy = nil
bot.bPurchaseFromSecret = false
bot.hasBuyShard = true
local itemCost = 0
local courier = nil
local t3AlreadyDamaged = false
local t3Check = -90

bot.lastInvCheck = -90
bot.fullInvCheck = -90
bot.switchTime = 0
bot.hasBuyClarity = false
local lastBootsCheck = -90
local buyBootsStatus = false
local buyRD = false

local buyWardTime = -999

local buyBookTime = 0

local initSmoke = false

local currentTime, botLevel, botGold, botWorth, botMode, botHP, botCourierValue, botStashValue, botDistanceFromFountain

-- utilities for counting/need detection
local function _countOwnedEverywhere(unit, itemName)
	local count = 0
	for slot = 0, 14 do
		local it = unit:GetItemInSlot(slot)
		if it ~= nil and it:GetName() == itemName then count = count + 1 end
	end
	-- we cannot reliably inspect courier bags here; use conservative logic elsewhere.
	return count
end

local function _buildRequiredCounts(list)
	local m = {}
	for _, n in ipairs(list) do
		m[n] = (m[n] or 0) + 1
	end
	return m
end

-- Items that should never be re-bought in ARDM after hero swap
-- (early game consumables / cheap items that waste gold mid-late game)
local tARDMNeverRebuy = {
	item_tango = true, item_double_tango = true, item_clarity = true,
	item_faerie_fire = true, item_enchanted_mango = true, item_flask = true,
	item_blood_grenade = true, item_branches = true, item_double_branches = true,
	item_magic_stick = true,
	item_magic_wand = true, item_recipe_magic_wand = true,
	item_infused_raindrop = true, item_orb_of_venom = true,
	item_blight_stone = true, item_orb_of_frost = true,
	item_gauntlets = true, item_slippers = true, item_mantle = true,
	item_circlet = true, item_ring_of_protection = true,
	item_bracer = true, item_wraith_band = true, item_null_talisman = true,
	item_soul_ring = true,
}

local function _stillNeeds(itemName)
	-- Don't buy a second pair of basic boots if we already have upgraded boots.
	-- BUT allow buying item_boots when it's a COMPONENT of the current build target
	-- (e.g., building power_treads needs item_boots as a component — don't skip it).
	if itemName == 'item_boots' then
		local currentTarget = bot.currBuyingItemInPurchaseList
		-- Only skip if we have upgraded boots AND the current target is NOT a boots upgrade
		-- (i.e., we're not building treads/arcane/tranquil/phase from basic boots)
		local tBootsUpgrades = {
			item_power_treads = true, item_phase_boots = true,
			item_arcane_boots = true, item_tranquil_boots = true,
			item_travel_boots = true, item_travel_boots_2 = true,
			item_guardian_greaves = true, item_boots_of_bearing = true,
		}
		if Item.HasBootsInMainSolt(bot) and not tBootsUpgrades[currentTarget] then
			return false
		end
	end
	-- In ARDM after laning phase, skip early game items that shouldn't be re-bought
	if GetGameMode() == GAMEMODE_ARDM and DotaTime() > 2 * 60 and tARDMNeverRebuy[itemName] then
		return false
	end
	if not bot.currBuyingRequiredCounts then return true end
	local required = bot.currBuyingRequiredCounts[itemName]
	if not required then return true end
	local have = _countOwnedEverywhere(bot, itemName)
	return have < required
end

local function _popIfNoLongerNeeded()
	while #bot.currBuyingBasicItemList > 0 do
		local name = bot.currBuyingBasicItemList[#bot.currBuyingBasicItemList]
		if _stillNeeds(name) then
			return name
		else
			-- drop this component from the queue; already satisfied (owned/picked earlier)
			bot.currBuyingBasicItemList[#bot.currBuyingBasicItemList] = nil
		end
	end
	return nil
end

local function _antiSpamPurchase(name)
	local t = DotaTime()
	if bot._lastPurchaseAttempt.name == name and t - bot._lastPurchaseAttempt.t < 0.4 then
		return true -- skip this frame
	end
	bot._lastPurchaseAttempt.name, bot._lastPurchaseAttempt.t = name, t
	return false
end

local function HasSufficientTp()
	local tCharges = Item.GetItemCharges( bot, 'item_tpscroll' )
	return tCharges >= 2
		or (tCharges >= 1 and Item.HasItem( bot, 'item_travel_boots' ))
		or (tCharges >= 1 and Item.HasItem( bot, 'item_travel_boots_2' ))
end

local function ClearCurrBuyingBasicItemList()
	-- NOTE: despite its name, this function was used as "pop last component";
	-- keep behavior to avoid regressions.
	bot.countInvCheck = 0
	bot.currBuyingBasicItem = nil
	bot.currBuyingBasicItemList[#bot.currBuyingBasicItemList] = nil
end

-- safe pop entire state when finishing/abandoning a composite item
local function _resetCurrentTarget()
	bot.countInvCheck = 0
	bot.currBuyingItemInPurchaseList = nil
	bot.currBuyingBasicItem = nil
	bot.currBuyingBasicItemList = {}
	bot.currBuyingBasicItemRefList = {}
	bot.currBuyingRequiredCounts = nil
end

local function GeneralPurchase()

	if bot.lastItemToBuy ~= bot.currBuyingBasicItem
	then
		bot.lastItemToBuy = bot.currBuyingBasicItem
		bot:SetNextItemPurchaseValue( GetItemCost( bot.currBuyingBasicItem ) )
		bot.bPurchaseFromSecret = IsItemPurchasedFromSecretShop( bot.currBuyingBasicItem )
		itemCost = GetItemCost( bot.currBuyingBasicItem )
	end

	if bot.currBuyingBasicItem == "item_infused_raindrop"
		or bot.currBuyingBasicItem == "item_tome_of_knowledge"
		or bot.currBuyingBasicItem == "item_flask"
	then
		if GetItemStockCount( bot.currBuyingBasicItem ) <= 0
		then
			ClearCurrBuyingBasicItemList()
			return
		end
	end

	-- if current last component is already satisfied (picked up or bought earlier), skip it
	local neededHead = _popIfNoLongerNeeded()
	if not neededHead then return end -- nothing left; higher-level loop will progress/retarget
	bot.currBuyingBasicItem = neededHead
	if _antiSpamPurchase(bot.currBuyingBasicItem) then return end

	local cost = itemCost

	if bot.lastItemToBuy == 'item_boots'
		and bot.currBuyingItemInPurchaseList == 'item_travel_boots'
		and Item.HasBootsInMainSolt( bot )
	then
		cost = GetItemCost( 'item_travel_boots' )
	end

	if bot:GetLevel() >= 18
		and t3AlreadyDamaged == false
		and DotaTime() > t3Check + 1.0
	then

		for i = 2, 8, 3
		do
			local tower = GetTower( GetTeam(), i )
			if tower == nil or tower:GetHealth() / tower:GetMaxHealth() < 0.3
			then
				t3AlreadyDamaged = true
				break
			end
		end


		for i = 1, 7, 3
		do
			local tower = GetTower( GetTeam(), i )
			if tower ~= nil
				and tower:IsAlive()
			then
				t3AlreadyDamaged = false
				break
			end
		end


		for i = 9, 10, 1
		do
			local tower = GetTower( GetTeam(), i )
			if tower == nil
				or tower:GetHealth() / tower:GetMaxHealth() < 0.9
			then
				t3AlreadyDamaged = true
				break
			end
		end


		if DotaTime() >= 54 * 60 then t3AlreadyDamaged = true end

		t3Check = DotaTime()

	elseif t3AlreadyDamaged == true
			and bot:GetBuybackCooldown() <= 10
	then
		cost = itemCost + bot:GetBuybackCost() + bot:GetNetWorth() / 40 - 300
	end

	--如果只剩下一个小配件则不留
	if #bot.currBuyingBasicItemList == 1
		or Role.IsPvNMode()
	then
		cost = itemCost
	end

	--从第12分钟起存钱买魔晶
	if not bot.hasBuyShard
		and DotaTime() > 12 * 60
	then
		local shardCDTime = 15 * 60 - DotaTime()
		if shardCDTime < 0
		then
			cost = cost + 1400
		else
			cost = cost + 1400 * ( 1 - shardCDTime / 300 )
		end
	end

	--开始购买魔晶
	if bot.currBuyingBasicItem == "item_aghanims_shard"
	then
		bot.hasBuyShard = false
		ClearCurrBuyingBasicItemList()
		return
	end

	--达到金钱需要时购物
	if bot:GetGold() >= cost
		and bot:GetItemInSlot( 14 ) == nil
	then

		if courier == nil
		then
			courier = bot.theCourier
		end

		--当信使购买神秘商店物品后
		if bot.SecretShop
			and courier ~= nil
			and courier:DistanceFromSecretShop() == 0
		then
			local res = courier:ActionImmediate_PurchaseItem(bot.currBuyingBasicItem)
			if res == PURCHASE_ITEM_SUCCESS then
				ClearCurrBuyingBasicItemList()
				bot.SecretShop = false
				return
			elseif GetItemStockCount(bot.currBuyingBasicItem) < 1 then
				-- out of stock → don’t block the queue
				ClearCurrBuyingBasicItemList()
				bot.SecretShop = false
				return
			end
		end


		--决定是否在神秘购物
		if bot.bPurchaseFromSecret
			and bot:DistanceFromSecretShop() > 0
		then
			bot.SecretShop = true
		else
			if Utils.CountBackpackEmptySpace(bot) > 0 -- has empty slot
			or bot:DistanceFromSecretShop() > 700
			then
				if bot:ActionImmediate_PurchaseItem( bot.currBuyingBasicItem ) == PURCHASE_ITEM_SUCCESS
				then
					ClearCurrBuyingBasicItemList()
					bot.SecretShop = false
					return
				else
					if GetItemStockCount(bot.currBuyingBasicItem ) < 1 then
						-- out of stock, skip that item.
						ClearCurrBuyingBasicItemList()
						bot.SecretShop = false
					else
						local purchaseResult = bot:ActionImmediate_PurchaseItem( bot.currBuyingBasicItem )
						log( "%s 未能购买物品 %s : %s", botName, bot.currBuyingBasicItem, purchaseResult )
					end
				end
			end
		end
	else
		bot.SecretShop = false
	end
end

--加速模式购物逻辑
local function TurboModeGeneralPurchase()

	-- ensure the current head is still needed (dedupe)
	local neededHead = _popIfNoLongerNeeded()
	if not neededHead then return end
	bot.currBuyingBasicItem = neededHead
	if _antiSpamPurchase(bot.currBuyingBasicItem) then return end

	if bot.lastItemToBuy ~= bot.currBuyingBasicItem
	then
		bot.lastItemToBuy = bot.currBuyingBasicItem
		bot:SetNextItemPurchaseValue( GetItemCost( bot.currBuyingBasicItem ) )
		itemCost = GetItemCost( bot.currBuyingBasicItem )
		bot.lastItemToBuy = bot.currBuyingBasicItem
	end

	if bot.currBuyingBasicItem == "item_infused_raindrop"
		or bot.currBuyingBasicItem == "item_tome_of_knowledge"
	then
		if GetItemStockCount( bot.currBuyingBasicItem ) <= 0
		then
			ClearCurrBuyingBasicItemList()
			return
		end
	end

	local cost = itemCost

	if bot.lastItemToBuy == 'item_boots'
		and bot.currBuyingItemInPurchaseList == 'item_travel_boots'
		and Item.HasBootsInMainSolt( bot )
	then
		cost = GetItemCost( 'item_travel_boots' )
	end
	

	if not bot.hasBuyShard
		and DotaTime() > 8 * 60
	then
		local shardCDTime = 10 * 60 - DotaTime()
		if shardCDTime < 0
		then
			cost = cost + 1400
		else
			cost = cost + 1400 * ( 1 - shardCDTime / 180 )
		end
	end

	if bot.currBuyingBasicItem == "item_aghanims_shard"
	then
		bot.hasBuyShard = false
		ClearCurrBuyingBasicItemList()
		return
	end

	if bot:GetGold() >= cost
		and bot:GetItemInSlot( 14 ) == nil
	then
		if bot:ActionImmediate_PurchaseItem( bot.currBuyingBasicItem ) == PURCHASE_ITEM_SUCCESS
		then
			ClearCurrBuyingBasicItemList()
			return
		else
			if GetItemStockCount(bot.currBuyingBasicItem ) < 1 then
				-- out of stock, skip that item.
				ClearCurrBuyingBasicItemList()
			else
				local purchaseResult = bot:ActionImmediate_PurchaseItem( bot.currBuyingBasicItem )
				log( "%s 未能购买物品 %s : %s", botName, bot.currBuyingBasicItem, purchaseResult )
			end
		end
	end
end

function ItemPurchaseThink()
	currentTime = DotaTime()

	-- ARDM: detect stale hero instance and rebuild purchase list on hero swap
	local isStale, freshBot, freshName = Fu.IsStaleARDMHero(bot, botName)
	if isStale then return end
	if freshName ~= botName then
		if not freshBot:IsAlive() then return end
		log("[ARDM] Item purchase: hero changed from %s to %s", botName, freshName)
		bot = freshBot
		botName = freshName

		-- Load new hero's item build
		local heroFile = string.gsub(botName, "npc_dota_", "")
		local ok, newBuild = pcall(dofile, GetScriptDirectory().."/BotsLib/"..heroFile)
		if ok and newBuild ~= nil and newBuild['sBuyList'] ~= nil then
			BotBuild = newBuild
			sPurchaseList = newBuild['sBuyList']
			sItemSellList = newBuild['sSellList']
		else
			sPurchaseList = {}
			sItemSellList = {}
		end

		-- Rebuild purchase list, skipping owned items, duplicate boots, early items
		local bHasBoots = Item.HasBuyBoots(bot)
			or Item.HasItem(bot, 'item_guardian_greaves')
			or Item.HasItem(bot, 'item_travel_boots')
			or Item.HasItem(bot, 'item_travel_boots_2')
			or Item.HasItem(bot, 'item_boots_of_bearing')
		local tSkipBoots = {
			item_boots = true, item_phase_boots = true, item_power_treads = true,
			item_tranquil_boots = true, item_arcane_boots = true,
			-- greaves/bearing/travel are intentional upgrades, don't skip
		}

		bot.purchaseListInReverseOrder = {}
		local idx = 0
		for i = #sPurchaseList, 1, -1 do
			local itemName = sPurchaseList[i]
			local bSkip = false
			if Item.IsItemInHero(itemName) then
				bSkip = true
			elseif GetGameMode() == GAMEMODE_ARDM and DotaTime() > 2 * 60 and tARDMNeverRebuy[itemName] then
				bSkip = true
			elseif bHasBoots and tSkipBoots[itemName] then
				bSkip = true
			end
			if not bSkip then
				idx = idx + 1
				bot.purchaseListInReverseOrder[idx] = itemName
			end
		end

		-- Build set of all items/components needed by new build
		local tNewBuildNeeds = {}
		for _, itemName in ipairs(sPurchaseList) do
			tNewBuildNeeds[itemName] = true
			if Item[itemName] ~= nil then
				for _, comp in pairs(Item[itemName]) do
					tNewBuildNeeds[comp] = true
				end
			end
		end

		local tNeverSell = {
			item_aegis = true, item_rapier = true, item_gem = true,
			item_cheese = true, item_refresher_shard = true,
			item_moon_shard = true, item_tpscroll = true,
			item_famango = true, item_great_famango = true, item_greater_famango = true,
		}

		-- Collect sellable items sorted by cost (cheapest first)
		local tSellable = {}
		for slot = 0, 14 do
			local item = bot:GetItemInSlot(slot)
			if item ~= nil then
				local name = item:GetName()
				if not tNeverSell[name]
				and not tNewBuildNeeds[name]
				and not string.find(name, 'token')
				then
					table.insert(tSellable, { slot = slot, name = name, cost = GetItemCost(name) })
				end
			end
		end
		table.sort(tSellable, function(a, b) return a.cost < b.cost end)

		-- Phase 1: sell recipes and cheap items (< 1000g) not in new build
		local MIN_FREE_SLOTS = 3
		for _, entry in ipairs(tSellable) do
			local item = bot:GetItemInSlot(entry.slot)
			if item ~= nil then
				if string.find(entry.name, 'recipe') or entry.cost < 1000 then
					bot:ActionImmediate_SellItem(item)
					log("[ARDM] Sold: %s (cost: %s)", entry.name, entry.cost)
				end
			end
		end

		-- Phase 2: sell more if inventory still too full
		local nUsedSlots = 0
		for slot = 0, 8 do
			if bot:GetItemInSlot(slot) ~= nil then nUsedSlots = nUsedSlots + 1 end
		end
		local nFreeSlots = 9 - nUsedSlots
		if nFreeSlots < MIN_FREE_SLOTS then
			for _, entry in ipairs(tSellable) do
				if nFreeSlots >= MIN_FREE_SLOTS then break end
				local item = bot:GetItemInSlot(entry.slot)
				if item ~= nil then
					bot:ActionImmediate_SellItem(item)
					log("[ARDM] Sold (full inv): %s (cost: %s)", entry.name, entry.cost)
					nFreeSlots = nFreeSlots + 1
				end
			end
		end

		-- Reset purchase state machine
		bot.currBuyingItemInPurchaseList = nil
		bot.currBuyingBasicItem = nil
		bot.currBuyingBasicItemList = {}
		bot.currBuyingBasicItemRefList = {}
		bot.currBuyingRequiredCounts = nil
		bot.rebuildCount = 0
		bot.countInvCheck = 0
	end

	-- Detect position swap from !pos command: rebuild purchase list for new role
	if bot.needPurchaseRebuild then
		bot.needPurchaseRebuild = nil
		local nNewPos = Fu.GetPosition(bot)
		log("[PosSwap] Item purchase rebuild for %s -> pos%s", botName, nNewPos)

		-- Reload BotBuild to get new role's item list
		local heroFile = string.gsub(botName, "npc_dota_", "")
		local ok, newBuild = pcall(dofile, GetScriptDirectory().."/BotsLib/"..heroFile)
		if ok and newBuild ~= nil and newBuild['sBuyList'] ~= nil then
			BotBuild = newBuild
			sPurchaseList = newBuild['sBuyList']
			sItemSellList = newBuild['sSellList']
		end

		-- Rebuild purchase list, skipping:
		-- 1. Items the bot already owns (final item in inventory)
		-- 2. Items whose ALL components the bot already has (final item effectively built)
		-- 3. Duplicate boots if bot already has boots
		if sPurchaseList then
			local bHasBoots = Item.HasBuyBoots(bot)
				or Item.HasItem(bot, 'item_guardian_greaves')
				or Item.HasItem(bot, 'item_travel_boots')
				or Item.HasItem(bot, 'item_travel_boots_2')
				or Item.HasItem(bot, 'item_boots_of_bearing')
			local tSkipBoots = {
				item_boots = true, item_phase_boots = true, item_power_treads = true,
				item_tranquil_boots = true, item_arcane_boots = true,
				-- greaves/bearing/travel are intentional upgrades, don't skip
			}

			bot.purchaseListInReverseOrder = {}
			local idx = 0
			for i = #sPurchaseList, 1, -1 do
				local itemName = sPurchaseList[i]
				local bSkip = false

				-- Already own it
				if Item.IsItemInHero(itemName) then
					bSkip = true
				-- Duplicate boots
				elseif bHasBoots and tSkipBoots[itemName] then
					bSkip = true
				-- Early game items past laning (same as ARDM)
				elseif DotaTime() > 10 * 60 and tARDMNeverRebuy[itemName] then
					bSkip = true
				end

				if not bSkip then
					idx = idx + 1
					bot.purchaseListInReverseOrder[idx] = itemName
				end
			end
		end

		-- Reset purchase state machine
		bot.currBuyingItemInPurchaseList = nil
		bot.currBuyingBasicItem = nil
		bot.currBuyingBasicItemList = {}
		bot.currBuyingBasicItemRefList = {}
		bot.currBuyingRequiredCounts = nil
		bot.rebuildCount = 0
		bot.countInvCheck = 0
		log("[PosSwap] Purchase list rebuilt with %s items", #bot.purchaseListInReverseOrder)
	end

	if bot.lastItemPurchaseFrameProcessTime == nil then bot.lastItemPurchaseFrameProcessTime = currentTime end
	if currentTime > 30 and (currentTime - bot.lastItemPurchaseFrameProcessTime < 1) then return end
	bot.lastItemPurchaseFrameProcessTime = currentTime

	if ( GetGameState() ~= GAME_STATE_PRE_GAME and GetGameState() ~= GAME_STATE_GAME_IN_PROGRESS )
	then return	end

	if bot:IsIllusion()
	or bot:HasModifier( 'modifier_arc_warden_tempest_double' )
	or (currentTime > 0 and Fu.IsMeepoClone(bot))
	or bot:HasModifier('modifier_dazzle_nothl_projection_soul_debuff')
	then
		bot.purchaseListInReverseOrder = {}
		return
	end

	botLevel = bot:GetLevel()
	botGold = bot:GetGold()
	botWorth = bot:GetNetWorth()
	botMode = bot:GetActiveMode()
	botHP	= Fu.GetHP(bot)
	botCourierValue = bot:GetCourierValue()
	botStashValue = bot:GetStashValue()
	botDistanceFromFountain = bot:DistanceFromFountain()

	-- try to recover own dropped items (generic, not only for bear)
	local dropped = GetDroppedItemList()
	for _, d in pairs(dropped) do
		if d ~= nil and d.owner == bot and d.item ~= nil and not string.find(d.item:GetName(), 'token') then
			local dist = GetUnitToLocationDistance(bot, d.location)
			if dist > 200 and dist < 1000 then
				bot:Action_MoveToLocation(d.location)
			elseif dist <= 100 then
				bot:Action_PickUpItem(d.item)
				return
			end
		end
	end

	-- Lone Druid item transfer: moved to mode_team_roam_generic.lua
	-- (desire+think allows proper prioritization of drop/pickup actions).
	-- Bear pickup of dropped items is kept here since it's lightweight.
	if Utils.IsBear(bot) and bot:IsAlive() then
		local bearItemsMap = Utils.GetLoneDruid(bot).bearItemsMap or {}
		local dropItemList = GetDroppedItemList()
		for _, tDropItem in pairs( dropItemList ) do
			if tDropItem.owner == Utils.GetLoneDruid(bot).hero
			and tDropItem.item ~= nil
			and not string.find(tDropItem.item:GetName(), 'token')
			then
				local itemName = tDropItem.item:GetName()
				-- Only pick up items from the bear items list
				if bearItemsMap[itemName] and not Item.HasItem(bot, itemName) then
					local distance = GetUnitToLocationDistance(bot, tDropItem.location)
					if distance > 100 and distance < 1000 then
						bot:Action_MoveToLocation(tDropItem.location)
						return
					elseif distance <= 100 then
						bot:Action_PickUpItem(tDropItem.item)
						return
					end
				end
			end
		end
	end

	--更新队伍里是否有辅助的定位
	if Role['supportExist'] == nil then Role.UpdateSupportStatus( bot ) end

	--更新敌方是否有隐身英雄或道具的状态
	if Role['invisEnemyExist'] == false then Role.UpdateInvisEnemyStatus( bot ) end

	--更新是否出鞋的状态
	if buyBootsStatus == false
		and currentTime > lastBootsCheck + 2.0
	then
		buyBootsStatus = Item.HasBuyBoots( bot )
		lastBootsCheck = currentTime
	end

	--买小净化
	if Fu.GetMP(bot) < 0.3
	and botDistanceFromFountain > 2000
	and botCourierValue == 0
	and GetItemStockCount('item_clarity') > 1
	and Item.GetItemCharges(bot, 'item_clarity') <= 0
	and botGold >= GetItemCost( "item_clarity" )
	then
		bot.hasBuyClarity = true
		bot:ActionImmediate_PurchaseItem( "item_clarity" )
	end

	--辅助定位英雄购买辅助物品
	if Fu.GetPosition(bot) >= 4
	then
		if currentTime > 30 and not bot.hasBuyClarity
			and botGold >= GetItemCost( "item_clarity" )
			and not Role.IsPvNMode()
			and Utils.CountBackpackEmptySpace(bot) >= 2
		then
			bot.hasBuyClarity = true
			bot:ActionImmediate_PurchaseItem( "item_clarity" )
		elseif botLevel >= 5
			and Role['invisEnemyExist'] == true
			and buyBootsStatus == true
			and botGold >= GetItemCost( "item_dust" )
			and Item.GetEmptyInventoryAmount( bot ) >= 2
			and Item.GetItemCharges( bot, "item_dust" ) <= 0
			and botCourierValue == 0
			and not Fu.HasItem(bot, 'item_ward_sentry')
		then
			bot:ActionImmediate_PurchaseItem( "item_dust" )
		end
	end

	-- Init Healing Items in Lane; works for now
	-- Skip for Lone Druid hero and bear — they share courier and rebuy flasks infinitely
	if Fu.IsInLaningPhase()
	and not string.find(botName, 'lone_druid')
	then
		if botLevel < 6
		and bot:IsAlive()
		and botCourierValue == 0
		and bot:FindItemSlot('item_flask') < 0
		and bot:FindItemSlot('item_tango') < 0
		and botDistanceFromFountain > 2000
		and botStashValue == 0
		and not bot:HasModifier('modifier_elixer_healing')
		and not bot:HasModifier('modifier_filler_heal')
		and not bot:HasModifier('modifier_flask_healing')
		and not bot:HasModifier('modifier_fountain_aura_buff')
		and not bot:HasModifier('modifier_juggernaut_healing_ward_heal')
		and not bot:HasModifier('modifier_warlock_shadow_word')
		and not IsThereHealingInStash(bot)
		and Item.GetEmptyInventoryAmount(bot) >= 1
		and Fu.GetHP(bot) < 0.5
		then
			local partner = Fu.GetLanePartner(bot)

			if bot:GetHealthRegen() <= 10
			then
				if Fu.IsCore(bot)
				then
					if partner ~= nil
					then
						if partner:FindItemSlot('item_flask') < 0
						and partner:FindItemSlot('item_tango') < 0
						and Item.GetItemCharges(bot, 'item_flask') <= 0
						and botGold >= GetItemCost('item_flask')
						and GetItemStockCount('item_flask') > 1
						then
							bot:ActionImmediate_PurchaseItem('item_flask')
						end
					else
						if Item.GetItemCharges(bot, 'item_flask') <= 0
						and botGold >= GetItemCost('item_flask')
						and GetItemStockCount('item_flask') > 1
						and (not Fu.HasItem(bot, 'item_bottle')
							or (Fu.HasItem(bot, 'item_bottle') and Item.GetItemCharges(bot, 'item_bottle') <= 0))
						then
							bot:ActionImmediate_PurchaseItem('item_flask')
						end
					end
				else
					if Item.GetItemCharges(bot, 'item_flask') <= 0
					and botGold >= GetItemCost('item_flask')
					and GetItemStockCount('item_flask') > 1
					then
						bot:ActionImmediate_PurchaseItem('item_flask')
					end
				end
			else
				if Fu.IsCore(bot)
				then
					if partner ~= nil
					then
						if partner:FindItemSlot('item_flask') < 0
						and partner:FindItemSlot('item_tango') < 0
						and partner ~= nil
						and Item.GetItemCharges(bot, 'item_tango') <= 0
						and botGold >= GetItemCost('item_tango')
						and GetItemStockCount('item_flask') > 1
						then
							bot:ActionImmediate_PurchaseItem('item_tango')
						end
					else
						if Item.GetItemCharges(bot, 'item_flask') <= 0
						and GetItemStockCount('item_flask') > 1
						and botGold >= GetItemCost('item_flask')
						and (not Fu.HasItem(bot, 'item_bottle')
							or (Fu.HasItem(bot, 'item_bottle') and Item.GetItemCharges(bot, 'item_bottle') <= 0))
						then
							bot:ActionImmediate_PurchaseItem('item_flask')
						end
					end
				else
					if Item.GetItemCharges(bot, 'item_tango') <= 0
					and botGold >= GetItemCost('item_tango')
					then
						bot:ActionImmediate_PurchaseItem('item_tango')
					end
				end
			end
		end
	end

	-- Observer and Sentry Wards
	if Fu.GetPosition(bot) == 4 and DotaTime() > 300 and botWorth < 25000
	then
		local wardType = 'item_ward_sentry'

		if GetItemStockCount(wardType) > 1
		and botGold >= GetItemCost(wardType)
		and Item.GetEmptyInventoryAmount(bot) >= 2
		and Item.GetItemCharges(bot, wardType) < 1
		and botCourierValue == 0
		then
			bot:ActionImmediate_PurchaseItem(wardType)
		end
	end

	-- Smart Bots: keep vision up. Pos 5 buys every observer in stock (the old rule needed 2+ in
	-- stock and 2 free slots, so it rarely bought any); pos 4 also buys one when 2+ are in stock.
	local nPos = Fu.GetPosition(bot)
	if (nPos == 5 or nPos == 4) and botWorth < 25000
	then
		local wardType = 'item_ward_observer'
		local nCharges = Item.GetItemCharges(bot, wardType)

		if GetItemStockCount(wardType) >= (nPos == 5 and 1 or 2)
		and botGold >= GetItemCost(wardType)
		and (nCharges > 0 or Item.GetEmptyInventoryAmount(bot) >= 1)
		and nCharges < (nPos == 5 and 2 or 1)
		and botCourierValue == 0
		then
			bot:ActionImmediate_PurchaseItem(wardType)
		end
	end

	-- Smoke of Deceit
	if Fu.GetPosition(bot) == 5 and botWorth < 10000
	and Utils.CountBackpackEmptySpace(bot) >= 2
	and GetItemStockCount('item_smoke_of_deceit') > 1
	and botGold >= GetItemCost('item_smoke_of_deceit')
	and Item.GetEmptyInventoryAmount(bot) >= 3
	and Item.GetItemCharges(bot, 'item_smoke_of_deceit') == 0
	and botCourierValue == 0
	then
		if DotaTime() < 0
		and not initSmoke
		then
			local hasSmoke = false
			for _, allyHero in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES))
			do
				if Fu.IsValidHero(allyHero)
				and Fu.IsNotSelf(bot, allyHero)
				and Fu.HasItem(allyHero, 'item_smoke_of_deceit')
				then
					hasSmoke = true
				end
			end

			if not hasSmoke
			then
				bot:ActionImmediate_PurchaseItem('item_smoke_of_deceit')
			end
		else
			if not Fu.IsInLaningPhase()
			then
				bot:ActionImmediate_PurchaseItem('item_smoke_of_deceit')
			end
		end
	end

	-- Blood Grenade
	if Fu.IsInLaningPhase()
	and (Fu.GetPosition(bot) == 4 or Fu.GetPosition(bot) == 5)
	and GetItemStockCount('item_blood_grenade') > 0
	and botLevel < 5
	and botGold >= GetItemCost('item_blood_grenade')
	and Item.GetEmptyInventoryAmount(bot) >= 3
	and Item.GetItemCharges(bot, 'item_blood_grenade') == 0
	and botStashValue > 0
	then
		bot:ActionImmediate_PurchaseItem('item_blood_grenade')
	end

	--为自己购买魔晶
	if not bot.hasBuyShard
		and GetItemStockCount( "item_aghanims_shard" ) > 0
		and botGold >= 1400
	then
		bot.hasBuyShard = true
		bot:ActionImmediate_PurchaseItem( "item_aghanims_shard" )
	end

	--防止非辅助购买魂泪
	if buyRD == false
		and currentTime < 0
	then
		buyRD = true
	end

	local tpCost = GetItemCost( "item_tpscroll" )
	
	--正常买备用tp
	if currentTime > 4 * 60
		and botCourierValue <= 100
		and botGold >= tpCost
		and not HasSufficientTp()
		and botName ~= "npc_dota_hero_meepo" -- don't let meepo buy tp
		and botName ~= "npc_dota_hero_lone_druid_bear"
	then
		local tCharges = Item.GetItemCharges( bot, 'item_tpscroll' )
		if bot:HasModifier("modifier_teleporting") then tCharges = tCharges - 1 end
		if tCharges <= 0 or ( botLevel >= 18 and tCharges <= 1 )
		then
			if botGold >= tpCost * 2 and currentTime > 25 * 60 then
				bot:ActionImmediate_PurchaseItem( "item_tpscroll" )
			end
			bot:ActionImmediate_PurchaseItem( "item_tpscroll" )
		end
	end


	--交换魂泪的位置避免过早被破坏
	if currentTime > 180
		and currentTime < 1800
		and bot.switchTime < currentTime - 5.6
	then
		local raindrop = bot:FindItemSlot( "item_infused_raindrop" )
		local raindropCharge = Item.GetItemCharges( bot, "item_infused_raindrop" )
		local nEnemyHeroes = Fu.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE )
		if ( raindrop >= 0 and raindrop <= 5 )
			and ( nEnemyHeroes[1] ~= nil
				or botMode == BOT_MODE_ROSHAN
				or bot:WasRecentlyDamagedByAnyHero( 3.1 ) )
			and ( raindropCharge == 1 or raindropCharge >= 7 )
		then
			bot.switchTime = currentTime
			bot:ActionImmediate_SwapItems( raindrop, 6 )
		end
	end

	-- Ward slot management for supports (pos 4/5):
	-- Move wards to backpack when not actively warding to free up a main slot.
	-- Move them back to main inventory when entering ward mode.
	if Fu.GetPosition(bot) >= 4 and currentTime > (bot._lastWardSwapTime or 0) + 3 then
		local bIsWarding = botMode == BOT_MODE_WARD
		local tWardNames = { 'item_ward_observer', 'item_ward_sentry', 'item_ward_dispenser' }

		for _, wardName in ipairs(tWardNames) do
			local wardSlot = bot:FindItemSlot(wardName)
			if wardSlot >= 0 then
				if bIsWarding then
					-- Move ward from backpack (6-8) to main inventory if there's a free slot
					if wardSlot >= 6 and wardSlot <= 8 then
						for mainSlot = 0, 5 do
							local mainItem = bot:GetItemInSlot(mainSlot)
							if mainItem == nil then
								bot:ActionImmediate_SwapItems(wardSlot, mainSlot)
								bot._lastWardSwapTime = currentTime
								break
							end
						end
					end
				else
					-- Move ward from main inventory (0-5) to backpack if backpack has space
					if wardSlot >= 0 and wardSlot <= 5 then
						for bpSlot = 6, 8 do
							local bpItem = bot:GetItemInSlot(bpSlot)
							if bpItem == nil then
								bot:ActionImmediate_SwapItems(wardSlot, bpSlot)
								bot._lastWardSwapTime = currentTime
								break
							end
						end
					end
				end
			end
		end
	end

	if ( GetGameMode() ~= 23 and botLevel > 6 and currentTime > bot.fullInvCheck + 1.0
		and (botDistanceFromFountain <= 200 or bot:DistanceFromSecretShop() <= 200 ))
		or ( GetGameMode() == 23 and botLevel > 9 and currentTime > bot.fullInvCheck + 1.0 )
	then
		local emptySlot = Item.GetEmptyInventoryAmount( bot )
		local slotToSell = nil

		local preEmpty = 2
		if botLevel <= 17 then preEmpty = 1 end
		-- Supports need at least 1 free slot for wards/dust purchases
		if not Fu.IsCore(bot) and botLevel > 10 then preEmpty = 2 end
		if emptySlot <= preEmpty - 1
		then
			-- Standard early item sell (all roles)
			for i = 1, #Item['tEarlyItem']
			do
				local itemName = Item['tEarlyItem'][i]
				local itemSlot = bot:FindItemSlot( itemName )
				if itemSlot >= 0 and itemSlot <= 8
				then
					slotToSell = itemSlot
					break
				end
			end

			-- Supports (pos 4-5): also sell wand and other early items when full
			if slotToSell == nil and not Fu.IsCore(bot) then
				for i = 1, #Item['tSupportSellWhenFull']
				do
					local itemName = Item['tSupportSellWhenFull'][i]
					local itemSlot = bot:FindItemSlot( itemName )
					if itemSlot >= 0 and itemSlot <= 8
					then
						slotToSell = itemSlot
						break
					end
				end
			end
		end

		-- Cores: sell stat items when backpack is full and networth is high
		if slotToSell == nil
			and botWorth > 10000
			and bot:GetItemInSlot( 6 ) ~= nil
			and bot:GetItemInSlot( 7 ) ~= nil
		then
			local wand = bot:FindItemSlot( "item_magic_wand" )
			local assitItem = bot:FindItemSlot( "item_infused_raindrop" )
			if assitItem < 0 then assitItem = bot:FindItemSlot( "item_bracer" ) end
			if assitItem < 0 then assitItem = bot:FindItemSlot( "item_null_talisman" ) end
			if assitItem < 0 then assitItem = bot:FindItemSlot( "item_wraith_band" ) end
			if assitItem >= 0
				and wand >= 6
				and wand <= 8
			then
				slotToSell = assitItem
			end
		end

		if slotToSell ~= nil
		then
			bot:ActionImmediate_SellItem( bot:GetItemInSlot( slotToSell ) )
		end

		bot.fullInvCheck = currentTime
	end

	--出售过渡装备
	local countEmptyBackpack = Utils.CountBackpackEmptySpace(bot)
	if currentTime > bot.sell_time + 0.5
		and countEmptyBackpack <= 1
		and ( botDistanceFromFountain <= 100 or bot:DistanceFromSecretShop() <= 100 )
	then
		bot.sell_time = currentTime

		-- default list
		SetPairedItems(Item.sSellList)
		-- specific list
		SetPairedItems(sItemSellList)

		if botWorth > 23000 then
			if Item.HasItem( bot, "item_hand_of_midas" ) then
				bot:ActionImmediate_SellItem(bot:GetItemInSlot(bot:FindItemSlot('item_hand_of_midas')))
			end
		end

		if (currentTime > 18 * 60 or botWorth > 20000)
			and ( Item.HasItem( bot, "item_travel_boots" ) or Item.HasItem( bot, "item_travel_boots_2" ) )
		then
			for i = 1, #Item['tEarlyBoots']
			do
				local bootsSlot = bot:FindItemSlot( Item['tEarlyBoots'][i] )
				if bootsSlot >= 0
				then
					bot:ActionImmediate_SellItem( bot:GetItemInSlot( bootsSlot ) )
				end
			end
		end
	end

	if Item.HasItem(bot, 'item_mask_of_madness')
	and Item.HasItem(bot, 'item_satanic')
	then
		bot:ActionImmediate_SellItem(bot:GetItemInSlot(bot:FindItemSlot('item_mask_of_madness')))
	end

	-- Cores drop normal/great lotuses after 30min to free up slots for real items.
	-- Greater lotus (item_greater_famango) is kept by everyone — too valuable to drop.
	if currentTime > 30 * 60 and Fu.IsCore(bot) then
		local tDropLotus = { 'item_famango', 'item_great_famango' }
		for _, lotusName in ipairs(tDropLotus) do
			local slot = bot:FindItemSlot(lotusName)
			if slot >= 0 then
				bot:Action_DropItem(bot:GetItemInSlot(slot), bot:GetLocation())
				log("[Item] Core %s dropped %s (past 30min)", botName, lotusName)
			end
		end
	end

	if #bot.purchaseListInReverseOrder == 0 then
		_resetCurrentTarget()
		bot:SetNextItemPurchaseValue( 0 )
		return
	end

	-- Only skip raw boots of speed when we already have ANY boots.
	-- All upgraded boots (treads, phase, arcane, tranquil, greaves, travel,
	-- bearing) are intentional build items and must NEVER be skipped.
	local tRawBootsOnly = {
		item_boots = true,
	}

	if bot.currBuyingItemInPurchaseList == nil
	and #bot.currBuyingBasicItemList == 0
	then
		-- Skip duplicate basic boots (not upgrades like greaves/travel/bearing)
		while #bot.purchaseListInReverseOrder > 0 do
			local nextItem = bot.purchaseListInReverseOrder[#bot.purchaseListInReverseOrder]
			if tRawBootsOnly[nextItem] and (Item.HasBuyBoots(bot)
				or Item.HasItem(bot, 'item_guardian_greaves')
				or Item.HasItem(bot, 'item_travel_boots')
				or Item.HasItem(bot, 'item_travel_boots_2')
				or Item.HasItem(bot, 'item_boots_of_bearing'))
			then
				log("[Purchase] Skipping %s — already have boots", nextItem)
				bot.purchaseListInReverseOrder[#bot.purchaseListInReverseOrder] = nil
			else
				break
			end
		end
		if #bot.purchaseListInReverseOrder == 0 then
			_resetCurrentTarget()
			bot:SetNextItemPurchaseValue(0)
			return
		end

		bot.currBuyingItemInPurchaseList = bot.purchaseListInReverseOrder[#bot.purchaseListInReverseOrder]
		local basicItemTable = Item.GetBasicItems( { bot.currBuyingItemInPurchaseList } )
		-- original behavior: reverse-half interleave to spread purchases
		for i = 1, math.ceil( #basicItemTable / 2 )
		do
			bot.currBuyingBasicItemList[i] = basicItemTable[#basicItemTable-i+1]
			bot.currBuyingBasicItemList[#basicItemTable-i+1] = basicItemTable[i]
		end
		bot.currBuyingBasicItemRefList = Utils.Deepcopy(bot.currBuyingBasicItemList)
		-- build the required counts map for dedupe and re-buy-missing
		bot.currBuyingRequiredCounts = _buildRequiredCounts(bot.currBuyingBasicItemRefList)
		-- proactively drop already-satisfied components to avoid overbuying
		_popIfNoLongerNeeded()
	end

	if #bot.currBuyingBasicItemList == 0
	then
		if Item.IsItemInHero( bot.currBuyingItemInPurchaseList )
			or bot.currBuyingItemInPurchaseList == "item_aghanims_shard"
			or (
				bot == Utils.GetLoneDruid(bot).hero
				and Utils.GetLoneDruid(bot).bear ~= nil
				and Item.GetItemTotalWorthInSlots(Utils.GetLoneDruid(bot).bear) < 28000
				and Item.IsItemInTargetHero(bot.currBuyingItemInPurchaseList, Utils.GetLoneDruid(bot).bear)
			)
			or bot.countInvCheck > (GetGameMode() == GAMEMODE_ARDM and 30 or 30) -- skip stuck items after 30s
			-- Rebuilds exhausted with empty courier/stash: components were bought but
			-- item didn't combine (virtual items like item_double_tango, or lost components).
			-- Skip immediately instead of waiting for the 30s timeout.
			or (bot.rebuildCount >= 5 and botCourierValue == 0 and botStashValue == 0)
		then
			-- skip it and continue next
			if bot.countInvCheck > 0 or bot.rebuildCount >= 5 then
				log("[Purchase] %s skipping stuck item %s (rebuilds=%d invCheck=%d)", botName, tostring(bot.currBuyingItemInPurchaseList), bot.rebuildCount, bot.countInvCheck)
			end
			bot.countInvCheck = 0
			_resetCurrentTarget()
			bot.purchaseListInReverseOrder[#bot.purchaseListInReverseOrder] = nil
		elseif currentTime > bot.lastInvCheck + 1.0 then
			bot.lastInvCheck = currentTime
			-- Waiting for courier/stash delivery — don't count as stuck
			if botCourierValue > 0 or botStashValue > 0 then
				bot.countInvCheck = 0
			elseif bot.rebuildCount < 5 and botName ~= "npc_dota_hero_lone_druid" then
				bot.rebuildCount = bot.rebuildCount + 1

				-- Check for orphaned recipes in inventory: recipe exists but
				-- missing components (bot dropped/lost them mid-build)
				for slot = 0, 14 do
					local slotItem = bot:GetItemInSlot(slot)
					if slotItem then
						local slotName = slotItem:GetName()
						if string.find(slotName, 'recipe') then
							-- Find final item this recipe belongs to
							local finalItem = string.gsub(slotName, 'item_recipe_', 'item_')
							local components = Item[finalItem] or Item.GetComponentList(finalItem)
							if components and #components > 0 then
								for _, comp in pairs(components) do
									if not string.find(comp, 'recipe') and not Item.IsItemInHero(comp) then
										table.insert(bot.currBuyingBasicItemList, 1, comp)
									end
								end
								if #bot.currBuyingBasicItemList > 0 then
									bot.currBuyingRequiredCounts = _buildRequiredCounts(bot.currBuyingBasicItemList)
									break
								end
							end
						end
					end
				end

				-- Also try normal rebuild based on what's actually missing
				local newList = Item.GetReducedPurchaseList(bot, bot.currBuyingBasicItemRefList)
				for _, value in pairs(newList) do
					if not Item.IsItemInHero(value) then
						bot.currBuyingBasicItemList[#bot.currBuyingBasicItemList+1] = value
					end
				end
				-- refresh counts after rebuild
				bot.currBuyingRequiredCounts = _buildRequiredCounts(bot.currBuyingBasicItemList)
				_popIfNoLongerNeeded()
			else
				-- Rebuilds exhausted, courier/stash empty, item still not in inventory.
				-- Item is genuinely stuck — count toward skip unconditionally.
				bot.countInvCheck = bot.countInvCheck + 1
			end
		end
	elseif #bot.currBuyingBasicItemList > 0
	then
		if bot.currBuyingBasicItem == nil
		then
			bot.currBuyingBasicItem = _popIfNoLongerNeeded()
		else
			if GetGameMode() == 23
			then
				TurboModeGeneralPurchase()
			else
				GeneralPurchase()
			end
		end
	end

end

function SetPairedItems(itemList)
	for i = 2 , #itemList, 2
	do
		local nNewSlot = bot:FindItemSlot( itemList[i - 1] )
		local nOldSlot = bot:FindItemSlot( itemList[i] )
		if nNewSlot >= 0 and nOldSlot >= 0
		then
			bot:ActionImmediate_SellItem( bot:GetItemInSlot( nOldSlot ) )
		end
	end
end

function IsThereHealingInStash(unit)
	local amount = 0

	for i = 9, 14
	do
		local item = unit:GetItemInSlot(i)
		if item ~= nil
		then
			if string.find(item:GetName(), 'item_flask')
			or string.find(item:GetName(), 'item_tango')
			or string.find(item:GetName(), 'item_bottle')
			then
				amount = amount + 1
			end
		end
	end

	return amount > 0
end

X.ItemPurchaseThink = ItemPurchaseThink

return X
