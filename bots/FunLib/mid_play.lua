--==============================================================================
-- Mid player (pos 2) in the laning stage and right after it.
--
--   * Lane harass: when the enemy mid is in range, no last hit is pending and
--     the trade is fair, the mid briefly counts as "going on someone" so its
--     hero file throws spells at the enemy, then goes back to last hitting.
--   * Water runes (2:00, 4:00): the mid takes them once its wave is cleared
--     and it actually needs HP/mana. Other bots leave them to the mid.
--   * Power runes (6:00 and every 2 min): the mid contests them.
--   * Haste / invisibility rune: the mid goes to a side lane where the allies
--     there plus the mid have the damage to kill someone (enemy skills such as
--     escapes are taken into account).
--   * After the enemy mid tower falls: gank-type mids (nukers, disablers,
--     initiators with escapes) look for ganks on the side lanes; farm-type mids
--     keep farming, but step back to the own half when most enemies are missing.
--==============================================================================

local X = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local okRoles, HeroRoles = pcall(require, GetScriptDirectory()..'/FunLib/aba_hero_roles_map')
if not okRoles then HeroRoles = nil end

local HARASS_TIME = 1.5        -- seconds a harass window lasts
local HARASS_COOLDOWN = 3.0
local GANK_MARGIN = 1.2        -- team damage / target HP needed for a gank
local GANK_MARGIN_ESCAPE = 1.5
local POST_TOWER_CHECK = 15    -- seconds between gank checks after the tower falls
local POST_TOWER_UNTIL = 20 * 60

local function Log(bot, msg) print('[Mid] '..bot:GetUnitName()..': '..msg) end
local function Dist(a, b) return (a - b):Length2D() end

local function IsMid(bot) return J.GetPosition(bot) == 2 end

local function RealHeroes(listType, loc, radius)
	local list = {}
	for _, h in pairs(GetUnitList(listType)) do
		if J.IsValidHero(h) and not h:IsIllusion() and not J.IsSuspiciousIllusion(h) and Dist(h:GetLocation(), loc) <= radius then
			table.insert(list, h)
		end
	end
	return list
end

local function NearEnemyTower(loc, radius)
	for _, id in ipairs({ TOWER_TOP_1, TOWER_MID_1, TOWER_BOT_1, TOWER_TOP_2, TOWER_MID_2, TOWER_BOT_2 }) do
		local t = GetTower(GetOpposingTeam(), id)
		if t and Dist(t:GetLocation(), loc) < radius then return true end
	end
	return false
end

local function HasEscape(hero)
	return HeroRoles and HeroRoles.HasEscape and HeroRoles.HasEscape(hero:GetUnitName())
end

--------------------------------------------------------------------------------
-- Lane harass
--------------------------------------------------------------------------------

-- Called from mode_laning_generic GetDesire (runs every frame).
function X.LaningHarass(bot)
	if not IsMid(bot) or bot:GetActiveMode() ~= BOT_MODE_LANING then return end
	local t = DotaTime()
	if t < 0 or t > 10 * 60 then return end
	if (bot.forceFightUntil or -math.huge) > t or (bot._harassNext or -math.huge) > t then return end
	if J.GetHP(bot) < 0.5 then return end

	local myLoc = bot:GetLocation()
	local range = bot:GetAttackRange()
	if NearEnemyTower(myLoc, 850) then return end

	-- A last hit is up: that comes first.
	local dmg = bot:GetAttackDamage()
	local creeps = bot:GetNearbyLaneCreeps(range + 250, true)
	for _, c in pairs(creeps) do
		if J.IsValid(c) and c:GetHealth() < dmg * 1.4 then return end
	end
	-- Hitting a hero pulls the enemy creeps: only with few of them around.
	if #bot:GetNearbyLaneCreeps(500, true) > 2 and J.GetHP(bot) < 0.75 then return end

	local target, best = nil, math.huge
	for _, e in ipairs(RealHeroes(UNIT_LIST_ENEMY_HEROES, myLoc, math.max(range + 250, 700))) do
		if J.CanBeAttacked(e) and not NearEnemyTower(e:GetLocation(), 700) then
			local d = Dist(e:GetLocation(), myLoc)
			if d < best then target, best = e, d end
		end
	end
	if not target then return end
	-- Fair trade only: don't harass from far behind in HP.
	if J.GetHP(target) > J.GetHP(bot) + 0.15 then return end

	bot.forceFightUntil = t + HARASS_TIME
	bot._harassNext = t + HARASS_TIME + HARASS_COOLDOWN
	bot:SetTarget(target)
end

--------------------------------------------------------------------------------
-- Water / power runes
--------------------------------------------------------------------------------

local function MidAlly()
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if m and m:IsAlive() and J.GetPosition(m) == 2 then return m end
	end
	return nil
