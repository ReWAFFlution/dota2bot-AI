-- Score system and objective decisions.
--
-- Every bot earns points for what moves the game toward the enemy ancient and
-- loses points for what moves it away. Points are kept per team (one Lua VM
-- per team) and printed as [Score] lines.
--
-- They're also used to decide: a bot joins a push or a tower defense when the
-- points the team expects to gain from its help are worth more than what it
-- earns meanwhile (its own point rate over the last 3 minutes x travel time).
-- An idle bot (low rate, -points for inactivity) is the cheapest helper, so it
-- goes first; a carry on a big farm rate only comes when it really matters.

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local okRolesLib, HeroRolesLib = pcall(require, GetScriptDirectory()..'/FunLib/aba_hero_roles_map')
if not okRolesLib then HeroRolesLib = nil end

local X = {}

-- Points ----------------------------------------------------------------------
X.POINTS = {
	ancient = 1000,
	tower = { 40, 70, 110, 90 },   -- T1, T2, T3 (opens the base), T4
	barracks = 120,
	kill = 25, assist = 10,
	death = -25, deathPerMinute = -0.5, -- dying late costs more (long respawn, buyback)
	lastHit = 0.5, deny = 0.3,
	ward = 4,
	roshan = 80,
	idle = -5,                     -- per 15 s with no income while alive and healthy
	participation = 0.3,           -- share of a building's value for heroes that were there
	disable = 2,                   -- stun/root/hex/silence/sleep landed on an enemy hero
	harassPer100 = 0.25,           -- per 100 damage to an enemy hero (max 2 per second per bot)
	rune = { bounty = 3, power = 4, water = 1 },
	lotus = 3,
}

local UPDATE_GAP = 1
local RATE_WINDOW = 180
local ASSIGN_TIME = 20
local SCOREBOARD_GAP = 300

local TOWERS = {
	{ id = TOWER_TOP_1, lane = LANE_TOP, tier = 1 }, { id = TOWER_MID_1, lane = LANE_MID, tier = 1 }, { id = TOWER_BOT_1, lane = LANE_BOT, tier = 1 },
	{ id = TOWER_TOP_2, lane = LANE_TOP, tier = 2 }, { id = TOWER_MID_2, lane = LANE_MID, tier = 2 }, { id = TOWER_BOT_2, lane = LANE_BOT, tier = 2 },
	{ id = TOWER_TOP_3, lane = LANE_TOP, tier = 3 }, { id = TOWER_MID_3, lane = LANE_MID, tier = 3 }, { id = TOWER_BOT_3, lane = LANE_BOT, tier = 3 },
	{ id = TOWER_BASE_1, lane = LANE_MID, tier = 4 }, { id = TOWER_BASE_2, lane = LANE_MID, tier = 4 },
}

local function Log(msg) print('[Score] '..msg) end
local function ObjLog(msg) print('[Obj] '..msg) end
local function Dist(a, b) return (a - b):Length2D() end
local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function Stat(fn, pid)
	if type(fn) ~= 'function' then return 0 end
	local ok, v = pcall(fn, pid)
	return (ok and v) or 0
end

ObjectivesState = ObjectivesState or {}
local function State()
	local team = GetTeam()
	local S = ObjectivesState[team]
	if not S then
		S = { nextUpdate = -math.huge, team = 0, bots = {}, towers = {}, barracks = {}, wards = {},
		      assign = {}, objectives = {}, nextBoard = SCOREBOARD_GAP, roshanT = 0 }
		ObjectivesState[team] = S
	end
	return S
end

local function BotEntry(S, m)
	local pid = m:GetPlayerID()
	local e = S.bots[pid]
	if not e then
		e = { score = 0, kills = Stat(GetHeroKills, pid), deaths = Stat(GetHeroDeaths, pid),
		      assists = Stat(GetHeroAssists, pid), lh = Stat(GetHeroLastHits, pid), dn = Stat(GetHeroDenies, pid),
		      hist = {}, idleT = DotaTime(), nw = m:GetNetWorth(), name = m:GetUnitName() }
		S.bots[pid] = e
	end
	return e
end

local function Members()
	local list = {}
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if m and m:IsHero() and not m:IsIllusion() then table.insert(list, m) end
	end
	return list
end

local function Add(S, m, pts, why)
	local e = BotEntry(S, m)
	e.score = e.score + pts
	S.team = S.team + pts
	local quiet = why == 'harass' or why == 'last hits' or why == 'denies' or why == 'idle'
	if math.abs(pts) >= 20 or not quiet then Log(string.format('%s %+d (%s) = %d', e.name, pts, why, math.floor(e.score))) end
end

local function AddTeam(S, pts, why)
	S.team = S.team + pts
	Log(string.format('team %d %+d (%s) = %d', GetTeam(), pts, why, math.floor(S.team)))
end

-- Point rate of a bot (points per minute over the last 3 minutes).
function X.Rate(m)
	local S = State()
	local e = S.bots[m:GetPlayerID()]
	if not e or #e.hist == 0 then return 3 end
	local old = e.hist[1]
	local dt = DotaTime() - old.t
	if dt < 30 then return 3 end
	return math.max(1, (e.score - old.score) / (dt / 60))
end

function X.Score(m)
	local e = State().bots[m:GetPlayerID()]
	return e and e.score or 0
end

--------------------------------------------------------------------------------
-- Scoring
--------------------------------------------------------------------------------

local function HeroesNear(team, loc, r)
	local list = {}
	local lt = team == GetTeam() and UNIT_LIST_ALLIED_HEROES or UNIT_LIST_ENEMY_HEROES
	for _, h in pairs(GetUnitList(lt)) do
		if J.IsValidHero(h) and not h:IsIllusion() and not J.IsSuspiciousIllusion(h) and Dist(h:GetLocation(), loc) <= r then table.insert(list, h) end
	end
	return list
end

local function ScoreHeroes(S, t)
	for _, m in ipairs(Members()) do
		local pid = m:GetPlayerID()
		local e = BotEntry(S, m)
		local k, d, a = Stat(GetHeroKills, pid), Stat(GetHeroDeaths, pid), Stat(GetHeroAssists, pid)
		local lh, dn = Stat(GetHeroLastHits, pid), Stat(GetHeroDenies, pid)
		if k > e.kills then Add(S, m, (k - e.kills) * X.POINTS.kill, 'kill') end
		if a > e.assists then Add(S, m, (a - e.assists) * X.POINTS.assist, 'assist') end
		if d > e.deaths then Add(S, m, (d - e.deaths) * (X.POINTS.death + X.POINTS.deathPerMinute * t / 60), 'death') end
		if lh > e.lh then Add(S, m, (lh - e.lh) * X.POINTS.lastHit, 'last hits') end
		if dn > e.dn then Add(S, m, (dn - e.dn) * X.POINTS.deny, 'denies') end
		e.kills, e.deaths, e.assists, e.lh, e.dn = k, d, a, lh, dn

		-- Inactivity: alive, healthy, out of the fountain and no income.
		if t > 60 and t - e.idleT >= 15 then
			local nw = m:GetNetWorth()
			if m:IsAlive() and J.GetHP(m) > 0.7 and m:DistanceFromFountain() > 1500 and nw - e.nw < 25 then
				Add(S, m, X.POINTS.idle, 'idle')
			end
			e.nw, e.idleT = nw, t
		end

		-- History for the rate.
		table.insert(e.hist, { t = t, score = e.score })
		while #e.hist > 1 and t - e.hist[1].t > RATE_WINDOW do table.remove(e.hist, 1) end
	end
end

