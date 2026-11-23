local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

if GAMEMODE_ARDM == nil then GAMEMODE_ARDM = 20 end
local Item = require( GetScriptDirectory()..'/FunLib/aba_item' )
local Role = require( GetScriptDirectory()..'/FunLib/aba_role' )
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')
local Utils = require( GetScriptDirectory()..'/FunLib/utils')

local X = {}

if bot:IsInvulnerable()
	or not bot:IsHero()
	or bot:IsIllusion()
then
	return
end

local BotBuild = require( GetScriptDirectory() .. "/BotLib/" .. string.gsub( botName, "npc_dota_", "" ) )

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

-- Meta build from Stratz data (FunLib/item_meta_data.lua) instead of the hero
-- file's list, unless the user customized this hero or a special mode is on.
local okStrategy, ItemStrategy = pcall(require, GetScriptDirectory()..'/FunLib/item_strategy')
if not okStrategy then ItemStrategy = nil end
local function MetaBuyList(heroName, unit, fallback)
	if ItemStrategy == nil or unit.bUserItemBuild or Role.IsPvNMode() or Role.IsAllShadow() then
		return fallback
	end
	local list = ItemStrategy.GetMetaBuyList(heroName, J.GetPosition(unit))
	if list then
		print('[Items] '..heroName..' uses the meta build for pos '..tostring(J.GetPosition(unit)))
		return list
	end
	return fallback
end
sPurchaseList = MetaBuyList(botName, bot, sPurchaseList)
-- Items a patch removed from the shop are replaced or dropped.
if ItemStrategy ~= nil and ItemStrategy.CleanBuildList and sPurchaseList ~= nil then
	sPurchaseList = ItemStrategy.CleanBuildList(sPurchaseList, botName)
end


if sPurchaseList == nil then
	print("[ERROR] Can't load purchase list for: " .. botName)
	print("Stack Trace:", debug.traceback())
	return
end

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
	-- Items the courier is carrying to us count too: SF bought a second pair
	-- of boots while the first was on the courier.
	local courier = unit.theCourier
	if courier ~= nil and not courier:IsNull() then
		for slot = 0, 8 do
			local it = courier:GetItemInSlot(slot)
			if it ~= nil and it:GetName() == itemName then count = count + 1 end
		end
	end
	return count
end

-- How many of each basic item the whole recipe of `itemName` takes, counting
-- duplicates (Magic Wand: 2 branches). The to-buy list skips what the hero
-- already owns, so it can't be used for this: with one starting branch it
-- holds one branch, and the owned branch then "satisfied" it.
local function _fullBasicCounts(itemName, acc)
	acc = acc or {}
	local comps = Item[itemName]
	if type(comps) == 'table' and #comps > 0 then
		for _, c in ipairs(comps) do _fullBasicCounts(c, acc) end
	else
		acc[itemName] = (acc[itemName] or 0) + 1
	end
	return acc
end

-- Is `name` a component (at any depth) of an item still planned? Such items
-- are never sold as fillers (a Radiance part was sold once the target moved
-- on to BKB).
local function _plannedComponent(name)
	for _, planned in ipairs(bot.purchaseListInReverseOrder or {}) do
		if planned == name or (_fullBasicCounts(planned)[name] ~= nil) then return true end
		local comps = Item[planned]
		if type(comps) == 'table' then
			for _, c in ipairs(comps) do if c == name then return true end end
		end
	end
	return false
end

-- Is `name` already built into an item the hero owns (Dagon 3 inside Dagon 5)?
local function _contains(item, name, depth)
	if depth > 6 then return false end
	local comps = Item[item]
	if type(comps) ~= 'table' then return false end
	for _, c in ipairs(comps) do
		if c == name or _contains(c, name, depth + 1) then return true end
	end
	return false
end
local function _insideOwnedUpgrade(name)
	for slot = 0, 16 do
		local it = bot:GetItemInSlot(slot)
		if it ~= nil and it:GetName() ~= name and _contains(it:GetName(), name, 0) then return true end
	end
	return false
end

