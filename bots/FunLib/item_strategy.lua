--==============================================================================
-- Item strategy: meta builds + situational purchases.
--
--   * GetMetaBuyList(hero, pos): the hero's meta build for its position from
--     Stratz data (FunLib/item_meta_data.lua), or nil to keep the hero file's.
--   * Think(bot, pos, stack): called by item_purchase_generic.lua between two
--     purchases. Looks at both drafts and the game state and changes the
--     purchase stack (bot.purchaseListInReverseOrder, next item = last entry):
--       - counter items vs the enemy draft (illusions, evasion, healing,
--         escapes, magic burst, disables, saves, passives, invisibility),
--       - synergy items for the own draft (Vladmir for physical cores, ...),
--       - game-state choices: farm item first when behind or when the draft
--         can't fight yet (Radiance on WK), fight items first when ahead,
--         defensive items when dying a lot,
--       - only one Pipe/Mek/Greaves/Vladmir/Crimson/Gem per team.
--     Items the hero actually buys on Stratz are preferred, so situational
--     items stay in the hero's style. Every rule fires at most once per bot.
--==============================================================================

local X = {}

local okData, Data = pcall(require, GetScriptDirectory()..'/FunLib/item_meta_data')
if not okData then Data = nil end
local okRoles, HeroRoles = pcall(require, GetScriptDirectory()..'/FunLib/aba_hero_roles_map')
if not okRoles then HeroRoles = nil end

local THINK_INTERVAL = 3      -- seconds between evaluations per bot
local MAX_SITUATIONAL = 4     -- situational additions per bot per game
local MAX_STACK = 9           -- trim the least important planned items above this
local CORE_ITEM_RATE = 80 -- core-defining items (TB's Manta): an early BKB comes right after them
local KEY_ITEM_RATE = 60  -- items the hero buys this often are its key build; situational items wait for them

local function Set(list)
	local s = {}
	for _, v in ipairs(list) do s['npc_dota_hero_'..v] = true end
	return s
end

-- Enemy hero traits ----------------------------------------------------------
local ILLUSION = Set{ 'phantom_lancer', 'terrorblade', 'naga_siren', 'chaos_knight', 'meepo', 'arc_warden', 'morphling' }
local EVASION  = Set{ 'phantom_assassin', 'windrunner', 'brewmaster' }
local HEALING  = Set{ 'necrolyte', 'alchemist', 'huskar', 'morphling', 'abaddon', 'oracle', 'dazzle',
                      'omniknight', 'life_stealer', 'skeleton_king', 'witch_doctor', 'juggernaut',
                      'chen', 'treant', 'wisp', 'undying', 'winter_wyvern', 'bristleback' }
-- "Wild" healing worth a core's Skadi/Shiva; the wider list is enough for a
-- support's Spirit Vessel.
local EXTREME_REGEN = Set{ 'necrolyte', 'huskar', 'alchemist', 'life_stealer', 'morphling' }
local HEAVY_REGEN = Set{ 'necrolyte', 'huskar', 'alchemist', 'life_stealer', 'morphling',
                      'dragon_knight', 'abaddon', 'troll_warlord', 'tidehunter', 'undying' }
-- Escape by blink/teleport/dash: slows don't help, silence/hex/root/bash do.
local BLINK_ESCAPE = Set{ 'storm_spirit', 'puck', 'queenofpain', 'ember_spirit', 'void_spirit',
                      'antimage', 'faceless_void', 'morphling', 'mirana', 'weaver', 'pangolier',
                      'kez', 'marci', 'earth_spirit', 'phoenix', 'monkey_king' }
-- Escape by running (speed, invisibility, leash): slows (Skadi/Shiva) help.
local RUN_ESCAPE = Set{ 'slark', 'riki', 'clinkz', 'dark_willow', 'hoodwink', 'bloodseeker',
                      'spirit_breaker', 'windrunner', 'lycan', 'broodmother', 'batrider',
                      'bounty_hunter', 'nyx_assassin', 'naga_siren', 'troll_warlord', 'ursa' }
-- Own heroes whose skills already stop a blinking hero (silence / stun / root /
-- bash / hex), e.g. Drow's Gust: no uptime item needed.
local OWN_DISABLE = Set{ 'drow_ranger', 'troll_warlord', 'faceless_void', 'slardar', 'spirit_breaker',
                      'sven', 'skeleton_king', 'chaos_knight', 'naga_siren', 'meepo', 'luna', 'medusa',
                      'monkey_king', 'riki', 'morphling', 'lina', 'dragon_knight', 'ogre_magi',
                      'beastmaster', 'mars', 'centaur', 'axe', 'legion_commander', 'tidehunter',
                      'magnataur', 'earthshaker', 'sand_king', 'night_stalker', 'void_spirit',
                      'storm_spirit', 'puck', 'invoker', 'bloodseeker', 'primal_beast', 'pudge',
                      'dawnbreaker', 'kez' }
-- Own heroes with a reliable slow (Drow's Frost Arrows, Ursa's Earthshock...):
-- no slow item needed vs runners. Disablers count too.
local OWN_SLOW = Set{ 'drow_ranger', 'viper', 'venomancer', 'ursa', 'life_stealer', 'bristleback',
                      'sniper', 'muerta', 'razor', 'lycan', 'slark' }
for h, _ in pairs(OWN_DISABLE) do OWN_SLOW[h] = true end
local INVIS    = Set{ 'riki', 'clinkz', 'bounty_hunter', 'weaver', 'nyx_assassin', 'sand_king',
                      'invoker', 'mirana', 'treant' }
local SAVES    = Set{ 'oracle', 'omniknight', 'abaddon', 'dazzle', 'shadow_demon', 'winter_wyvern' }
local PASSIVES = Set{ 'phantom_assassin', 'bristleback', 'spectre', 'troll_warlord', 'slark',
                      'huskar', 'medusa', 'axe', 'chaos_knight', 'skeleton_king' }
local PHYS_CARRY = Set{ 'antimage', 'juggernaut', 'phantom_assassin', 'phantom_lancer', 'spectre',
                      'skeleton_king', 'sven', 'luna', 'life_stealer', 'slark', 'faceless_void',
                      'ursa', 'drow_ranger', 'troll_warlord', 'chaos_knight', 'terrorblade',
                      'medusa', 'naga_siren', 'gyrocopter', 'monkey_king', 'riki', 'weaver',
                      'clinkz', 'templar_assassin', 'lycan', 'bloodseeker', 'dragon_knight', 'kez',
                      'sniper', 'muerta', 'morphling', 'razor', 'lone_druid', 'beastmaster' }
-- Draft timing: heroes whose team wants to fight early vs. heroes that need time.
local EARLY_FIGHT = Set{ 'ursa', 'bloodseeker', 'legion_commander', 'night_stalker', 'batrider',
                      'spirit_breaker', 'bounty_hunter', 'slardar', 'centaur', 'mars', 'tusk',
                      'earth_spirit', 'pangolier', 'void_spirit', 'ember_spirit', 'storm_spirit',
                      'queenofpain', 'lina', 'lion', 'viper', 'venomancer', 'huskar', 'beastmaster',
                      'broodmother', 'razor', 'clockwerk', 'nyx_assassin', 'pudge', 'dragon_knight',
                      'death_prophet', 'leshrac', 'shadow_shaman', 'witch_doctor' }
-- Enemies that gank cores in lane / jungle.
local GANKERS = Set{ 'spirit_breaker', 'nyx_assassin', 'bounty_hunter', 'riki', 'storm_spirit',
                      'night_stalker', 'slardar', 'pudge', 'mirana', 'void_spirit', 'ember_spirit',
                      'queenofpain', 'bloodseeker', 'clockwerk', 'earth_spirit', 'tusk', 'batrider',
                      'legion_commander', 'lion', 'shadow_shaman', 'hoodwink', 'kez' }
local LATE_CARRY = Set{ 'antimage', 'spectre', 'medusa', 'naga_siren', 'terrorblade', 'phantom_lancer',
                      'morphling', 'arc_warden', 'alchemist', 'faceless_void', 'luna', 'gyrocopter',
                      'troll_warlord', 'slark', 'muerta', 'drow_ranger', 'chaos_knight', 'lifestealer',
                      'skeleton_king', 'sven', 'juggernaut', 'phantom_assassin', 'kez', 'weaver' }

-- Items ----------------------------------------------------------------------
local PHYS_ITEMS = { 'desolator', 'bfury', 'manta', 'butterfly', 'greater_crit', 'lesser_crit',
                     'monkey_king_bar', 'skadi', 'satanic', 'basher', 'abyssal_blade', 'mjollnir',
                     'maelstrom', 'echo_sabre', 'harpoon', 'armlet', 'diffusal_blade', 'disperser' }
local FARM_ITEMS  = { 'item_radiance', 'item_bfury', 'item_hand_of_midas', 'item_maelstrom', 'item_mjollnir' }
local FIGHT_ITEMS = { 'item_blink', 'item_black_king_bar', 'item_desolator', 'item_harpoon', 'item_echo_sabre',
                      'item_orchid', 'item_blade_mail', 'item_assault' }
-- One per team.
local TEAM_UNIQUE = { item_pipe = true, item_mekansm = true, item_guardian_greaves = true,
                      item_vladmir = true, item_crimson_guard = true, item_gem = true,
                      item_ancient_janggo = true, item_boots_of_bearing = true }

-- Expected net worth per minute by position, for "is this bot behind?"
local EXPECTED_GPM = { 520, 480, 400, 280, 230 }

--==============================================================================
-- Meta build
--==============================================================================

local function BuildData(hero, pos)
	return Data and Data.Builds[hero] and Data.Builds[hero][pos]
end

-- All components (recursively) of an item, from the game's recipes (aba_item.lua
-- builds Item[...] with GetItemComponents).
local function ComponentsOf(Item, name, acc)
	acc = acc or {}
	local comps = Item and Item[name]
	if type(comps) == 'table' then
		for _, c in ipairs(comps) do
			if type(c) == 'string' and not acc[c] then
				acc[c] = true
				ComponentsOf(Item, c, acc)
			end
		end
	end
	return acc
