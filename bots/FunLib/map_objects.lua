-- Lotus pools and watchers (lanterns).
--
-- Names come from the game's scripts/npc/npc_units.txt and npc_abilities.txt:
--   npc_dota_lotus_pool + hero ability ability_pluck_lotus (channel 1 s, range 400)
--   npc_dota_lantern    + hero ability ability_lamp_use    (channel 1 s, range 200,
--                         active 420 s, then 120 s inactive)
-- Both units are "buildings" (UnitRelationshipClass BUILDING) on the neutral
-- team, so they must not be filtered out with IsBuilding(), and a used lantern
-- doesn't change team: we remember when we lit it.
--
-- Lotus: one grows in each pool every 3 minutes (they pile up). The closest
-- support goes for it; ability_item_usage_generic then eats it or gives it to
-- a core (ConsiderHealingLotus).

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local StuckGuard = require(GetScriptDirectory()..'/FunLib/stuck_guard')
local Objectives = require(GetScriptDirectory()..'/FunLib/objectives')

local X = {}

local SCAN_GAP = 10
local LOTUS_PERIOD = 180
local LOTUS_RANGE_SUPPORT = 3500
local LOTUS_RANGE_ANY = 1000 -- cores: only a pool right on the way (WK left his camp to his skeletons for a pool)
local WATCHER_RANGE = 1300
local WATCHER_COOLDOWN = 420 + 120
local USE_TIMEOUT = 7

local function Log(msg) print('[Map] '..msg) end

MapObjectsState = MapObjectsState or {}
local function State()
	local team = GetTeam()
	if not MapObjectsState[team] then
		MapObjectsState[team] = { scanT = -999, pools = {}, watchers = {}, poolTaken = {}, poolBy = {},
			watcherUsed = {}, watcherBan = {}, logged = false }
	end
	return MapObjectsState[team]
end

local function Key(u)
	local l = u:GetLocation()
	return math.floor(l.x / 100)..':'..math.floor(l.y / 100)
end

local function ModifierNames(u)
	local list = {}
	local ok = pcall(function()
		for i = 0, u:NumModifiers() - 1 do
			table.insert(list, tostring(u:GetModifierName(i))..'x'..tostring(u:GetModifierStackCount(i)))
		end
	end)
	return ok and table.concat(list, ', ') or '?'
end

-- Lotuses waiting in the pool, when the pool's modifier tells (nil if unknown).
local function LotusCount(pool)
	local count
	pcall(function()
		for i = 0, pool:NumModifiers() - 1 do
			local n = string.lower(tostring(pool:GetModifierName(i)))
			if string.find(n, 'lotus') then
				local c = pool:GetModifierStackCount(i)
				if c and c >= 0 then count = math.max(count or 0, c) end
			end
		end
	end)
	return count
end

-- The 10 watchers (npc_dota_lantern) of the 7.42 map, from maps/dota.vpk:
-- they give vision once captured, so no observer ward next to one.
X.LANTERNS = {
	Vector(7918, -1524), Vector(-6464, 6656), Vector(2718, -657), Vector(-3484, 34), Vector(1032, -4260),
	Vector(6528, -6592), Vector(768, -7648), Vector(-671, 7130), Vector(-1527, 3926), Vector(-7808, 1056),
}
function X.NearLantern(loc, r)
	for _, l in ipairs(X.LANTERNS) do
		if (l - loc):Length2D() < (r or 800) then return true end
	end
	return false
end