-- Does the bot hold any part of `target` (so dropping it would waste gold)?
local function _holdsPartOf(target)
	local counts = _fullBasicCounts(target)
	for part, _ in pairs(counts) do
		if part ~= target and bot:FindItemSlot(part) >= 0 then return true end
	end
	local comps = Item[target]
	if type(comps) == 'table' then
		for _, c in ipairs(comps) do if bot:FindItemSlot(c) >= 0 then return true end end
	end
	return false
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
	item_quelling_blade = true, item_magic_stick = true,
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
						print( botName.." 未能购买物品 "..bot.currBuyingBasicItem.." : "..tostring( bot:ActionImmediate_PurchaseItem( bot.currBuyingBasicItem ) ) )
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
				print( botName.." 未能购买物品 "..bot.currBuyingBasicItem.." : "..tostring( bot:ActionImmediate_PurchaseItem( bot.currBuyingBasicItem ) ) )
			end
		end
	end
end

function ItemPurchaseThink()
	currentTime = DotaTime()

	-- ARDM: detect stale hero instance and rebuild purchase list on hero swap
	local isStale, freshBot, freshName = J.IsStaleARDMHero(bot, botName)
	if isStale then return end
	if freshName ~= botName then
		if not freshBot:IsAlive() then return end
		print("[ARDM] Item purchase: hero changed from "..botName.." to "..freshName)
		bot = freshBot
		botName = freshName

		-- Load new hero's item build
		local heroFile = string.gsub(botName, "npc_dota_", "")
		local ok, newBuild = pcall(dofile, GetScriptDirectory().."/BotLib/"..heroFile)
		if ok and newBuild ~= nil and newBuild['sBuyList'] ~= nil then
			BotBuild = newBuild
			sPurchaseList = MetaBuyList(botName, bot, newBuild['sBuyList'])
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
					print("[ARDM] Sold: "..entry.name.." (cost: "..entry.cost..")")
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
					print("[ARDM] Sold (full inv): "..entry.name.." (cost: "..entry.cost..")")
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
		local nNewPos = J.GetPosition(bot)
		print("[PosSwap] Item purchase rebuild for "..botName.." -> pos"..nNewPos)

		-- Reload BotBuild to get new role's item list
		local heroFile = string.gsub(botName, "npc_dota_", "")
		local ok, newBuild = pcall(dofile, GetScriptDirectory().."/BotLib/"..heroFile)
		if ok and newBuild ~= nil and newBuild['sBuyList'] ~= nil then
			BotBuild = newBuild
			sPurchaseList = MetaBuyList(botName, bot, newBuild['sBuyList'])
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
		print("[PosSwap] Purchase list rebuilt with "..#bot.purchaseListInReverseOrder.." items")
	end

	if bot.lastItemPurchaseFrameProcessTime == nil then bot.lastItemPurchaseFrameProcessTime = currentTime end
	if currentTime > 30 and (currentTime - bot.lastItemPurchaseFrameProcessTime < 1) then return end
	bot.lastItemPurchaseFrameProcessTime = currentTime

	if ( GetGameState() ~= GAME_STATE_PRE_GAME and GetGameState() ~= GAME_STATE_GAME_IN_PROGRESS )
	then return	end

	if bot:IsIllusion()
	or bot:HasModifier( 'modifier_arc_warden_tempest_double' )
	or (currentTime > 0 and J.IsMeepoClone(bot))
	or bot:HasModifier('modifier_dazzle_nothl_projection_soul_debuff')
	then
		bot.purchaseListInReverseOrder = {}
		return
	end

	botLevel = bot:GetLevel()
	botGold = bot:GetGold()
	botWorth = bot:GetNetWorth()
	botMode = bot:GetActiveMode()
	botHP	= J.GetHP(bot)
	botCourierValue = bot:GetCourierValue()
	botStashValue = bot:GetStashValue()
	botDistanceFromFountain = bot:DistanceFromFountain()

	-- try to recover own dropped items (generic, not only for bear)
	local dropped = GetDroppedItemList()
	for _, d in pairs(dropped) do
		-- Not what it dropped itself to free the backpack (Riki dropped and
		-- picked up his Magic Stick every 3 s, bot vs bot 9102944605), nor
		-- the early consumables that drop is for.
		local dName = d ~= nil and d.item ~= nil and d.item:GetName() or ''
		local onPurpose = bot._droppedOnPurpose and bot._droppedOnPurpose[dName]
		if d ~= nil and d.owner == bot and d.item ~= nil and not string.find(dName, 'token')
		and not (onPurpose and DotaTime() - onPurpose < 600)
		and not (Item and Item['tEarlyConsumableItem'] and Utils.HasValue(Item['tEarlyConsumableItem'], dName)) then
			local dist = GetUnitToLocationDistance(bot, d.location)
			if dist > 200 and dist < 1000 then
				bot:Action_MoveToLocation(d.location)
			elseif dist <= 100 then
				bot:Action_PickUpItem(d.item)
				return
			end
		end
	end

	if bot == Utils.GetLoneDruid(bot).hero then
		local bear = Utils.GetLoneDruid(bot).bear
		if bear ~= nil then
			local hEnemyList = J.GetNearbyHeroes(bot, 1000, true, BOT_MODE_NONE)
			if #hEnemyList >= 1 then return end
			
			if not bear:IsAlive() or bear:IsChanneling() or bear:IsUsingAbility() or Utils.CountBackpackEmptySpace(bear) <= 0 then return end
			if bear:HasModifier('modifier_item_ultimate_scepter_consumed') then return end

			local bearNetworth = Item.GetItemTotalWorthInSlots(bear)
			if GetUnitToUnitDistance(bot, bear) < 400 then
				for i = 0, 9
				do
					local item = bot:GetItemInSlot( i )
					if item ~= nil
					then
						local itemName = item:GetName()
						if Utils.HasValue(Item['tEarlyConsumableItem'], itemName)
						or Utils.HasValue(Item['item_ultimate_scepter'], itemName)
						or (string.find(itemName, 'boot') and bearNetworth > 600)
						or itemName == 'item_tpscroll' and Item.HasItem(bear, 'item_tpscroll')
						then
							-- do nothing, keep it.
						elseif Utils.CountBackpackEmptySpace(bear) >= 1 then
							bot:Action_DropItem(item, bear:GetLocation())
						end
					end
				end
			end
		end
	end
	if Utils.IsBear(bot) and bot:IsAlive() then
		local dropItemList = GetDroppedItemList()
		for _, tDropItem in pairs( dropItemList )
		do
			if tDropItem.owner == Utils.GetLoneDruid(bot).hero and not string.find(tDropItem.item:GetName(), 'token')
			and not (string.find(tDropItem.item:GetName(), 'boot') and Item.HasItemWithName(bot, 'boot')) then
				local distance = GetUnitToLocationDistance(bot, tDropItem.location)
				if distance > 200 and distance < 1000 and tDropItem.owner == bot
				then
					bot:Action_MoveToLocation(tDropItem.location)
				elseif distance <= 100 then
					bot:Action_PickUpItem(tDropItem.item)
					return
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
	if J.GetMP(bot) < 0.3
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
	if J.GetPosition(bot) >= 4
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
			and not J.HasItem(bot, 'item_ward_sentry')
		then
			bot:ActionImmediate_PurchaseItem( "item_dust" )
		end
	end

	-- Init Healing Items in Lane; works for now
	if J.IsInLaningPhase()
	then
		if bot:IsAlive()
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
		and J.GetHP(bot) < 0.55
		then
			local partner = J.GetLanePartner(bot)
			-- Simple rule first: a salve (or tangos if none in stock) keeps the
			-- hero in lane instead of walking/teleporting home.
			if Item.GetItemCharges(bot, 'item_flask') <= 0 and botGold >= GetItemCost('item_flask') and GetItemStockCount('item_flask') >= 1 then
				bot:ActionImmediate_PurchaseItem('item_flask')
				print('[Items] '..botName..' buys a salve to stay in lane')
				partner = nil
				return
			elseif Item.GetItemCharges(bot, 'item_tango') <= 0 and botGold >= GetItemCost('item_tango') then
				bot:ActionImmediate_PurchaseItem('item_tango')
				return
			end

			if bot:GetHealthRegen() <= 10
			then
				if J.IsCore(bot)
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
						and (not J.HasItem(bot, 'item_bottle')
							or (J.HasItem(bot, 'item_bottle') and Item.GetItemCharges(bot, 'item_bottle') <= 0))
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
				if J.IsCore(bot)
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
						and (not J.HasItem(bot, 'item_bottle')
							or (J.HasItem(bot, 'item_bottle') and Item.GetItemCharges(bot, 'item_bottle') <= 0))
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
	-- Supports keep the map lit: both buy observers, sentries after 5 min.
	if J.GetPosition(bot) >= 4 and botWorth < 30000 and currentTime > buyWardTime + 2
	and botCourierValue == 0
	then
		local function WardCharges(name)
			local n = Item.GetItemCharges(bot, name)
			local disp = bot:FindItemSlot('item_ward_dispenser')
			if disp >= 0 then
				local d = bot:GetItemInSlot(disp)
				local ok, c = pcall(function()
					if name == 'item_ward_observer' then return d:GetCurrentCharges() end
					return d:GetSecondaryCharges()
				end)
				if ok and c then n = n + c end
			end
			return n
		end
		local function CanHold(name)
			return Item.GetEmptyInventoryAmount(bot) >= 1 or bot:FindItemSlot(name) >= 0 or bot:FindItemSlot('item_ward_dispenser') >= 0
		end
		local nObsWanted = J.GetPosition(bot) == 5 and 3 or 2
		local nSentryWanted = currentTime > 300 and (J.GetPosition(bot) == 4 and 2 or 1) or 0
		if GetItemStockCount('item_ward_observer') >= 1
		and botGold >= GetItemCost('item_ward_observer')
		and WardCharges('item_ward_observer') < nObsWanted
		and CanHold('item_ward_observer')
		then
			bot:ActionImmediate_PurchaseItem('item_ward_observer')
			buyWardTime = currentTime
		elseif GetItemStockCount('item_ward_sentry') >= 1
		and botGold >= GetItemCost('item_ward_sentry') + 100
		and WardCharges('item_ward_sentry') < nSentryWanted
		and CanHold('item_ward_sentry')
		then
			bot:ActionImmediate_PurchaseItem('item_ward_sentry')
			buyWardTime = currentTime
		end
	end

	-- Smoke of Deceit
	if J.GetPosition(bot) == 5 and botWorth < 10000
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
				if J.IsValidHero(allyHero)
				and J.IsNotSelf(bot, allyHero)
				and J.HasItem(allyHero, 'item_smoke_of_deceit')
				then
					hasSmoke = true
				end
			end

			if not hasSmoke
			then
				bot:ActionImmediate_PurchaseItem('item_smoke_of_deceit')
			end
		else
			if not J.IsInLaningPhase()
			then
				bot:ActionImmediate_PurchaseItem('item_smoke_of_deceit')
			end
		end
	end

	-- Blood Grenade
	if J.IsInLaningPhase()
	and (J.GetPosition(bot) == 4 or J.GetPosition(bot) == 5)
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

	--死前如果会损失金钱则购买额外TP
	local tpCost = GetItemCost( "item_tpscroll" )
	if botGold >= tpCost
		and bot:IsAlive()
		and botGold < ( tpCost + botWorth / 40 )
		and botHP < 0.08
		and botHP >= 1
		and bot:WasRecentlyDamagedByAnyHero( 3.1 )
		and not HasSufficientTp()
		and Item.GetItemCharges( bot, 'item_tpscroll' ) <= 2
	then
		bot:ActionImmediate_PurchaseItem( "item_tpscroll" )
	end
	
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

	-- --辅助死前如果会损失金钱则购买粉
	if botGold >= GetItemCost( "item_dust" )
		and bot:IsAlive()
		and botLevel > 6
		and J.GetPosition(bot) >= 4
		and botGold < ( GetItemCost( "item_dust" )  + botWorth / 40 )
		and botHP < 0.06
		and bot:WasRecentlyDamagedByAnyHero( 3.1 )
		and Item.GetItemCharges( bot, 'item_dust' ) <= 1
		and Utils.CountBackpackEmptySpace(bot) >= 2
	then
		bot:ActionImmediate_PurchaseItem( "item_dust" )
	end

	--交换魂泪的位置避免过早被破坏
	if currentTime > 180
		and currentTime < 1800
		and bot.switchTime < currentTime - 5.6
	then
		local raindrop = bot:FindItemSlot( "item_infused_raindrop" )
		local raindropCharge = Item.GetItemCharges( bot, "item_infused_raindrop" )
		local nEnemyHeroes = J.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE )
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
	if J.GetPosition(bot) >= 4 and currentTime > (bot._lastWardSwapTime or 0) + 3 then
		local bIsWarding = botMode == BOT_MODE_WARD or (bot._wardWantedUntil or -99) > currentTime
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
				elseif false then
					-- Disabled: hiding wards in the backpack put them on a 6 s
					-- cooldown every time the ward mode wanted to plant them.
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
		if emptySlot <= preEmpty - 1
		then
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
		end


		if botWorth > 10000
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

	-- Late game with a full inventory: sell the cheapest filler item so the
	-- next big item (or Moon Shard / Blessing) has room. Meta builds have no
	-- sell list, so without this the inventory stayed full of wands/bracers.
	if botWorth > 14000 and currentTime > (bot._fillerSellT or -99) + 2
	and (botDistanceFromFountain <= 400 or bot:DistanceFromSecretShop() <= 200)
	and Item.GetEmptyInventoryAmount(bot) == 0
	and (botGold >= 2000 or (bot.currBuyingItemInPurchaseList ~= nil and GetItemCost(bot.currBuyingItemInPurchaseList) >= 2000))
	then
		bot._fillerSellT = currentTime
		local tKeep = { item_tpscroll = true, item_ward_observer = true, item_ward_sentry = true, item_ward_dispenser = true,
			item_dust = true, item_smoke_of_deceit = true, item_gem = true, item_rapier = true, item_aegis = true,
			item_cheese = true, item_refresher_shard = true, item_moon_shard = true, item_aghanims_shard = true,
			item_famango = true, item_great_famango = true, item_greater_famango = true }
		local sellSlot, sellCost = nil, 2200
		for slot = 0, 8 do
			local it = bot:GetItemInSlot(slot)
			if it ~= nil then
				local name = it:GetName()
				local cost = GetItemCost(name)
				local isBoots = string.find(name, 'boots') or string.find(name, 'treads') or string.find(name, 'greaves')
				local needed = (bot.currBuyingRequiredCounts and bot.currBuyingRequiredCounts[name]) or _plannedComponent(name)
				if not tKeep[name] and not isBoots and not needed and not string.find(name, 'token')
				and cost < sellCost then
					sellSlot, sellCost = slot, cost
				end
			end
		end
		if sellSlot ~= nil then
			print('[Items] '..botName..' sells '..bot:GetItemInSlot(sellSlot):GetName()..' to make room')
			bot:ActionImmediate_SellItem(bot:GetItemInSlot(sellSlot))
		end
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

	-- Cores free the slot of a normal/great lotus after 30 min by eating it
	-- (on the most hurt ally within 600, else on themselves). Dropping it made
	-- SF drop it, pick it up again and drop it again, over and over.
	-- Greater lotus (item_greater_famango) is kept by everyone.
	if currentTime > 30 * 60 and J.IsCore(bot) and not bot:IsChanneling() and not J.CanNotUseAction(bot) then
		for _, lotusName in ipairs({ 'item_famango', 'item_great_famango' }) do
			local slot = bot:FindItemSlot(lotusName)
			if slot >= 0 and slot <= 5 then
				local item = bot:GetItemInSlot(slot)
				if item and item:IsFullyCastable() and (bot._lotusEatT or -math.huge) < currentTime - 2 then
					local target, low = bot, J.GetHP(bot)
					for i = 1, 5 do
						local m = GetTeamMember(i)
						if m and m:IsAlive() and m ~= bot and GetUnitToUnitDistance(bot, m) < 600 and J.GetHP(m) < low then target, low = m, J.GetHP(m) end
					end
					bot._lotusEatT = currentTime
					bot:Action_UseAbilityOnEntity(item, target)
					print('[Items] '..botName..' uses its '..lotusName..' on '..target:GetUnitName()..' (slot for real items)')
				end
				break
			end
		end
	end

	-- Between two purchases: adapt the plan to the drafts and the game state
	-- (also once the planned build is finished).
	if ItemStrategy ~= nil and not Role.IsPvNMode()
	and bot.currBuyingItemInPurchaseList == nil and #bot.currBuyingBasicItemList == 0
	then
		ItemStrategy.Think(bot, J.GetPosition(bot), bot.purchaseListInReverseOrder)
		if ItemStrategy.LateGame then ItemStrategy.LateGame(bot, J.GetPosition(bot), bot.purchaseListInReverseOrder) end
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
				print("[Purchase] Skipping "..nextItem.." — already have boots")
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

		-- One pair of upgraded boots is enough (Axe built two Phase Boots).
		local tBootUpgrades = { item_phase_boots = true, item_power_treads = true, item_arcane_boots = true, item_tranquil_boots = true }
		while #bot.purchaseListInReverseOrder > 0 and tBootUpgrades[bot.purchaseListInReverseOrder[#bot.purchaseListInReverseOrder]] do
			local bHasUpgrade = false
			for slot = 0, 16 do
				local it = bot:GetItemInSlot(slot)
				if it ~= nil and (tBootUpgrades[it:GetName()] or it:GetName() == 'item_guardian_greaves'
					or it:GetName() == 'item_travel_boots' or it:GetName() == 'item_travel_boots_2' or it:GetName() == 'item_boots_of_bearing') then
					bHasUpgrade = true
				end
			end
			if not bHasUpgrade then break end
			print('[Items] '..botName..' already has boots, skipping '..bot.purchaseListInReverseOrder[#bot.purchaseListInReverseOrder])
			bot.purchaseListInReverseOrder[#bot.purchaseListInReverseOrder] = nil
		end
		if #bot.purchaseListInReverseOrder == 0 then
			_resetCurrentTarget()
			bot:SetNextItemPurchaseValue(0)
			return
		end

		-- A big item the hero already owns (or finished earlier) isn't bought
		-- again (WK bought two Phase Boots in a row).
		while #bot.purchaseListInReverseOrder > 0 do
			local nextItem = bot.purchaseListInReverseOrder[#bot.purchaseListInReverseOrder]
			local owned = bot:FindItemSlot(nextItem) >= 0 or (bot.completedItems and bot.completedItems[nextItem])
				or _insideOwnedUpgrade(nextItem)
			if GetItemCost(nextItem) >= 1000 and owned and nextItem ~= 'item_aghanims_shard' then
				print('[Items] '..botName..' already has '..nextItem..', skipping it')
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

		bot.rebuildCount = 0
		bot.countInvCheck = 0
		if ItemStrategy ~= nil and ItemStrategy.ReviewNext and not Role.IsPvNMode() then
			ItemStrategy.ReviewNext(bot, J.GetPosition(bot), bot.purchaseListInReverseOrder)
		end
		bot.currBuyingItemInPurchaseList = bot.purchaseListInReverseOrder[#bot.purchaseListInReverseOrder]
		-- Item.GetBasicItems keeps "the last skipped owned item" on the bot to
		-- handle doubled components; left over from an earlier item it made an
		-- owned Sange get bought again for Kaya and Sange.
		bot.sLastRepeatItem = nil
		local basicItemTable = Item.GetBasicItems( { bot.currBuyingItemInPurchaseList } )
		-- original behavior: reverse-half interleave to spread purchases
		for i = 1, math.ceil( #basicItemTable / 2 )
		do
			bot.currBuyingBasicItemList[i] = basicItemTable[#basicItemTable-i+1]
			bot.currBuyingBasicItemList[#basicItemTable-i+1] = basicItemTable[i]
		end
		-- Stat components first, the recipe last (the list is bought from the
		-- end): the hero gets the stats early and the gold isn't stuck in a recipe.
		do
			local recipes, others = {}, {}
			for _, name in ipairs(bot.currBuyingBasicItemList) do
				if string.find(name, 'item_recipe_') then table.insert(recipes, name) else table.insert(others, name) end
			end
			local ordered = {}
			for _, name in ipairs(recipes) do table.insert(ordered, name) end
			for _, name in ipairs(others) do table.insert(ordered, name) end
			bot.currBuyingBasicItemList = ordered
		end
		bot.currBuyingBasicItemRefList = Utils.Deepcopy(bot.currBuyingBasicItemList)
		-- build the required counts map for dedupe and re-buy-missing
		bot.currBuyingRequiredCounts = _fullBasicCounts(bot.currBuyingItemInPurchaseList)
		-- proactively drop already-satisfied components to avoid overbuying
		_popIfNoLongerNeeded()
	end

	if #bot.currBuyingBasicItemList == 0
	then
		-- Done also when it went straight into a bigger item (Yasha + Kaya
		-- merge into Yasha and Kaya the moment Kaya is done: SF then "rebuilt"
		-- the Kaya and bought another Yasha).
		local mergedIn = _insideOwnedUpgrade(bot.currBuyingItemInPurchaseList)
		if Item.IsItemInHero( bot.currBuyingItemInPurchaseList ) or mergedIn
			or bot.currBuyingItemInPurchaseList == "item_aghanims_shard"
			or (
				bot == Utils.GetLoneDruid(bot).hero
				and Utils.GetLoneDruid(bot).bear ~= nil
				and Item.GetItemTotalWorthInSlots(Utils.GetLoneDruid(bot).bear) < 28000
				and Item.IsItemInTargetHero(bot.currBuyingItemInPurchaseList, Utils.GetLoneDruid(bot).bear)
			)
			or (bot.countInvCheck > 30 and not _holdsPartOf(bot.currBuyingItemInPurchaseList)) -- can't assemble it: move on, unless we hold parts of it
			or bot.countInvCheck > 120 -- hard limit either way
		then
			-- skip it and continue next
			if Item.IsItemInHero( bot.currBuyingItemInPurchaseList ) or mergedIn then
				bot.completedItems = bot.completedItems or {}
				bot.completedItems[bot.currBuyingItemInPurchaseList] = true
			end
			bot.countInvCheck = 0
			_resetCurrentTarget()
			bot.purchaseListInReverseOrder[#bot.purchaseListInReverseOrder] = nil
		elseif currentTime > bot.lastInvCheck + 1.0 then
			bot.lastInvCheck = currentTime
			-- Holding parts of it: keep rebuying what's missing instead of giving up.
			local nRebuilds = _holdsPartOf(bot.currBuyingItemInPurchaseList) and 10 or 3
			if bot.rebuildCount < nRebuilds and botCourierValue == 0 and botStashValue == 0 and botName ~= "npc_dota_hero_lone_druid" then
				bot.rebuildCount = bot.rebuildCount + 1
				-- try rebuild it based on what's actually missing
				local newList = Item.GetReducedPurchaseList(bot, bot.currBuyingBasicItemRefList)
				for _, value in pairs(newList) do
					if not Item.IsItemInHero(value) then
						bot.currBuyingBasicItemList[#bot.currBuyingBasicItemList+1] = value
					end
				end
				-- Count against the full recipe: a wand missing its second branch
				-- needs 2 branches, not 1 (the owned branch used to satisfy it).
				bot.currBuyingRequiredCounts = _fullBasicCounts(bot.currBuyingItemInPurchaseList)
				_popIfNoLongerNeeded()
				print('[Items] '..botName..' rebuilding '..tostring(bot.currBuyingItemInPurchaseList)..', missing: '..table.concat(bot.currBuyingBasicItemList, ', '))
			elseif botCourierValue == 0 and botStashValue == 0 then
				-- Can't finish it: give up after a while instead of blocking
				-- every later purchase.
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
