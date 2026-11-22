-- Laning for every position.
--
-- Harass (all positions): short "fight windows" (bot.forceFightUntil, read by
-- J.IsGoingOnSomeone) so hero files cast their spells on the lane enemy.
-- Supports trade freely and go for the enemy support first, then the core once
-- the support is gone. Cores only harass when no last hit is pending.
--
-- Support lane Think (pos 4/5, replaces the default laning Think for them):
-- right-click harass, deny, no last hits while a core ally is near, stay out
-- of enemy tower range, and pull the next wave into our camp when our wave
-- is about to crash into the enemy tower.

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Objectives = require(GetScriptDirectory()..'/FunLib/objectives')
local okER, EnemyRoles = pcall(require, GetScriptDirectory()..'/FunLib/enemy_role_estimation')
if not okER then EnemyRoles = nil end

local X = {}

-- The bot's lane. Heroes with the replacement laning logic (Hoodwink, Elder
-- Titan, Dark Willow, IO, Marci...) get theirs from it: the engine's lane
-- assignment isn't reliable for them.
function X.Lane(bot)
	if bot._laneOverrideFn then
		local ok, lane = pcall(bot._laneOverrideFn)
		if ok and lane then return lane end
	end
	return bot:GetAssignedLane()
end


local HARASS_TIME = 1.5
local SUPPORT_HARASS_TIME = 2.5  -- supports keep hitting the enemy core
local SUPPORT_HARASS_GAP = 0.8
local CORE_HARASS_GAP = 3.0
local LANING_END = 10 * 60
local PULL_FROM, PULL_UNTIL = 2 * 60, 10 * 60
local PULL_GAP = 50
local PULL_TIMEOUT = 40

local TIER1 = { [LANE_TOP] = TOWER_TOP_1, [LANE_MID] = TOWER_MID_1, [LANE_BOT] = TOWER_BOT_1 }

local function Log(bot, msg) print('[Lane] '..bot:GetUnitName()..': '..msg) end
local function Dist(a, b) return (a - b):Length2D() end

local function RealHeroes(enemy, loc, radius)
	local list = {}
	for _, h in pairs(GetUnitList(enemy and UNIT_LIST_ENEMY_HEROES or UNIT_LIST_ALLIED_HEROES)) do
		if J.IsValidHero(h) and not h:IsIllusion() and not J.IsSuspiciousIllusion(h) and Dist(h:GetLocation(), loc) <= radius then
			table.insert(list, h)
		end
	end
	return list
end

local function EnemyTowerNear(loc, radius)
	for _, id in pairs(TIER1) do
		local t = GetTower(GetOpposingTeam(), id)
		if t and Dist(t:GetLocation(), loc) < radius then return t end
	end
	for _, id in ipairs({ TOWER_TOP_2, TOWER_MID_2, TOWER_BOT_2 }) do
		local t = GetTower(GetOpposingTeam(), id)
		if t and Dist(t:GetLocation(), loc) < radius then return t end
	end
	return nil
end

local function IsSupport(bot) return J.GetPosition(bot) >= 4 end

local function EnemyPos(h)
	if not EnemyRoles then return nil end
	local ok, p = pcall(EnemyRoles.GetEnemyPosition, h:GetPlayerID())
	return ok and p or nil
end

local function LastHitPending(bot)
	local dmg = bot:GetAttackDamage()
	for _, c in pairs(bot:GetNearbyLaneCreeps(bot:GetAttackRange() + 250, true)) do
		if J.IsValid(c) and c:GetHealth() < dmg * 1.4 then return true end
	end
	return false
end

local function CoreAllyNear(bot, radius)
	for _, a in ipairs(RealHeroes(false, bot:GetLocation(), radius)) do
		if a ~= bot and J.GetPosition(a) <= 3 then return true end
	end
	return false
end

--------------------------------------------------------------------------------
-- Harass
--------------------------------------------------------------------------------