local function Scan(S)
	if DotaTime() < S.scanT + SCAN_GAP then return end
	S.scanT = DotaTime()
	S.pools, S.watchers = {}, {}
	for _, u in pairs(GetUnitList(UNIT_LIST_ALL)) do
		if u and not u:IsNull() then
			local n = string.lower(u:GetUnitName() or '')
			if string.find(n, 'lotus_pool') then table.insert(S.pools, u)
			elseif string.find(n, 'lantern') then table.insert(S.watchers, u) end
		end
	end
	if not S.logged and DotaTime() > 5 then
		S.logged = true
		Log(#S.pools..' lotus pools, '..#S.watchers..' watchers')
		if S.pools[1] then Log('lotus pool modifiers: '..ModifierNames(S.pools[1])) end
		if S.watchers[1] then Log('watcher modifiers: '..ModifierNames(S.watchers[1])) end
	end
end

local function EnemiesNear(loc, r)
	local n = 0
	for _, h in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(h) and not h:IsIllusion() and not J.IsSuspiciousIllusion(h) and GetUnitToLocationDistance(h, loc) < r then n = n + 1 end
	end
	return n
end

-- A real threat, not just an enemy standing in its lane: the bot was hit in
-- the last 3 s, an enemy is within 600, or it's under 50% HP. (The pools sit
-- by the lanes; "no enemy within 1000-1200" kept restarting every trip.)
local function Threatened(bot)
	return bot:WasRecentlyDamagedByAnyHero(3) or J.GetHP(bot) < 0.5
		or #J.GetNearbyHeroes(bot, 600, true, BOT_MODE_NONE) > 0
end
X.Threatened = Threatened

local function Calm(bot)
	return not J.IsRetreating(bot) and J.GetHP(bot) > 0.25
		and not (J.IsGoingOnSomeone(bot) and (bot.forceFightUntil or -math.huge) < DotaTime()) -- a real fight, not a harass window
end

-- The core of this support's lane is safe to leave for a moment: alive, over
-- 50% HP, not hit in the last 3 s, no enemy hero within 1000 of it.
local function LaneCoreSafe(bot)
	local lane = bot:GetAssignedLane()
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if m and m ~= bot and J.GetPosition(m) <= 3 and m:GetAssignedLane() == lane then
			if not m:IsAlive() then return true end
			if J.GetHP(m) < 0.5 or m:WasRecentlyDamagedByAnyHero(3) then return false end
			if #J.GetNearbyHeroes(m, 1000, true, BOT_MODE_NONE) > 0 then return false end
		end
	end
	return true
end

-- Who may go now: a support when its core is safe; a core last, once the
-- enemy wave next to it is dead.
local function MayGoForLotus(bot)
	if J.GetPosition(bot) >= 4 then return LaneCoreSafe(bot) end
	if DotaTime() > 30 * 60 then return false end -- cores' slots are for items by then
	return #bot:GetNearbyLaneCreeps(1200, true) == 0
end

local function PoolHasLotus(S, pool)
	local c = LotusCount(pool)
	-- A positive stack count is a real count; 0 may just be a modifier that
	-- doesn't count lotuses, so then fall back to the 3-minute schedule.
	if c ~= nil and c > 0 then return true end
	-- Unknown: assume a new one after each 3-minute mark since our last pick.
	local last = S.poolTaken[Key(pool)] or 0
	return math.floor(DotaTime() / LOTUS_PERIOD) > math.floor(last / LOTUS_PERIOD)
end