end

-- Fix the order Stratz phases can produce: a component listed after its
-- upgrade would be bought twice (Perseverance after Battle Fury), so it's
-- dropped; Aghanim's Blessing goes after Aghanim's Scepter.
function X.FixOrder(list, Item)
	for i = #list, 2, -1 do
		for j = 1, i - 1 do
			if list[j] ~= list[i] and ComponentsOf(Item, list[j])[list[i]] then
				table.remove(list, i)
				break
			end
		end
	end
	local s2, s1
	for i, it in ipairs(list) do
		if it == 'item_ultimate_scepter_2' then s2 = i end
		if it == 'item_ultimate_scepter' then s1 = i end
	end
	if s2 and s1 and s2 < s1 then
		table.remove(list, s2)
		table.insert(list, s1, 'item_ultimate_scepter_2') -- s1 shifted down by one: lands right after the scepter
	end
	return list
end

-- Mid heroes buy a Bottle (water runes refill it) unless the hero doesn't
-- play that way. Stratz rates are low for many mids, so it's added here.
local NO_BOTTLE = { invoker = true, huskar = true, viper = true, meepo = true, arc_warden = true, alchemist = true,
	lone_druid = true, medusa = true, razor = true, dragon_knight = true, broodmother = true, necrolyte = true,
	obsidian_destroyer = true, templar_assassin = true, sniper = true, terrorblade = true, ursa = true, slark = true,
	skeleton_king = true, juggernaut = true, morphling = true, troll_warlord = true, faceless_void = true }
local LANE_START = { item_tango = true, item_branches = true, item_quelling_blade = true, item_circlet = true,
	item_faerie_fire = true, item_magic_stick = true, item_gauntlets = true, item_slippers = true, item_mantle = true,
	item_blood_grenade = true, item_flask = true, item_clarity = true, item_enchanted_mango = true,
	item_magic_wand = true, item_bracer = true, item_wraith_band = true, item_null_talisman = true,
	item_double_branches = true, item_double_tango = true }