local function PickHarassTarget(bot)
	local myLoc = bot:GetLocation()
	local reach = math.max(bot:GetAttackRange() + 300, 750)
	local list = {}
	for _, e in ipairs(RealHeroes(true, myLoc, reach)) do
		if J.CanBeAttacked(e) and not EnemyTowerNear(e:GetLocation(), 750) then table.insert(list, e) end
	end
	if #list == 0 then return nil end
	if IsSupport(bot) then
		-- The enemy core first (deny its farm), the lowest HP one if several;
		-- their support when no core is in reach.
		local best, low = nil, math.huge
		for _, e in ipairs(list) do
			local p = EnemyPos(e)
			if (not p or p <= 3) and e:GetHealth() < low then best, low = e, e:GetHealth() end
		end
		if best then return best end
	end
	table.sort(list, function(a, b) return Dist(a:GetLocation(), myLoc) < Dist(b:GetLocation(), myLoc) end)
	return list[1]
end

-- Share of our HP the enemies around could take in ~2 s (their tower too).
function X.TradeRisk(bot, enemies)
	-- The exchange decides first: when they can't kill us within 4 s, or we
	-- kill first, there's nothing to fear (WK wouldn't walk up to his creeps
	-- next to a Legion Commander who was no threat to him).
	if Objectives and Objectives.Combat and #enemies > 0 then
		local c = Objectives.Combat(bot)
		if c and (c.ttkThem > 4 or c.ttkUs <= c.ttkThem) then return 0 end
	end
	local dmg = 0
	for _, e in ipairs(enemies) do
		local ok, d = pcall(function() return e:GetEstimatedDamageToTarget(true, bot, 2.0, DAMAGE_TYPE_ALL) end)
		if ok and d then dmg = dmg + d end
	end
	if EnemyTowerNear(bot:GetLocation(), 850) then dmg = dmg + 300 end
	return dmg / math.max(1, bot:GetHealth())
end

-- Called from mode_laning_generic.GetDesire every frame.
function X.Harass(bot)
	if bot:GetActiveMode() ~= BOT_MODE_LANING then return end
	local t = DotaTime()
	if t < 0 or t > LANING_END then return end
	if (bot.forceFightUntil or -math.huge) > t or (bot._harassNext or -math.huge) > t then return end
	if bot._pull then return end

	local support = IsSupport(bot)
	if J.GetHP(bot) < (support and 0.4 or 0.5) then return end
	if EnemyTowerNear(bot:GetLocation(), 850) then return end
	if not support and LastHitPending(bot) then return end
	-- Hitting a hero pulls the enemy creeps: not into a full wave when hurt.
	if #bot:GetNearbyLaneCreeps(500, true) > 2 and J.GetHP(bot) < 0.7 then return end
	-- Not alone into two.
	local enemies = RealHeroes(true, bot:GetLocation(), 1200)
	local allies = RealHeroes(false, bot:GetLocation(), 1200)
	if #enemies > #allies + 1 then return end

	local target = PickHarassTarget(bot)
	if not target then return end
	if not support and J.GetHP(target) > J.GetHP(bot) + 0.15 then return end
	-- Not into a trade we'd lose: a harass is a short trade, so what counts is
	-- the enemies' burst over ~2 s (the 4 s all-in estimate made supports
	-- skip almost every trade at low levels).
	if X.TradeRisk(bot, enemies) > (support and 0.75 or 0.6) then return end

	local window = support and SUPPORT_HARASS_TIME or HARASS_TIME
	bot.forceFightUntil = t + window
	bot._harassNext = t + window + (support and SUPPORT_HARASS_GAP or CORE_HARASS_GAP)
	bot._harassTarget = target
	bot:SetTarget(target)
end

--------------------------------------------------------------------------------
-- Pulls
--------------------------------------------------------------------------------

local function PullCamp(bot)
	if bot._pullCamp ~= nil then return bot._pullCamp or nil end
	bot._pullCamp = false
	local lane = X.Lane(bot)
	local tower = TIER1[lane] and GetTower(GetTeam(), TIER1[lane])
	if not tower or lane == LANE_MID then return nil end
	local best, bestDist = nil, 3000
	for _, camp in pairs(GetNeutralSpawners and GetNeutralSpawners() or {}) do
		if camp and camp.location and camp.team == GetTeam() and camp.type ~= 'ancient' then
			local d = Dist(camp.location, tower:GetLocation())
			if d < bestDist then best, bestDist = camp, d end
		end
	end
	if best then
		bot._pullCamp = best
		Log(bot, string.format('pull camp (%s) at (%d, %d)', tostring(best.type), best.location.x, best.location.y))
	end
	return best