local function LotusDesire(bot, S)
	if DotaTime() < LOTUS_PERIOD then return nil end
	if (bot._lotusGiveUpUntil or -math.huge) > DotaTime() then return nil end
	if not MayGoForLotus(bot) then return nil end
	-- Not past enemies or into a fight we lose there: Lion went 3400 for a
	-- lotus with Viper and Techies on his way and died, twice in 3 minutes.
	if J.GetHP(bot) < 0.6 or #J.GetNearbyHeroes(bot, 1400, true, BOT_MODE_NONE) > 0 then return nil end
	local support = J.GetPosition(bot) >= 4
	local best, bestDist
	for _, pool in ipairs(S.pools) do
		if pool and not pool:IsNull() and PoolHasLotus(S, pool) then
			local key = Key(pool)
			local d = GetUnitToUnitDistance(bot, pool)
			local claimer = S.poolBy[key]
			local claimed = claimer and claimer ~= bot and claimer:IsAlive() and (claimer._mapTarget == pool)
			local range = support and LOTUS_RANGE_SUPPORT or LOTUS_RANGE_ANY
			if support and DotaTime() > 30 * 60 then range = 1500 end -- late: not across the map (Lion walked 3400 for a pool)
			local safe = EnemiesNear(pool:GetLocation(), 1400) == 0
				and not (Objectives and Objectives.PickoffRisk and Objectives.PickoffRisk(bot, pool:GetLocation()))
				and not (Objectives and Objectives.FightAt and Objectives.FightAt(pool:GetLocation(), bot) < 1.0)
			if not claimed and d < range and safe and (not bestDist or d < bestDist) then
				best, bestDist = pool, d
			end
		end
	end
	if not best then return nil end
	if bot._mapTarget ~= best then
		bot._lotusGoT = DotaTime()
		Log(bot:GetUnitName()..' goes for a lotus ('..math.floor(bestDist)..' away)')
	end
	S.poolBy[Key(best)] = bot
	bot._mapTarget, bot._mapKind = best, 'lotus'
	if bot._mapTarget ~= best or not bot._lotusGoT then bot._lotusGoT = DotaTime() end
	return support and 0.75 or 0.5 -- cores: only when nothing else to do
end

local function WatcherDesire(bot, S)
	-- Supports only: a core's time is worth more (Juggernaut walked back and
	-- forth between his camps and a watcher).
	if J.GetPosition(bot) < 4 then return nil end
	for _, w in ipairs(S.watchers) do
		if w and not w:IsNull() then
			local key = Key(w)
			if DotaTime() > (S.watcherUsed[key] or -9999) + WATCHER_COOLDOWN
			and DotaTime() > (S.watcherBan[key] or -math.huge)
			and GetUnitToUnitDistance(bot, w) < WATCHER_RANGE
			and EnemiesNear(w:GetLocation(), 1300) == 0 then
				bot._mapTarget, bot._mapKind = w, 'watcher'
				return 0.5
			end
		end
	end
	return nil
end

-- Standing in a pool ends after STAND_MAX s whatever else happens. Called
-- first thing in mode_roam's GetDesire (OD stood in the pool for over a
-- minute: another roam desire came first, so the time limit below never ran).
local STAND_MAX = 12
function X.Expire(bot)
	if bot._lotusStandT and (DotaTime() - bot._lotusStandT >= STAND_MAX or J.GetHP(bot) <= 0.25) then
		Log(bot:GetUnitName()..' leaves the lotus pool ('..math.floor(DotaTime() - bot._lotusStandT)..' s there)')
		bot._lotusStandT, bot._mapTarget, bot._mapUseT, bot._lotusGoT = nil, nil, nil, nil
		bot._lotusGiveUpUntil = DotaTime() + 30
		if bot:IsUsingAbility() and not bot:IsChanneling() then bot:Action_ClearActions(true) end
	end
end

-- Desire for mode_roam_generic, or nil.
function X.RoamDesire(bot)
	X.Expire(bot)
	-- Standing in a lotus pool is on purpose.
	if bot._lotusStandT then return 0.75 end
	-- On the way to a pool: keep going (other modes kept interrupting the
	-- walk) for up to 25 s, unless enemies show up or HP gets low.
	-- Keep going unless nearly dead, or (support) its core got in trouble.
	if bot._mapKind == 'lotus' and bot._mapTarget and not bot._mapTarget:IsNull() and bot._lotusGoT
	and DotaTime() - bot._lotusGoT < 25 and J.GetHP(bot) > 0.25
	and (J.GetPosition(bot) < 4 or LaneCoreSafe(bot)) then
		return J.GetPosition(bot) >= 4 and 0.75 or 0.5
	end
	if bot._lotusGoT and not bot._lotusStandT then
		-- The trip ended without getting there (too slow, or its core needed it):
		-- leave the pools alone for a minute (76 trips, 20 arrivals in a game:
		-- they kept turning back and starting again).
		local why = DotaTime() - bot._lotusGoT >= 25 and 'too slow' or 'called back'
		Log(bot:GetUnitName()..' gives up the lotus ('..why..')')
		bot._lotusGoT, bot._mapTarget = nil, nil
		bot._lotusGiveUpUntil = DotaTime() + 60
	end
	if StuckGuard.Blocked(bot, 'map', BOT_MODE_ROAM, 90) or (Objectives and Objectives.IsIdle(bot)) then
		bot._mapTarget, bot._mapUseT = nil, nil
		return nil
	end
	if DotaTime() < 0 or not Calm(bot) then bot._mapTarget, bot._mapUseT = nil, nil return nil end
	local S = State()
	Scan(S)
	if bot._mapTarget and not bot._mapTarget:IsNull() and bot._mapUseT and DotaTime() < bot._mapUseT + USE_TIMEOUT then
		return 0.62
	end
	bot._mapUseT = nil
	return LotusDesire(bot, S) or WatcherDesire(bot, S)
