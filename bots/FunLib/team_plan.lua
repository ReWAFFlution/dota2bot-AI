--==============================================================================
-- Team plan for the mid game until one of the ancients falls.
--
-- Phases (one shared state per team, recomputed twice a second):
--   laning   - before the first enemy tier-1 tower falls.
--   spread   - some enemy T1 are down: no deep pushes past them unless the team
--              is grouped (4+ heroes with 2 cores); supports roam, ward, help.
--   hunt     - all enemy T1 are down: pos 3 + pos 4 + pos 5 gather, smoke and
--              hunt the enemy carry (or the mid if there's enough damage for
--              it), ward the enemy jungle near the target, tank in front.
--   siege    - another core joins the hunting group: push the closest enemy T2
--              together, then the next buildings while it goes well; back to
--              hunting when it doesn't.
--   finish   - after a (near) team wipe: everyone pushes the base.
--   regroup  - the enemies respawned during the finish: step back to safety.
--   defend   - we are clearly behind: hold near our base and pick off enemies
--              that step in with spells; after a good defense, hunt again.
-- Bots never give up: no phase stops them from playing until an ancient falls.
--==============================================================================

local X = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Objectives = require(GetScriptDirectory()..'/FunLib/objectives')
local okRoles, HeroRoles = pcall(require, GetScriptDirectory()..'/FunLib/aba_hero_roles_map')
if not okRoles then HeroRoles = nil end
local okER, EnemyRoles = pcall(require, GetScriptDirectory()..'/FunLib/enemy_role_estimation')
if not okER then EnemyRoles = nil end

local UPDATE_GAP = 0.5
local HUNT_TIMEOUT = 75          -- seconds a hunt may last before a new target is picked
local HUNT_MARGIN = 1.15         -- group damage / target HP needed to commit
local HUNT_MARGIN_ESCAPE = 1.45
local SIEGE_MIN_GROUP = 4
local REGROUP_TIME = 10
local BEHIND_NETWORTH = 10000    -- "defend" phase when this far behind ...
local BEHIND_LEVELS = 3          -- ... or this many levels on average

local function Log(msg) print('[Team '..GetTeam()..'] '..msg) end
local function Dist(a, b) return (a - b):Length2D() end

local LANES = { LANE_TOP, LANE_MID, LANE_BOT }
local T1 = { [LANE_TOP] = TOWER_TOP_1, [LANE_MID] = TOWER_MID_1, [LANE_BOT] = TOWER_BOT_1 }
local T2 = { [LANE_TOP] = TOWER_TOP_2, [LANE_MID] = TOWER_MID_2, [LANE_BOT] = TOWER_BOT_2 }
local T3 = { [LANE_TOP] = TOWER_TOP_3, [LANE_MID] = TOWER_MID_3, [LANE_BOT] = TOWER_BOT_3 }