local function AddBottle(hero, pos, list)
	if pos ~= 2 or NO_BOTTLE[string.gsub(hero, '^npc_dota_hero_', '')] then return end
	-- Intelligence mids with a big mana pool regenerate on their own (OD).
	local r = HeroRoles and HeroRoles.HeroRolesMap and (HeroRoles.HeroRolesMap[hero] or HeroRoles.HeroRolesMap[(string.gsub(hero, '^npc_dota_hero_', ''))])
	if r then
		if r.carry and r.carry >= 3 and (r.nuker or 0) <= 1 then return end -- right-click carries on mid
	end
	for _, it in ipairs(list) do if it == 'item_bottle' then return end end
	local at = #list + 1
	for i, it in ipairs(list) do
		if not LANE_START[it] then at = i break end
	end
	table.insert(list, at, 'item_bottle')
end

-- Stratz merges "boots now, Boots of Travel later" into one early Travel
-- entry: bought literally, the bot got plain boots and then saved 2000 for
-- the Travel recipe with no item in between. Early Travel becomes the hero's
-- usual first boots, and Travel moves three big items later.
local FIRST_BOOTS = { 'item_power_treads', 'item_phase_boots', 'item_arcane_boots', 'item_tranquil_boots' }
local BOOTS_SET = { item_boots = true, item_power_treads = true, item_phase_boots = true, item_arcane_boots = true,
	item_tranquil_boots = true, item_guardian_greaves = true, item_boots_of_bearing = true }
local function FixEarlyTravel(hero, pos, list)
	for i, it in ipairs(list) do
		if BOOTS_SET[it] then return end -- already has early boots
		if it == 'item_travel_boots' then
			if i > 8 then return end
			local first, rate = 'item_boots', 19
			for _, bname in ipairs(FIRST_BOOTS) do
				local r = X._KnownRate(hero, pos, bname) -- defined further down
				if r > rate then first, rate = bname, r end
			end
			list[i] = first
			local later, big = #list + 1, 0
			for j = i + 1, #list do
				if GetItemCost(list[j]) >= 2000 then
					big = big + 1
					if big == 3 then later = j + 1 break end
				end
			end
			table.insert(list, math.min(later, #list + 1), 'item_travel_boots')
			return
		end
	end
end

function X.GetMetaBuyList(hero, pos)
	local b = BuildData(hero, pos)
	if not b then return nil end
	local list = {}
	for i, item in ipairs(b.buy) do list[i] = item end
	FixEarlyTravel(hero, pos, list)
	AddBottle(hero, pos, list)
	local okItem, Item = pcall(require, GetScriptDirectory()..'/FunLib/aba_item')
	return X.FixOrder(list, okItem and Item or nil)
end

-- Highest Stratz purchase rate (%) of an item for this hero at this position.
local function KnownRate(hero, pos, item)
	local b = BuildData(hero, pos)
	return (b and b.known[string.gsub(item, '^item_', '')]) or 0
end
X._KnownRate = KnownRate

--==============================================================================
-- Game state snapshot
--==============================================================================

local function HeroesOf(team)
	local list = {}
	for _, pid in pairs(GetTeamPlayers(team)) do
		local h = GetSelectedHeroName(pid)
		if h and h ~= '' then table.insert(list, h) end
	end
	return list
end

local function Count(heroes, set)
	local n = 0
	for _, h in ipairs(heroes) do if set[h] then n = n + 1 end end
	return n
end

local function CountRole(heroes, fn)
	local n = 0
	if not HeroRoles or not HeroRoles[fn] then return 0 end
	for _, h in ipairs(heroes) do
		local ok, res = pcall(HeroRoles[fn], h)
		if ok and res then n = n + 1 end
	end
	return n
end

local function TeamKills(team)
	local n = 0
	for _, pid in pairs(GetTeamPlayers(team)) do n = n + (GetHeroKills(pid) or 0) end
	return n
end

local function EnemyHasItem(itemName)
	for _, unit in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES) or {}) do
		if unit and unit.FindItemSlot and unit:FindItemSlot(itemName) >= 0 then return true end
	end
	return false
end

local function Snapshot(bot, pos)
	local S = {}
	local hero = bot:GetUnitName()
	S.hero, S.pos = hero, pos
	S.minutes = DotaTime() / 60
	S.allies = HeroesOf(GetTeam())
	S.enemies = HeroesOf(GetOpposingTeam())
	S.core = pos <= 3
	S.support = pos >= 4

	S.physical = false
	for _, item in ipairs(PHYS_ITEMS) do
		if KnownRate(hero, pos, item) >= 10 then S.physical = true break end
	end
	if not BuildData(hero, pos) then S.physical = S.core and PHYS_CARRY[hero] == true end
	S.melee = HeroRoles and HeroRoles.IsRanged and not HeroRoles.IsRanged(hero)
	S.ownSlow = OWN_SLOW[hero] == true
	S.ownDisable = OWN_DISABLE[hero] == true

	S.killDiff = TeamKills(GetTeam()) - TeamKills(GetOpposingTeam())
	local expected = 600 + EXPECTED_GPM[pos] * math.max(0, S.minutes)
	S.farmRatio = bot:GetNetWorth() / expected
	S.deaths = GetHeroDeaths(bot:GetPlayerID()) or 0

	S.behind = (S.killDiff <= -6) or (S.minutes > 8 and S.farmRatio < 0.75)
	S.ahead = (S.killDiff >= 6) and S.farmRatio >= 0.95
	-- "The draft doesn't want to fight yet": our team needs time, theirs is
	-- strong early, and it's still early/mid game.
	S.cantFight = S.minutes < 25
		and Count(S.allies, LATE_CARRY) >= 2
		and Count(S.enemies, EARLY_FIGHT) >= 2

	-- Physical cores on our team other than this bot (for aura/support items).
	S.allyPhysCores = 0
	for _, h in ipairs(S.allies) do
		if h ~= hero and PHYS_CARRY[h] then S.allyPhysCores = S.allyPhysCores + 1 end
	end
	return S
end