end

-- Lotuses in the inventory (all kinds, charges counted).
local function LotusCount(bot)
	local n = 0
	for _, name in ipairs({ 'item_famango', 'item_great_famango', 'item_greater_famango' }) do
		for slot = 0, 16 do
			local it = bot:GetItemInSlot(slot)
			if it and it:GetName() == name then n = n + math.max(1, it:GetCurrentCharges()) end
		end
	end
	return n
end

-- The pool's passive (ability_lotus_pool, radius 350) hands a lotus to a hero
-- standing inside it for 1.5 s (the next ones faster). Any order resets that,
-- so: walk in, stop, and give no orders until the lotuses stop coming.
function X.LotusThink(bot, pool, S, key)
	local t = DotaTime()
	local d = GetUnitToUnitDistance(bot, pool)
	if not bot._lotusStandT then
		local inside = d <= 220
		if not inside then
			if not bot._mapApproach or d < bot._mapApproach.d - 20 then bot._mapApproach = { d = d, t = t } end
			-- Can't get closer (the pool's hull): inside the 350 radius is enough.
			if d <= 320 and t - bot._mapApproach.t > 1.5 then inside = true end
		end
		if not inside then
			bot:Action_MoveToLocation(pool:GetLocation())
			return true
		end
		bot._mapApproach = nil
		bot:Action_ClearActions(true)
		bot._lotusStandT, bot._lotusLastT, bot._lotusCount, bot._lotusGot = t, t, LotusCount(bot), 0
		bot._lotusCasts, bot._lotusCastT = 0, -99
		Log(bot:GetUnitName()..' stands in the lotus pool')
		return true
	end
	-- Pluck: the hero's hidden channel (ability_pluck_lotus, 1.5 s for the
	-- first lotus, faster after). One order, then wait it out (RoamThink
	-- returns early while channeling); recast if it didn't start.
	local pluck = bot:GetAbilityByName('ability_pluck_lotus')
	if bot:IsChanneling() then bot._lotusChanneled = true end
	-- Cast again only if the last cast gave a lotus (more may be waiting) or
	-- never started its channel.
	local again = bot._lotusCasts == 0 or not bot._lotusChanneled or LotusCount(bot) > (bot._lotusCountAtCast or 0)
	if pluck and again and bot._lotusCasts < 6 and t - bot._lotusCastT > 1.0 and not bot:IsChanneling() then
		bot._lotusCasts, bot._lotusCastT = bot._lotusCasts + 1, t
		bot._lotusCountAtCast, bot._lotusChanneled = LotusCount(bot), false
		bot:Action_UseAbilityOnEntity(pluck, pool)
		bot._lotusLastT = math.max(bot._lotusLastT, t)
		return true
	end
	local n = LotusCount(bot)
	if n > bot._lotusCount then
		bot._lotusGot = bot._lotusGot + (n - bot._lotusCount)
		bot._lotusCount, bot._lotusLastT = n, t
	end
	local done = (bot._lotusGot > 0 and t - bot._lotusLastT > 2.5) or (bot._lotusGot == 0 and t - bot._lotusStandT > 7.0)
	if done or d > 400 then
		S.poolTaken[key] = t
		Log(bot:GetUnitName()..(bot._lotusGot > 0 and (' picked '..bot._lotusGot..' lotus(es)') or ' got no lotus from the pool'))
		bot._lotusStandT, bot._mapTarget, bot._mapUseT, bot._lotusGoT = nil, nil, nil, nil
		return false
	end
	return true -- stand still: no order
