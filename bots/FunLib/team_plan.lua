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

-- A human ally far ahead of our bots (match 9102024904: a human Kez at 19.9k
-- on 30:00, our bot cores 7.6k; the team pushed and hunted elsewhere and the
-- human played alone). The plan then moves with them: finishes and sieges
-- go to the lane nearest that human, and they count in the siege group.
function X.HumanLead()
	local human, best = nil, 0
	for _, m in ipairs(Members()) do
		if m:IsAlive() then
			local nw = m:GetNetWorth()
			if m:IsBot() then best = math.max(best, nw)
			elseif not human or nw > human:GetNetWorth() then human = m end
		end
	end
	if human and human:GetNetWorth() >= 5000 and human:GetNetWorth() >= best * 1.4 then return human end
	return nil
end

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
-- The real networth where the engine gives it (GetNetWorth of an enemy hero
-- seen; 0 if hidden): inventory networth stops at 6 slots - Radiant, 40k
-- ahead at 90:00, held "behind by 13990" for 20 min and defended at home
-- with Dire's ancient open (bot vs bot 9103201907).
local seenNW = {}
local function RealNetworthDiff()
	local ally, enemy, n = 0, 0, 0
	for i = 1, #GetTeamPlayers(GetTeam()) do
		local m = GetTeamMember(i)
		if m then ally = ally + (m:GetNetWorth() or 0) end
	end
	for _, e in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(e) and not e:IsIllusion() and not J.IsSuspiciousIllusion(e) then
			local ok, nw = pcall(function() return e:GetNetWorth() end)
			if ok and nw and nw > 0 then seenNW[e:GetPlayerID()] = nw end
		end
	end
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if type(seenNW[pid]) == 'number' then enemy, n = enemy + seenNW[pid], n + 1 end
	end
	if n < #GetTeamPlayers(GetOpposingTeam()) or ally <= 0 then return nil end
	return ally - enemy
end

local lastNW = { 0, 0 }
local function NetworthDiff()
	local real = RealNetworthDiff()
	if real then
		if not seenNW.logged then seenNW.logged = true print('[Team '..GetTeam()..'] networth: real (GetNetWorth of enemies works), diff '..math.floor(real)) end
		return real
	end
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

-- Hunt, siege and spread hold for 15 s at least (the plan flipped between
-- them every few seconds, sending the team to a new spot each time); finish,
-- defend and regroup start at once.
local PHASE_HOLD = 15
local QUICK = { finish = true, defend = true, regroup = true }
local function SetPhase(S, phase, why)
	if S.phase ~= phase and not QUICK[phase] and S.phase and not QUICK[S.phase] and S.phase ~= 'laning'
	and DotaTime() - (S.phaseT or -math.huge) < PHASE_HOLD then
		return
	end
	if S.phase ~= phase then
		Log('phase '..(S.phase or '-')..' -> '..phase..(why and (' ('..why..')') or ''))
		S.phase, S.phaseT = phase, DotaTime()
	end
end