--==============================================================================
-- Purchase stack helpers (stack[#stack] is the next item)
--==============================================================================

local function StackIndex(stack, item)
	for i = #stack, 1, -1 do if stack[i] == item then return i end end
	return nil
end

local function OwnsOrPlans(bot, stack, item)
	return bot:FindItemSlot(item) >= 0 or StackIndex(stack, item) ~= nil
end

-- Team-unique items: who owns or has claimed them (shared by the team's bots).
TeamItemClaims = TeamItemClaims or {}
local function TeamClaims()
	local t = GetTeam()
	TeamItemClaims[t] = TeamItemClaims[t] or {}
	return TeamItemClaims[t]
end

local function AllyHasItem(bot, item)
	for i = 1, 5 do
		local ally = GetTeamMember(i)
		if ally and ally ~= bot and ally:IsHero() and ally:FindItemSlot(item) >= 0 then return true end
	end
	local owner = TeamClaims()[item]
	return owner ~= nil and owner ~= bot:GetUnitName()
end

local function Log(bot, msg)
	print('[Items] '..bot:GetUnitName()..': '..msg)
end

-- Put `item` next in line (moves it up if planned, adds it otherwise).
local function PushNext(bot, stack, item, reason, urgent)
	if bot:FindItemSlot(item) >= 0 then return false end
	if TEAM_UNIQUE[item] then
		if AllyHasItem(bot, item) then return false end
		TeamClaims()[item] = bot:GetUnitName()
	end
	local idx = StackIndex(stack, item)
	if idx then table.remove(stack, idx) end

	-- Where it goes (stack[#stack] is bought next):
	--  * situational items wait for the hero's key items still planned (bought
	--    in >= KEY_ITEM_RATE% of games, e.g. TB's Manta), so they don't delay the
	--    core build; only farm-first/fight-first decisions (urgent) skip this;
	--  * a farm-first/fight-first item stays next until bought.
	local at = #stack + 1
	if not urgent or urgent == 'after_core' then
		local hero, pos = bot:GetUnitName(), bot._itemPos or 1
		local rate = urgent == 'after_core' and CORE_ITEM_RATE or KEY_ITEM_RATE
		for i = 1, #stack do
			if KnownRate(hero, pos, stack[i]) >= rate then at = i break end
		end
	end
	if bot._itemProtected and stack[#stack] == bot._itemProtected and item ~= bot._itemProtected then
		at = math.min(at, #stack)
	end

	if idx then
		if idx >= at then -- already planned at least that early: leave it
			table.insert(stack, idx, item)
			return false
		end
		table.insert(stack, at, item)
		Log(bot, 'buy '..item..' earlier ('..reason..')')
	else
		table.insert(stack, at, item)
		Log(bot, '+'..item..' ('..reason..')')
		-- Too many planned items: drop the one this hero buys least on Stratz
		-- (never the next three, never another situational pick), so e.g. Drow's
		-- Aghanim's stays and a rare late item goes.
		while #stack > MAX_STACK do
			local worst, worstRate = 1, math.huge
			for i = 1, #stack - 3 do
				local it = stack[i]
				if not (bot._itemTouched and bot._itemTouched[it]) then
					local r = KnownRate(bot:GetUnitName(), bot._itemPos or 1, it)
					if r < worstRate then worst, worstRate = i, r end
				end
			end
			Log(bot, 'drop '..stack[worst]..' to make room')
			table.remove(stack, worst)
		end
	end
	return true
end

-- First candidate the hero really buys (Stratz >= minRate), else `fallback`.
local function Choose(S, bot, stack, candidates, fallback, minRate)
	for _, item in ipairs(candidates) do
		if KnownRate(S.hero, S.pos, item) >= (minRate or 5) and not OwnsOrPlans(bot, {}, item) then
			return item
		end
	end
	for _, item in ipairs(candidates) do
		if StackIndex(stack, item) then return item end -- already planned: move it up
	end
	return fallback
end

-- Slow / anti-regen item by position: Skadi on pos 1 (and on a physical pos 2),
-- Shiva's Guard on pos 3 and on caster mids.
local function SlowItem(S, bot, stack)
	if S.pos == 1 or (S.pos == 2 and S.physical) then return 'item_skadi' end
	return 'item_shivas_guard'
end

--==============================================================================
-- Rules
--   minute: earliest game minute; when(S): condition; pick(S, bot, stack):
--   returns item, reason. Rules are checked in this order.
--==============================================================================

-- Heroes whose fighting depends on their mana (Medusa's HP is her mana):
-- Diffusal Blade burns it.
local okStatsE, StatsE = pcall(require, GetScriptDirectory()..'/FunLib/item_stats_data')
if not okStatsE then StatsE = nil end
local MANA_DEPENDENT = { npc_dota_hero_medusa = true, npc_dota_hero_storm_spirit = true }

local RULES = {
	-- Mana burn against mana-dependent heroes, for agility melee cores.
	{ name = 'anti_mana', minute = 5, urgent = 'after_core',
	  when = function(S)
		if not S.core or not S.melee then return false end
		local agi = StatsE and StatsE.Heroes and StatsE.Heroes[S.hero] and StatsE.Heroes[S.hero].attr == 'agi'
		if not agi then return false end
		for _, e in ipairs(S.enemies) do if MANA_DEPENDENT[e] then return true end end
		return false
	  end,
	  pick = function(S, bot, stack)
		if OwnsOrPlans(bot, {}, 'item_disperser') then return nil end
		return 'item_diffusal_blade', 'mana burn against a mana-dependent hero'
	  end },
	-- Game state -----------------------------------------------------------
	{ name = 'farm_first', minute = 6, protect = true, when = function(S) return S.core and (S.behind or S.cantFight) end,
	  pick = function(S, bot, stack)
		for _, item in ipairs(FARM_ITEMS) do
			-- Only farm items the hero really builds (like the meta build: >= 30%).
			if KnownRate(S.hero, S.pos, item) >= 30 and not OwnsOrPlans(bot, {}, item) then
				return item, S.behind and 'behind: farm first' or 'draft needs time: farm first'
			end
		end
	  end },
	{ name = 'fight_first', minute = 8, protect = true, when = function(S) return S.core and S.ahead and not S.cantFight end,
	  pick = function(S, bot, stack)
		-- If a farm item is next, take the fight item planned right after it first.
		local top = stack[#stack]
		local isFarm = false
		for _, f in ipairs(FARM_ITEMS) do if f == top then isFarm = true end end
		if not isFarm then return nil end
		for i = #stack - 1, 1, -1 do
			for _, fi in ipairs(FIGHT_ITEMS) do
				if stack[i] == fi then return fi, 'ahead: press the advantage' end
			end
		end
	  end },
	-- Early BKB: right after the hero's core-defining items (>= CORE_ITEM_RATE%,
	-- TB: Manta), before the rest (Dragon Lance, Skadi...) when the own draft wants
	-- early fights, or the bot gets ganked: died 3+ times before 15 min, or the
	-- enemy has 2+ gankers. For cores that build BKB (and mid/carry anyway).
	{ name = 'early_bkb', minute = 7, urgent = 'after_core',
	  when = function(S)
		if not S.core then return false end
		if KnownRate(S.hero, S.pos, 'item_black_king_bar') < 10 and S.pos > 2 then return false end
		local earlyDraft = Count(S.allies, EARLY_FIGHT) >= 3
		local ganked = (S.deaths >= 3 and S.minutes < 15) or Count(S.enemies, GANKERS) >= 2
		return earlyDraft or ganked
	  end,
	  pick = function(S, bot, stack)
		local why = Count(S.allies, EARLY_FIGHT) >= 3 and 'early fights planned' or 'getting ganked'
		return 'item_black_king_bar', why
	  end },
	{ name = 'dying', minute = 8, when = function(S) return S.deaths >= 6 and S.minutes < 30 end,
	  pick = function(S, bot, stack)
		if S.core then
			return Choose(S, bot, stack, { 'item_black_king_bar', 'item_blade_mail' }, S.pos == 1 and 'item_black_king_bar' or nil), 'dying a lot'
		end
		return Choose(S, bot, stack, { 'item_glimmer_cape', 'item_force_staff', 'item_ghost' }, 'item_glimmer_cape'), 'dying a lot'
	  end },

	-- Counters to the enemy draft -------------------------------------------
	{ name = 'anti_illusion', minute = 12,
	  when = function(S) return S.core and S.physical and Count(S.enemies, ILLUSION) >= 1 end,
	  pick = function(S, bot, stack)
		local cands = { 'item_mjollnir', 'item_radiance', 'item_shivas_guard' }
		if S.melee then table.insert(cands, 2, 'item_bfury') end
		return Choose(S, bot, stack, cands, 'item_mjollnir'), 'enemy illusions'
	  end },
	{ name = 'anti_evasion', minute = 16,
	  when = function(S) return S.core and S.physical and (Count(S.enemies, EVASION) >= 1 or EnemyHasItem('item_butterfly')) end,
	  pick = function(S, bot, stack) return 'item_monkey_king_bar', 'enemy evasion' end },
	{ name = 'anti_magic', minute = 10,
	  when = function(S) return CountRole(S.enemies, 'IsNuker') >= 3 end,
	  pick = function(S, bot, stack)
		if S.pos <= 2 then return 'item_black_king_bar', 'enemy magic burst' end
		if S.pos == 3 then return Choose(S, bot, stack, { 'item_pipe', 'item_black_king_bar' }, 'item_pipe'), 'enemy magic burst' end
		return Choose(S, bot, stack, { 'item_pipe', 'item_glimmer_cape' }, nil), 'enemy magic burst'
	  end },
	{ name = 'anti_disable', minute = 14,
	  when = function(S) return S.core and CountRole(S.enemies, 'IsDisabler') >= 3 end,
	  pick = function(S, bot, stack)
		return Choose(S, bot, stack, { 'item_black_king_bar', 'item_sphere', 'item_lotus_orb' }, S.pos <= 2 and 'item_black_king_bar' or nil), 'enemy disables'
	  end },
	{ name = 'anti_physical', minute = 12,
	  when = function(S) return (S.pos >= 3) and Count(S.enemies, PHYS_CARRY) >= 2 end,
	  pick = function(S, bot, stack)
		if S.pos == 3 then
			return Choose(S, bot, stack, { 'item_crimson_guard', 'item_assault', 'item_shivas_guard', 'item_blade_mail' }, 'item_crimson_guard'), 'enemy physical cores'
		end
		return Choose(S, bot, stack, { 'item_solar_crest', 'item_ghost', 'item_glimmer_cape', 'item_force_staff' }, 'item_ghost'), 'enemy physical cores'
	  end },
	-- Huge HP regen (Necrophos, Huskar, Alchemist...): Skadi / Shiva cut healing
	-- and slow; supports take Spirit Vessel.
	{ name = 'anti_regen', minute = 10,
	  when = function(S)
		if S.core then return Count(S.enemies, EXTREME_REGEN) >= 1 end
		return Count(S.enemies, HEAVY_REGEN) >= 1 or Count(S.enemies, HEALING) >= 3
	  end,
	  pick = function(S, bot, stack)
		if S.core then return SlowItem(S, bot, stack), 'enemy hp regen' end
		return Choose(S, bot, stack, { 'item_spirit_vessel', 'item_shivas_guard' }, 'item_spirit_vessel'), 'enemy hp regen'
	  end },
	-- Slows vs heroes that escape by running (Slark, Riki, Bloodseeker...):
	-- Skadi on pos 1-2, Shiva on pos 3, Atos/Gleipnir on supports. Not for heroes
	-- with their own slow/disable (Drow, Viper, Troll...).
	{ name = 'slow', minute = 12,
	  when = function(S) return Count(S.enemies, RUN_ESCAPE) >= 1 and not S.ownSlow end,
	  pick = function(S, bot, stack)
		if S.core then
			-- Melee cores that build Basher get their uptime from the bash instead.
			if S.melee and S.physical and KnownRate(S.hero, S.pos, 'item_basher') >= 10 then
				if bot:FindItemSlot('item_abyssal_blade') >= 0 then return nil end
				return 'item_basher', 'uptime on running enemies'
			end
			return SlowItem(S, bot, stack), 'slow running enemies'
		end
		return Choose(S, bot, stack, { 'item_rod_of_atos', 'item_gungir', 'item_sheepstick' }, 'item_rod_of_atos'), 'slow running enemies'
	  end },
	-- Uptime vs heroes that blink/dash away (QoP, Ember, Storm, AM...): slows are
	-- useless, so silence / hex / root / bash: Basher for melee cores that build
	-- it, Orchid / Bloodthorn / Sheepstick if the hero buys them; supports root
	-- with Atos / Gleipnir. Not for heroes with their own disable (Drow's Gust).
	{ name = 'uptime', minute = 14,
	  when = function(S) return Count(S.enemies, BLINK_ESCAPE) >= 1 and not S.ownDisable end,
	  pick = function(S, bot, stack)
		if S.support then
			return Choose(S, bot, stack, { 'item_rod_of_atos', 'item_gungir', 'item_sheepstick' }, 'item_rod_of_atos'), 'pin down blinking enemies'
		end
		if bot:FindItemSlot('item_abyssal_blade') >= 0 then return nil end
		if S.melee and S.physical and (KnownRate(S.hero, S.pos, 'item_basher') >= 10 or KnownRate(S.hero, S.pos, 'item_abyssal_blade') >= 10) then
			return 'item_basher', 'pin down blinking enemies'
		end
		return Choose(S, bot, stack, { 'item_orchid', 'item_bloodthorn', 'item_sheepstick', 'item_gungir' }, nil), 'pin down blinking enemies'
	  end },
	{ name = 'anti_saves', minute = 22,
	  when = function(S) return S.core and S.physical and Count(S.enemies, SAVES) >= 1 end,
	  pick = function(S, bot, stack)
		return Choose(S, bot, stack, { 'item_nullifier' }, S.pos == 1 and 'item_nullifier' or nil), 'enemy saves'
	  end },
	{ name = 'anti_passive', minute = 20,
	  when = function(S) return S.core and S.physical and Count(S.enemies, PASSIVES) >= 1 end,
	  pick = function(S, bot, stack) return Choose(S, bot, stack, { 'item_silver_edge' }, nil, 5), 'enemy passives' end },
	{ name = 'anti_invis', minute = 16,
	  when = function(S) return S.support and Count(S.enemies, INVIS) >= 1 end,
	  pick = function(S, bot, stack) return 'item_gem', 'invisible enemies' end },

	-- Synergy with the own draft --------------------------------------------
	{ name = 'vladmir_aura', minute = 9,
	  when = function(S)
		return S.allyPhysCores >= 1 and (S.hero == 'npc_dota_hero_wisp'
			or (S.allyPhysCores >= 2 and S.pos >= 3 and KnownRate(S.hero, S.pos, 'item_vladmir') >= 5))
	  end,
	  pick = function(S, bot, stack) return 'item_vladmir', 'aura for physical cores' end },
	{ name = 'solar_crest_carry', minute = 14,
	  when = function(S) return S.support and S.allyPhysCores >= 2 and KnownRate(S.hero, S.pos, 'item_solar_crest') >= 5 end,
	  pick = function(S, bot, stack) return 'item_solar_crest', 'armor for physical cores' end },
}

--==============================================================================
-- Think
--==============================================================================

local function DropDuplicateTeamItems(bot, stack)
	for i = #stack, 1, -1 do
		local item = stack[i]
		if TEAM_UNIQUE[item] and AllyHasItem(bot, item) and bot:FindItemSlot(item) < 0 then
			Log(bot, 'skip '..item..' (a teammate has it)')
			table.remove(stack, i)
		end
	end
	-- Claim team-unique items this bot owns or buys next.
	for item, _ in pairs(TEAM_UNIQUE) do
		if bot:FindItemSlot(item) >= 0 or stack[#stack] == item then
			TeamClaims()[item] = TeamClaims()[item] or bot:GetUnitName()
		end
	end
end

function X.Think(bot, pos, stack)
	if bot.bUserItemBuild or not pos or pos < 1 or pos > 5 then return end
	local now = DotaTime()
	if now < 0 or (bot._itemStrategyNext or -math.huge) > now then return end
	bot._itemStrategyNext = now + THINK_INTERVAL
	bot._itemPos = pos
	bot._itemRulesDone = bot._itemRulesDone or {}
	bot._itemAdded = bot._itemAdded or 0

	DropDuplicateTeamItems(bot, stack)
	if bot._itemAdded >= MAX_SITUATIONAL then return end

	local S = Snapshot(bot, pos)
	for _, rule in ipairs(RULES) do
		if not bot._itemRulesDone[rule.name] and S.minutes >= rule.minute and rule.when(S) then
			local item, reason = rule.pick(S, bot, stack)
			bot._itemRulesDone[rule.name] = true
			bot._itemTouched = bot._itemTouched or {}
			-- Farm/fight-first decision on an item that is already next: keep it next.
			if rule.protect and item and stack[#stack] == item then bot._itemProtected = item end
			-- An item another rule already moved up counts once (BKB vs magic and vs disables).
			if item and not bot._itemTouched[item] and PushNext(bot, stack, item, reason or rule.name, rule.protect or rule.urgent) then
				bot._itemTouched[item] = true
				if rule.protect then bot._itemProtected = item end
				bot._itemAdded = bot._itemAdded + 1
				return -- one change per evaluation; the next one may see a new state
			end
		end
	end
end

--==============================================================================
-- Late game: the meta build is done, keep spending
--==============================================================================
-- Stratz buy phases end around 30-35 minutes, so a finished build left bots
-- with 20k+ unspent. Order: Aghanim's Shard, Scepter (if the hero buys it),
-- Moon Shard (cores), Aghanim's Blessing, then the hero's own late items
-- from Stratz (by purchase rate), then a role list.

local LATE_BY_ROLE = {
	[1] = { 'item_butterfly', 'item_satanic', 'item_greater_crit', 'item_skadi', 'item_abyssal_blade',
	        'item_monkey_king_bar', 'item_disperser', 'item_heart', 'item_refresher', 'item_travel_boots' },
	[2] = { 'item_sheepstick', 'item_refresher', 'item_octarine_core', 'item_shivas_guard', 'item_bloodthorn',
	        'item_skadi', 'item_heart', 'item_arcane_blink', 'item_travel_boots', 'item_satanic' },
	[3] = { 'item_heart', 'item_shivas_guard', 'item_assault', 'item_refresher', 'item_overwhelming_blink',
	        'item_abyssal_blade', 'item_lotus_orb', 'item_travel_boots', 'item_satanic' },
	[4] = { 'item_travel_boots', 'item_aeon_disk', 'item_sheepstick', 'item_octarine_core', 'item_refresher',
	        'item_shivas_guard', 'item_lotus_orb', 'item_heart' },
	[5] = { 'item_travel_boots', 'item_aeon_disk', 'item_sheepstick', 'item_octarine_core', 'item_refresher',
	        'item_shivas_guard', 'item_lotus_orb', 'item_heart' },
}
local NOT_LATE = {}
for _, n in ipairs({ 'aghanims_shard', 'ultimate_scepter', 'ultimate_scepter_2', 'moon_shard', 'boots',
	'travel_boots_2', 'power_treads', 'phase_boots', 'arcane_boots', 'tranquil_boots', 'hand_of_midas',
	'magic_wand', 'bracer', 'wraith_band', 'null_talisman', 'soul_ring', 'infused_raindrop', 'urn_of_shadows',
	'vanguard', 'buckler', 'ring_of_basilius', 'pers', 'oblivion_staff', 'sange', 'yasha', 'kaya', 'maelstrom',
	'lesser_crit', 'dragon_lance', 'echo_sabre', 'ogre_axe', 'blade_of_alacrity', 'staff_of_wizardry' }) do NOT_LATE[n] = true end

local okItemLib, ItemLib = pcall(require, GetScriptDirectory()..'/FunLib/aba_item')
if not okItemLib then ItemLib = nil end
local okValue, ItemValue = pcall(require, GetScriptDirectory()..'/FunLib/item_value')
if not okValue then ItemValue = nil end
local okStatsL, Stats = pcall(require, GetScriptDirectory()..'/FunLib/item_stats_data')
if not okStatsL then Stats = nil end
-- Added by 7.42.
local NEW_ITEMS = { 'item_caduceus', 'item_skypiercer', 'item_starforge', 'item_berserkers_sabatons', 'item_ristuls_devotion' }

-- Mid game: of the next big items planned, buy first the one worth clearly
-- more for this hero right now (pros' order otherwise). Called by
-- item_purchase_generic before it starts a new item.
-- Items that make the hero's fight work come before BKB: a BKB alone does
-- nothing for an initiator (LC bought BKB with no Blink or Blade Mail).
local INITIATION = { { item = 'item_blink', rate = 30 }, { item = 'item_blade_mail', rate = 40 } }
local OWNED_AS = { item_blink = { 'item_blink', 'item_overwhelming_blink', 'item_swift_blink', 'item_arcane_blink' },
                   item_blade_mail = { 'item_blade_mail' } }

-- The initiation item this hero still lacks (nil if none or owned).
local function MissingInitiation(bot, pos)
	local hero = bot:GetUnitName()
	for _, it in ipairs(INITIATION) do
		local owned = false
		for _, n in ipairs(OWNED_AS[it.item]) do if bot:FindItemSlot(n) >= 0 then owned = true end end
		if not owned and KnownRate(hero, pos, it.item) >= it.rate then return it end
	end
	return nil
end

local function InitiationFirst(bot, pos, stack)
	if stack[#stack] ~= 'item_black_king_bar' then return end
	do
		local it = MissingInitiation(bot, pos)
		if it then
			local idx = StackIndex(stack, it.item)
			if idx then table.remove(stack, idx) end
			table.insert(stack, it.item)
			Log(bot, it.item..' before item_black_king_bar (the fight starts with it)')
			return
		end
	end
end

-- A carry's BKB with no damage item yet does nothing for its fights: take
-- the first planned damage item first, unless the enemies are mostly magic.
local function DamageBeforeBKB(bot, pos, stack)
	if pos ~= 1 or stack[#stack] ~= 'item_black_king_bar' or not StatsE then return end
	if ItemValue and ItemValue.EnemyMix() >= 0.65 then return end
	local function IsDamage(name)
		local st = StatsE.Items[name]
		return st and (st.cost or 0) >= 1500 and ((st.dmg or 0) >= 20 or (st.as or 0) >= 25 or (st.crit or 0) > 0 or (st.agi or 0) >= 25)
	end
	for i = 0, 8 do
		local it = bot:GetItemInSlot(i)
		if it and IsDamage(it:GetName()) then return end -- already has one
	end
	for i = #stack - 1, 1, -1 do
		if IsDamage(stack[i]) then
			local it = table.remove(stack, i)
			table.insert(stack, it)
			Log(bot, it..' before item_black_king_bar (no damage item yet)')
			return
		end
	end
end

function X.ReviewNext(bot, pos, stack)
	if #stack >= 1 then InitiationFirst(bot, pos, stack) end
	if #stack >= 1 then DamageBeforeBKB(bot, pos, stack) end
	if not ItemValue or #stack < 2 or DotaTime() < 15 * 60 then return end
	local top = stack[#stack]
	if GetItemCost(top) < 2500 then return end
	local hero, minutes = bot:GetUnitName(), DotaTime() / 60
	local magic = ItemValue.EnemyMix()
	local topScore = ItemValue.Score(hero, pos, top, minutes, magic)
	local bestIdx, bestScore = nil, topScore * 1.25
	for i = #stack - 1, math.max(1, #stack - 3), -1 do
		local it = stack[i]
		-- Not an item much dearer than the planned one: MK went for Skadi
		-- (5900, two 2800 orbs) over Desolator (3500) and sat on 2000 gold.
		if GetItemCost(it) >= 2500 and GetItemCost(it) <= GetItemCost(top) * 1.25
		and not (it == 'item_black_king_bar' and MissingInitiation(bot, pos)) then
			local sc = ItemValue.Score(hero, pos, it, minutes, magic)
			if sc > bestScore then bestIdx, bestScore = i, sc end
		end
	end
	if bestIdx then
		local it = table.remove(stack, bestIdx)
		table.insert(stack, it)
		Log(bot, string.format('%s before %s (worth %.2f vs %.2f for this hero now)', it, top, bestScore, topScore))
	end
end

-- Owned, or already built into an owned item (Kaya inside Kaya and Sange).
local function Has(bot, item)
	if bot:FindItemSlot(item) >= 0 then return true end
	if not ItemLib then return false end
	for i = 0, 16 do
		local it = bot:GetItemInSlot(i)
		if it and ComponentsOf(ItemLib, it:GetName())[item] then return true end
	end
	return false
end

local function BigItemsCount(bot)
	local n = 0
	for i = 0, 8 do
		local it = bot:GetItemInSlot(i)
		if it and GetItemCost(it:GetName()) >= 2000 then n = n + 1 end
	end
	return n
end

function X.NextLateItem(bot, pos)
	local hero = bot:GetUnitName()
	if not bot:HasModifier('modifier_item_aghanims_shard') and not Has(bot, 'item_aghanims_shard')
	and bot.hasBuyShard ~= false -- false: already saving up for it
	and DotaTime() > 15 * 60 then
		return 'item_aghanims_shard'
	end
	if not bot:HasScepter() and KnownRate(hero, pos, 'item_ultimate_scepter') >= 10 then
		return 'item_ultimate_scepter'
	end
	if pos <= 3 and not bot:HasModifier('modifier_item_moon_shard_consumed') and not Has(bot, 'item_moon_shard')
	and bot:GetNetWorth() > 18000 then
		return 'item_moon_shard'
	end
	if not bot:HasModifier('modifier_item_ultimate_scepter_consumed') and bot:GetNetWorth() > 22000
	and (bot:HasScepter() or KnownRate(hero, pos, 'item_ultimate_scepter_2') >= 3) then
		return 'item_ultimate_scepter_2'
	end
	-- Six big items: nothing left to add (selling for upgrades isn't planned).
	if BigItemsCount(bot) >= 6 then return nil end

	-- Candidates: what this hero buys on Stratz, the role list and the new
	-- 7.42 items; ranked by the item's stats for this hero now (item_value.lua),
	-- with the pros' purchase rate as a bonus.
	local cand = {}
	local b = BuildData(hero, pos)
	if b and b.known then
		for name, rate in pairs(b.known) do
			if rate >= 4 then cand['item_'..name] = rate end
		end
	end
	for _, item in ipairs(LATE_BY_ROLE[pos] or LATE_BY_ROLE[1]) do cand[item] = cand[item] or 0 end
	for _, item in ipairs(NEW_ITEMS) do cand[item] = cand[item] or 0 end
	local magic = ItemValue and ItemValue.EnemyMix() or 0.5
	local best, bestScore
	for item, rate in pairs(cand) do
		local name = string.gsub(item, '^item_', '')
		if not NOT_LATE[name] and GetItemCost(item) >= 2000 and not Has(bot, item)
		and not (Stats and Stats.Items and not Stats.Items[item])
		and not (TEAM_UNIQUE[item] and AllyHasItem(bot, item)) then
			local sc = ItemValue and ItemValue.Score(hero, pos, item, DotaTime() / 60, magic) or 0
			sc = sc * (1 + 0.6 * rate / 100)
			if not bestScore or sc > bestScore then best, bestScore = item, sc end
		end
	end
	return best
end

-- Called by item_purchase_generic when the purchase list is empty.
function X.LateGame(bot, pos, stack)
	if bot.bUserItemBuild or not pos or #stack > 0 then return end
	local now = DotaTime()
	if now < 20 * 60 or (bot._lateNext or -math.huge) > now then return end
	bot._lateNext = now + 5
	local item = X.NextLateItem(bot, pos)
	if item then
		table.insert(stack, item)
		Log(bot, '+'..item..' (late game, the build is finished)')
	end
end

--==============================================================================
-- Patch check: items removed from the shop
--==============================================================================
-- The meta data and the hero files can name items a patch removed (7.42:
-- Khanda, Helm of the Overlord, Javelin...). Buying them fails, so they're
-- replaced by their closest successor, or dropped.
local okStats, Stats = pcall(require, GetScriptDirectory()..'/FunLib/item_stats_data')
if not okStats then Stats = nil end
local SUCCESSOR = {
	item_khanda = 'item_caduceus', item_angels_demise = 'item_caduceus',
	item_helm_of_the_overlord = 'item_helm_of_the_dominator', item_eternal_shroud = 'item_pipe',
	item_wraith_pact = 'item_ristuls_devotion',
}
local KEEP = { item_famango = true, item_great_famango = true, item_greater_famango = true, item_ward_dispenser = true }

local function Removed(name)
	if not Stats or KEEP[name] then return false end
	if string.find(name, '^item_recipe_') or string.find(name, 'item_double') or string.find(name, 'PvN_') then return false end
	if Stats.Items[name] then return false end
	if Stats.Obsolete[name] then return true end
	if Stats.Known and Stats.Known[name] then return false end -- free items (observer wards...)
	-- Not in the game at all (and not one of aba_item's own bundles).
	local okItem, ItemLib = pcall(require, GetScriptDirectory()..'/FunLib/aba_item')
	if okItem and ItemLib and type(ItemLib[name]) == 'table' and #ItemLib[name] > 0 then return false end
	return true
end

function X.CleanBuildList(list, heroName)
	if not list or not Stats then return list end
	local out, seen = {}, {}
	for _, it in ipairs(list) do
		local name = it
		if Removed(name) then
			name = SUCCESSOR[it]
			print('[Items] '..tostring(heroName)..': '..it..' is not in the shop ('..(name and ('-> '..name) or 'dropped')..')')
		end
		if name and not (seen[name] and GetItemCost(name) >= 1000) then
			table.insert(out, name)
			seen[name] = true
		end
	end
	return out
end

X.RULES = RULES -- for tests
X.Snapshot = Snapshot
return X