end

local function ShouldPull(bot)
	local t = DotaTime()
	if t < PULL_FROM or t > PULL_UNTIL then return false end
	if t < (bot._pullNext or 0) then return false end
	local pos, lane = J.GetPosition(bot), X.Lane(bot)
	local safe = GetTeam() == TEAM_RADIANT and LANE_BOT or LANE_TOP
	if not ((pos == 5 and lane == safe) or (pos == 4 and lane ~= safe and lane ~= LANE_MID)) then return false end
	if J.GetHP(bot) < 0.5 then return false end
	local camp = PullCamp(bot)
	if not camp then return false end

	-- Our wave is about to crash into the enemy tower; never when the
	-- creeps already fight under our own tower.
	local front = GetLaneFrontLocation(GetTeam(), lane, 0)
	local enemyT1 = GetTower(GetOpposingTeam(), TIER1[lane])
	local ownT1 = GetTower(GetTeam(), TIER1[lane])
	if not enemyT1 then return false end
	if ownT1 and Dist(front, ownT1:GetLocation()) < 1300 then return false end
	if Dist(front, enemyT1:GetLocation()) > 1700 then return false end
	if #RealHeroes(true, camp.location, 1200) > 0 then return false end
	return true
end

local function NearestOwnLaneCreep(bot, radius)
	local best, bd = nil, math.huge
	for _, c in pairs(bot:GetNearbyLaneCreeps(radius, false)) do
		if J.IsValid(c) then
			local d = GetUnitToUnitDistance(bot, c)
			if d < bd then best, bd = c, d end
		end
	end
	return best
end

local function EndPull(bot, why)
	if why then Log(bot, 'pull: '..why) end
	bot._pull = nil
	bot._pullNext = DotaTime() + PULL_GAP
end

-- Returns true when it issued an action.
local function ThinkPull(bot)
	local P = bot._pull
	local t = DotaTime()
	if #RealHeroes(true, bot:GetLocation(), 900) > 0 or J.GetHP(bot) < 0.4 then EndPull(bot, 'enemies, aborted') return false end
	if t > P.startT + PULL_TIMEOUT then EndPull(bot, 'timeout') return false end
	local campLoc = P.camp.location

	if P.state == 'go' then
		if GetUnitToLocationDistance(bot, campLoc) > 450 then
			bot:Action_MoveToLocation(campLoc)
			return true
		end
		P.state = 'wait'
	end

	if P.state == 'wait' then
		local neutrals = bot:GetNearbyNeutralCreeps(900)
		if #neutrals == 0 and GetUnitToLocationDistance(bot, campLoc) < 500 then EndPull(bot, 'camp is empty') return false end
		-- Hit the camp when our next wave walks by it (the camp follows us into
		-- the wave); timings by the clock broke when the map changed.
		local wave = NearestOwnLaneCreep(bot, 1600)
		if #neutrals > 0 and wave and Dist(wave:GetLocation(), campLoc) < 1400 then
			P.state = 'aggro'
			P.aggroT = t
			P.neutral = neutrals[1]
			Log(bot, 'pulling the camp into our wave')
		else
			-- Wait out of the camp's aggro range, on the side of our lane.
			local tower = GetTower(GetTeam(), TIER1[X.Lane(bot)])
			local side = (tower and tower:GetLocation() or J.GetTeamFountain()) - campLoc
			if side:Length2D() < 1 then side = Vector(1, 0, 0) end
			local spot = campLoc + side:Normalized() * 450
			if GetUnitToLocationDistance(bot, spot) > 80 then bot:Action_MoveToLocation(spot) end
			return true
		end
	end

	if P.state == 'aggro' then
		local n = P.neutral
		if J.IsValid(n) and t < P.aggroT + 1.5 and not n:WasRecentlyDamagedByHero(bot, 1.0) then
			bot:Action_AttackUnit(n, true)
			return true
		end
		P.state = 'drag'
		P.dragT = t
	end

	if P.state == 'drag' then
		local creep = NearestOwnLaneCreep(bot, 1600)
		if creep then
			-- Neutrals reached our creeps: they fight, the wave is pulled.
			for _, n in pairs(bot:GetNearbyNeutralCreeps(900)) do
				if J.IsValid(n) and GetUnitToUnitDistance(n, creep) < 300 then EndPull(bot, 'done') return false end
			end
			bot:Action_MoveToLocation(creep:GetLocation())
			return true
		end
		if t > P.dragT + 6 then EndPull(bot, 'no wave to pull into') return false end
		local tower = GetTower(GetTeam(), TIER1[X.Lane(bot)])
		bot:Action_MoveToLocation(tower and tower:GetLocation() or J.GetTeamFountain())
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Support lane Think
--------------------------------------------------------------------------------