local function ScoreBuildings(S)
	for _, side in ipairs({ GetTeam(), GetOpposingTeam() }) do
		local ours = side == GetTeam()
		S.towers[side] = S.towers[side] or {}
		for _, info in ipairs(TOWERS) do
			local tw = GetTower(side, info.id)
			local key = info.id
			if tw then
				S.towers[side][key] = tw:GetLocation()
			elseif S.towers[side][key] then
				local loc = S.towers[side][key]
				local pts = X.POINTS.tower[info.tier]
				S.towers[side][key] = false
				if ours then
					AddTeam(S, -pts, 'lost our T'..info.tier)
				else
					AddTeam(S, pts, 'destroyed enemy T'..info.tier)
					for _, h in ipairs(HeroesNear(GetTeam(), loc, 1500)) do
						if h:IsBot() then Add(S, h, pts * X.POINTS.participation, 'took a T'..info.tier) end
					end
				end
			end
		end
		S.barracks[side] = S.barracks[side] or {}
		for b = 0, 5 do
			local br = GetBarracks and GetBarracks(side, b)
			if br then S.barracks[side][b] = true
			elseif S.barracks[side][b] then
				S.barracks[side][b] = false
				AddTeam(S, ours and -X.POINTS.barracks or X.POINTS.barracks, ours and 'lost barracks' or 'destroyed barracks')
			end
		end
	end
end

local function ScoreWards(S)
	for _, w in pairs(GetUnitList(UNIT_LIST_ALLIED_WARDS) or {}) do
		if w and not w:IsNull() and not S.wards[w] then
			S.wards[w] = true
			-- Credit the closest bot (the one that planted it).
			local best, bd = nil, 800
			for _, m in ipairs(Members()) do
				if m:IsAlive() and GetUnitToUnitDistance(m, w) < bd then best, bd = m, GetUnitToUnitDistance(m, w) end
			end
			if best then Add(S, best, X.POINTS.ward, 'ward') end
		end
	end
end

-- Disables and harass on visible enemy heroes. Credit goes to the bots that
-- damaged the enemy in the last second (or the closest bot for a disable
-- without damage, like a hex or a silence).
local function IsDisabled(h)
	return h:IsStunned() or h:IsRooted() or h:IsHexed() or h:IsSilenced() or h:IsNightmared()
end