end

local function Scaled(base, dist, maxDist)
	if dist >= maxDist then return 0 end
	return base * (1 - 0.5 * dist / maxDist)
end

-- Called from mode_rune_generic for power-rune spots. Returns a desire, or nil
-- to keep the default logic.
function X.PowerRuneDesire(bot, rune, status, runeType, dist, hp, mp, hasBottle)
	local t = DotaTime()
	if t > 15 * 60 then return nil end
	local minute, second = math.floor(t / 60), t % 60

	if not IsMid(bot) then
		-- Leave runes to the mid during the laning stage unless they're right here.
		local mid = MidAlly()
		if mid and mid:IsBot() and J.IsInLaningPhase()
		and GetUnitToLocationDistance(mid, GetRuneSpawnLocation(rune)) < 4500
		and dist > 600 then
			return BOT_MODE_DESIRE_NONE
		end
		return nil
	end

	local waveClear = #bot:GetNearbyLaneCreeps(900, true) == 0

	if t < 6 * 60 - 15 or runeType == RUNE_WATER then
		-- Water rune: after the wave is dead, and only if HP/mana are missing.
		local up = status == RUNE_STATUS_AVAILABLE
			or (status == RUNE_STATUS_UNKNOWN and (minute == 2 or minute == 4) and second < 50)
		if not up then return nil end
		local need = hasBottle or hp < 0.85 or mp < 0.8
		if not need then return BOT_MODE_DESIRE_NONE end
		if waveClear or dist < 900 then
			if bot._waterLog ~= minute then bot._waterLog = minute Log(bot, 'wave cleared, going for the water rune') end
			return Scaled(BOT_MODE_DESIRE_HIGH, dist, 3500)
		end
		return BOT_MODE_DESIRE_NONE
	end

	-- Power rune: every 2 minutes from 6:00.
	if hp < 0.35 then return nil end
	if status == RUNE_STATUS_AVAILABLE and dist < 4500 then
		if bot._powerLog ~= minute then bot._powerLog = minute Log(bot, 'power rune is up, taking it') end
		return Scaled(BOT_MODE_DESIRE_VERYHIGH, dist, 4500)
	end
	local window = (minute % 2 == 1 and second >= 45) or (minute % 2 == 0 and second < 20)
	if status == RUNE_STATUS_UNKNOWN and window and dist < 4000 and (waveClear or second >= 52 or minute % 2 == 0) then
		return Scaled(BOT_MODE_DESIRE_HIGH, dist, 4000)
	end
	return nil
end

--------------------------------------------------------------------------------
-- Ganks (rune ganks and after the tower falls)
--------------------------------------------------------------------------------