function X.UseSupportThink(bot)
	return IsSupport(bot) and X.Lane(bot) ~= LANE_MID
end

local function BestDeny(bot)
	local dmg = bot:GetAttackDamage()
	for _, c in pairs(bot:GetNearbyLaneCreeps(bot:GetAttackRange() + 300, false)) do
		if J.IsValid(c) and J.GetHP(c) < 0.5 and c:GetHealth() <= dmg and J.CanBeAttacked(c) then return c end
	end
	return nil
end

local function BestLastHit(bot)
	local dmg = bot:GetAttackDamage()
	for _, c in pairs(bot:GetNearbyLaneCreeps(bot:GetAttackRange() + 300, true)) do
		if J.IsValid(c) and J.CanBeAttacked(c)
		and J.WillKillTarget(c, dmg, DAMAGE_TYPE_PHYSICAL, J.GetAttackProDelayTime(bot, c)) then
			return c
		end
	end
	return nil
end

-- Is an allied core (pos 1-3) of this lane alive and in it (within 2500 of
-- the bot, or of our wave)?
function X.LaneCoreHere(bot)
	local lane = X.Lane(bot)
	local front = GetLaneFrontLocation(GetTeam(), lane, 0)
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if m and m ~= bot and m:IsAlive() and J.GetPosition(m) <= 3 and m:GetAssignedLane() == lane
		and (GetUnitToUnitDistance(m, bot) < 2500 or GetUnitToLocationDistance(m, front) < 2500) then
			return true
		end
	end
	return false
end