end

function X.RoamThink(bot)
	local u, kind = bot._mapTarget, bot._mapKind
	if not u or u:IsNull() then return false end
	local S = State()
	local key = Key(u)
	if bot:IsChanneling() then bot._mapChanneled, bot._lotusChanneled = true, true return true end
	if bot:IsUsingAbility() then return true end
	if kind == 'lotus' then return X.LotusThink(bot, u, S, key) end

	-- Walk into the pool (the lotus is picked standing in it) / up to the lamp.
	-- If the hero can't get closer (the pool's hull), cast from where it is.
	local reach = kind == 'lotus' and 90 or 150
	local d = GetUnitToUnitDistance(bot, u)
	if d > reach and not bot._mapUseT then
		if not bot._mapApproach or d < bot._mapApproach.d - 20 then
			bot._mapApproach = { d = d, t = DotaTime() }
		end
		if DotaTime() - bot._mapApproach.t < 2 or d > 350 then
			bot:Action_MoveToLocation(u:GetLocation())
			return true
		end
	end
	bot._mapApproach = nil

	local t = DotaTime()
	if bot._mapUseT and (t > bot._mapUseT + USE_TIMEOUT or bot._mapChanneled) then
		if kind == 'lotus' then
			S.poolTaken[key] = t
			if not bot._mapChanneled then Log(bot:GetUnitName()..' could not pick the lotus') end
		elseif bot._mapChanneled then
			S.watcherUsed[key] = t
		else
			S.watcherBan[key] = t + 180
			Log(bot:GetUnitName()..' could not activate the watcher')
		end
		if bot._mapChanneled then Log(bot:GetUnitName()..(kind == 'lotus' and ' picked a lotus' or ' activated a watcher')) end
		bot._mapTarget, bot._mapUseT, bot._mapChanneled, bot._mapLogged = nil, nil, nil, nil
		return false
	end

	if not bot._mapUseT then
		bot._mapUseT, bot._mapChanneled = t, false
		Log(bot:GetUnitName()..(kind == 'lotus' and ' picks a lotus' or ' activates a watcher'))
	end
	-- Several ways to give the order, one after another (which one the engine
	-- accepts for bots isn't documented): the hidden ability by name, the same
	-- ability found by scanning the hero's slots, then a right-click on the unit.
	local name = kind == 'lotus' and 'ability_pluck_lotus' or 'ability_lamp_use'
	local ability = bot:GetAbilityByName(name)
	if not ability then
		for i = 0, 35 do
			local ab = bot:GetAbilityInSlot(i)
			if ab and not ab:IsNull() then
				local n = ab:GetName()
				if (kind == 'lotus' and (string.find(n, 'pluck') or string.find(n, 'lotus') or string.find(n, 'famango')))
				or (kind ~= 'lotus' and (string.find(n, 'lamp') or string.find(n, 'lantern'))) then
					ability = ab
					break
				end
			end
		end
	end
	local step = math.floor((t - bot._mapUseT) / 1.2) % 4
	if not bot._mapLogged then
		bot._mapLogged = true
		Log(string.format('%s: %s found=%s castable=%s dist=%d', bot:GetUnitName(), name, tostring(ability and ability:GetName()),
			tostring(ability and ability:IsFullyCastable()), math.floor(GetUnitToUnitDistance(bot, u))))
	end
	if ability and step < 2 then
		bot:Action_UseAbilityOnEntity(ability, u)
	elseif step == 2 then
		bot:Action_AttackUnit(u, true)
	else
		bot:Action_MoveToUnit(u)
	end
	return true
end

return X