local function GankMargin(bot, target)
	local tLoc = target:GetLocation()
	local allies = RealHeroes(UNIT_LIST_ALLIED_HEROES, tLoc, 1500)
	local hasBot = false
	for _, a in ipairs(allies) do if a == bot then hasBot = true end end
	if not hasBot then table.insert(allies, bot) end
	local enemies = RealHeroes(UNIT_LIST_ENEMY_HEROES, tLoc, 1500)
	if #enemies > #allies then return 0 end

	local dmg = 0
	for _, a in ipairs(allies) do
		if a:IsAlive() and J.GetHP(a) > 0.3 then
			dmg = dmg + a:GetEstimatedDamageToTarget(true, target, 5.0, DAMAGE_TYPE_ALL)
		end
	end
	local need = HasEscape(target) and GANK_MARGIN_ESCAPE or GANK_MARGIN
	-- Every extra enemy hero around makes it harder.
	need = need * (1 + 0.35 * (#enemies - 1))
	return dmg / math.max(1, target:GetHealth() * need)
end

local function InMidLane(loc)
	local info = GetAmountAlongLane(LANE_MID, loc)
	return info and info.distance and info.distance < 1300
end

local function FindGankTarget(bot, maxDist, minMargin)
	local best, bestScore = nil, 0
	for _, e in ipairs(RealHeroes(UNIT_LIST_ENEMY_HEROES, bot:GetLocation(), maxDist)) do
		local loc = e:GetLocation()
		if not InMidLane(loc) and not NearEnemyTower(loc, 750) and J.CanBeAttacked(e) then
			local m = GankMargin(bot, e)
			if m >= minMargin then
				local score = m - Dist(loc, bot:GetLocation()) / 10000
				if score > bestScore then best, bestScore = e, score end
			end
		end
	end
	return best
end

local function StartGank(bot, target, duration, why)
	bot.midGank = { target = target, untilT = DotaTime() + duration, lastSeen = DotaTime() }
	Log(bot, why..' -> '..target:GetUnitName())
end

-- 'gank' or 'farm', from the hero's roles.
function X.Style(bot)
	if bot._midStyle then return bot._midStyle end
	local style = 'farm'
	if HeroRoles and HeroRoles.HeroRolesMap then
		local r = HeroRoles.HeroRolesMap[bot:GetUnitName()]
		if r then
			local gank = (r.nuker or 0) + (r.disabler or 0) + (r.initiator or 0) + (r.escape or 0)
			if gank >= 2 * (r.carry or 0) then style = 'gank' end
		end
	end
	bot._midStyle = style
	Log(bot, 'mid style: '..style)
	return style
end

local function EnemyTowerMidDown()
	return GetTower(GetOpposingTeam(), TOWER_MID_1) == nil
end

local function MissingEnemies()
	local n = 0
	for _, id in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(id) then
			local info = GetHeroLastSeenInfo(id)
			local d = info and info[1]
			if d == nil or d.time_since_seen > 4 then n = n + 1 end
		end
	end
	return n
end

local function OnEnemyHalf(bot, margin)
	local loc = bot:GetLocation()
	return Dist(loc, J.GetEnemyFountain()) + margin < Dist(loc, J.GetTeamFountain())
end

-- Called from mode_roam_generic GetDesireHelper. Returns a desire or nil.
function X.RoamDesire(bot)
	if not IsMid(bot) then return nil end
	local t = DotaTime()
	if t < 5 * 60 or t > 25 * 60 then bot.midGank = nil return nil end

	local g = bot.midGank
	if g then
		local tgt = g.target
		if tgt and tgt:CanBeSeen() and tgt:IsAlive() then g.lastSeen = t end
		local enemiesHere = RealHeroes(UNIT_LIST_ENEMY_HEROES, bot:GetLocation(), 1200)
		local alliesHere = RealHeroes(UNIT_LIST_ALLIED_HEROES, bot:GetLocation(), 1400)
		if t > g.untilT or t - g.lastSeen > 3 or not tgt:IsAlive()
		or J.GetHP(bot) < 0.35 or #enemiesHere > #alliesHere + 1 then
			Log(bot, 'gank over')
			bot.midGank = nil
			bot._gankNext = t + POST_TOWER_CHECK
			return nil
		end
		return BOT_MODE_DESIRE_VERYHIGH
	end

	-- Haste / invisibility rune: look for a kill on a side lane.
	local haste = bot:HasModifier('modifier_rune_haste')
	local invis = bot:HasModifier('modifier_rune_invis')
	if (haste or invis) and J.GetHP(bot) > 0.5 then
		local tgt = FindGankTarget(bot, invis and 7000 or 6000, 1.0)
		if tgt then
			StartGank(bot, tgt, invis and 40 or 22, invis and 'invis rune gank' or 'haste rune gank')
			return BOT_MODE_DESIRE_VERYHIGH
		end
	end

	-- After the enemy mid tower falls.
	if EnemyTowerMidDown() and t < POST_TOWER_UNTIL then
		if X.Style(bot) == 'gank' then
			if t >= (bot._gankNext or 0) and J.GetHP(bot) > 0.6 and J.GetMP(bot) > 0.5 then
				bot._gankNext = t + POST_TOWER_CHECK
				local tgt = FindGankTarget(bot, 5000, 1.15)
				if tgt then
					StartGank(bot, tgt, 30, 'tower down, ganking')
					return BOT_MODE_DESIRE_VERYHIGH
				end
			end
		else
			-- Farm, but don't stay deep when most enemies are unaccounted for.
			local alone = #RealHeroes(UNIT_LIST_ALLIED_HEROES, bot:GetLocation(), 1500) <= 1
			if alone and MissingEnemies() >= 3 and OnEnemyHalf(bot, 800) then
				if not bot._safeLog or t - bot._safeLog > 20 then bot._safeLog = t Log(bot, 'enemies missing, farming on our half') end
				bot._safeFarm = true
				return BOT_MODE_DESIRE_HIGH
			end
		end
	end
	bot._safeFarm = nil
	return nil
end

-- Returns true when it issued an action.
function X.RoamThink(bot)
	if not IsMid(bot) then return false end
	local g = bot.midGank
	if g then
		local tgt = g.target
		local d = GetUnitToUnitDistance(bot, tgt)
		if d > bot:GetAttackRange() + 500 then
			bot:Action_MoveToLocation(tgt:GetLocation())
		else
			bot.forceFightUntil = DotaTime() + 2 -- spells on the target
			bot:SetTarget(tgt)
			bot:Action_AttackUnit(tgt, true)
		end
		return true
	end
	if bot._safeFarm then
		local tower = GetTower(GetTeam(), TOWER_MID_1) or GetTower(GetTeam(), TOWER_MID_2)
		bot:Action_MoveToLocation(tower and tower:GetLocation() or J.GetTeamFountain())
		return true
	end
	return false
end

return X