-- Hold a spot without auto-attacking: an idle hero hits the creeps around
-- it (taking the core's last hits and pushing the lane), so keep stepping
-- around the spot instead of standing still.
function X.StandAt(bot, loc)
	if GetUnitToLocationDistance(bot, loc) > 150 then
		bot:Action_MoveToLocation(loc)
	else
		bot:Action_MoveToLocation(loc + RandomVector(80))
	end
end

function X.SupportThink(bot)
	if J.CanNotUseAction(bot) then return end
	local t = DotaTime()
	local lane = X.Lane(bot)

	-- Pull.
	if not bot._pull and ShouldPull(bot) then
		bot._pull = { camp = PullCamp(bot), state = 'go', startT = t }
		Log(bot, 'wave is at the enemy tower, going to pull')
	end
	if bot._pull and ThinkPull(bot) then return end

	-- Our core is dead or away from the lane: play the lane as the core does
	-- (last hits next to the wave, harass), instead of waiting at the tower.
	if not X.LaneCoreHere(bot) and J.GetHP(bot) > 0.4 then
		X.CoreThink(bot)
		return
	end

	-- Harass window: right-click the target (spells come from the hero file).
	local target = bot._harassTarget
	if (bot.forceFightUntil or -math.huge) > t and J.IsValidHero(target) and J.CanBeAttacked(target)
	and GetUnitToUnitDistance(bot, target) < bot:GetAttackRange() + 600
	and not EnemyTowerNear(target:GetLocation(), 750) then
		bot:Action_AttackUnit(target, true)
		return
	end

	-- Out of enemy tower range.
	local tower = EnemyTowerNear(bot:GetLocation(), 800)
	if tower then
		bot:Action_MoveToLocation(bot:GetLocation() + (bot:GetLocation() - tower:GetLocation()):Normalized() * 300)
		return
	end

	local deny = BestDeny(bot)
	if deny then
		bot:Action_AttackUnit(deny, true)
		return
	end

	-- Last hits belong to the core while it's in the lane.
	if not X.LaneCoreHere(bot) then
		local lh = BestLastHit(bot)
		if lh then
			bot:Action_AttackUnit(lh, true)
			return
		end
	end

	-- Zone the enemy core: stand at our attack range from it (on our side)
	-- when the trade is safe, so every last hit it goes for costs it HP.
	local enemies = RealHeroes(true, bot:GetLocation(), 1600)
	local core
	for _, e in ipairs(enemies) do
		local p = EnemyPos(e)
		if (not p or p <= 3) and not EnemyTowerNear(e:GetLocation(), 800) then core = e break end
	end
	if core and J.GetHP(bot) > 0.45 and X.TradeRisk(bot, enemies) < 0.5 then
		local away = (bot:GetLocation() - core:GetLocation())
		if away:Length2D() < 1 then away = Vector(1, 0, 0) end
		local spot = core:GetLocation() + away:Normalized() * (bot:GetAttackRange() + 30)
		X.StandAt(bot, spot)
		return
	end

	-- Stand a little behind our wave, between it and the enemy heroes.
	local range = math.max(bot:GetAttackRange(), 300)
	local back = #enemies > 0 and -(range + 100) or -250
	local loc = GetLaneFrontLocation(GetTeam(), lane, back)
	local enemyFront = GetLaneFrontLocation(GetOpposingTeam(), lane, back)
	if GetLaneFrontAmount(GetOpposingTeam(), lane, false) < GetLaneFrontAmount(GetTeam(), lane, false) then
		loc = enemyFront
	end
	X.StandAt(bot, loc)
end

--------------------------------------------------------------------------------
-- Melee core lane Think (pos 1/3 melee): the default laning kept melee cores
-- too far from the creeps to last hit.
--------------------------------------------------------------------------------

-- Every core in its lane (pos 1-3, melee and ranged, mid too). It was melee
-- pos 1/3 only, and the ranged cores and mids last hit with the engine's
-- laning: at 10:00 Luna and Invoker had 13 last hits each (a human carry in
-- the same game 56).
function X.UseCoreThink(bot)
	local pos = J.GetPosition(bot)
	return pos >= 1 and pos <= 3
end

-- Time to turn to face `u` (about 0.17 s for a half turn at a common turn
-- rate); the attack can't start before it.
function X.TurnTime(bot, u)
	local ok, facing = pcall(function() return bot:GetFacing() end)
	if not ok or not facing then return 0 end
	local v = u:GetLocation() - bot:GetLocation()
	local want = math.deg(math.atan2(v.y, v.x))
	local diff = math.abs(((want - facing) + 540) % 360 - 180)
	return diff / 180 * 0.17
end

-- Last-hit accounting: creeps we swung at for a last hit against last hits
-- we actually got, printed once a minute ("[Diag] X last hits: ...").
function X.NoteLastHitTry(bot, c, dmg, delay)
	bot._lhTried = bot._lhTried or {}
	bot._lhTried[c] = true
	-- The swing, to check in 1.5 s whether we got it.
	bot._lhSwings = bot._lhSwings or {}
	if not bot._lhSwings[c] then
		local lh = 0
		pcall(function() lh = bot:GetLastHits() end)
		local incoming = 0
		pcall(function() incoming = J.GetTotalAttackWillRealDamage(c, delay or 0) end)
		bot._lhSwings[c] = { t = DotaTime(), hp = c:GetHealth(), dmg = dmg or 0, delay = delay or 0, lh = lh,
			incoming = incoming, real = c:GetActualIncomingDamage(dmg or 0, DAMAGE_TYPE_PHYSICAL),
			name = string.gsub(c:GetUnitName() or '?', 'npc_dota_', ''), dist = GetUnitToUnitDistance(bot, c) }
	end
end

-- Swings 1.5 s old: a creep that died without a last hit of ours is a miss,
-- printed with the numbers the swing was made on.
local function CheckSwings(bot)
	if not bot._lhSwings then return end
	local t = DotaTime()
	local lh = 0
	pcall(function() lh = bot:GetLastHits() end)
	for c, w in pairs(bot._lhSwings) do
		if t - w.t > 1.5 then
			local dead = c:IsNull() or not c:IsAlive()
			if dead and lh <= w.lh then
				print(string.format('[Diag] %s missed %s: HP %d at the swing, our hit %d (%d before armor), others %d within %.2f s, %d away',
					bot:GetUnitName(), w.name, w.hp, w.real, w.dmg, w.incoming, w.delay, w.dist))
			end
			bot._lhSwings[c] = nil
		end
	end
end

function X.LastHitStats(bot, t)
	CheckSwings(bot)
	local lh = 0
	pcall(function() lh = bot:GetLastHits() end)
	local st = bot._lhStats
	if not st then
		bot._lhStats = { t = t, lh = lh }
		bot._lhTried = {}
		return
	end
	if t - st.t >= 60 then
		local tried = 0
		for _ in pairs(bot._lhTried or {}) do tried = tried + 1 end
		print(string.format('[Diag] %s last hits %d:00-%d:00: went for %d, got %d', bot:GetUnitName(),
			math.floor(st.t / 60), math.floor(t / 60), tried, lh - st.lh))
		bot._lhStats = { t = t, lh = lh }
		bot._lhTried = {}
	end
end

function X.CoreThink(bot)
	if J.CanNotUseAction(bot) then return end
	local t = DotaTime()
	local lane = X.Lane(bot)
	local range = bot:GetAttackRange()
	local dmg = bot:GetAttackDamage()
	-- The low roll, not the average: an attack at "HP <= average damage" fails
	-- about half the time on the close calls and the next creep hit takes it.
	local var = 0
	pcall(function() var = bot:GetBaseDamageVariance() or 0 end)
	dmg = dmg - math.max(0, var) * 0.5
	local qb = bot:FindItemSlot('item_quelling_blade')
	if qb >= 0 and bot:GetItemSlotType(qb) == ITEM_SLOT_TYPE_MAIN then dmg = dmg + (range > 350 and 4 or 8) end
	X.LastHitStats(bot, t)
	local enemies = RealHeroes(true, bot:GetLocation(), 1400)
	-- Far from our own lane (after a bounty rune by mid): go there first, no
	-- last hits on another core's lane (Gyrocopter stayed at mid taking the
	-- mid creeps).
	local ownFront = GetLaneFrontLocation(GetTeam(), lane, 0)
	if ownFront and J.GetPosition(bot) <= 3 and GetUnitToLocationDistance(bot, ownFront) > 2500 then
		bot:Action_MoveToLocation(ownFront)
		return
	end
	local risk = X.TradeRisk(bot, enemies)

	-- Creeps our tower is shooting: their HP drops in tower-shot chunks, so
	-- "dies to one hit now" comes too late (WK lost three last hits under his
	-- tower). Hit now when the tower's next shot then leaves it in one-hit
	-- range; wait next to it when the tower's shot does that on its own.
	local myTower
	local okT, towers = pcall(function() return bot:GetNearbyTowers(1100, false) end)
	for _, tw in pairs(okT and towers or {}) do
		if tw and not tw:IsNull() and tw:IsAlive() then myTower = tw break end
	end
	if myTower then
		local tgt = myTower:GetAttackTarget()
		local towerDmg = myTower:GetAttackDamage() or 0
		if tgt and not tgt:IsNull() and tgt:IsAlive() and tgt:GetTeam() == GetOpposingTeam() and not tgt:IsHero()
		and GetUnitToUnitDistance(bot, tgt) < 900 and J.CanBeAttacked(tgt) then
			local hp = tgt:GetHealth()
			if hp <= dmg then
				bot:Action_AttackUnit(tgt, true)
				return
			end
			local afterTower = hp - towerDmg
			local afterHit = hp - dmg - towerDmg
			if afterTower > dmg and afterHit > 0 and afterHit <= dmg then
				bot:Action_AttackUnit(tgt, true) -- the prep hit
				return
			end
			if GetUnitToUnitDistance(bot, tgt) > range + 50 then
				bot:Action_MoveToLocation(tgt:GetLocation())
				return
			end
			if afterTower > 0 and afterTower <= dmg then
				bot:Action_ClearActions(true) -- wait for the tower's shot
				return
			end
		end
	end

	-- Last hits first: a creep we kill now (DK chased Troll toward his tower
	-- in a harass window and lost two last hits and a deny).
	local walkTo
	for _, c in pairs(bot:GetNearbyLaneCreeps(800, true)) do
		if J.IsValid(c) and J.CanBeAttacked(c) and not EnemyTowerNear(c:GetLocation(), 700) then
			local delay = J.GetAttackProDelayTime(bot, c) + X.TurnTime(bot, c)
			if J.WillKillTarget(c, dmg, DAMAGE_TYPE_PHYSICAL, delay) then
				X.NoteLastHitTry(bot, c, dmg, delay)
				bot:Action_AttackUnit(c, true)
				return
			end
			if c:GetHealth() < dmg * 2.2 and (not walkTo or c:GetHealth() < walkTo:GetHealth()) then walkTo = c end
		end
	end
	-- A deny now beats a hit on a hero too.
	for _, c in pairs(bot:GetNearbyLaneCreeps(range + 150, false)) do
		if J.IsValid(c) and J.GetHP(c) < 0.5 and c:GetHealth() <= dmg and J.CanBeAttacked(c) then
			bot:Action_AttackUnit(c, true)
			return
		end
	end

	-- Harass window (set by X.Harass): hit a hero in range, no chasing and
	-- nothing near their tower, unless it's a kill (under 35% HP).
	local target = bot._harassTarget
	if (bot.forceFightUntil or -math.huge) > t and J.IsValidHero(target) and J.CanBeAttacked(target) then
		local kill = J.GetHP(target) < 0.35
		local d = GetUnitToUnitDistance(bot, target)
		if (kill and d < range + 400 and not EnemyTowerNear(target:GetLocation(), 750))
		or (d < range + 80 and not EnemyTowerNear(target:GetLocation(), 900) and not walkTo) then
			bot:Action_AttackUnit(target, true)
			return
		end
	end
	-- Being harassed (an enemy hero hit us in the last 2 s): hit back when it
	-- is in our range, else step out of its attack range, unless a last hit
	-- is about to drop. TradeRisk says 0 when they can't kill us in 4 s, so
	-- WK stood still and took every Crystal Maiden attack.
	local harasser, hd
	for _, e in ipairs(enemies) do
		if bot:WasRecentlyDamagedByHero(e, 2.0) then
			local d = GetUnitToUnitDistance(bot, e)
			if not hd or d < hd then harasser, hd = e, d end
		end
	end
	if harasser and J.GetHP(bot) < 0.95 then
		if hd <= range + 60 and risk < 0.6 and J.CanBeAttacked(harasser) and not EnemyTowerNear(harasser:GetLocation(), 900) then
			bot:Action_AttackUnit(harasser, true)
			return
		end
		-- Only when the harass really costs (under 75% HP, or more hurt than
		-- the harasser), and not with a deny or last hit coming up: DK stepped
		-- out of Invoker's range every 20 s at 96% HP and denied nothing.
		local soon = walkTo ~= nil
		for _, c in pairs(bot:GetNearbyLaneCreeps(range + 400, false)) do
			if J.IsValid(c) and J.GetHP(c) < 0.5 and c:GetHealth() < dmg * 2 then soon = true end
		end
		local costly = J.GetHP(bot) < 0.75 or J.GetHP(bot) + 0.15 < J.GetHP(harasser)
		if costly and not soon then
			local er = 600
			pcall(function() er = harasser:GetAttackRange() end)
			local away = bot:GetLocation() - harasser:GetLocation()
			if away:Length2D() < 1 then away = Vector(1, 0, 0) end
			if hd < er + 200 then
				if t - (bot._harassedLogT or -math.huge) > 20 then
					bot._harassedLogT = t
					print('[Diag] '..bot:GetUnitName()..' harassed by '..harasser:GetUnitName()..': steps out of its range')
				end
				local spot = harasser:GetLocation() + away:Normalized() * (er + 250)
				if EnemyTowerNear(spot, 850) then spot = GetLaneFrontLocation(GetTeam(), lane, -1300) end
				bot:Action_MoveToLocation(spot)
				return
			end
		end
	end
	-- A trade we'd lose keeps us back, unless no enemy hero is near that creep
	-- (Chaos Knight at 36% HP stood 500 behind his wave for 5 s at 2:40
	-- while two creeps died to it, Bristleback and Spirit Breaker away).
	local freeCreep = false
	if walkTo and risk >= 0.8 and J.GetHP(bot) > 0.25 then
		freeCreep = #RealHeroes(true, walkTo:GetLocation(), 750) == 0
	end
	-- A creep about to die (under 1.4 hits) is worth some harass, the ranged
	-- one more so: Legion Commander stood 500 back at 4:00 and left the
	-- ranged creep to the wave. Not into a kill (risk over 1.0-1.2) or under
	-- 40% HP.
	local worth = false
	if walkTo and not freeCreep and J.GetHP(bot) > 0.4 and walkTo:GetHealth() < dmg * 1.4 then
		local ranged = string.find(walkTo:GetUnitName() or '', 'ranged') ~= nil
		worth = risk < (ranged and 1.2 or 1.0)
	end
	if walkTo and (risk < 0.8 or freeCreep or worth) then
		-- Stand in range and face it, like a player shuffling by the creep:
		-- bots stood a step out of range or turned away and lost the turn
		-- and the walk-in on the last hit (Arc Warden missed the flag
		-- bearer).
		local d = GetUnitToUnitDistance(bot, walkTo)
		local want = math.max(100, range - 40)
		if d > want + 40 then
			local dir = (bot:GetLocation() - walkTo:GetLocation())
			if dir:Length2D() < 1 then dir = Vector(1, 0, 0) end
			bot:Action_MoveToLocation(walkTo:GetLocation() + dir:Normalized() * want)
		elseif X.TurnTime(bot, walkTo) > 0.06 then
			local toward = walkTo:GetLocation() - bot:GetLocation()
			bot:Action_MoveToLocation(bot:GetLocation() + toward:Normalized() * 20)
		end
		return -- stay next to it for the last hit
	end

	-- Denies.
	for _, c in pairs(bot:GetNearbyLaneCreeps(range + 300, false)) do
		if J.IsValid(c) and J.GetHP(c) < 0.5 and c:GetHealth() <= dmg and J.CanBeAttacked(c) then
			bot:Action_AttackUnit(c, true)
			return
		end
	end

	-- Nobody to trade with (no enemy hero within 1400) or the laning stage is
	-- over: clear the wave instead of waiting for last hits. Medusa stood in
	-- an enemy wave for seconds ("stands still 5 s in mode laning") hitting
	-- nothing until each creep was low enough.
	if (#enemies == 0 or (not J.IsInLaningPhase() and risk < 0.6)) and not EnemyTowerNear(bot:GetLocation(), 850) then
		local weakest
		for _, c in pairs(bot:GetNearbyLaneCreeps(range + 300, true)) do
			if J.IsValid(c) and J.CanBeAttacked(c) and not EnemyTowerNear(c:GetLocation(), 800)
			and (not weakest or c:GetHealth() < weakest:GetHealth()) then weakest = c end
		end
		if weakest then
			bot:Action_AttackUnit(weakest, true)
			return
		end
	end

	-- Out of enemy tower range.
	local tower = EnemyTowerNear(bot:GetLocation(), 800)
	if tower then
		bot:Action_MoveToLocation(bot:GetLocation() + (bot:GetLocation() - tower:GetLocation()):Normalized() * 300)
		return
	end

	-- Next to our wave's front; further back only when a trade would hurt.
	-- Never a spot in their tower's range: with our wave at their tower the
	-- front is under it, and DK went back and forth between it and "out of
	-- tower range" on Radiant's mid high ground until he died.
	local back = risk < 0.6 and -(range + 50) or -500
	local loc = GetLaneFrontLocation(GetTeam(), lane, back)
	for _, b in ipairs({ -700, -1000, -1300, -1600 }) do
		if not EnemyTowerNear(loc, 850) then break end
		loc = GetLaneFrontLocation(GetTeam(), lane, math.min(back, b))
	end
	if GetUnitToLocationDistance(bot, loc) > 150 then
		bot:Action_MoveToLocation(loc + RandomVector(50))
	end
end

return X
