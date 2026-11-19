--==============================================================================
-- Early game (pre-horn until ~0:30): bounty runes, harass, kill attempts and
-- an occasional team smoke gank. Used by mode_rune_generic.lua.
--
--   * Each team owns the 2 bounty runes on its side of the map (out of 4).
--     Safe-lane bounty: pos 5 picks it, pos 1 stands there.
--     Off-lane bounty:  pos 4 picks it, pos 3 stands there.
--     Mid stands at the own bounty closest to mid.
--     If the picker isn't there, whoever is closest picks it.
--   * Around the rune bots harass enemies that come for it (right clicks,
--     staying near the rune), back off when outnumbered, and go for a kill
--     when the heroes there have enough damage/disables for it (spells are
--     used: the bot counts as "going on someone" while fighting).
--   * Sometimes (SMOKE_GANK_CHANCE) pos 2-5 smoke before the horn and gank
--     the enemy carry at its safe-lane bounty instead.
--   * After the bounty (or 0:30) everyone goes to lane.
--==============================================================================

local X = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Objectives = require(GetScriptDirectory()..'/FunLib/objectives')
local okRoles, HeroRoles = pcall(require, GetScriptDirectory()..'/FunLib/aba_hero_roles_map')
if not okRoles then HeroRoles = nil end

local EARLY_END = 30            -- seconds after the horn this module stops
local SMOKE_GANK_CHANCE = 25    -- % of games pos 2-5 smoke-gank the enemy carry's bounty
local CARRY_JOIN_CHANCE = 25    -- % the carry goes with the team to the off-lane bounty
local HARASS_LEASH = 900        -- don't chase further than this from the own rune spot
local KILL_MARGIN = 1.15        -- team damage must exceed target HP by this factor
local KILL_MARGIN_ESCAPE = 1.4  -- ... for targets with an escape skill

local BOUNTIES = { RUNE_BOUNTY_1, RUNE_BOUNTY_2, RUNE_BOUNTY_3, RUNE_BOUNTY_4 }

local function Log(bot, msg) print('[Early] '..bot:GetUnitName()..': '..msg) end

local function SafeLane(team) return team == TEAM_RADIANT and LANE_BOT or LANE_TOP end
local function OffLane(team) return team == TEAM_RADIANT and LANE_TOP or LANE_BOT end

local function Dist(a, b) return (a - b):Length2D() end

