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

local HARASS_TIME = 1.5
local SUPPORT_HARASS_GAP = 2.0
local CORE_HARASS_GAP = 4.0
local LANING_END = 10 * 60
local PULL_FROM, PULL_UNTIL = 2 * 60, 10 * 60
local PULL_GAP = 50
local PULL_TIMEOUT = 25

local TIER1 = { [LANE_TOP] = TOWER_TOP_1, [LANE_MID] = TOWER_MID_1, [LANE_BOT] = TOWER_BOT_1 }

local function Log(bot, msg) print('[Lane] '..bot:GetUnitName()..': '..msg) end
local function Dist(a, b) return (a - b):Length2D() end

local function RealHeroes(enemy, loc, radius)
	local list = {}
	for _, h in pairs(GetUnitList(enemy and UNIT_LIST_ENEMY_HEROES or UNIT_LIST_ALLIED_HEROES)) do
		if J.IsValidHero(h) and not h:IsIllusion() and Dist(h:GetLocation(), loc) <= radius then
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
		-- Enemy support first; their core once the support has left.
		for _, e in ipairs(list) do
			local p = EnemyPos(e)
			if p and p >= 4 then return e end
		end
	end
	table.sort(list, function(a, b) return Dist(a:GetLocation(), myLoc) < Dist(b:GetLocation(), myLoc) end)
	return list[1]
end

-- Called from mode_laning_generic.GetDesire every frame.
function X.Harass(bot)
	if bot:GetActiveMode() ~= BOT_MODE_LANING then return end
	local t = DotaTime()
	if t < 0 or t > LANING_END then return end
	if (bot.forceFightUntil or -1) > t or (bot._harassNext or -1) > t then return end
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
	-- Not into a trade we'd lose (their burst, their tower, a gank coming).
	local _, _, pDeath = Objectives.FightValue(bot, target)
	if pDeath > 0.35 then return end

	bot.forceFightUntil = t + HARASS_TIME
	bot._harassNext = t + HARASS_TIME + (support and SUPPORT_HARASS_GAP or CORE_HARASS_GAP)
	bot._harassTarget = target
	bot:SetTarget(target)
end

--------------------------------------------------------------------------------
-- Pulls
--------------------------------------------------------------------------------

local function PullCamp(bot)
	if bot._pullCamp ~= nil then return bot._pullCamp or nil end
	bot._pullCamp = false
	local lane = bot:GetAssignedLane()
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
	local pos, lane = J.GetPosition(bot), bot:GetAssignedLane()
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
		local neutrals = bot:GetNearbyNeutralCreeps(700)
		if #neutrals == 0 then EndPull(bot, 'camp is empty') return false end
		-- Hit at :15/:45 — the next wave walks past the camp a few seconds later.
		local sec = t % 30
		if sec >= 14 and sec < 18 then
			P.state = 'aggro'
			P.aggroT = t
			P.neutral = neutrals[1]
			Log(bot, 'pulling the camp into our wave')
		else
			-- Wait out of the camp's aggro range, on the side of our lane.
			local tower = GetTower(GetTeam(), TIER1[bot:GetAssignedLane()])
			local side = (tower and tower:GetLocation() or J.GetTeamFountain()) - campLoc
			if side:Length2D() < 1 then side = Vector(1, 0, 0) end
			local spot = campLoc + side:Normalized() * 400
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
		local tower = GetTower(GetTeam(), TIER1[bot:GetAssignedLane()])
		bot:Action_MoveToLocation(tower and tower:GetLocation() or J.GetTeamFountain())
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Support lane Think
--------------------------------------------------------------------------------

function X.UseSupportThink(bot)
	return IsSupport(bot) and bot:GetAssignedLane() ~= LANE_MID
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

function X.SupportThink(bot)
	if J.CanNotUseAction(bot) then return end
	local t = DotaTime()
	local lane = bot:GetAssignedLane()

	-- Pull.
	if not bot._pull and ShouldPull(bot) then
		bot._pull = { camp = PullCamp(bot), state = 'go', startT = t }
		Log(bot, 'wave is at the enemy tower, going to pull')
	end
	if bot._pull and ThinkPull(bot) then return end

	-- Harass window: right-click the target (spells come from the hero file).
	local target = bot._harassTarget
	if (bot.forceFightUntil or -1) > t and J.IsValidHero(target) and J.CanBeAttacked(target)
	and GetUnitToUnitDistance(bot, target) < bot:GetAttackRange() + 350
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

	-- Last hits belong to the core.
	if not CoreAllyNear(bot, 1000) then
		local lh = BestLastHit(bot)
		if lh then
			bot:Action_AttackUnit(lh, true)
			return
		end
	end

	-- Stand a little behind our wave, between it and the enemy heroes.
	local enemies = RealHeroes(true, bot:GetLocation(), 1600)
	local range = math.max(bot:GetAttackRange(), 300)
	local back = #enemies > 0 and -(range + 100) or -250
	local loc = GetLaneFrontLocation(GetTeam(), lane, back)
	local enemyFront = GetLaneFrontLocation(GetOpposingTeam(), lane, back)
	if GetLaneFrontAmount(GetOpposingTeam(), lane, false) < GetLaneFrontAmount(GetTeam(), lane, false) then
		loc = enemyFront
	end
	if GetUnitToLocationDistance(bot, loc) > 150 then
		bot:Action_MoveToLocation(loc + RandomVector(60))
	end
end

return X