TeamPlanState = TeamPlanState or {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function Members()
	local list = {}
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if m and m:IsHero() then table.insert(list, m) end
	end
	return list
end

local function MemberAt(pos)
	for _, m in ipairs(Members()) do
		if J.GetPosition(m) == pos then return m end
	end
	return nil
end

local function IsAliveBot(m) return m and m:IsAlive() and m:IsBot() end

local function AliveCount(team)
	local n = 0
	for _, id in pairs(GetTeamPlayers(team)) do
		if IsHeroAlive(id) then n = n + 1 end
	end
	return n
end

local function RealEnemiesNear(loc, radius)
	local list = {}
	for _, h in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(h) and not h:IsIllusion() and not J.IsSuspiciousIllusion(h) and Dist(h:GetLocation(), loc) <= radius then
			table.insert(list, h)
		end
	end
	return list
end

-- Inventory networth (enemy items are known once seen), cached by jmz_func.
local lastNW = { 0, 0 }
local function NetworthDiff()
	local ally, enemy = J.GetInventoryNetworth()
	if ally and enemy and (ally > 0 or enemy > 0) then lastNW = { ally, enemy } end
	return lastNW[1] - lastNW[2]
end

local function Durability(m)
	local d = 0
	if HeroRoles and HeroRoles.HeroRolesMap then
		local r = HeroRoles.HeroRolesMap[m:GetUnitName()]
		if r then d = (r.durable or 0) * 2 + (r.initiator or 0) end
	end
	return d + m:GetHealth() / 1000 + m:GetArmor() / 10
end

-- Enemy hero by estimated position (1 = carry, 2 = mid).
local function EnemyAtPosition(pos)
	if EnemyRoles then EnemyRoles.UpdateEnemyHeroPositions() end
	for _, h in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(h) and not h:IsIllusion() and not J.IsSuspiciousIllusion(h) then
			local p = EnemyRoles and EnemyRoles.GetEnemyPosition(h:GetPlayerID())
			if p == pos then return h end
		end
	end
	return nil
end

local function GroupCenter(group)
	local x, y, n = 0, 0, 0
	for _, m in ipairs(group) do
		if m:IsAlive() then
			local l = m:GetLocation()
			x, y, n = x + l.x, y + l.y, n + 1
		end
	end
	if n == 0 then return nil end
	return Vector(x / n, y / n, 0)
end

local function GroupMargin(group, target)
	local dmg = 0
	for _, m in ipairs(group) do
		if m:IsAlive() and J.GetHP(m) > 0.3 and GetUnitToUnitDistance(m, target) < 2500 then
			dmg = dmg + m:GetEstimatedDamageToTarget(true, target, 5.0, DAMAGE_TYPE_ALL)
		end
	end
	local need = HUNT_MARGIN
	if HeroRoles and HeroRoles.HasEscape and HeroRoles.HasEscape(target:GetUnitName()) then need = HUNT_MARGIN_ESCAPE end
	local enemies = RealEnemiesNear(target:GetLocation(), 1400)
	need = need * (1 + 0.4 * math.max(0, #enemies - 1))
	return dmg / math.max(1, target:GetHealth() * need)
end

local function EnemyTowerAlive(lane, tiers)
	for _, t in ipairs(tiers) do
		if GetTower(GetOpposingTeam(), t[lane]) ~= nil then return true end
	end
	return false
end

--------------------------------------------------------------------------------
-- Phase update
--------------------------------------------------------------------------------

local function IsDisabler(m)
	return HeroRoles and HeroRoles.IsDisabler and HeroRoles.IsDisabler(m:GetUnitName()) and J.GetMP(m) > 0.25
end

-- Pos 3-5 hunt; the group needs a disable (stun, hex, root...). Without one
-- the mid joins if it has one; otherwise there's no hunt.
local function HuntGroup()
	local g, disablers = {}, 0
	for _, pos in ipairs({ 3, 4, 5 }) do
		local m = MemberAt(pos)
		if IsAliveBot(m) and J.GetHP(m) > 0.4 then
			table.insert(g, m)
			if IsDisabler(m) then disablers = disablers + 1 end
		end
	end
	if disablers == 0 then
		local mid = MemberAt(2)
		if IsAliveBot(mid) and J.GetHP(mid) > 0.5 and IsDisabler(mid) then
			table.insert(g, mid)
			disablers = 1
		end
	end
	return g, disablers
end

local function SetPhase(S, phase, why)
	if S.phase ~= phase then
		Log('phase '..(S.phase or '-')..' -> '..phase..(why and (' ('..why..')') or ''))
		S.phase, S.phaseT = phase, DotaTime()
	end
end

local function PickHuntTarget(group)
	-- The enemy carry first; the mid when the group has the damage for it.
	local carry = EnemyAtPosition(1)
	if carry and GroupMargin(group, carry) >= 0.8 then return carry end
	local mid = EnemyAtPosition(2)
	if mid and GroupMargin(group, mid) >= 1.0 then return mid end
	if carry then return carry end
	-- Anyone visible that the group can kill.
	local best, bestM = nil, 1.0
	for _, h in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(h) and not h:IsIllusion() and not J.IsSuspiciousIllusion(h) then
			local m = GroupMargin(group, h)
			if m > bestM then best, bestM = h, m end
		end
	end
	return best
end

local function ClosestEnemyT2Lane(loc)
	local best, bestD = nil, math.huge
	for _, lane in ipairs(LANES) do
		local tower = GetTower(GetOpposingTeam(), T2[lane]) or GetTower(GetOpposingTeam(), T3[lane])
		if tower then
			local d = Dist(tower:GetLocation(), loc)
			if d < bestD then best, bestD = lane, d end
		end
	end
	return best
end

function X.Update()
	local team = GetTeam()
	local S = TeamPlanState[team]
	if S == nil then
		S = { phase = 'laning', phaseT = 0, nextUpdate = -math.huge, enemyAliveLast = 5 }
		TeamPlanState[team] = S
	end
	local t = DotaTime()
	if t < S.nextUpdate then return S end
	S.nextUpdate = t + UPDATE_GAP

	local enemyAlive = AliveCount(GetOpposingTeam())
	local allyAlive = AliveCount(team)
	local t1Down = 0
	for _, lane in ipairs(LANES) do
		if GetTower(GetOpposingTeam(), T1[lane]) == nil then t1Down = t1Down + 1 end
	end
	S.t1Down = t1Down

	-- Enemy deaths in the last 30 s (for "good defense" / comeback).
	if enemyAlive < S.enemyAliveLast then
		S.lastEnemyDeathT = t
		S.recentEnemyDeaths = (S.recentEnemyDeathsT and t - S.recentEnemyDeathsT < 30) and (S.recentEnemyDeaths or 0) + (S.enemyAliveLast - enemyAlive) or (S.enemyAliveLast - enemyAlive)
		S.recentEnemyDeathsT = t
	end
	S.enemyAliveLast = enemyAlive

	-- Push while we have the advantage (more heroes alive, or as many with a
	-- clear lead), whatever our own count is; regroup once it's gone.
	-- Hysteresis: starting needs healthier heroes than going on.
	local advantage, why = X.HasPushAdvantage(enemyAlive, allyAlive, S.phase == 'finish' and 0.3 or 0.45)
	if S.phase == 'finish' then
		if not advantage then
			SetPhase(S, 'regroup', 'advantage lost: '..allyAlive..' vs '..enemyAlive)
		end
		return S
	end
	if advantage and t > 10 * 60 then
		SetPhase(S, 'finish', why)
		return S
	end
	if S.phase == 'regroup' then
		if t - S.phaseT < REGROUP_TIME then return S end
		S.phase = nil
	end

	-- Behind: defend, pick off, and come back when it works.
	local nwDiff = NetworthDiff()
	local lvlDiff = J.GetAverageLevel(false) - J.GetAverageLevel(true)
	local behind = nwDiff < -BEHIND_NETWORTH or lvlDiff < -BEHIND_LEVELS
	if behind and t > 15 * 60 then
		local goodDefense = S.recentEnemyDeaths and S.recentEnemyDeaths >= 2 and t - (S.recentEnemyDeathsT or -100) < 30 and enemyAlive <= 3
		if not goodDefense then
			SetPhase(S, 'defend', 'behind by '..math.floor(-nwDiff)..' networth')
			return S
		end
		-- After a good defense the team goes hunting (comeback).
	end

	if t1Down == 0 then
		SetPhase(S, 'laning')
		return S
	end
	if t1Down < 3 and not behind then
		SetPhase(S, 'spread', t1Down..' enemy T1 down')
		-- The hunt is close: a support gets a smoke ready.
		if t1Down >= 2 then X.BuySmoke(S, (HuntGroup())) end
		return S
	end

	-- Hunt / siege.
	local group, disablers = HuntGroup()
	S.group = group
	if #group < 2 or (disablers == 0 and S.phase ~= 'siege') then
		SetPhase(S, 'spread', disablers == 0 and 'no disables for a hunt' or 'hunting group not ready')
		return S
	end
	X.BuySmoke(S, group)
	local center = GroupCenter(group)
	local cores = 0
	local gathered = {}
	for _, m in ipairs(Members()) do
		if m:IsAlive() and center and GetUnitToLocationDistance(m, center) < 2500 then
			table.insert(gathered, m)
			if J.GetPosition(m) <= 2 then cores = cores + 1 end -- pos 1/2 joining the offlaner
		end
	end

	if S.phase == 'siege' then
		local avgHP = 0
		for _, m in ipairs(gathered) do avgHP = avgHP + J.GetHP(m) end
		avgHP = #gathered > 0 and avgHP / #gathered or 0
		local towerGone = S.siegeLane and not EnemyTowerAlive(S.siegeLane, { T2, T3 })
		local failing = #gathered < math.min(SIEGE_MIN_GROUP - 1, math.max(2, enemyAlive)) or avgHP < 0.4 or allyAlive < enemyAlive
		-- A failure has to last 5 s (heroes stepping in and out of 2500 of the
		-- group flipped hunt/siege 7 times in 3 minutes); then 30 s without a
		-- new siege.
		if failing then S.siegeFailT = S.siegeFailT or t else S.siegeFailT = nil end
		if failing and t - S.siegeFailT >= 5 then
			SetPhase(S, 'hunt', 'siege failed')
			S.hunt, S.siegeFailT = nil, nil
			S.noSiegeUntil = t + 30
		elseif towerGone or t - S.phaseT > 90 then
			S.siegeLane = ClosestEnemyT2Lane(center)
			S.phaseT = t
			if S.siegeLane then Log('siege goes on: lane '..S.siegeLane) else SetPhase(S, 'hunt', 'nothing left to siege') end
		end
		return S
	end

	if #gathered >= math.max(3, math.min(SIEGE_MIN_GROUP, enemyAlive)) and cores >= 1 and allyAlive >= enemyAlive
	and t >= (S.noSiegeUntil or -math.huge) then
		S.siegeLane = ClosestEnemyT2Lane(center)
		if S.siegeLane then
			SetPhase(S, 'siege', 'a core joined, pushing lane '..S.siegeLane)
			return S
		end
	end

	SetPhase(S, 'hunt', 'all enemy T1 down')
	local h = S.hunt
	if h == nil or t > h.untilT or h.target == nil or h.target:IsNull() or not h.target:IsAlive() or t - h.lastSeen > 8 then
		local target = PickHuntTarget(group)
		if target then
			S.hunt = { target = target, startT = t, untilT = t + HUNT_TIMEOUT, lastSeen = t,
			           state = 'gather', warded = false }
			Log('hunting '..target:GetUnitName())
		else
			S.hunt = nil
		end
	elseif h.target:CanBeSeen() then
		h.lastSeen = t
		h.lastLoc = h.target:GetLocation()
	end
	return S
end

--------------------------------------------------------------------------------
-- Push desire adjustment (mode_push_tower_*_generic)
--------------------------------------------------------------------------------

-- Supports after the laning stage: a fight our heroes are in (an ally
-- trading with enemies within 4500 of us) worth running to. Returns the ally.
function X.SupportFightToJoin(bot)
	if J.GetPosition(bot) < 4 or J.IsInLaningPhase() or J.GetHP(bot) < 0.4 then return nil end
	local best, bestD
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if m and m ~= bot and m:IsAlive() and GetUnitToUnitDistance(bot, m) < 4500 then
			local enemies = RealEnemiesNear(m:GetLocation(), 1200)
			local fighting = #enemies > 0 and (m:WasRecentlyDamagedByAnyHero(2.0) or J.IsGoingOnSomeone(m))
			-- Not into a fight the ally itself is leaving (lost by the numbers).
			if m._combat and m._combat.retreat then fighting = false end
			if fighting and (not bestD or GetUnitToUnitDistance(bot, m) < bestD) then
				best, bestD = m, GetUnitToUnitDistance(bot, m)
			end
		end
	end
	return best
end

-- Supports after the laning stage push the closest wave that's safe to push
-- (no enemy seen near it, not past the enemy tier-1 alone) instead of
-- farming the jungle.
function X.SupportPushLane(bot)
	if J.GetPosition(bot) < 4 or J.IsInLaningPhase() then return nil end
	local best, bestD
	for _, lane in ipairs(LANES) do
		local front = GetLaneFrontLocation(GetTeam(), lane, 0)
		local safe = #RealEnemiesNear(front, 1800) == 0
		local t1 = GetTower(GetOpposingTeam(), T1[lane])
		local tooDeep = t1 == nil and #J.GetAlliesNearLoc(front, 1600) < 2
		local d = GetUnitToLocationDistance(bot, front)
		if safe and not tooDeep and (not bestD or d < bestD) then best, bestD = lane, d end
	end
	return best
end

function X.AdjustPushDesire(bot, lane, desire)
	local S = X.Update()
	local p = S.phase
	-- A free support pushes its chosen wave (wards, fights and the team plan
	-- below still take precedence through their own higher desires).
	if (p == 'spread' or p == 'laning' or p == 'hunt') and not X.InGroup(bot) and X.SupportPushLane(bot) == lane then
		desire = math.max(desire, 0.5)
	end
	if p == 'finish' then
		-- Everyone to the lane with the most progress toward the ancient
		-- (a hero that is nearly dead heals first).
		if J.GetHP(bot) < 0.3 then return desire end
		local best = X.FinishLane()
		if lane == best then return math.max(desire, 0.95) end
		return math.min(desire, 0.2)
	elseif p == 'regroup' then
		return 0
	elseif p == 'spread' then
		-- Don't go past a fallen T1 into the T2 alone.
		if GetTower(GetOpposingTeam(), T1[lane]) == nil then
			local allies = J.GetAlliesNearLoc(bot:GetLocation(), 1600)
			local cores = 0
			for _, a in pairs(allies) do if J.GetPosition(a) <= 3 then cores = cores + 1 end end
			local enemyAlive = AliveCount(GetOpposingTeam())
			local enough = (#allies >= 4 and cores >= 2) or (#allies >= 2 and cores >= 1 and #allies > enemyAlive)
			if not enough then return math.min(desire, 0.3) end
		end
	elseif p == 'siege' then
		if lane == S.siegeLane and X.InGroup(bot) then return math.max(desire, 0.85) end
	elseif p == 'hunt' then
		if X.InGroup(bot) then return math.min(desire, 0.3) end
	end
	return desire
end

-- Do we have the edge to push now? Numbers first, then the resources to use
-- them: the alive heroes' health and the networth/level lead.
function X.HasPushAdvantage(enemyAlive, allyAlive, hpNeed)
	if allyAlive == 0 then return false end
	local hp, n = 0, 0
	for _, m in ipairs(Members()) do
		if m:IsAlive() then hp, n = hp + J.GetHP(m), n + 1 end
	end
	local avgHP = n > 0 and hp / n or 0
	if avgHP < (hpNeed or 0.45) then return false end
	local nwDiff = NetworthDiff()
	local lvlDiff = J.GetAverageLevel(false) - J.GetAverageLevel(true)
	if enemyAlive == 0 then return true, 'no enemies alive' end
	-- Heroes alive weighted by the teams' networth: 5 v 4 while 13k behind
	-- isn't an advantage (Dire pushed "5 vs 4" into a far stronger Terrorblade).
	local ourNW, theirNW = J.GetInventoryNetworth()
	local nwFactor = math.max(0.3, math.min(3, (ourNW or 1) / math.max(1, theirNW or 1)))
	local strength = (allyAlive / math.max(1, enemyAlive)) * nwFactor
	if allyAlive - enemyAlive >= 2 and strength >= 1.2 then return true, allyAlive..' vs '..enemyAlive..' alive' end
	if allyAlive > enemyAlive and strength >= 1.3 and (nwDiff > -3000 or lvlDiff >= 0) then
		return true, allyAlive..' vs '..enemyAlive..' alive'
	end
	if allyAlive == enemyAlive and allyAlive <= 4 and (nwDiff > 12000 or lvlDiff >= 3) then
		return true, 'big lead ('..math.floor(nwDiff)..' networth), '..allyAlive..' vs '..enemyAlive
	end
	return false
end

function X.FinishLane()
	local best, bestScore = LANE_MID, -1
	for _, lane in ipairs(LANES) do
		local score = 0
		for tier, tbl in ipairs({ T1, T2, T3 }) do
			if GetTower(GetOpposingTeam(), tbl[lane]) == nil then score = score + tier end
		end
		if score > bestScore then best, bestScore = lane, score end
	end
	return best
end

function X.InGroup(bot)
	local S = TeamPlanState[GetTeam()]
	if not S or not S.group then return false end
	for _, m in ipairs(S.group) do if m == bot then return true end end
	-- Cores that joined the group count as well during a siege.
	if S.phase == 'siege' then
		local center = GroupCenter(S.group)
		return center ~= nil and GetUnitToLocationDistance(bot, center) < 2500
	end
	return false
end

--------------------------------------------------------------------------------
-- Roam hooks (mode_roam_generic): hunting, regrouping, pick-offs in defense
--------------------------------------------------------------------------------

local function Tank(group)
	local best, bestD = nil, -1
	for _, m in ipairs(group) do
		if m:IsAlive() then
			local d = Durability(m)
			if d > bestD then best, bestD = m, d end
		end
	end
	return best
end

local function SafePoint(bot)
	-- Our closest standing tower, else the fountain.
	local best, bestD = nil, math.huge
	for _, lane in ipairs(LANES) do
		for _, tbl in ipairs({ T1, T2, T3 }) do
			local tower = GetTower(GetTeam(), tbl[lane])
			if tower then
				local d = GetUnitToUnitDistance(bot, tower)
				if d < bestD then best, bestD = tower:GetLocation(), d end
			end
		end
	end
	return best or J.GetTeamFountain()
end

function X.RoamDesire(bot)
	if not bot:IsBot() then return nil end
	local S = X.Update()
	local p = S.phase

	if p == 'regroup' then
		if GetUnitToLocationDistance(bot, J.GetEnemyFountain()) < 7000 then
			bot._teamAction = 'regroup'
			return BOT_MODE_DESIRE_VERYHIGH
		end
		return nil
	end

	if p == 'defend' then
		-- Pick off enemies that step into us near our base.
		if GetUnitToUnitDistance(bot, GetAncient(GetTeam())) < 6000 and J.GetHP(bot) > 0.4 then
			local enemies = RealEnemiesNear(bot:GetLocation(), 1100)
			local allies = J.GetAlliesNearLoc(bot:GetLocation(), 1400)
			for _, e in ipairs(enemies) do
				if J.CanBeAttacked(e) and #enemies <= #allies and GroupMargin(allies, e) >= 1.0 and Objectives.FightValue(bot, e) > 0 then
					bot._teamAction = 'pickoff'
					bot._teamTarget = e
					return BOT_MODE_DESIRE_VERYHIGH
				end
			end
		end
		return nil
	end

	-- The combat evaluation says we kill first (FunLib/objectives.lua
	-- X.Combat, updated by the retreat mode's fight hint): commit.
	local c = bot._combat
	if c and c.go and J.IsValidHero(c.target) and DotaTime() - (bot._fightHintT or -99) < 1.5
	and (not J.IsInLaningPhase() or c.ttkUs <= 3) then
		bot._teamAction = 'pickoff'
		bot._teamTarget = c.target
		return 0.85
	end

	if p == 'hunt' and S.hunt and X.InGroup(bot) then
		bot._teamAction = 'hunt'
		return BOT_MODE_DESIRE_VERYHIGH
	end

	-- Supports go where the team fights.
	local fightAlly = X.SupportFightToJoin(bot)
	if fightAlly then
		bot._teamAction = 'join_fight'
		bot._teamTarget = fightAlly
		return 0.8
	end

	-- Supports ward the jungle where our carry farms.
	if X.CarryWardSpot(bot, S) then
		bot._teamAction = 'ward_carry'
		return 0.72
	end
	bot._teamAction = nil
	return nil
end

local function UseItem(bot, name, loc)
	local slot = bot:FindItemSlot(name)
	if slot < 0 or slot > 8 then return false end
	if slot >= 6 then
		-- In the backpack (wards wait there): swap into the cheapest main slot.
		local target, cheapest = nil, math.huge
		for i = 0, 5 do
			local it = bot:GetItemInSlot(i)
			if it == nil then target = i break end
			local cost = GetItemCost(it:GetName())
			if cost < cheapest then target, cheapest = i, cost end
		end
		if target then bot:ActionImmediate_SwapItems(slot, target) end
		bot._wardWantedUntil = DotaTime() + 10 -- item_purchase: don't move it back
		return false -- cast once it's in the main bar
	end
	local item = bot:GetItemInSlot(slot)
	if not item or not item:IsFullyCastable() then return false end
	if loc then bot:Action_UseAbilityOnLocation(item, loc) else bot:Action_UseAbility(item) end
	return true
end

local function Attack(bot, target)
	-- Never chase into their fountain (allies died there after a won fight).
	if GetUnitToLocationDistance(target, J.GetEnemyFountain()) < 1700 then
		local back = J.GetTeamFountain() - bot:GetLocation()
		bot:Action_MoveToLocation(bot:GetLocation() + back:Normalized() * 500)
		return
	end
	bot.forceFightUntil = DotaTime() + 2 -- spells on the target
	bot:SetTarget(target)
	bot:Action_AttackUnit(target, true)
end

local function ThinkHunt(bot, S)
	local h = S.hunt
	local group = S.group
	local target = h.target
	if target == nil or target:IsNull() then S.hunt = nil return false end -- the handle went invalid
	local targetLoc = (target:CanBeSeen() and target:GetLocation()) or h.lastLoc or target:GetLocation()
	local center = GroupCenter(group) or bot:GetLocation()

	-- 1) Gather close to each other, then smoke.
	if h.state == 'gather' then
		local spread = 0
		for _, m in ipairs(group) do
			if m:IsAlive() then spread = math.max(spread, GetUnitToLocationDistance(m, center)) end
		end
		if spread < 600 or DotaTime() - h.startT > 20 then
			-- Whoever carries the smoke pops it; go without it if nobody has one.
			if UseItem(bot, 'item_smoke_of_deceit') then
				Log(bot:GetUnitName()..' smokes the group')
				h.state = 'move'
				return
			end
			local anySmoke = false
			for _, m in ipairs(group) do
				if m:IsAlive() and m:FindItemSlot('item_smoke_of_deceit') >= 0 then anySmoke = true end
			end
			if not anySmoke or DotaTime() - h.startT > 40 then h.state = 'move' end
		end
		bot:Action_MoveToLocation(center)
		return
	end

	-- 2) Ward the enemy jungle next to the target once.
	if not h.warded and J.GetPosition(bot) >= 4 and GetUnitToLocationDistance(bot, targetLoc) < 1600 then
		local toEnemy = (J.GetEnemyFountain() - targetLoc):Normalized()
		local wardLoc = targetLoc + toEnemy * 500
		if GetUnitToLocationDistance(bot, wardLoc) < 600
		and (UseItem(bot, 'item_ward_observer', wardLoc) or UseItem(bot, 'item_ward_dispenser', wardLoc)) then
			h.warded = true
			Log(bot:GetUnitName()..' wards the enemy jungle for the gank')
			return
		end
	end

	-- 3) Move together; engage once a disabler is in range (or the fight started).
	local dist = GetUnitToLocationDistance(bot, targetLoc)
	local disablerClose = false
	for _, m in ipairs(group) do
		if m:IsAlive() and IsDisabler(m) and GetUnitToLocationDistance(m, targetLoc) < 800 then disablerClose = true end
	end
	local engaged = target:CanBeSeen() and (disablerClose or target:WasRecentlyDamagedByAnyHero(1.0))

	if target:CanBeSeen() and engaged and dist < 1300 then
		local margin = GroupMargin(group, target)
		if margin >= 0.9 or engaged then
			if h.state ~= 'fight' then h.state = 'fight' Log('fight on '..target:GetUnitName()..' (margin '..string.format('%.2f', margin)..')') end
			Attack(bot, target)
			return
		end
	end

	-- Don't run far ahead of the group.
	local center2 = GroupCenter(group) or bot:GetLocation()
	if GetUnitToLocationDistance(bot, center2) > 700 and dist < Dist(center2, targetLoc) - 500 then
		bot:Action_MoveToLocation(center2)
		return
	end
	bot:Action_MoveToLocation(targetLoc)
end

-- Returns true when it issued an action.
function X.RoamThink(bot)
	local a = bot._teamAction
	if not a then return false end
	local S = X.Update()
	if a == 'regroup' then
		bot:Action_MoveToLocation(SafePoint(bot))
		return true
	elseif a == 'join_fight' then
		local ally = bot._teamTarget
		if not J.IsValidHero(ally) then return false end
		-- Close enough: hit the best enemy around the ally (spells via the
		-- fight window), otherwise run to the ally.
		if GetUnitToUnitDistance(bot, ally) < 1300 then
			local best, bestEV = nil, -5
			for _, e in ipairs(RealEnemiesNear(ally:GetLocation(), 1300)) do
				if J.CanBeAttacked(e) then
					local ev = Objectives.FightValue(bot, e)
					if ev > bestEV then best, bestEV = e, ev end
				end
			end
			if best then Attack(bot, best) return true end
		end
		bot:Action_MoveToLocation(ally:GetLocation())
		return true
	elseif a == 'pickoff' then
		local e = bot._teamTarget
		if J.IsValidHero(e) then Attack(bot, e) return true end
		return false
	elseif a == 'ward_carry' and bot._carryWardLoc then
		local loc = bot._carryWardLoc
		if GetUnitToLocationDistance(bot, loc) > 500 then
			bot:Action_MoveToLocation(loc)
		elseif UseItem(bot, 'item_ward_observer', loc) or UseItem(bot, 'item_ward_dispenser', loc) then
			Log(bot:GetUnitName()..' wards the jungle where our carry farms')
			S.carryWardT = DotaTime()
			bot._carryWardLoc = nil
		end
		return true
	elseif a == 'hunt' and S.hunt then
		ThinkHunt(bot, S)
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Smoke purchase before a gank
--------------------------------------------------------------------------------

function X.BuySmoke(S, group)
	local t = DotaTime()
	if S.smokeBuyT and t - S.smokeBuyT < 20 then return end
	for _, m in ipairs(Members()) do
		if m:IsAlive() and m:FindItemSlot('item_smoke_of_deceit') >= 0 then return end
	end
	if GetItemStockCount('item_smoke_of_deceit') < 1 then return end
	local cost = GetItemCost('item_smoke_of_deceit')
	for _, pos in ipairs({ 5, 4 }) do
		local m = MemberAt(pos)
		if IsAliveBot(m) and m:GetGold() >= cost then
			m:ActionImmediate_PurchaseItem('item_smoke_of_deceit')
			S.smokeBuyT = t
			Log(m:GetUnitName()..' buys a smoke for the gank')
			return
		end
	end
end

--------------------------------------------------------------------------------
-- Observer wards where our carry farms
--------------------------------------------------------------------------------

local function HasObserver(bot)
	for _, name in ipairs({ 'item_ward_observer', 'item_ward_dispenser' }) do
		local slot = bot:FindItemSlot(name)
		if slot >= 0 and slot <= 8 then return true end
	end
	return false
end

local function ObserverNear(loc, radius)
	for _, w in pairs(GetUnitList(UNIT_LIST_ALLIED_WARDS)) do
		if w and not w:IsNull() and string.find(w:GetUnitName(), 'observer') and Dist(w:GetLocation(), loc) < radius then
			return true
		end
	end
	return false
end

local function InSomeLane(loc)
	for _, lane in ipairs(LANES) do
		local info = GetAmountAlongLane(lane, loc)
		if info and info.distance and info.distance < 1200 then return true end
	end
	return false
end

-- Sets bot._carryWardLoc and returns true when this support should go ward.
function X.CarryWardSpot(bot, S)
	local t = DotaTime()
	local pos = J.GetPosition(bot)
	if pos < 4 or t < 8 * 60 or J.GetHP(bot) < 0.5 or not HasObserver(bot) then return false end
	if S.carryWardT and t - S.carryWardT < 60 then return false end
	if S.carryWardBy and S.carryWardBy ~= bot and t < (S.carryWardUntil or 0) then return false end

	local carry = MemberAt(1)
	if not (carry and carry:IsAlive()) then return false end
	local cLoc = carry:GetLocation()
	if carry:GetActiveMode() ~= BOT_MODE_FARM or InSomeLane(cLoc) then return false end
	if ObserverNear(cLoc, 1600) then return false end

	-- Between the carry and where the enemies come from.
	local dir = (J.GetEnemyFountain() - cLoc):Normalized()
	local spot = nil
	for _, d in ipairs({ 800, 600, 400 }) do
		local l = cLoc + dir * d
		if IsLocationPassable(l) then spot = l break end
	end
	if not spot or GetUnitToLocationDistance(bot, spot) > 6000 then return false end
	if #RealEnemiesNear(spot, 1200) > 0 then return false end

	if S.carryWardBy ~= bot then Log(bot:GetUnitName()..' goes to ward the carry\'s jungle') end
	S.carryWardBy, S.carryWardUntil = bot, t + 30
	bot._carryWardLoc = spot
	return true
end

--------------------------------------------------------------------------------
-- Push formation: the tankiest hero goes first
--------------------------------------------------------------------------------

-- Called from mode_push_tower_*_generic Think. Returns true when it issued an action.
function X.PushFormationThink(bot, lane)
	local loc = bot:GetLocation()
	if #RealEnemiesNear(loc, 1200) > 0 then return false end -- fighting: free play
	local allies = {}
	for _, m in ipairs(Members()) do
		if m:IsAlive() and GetUnitToUnitDistance(m, bot) < 1500 then table.insert(allies, m) end
	end
	if #allies < 3 then return false end
	local tank = Tank(allies)
	if not tank or tank == bot then return false end

	local building = nil
	for _, tbl in ipairs({ T1, T2, T3 }) do
		building = GetTower(GetOpposingTeam(), tbl[lane])
		if building then break end
	end
	local bLoc = building and building:GetLocation() or GetAncient(GetOpposingTeam()):GetLocation()
	local dTank = GetUnitToLocationDistance(tank, bLoc)
	local dBot = GetUnitToLocationDistance(bot, bLoc)
	-- Until the tank is at the building, stay behind it.
	if dTank > 900 and dBot < dTank + 150 then
		local dir = (bLoc - tank:GetLocation()):Normalized()
		bot:Action_MoveToLocation(tank:GetLocation() - dir * 350)
		return true
	end
	return false
end

return X