--------------------------------------------------------------------------------
-- Team plan (shared by the team's bots: one Lua VM per team)
--------------------------------------------------------------------------------

EarlyTeamPlan = EarlyTeamPlan or {}

local function BountySides(team)
	local own, enemy = {}, {}
	local myFountain = J.GetTeamFountain()
	local enemyFountain = J.GetEnemyFountain and J.GetEnemyFountain() or GetAncient(GetOpposingTeam()):GetLocation()
	for _, rune in ipairs(BOUNTIES) do
		local loc = rune and GetRuneSpawnLocation(rune)
		-- Unused rune slots report the map centre (0,0): that is the mid river.
		local dup = false
		for _, r in ipairs(own) do if Dist(GetRuneSpawnLocation(r), loc) < 300 then dup = true end end
		for _, r in ipairs(enemy) do if Dist(GetRuneSpawnLocation(r), loc) < 300 then dup = true end end
		if loc and loc.x and loc:Length2D() > 1500 and not dup then
			print(string.format('[Early] bounty %d at (%d, %d)', rune, loc.x, loc.y))
			if Dist(loc, myFountain) < Dist(loc, enemyFountain) then
				table.insert(own, rune)
			else
				table.insert(enemy, rune)
			end
		end
	end
	return own, enemy
end

-- Of `runes`, the one closest to `team`'s tier-1 tower of `lane`.
local TIER1 = { [LANE_TOP] = TOWER_TOP_1, [LANE_MID] = TOWER_MID_1, [LANE_BOT] = TOWER_BOT_1 }
local function ClosestToLane(runes, lane, team)
	local tower = GetTower(team or GetTeam(), TIER1[lane])
	local laneLoc = tower and tower:GetLocation() or GetLocationAlongLane(lane, 0.5)
	local best, bestDist = nil, math.huge
	for _, rune in ipairs(runes) do
		local d = Dist(GetRuneSpawnLocation(rune), laneLoc)
		if d < bestDist then best, bestDist = rune, d end
	end
	return best
end

local function TeamHasHuman(team)
	for _, pid in pairs(GetTeamPlayers(team)) do
		if not IsPlayerBot(pid) then return true end
	end
	return false
end

function X.TeamPlan()
	local team = GetTeam()
	if EarlyTeamPlan[team] then return EarlyTeamPlan[team] end

	local own, enemy = BountySides(team)
	local plan = { own = own, enemy = enemy }
	plan.safeRune = ClosestToLane(own, SafeLane(team))
	plan.offRune = ClosestToLane(own, OffLane(team))
	if plan.offRune == plan.safeRune then
		plan.offRune = nil
		for _, r in ipairs(own) do if r ~= plan.safeRune then plan.offRune = r end end
	end
	-- Mid takes the river rune spot by the mid lane, not a bounty in the jungle
	-- (with one own bounty that put pos 5, 1 and 2 on the same rune).
	local midSpots = {}
	for _, r in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
		local l = r and GetRuneSpawnLocation(r)
		if l and l:Length2D() > 500 then table.insert(midSpots, r) end
	end
	plan.midRune = ClosestToLane(midSpots, LANE_MID) or ClosestToLane(own, LANE_MID)
	-- The enemy carry stands at the enemy's safe-lane bounty.
	plan.enemyCarryRune = ClosestToLane(enemy, SafeLane(GetOpposingTeam()), GetOpposingTeam())

	-- Smoke gank: bots only (humans aren't dragged along), and the team needs
	-- some disables among pos 2-5.
	plan.smoke = false
	if not TeamHasHuman(team) and plan.enemyCarryRune and RandomInt(1, 100) <= SMOKE_GANK_CHANCE then
		local disablers = 0
		for i = 1, 5 do
			local m = GetTeamMember(i)
			if m and J.GetPosition(m) >= 2 and HeroRoles and HeroRoles.IsDisabler(m:GetUnitName()) then
				disablers = disablers + 1
			end
		end
		plan.smoke = disablers >= 2
	end
	if plan.smoke then
		plan.gatherRune = plan.offRune
		local best = math.huge
		for _, r in ipairs(own) do
			local d = Dist(GetRuneSpawnLocation(r), GetRuneSpawnLocation(plan.enemyCarryRune))
			if d < best then best, plan.gatherRune = d, r end
		end
		plan.smokeState = 'gather'
		print('[Early] team '..team..' plans a smoke gank on the enemy carry bounty')
	end
	EarlyTeamPlan[team] = plan
	return plan
end

-- Rune this bot goes to, and whether it should pick it up first.
local AssignmentRaw, SafePointFor
local function Assignment(bot, plan)
	local rune, picker = AssignmentRaw(bot, plan)
	-- A rune on the other side of the map isn't worth the walk: lane instead.
	if rune and not bot._earlyJoin and Dist(GetRuneSpawnLocation(rune), SafePointFor(bot)) > 7000 then return nil, false end
	return rune, picker
end

AssignmentRaw = function(bot, plan)
	local pos = J.GetPosition(bot)
	if pos == 5 then return plan.safeRune, true end
	if pos == 1 then
		if bot._earlyJoin == nil then bot._earlyJoin = RandomInt(1, 100) <= CARRY_JOIN_CHANCE end
		return bot._earlyJoin and plan.offRune or plan.safeRune, false
	end
	if pos == 4 then return plan.offRune, true end
	if pos == 3 then return plan.offRune, false end
	return plan.midRune, true
end

SafePointFor = function(bot)
	local lane = bot:GetAssignedLane()
	local towerId = lane == LANE_TOP and TOWER_TOP_1 or (lane == LANE_BOT and TOWER_BOT_1 or TOWER_MID_1)
	local tower = GetTower(GetTeam(), towerId)
	return tower and tower:GetLocation() or J.GetTeamFountain()
end

local function InSmokeGank(bot, plan)
	return plan.smoke and plan.smokeState ~= 'done' and J.GetPosition(bot) >= 2
end

--------------------------------------------------------------------------------
-- Fight evaluation
--------------------------------------------------------------------------------

local function RealHeroesNear(loc, radius, enemy)
	local list = {}
	for _, h in pairs(GetUnitList(enemy and UNIT_LIST_ENEMY_HEROES or UNIT_LIST_ALLIED_HEROES)) do
		if J.IsValidHero(h) and not h:IsIllusion() and Dist(h:GetLocation(), loc) <= radius then
			table.insert(list, h)
		end
	end
	return list
end

-- Damage the allies around `target` can deal in a few seconds with the spells
-- and items they have ready, against what the target can take.
local function KillMargin(target, allies)
	local dmg = 0
	for _, ally in ipairs(allies) do
		if Dist(ally:GetLocation(), target:GetLocation()) <= 1000 then
			dmg = dmg + ally:GetEstimatedDamageToTarget(true, target, 4.0, DAMAGE_TYPE_ALL)
		end
	end
	local need = KILL_MARGIN
	if HeroRoles and HeroRoles.HasEscape and HeroRoles.HasEscape(target:GetUnitName()) then need = KILL_MARGIN_ESCAPE end
	return dmg / math.max(1, target:GetHealth() * need)
end

local function BestKillTarget(bot, enemies, allies)
	local best, bestMargin = nil, 1
	for _, e in ipairs(enemies) do
		if J.CanBeAttacked(e) then
			local m = KillMargin(e, allies)
			if Objectives.FightValue(bot, e) < 0 then m = 0 end -- costs more than it brings
			if m >= bestMargin then best, bestMargin = e, m end
		end
	end
	return best
end

local function Fight(bot, target, why)
	if bot._earlyTarget ~= target then Log(bot, why..' '..target:GetUnitName()) end
	bot._earlyTarget = target
	bot.forceFightUntil = DotaTime() + 3 -- J.IsGoingOnSomeone: heroes use their spells
	bot:SetTarget(target)
	bot:Action_AttackUnit(target, true)
end

local function SafePoint(bot)
	local lane = bot:GetAssignedLane()
	local towerId = lane == LANE_TOP and TOWER_TOP_1 or (lane == LANE_BOT and TOWER_BOT_1 or TOWER_MID_1)
	local tower = GetTower(GetTeam(), towerId)
	if tower then return tower:GetLocation() end
	return J.GetTeamFountain()
end

--------------------------------------------------------------------------------
-- Smoke gank
--------------------------------------------------------------------------------

local function SmokeParticipants()
	local list = {}
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if J.IsValidHero(m) and J.GetPosition(m) >= 2 then table.insert(list, m) end
	end
	return list
end

local function ThinkSmoke(bot, plan)
	local gather = GetRuneSpawnLocation(plan.gatherRune)
	local target = GetRuneSpawnLocation(plan.enemyCarryRune)
	local mates = SmokeParticipants()

	if plan.smokeState == 'gather' then
		-- Smoke already popped (by anyone): go, don't sit in it at our rune.
		for _, m in ipairs(mates) do
			if m:HasModifier('modifier_smoke_of_deceit') then
				plan.smokeState = 'move'
				Log(bot, 'we are smoked, going for the enemy carry bounty')
				return
			end
		end
		local ready = 0
		for _, m in ipairs(mates) do
			if Dist(m:GetLocation(), gather) < 700 then ready = ready + 1 end
		end
		local t = DotaTime()
		if ready >= #mates or (t > -30 and ready >= 3) or t > -20 then
			-- Whoever carries the smoke pops it.
			for _, m in ipairs(mates) do
				local slot = m:FindItemSlot('item_smoke_of_deceit')
				if slot >= 0 and m == bot then
					bot:Action_UseAbility(bot:GetItemInSlot(slot))
					plan.smokeState = 'move'
					Log(bot, 'smoke! going for the enemy carry bounty')
					return
				end
			end
			-- Nobody can smoke yet: if no one has it at all, cancel.
			local anyone = false
			for _, m in ipairs(mates) do if m:FindItemSlot('item_smoke_of_deceit') >= 0 then anyone = true end end
			if not anyone then
				plan.smokeState = 'done'
				Log(bot, 'no smoke on the team, gank cancelled')
				return
			end
		end
		bot:Action_MoveToLocation(gather + RandomVector(150))
		return
	end

	if plan.smokeState == 'move' then
		local enemies = RealHeroesNear(bot:GetLocation(), 1200, true)
		local allies = RealHeroesNear(bot:GetLocation(), 1400, false)
		if #enemies > 0 then
			local t = BestKillTarget(bot, enemies, allies)
			if t then Fight(bot, t, 'smoke gank on') return end
			if #enemies > #allies then
				plan.smokeState = 'done'
				Log(bot, 'smoke gank: outnumbered, backing off')
				return
			end
			Fight(bot, enemies[1], 'smoke gank harass')
			return
		end
		if Dist(bot:GetLocation(), target) < 300 and DotaTime() > 5 then
			plan.smokeState = 'done' -- nobody there
			Log(bot, 'smoke gank: nobody at the rune')
			return
		end
		bot:Action_MoveToLocation(target)
		return
	end
end

--------------------------------------------------------------------------------
-- Mode hooks
--------------------------------------------------------------------------------

-- Desire for mode_rune_generic, or nil when this module isn't in charge.
function X.GetDesire(bot)
	local t = DotaTime()
	if t >= EARLY_END or GetGameMode() == GAMEMODE_1V1MID or GetGameMode() == GAMEMODE_MO then return nil end
	if bot._earlyDone then return nil end
	local plan = X.TeamPlan()

	if InSmokeGank(bot, plan) then
		if plan.smokeState == 'move' and t > 25 then plan.smokeState = 'done' end
		return 0.95
	end

	local rune, isPicker = Assignment(bot, plan)
	if not rune then return nil end
	if t < 0 then return 0.9 end

	-- After the horn: stay while the rune is up or there's a fight around it.
	-- (A rune out of sight reads as unknown: keep going until we're there.)
	local loc = GetRuneSpawnLocation(rune)
	if GetUnitToLocationDistance(bot, loc) > 1200 then return 0.9 end
	local enemies = RealHeroesNear(loc, 1000, true)
	if GetRuneStatus(rune) == RUNE_STATUS_AVAILABLE or #enemies > 0 then return 0.9 end
	bot._earlyDone = true
	Log(bot, 'bounty done, going to lane')
	return nil
end

-- Returns true when it issued an action.
function X.Think(bot)
	if X.GetDesire(bot) == nil then return false end
	if J.CanNotUseAction(bot) then return true end
	local plan = X.TeamPlan()

	if InSmokeGank(bot, plan) then
		ThinkSmoke(bot, plan)
		return true
	end

	local rune, isPicker = Assignment(bot, plan)
	local runeLoc = GetRuneSpawnLocation(rune)
	local myLoc = bot:GetLocation()
	local enemies = RealHeroesNear(myLoc, 1200, true)
	local allies = RealHeroesNear(myLoc, 1400, false)

	-- Outnumbered: back off toward the own tower.
	local close = 0
	for _, e in ipairs(enemies) do if Dist(e:GetLocation(), myLoc) < 900 then close = close + 1 end end
	if close > #allies then
		bot:Action_MoveToLocation(SafePoint(bot))
		return true
	end

	-- Kill attempt when the heroes here have the damage for it.
	local target = BestKillTarget(bot, enemies, allies)
	if target and Dist(target:GetLocation(), runeLoc) < HARASS_LEASH + 300 then
		Fight(bot, target, 'going for a kill on')
		return true
	end
	bot._earlyTarget = nil

	-- Pick the rune (picker, or anyone if the picker isn't around).
	if DotaTime() >= 0 and GetRuneStatus(rune) == RUNE_STATUS_AVAILABLE then
		local picker = isPicker
		if not picker then
			picker = true
			for i = 1, 5 do
				local m = GetTeamMember(i)
				if J.IsValidHero(m) and m ~= bot and Dist(m:GetLocation(), runeLoc) < Dist(myLoc, runeLoc) then
					picker = false
				end
			end
		end
		if picker then
			if Dist(myLoc, runeLoc) > 100 then bot:Action_MoveToLocation(runeLoc) else bot:Action_PickUpRune(rune) end
			return true
		end
	end

	-- Harass enemies that come for the rune: right clicks, not too far from it.
	for _, e in ipairs(enemies) do
		if J.CanBeAttacked(e) and J.GetHP(bot) > 0.5
		and Dist(e:GetLocation(), runeLoc) < HARASS_LEASH
		and Dist(e:GetLocation(), myLoc) < bot:GetAttackRange() + 200
		then
			bot:Action_AttackUnit(e, true)
			return true
		end
	end

	-- Wait next to the rune (pickers on it, the others a bit behind).
	local standLoc = runeLoc
	if not isPicker then
		local back = J.GetTeamFountain() - runeLoc
		standLoc = runeLoc + back:Normalized() * 200
	end
	if Dist(myLoc, standLoc) > 150 then
		bot:Action_MoveToLocation(standLoc)
	elseif RandomInt(1, 20) == 1 then
		bot:Action_MoveToLocation(standLoc + RandomVector(100))
	end
	return true
end

return X