local function ScoreFights(S, t)
	S.enemyHP = S.enemyHP or {}
	S.enemyDisabled = S.enemyDisabled or {}
	local bots = {}
	for _, m in ipairs(Members()) do if m:IsBot() and m:IsAlive() then table.insert(bots, m) end end
	for _, e in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(e) and not e:IsIllusion() then
			local pid = e:GetPlayerID()
			local dealers = {}
			for _, m in ipairs(bots) do
				if e:WasRecentlyDamagedByHero(m, 1.0) then table.insert(dealers, m) end
			end
			-- Harass: HP lost since the last update, split between the dealers.
			local hp = e:GetHealth()
			local last = S.enemyHP[pid]
			if last and last.t >= t - 1.5 and hp < last.hp and #dealers > 0 then
				local per = math.min(2, (last.hp - hp) / 100 * X.POINTS.harassPer100 / #dealers)
				for _, m in ipairs(dealers) do Add(S, m, per, 'harass') end
			end
			S.enemyHP[pid] = { hp = hp, t = t }
			-- Disable: newly disabled since the last update.
			local now = IsDisabled(e)
			if now and not S.enemyDisabled[pid] then
				local who = dealers
				if #who == 0 then
					local best, bd = nil, 1200
					for _, m in ipairs(bots) do
						local d = GetUnitToUnitDistance(m, e)
						if d < bd then best, bd = m, d end
					end
					who = best and { best } or {}
				end
				for _, m in ipairs(who) do Add(S, m, X.POINTS.disable / #who, 'disable on '..e:GetUnitName()) end
			end
			S.enemyDisabled[pid] = now
		end
	end
end

-- Runes: an available rune that disappears with one of our bots next to it.
local RUNES = { RUNE_BOUNTY_1, RUNE_BOUNTY_2, RUNE_BOUNTY_3, RUNE_BOUNTY_4, RUNE_POWERUP_1, RUNE_POWERUP_2 }
local function ScoreRunes(S)
	S.runes = S.runes or {}
	for _, r in ipairs(RUNES) do
		if r then
			local status = GetRuneStatus(r)
			local prev = S.runes[r]
			if status == RUNE_STATUS_AVAILABLE then
				S.runes[r] = { type = GetRuneType(r) }
			elseif prev and status ~= RUNE_STATUS_AVAILABLE then
				S.runes[r] = nil
				local loc = GetRuneSpawnLocation(r)
				for _, m in ipairs(Members()) do
					if m:IsBot() and m:IsAlive() and GetUnitToLocationDistance(m, loc) < 350 then
						local kind = prev.type == RUNE_BOUNTY and 'bounty' or (prev.type == RUNE_WATER and 'water' or 'power')
						Add(S, m, X.POINTS.rune[kind], kind..' rune')
						break
					end
				end
			end
		end
	end
end

-- Lotuses: more Healing Lotuses in the inventory than last time.
local function ScoreLotus(S)
	for _, m in ipairs(Members()) do
		if m:IsBot() then
			local e = BotEntry(S, m)
			local n = 0
			for _, name in ipairs({ 'item_famango', 'item_great_famango', 'item_greater_famango' }) do
				local slot = m:FindItemSlot(name)
				if slot >= 0 then
					local it = m:GetItemInSlot(slot)
					n = n + math.max(1, it and it:GetCurrentCharges() or 1)
				end
			end
			if e.lotus and n > e.lotus then Add(S, m, (n - e.lotus) * X.POINTS.lotus, 'lotus') end
			e.lotus = n
		end
	end
end

local function ScoreRoshan(S)
	local kt = GetRoshanKillTime and GetRoshanKillTime() or 0
	if kt and kt > S.roshanT then
		S.roshanT = kt
		local loc = J.GetCurrentRoshanLocation and J.GetCurrentRoshanLocation()
		if loc and #HeroesNear(GetTeam(), loc, 1800) > #HeroesNear(GetOpposingTeam(), loc, 1800) then
			AddTeam(S, X.POINTS.roshan, 'Roshan')
		end
	end
end

local function Scoreboard(S, t)
	if t < S.nextBoard then return end
	S.nextBoard = t + SCOREBOARD_GAP
	local parts = {}
	for _, m in ipairs(Members()) do
		local e = BotEntry(S, m)
		table.insert(parts, string.format('%s %d (%.1f/min)', string.gsub(e.name, 'npc_dota_hero_', ''), math.floor(e.score), X.Rate(m)))
	end
	Log(string.format('%d:%02d team %d: %d | %s', math.floor(t / 60), math.floor(t % 60), GetTeam(), math.floor(S.team), table.concat(parts, ', ')))
end

--------------------------------------------------------------------------------
-- Objectives: who joins a push / a defense
--------------------------------------------------------------------------------

local function GetNumAlive(team)
	local n = 0
	for _, pid in pairs(GetTeamPlayers(team)) do if IsHeroAlive(pid) then n = n + 1 end end
	return n
end

-- Chance a fight at the building goes our way with `a` of our heroes vs `e`.
local function WinChance(a, e) return Clamp(0.5 + 0.22 * (a - e), 0.05, 0.95) end

local function MissingEnemies()
	local n = 0
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(pid) then
			local info = GetHeroLastSeenInfo(pid)
			local d = info and info[1]
			if not d or d.time_since_seen > 5 then n = n + 1 end
		end
	end
	return n
end

local function TravelTime(m, loc)
	local d = GetUnitToLocationDistance(m, loc)
	local walk = d / math.max(250, m:GetCurrentMovementSpeed())
	local tp = m:FindItemSlot('item_tpscroll')
	if tp >= 0 and d > 5000 then
		local item = m:GetItemInSlot(tp)
		if item and item:IsFullyCastable() then return math.min(walk, 10) end
	end
	return walk
end

local function TowerHPTracker(S, key, tw, t)
	S.hp = S.hp or {}
	local h = S.hp[key]
	local hp = tw:GetHealth()
	if not h then h = { hp = hp, t = t, rate = 0 } S.hp[key] = h return h end
	local dt = t - h.t
	if dt > 0 then
		local r = math.max(0, (h.hp - hp) / dt)
		h.rate = h.rate * 0.6 + r * 0.4
	end
	h.hp, h.t = hp, t
	return h
end

-- The carry farms its own lane in the early game: it doesn't leave it to help.
-- Cores farm their own lane in the early game (carry until 14:00, mid and
-- offlane until 10:00): they don't leave it to help elsewhere.
function X.CoreLaneLocked(m)
	local pos = J.GetPosition(m)
	return (pos == 1 and DotaTime() < 14 * 60) or ((pos == 2 or pos == 3) and DotaTime() < 10 * 60)
end
local function CarryLocked(m, lane, kind, tier)
	if X.CoreLaneLocked(m) and lane ~= m:GetAssignedLane() then return true end
	-- The carry keeps farming instead of defending T1/T2 before 30:00, unless
	-- it's right there.
	if kind == 'defend' and J.GetPosition(m) == 1 and DotaTime() < 30 * 60 and (tier or 1) <= 2 then return true end
	return false
end

local function Candidates(S, loc, exclude, lane, kind, tier)
	local list = {}
	for _, m in ipairs(Members()) do
		if m:IsBot() and m:IsAlive() and J.GetHP(m) > 0.4 and not exclude[m] and not m:IsChanneling()
		and not (CarryLocked(m, lane, kind, tier) and GetUnitToLocationDistance(m, loc) > 2500) then
			table.insert(list, { m = m, travel = TravelTime(m, loc) })
		end
	end
	table.sort(list, function(a, b) return a.travel < b.travel end)
	return list
end

-- Adds helpers while each one is worth it. Returns the helpers.
local function PickHelpers(S, obj, taken, maxHelpers)
	local helpers = {}
	local a, e = obj.allies, obj.enemies
	for _, c in ipairs(Candidates(S, obj.loc, taken, obj.lane, obj.kind, obj.tier)) do
		if #helpers >= maxHelpers then break end
		if obj.ttd and c.travel > obj.ttd + 5 then break end -- too late to save it
		local near = GetUnitToLocationDistance(c.m, obj.loc) < 1200 or obj.ancient
		-- Not into a fight lost by strength, whatever the head count (Clockwerk
		-- teleported to defend a T1 against a far stronger Terrorblade).
		if not obj.ancient and obj.enemies > 0 and X.FightAt(obj.loc, c.m) < 0.8 then break end
		local gain = obj.value * (WinChance(a + 1, e) - WinChance(a, e)) + obj.value * WinChance(a + 1, e) * 0.15
		local cost = X.Rate(c.m) * c.travel / 60 + 2
		if near or gain > cost then
			table.insert(helpers, { m = c.m, gain = gain, cost = cost })
			if not near then a = a + 1 end
			if WinChance(a, e) >= obj.enough then break end
		end
	end
	return helpers
end

local function FindObjectives(S, t)
	local list = {}
	local missing = MissingEnemies()
	-- Enemy towers our heroes (bots or humans) are hitting.
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(GetOpposingTeam(), info.id)
		if tw then
			local hp = TowerHPTracker(S, 'e'..info.id, tw, t)
			local allies = HeroesNear(GetTeam(), tw:GetLocation(), 1000)
			if #allies > 0 and (hp.rate > 5 or tw:WasRecentlyDamagedByAnyHero(3)) then
				local enemies = #HeroesNear(GetOpposingTeam(), tw:GetLocation(), 2000) + missing * 0.4
				table.insert(list, { kind = 'push', lane = info.lane, tier = info.tier, loc = tw:GetLocation(),
					value = X.POINTS.tower[info.tier], allies = #allies, enemies = enemies, enough = 0.75,
					max = math.min(4, GetNumAlive(GetOpposingTeam()) + 1), name = 'enemy T'..info.tier })
			end
		end
	end
	-- Our ancient: everyone defends it (a base defense is the last one).
	local anc = GetAncient(GetTeam())
	if anc and anc:IsAlive() then
		local hp = TowerHPTracker(S, 'ancient', anc, t)
		local enemies = HeroesNear(GetOpposingTeam(), anc:GetLocation(), 1500)
		if hp.rate > 5 or #enemies > 0 then
			table.insert(list, { kind = 'defend', lane = LANE_MID, tier = 5, loc = anc:GetLocation(), tower = anc,
				value = X.POINTS.ancient, allies = #HeroesNear(GetTeam(), anc:GetLocation(), 1500) + 1.5, enemies = #enemies,
				ttd = 99, enough = 0.99, max = 5, name = 'our ancient', ancient = true })
		end
	end
	-- Our towers under attack.
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(GetTeam(), info.id)
		if tw then
			local hp = TowerHPTracker(S, 'o'..info.id, tw, t)
			local enemies = HeroesNear(GetOpposingTeam(), tw:GetLocation(), 1200)
			-- A real threat: the tower is losing HP, or an enemy hero is in its
			-- range. A hero farming near it isn't one (two enemy cores used to
			-- come and stand behind their tower while a human farmed nearby).
			local inRange = #HeroesNear(GetOpposingTeam(), tw:GetLocation(), 750) > 0
			if hp.rate > 5 or inRange then
				local allies = #HeroesNear(GetTeam(), tw:GetLocation(), 1300)
				local bonus = info.tier >= 3 and 1.5 or 1 -- the tower fights too
				local ttd = hp.rate > 1 and tw:GetHealth() / hp.rate or 60
				local creepsOnly = #enemies == 0
				table.insert(list, { kind = 'defend', lane = info.lane, tier = info.tier, loc = tw:GetLocation(), tower = tw,
					value = X.POINTS.tower[info.tier] * (creepsOnly and 0.3 or 1), allies = allies + bonus, enemies = #enemies,
					ttd = ttd, enough = 0.7, max = creepsOnly and 1 or math.min(4, #enemies + 1), name = 'our T'..info.tier })
			end
		end
	end
	return list
end

local function Assign(S, t)
	local objectives = FindObjectives(S, t)
	-- Defense first (losing a building is final), then the most valuable.
	table.sort(objectives, function(x, y)
		if x.kind ~= y.kind then return x.kind == 'defend' end
		return x.value > y.value
	end)
	local taken, newAssign = {}, {}
	-- Stay with an objective that's still on, unless a new one is worth 1.5x
	-- more (Dire's defenders ran back and forth between T3 and T4).
	local active = {}
	for _, obj in ipairs(objectives) do active[obj.name..obj.lane] = obj end
	for pid, a in pairs(S.assign) do
		local still = active[a.name..a.lane]
		if still and a.untilT > t then
			local better = false
			for _, obj in ipairs(objectives) do
				if obj.value > still.value * 1.5 then better = true end
			end
			if not better then
				for _, m in ipairs(Members()) do
					if m:GetPlayerID() == pid then taken[m] = true end
				end
				a.untilT = t + ASSIGN_TIME
				newAssign[pid] = a
			end
		end
	end
	for _, obj in ipairs(objectives) do
		local losing = obj.kind == 'defend' and not obj.ancient and obj.enemies > GetNumAlive(GetTeam()) + 1
		if not losing then
			for _, h in ipairs(PickHelpers(S, obj, taken, obj.max)) do
				taken[h.m] = true
				local pid = h.m:GetPlayerID()
				local old = S.assign[pid]
				if not old or old.name ~= obj.name or old.lane ~= obj.lane then
					ObjLog(string.format('%s -> %s %s (gain %.0f vs cost %.0f)', h.m:GetUnitName(),
						obj.kind == 'push' and 'push' or 'defend', obj.name..' lane '..obj.lane, h.gain, h.cost))
				end
				newAssign[pid] = { kind = obj.kind, lane = obj.lane, loc = obj.loc, tower = obj.tower, name = obj.name, untilT = t + ASSIGN_TIME }
			end
		end
	end
	-- Keep a recent assignment a little longer (no flip-flopping).
	for pid, a in pairs(S.assign) do
		if not newAssign[pid] and a.untilT > t then
			local tw = a.kind == 'defend' and a.tower
			if not tw or (not tw:IsNull() and tw:IsAlive()) then newAssign[pid] = a end
		end
	end
	S.assign = newAssign
end

function X.Update()
	local S = State()
	local t = DotaTime()
	if t < S.nextUpdate then return S end
	S.nextUpdate = t + UPDATE_GAP
	if t < 0 then return S end
	ScoreHeroes(S, t)
	ScoreBuildings(S)
	ScoreWards(S)
	ScoreRoshan(S)
	ScoreFights(S, t)
	ScoreRunes(S)
	ScoreLotus(S)
	Scoreboard(S, t)
	Assign(S, t)
	return S
end

function X.Assignment(bot)
	local S = X.Update()
	local a = S.assign[bot:GetPlayerID()]
	if a and a.untilT > DotaTime() then return a end
	return nil
end

-- Idle: alive, healthy, out of the fountain, no income for 20 s and not
-- moving anywhere (pacing by a rune or a watcher). Rune/outpost/ward/watcher
-- modes switch off for an idle bot so it goes farming or back to its lane.
function X.IsIdle(bot)
	local t = DotaTime()
	if t < 60 or not bot:IsAlive() then return false end
	local h = bot._idleHist
	if not h or t - h.t > 20 then
		local idle = h and (bot:GetNetWorth() - h.nw < 30) and GetUnitToLocationDistance(bot, h.loc) < 900
			and J.GetHP(bot) > 0.6 and bot:DistanceFromFountain() > 1500
		bot._idleHist = { t = t, nw = bot:GetNetWorth(), loc = bot:GetLocation() }
		bot._idleNow = idle or false
		if idle then print('[Score] '..bot:GetUnitName()..' was idle for 20 s, back to farming') end
	end
	return bot._idleNow == true
end

-- The combat evaluation says leave: a push (or tower hit) waits. Medusa hit a
-- tower inside MK's arena with his team around because the push desire beat
-- the retreat hint.
--------------------------------------------------------------------------------
-- Retreat: where to step
--------------------------------------------------------------------------------
-- The default retreat walked straight to the fountain past the enemies. The
-- bot heads for its closest tower that's further from the enemies than it is
-- (else the fountain), bending away from enemies within 1300.
function X.RetreatStep(bot)
	local myLoc = bot:GetLocation()
	local fountain = J.GetTeamFountain()
	local enemies = HeroesNear(GetOpposingTeam(), myLoc, 1300)
	local goal, bestD = fountain, math.huge
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(GetTeam(), info.id)
		if tw then
			local tl = tw:GetLocation()
			local d = Dist(tl, myLoc)
			local safer = Dist(tl, fountain) < Dist(myLoc, fountain) + 300
			for _, e in ipairs(enemies) do
				if Dist(e:GetLocation(), tl) < d then safer = false end -- they're between us and it
			end
			if safer and d < bestD and d > 300 then goal, bestD = tl, d end
		end
	end
	local dir = goal - myLoc
	if dir:Length2D() < 1 then return goal end
	dir = dir / dir:Length2D()
	local away = Vector(0, 0, 0)
	for _, e in ipairs(enemies) do
		local v = myLoc - e:GetLocation()
		local d = v:Length2D()
		if d > 1 then away = away + v / d * ((1300 - d) / 1300) end
	end
	local step = dir + away * 0.8
	if step:Length2D() < 0.1 then step = dir end
	step = step / step:Length2D()
	local loc = myLoc + step * 500
	if not IsLocationPassable(loc) then loc = myLoc + dir * 500 end
	return loc
end

-- Is a teleport home safe now? Damage doesn't cancel the channel (~3 s),
-- disables do, and dying does. Unsafe when an enemy with a disable (role
-- table) seen in the last 2 s can get within ~800 of the bot before the
-- channel ends (not counted while the bot is magic immune), or when the
-- enemies around can kill it before then. Next to our own tower it's fine.
local TP_CHANNEL = 3.0
local DISABLE_RANGE = 800
function X.SafeToTeleport(bot)
	local myLoc = bot:GetLocation()
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(GetTeam(), info.id)
		if tw and Dist(tw:GetLocation(), myLoc) < 500 then return true end
	end
	local immune = bot:HasModifier('modifier_black_king_bar_immune') or (bot.IsMagicImmune and bot:IsMagicImmune())
	local visible = {}
	for _, e in ipairs(HeroesNear(GetOpposingTeam(), myLoc, 2500)) do visible[e:GetPlayerID()] = e end
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(pid) then
			local info = GetHeroLastSeenInfo(pid)
			local d = info and info[1]
			if d and d.time_since_seen < 2 then
				local unit = visible[pid]
				local name = unit and unit:GetUnitName() or GetSelectedHeroName(pid)
				local disabler = HeroRolesLib and HeroRolesLib.IsDisabler and name and HeroRolesLib.IsDisabler(name)
				local ms = 320
				if unit then pcall(function() ms = unit:GetCurrentMovementSpeed() end) end
				local reachIn = math.max(0, Dist(d.location, myLoc) - DISABLE_RANGE) / math.max(200, ms)
				if disabler and not immune and reachIn < TP_CHANNEL then return false end
			end
		end
	end
	-- They'd kill us before we're gone.
	local near = HeroesNear(GetOpposingTeam(), myLoc, 1600)
	if #near > 0 and X._Burst and X._Burst(near, bot, TP_CHANNEL, false) >= bot:GetHealth() then return false end
	return true
end

-- The same when it says fight: heroes first, buildings after (SF hit a T4
-- he couldn't take while enemies he could kill stood around him).
function X.CapPushWhenLosing(bot, desire)
	local c = bot._combat
	if c and (c.retreat or (c.go and J.IsValidHero(c.target))) and DotaTime() - (bot._fightHintT or -math.huge) < 1.5 then
		return math.min(desire, 0.3)
	end
	return desire
end

-- For the push wrappers: max with the normal desire.
function X.PushDesire(bot, lane)
	local a = X.Assignment(bot)
	if a and a.kind == 'push' and a.lane == lane then return 0.82 end
	return 0
end

-- Our first standing tower on a lane and its tier (nil past T3).
function X.OwnLaneTower(lane)
	for tier = 1, 3 do
		for _, info in ipairs(TOWERS) do
			if info.lane == lane and info.tier == tier then
				local tw = GetTower(GetTeam(), info.id)
				if tw then return tw, tier end
			end
		end
	end
	return nil, 4
end

-- The default defend desire, minus what a core shouldn't do: the carry keeps
-- farming instead of walking across the map for a T1/T2 before 30:00, and no
-- core leaves its lane for another lane in the early game.
-- Tower under real threat: losing HP, or an enemy hero in its range.
function X.TowerThreatened(tw)
	if not tw then return false end
	for _, info in ipairs(TOWERS) do
		if GetTower(GetTeam(), info.id) == tw then
			local h = State().hp and State().hp['o'..info.id]
			if h ~= nil and h.rate > 5 then return true end
		end
	end
	return #HeroesNear(GetOpposingTeam(), tw:GetLocation(), 750) > 0
end

function X.FilterDefendDesire(bot, lane, desire)
	if desire <= 0 then return desire end
	local tw, tier = X.OwnLaneTower(lane)
	-- Nobody hits the tower: no standing guard at T1/T2.
	if tw and tier <= 2 and not X.TowerThreatened(tw) then return math.min(desire, 0.2) end
	local far = not tw or GetUnitToUnitDistance(bot, tw) > 2500
	if far and X.CoreLaneLocked(bot) and lane ~= bot:GetAssignedLane() and tier <= 2 then return math.min(desire, 0.1) end
	if far and J.GetPosition(bot) == 1 and DotaTime() < 30 * 60 and tier <= 2 then return math.min(desire, 0.2) end
	return desire
end

-- For the defend wrappers.
function X.DefendDesire(bot, lane)
	local a = X.Assignment(bot)
	if a and a.kind == 'defend' and a.lane == lane then return 0.88 end
	return 0
end

--------------------------------------------------------------------------------
-- Fight value: is it worth fighting `target` here, now and for what follows?
--------------------------------------------------------------------------------
-- EV (points) = P(kill) x (kill points + what the kill opens: the enemy's
-- respawn time x our team's point rate, plus a nearby enemy building we can
-- take) - P(we die) x (death points + our respawn time x our own rate, plus a
-- nearby own building they can take). Used by harass, ganks, hunts, the
-- defense and the retreat hint.

local function Respawn(level) return 6 + 2.2 * (level or 1) end

local function TeamRate()
	local sum = 0
	for _, m in ipairs(Members()) do sum = sum + X.Rate(m) end
	return sum
end

local function BuildingNear(team, loc, r)
	local best, bd = nil, r
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(team, info.id)
		if tw then
			local d = Dist(tw:GetLocation(), loc)
			if d < bd then best, bd = info, d end
		end
	end
	return best, bd
end

-- Returns ev, pKill, pDeath.
function X.FightValue(bot, target)
	if not J.IsValidHero(target) then return 0, 0, 0 end
	local tloc = target:GetLocation()
	local allies = HeroesNear(GetTeam(), tloc, 1300)
	local enemies = HeroesNear(GetOpposingTeam(), bot:GetLocation(), 1300)
	local seenBot = false
	for _, a in ipairs(allies) do if a == bot then seenBot = true end end
	if not seenBot then table.insert(allies, bot) end

	-- Our burst on the target in ~4 s, against its health (more for escapes).
	local dmg = 0
	for _, a in ipairs(allies) do
		local ok, d = pcall(function() return a:GetEstimatedDamageToTarget(true, target, 4.0, DAMAGE_TYPE_ALL) end)
		if ok and d then dmg = dmg + d end
	end
	local need = target:GetHealth() * 1.15
	local pKill = Clamp((dmg / math.max(1, need) - 0.6) / 0.8, 0, 1)

	-- Their burst on us, split over our heroes there; their tower adds up.
	local edmg = 0
	for _, e in ipairs(enemies) do
		local ok, d = pcall(function() return e:GetEstimatedDamageToTarget(true, bot, 4.0, DAMAGE_TYPE_ALL) end)
		if ok and d then edmg = edmg + d end
	end
	local eTower, eTowerDist = BuildingNear(GetOpposingTeam(), bot:GetLocation(), 850)
	if eTower then edmg = edmg + 600 end
	edmg = edmg / math.sqrt(#allies)
	local pDeath = Clamp((edmg / math.max(1, bot:GetHealth()) - 0.5) / 0.8, 0, 1)

	local t = DotaTime()
	local rate = TeamRate()
	local killValue = X.POINTS.kill + Respawn(target:GetLevel()) / 60 * rate * 0.5
	local eb = BuildingNear(GetOpposingTeam(), tloc, 3000)
	if eb then killValue = killValue + X.POINTS.tower[eb.tier] * 0.35 * math.min(1, #allies / 3) end
	local deathCost = -X.POINTS.death - X.POINTS.deathPerMinute * t / 60 + Respawn(bot:GetLevel()) / 60 * (X.Rate(bot) + rate * 0.3)
	local ob = BuildingNear(GetTeam(), bot:GetLocation(), 3000)
	if ob then deathCost = deathCost + X.POINTS.tower[ob.tier] * 0.25 end

	local ev = pKill * killValue - pDeath * deathCost
	return ev, pKill, pDeath
end

--------------------------------------------------------------------------------
-- Combat: time to kill, both ways (the bot's "chess" evaluation)
--------------------------------------------------------------------------------
-- The engine's GetEstimatedDamageToTarget(true, ...) counts only what's ready
-- now: spells off cooldown with the mana for them, items, attacks. From it:
--   ttkUs(target): first second (1..6) when our heroes near the target
--     out-damage its HP (x1.5 if it has an escape), one second sooner per ready
--     stun among them;
--   ttkThem(bot): the same for the enemies near the bot (plus their tower);
--     the bot's ready escape (Blink, Force Staff, Glimmer...) adds 40% to its
--     HP, a ready BKB cuts their magic damage.
-- Go when we kill first within 4 s; retreat when they kill us first, or
-- within 3 s while we can't kill anyone.

local ESCAPES = { 'item_blink', 'item_overwhelming_blink', 'item_swift_blink', 'item_arcane_blink', 'item_force_staff',
	'item_hurricane_pike', 'item_glimmer_cape', 'item_ghost', 'item_cyclone', 'item_wind_waker', 'item_manta' }

local function ItemReady(u, name)
	local slot = u:FindItemSlot(name)
	if slot < 0 or slot > 5 then return false end
	local it = u:GetItemInSlot(slot)
	return it ~= nil and it:IsFullyCastable()
end

-- Damage the engine's estimate leaves out: summons and channels (WD's Death
-- Ward made WD think he couldn't finish an almost dead Terrorblade). Damage
-- per second by ability level, while the ability is learned and ready.
local SUMMON_DPS = {
	{ name = 'witch_doctor_death_ward', dps = { 260, 380, 500 }, maxSecs = 8 },
	{ name = 'jakiro_macropyre', dps = { 100, 140, 180 }, maxSecs = 8 },
	{ name = 'crystal_maiden_freezing_field', dps = { 150, 220, 290 }, maxSecs = 10 },
	{ name = 'enigma_black_hole', dps = { 100, 150, 200 }, maxSecs = 4 },
	{ name = 'shadow_shaman_mass_serpent_ward', dps = { 140, 200, 260 }, maxSecs = 10 },
}
local function SummonDamage(u, secs)
	local total = 0
	for _, sd in ipairs(SUMMON_DPS) do
		local ok, extra = pcall(function()
			local ab = u:GetAbilityByName(sd.name)
			if not ab or ab:GetLevel() <= 0 then return 0 end
			local ready = true
			pcall(function() ready = ab:GetCooldownTimeRemaining() <= 0 and u:GetMana() >= ab:GetManaCost() end)
			if not ready then return 0 end
			local lvl = math.min(#sd.dps, ab:GetLevel())
			return sd.dps[lvl] * math.min(secs, sd.maxSecs)
		end)
		if ok and extra then total = total + extra end
	end
	return total
end

local function Burst(dealers, victim, secs, magicCut)
	local d = 0
	for _, u in ipairs(dealers) do
		local ok, v = pcall(function() return u:GetEstimatedDamageToTarget(true, victim, secs, DAMAGE_TYPE_ALL) end)
		if ok and v then v = v + SummonDamage(u, secs) end
		if ok and v then
			if magicCut then
				local ok2, mag = pcall(function() return u:GetEstimatedDamageToTarget(true, victim, secs, DAMAGE_TYPE_MAGICAL) end)
				if ok2 and mag then v = v - mag * 0.75 end
			end
			d = d + math.max(0, v)
		end
	end
	return d
end
X._Burst = Burst

local function ReadyStuns(units)
	local n = 0
	for _, u in ipairs(units) do
		if HeroRolesLib and HeroRolesLib.IsDisabler and HeroRolesLib.IsDisabler(u:GetUnitName()) and J.GetMP(u) > 0.2 then n = n + 1 end
	end
	return n
end

-- A second life: Wraith King's Reincarnation ready (its cooldown is read when
-- the engine allows, else assumed ready from level 6) or the Aegis.
local function ExtraLife(victim)
	if victim:HasModifier('modifier_aegis_regen') or (victim.FindItemSlot and victim:FindItemSlot('item_aegis') >= 0) then
		return victim:GetMaxHealth()
	end
	if victim:GetUnitName() == 'npc_dota_hero_skeleton_king' then
		local ready = nil
		pcall(function()
			local ab = victim:GetAbilityByName('skeleton_king_reincarnation')
			if ab then ready = ab:GetLevel() > 0 and ab:GetCooldownTimeRemaining() <= 0 end
		end)
		if ready == nil then ready = victim:GetLevel() >= 6 end
		if ready then return victim:GetMaxHealth() end
	end
	return 0
end
X.ExtraLife = ExtraLife

-- Mana that soaks damage (Medusa's Mana Shield: ~2.5 damage per mana), plus
-- a second life.
local function ShieldHP(victim)
	local extra = ExtraLife(victim)
	if victim:HasModifier('modifier_medusa_mana_shield') or victim:GetUnitName() == 'npc_dota_hero_medusa' then
		local ok, mana = pcall(function() return victim:GetMana() end)
		if ok and mana then return extra + mana * 2.5 end
	end
	return extra
end
X.ShieldHP = ShieldHP

-- Team strength helpers: 4 s of ready damage per hero on the average
-- enemy, and total HP (shields and extra lives included).
local function TeamPower(dealers, victims)
	local sum = 0
	for _, d in ipairs(dealers) do
		local per = 0
		for _, v in ipairs(victims) do per = per + Burst({ d }, v, 4, false) end
		sum = sum + per / math.max(1, #victims)
	end
	return sum
end
local function TeamHP(units)
	local sum = 0
	for _, u in ipairs(units) do sum = sum + u:GetHealth() + ShieldHP(u) end
	return math.max(1, sum)
end

-- Who wins a fight at `loc` if `extra` joins: our burn rate over theirs (>1
-- we win). 99 with no enemy there.
function X.FightAt(loc, extra)
	local allies = HeroesNear(GetTeam(), loc, 1500)
	if extra then
		local has = false
		for _, a in ipairs(allies) do if a == extra then has = true end end
		if not has then table.insert(allies, extra) end
	end
	local enemies = HeroesNear(GetOpposingTeam(), loc, 1500)
	if #enemies == 0 then return 99 end
	if #allies == 0 then return 0 end
	local ours = TeamPower(allies, enemies) / TeamHP(enemies)
	local theirs = TeamPower(enemies, allies) / TeamHP(allies)
	return ours / math.max(0.0001, theirs)
end

local function TimeToKill(dealers, victim, extraHP, extraDps, magicCut, stuns, share, stunnedFor)
	if #dealers == 0 and (extraDps or 0) == 0 then return 99 end
	share = share or 1
	stunnedFor = stunnedFor or 0 -- seconds the dealers spend disabled by us
	local hp = victim:GetHealth() + (extraHP or 0) + ShieldHP(victim)
	local regen = 0
	pcall(function() regen = victim:GetHealthRegen() end)
	for s = 1, 6 do
		local window = math.max(0, s + math.min(stuns or 0, 2) - stunnedFor)
		if Burst(dealers, victim, window, magicCut) * share + (extraDps or 0) * s >= hp + regen * s then return s end
	end
	return 99
end

function X.Combat(bot)
	if not bot:IsAlive() then return nil end
	local myLoc = bot:GetLocation()
	local enemies = HeroesNear(GetOpposingTeam(), myLoc, 1400)
	if #enemies == 0 then return nil end
	local allies = HeroesNear(GetTeam(), myLoc, 1400)
	local hasBot = false
	for _, a in ipairs(allies) do if a == bot then hasBot = true end end
	if not hasBot then table.insert(allies, bot) end

	-- Their time to kill us. They don't all hit the same hero when we're
	-- several: their damage on the bot is split (1/sqrt of our heroes here).
	-- Assuming everybody focuses this one bot made every bot in a 4v4 think
	-- it dies in a second, and the whole team backed off with a big lead.
	local escape = false
	for _, n in ipairs(ESCAPES) do if ItemReady(bot, n) then escape = true break end end
	local bkb = ItemReady(bot, 'item_black_king_bar')
	local tower = BuildingNear(GetOpposingTeam(), myLoc, 750)
	local share = 1 / math.sqrt(#allies)
	-- Their fountain shreds anyone in its range (allies died chasing into it).
	local enemyFountain = J.GetEnemyFountain and J.GetEnemyFountain() or GetAncient(GetOpposingTeam()):GetLocation()
	local nearFountain = Dist(myLoc, enemyFountain) < 1500
	local extraDps = (tower and 150 or 0) + (nearFountain and 900 or 0)
	-- Our ready disables keep them from hitting for a while (WD's Cask chain on
	-- Terrorblade: he can't use his Metamorphosis damage while stunned).
	local ourStuns = math.min(ReadyStuns(allies), 2) * 1.2
	local ttkThem = TimeToKill(enemies, bot, escape and bot:GetHealth() * 0.4 or 0, extraDps, bkb, ReadyStuns(enemies), share, ourStuns)

	-- Team exchange: how fast each group burns the other's total HP (4 s of
	-- ready damage, each hero on the average enemy). > 1: we win the fight.
	local Power, TotalHP = TeamPower, TeamHP
	local ourRate = Power(allies, enemies) / TotalHP(enemies)
	local theirRate = Power(enemies, allies) / TotalHP(allies)
	-- Who else may join. Enemies seen near here in the last 10 s but in the
	-- fog now count almost fully; enemies unseen for longer a little (they
	-- may come). Our heroes 1400-3000 away (a human too) are on their way and
	-- count half. (A fight taken 4v2 on what was visible turned out 4v4,
	-- without the human who was a bit further.)
	local visible = {}
	for _, e in ipairs(enemies) do visible[e:GetPlayerID()] = true end
	local ghosts, farMissing = 0, 0
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(pid) and not visible[pid] then
			local info = GetHeroLastSeenInfo(pid)
			local d = info and info[1]
			if d and d.time_since_seen < 10 and Dist(d.location, myLoc) < 3000 then
				ghosts = ghosts + 1
			elseif not d or d.time_since_seen >= 10 then
				farMissing = farMissing + 1
			end
		end
	end
	local arriving = 0
	for _, a in ipairs(HeroesNear(GetTeam(), myLoc, 3000)) do
		if Dist(a:GetLocation(), myLoc) > 1400 then arriving = arriving + 1 end
	end
	theirRate = theirRate * (1 + (ghosts * 0.9 + farMissing * 0.25) / math.max(1, #enemies))
	ourRate = ourRate * (1 + 0.5 * arriving / math.max(1, #allies))
	local teamRatio = ourRate / math.max(0.0001, theirRate)

	-- Our fastest kill among them.
	local best, bestT = nil, 99
	for _, e in ipairs(enemies) do
		-- Not a target next to their fountain: chasing there kills us.
		if J.CanBeAttacked(e) and Dist(e:GetLocation(), enemyFountain) > 1700 then
			local helpers = HeroesNear(GetTeam(), e:GetLocation(), 1300)
			local mine = false
			for _, a in ipairs(helpers) do if a == bot then mine = true end end
			if not mine then table.insert(helpers, bot) end
			local extra = (HeroRolesLib and HeroRolesLib.HasEscape and HeroRolesLib.HasEscape(e:GetUnitName())) and e:GetHealth() * 0.5 or 0
			local ourFountainDps = Dist(e:GetLocation(), J.GetTeamFountain()) < 1500 and 900 or 0 -- our fountain hits them
			local tt = TimeToKill(helpers, e, extra, ourFountainDps, false, ReadyStuns(helpers))
			-- Finishing blow: a target with a few hits of HP left, right next to
			-- us, is a kill whatever the engine's estimate says.
			local reach = 400
			pcall(function() reach = bot:GetAttackRange() + 400 end)
			local hits = 3
			pcall(function() hits = e:GetHealth() / math.max(1, bot:GetAttackDamage()) end)
			if Dist(e:GetLocation(), myLoc) < reach and (e:GetHealth() < 250 or hits <= 3) and ShieldHP(e) == 0 then
				tt = math.min(tt, 2)
			end
			if tt < bestT or (tt == bestT and best and e:GetHealth() < best:GetHealth()) then best, bestT = e, tt end
		end
	end
	local noTarget = best == nil
	if not best then best = enemies[1] end

	local c = { target = best, ttkUs = bestT, ttkThem = ttkThem, teamRatio = teamRatio, ghosts = ghosts, arriving = arriving }
	local hp = J.GetHP(bot)
	local teamWins = teamRatio >= 1.2
	-- A tie goes to us: we strike first (finishing an almost dead hero).
	c.go = J.GetHP(bot) > 0.3 and ((bestT <= 4 and bestT <= ttkThem) or (teamWins and bestT <= 6))
	c.retreat = (ttkThem <= 1.5 and hp < 0.4)
		or (not teamWins and ((ttkThem < bestT and ttkThem <= 4) or (ttkThem <= 3 and bestT >= 99)))
	-- Pushing the win (team plan "finish"): only a real personal danger.
	local S = TeamPlanState and TeamPlanState[GetTeam()]
	if S and S.phase == 'finish' and not (ttkThem <= 1.5 and hp < 0.35) and teamRatio >= 0.6 then c.retreat = false end
	-- Last stand: enemies at our ancient. Leaving only when about to die.
	local ourAnc = GetAncient(GetTeam())
	if ourAnc and #HeroesNear(GetOpposingTeam(), ourAnc:GetLocation(), 1800) > 0 and Dist(myLoc, ourAnc:GetLocation()) < 3500 then
		c.lastStand = true
		c.retreat = ttkThem <= 1.5 and hp < 0.3
		if not c.retreat and best and not noTarget then c.go = true end
	end
	-- No target outside their fountain: nothing to chase.
	if noTarget then c.go = false end
	if nearFountain and #enemies > 0 then c.go, c.retreat = false, true end
	-- An enemy right next to us: decide (fight or leave), never keep farming
	-- creeps in between (MK hit creeps with enemies around in their base).
	if not c.go and not c.retreat then
		local close = false
		for _, e in ipairs(enemies) do if Dist(e:GetLocation(), myLoc) < 900 then close = true end end
		if close then
			if teamRatio >= 1.0 and not noTarget and hp > 0.35 then c.go = true else c.retreat = true end
		end
	end
	-- Medusa's health is her mana: low on mana near enemies, step back.
	if bot:GetUnitName() == 'npc_dota_hero_medusa' and J.GetMP(bot) < 0.25 then
		c.retreat, c.go = true, false
	end
	return c
end

-- Best enemy to fight around the bot: highest EV.
function X.BestFight(bot, radius)
	local best, bestEV, bk, bd = nil, -math.huge, 0, 0
	for _, e in ipairs(HeroesNear(GetOpposingTeam(), bot:GetLocation(), radius or 1200)) do
		if J.CanBeAttacked(e) then
			local ev, pk, pd = X.FightValue(bot, e)
			if ev > bestEV then best, bestEV, bk, bd = e, ev, pk, pd end
		end
	end
	return best, bestEV, bk, bd
end

-- Supports (and anyone below 60% HP) alone on the enemy half: no ally hero
-- within 1600, and either 3+ enemies not seen for 5 s or 2+ enemies close.
function X.LoneDanger(bot)
	if J.GetPosition(bot) < 4 and J.GetHP(bot) > 0.6 then return false end
	if DotaTime() < 60 or bot:DistanceFromFountain() < 3000 then return false end
	if GetUnitToLocationDistance(bot, GetAncient(GetTeam()):GetLocation()) < 4000 then return false end
	-- In its own lane during the laning stage: that's where it should be.
	if J.IsInLaningPhase() and GetUnitToLocationDistance(bot, GetLaneFrontLocation(GetTeam(), bot:GetAssignedLane(), 0)) < 1500 then return false end
	local enemyFountain = J.GetEnemyFountain and J.GetEnemyFountain() or GetAncient(GetOpposingTeam()):GetLocation()
	if GetUnitToLocationDistance(bot, enemyFountain) > GetUnitToLocationDistance(bot, J.GetTeamFountain()) - 1500 then return false end
	for _, a in ipairs(HeroesNear(GetTeam(), bot:GetLocation(), 1600)) do
		if a ~= bot then return false end
	end
	if #HeroesNear(GetOpposingTeam(), bot:GetLocation(), 1600) >= 2 then return true end
	return MissingEnemies() >= 3
end

-- Is it safe for `bot` to walk to `loc` (a ward spot) alone? On the enemy half
-- only when nearly every enemy is visible or an ally is there, and never
-- where an enemy was just seen.
function X.SafeSpot(bot, loc)
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(pid) then
			local info = GetHeroLastSeenInfo(pid)
			local d = info and info[1]
			if d and d.time_since_seen < 5 and Dist(d.location, loc) < 1400 then return false end
		end
	end
	local enemyFountain = J.GetEnemyFountain and J.GetEnemyFountain() or GetAncient(GetOpposingTeam()):GetLocation()
	local enemySide = Dist(loc, enemyFountain) < Dist(loc, J.GetTeamFountain()) - 1500
	if not enemySide or J.IsRealInvisible and J.IsRealInvisible(bot) then return true end
	for _, a in ipairs(HeroesNear(GetTeam(), loc, 1600)) do
		if a ~= bot then return true end
	end
	return MissingEnemies() <= 1
end

-- For mode_retreat_generic: back off from a fight that costs more than it
-- brings; commit (spells on the target) to one that clearly pays off.
function X.FightHint(bot)
	local t = DotaTime()
	if t < 0 or not bot:IsAlive() then return 0 end

	-- Burst: lost 30%+ of max HP in the last 1.5 s and below 55% -> leave now,
	-- unless the target is about to die. Checked every frame (no throttle).
	bot._hpHist = bot._hpHist or {}
	table.insert(bot._hpHist, { t = t, hp = J.GetHP(bot) })
	while #bot._hpHist > 1 and t - bot._hpHist[1].t > 1.5 do table.remove(bot._hpHist, 1) end
	local lost = bot._hpHist[1].hp - J.GetHP(bot)
	local TS = TeamPlanState and TeamPlanState[GetTeam()]
	local finishing = TS and TS.phase == 'finish' and J.GetHP(bot) > 0.35
	-- Defending our ancient: hold unless nearly dead.
	local ourAnc = GetAncient(GetTeam())
	if ourAnc and J.GetHP(bot) > 0.3 and GetUnitToLocationDistance(bot, ourAnc:GetLocation()) < 3500
	and #HeroesNear(GetOpposingTeam(), ourAnc:GetLocation(), 1800) > 0 then
		finishing = true
	end
	if lost > 0.3 and J.GetHP(bot) < 0.55 and not finishing then
		local target = J.GetProperTarget and J.GetProperTarget(bot)
		local finishing = J.IsValidHero(target) and J.GetHP(target) < 0.2 and GetUnitToUnitDistance(bot, target) < 600
		if not finishing then
			if not bot._burstLogT or t - bot._burstLogT > 5 then
				bot._burstLogT = t
				print(string.format('[Fight] %s took %.0f%% HP in 1.5 s, getting out', bot:GetUnitName(), lost * 100))
			end
			bot._fightHint, bot._fightHintT = 0.95, t + 1.0
			return 0.95
		end
	end

	if (bot._fightHintT or -math.huge) > t then return bot._fightHint or 0 end
	bot._fightHintT = t + 0.5
	bot._fightHint = 0
	-- A support alone deep on the enemy side while enemies are unaccounted
	-- for walks back toward the team instead of feeding.
	if X.LoneDanger(bot) and not finishing then
		if not bot._loneLogT or t - bot._loneLogT > 15 then
			bot._loneLogT = t
			print('[Fight] '..bot:GetUnitName()..' is alone on the enemy side, falling back to the team')
		end
		bot._fightHint = 0.75
		return bot._fightHint
	end
	-- Exchange: who kills whom first (X.Combat), then the long-term value.
	local c = X.Combat(bot)
	bot._combat = c
	if not c then return 0 end
	local target, ttkUs, ttkThem = c.target, c.ttkUs, c.ttkThem
	local ev = X.FightValue(bot, target)
	-- In lane, enemies standing nearby is normal: back off only when they're
	-- actually hitting us or could kill us very fast.
	local laneCalm = J.IsInLaningPhase() and not bot:WasRecentlyDamagedByAnyHero(2.0) and J.GetHP(bot) > 0.5 and ttkThem > 3
	local function Say(what)
		if not bot._fightLogT or t - bot._fightLogT > 8 then
			bot._fightLogT = t
			print(string.format('[Fight] %s %s %s (we kill in %.1f s, they kill us in %.1f s, team x%.2f, unseen enemies %d, allies coming %d, value %.0f)',
				bot:GetUnitName(), what, target:GetUnitName(), ttkUs, ttkThem, c.teamRatio or 0, c.ghosts or 0, c.arriving or 0, ev))
		end
	end
	-- Commitment: a decision holds for a while (retreat 3 s, fight 2 s) so the
	-- bot doesn't turn around every half second as the numbers wobble (Sniper
	-- kept turning back and taking hits). A fight is dropped early only when
	-- the bot is about to die.
	local d = bot._decision
	if d and d.untilT > t then
		if d.kind == 'retreat' then c.retreat, c.go = true, false
		elseif d.kind == 'go' and not (ttkThem <= 1.5) then c.go, c.retreat = true, false end
	end
	if c.retreat and not laneCalm then
		Say('backs off from')
		if not (d and d.kind == 'retreat' and d.untilT > t) then bot._decision = { kind = 'retreat', untilT = t + 3 } end
		bot._fightHint = ttkThem < 2.5 and 0.95 or 0.9
	elseif c.go and ev > -5 and J.IsValidHero(target) then
		Say('goes for')
		if not (d and d.kind == 'go' and d.untilT > t) then bot._decision = { kind = 'go', untilT = t + 2 } end
		bot.forceFightUntil = t + 2.0 -- spells on the target
		bot:SetTarget(target)
	end
	return bot._fightHint
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

-- Teleport to our building closest to `loc` when that saves a long walk.
local function TryTP(bot, loc)
	if X.CoreLaneLocked(bot) then return false end
	if J.GetPosition(bot) >= 4 and DotaTime() < 15 * 60 then return false end -- walk: the lane partner stays
	if #J.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE) > 0 then return false end
	local slot = bot:FindItemSlot('item_tpscroll')
	if slot < 0 then return false end
	local item = bot:GetItemInSlot(slot)
	if not item or not item:IsFullyCastable() then return false end
	local myDist = GetUnitToLocationDistance(bot, loc)
	if myDist < 5000 then return false end
	local best, bd = nil, math.huge
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(GetTeam(), info.id)
		if tw then
			local d = Dist(tw:GetLocation(), loc)
			if d < bd then best, bd = tw, d end
		end
	end
	if best and bd < myDist - 3500 then
		bot:Action_UseAbilityOnLocation(item, best:GetLocation())
		ObjLog(bot:GetUnitName()..' teleports to help')
		return true
	end
	return false
end

-- Push helpers: get there (TP if far); the push mode does the rest.
function X.PushThink(bot, lane)
	local a = X.Assignment(bot)
	if not a or a.kind ~= 'push' or a.lane ~= lane then return false end
	if J.CanNotUseAction(bot) or bot:IsChanneling() then return true end
	if GetUnitToLocationDistance(bot, a.loc) > 1600 then
		if TryTP(bot, a.loc) then return true end
		bot:Action_MoveToLocation(a.loc)
		return true
	end
	return false
end

-- Defense at a tower (T1-T3): fight under the tower when it's even or better,
-- otherwise hold behind it and hit whoever dives into its range. Replaces the
-- default "wander around behind the tower".
function X.DefendThink(bot, lane)
	if J.CanNotUseAction(bot) or bot:IsChanneling() then return true end
	local a = X.Assignment(bot)
	local tower
	if a and a.kind == 'defend' and a.lane == lane and a.tower and not a.tower:IsNull() then
		tower = a.tower
	else
		for tier = 1, 3 do
			for _, info in ipairs(TOWERS) do
				if info.lane == lane and info.tier == tier and not tower then
					local tw = GetTower(GetTeam(), info.id)
					if tw then tower = tw end
				end
			end
		end
	end
	if not tower or not tower:IsAlive() then return false end
	-- Base fights (enemies at the ancient) and high ground stay with aba_defend.
	if J.GetEnemiesAroundAncient(bot, 3200) > 0 then return false end
	if not (a and a.kind == 'defend') and string.find(tower:GetUnitName(), 'tower3') then return false end
	local tloc = tower:GetLocation()
	local d = GetUnitToLocationDistance(bot, tloc)
	if d > 1500 then
		if TryTP(bot, tloc) then return true end
		bot:Action_MoveToLocation(tloc)
		return true
	end

	local enemies = HeroesNear(GetOpposingTeam(), tloc, 1100)
	local allies = HeroesNear(GetTeam(), tloc, 1300)
	-- Nothing threatens the tower (not losing HP, nobody in its range): don't
	-- stand there, let farming/laning take over.
	local losing = false
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(GetTeam(), info.id)
		if tw == tower then
			local h = State().hp and State().hp['o'..info.id]
			losing = h ~= nil and h.rate > 5
		end
	end
	if not losing and #HeroesNear(GetOpposingTeam(), tloc, 750) == 0 then return false end
	local strong = #allies + 1 >= #enemies -- +1: the tower
	if #enemies > 0 then
		local _, ev = X.BestFight(bot, 1300)
		strong = strong and ev > -5
		-- Who kills whom first (X.Combat) overrides: fight when we win it.
		local c = X.Combat(bot)
		if c and c.go then strong = true elseif c and c.retreat then strong = false end
	end
	local back = tloc + (J.GetTeamFountain() - tloc):Normalized() * 250

	local target, low = nil, math.huge
	for _, e in ipairs(enemies) do
		local inTower = Dist(e:GetLocation(), tloc) < 750
		if J.CanBeAttacked(e) and (strong or inTower) and e:GetHealth() < low then target, low = e, e:GetHealth() end
	end
	if target then
		bot.forceFightUntil = DotaTime() + 2 -- spells on them
		bot:SetTarget(target)
		bot:Action_AttackUnit(target, true)
		return true
	end
	if #enemies == 0 then
		-- Creeps hitting the tower.
		local best, bestHP = nil, math.huge
		for _, c in pairs(bot:GetNearbyCreeps(1000, true)) do
			if J.IsValid(c) and J.CanBeAttacked(c) and Dist(c:GetLocation(), tloc) < 900 and c:GetHealth() < bestHP then
				best, bestHP = c, c:GetHealth()
			end
		end
		if best then bot:Action_AttackUnit(best, true) return true end
	end
	if GetUnitToLocationDistance(bot, back) > 150 then bot:Action_MoveToLocation(back) end
	return true
end

return X