-- Not a hunt into their base: a target within 4500 of their ancient is
-- off (Bristleback was taken onto Dire's high ground hunting their carry).
local function InTheirBase(h)
	local anc = GetAncient(GetOpposingTeam())
	return anc ~= nil and GetUnitToUnitDistance(h, anc) < 4500
end
local function Huntable(h) return h ~= nil and not InTheirBase(h) end

local function PickHuntTarget(group)
	-- The enemy carry first; the mid when the group has the damage for it.
	local carry = EnemyAtPosition(1)
	if carry and not Huntable(carry) then carry = nil end
	if carry and GroupMargin(group, carry) >= 0.8 then return carry end
	local mid = EnemyAtPosition(2)
	if mid and Huntable(mid) and GroupMargin(group, mid) >= 1.0 then return mid end
	-- (No "the carry anyway": Pudge and Abaddon at 6k hunted a 15-17k carry
	-- at 45:00, far from their cores, dead 32% of the time - bot vs bot
	-- 9103068510.)
	-- Anyone visible that the group can kill.
	local best, bestM = nil, 1.0
	for _, h in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(h) and not h:IsIllusion() and not J.IsSuspiciousIllusion(h) and Huntable(h) then
			local m = GroupMargin(group, h)
			if m > bestM then best, bestM = h, m end
		end
	end
	return best
end

local function ClosestEnemyT2Lane(loc)
	local best, bestD = nil, math.huge
	for _, lane in ipairs(LANES) do
		-- The lane's first standing tower (T1 too: hunts start at 14:00 with T1s up).
		local tower = GetTower(GetOpposingTeam(), T1[lane]) or GetTower(GetOpposingTeam(), T2[lane]) or GetTower(GetOpposingTeam(), T3[lane])
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
	-- When each enemy died, for "how long until they're back".
	S.deadAt = S.deadAt or {}
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(pid) then S.deadAt[pid] = nil elseif not S.deadAt[pid] then S.deadAt[pid] = t end
	end

	-- Push while we have the advantage (more heroes alive, or as many with a
	-- clear lead), whatever our own count is; regroup once it's gone.
	-- Hysteresis: starting needs healthier heroes than going on.
	local advantage, why = X.HasPushAdvantage(enemyAlive, allyAlive, S.phase == 'finish' and 0.3 or 0.45)
	if S.phase == 'finish' then
		-- A finish holds while the dead are dead (match 9102358727: 56
		-- finishes, most over in 1-20 s - "advantage lost" when one enemy
		-- stepped out of the fog - and 8 towers fell in 80 minutes). It
		-- ends early only when we are outnumbered or badly hurt.
		-- (100:08 of that match: 5 vs 3, then 5 vs 2, "advantage lost" in
		-- 4 and 18 s - hurt after the fight - and the viper pushed alone.)
		-- Enemies killed during the finish extend it to the first of the dead
		-- to come back (Radiant killed Weaver and Dazzle under Dire's mid T2
		-- at 50:20, the 25 s from the start ran out, "advantage lost: 5 vs 4",
		-- push 0, and the nearly dead T2 stood; bot vs bot 9103068510).
		do
			local back, lvl = math.huge, J.GetAverageLevel(true) or 10
			for _, dt in pairs(S.deadAt) do back = math.min(back, dt + 6 + 2.2 * lvl) end
			if back < math.huge and back > (S.finishUntil or -math.huge) then S.finishUntil = back end
		end
		-- At their base: held while the heroes there win there (the whole-team
		-- check counted their fog heroes; Radiant at 36-37k left Dire's base
		-- at 4 vs 4 after the first T4, bot vs bot 9103068510, 67:56).
		-- Same at the building being finished, whatever the time: Dire
		-- started 14 finishes at x1.4-3.0 between 23:00 and 45:00 and took no
		-- building - each ended 25-45 s later, before the T2 fell.
		local target = S.finishLane and (GetTower(GetOpposingTeam(), T1[S.finishLane]) or GetTower(GetOpposingTeam(), T2[S.finishLane])
			or GetTower(GetOpposingTeam(), T3[S.finishLane]))
		local eAnc = GetAncient(GetOpposingTeam())
		target = target or eAnc
		local atBase = false
		if target and Objectives.FightAt then
			local radius = (target == eAnc) and 4000 or 2500
			local near = {}
			for _, m in ipairs(Members()) do
				if m:IsAlive() and GetUnitToUnitDistance(m, target) < radius then table.insert(near, m) end
			end
			if #near >= 2 or (#near >= 1 and target ~= eAnc and J.GetHP(near[1]) > 0.5) then
				local ok, r = pcall(Objectives.FightAt, target:GetLocation(), near, false, true)
				atBase = ok and r ~= nil and r >= 1.0 and X.TeamHP() >= 0.3
			end
		end
		local holding = atBase or t < (S.finishUntil or -math.huge) and allyAlive >= enemyAlive
			and (X.TeamHP() >= 0.2 or allyAlive - enemyAlive >= 2)
		if not advantage and not holding then
			SetPhase(S, 'regroup', 'advantage lost: '..allyAlive..' vs '..enemyAlive)
		end
		return S
	end
	-- A kill opens a push only with time to use it: the dead enemy has 20+ s
	-- left (respawn ~6 + 2.2 x level). Radiant flipped finish/regroup every
	-- 30-40 s, walked to the top lane and back and never took the T1.
	local timeLeft = 0
	if enemyAlive < allyAlive then
		local lvl = J.GetAverageLevel(true) or 10
		for _, dt in pairs(S.deadAt) do timeLeft = math.max(timeLeft, dt + 6 + 2.2 * lvl - t) end
	end
	-- Not out of a regroup before it's over: Dire flipped finish/regroup
	-- three times in 11 s.
	local regrouping = S.phase == 'regroup' and t - S.phaseT < REGROUP_TIME
	-- Behind by 5k+: a finish only with enemies dead for 20 s more (Dire,
	-- 10-40k behind, went from the defense to a "finish" 20 times and lost
	-- all 39 of theirs, bot vs bot 9103163695).
	local behind = NetworthDiff() < -5000
	if advantage and not regrouping and t > 10 * 60 and ((enemyAlive >= allyAlive and not behind) or timeLeft >= 20) then
		if S.phase ~= 'finish' then
			S.finishLane = X.FinishLane(true)
			-- Until the first dead enemy is back (at least 25 s).
			local back = math.huge
			local lvl = J.GetAverageLevel(true) or 10
			for _, dt in pairs(S.deadAt) do back = math.min(back, dt + 6 + 2.2 * lvl) end
			S.finishUntil = back < math.huge and math.max(t + 25, back) or t + 25
		end
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
	-- Their ancient open (both T4 down): no "defend" - the finish decides by
	-- the fight there (Radiant defended for 19 min after Dire's last T4).
	local ancientOpen = GetTower(GetOpposingTeam(), TOWER_BASE_1) == nil and GetTower(GetOpposingTeam(), TOWER_BASE_2) == nil
	if behind and t > 15 * 60 and not ancientOpen then
		local goodDefense = S.recentEnemyDeaths and S.recentEnemyDeaths >= 2 and t - (S.recentEnemyDeathsT or -100) < 30 and enemyAlive <= 3
		if not goodDefense then
			SetPhase(S, 'defend', 'behind by '..math.floor(-nwDiff)..' networth')
			return S
		end
		-- After a good defense the team goes hunting (comeback).
	end

	if t1Down == 0 and t < 14 * 60 then
		SetPhase(S, 'laning')
		return S
	end
	-- Before 14:00 the hunt waits for all three T1. After that the support
	-- group smokes and ganks even with T1s standing (OpenDota 9098557365:
	-- the winning side's smokes at 10:57 and 21:14 each took a kill and a
	-- tower within the minute).
	if t1Down < 3 and not behind and t < 14 * 60 then
		SetPhase(S, 'spread', t1Down..' enemy T1 down')
		-- The hunt is close: a support gets a smoke ready.
		if t1Down >= 2 then X.BuySmoke(S, (HuntGroup())) end
		return S
	end

	-- Hunt / siege.
	local group, disablers = HuntGroup()
	S.group = group
	-- No hunting group: no hunt, but a siege still can be - one hero who wins
	-- at the tower is enough (the user: "a siege can be done by one hero").
	-- It is planned around the human far ahead, else our strongest hero.
	local noHunt = #group < 2 or (disablers == 0 and S.phase ~= 'siege')
	local center
	if noHunt then
		local best = X.HumanLead()
		if not best then
			for _, m in ipairs(Members()) do
				if m:IsAlive() and (not best or m:GetNetWorth() > best:GetNetWorth()) then best = m end
			end
		end
		center = best and best:GetLocation()
		if not center then
			SetPhase(S, 'spread', 'nobody to siege with')
			return S
		end
	else
		X.BuySmoke(S, group)
		center = GroupCenter(group)
	end
	local lead = X.HumanLead()
	if lead and center and GetUnitToLocationDistance(lead, center) > 2500 then
		-- The group comes to the human instead of sieging without them.
		center = lead:GetLocation()
	end
	S.siegeCenter = center
	local cores = 0
	local gathered = {}
	for _, m in ipairs(Members()) do
		if m:IsAlive() and center and GetUnitToLocationDistance(m, center) < 2500 then
			table.insert(gathered, m)
			if J.GetPosition(m) <= 2 then cores = cores + 1 end -- pos 1/2 joining the offlaner
		end
	end

	-- Team siege: clearly ahead after 18:00, the whole team (cores out of
	-- the jungle too) takes the nearest tower, then the next one. Match
	-- 9102507636: Dire 12k ahead at 45:00 hunted and farmed ancients, the
	-- sieges waited for a group already at a tower, and 5 towers fell in
	-- 45 minutes.
	local alive = {}
	for _, m in ipairs(Members()) do if m:IsAlive() then table.insert(alive, m) end end
	local aliveCenter = GroupCenter(alive)
	if S.phase == 'siege' and S.siegeAll then
		local stw = S.siegeLane and (GetTower(GetOpposingTeam(), T1[S.siegeLane]) or GetTower(GetOpposingTeam(), T2[S.siegeLane]) or GetTower(GetOpposingTeam(), T3[S.siegeLane]))
		local r = stw and Objectives.FightAt and Objectives.FightAt(stw:GetLocation(), alive, false, true) or 0
		local failing = allyAlive < enemyAlive or X.TeamHP() < 0.35 or r < 0.9
		if failing then S.siegeFailT = S.siegeFailT or t else S.siegeFailT = nil end
		if failing and t - S.siegeFailT >= 5 then
			SetPhase(S, 'hunt', 'team siege failed')
			S.siegeAll, S.siegeFailT, S.noSiegeUntil = nil, nil, t + 60
		elseif not stw or t - S.phaseT > 120 then
			S.siegeLane = aliveCenter and ClosestEnemyT2Lane(aliveCenter)
			S.phaseT = t
			if S.siegeLane then Log('team siege goes on: lane '..S.siegeLane) else S.siegeAll = nil SetPhase(S, 'hunt', 'nothing left to siege') end
		end
		return S
	end
	if S.phase ~= 'siege' and t >= 18 * 60 and t >= (S.noSiegeUntil or -math.huge) and allyAlive >= enemyAlive and aliveCenter then
		local teamR = Objectives.FightAt and Objectives.FightAt(aliveCenter, alive, true, false) or 0
		if nwDiff >= 6000 or teamR >= 1.3 then
			local lane = ClosestEnemyT2Lane(aliveCenter)
			local tw = lane and (GetTower(GetOpposingTeam(), T1[lane]) or GetTower(GetOpposingTeam(), T2[lane]) or GetTower(GetOpposingTeam(), T3[lane]))
			local r = tw and Objectives.FightAt and Objectives.FightAt(tw:GetLocation(), alive, false, true) or 0
			if r >= 1.15 then
				S.siegeLane, S.siegeAll, S.siegeCenter = lane, true, aliveCenter
				SetPhase(S, 'siege', string.format('team ahead (%d networth, x%.2f), all to lane %d', nwDiff, teamR, lane))
				return S
			end
			S.noSiegeUntil = t + 20
		end
	end

	if S.phase == 'siege' then
		local avgHP = 0
		for _, m in ipairs(gathered) do avgHP = avgHP + J.GetHP(m) end
		avgHP = #gathered > 0 and avgHP / #gathered or 0
		local towerGone = S.siegeLane and not EnemyTowerAlive(S.siegeLane, { T1, T2, T3 })
		-- By strength at the tower, not heads (two strong heroes are a siege,
		-- four weak ones may not be).
		local stw = S.siegeLane and (GetTower(GetOpposingTeam(), T1[S.siegeLane]) or GetTower(GetOpposingTeam(), T2[S.siegeLane]) or GetTower(GetOpposingTeam(), T3[S.siegeLane]))
		local failing
		if stw and Objectives.FightAt then
			failing = #gathered < 1 or avgHP < 0.4 or Objectives.FightAt(stw:GetLocation(), gathered, false, true) < 0.9
		else
			failing = #gathered < math.min(SIEGE_MIN_GROUP - 1, math.max(2, enemyAlive)) or avgHP < 0.4 or allyAlive < enemyAlive
		end
		-- A failure has to last 5 s (heroes stepping in and out of 2500 of the
		-- group flipped hunt/siege 7 times in 3 minutes); then 60 s without a
		-- new siege.
		if failing then S.siegeFailT = S.siegeFailT or t else S.siegeFailT = nil end
		if failing and t - S.siegeFailT >= 5 then
			SetPhase(S, 'hunt', 'siege failed')
			S.hunt, S.siegeFailT = nil, nil
			S.noSiegeUntil = t + 60
		elseif towerGone or t - S.phaseT > 90 then
			S.siegeLane = ClosestEnemyT2Lane(center)
			S.phaseT = t
			if S.siegeLane then Log('siege goes on: lane '..S.siegeLane) else SetPhase(S, 'hunt', 'nothing left to siege') end
		end
		return S
	end

	-- Strength decides (the 1.3 at the tower below, and the whole team vs
	-- theirs); two heroes are the least that make a siege.
	local alive = {}
	for _, m in ipairs(Members()) do if m:IsAlive() then table.insert(alive, m) end end
	local teamOK = Objectives.FightAt and Objectives.FightAt(center, alive, true, false) >= 0.9 or allyAlive >= enemyAlive
	if #gathered >= 1 and teamOK
	and t >= (S.noSiegeUntil or -math.huge) then
		S.siegeLane = ClosestEnemyT2Lane(center)
		-- Only a siege the group wins at that tower (their heroes elsewhere
		-- counted half: they teleport in). Match 9101853178: both teams
		-- "sieged" the top lane at each other 9 times in 8 minutes, every
		-- one failed within a minute, 4 towers fell in 36 minutes and both
		-- carries ended under 12k.
		local tower = S.siegeLane and (GetTower(GetOpposingTeam(), T1[S.siegeLane]) or GetTower(GetOpposingTeam(), T2[S.siegeLane]) or GetTower(GetOpposingTeam(), T3[S.siegeLane]))
		local ratio = tower and Objectives.FightAt and Objectives.FightAt(tower:GetLocation(), gathered, false, true) or 99
		if ratio < 1.15 then
			S.siegeLane = nil
			S.noSiegeUntil = t + 20
		end
		if S.siegeLane then
			S.siegeAll = nil
			SetPhase(S, 'siege', 'a core joined, pushing lane '..S.siegeLane)
			return S
		end
	end

	if noHunt then
		SetPhase(S, 'spread', disablers == 0 and 'no disables for a hunt' or 'hunting group not ready')
		return S
	end
	SetPhase(S, 'hunt', t1Down == 3 and 'all enemy T1 down' or 'hunts from 14:00')
	local h = S.hunt
	if h == nil or t > h.untilT or h.target == nil or h.target:IsNull() or not h.target:IsAlive() or t - h.lastSeen > 8
	or (h.target:CanBeSeen() and InTheirBase(h.target)) then
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
function X.SupportFightToJoin(bot, anyRole)
	if (J.GetPosition(bot) < 4 and not anyRole) or J.IsInLaningPhase() or J.GetHP(bot) < 0.4 then return nil end
	local best, bestD
	for i = 1, 5 do
		local m = GetTeamMember(i)
		-- 6500 (it was 4500): the supports stood at our top T2 while OD and
		-- the human fought at mid (9102507636, 31:25-31:51, four enemies died).
		if m and m ~= bot and m:IsAlive() and GetUnitToUnitDistance(bot, m) < 6500 then
			local enemies = RealEnemiesNear(m:GetLocation(), 1200)
			local okT, tgt = pcall(function() return m:GetAttackTarget() end)
			if not okT then tgt = nil end
			local hitsHero = tgt ~= nil and not tgt:IsNull() and tgt:IsHero() and tgt:GetTeam() ~= GetTeam()
			local fighting = #enemies > 0 and (m:WasRecentlyDamagedByAnyHero(2.0) or J.IsGoingOnSomeone(m) or hitsHero)
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
		-- Not a wave alone where the unseen enemies may be (Lion died 9 times).
		if safe and not tooDeep and Objectives.PickoffRisk and Objectives.PickoffRisk(bot, front) then safe = false end
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
		-- (a hero that is nearly dead heals first); a hero more than 5000
		-- from that lane's front keeps doing what it does (farming).
		if J.GetHP(bot) < 0.3 then return desire end
		local best = S.finishLane or X.FinishLane()
		local far = GetUnitToLocationDistance(bot, GetLaneFrontLocation(GetTeam(), best, 0))
		-- Far away: joins if it can teleport there with time to use it
		-- (the push mode's Think teleports, Objectives.FinishTravel).
		if far > 5000 and not (X.CanTP(bot) and (S.finishUntil or 0) - DotaTime() > 15) then return desire end
		-- The carry still farming its items joins only when it's right there.
		if Objectives and Objectives.CarryFarming and Objectives.CarryFarming(bot) and far > 2500 then return desire end
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
		if lane == S.siegeLane and X.InGroup(bot) then return math.max(desire, S.siegeAll and 0.9 or 0.85) end
		-- Team siege: the other lanes wait.
		if S.siegeAll and X.InGroup(bot) and J.GetHP(bot) >= 0.3 then return math.min(desire, 0.2) end
	elseif p == 'hunt' then
		if X.InGroup(bot) then return math.min(desire, 0.3) end
	end
	return desire
end

-- Do we have the edge to push now? Numbers first, then the resources to use
-- them: the alive heroes' health and the networth/level lead.
function X.CanTP(bot)
	local slot = bot:FindItemSlot('item_tpscroll')
	local item = slot >= 0 and bot:GetItemInSlot(slot) or nil
	if item and item:IsFullyCastable() then return true end
	for _, n in ipairs({ 'item_travel_boots', 'item_travel_boots_2' }) do
		local s2 = bot:FindItemSlot(n)
		local it = s2 >= 0 and bot:GetItemInSlot(s2) or nil
		if it and it:IsFullyCastable() then return true end
	end
	return false
end

function X.TeamHP()
	local hp, n = 0, 0
	for _, m in ipairs(Members()) do
		if m:IsAlive() then hp, n = hp + J.GetHP(m), n + 1 end
	end
	return n > 0 and hp / n or 0
end

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
	-- Strength of the whole team alive vs theirs (FightAt: damage x HP, fog
	-- included), not heroes alive: a 29k human and two bots can be ahead of
	-- four weak enemies.
	if Objectives.FightAt then
		local alive, sum = {}, Vector(0, 0, 0)
		for _, m in ipairs(Members()) do
			if m:IsAlive() then table.insert(alive, m) sum = sum + m:GetLocation() end
		end
		if #alive > 0 then
			local r = Objectives.FightAt(sum / #alive, alive, true, false)
			-- Going on needs less than starting (hpNeed 0.3 = a finish already on).
			if r >= ((hpNeed or 0.45) < 0.4 and 1.1 or 1.3) then return true, string.format('stronger x%.2f, %d vs %d alive', r, allyAlive, enemyAlive) end
			return false
		end
	end
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

-- The lane to push after a won fight. `near`: the one whose next enemy
-- tower is closest to where our heroes are (the fight), so the push starts
-- before the dead respawn (the winning side in 9098557365 took the mid T1
-- 4 s after a fight there, the bot T1 10 s after the next one). Otherwise,
-- and as a tie-break, the lane with the most progress toward the ancient.
function X.FinishLane(near)
	local center
	if near then
		local sum, n = Vector(0, 0, 0), 0
		for _, m in ipairs(Members()) do
			if m:IsAlive() then sum, n = sum + m:GetLocation(), n + 1 end
		end
		if n > 0 then center = sum / n end
		local lead = X.HumanLead()
		if lead then center = lead:GetLocation() end
	end
	local best, bestScore = LANE_MID, -math.huge
	for _, lane in ipairs(LANES) do
		local score, nextTower = 0, nil
		for tier, tbl in ipairs({ T1, T2, T3 }) do
			local tw = GetTower(GetOpposingTeam(), tbl[lane])
			if tw == nil then score = score + tier elseif not nextTower then nextTower = tw end
		end
		if center then
			local loc = nextTower and nextTower:GetLocation() or GetAncient(GetOpposingTeam()):GetLocation()
			score = score * 300 - Dist(center, loc)
		end
		if score > bestScore then best, bestScore = lane, score end
	end
	return best
end

function X.InGroup(bot)
	local S = TeamPlanState[GetTeam()]
	if not S or not S.group then return false end
	for _, m in ipairs(S.group) do if m == bot then return true end end
	-- Team siege: everyone (but the carry still farming its items).
	if S.phase == 'siege' and S.siegeAll then
		return bot:IsAlive() and not (Objectives.CarryFarming and Objectives.CarryFarming(bot))
	end
	-- Cores that joined the group count as well during a siege.
	if S.phase == 'siege' then
		-- Not the carry still farming its items (it farms on).
		if Objectives.CarryFarming and Objectives.CarryFarming(bot) then return false end
		local center = S.siegeCenter or GroupCenter(S.group)
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
	-- Hurt and being hit, or its own fight check said leave in the last 3 s:
	-- the plan waits, the retreat goes first.
	if J.GetHP(bot) < 0.5 and bot:WasRecentlyDamagedByAnyHero(2.0) then return nil end
	local d = bot._decision
	if d and d.kind == 'retreat' and d.untilT > DotaTime() - 3 then return nil end
	local S = X.Update()
	local p = S.phase

	-- The combat evaluation says we kill first (FunLib/objectives.lua
	-- X.Combat, updated by the retreat mode's fight hint): commit, before any
	-- phase and above a defend assignment (0.88): DK "went for" Terrorblade
	-- at our ancient and the base defense kept him off it.
	local c = bot._combat
	if c and c.go and J.IsValidHero(c.target) and DotaTime() - (bot._fightHintT or -99) < 1.5
	and (not J.IsInLaningPhase() or c.ttkUs <= 3) then
		bot._teamAction = 'pickoff'
		bot._teamTarget = c.target
		return 0.9
	end

	if p == 'regroup' then
		-- Only the heroes deep on their side walk back; the others keep
		-- farming and pushing (the whole team walked back at every respawn).
		if GetUnitToLocationDistance(bot, J.GetEnemyFountain()) < 5000 then
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


	if p == 'hunt' and S.hunt and X.InGroup(bot) then
		-- By strength where the target is (its friends nearby and in the fog
		-- count): a hunt the group loses there is dropped, the supports go
		-- back to the cores.
		local h = S.hunt
		local loc = h.lastLoc or (J.IsValidHero(h.target) and h.target:CanBeSeen() and h.target:GetLocation())
		local alive = {}
		for _, m in ipairs(S.group or {}) do if m:IsAlive() then table.insert(alive, m) end end
		local ok, r = true, 99
		if loc and Objectives.FightAt then ok, r = pcall(Objectives.FightAt, loc, alive, false, true) end
		if ok and r and r < 1.0 then
			if DotaTime() - (S.huntDropLogT or -99) > 20 then
				S.huntDropLogT = DotaTime()
				Log('drops the hunt on '..(h.target and not h.target:IsNull() and h.target:GetUnitName() or '?')..string.format(' (x%.2f there)', r))
			end
			S.hunt = nil
		else
			bot._teamAction = 'hunt'
			return BOT_MODE_DESIRE_VERYHIGH
		end
	end

	-- Supports go where the team fights.
	local fightAlly = X.SupportFightToJoin(bot)
	-- A core with nothing to do joins too (Legion stood 20 s at our top T2
	-- in defend_top at 0.11 while the team fought on their side, bot vs bot
	-- 9103068510, 50:20). Not the carry still farming its items.
	if not fightAlly and J.GetPosition(bot) <= 3 and bot:GetActiveModeDesire() < 0.3
	and bot:GetActiveMode() ~= BOT_MODE_RETREAT
	and not (Objectives.CarryFarming and Objectives.CarryFarming(bot)) then
		fightAlly = X.SupportFightToJoin(bot, true)
	end
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
	-- A support with nothing to do stacks a camp of ours near our cores
	-- (Crystal Maiden stood by Arc Warden under our T3, "idle for 12 s" every
	-- 20 s, 9105652499): hit a neutral at ~:53 and walk it out of the camp,
	-- so two camps' worth spawn for the core at :00.
	if X.StackPlan(bot) then
		bot._teamAction = 'stack'
		return 0.6
	end
	-- Idle with no lane safe to push: stay next to our nearest core.
	local follow = Objectives.IdleFollow and Objectives.IdleFollow(bot)
	if follow then
		if not bot._followLogT or DotaTime() - bot._followLogT > 30 then
			bot._followLogT = DotaTime()
			Log(bot:GetUnitName()..' idle, no lane safe: stays with '..follow:GetUnitName())
		end
		bot._teamAction = 'join_fight'
		bot._teamTarget = follow
		return 0.4
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

	-- 1) Gather close to each other, then smoke. The spot is fixed when the
	-- hunt starts (walking to a group centre that moves with everyone made
	-- them circle around one spot for a minute), and the wait is short.
	if h.state == 'gather' then
		h.gatherLoc = h.gatherLoc or center
		center = h.gatherLoc
		local spread = 0
		for _, m in ipairs(group) do
			if m:IsAlive() then spread = math.max(spread, GetUnitToLocationDistance(m, center)) end
		end
		if spread < 700 or DotaTime() - h.startT > 10 then
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
			if not anySmoke or DotaTime() - h.startT > 15 then h.state = 'move' end
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
			-- Following (no fight): a step behind the ally, not on top of it.
			if GetUnitToUnitDistance(bot, ally) < 500 then return true end
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
	elseif a == 'stack' and bot._stack then
		return X.StackThink(bot)
	end
	return false
end

--------------------------------------------------------------------------------
-- Camp stacking (supports with nothing else to do)
--------------------------------------------------------------------------------

local FarmPlanLib -- loaded on first use (no require loop at load time)

-- The camp to stack this minute, or nil: a support (pos 4-5) after 6:00,
-- HP over 60%, no enemy hero within 1600, between :35 and :59 of the minute;
-- our own non-ancient camp within 2500 that is safe and has no hero of ours
-- farming it, within 2000 of one of our cores (the farm goes to someone).
function X.StackPlan(bot)
	local t = DotaTime()
	local sec = t % 60
	local st = bot._stack
	-- An ongoing stack holds until :59.
	if st and st.minute == math.floor(t / 60) and sec < 59 and J.GetHP(bot) > 0.4 then return true end
	bot._stack = nil
	if J.GetPosition(bot) < 4 or t < 6 * 60 or sec < 35 or sec > 50 then return false end
	if J.GetHP(bot) < 0.6 or #RealEnemiesNear(bot:GetLocation(), 1600) > 0 then return false end
	if bot._stackDoneMinute == math.floor(t / 60) then return false end
	if FarmPlanLib == nil then
		local ok, F = pcall(require, GetScriptDirectory()..'/FunLib/farm_plan')
		FarmPlanLib = ok and F or false
	end
	local best, bd
	for _, camp in pairs(GetNeutralSpawners and GetNeutralSpawners() or {}) do
		if camp and camp.location and camp.team == GetTeam() and camp.type ~= 'ancient' then
			local d = GetUnitToLocationDistance(bot, camp.location)
			if d < 2500 and (not bd or d < bd) then
				local safe = not FarmPlanLib or not FarmPlanLib.IsSafe or FarmPlanLib.IsSafe(bot, camp)
				local coreNear, farmed = false, false
				for _, m in ipairs(Members()) do
					if m ~= bot and m:IsAlive() and J.GetPosition(m) <= 3 then
						local dm = GetUnitToLocationDistance(m, camp.location)
						if dm < 2000 then coreNear = true end
						if dm < 700 then farmed = true end
					end
				end
				-- Walk there in time: ~:53 at the camp.
				local eta = d / math.max(250, bot:GetCurrentMovementSpeed())
				if safe and coreNear and not farmed and sec + eta < 52 then best, bd = camp, d end
			end
		end
	end
	if not best then return false end
	bot._stack = { camp = best, minute = math.floor(t / 60), state = 'go' }
	Log(bot:GetUnitName()..' stacks the '..tostring(best.type)..' camp at '..string.format('(%d, %d)', best.location.x, best.location.y))
	return true
end

function X.StackThink(bot)
	local st = bot._stack
	if not st then return false end
	if J.CanNotUseAction(bot) then return true end
	local t = DotaTime()
	local sec = t % 60
	local loc = st.camp.location
	local away = J.GetTeamFountain() - loc
	away = away / math.max(1, away:Length2D())
	if st.state == 'go' then
		-- Wait at the camp's edge until :52.5, then hit a neutral once.
		local neutrals = bot:GetNearbyNeutralCreeps(700)
		if sec >= 52.5 and #neutrals > 0 then
			local n = neutrals[1]
			if GetUnitToUnitDistance(bot, n) > bot:GetAttackRange() + 150 then
				bot:Action_MoveToLocation(n:GetLocation())
			else
				bot:Action_AttackUnit(n, true)
				st.state, st.hitT = 'hit', t
			end
			return true
		end
		local spot = loc + away * 350
		if GetUnitToLocationDistance(bot, spot) > 120 then bot:Action_MoveToLocation(spot) end
		return true
	end
	-- Hit (or the swing started): walk them out until :59.
	if st.state == 'hit' and t - st.hitT > 0.5 then st.state = 'pull' end
	if st.state == 'pull' then
		bot:Action_MoveToLocation(loc + away * 1100)
		if sec >= 58.5 then
			bot._stackDoneMinute = st.minute
			bot._stack = nil
		end
	end
	return true
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
	if pos < 4 or t < 7 * 60 or J.GetHP(bot) < 0.5 or not HasObserver(bot) then return false end
	if S.carryWardT and t - S.carryWardT < 60 then return false end
	if S.carryWardBy and S.carryWardBy ~= bot and t < (S.carryWardUntil or 0) then return false end

	local carry = MemberAt(1)
	if not (carry and carry:IsAlive()) then return false end
	-- Where the carry farms: the camp it picked (it may still be walking
	-- there from the lane), else where it is in the jungle. A watched camp
	-- counts as safe for the farm (Objectives.Watched): no hidden enemies.
	local cLoc = carry:GetLocation()
	if carry._farmCampLoc and t - (carry._farmCampAt or -math.huge) < 15 then
		cLoc = carry._farmCampLoc
	elseif carry:GetActiveMode() ~= BOT_MODE_FARM or InSomeLane(cLoc) then return false end
	if ObserverNear(cLoc, 1300) then return false end

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
	local building = nil
	for _, tbl in ipairs({ T1, T2, T3 }) do
		building = GetTower(GetOpposingTeam(), tbl[lane])
		if building then break end
	end
	local bLoc = building and building:GetLocation() or GetAncient(GetOpposingTeam()):GetLocation()
	-- Our creeps already at the building tank it: everyone hits it.
	for _, c in ipairs(bot:GetNearbyLaneCreeps(1600, false)) do
		if c:IsAlive() and GetUnitToLocationDistance(c, bLoc) < 800 then return false end
	end
	-- The tank is a bot pushing this same lane. Match 9102056479: the
	-- human Kez (29k) was the "tank"; while they stood back, every pushing
	-- bot walked 350 behind them - back and forth under our T1, then
	-- circling at the enemy T2 while our creeps hit it.
	local pushMode = ({ [LANE_TOP] = BOT_MODE_PUSH_TOWER_TOP, [LANE_MID] = BOT_MODE_PUSH_TOWER_MID, [LANE_BOT] = BOT_MODE_PUSH_TOWER_BOT })[lane]
	local allies = {}
	for _, m in ipairs(Members()) do
		if m:IsAlive() and m:IsBot() and GetUnitToUnitDistance(m, bot) < 1500
		and (m == bot or m:GetActiveMode() == pushMode) then table.insert(allies, m) end
	end
	if #allies < 3 then return false end
	local tank = Tank(allies)
	if not tank or tank == bot then return false end
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
