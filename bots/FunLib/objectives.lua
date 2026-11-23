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

local okHW, HumanWatch = pcall(require, GetScriptDirectory()..'/FunLib/human_watch')
if not okHW then HumanWatch = nil end
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
	{ id = TOWER_BASE_1, lane = LANE_MID, tier = 4, tag = 'T4a' }, { id = TOWER_BASE_2, lane = LANE_MID, tier = 4, tag = 'T4b' },
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
-- Last hits and denies: the hero's own counters (GetHeroLastHits(pid)
-- returned 0 for everybody).
function X.LastHits(m)
	local lh, dn = 0, 0
	pcall(function() lh = m:GetLastHits() or 0 end)
	pcall(function() dn = m:GetDenies() or 0 end)
	if lh == 0 then lh = Stat(GetHeroLastHits, m:GetPlayerID()) end
	if dn == 0 then dn = Stat(GetHeroDenies, m:GetPlayerID()) end
	return lh, dn
end

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
		local lh, dn = X.LastHits(m)
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

-- Where each bot's time goes: its active mode every second, and whether it
-- stood still doing nothing (no move over 100, no attack, no cast).
local MODE_NAMES = {}
for name, v in pairs({ laning = BOT_MODE_LANING, attack = BOT_MODE_ATTACK, roam = BOT_MODE_ROAM, retreat = BOT_MODE_RETREAT,
	secret_shop = BOT_MODE_SECRET_SHOP, side_shop = BOT_MODE_SIDE_SHOP, rune = BOT_MODE_RUNE, push_top = BOT_MODE_PUSH_TOWER_TOP,
	push_mid = BOT_MODE_PUSH_TOWER_MID, push_bot = BOT_MODE_PUSH_TOWER_BOT, defend_top = BOT_MODE_DEFEND_TOWER_TOP,
	defend_mid = BOT_MODE_DEFEND_TOWER_MID, defend_bot = BOT_MODE_DEFEND_TOWER_BOT, assemble = BOT_MODE_ASSEMBLE,
	team_roam = BOT_MODE_TEAM_ROAM, farm = BOT_MODE_FARM, defend_ally = BOT_MODE_DEFEND_ALLY, evasive = BOT_MODE_EVASIVE_MANEUVERS,
	roshan = BOT_MODE_ROSHAN, item = BOT_MODE_ITEM, ward = BOT_MODE_WARD, outpost = BOT_MODE_OUTPOST, none = BOT_MODE_NONE }) do
	if v ~= nil then MODE_NAMES[v] = name end
end
-- The constants' real values, once (the report showed "defend_top" for a
-- team that was pushing).
local modesLogged = false
local function TrackModes(S)
	if not modesLogged then
		modesLogged = true
		local parts = {}
		for v, name in pairs(MODE_NAMES) do table.insert(parts, name..'='..tostring(v)) end
		table.sort(parts)
		print('[Diag] mode ids: '..table.concat(parts, ' '))
	end
	S.modes = S.modes or {}
	for _, m in ipairs(Members()) do
		if m:IsBot() then
			local pid = m:GetPlayerID()
			local r = S.modes[pid]
			if not r then r = { counts = {}, still = 0, dead = 0, n = 0 } S.modes[pid] = r end
			r.n = r.n + 1
			if not m:IsAlive() then
				r.dead = r.dead + 1
			else
				local name = MODE_NAMES[m:GetActiveMode()] or tostring(m:GetActiveMode())
				if name == 'farm' and (m._runUntil or -math.huge) > DotaTime() then name = 'run' end -- the farm mode's escape
				if m:GetActiveMode() == 28 then name = 'watcher' end
				-- A mode with no name (Pugna stood 55% of the time in "28"): once
				-- per bot, where it is and what is next to it.
				if not MODE_NAMES[m:GetActiveMode()] and not r.unknownLogged then
					r.unknownLogged = true
					local near, nd = '-', 500
					for _, u in pairs(GetUnitList(UNIT_LIST_ALL)) do
						if u and not u:IsNull() and u ~= m and not u:IsHero() then
							local d = GetUnitToUnitDistance(m, u)
							if d < nd then near, nd = u:GetUnitName(), d end
						end
					end
					local loc = m:GetLocation()
					print(string.format('[Diag] %s in mode %s at (%d, %d), next to %s', m:GetUnitName(), name, loc.x, loc.y, tostring(near)))
				end
				r.counts[name] = (r.counts[name] or 0) + 1
				-- Mode changes: how often the bot changes its mind.
				if r.lastMode and r.lastMode ~= name then r.switches = (r.switches or 0) + 1 end
				r.lastMode = name
				-- Gold earned while farming: how good the farm is, not just how long.
				local nw = m:GetNetWorth()
				if name == 'farm' and r.lastNW then r.farmGold = (r.farmGold or 0) + math.max(0, nw - r.lastNW) end
				if name == 'farm' then
					local b = m._farmBranch or '?'
					r.branch = r.branch or {}
					r.branch[b] = (r.branch[b] or 0) + 1
				end
				r.lastNW = nw
				local loc = m:GetLocation()
				local busy = m:GetAttackTarget() ~= nil or m:IsChanneling() or m:IsUsingAbility() or m:IsCastingAbility()
				if r.loc and Dist(loc, r.loc) < 100 and not busy and m:DistanceFromFountain() > 1000 then
					r.still = r.still + 1
					-- Standing 5 s in a row: say in which mode (Troll and CM stood
					-- by the bounty rune after taking it; nothing said why).
					r.stillRun = (r.stillRun or 0) + 1
					if r.stillRun == 5 and DotaTime() - (r.stillLogT or -math.huge) > 60 then
						r.stillLogT = DotaTime()
						print(string.format('[Diag] %s stands still 5 s in mode %s (desire %.2f) at (%d, %d)',
							m:GetUnitName(), name, m:GetActiveModeDesire(), loc.x, loc.y))
					end
				else
					r.stillRun = 0
				end
				-- Dithering: within 300 of where it was 8 s ago, not hitting or
				-- casting, nothing to fight or farm within 900 (Techies "stuck
				-- in place" with no stands-still line: it kept moving a bit).
				r.trail = r.trail or {}
				table.insert(r.trail, { loc = loc, mode = name, busy = busy })
				if #r.trail > 9 then table.remove(r.trail, 1) end
				if #r.trail == 9 and m:DistanceFromFountain() > 1000 and DotaTime() - (r.ditherLogT or -math.huge) > 60 then
					local far, anyBusy = 0, false
					for _, p in ipairs(r.trail) do
						far = math.max(far, Dist(p.loc, r.trail[1].loc))
						if p.busy then anyBusy = true end
					end
					if far < 300 and far >= 100 and not anyBusy
					and #m:GetNearbyHeroes(900, true, BOT_MODE_NONE) == 0
					and #m:GetNearbyCreeps(900, true) == 0 then
						r.ditherLogT = DotaTime()
						local modes = {}
						for _, p in ipairs(r.trail) do if modes[#modes] ~= p.mode then table.insert(modes, p.mode) end end
						local okA, act = pcall(function() return m:GetCurrentActionType() end)
						print(string.format('[Diag] %s dithers 8 s within %d at (%d, %d): modes %s, action %s, desire %.2f',
							m:GetUnitName(), far, loc.x, loc.y, table.concat(modes, '>'), okA and tostring(act) or '?', m:GetActiveModeDesire()))
					end
				end
				r.loc = loc
			end
		end
	end
end

local function ModeReport(S, t)
	if not S.modes then return end
	local rows = {}
	for _, m in ipairs(Members()) do
		local r = S.modes[m:GetPlayerID()]
		if r and r.n > 0 then
			local list = {}
			for name, c in pairs(r.counts) do table.insert(list, { name = name, c = c }) end
			table.sort(list, function(a, b) return a.c > b.c end)
			local parts = {}
			for i = 1, math.min(4, #list) do table.insert(parts, string.format('%s %d%%', list[i].name, math.floor(100 * list[i].c / r.n))) end
			local farmSecs = r.counts.farm or 0
			local farmRate = farmSecs > 10 and string.format(', farm %d g/min', math.floor((r.farmGold or 0) / farmSecs * 60)) or ''
			if farmSecs > 10 and r.branch then
				local bp = {}
				for b, c in pairs(r.branch) do table.insert(bp, b..' '..math.floor(100 * c / farmSecs)..'%') end
				farmRate = farmRate..' ('..table.concat(bp, ' ')..')'
			end
			r.branch = {}
			table.insert(rows, string.format('%s: %s, still %d%%, dead %d%%, %d switches%s', string.gsub(m:GetUnitName(), 'npc_dota_hero_', ''),
				table.concat(parts, ' '), math.floor(100 * r.still / r.n), math.floor(100 * r.dead / r.n), r.switches or 0, farmRate))
			r.counts, r.still, r.dead, r.n, r.farmGold, r.switches = {}, 0, 0, 0, 0, 0 -- per 5-minute window
		end
	end
	Log(string.format('modes %d:%02d team %d: %s', math.floor(t / 60), math.floor(t % 60), GetTeam(), table.concat(rows, ' | ')))
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
	-- How each hero plays, to compare with high-rank games: last hits and
	-- denies, gold and networth per minute, level, kills/deaths/assists.
	local mins = math.max(1, t / 60)
	local rows = {}
	for _, m in ipairs(Members()) do
		local pid = m:GetPlayerID()
		table.insert(rows, string.format('%s%s pos%d L%d cs %d/%d nw %d (%d/min) kda %d/%d/%d',
			string.gsub(m:GetUnitName(), 'npc_dota_hero_', ''), m:IsBot() and '' or ' (human)', J.GetPosition(m), m:GetLevel(),
			select(1, X.LastHits(m)), select(2, X.LastHits(m)), m:GetNetWorth(), math.floor(m:GetNetWorth() / mins),
			Stat(GetHeroKills, pid), Stat(GetHeroDeaths, pid), Stat(GetHeroAssists, pid)))
	end
	pcall(ModeReport, S, t)
	Log(string.format('stats %d:%02d team %d: %s', math.floor(t / 60), math.floor(t % 60), GetTeam(), table.concat(rows, ' | ')))
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
-- The carry's farm phase: before 20:00 and two items worth 2000+ (a human
-- TB at 761 GPM joined no fight or push before his Mjollnir at 22:30).
function X.CarryFarming(m)
	if J.GetPosition(m) ~= 1 then return false end
	if DotaTime() >= 20 * 60 then
		local big = 0
		for slot = 0, 5 do
			local it = m:GetItemInSlot(slot)
			if it and GetItemCost(it:GetName()) >= 2000 then big = big + 1 end
		end
		if big >= 2 then return false end
		if DotaTime() >= 30 * 60 then return false end
	end
	return true
end

local function CarryLocked(m, lane, kind, tier)
	if X.CoreLaneLocked(m) and lane ~= m:GetAssignedLane() then return true end
	-- Farming carry: no push or T1-T3 defense trips (only right where it is).
	if X.CarryFarming(m) and (kind == 'push' or (kind == 'defend' and (tier or 1) <= 3)) then return true end
	-- Supports stay with their core in the laning phase (Disruptor left
	-- Lifestealer at 5:00 to defend T1s on the other lanes), unless that core
	-- is dead.
	if J.GetPosition(m) >= 4 and DotaTime() < 10 * 60 and lane ~= m:GetAssignedLane() then
		for _, c in ipairs(Members()) do
			if c ~= m and J.GetPosition(c) <= 3 and c:GetAssignedLane() == m:GetAssignedLane() and c:IsAlive() then return true end
		end
	end
	-- The carry keeps farming instead of defending T1/T2 before 30:00, unless
	-- it's right there.
	if kind == 'defend' and J.GetPosition(m) == 1 and DotaTime() < 30 * 60 and (tier or 1) <= 2 then return true end
	return false
end

local function Candidates(S, loc, exclude, lane, kind, tier)
	local list = {}
	for _, m in ipairs(Members()) do
		if m:IsBot() and m:IsAlive() and J.GetHP(m) > 0.4 and not exclude[m] and not m:IsChanneling()
		and not X.IsIdle(m) -- dropped as idle: not handed the same job again every second
		and not (CarryLocked(m, lane, kind, tier) and GetUnitToLocationDistance(m, loc) > 2500) then
			table.insert(list, { m = m, travel = TravelTime(m, loc) })
		end
	end
	table.sort(list, function(a, b) return a.travel < b.travel end)
	return list
end

-- Adds helpers while each one is worth it. Returns the helpers.
-- Against enemy heroes at the objective: send a group that wins there. The
-- fastest helpers (teleport counted) are added one by one, up to 3; as soon
-- as the group wins the fight at the spot (x1.0+, with who is already there)
-- they all go. If even 3 don't, nobody goes (no feeding one by one).
local function PickGroup(S, obj, taken)
	local group, chosen = {}, {}
	-- Their T3s and base: every enemy alive defends there, so they all count,
	-- and it takes 3 of us (fewer only when fewer of them are alive). SF was
	-- sent alone to a T4 "at x1.64" and died to the five of them.
	local base = obj.kind == 'push' and (obj.tier or 1) >= 3
	local towerPush = obj.kind == 'push' and (obj.tier or 0) >= 1 -- an enemy tower (not a wave in our base)
	local minGroup = base and math.min(3, math.max(1, GetNumAlive(GetOpposingTeam()))) or 1
	local maxGroup = base and 5 or 3
	-- Just called off here: nobody for 10 s unless clearly winning (Dire
	-- called three off at x0.63 and sent three others at x1.57 the same second).
	local offT = S.calledOff and S.calledOff[obj.name..obj.lane]
	local need = (base or towerPush) and 1.2 or 1.0
	if offT and DotaTime() - offT < 10 then need = math.max(need, 1.3) end
	for _, c in ipairs(Candidates(S, obj.loc, taken, obj.lane, obj.kind, obj.tier)) do
		if #group >= maxGroup then break end
		if not (obj.ttd and c.travel > obj.ttd + 5) then -- in time to matter
			table.insert(group, c.m)
			table.insert(chosen, { m = c.m, gain = obj.value, cost = X.Rate(c.m) * c.travel / 60 + 2 })
			local ratio = X.FightAt(obj.loc, group, base, towerPush)
			if ratio >= need and #group >= minGroup then
				ObjLog(string.format('%d heroes win at %s lane %d (x%.2f): sending them', #group, obj.name, obj.lane, ratio))
				return chosen
			end
		end
	end
	return {}
end

local function PickHelpers(S, obj, taken, maxHelpers)
	if not obj.ancient and (obj.enemies > 0 or (obj.kind == 'push' and (obj.tier or 1) >= 3)) then return PickGroup(S, obj, taken) end
	local helpers = {}
	local a, e = obj.allies, obj.enemies
	for _, c in ipairs(Candidates(S, obj.loc, taken, obj.lane, obj.kind, obj.tier)) do
		if #helpers >= maxHelpers then break end
		if obj.ttd and c.travel > obj.ttd + 5 then break end -- too late to save it
		local near = GetUnitToLocationDistance(c.m, obj.loc) < 1200 or obj.ancient
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
					max = math.min(4, GetNumAlive(GetOpposingTeam()) + 1), name = 'enemy '..(info.tag or 'T'..info.tier) })
			end
		end
	end
	-- Our ancient: everyone defends it (a base defense is the last one).
	local anc = GetAncient(GetTeam())
	if anc and anc:IsAlive() then
		local hp = TowerHPTracker(S, 'ancient', anc, t)
		local enemies = HeroesNear(GetOpposingTeam(), anc:GetLocation(), 1500)
		-- It stays on 8 s after the last threat (enemies stepping in and out of
		-- range flipped DK between the ancient and a T4 every second).
		if hp.rate > 5 or #enemies > 0 then S.ancientUntil = t + 8 end
		if (S.ancientUntil or -math.huge) > t then
			table.insert(list, { kind = 'defend', lane = LANE_MID, tier = 5, loc = anc:GetLocation(), tower = anc,
				value = X.POINTS.ancient, allies = #HeroesNear(GetTeam(), anc:GetLocation(), 1500) + 1.5, enemies = #enemies,
				ttd = 99, enough = 0.99, max = 5, name = 'our ancient', ancient = true })
		end
	end
	-- Enemy waves walking into our base on a lane with no T3 of ours: one
	-- hero pushes that lane back out (waves on open lanes kept crashing into
	-- the base while the team was elsewhere). Only with no enemy hero at the
	-- wave.
	local ourAnc = GetAncient(GetTeam())
	if ourAnc then
		for _, info in ipairs(TOWERS) do
			if info.tier == 3 and not GetTower(GetTeam(), info.id) then
				local front = GetLaneFrontLocation(GetOpposingTeam(), info.lane, 0)
				if front and Dist(front, ourAnc:GetLocation()) < 5500
				and #HeroesNear(GetOpposingTeam(), front, 1500) == 0 then
					table.insert(list, { kind = 'push', lane = info.lane, tier = 0, loc = front,
						value = 60, allies = #HeroesNear(GetTeam(), front, 1300), enemies = 0, enough = 0.6,
						max = 1, name = 'wave in our base' })
				end
			end
		end
	end
	-- Our towers under attack. With the ancient defended, the T4s are part of
	-- that same fight (one objective, not three to switch between).
	local ancientOn = (S.ancientUntil or -math.huge) > t
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(GetTeam(), info.id)
		if tw and not (ancientOn and info.tier == 4) then
			local hp = TowerHPTracker(S, 'o'..info.id, tw, t)
			local enemies = HeroesNear(GetOpposingTeam(), tw:GetLocation(), 1200)
			-- A real threat: the tower is losing HP, or an enemy hero is in its
			-- range. A hero farming near it isn't one (two enemy cores used to
			-- come and stand behind their tower while a human farmed nearby).
			local inRange = X.HeroHitsTower(tw)
			if hp.rate > 5 or inRange then
				local allies = #HeroesNear(GetTeam(), tw:GetLocation(), 1300)
				local bonus = info.tier >= 3 and 1.5 or 1 -- the tower fights too
				local ttd = hp.rate > 1 and tw:GetHealth() / hp.rate or 60
				local creepsOnly = #enemies == 0
				table.insert(list, { kind = 'defend', lane = info.lane, tier = info.tier, loc = tw:GetLocation(), tower = tw,
					value = X.POINTS.tower[info.tier] * (creepsOnly and 0.3 or 1), allies = allies + bonus, enemies = #enemies,
					ttd = ttd, enough = 0.7, max = creepsOnly and 1 or math.min(4, #enemies + 1), name = 'our '..(info.tag or 'T'..info.tier) })
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
	local aliveById = {}
	for _, m in ipairs(Members()) do aliveById[m:GetPlayerID()] = m:IsAlive() end
	for pid, a in pairs(S.assign) do
		local still = active[a.name..a.lane]
		-- A dead hero's assignment ends (SF respawned, teleported to a T2 from
		-- before his death and stood there doing nothing).
		if aliveById[pid] == false then still = nil a.untilT = -math.huge end
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
	-- A kept group must still win where it's going (Clockwerk and Gyro kept
	-- walking to a T2 where Terrorblade had come): otherwise it's dropped, and
	-- a new winning group (or nobody) is picked below.
	for _, obj in ipairs(objectives) do
		local base = obj.kind == 'push' and (obj.tier or 1) >= 3
		if not obj.ancient and (obj.enemies > 0 or base) then
			local group, pids = {}, {}
			for _, m in ipairs(Members()) do
				local a = newAssign[m:GetPlayerID()]
				if a and a.name == obj.name and a.lane == obj.lane then
					table.insert(group, m) table.insert(pids, m:GetPlayerID())
				end
			end
			if #group > 0 then
				local ratio = X.FightAt(obj.loc, group, base, obj.kind == 'push' and (obj.tier or 0) >= 1)
				if ratio < 0.8 or (base and #group < math.min(3, math.max(1, GetNumAlive(GetOpposingTeam())))) then
					ObjLog(string.format('%d heroes lose at %s lane %d (x%.2f): calling them off', #group, obj.name, obj.lane, ratio))
					S.calledOff = S.calledOff or {}
					S.calledOff[obj.name..obj.lane] = t
					for i, m in ipairs(group) do taken[m] = nil newAssign[pids[i]] = nil end
					S.dropped = S.dropped or {}
					for _, pid in ipairs(pids) do S.dropped[pid] = obj.name..obj.lane end
				end
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
				newAssign[pid] = { kind = obj.kind, lane = obj.lane, tier = obj.tier, loc = obj.loc, tower = obj.tower, name = obj.name, enemies = obj.enemies, untilT = t + ASSIGN_TIME }
			end
		end
	end
	-- Keep a recent assignment a little longer (no flip-flopping).
	for pid, a in pairs(S.assign) do
		if not newAssign[pid] and a.untilT > t and not (S.dropped and S.dropped[pid] == a.name..a.lane) then
			local tw = a.kind == 'defend' and a.tower
			if not tw or (not tw:IsNull() and tw:IsAlive()) then newAssign[pid] = a end
		end
	end
	S.assign = newAssign
	S.dropped = nil
end

function X.Update()
	local S = State()
	local t = DotaTime()
	if t < S.nextUpdate then return S end
	S.nextUpdate = t + UPDATE_GAP
	if t < 0 then return S end
	X.RememberEnemies()
	pcall(TrackModes, S) -- diagnostics only
	if HumanWatch then pcall(HumanWatch.Update) end -- how the humans play
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

-- Ranged heroes hit buildings from their full range instead of walking up to
-- them (the default push attack-moved around the tower: Sniper stood at its
-- base). The default logic keeps the case where the tower hits us with no
-- creeps of ours under it (it steps back).
function X.RangedSiegeThink(bot)
	local range = 0
	pcall(function() range = bot:GetAttackRange() end)
	if range < 500 or J.CanNotUseAction(bot) then return false end
	local target, bestD
	local function Consider(b)
		if b and not b:IsNull() and b:IsAlive() and J.CanBeAttacked(b) then
			local d = GetUnitToUnitDistance(bot, b)
			if d < range + 600 and (not bestD or d < bestD) then target, bestD = b, d end
		end
	end
	for _, info in ipairs(TOWERS) do Consider(GetTower(GetOpposingTeam(), info.id)) end
	if not target then return false end
	if target:HasModifier('modifier_backdoor_protection') or target:HasModifier('modifier_backdoor_protection_active')
	or target:HasModifier('modifier_fountain_glyph') then return false end
	local myCreepsAtTower = 0
	for _, c in pairs(bot:GetNearbyLaneCreeps(1600, false)) do
		if J.IsValid(c) and GetUnitToUnitDistance(c, target) < 700 then myCreepsAtTower = myCreepsAtTower + 1 end
	end
	if target:GetAttackTarget() == bot and myCreepsAtTower == 0 then return false end
	local spot = target:GetLocation() + (bot:GetLocation() - target:GetLocation()):Normalized() * (range - 60)
	if bestD > range + 50 then
		bot:Action_MoveToLocation(spot)
	else
		bot:Action_AttackUnit(target, true)
	end
	return true
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
-- An enemy cuts us off from `tl` when it's ahead on the way (not the chaser
-- right behind us) and clearly closer to it than we are.
local function CutOff(myLoc, tl, enemies)
	local d = Dist(tl, myLoc)
	local dir = (tl - myLoc) / math.max(1, d)
	for _, e in ipairs(enemies) do
		local el = e:GetLocation()
		local toE = el - myLoc
		local de = toE:Length2D()
		if de > 1 then
			local ahead = (toE.x * dir.x + toE.y * dir.y) / de
			if ahead > 0.6 and Dist(el, tl) < d - 400 then return true end
		end
	end
	return false
end

-- The goal holds for 4 s unless it gets cut off: Largo turned back and forth
-- with Bristleback hitting him (a chaser at his side made the closest tower
-- look "blocked" one moment and free the next).
function X.RetreatStep(bot)
	local myLoc = bot:GetLocation()
	local fountain = J.GetTeamFountain()
	local enemies = HeroesNear(GetOpposingTeam(), myLoc, 1300)
	local t = DotaTime()
	local goal
	local g = bot._retreatGoal
	if g and t - g.t < 4 and t - (g.lastT or g.t) < 1.5 and not CutOff(myLoc, g.loc, enemies) and Dist(g.loc, myLoc) > 300 then
		goal = g.loc
	else
		local bestD = math.huge
		goal = fountain
		for _, info in ipairs(TOWERS) do
			local tw = GetTower(GetTeam(), info.id)
			if tw then
				local tl = tw:GetLocation()
				local d = Dist(tl, myLoc)
				local safer = Dist(tl, fountain) < Dist(myLoc, fountain) + 300
				if safer and d < bestD and d > 300 and not CutOff(myLoc, tl, enemies) then goal, bestD = tl, d end
			end
		end
		bot._retreatGoal = { loc = goal, t = t }
	end
	bot._retreatGoal.lastT = t
	local dir = goal - myLoc
	if dir:Length2D() < 1 then return goal end
	dir = dir / dir:Length2D()
	-- Bend away from enemies ahead or at the side; a chaser behind pushes
	-- the same way we go anyway.
	local away = Vector(0, 0, 0)
	for _, e in ipairs(enemies) do
		local v = myLoc - e:GetLocation()
		local d = v:Length2D()
		if d > 1 then away = away + v / d * ((1300 - d) / 1300) end
	end
	local step = dir + away * 0.6
	-- Never step back toward the enemies we flee from.
	if step.x * dir.x + step.y * dir.y < 0.3 * step:Length2D() then step = dir end
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
	-- Next to our tower their damage is less of a worry, but a disable still
	-- breaks the channel (Hoodwink teleported at her tower, Legion Commander
	-- with Duel ready right there, and died).
	local atTower = false
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(GetTeam(), info.id)
		if tw and Dist(tw:GetLocation(), myLoc) < 500 then atTower = true end
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
	if atTower then return true end
	local near = HeroesNear(GetOpposingTeam(), myLoc, 1600)
	if #near > 0 and X._Burst and X._Burst(near, bot, TP_CHANNEL, false) >= bot:GetHealth() then return false end
	return true
end

-- The same when it says fight: heroes first, buildings after (SF hit a T4
-- he couldn't take while enemies he could kill stood around him).
-- An idle bot (no income for 20 s, nowhere to go) pushes the nearest lane
-- where our wave is and nobody waits for it (match 9102358727 at 100:00:
-- Vengeful and Skywrath stood at their top T3 in "watcher" at 0.33, Razor
-- in team_roam - nothing else wanted anything). Lane chosen every 3 s.
function X.IdlePushLane(bot)
	local t = DotaTime()
	if t < 10 * 60 or bot:GetLevel() < 6 or J.GetHP(bot) < 0.5 then return nil end
	-- Nothing wants it: the winning mode's desire under 0.2 for 6 s counts
	-- as idle too (Vengeful stood 20 s at our top T2 in defend_top at 0.11
	-- before the 20 s idle check sent her off).
	local low = bot:GetActiveModeDesire() < 0.2 and bot:GetActiveMode() ~= BOT_MODE_RETREAT
	if low then bot._lowDesireSince = bot._lowDesireSince or t else bot._lowDesireSince = nil end
	local lowLong = bot._lowDesireSince and t - bot._lowDesireSince >= 6 and bot:DistanceFromFountain() > 1500
	-- Idle starts a 40 s push window (renewed while still idle).
	if X.IsIdle(bot) or lowLong then
		if t - (bot._idlePushStart or -math.huge) > 40 then bot._idlePushStart = t end
	elseif t - (bot._idlePushStart or -math.huge) > 40 then
		bot._idleNoLane = false
		return nil
	end
	if bot._idlePushCheck and t - bot._idlePushCheck < 3 then return bot._idlePushLane end
	bot._idlePushCheck = t
	local best, bestD = nil, math.huge
	for _, lane in ipairs({ LANE_TOP, LANE_MID, LANE_BOT }) do
		local front = GetLaneFrontLocation(GetTeam(), lane, 0)
		local d = GetUnitToLocationDistance(bot, front)
		if d < bestD and not X.PickoffRisk(bot, front, false) and X.FightAt(front, bot, false, true) >= 1.0 then
			best, bestD = lane, d
		end
	end
	bot._idlePushLane = best
	-- No safe lane anywhere: X.IdleFollow sends it to our nearest core.
	bot._idleNoLane = best == nil
	if best then
		if bot._idlePushLogged ~= bot._idlePushStart then
			bot._idlePushLogged = bot._idlePushStart
			print('[Obj] '..bot:GetUnitName()..' idle: pushes lane '..best)
		end
	end
	return best
end

-- Idle and no lane safe to push (Techies stood at our top T2 at 0.11 with
-- "3-4 enemies may be there" on every front): stay with our nearest core
-- that isn't in the base. Returns that ally or nil.
function X.IdleFollow(bot)
	if not bot._idleNoLane or J.GetPosition(bot) <= 3 then return nil end
	if DotaTime() - (bot._idlePushCheck or -math.huge) > 5 then return nil end
	local best, bd = nil, math.huge
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if m and m ~= bot and m:IsAlive() and J.GetPosition(m) <= 3 and m:DistanceFromFountain() > 3000 then
			local d = GetUnitToUnitDistance(bot, m)
			if d < bd then best, bd = m, d end
		end
	end
	return best
end

function X.CapPushWhenLosing(bot, desire)
	if X.IsIdle(bot) and X.IdlePushLane(bot) == nil then return math.min(desire, 0.2) end
	local c = bot._combat
	if c and (c.retreat or (c.go and J.IsValidHero(c.target))) and DotaTime() - (bot._fightHintT or -math.huge) < 1.5 then
		return math.min(desire, 0.3)
	end
	return desire
end

-- For the push wrappers: max with the normal desire.
function X.PushDesire(bot, lane)
	if X.IdlePushLane(bot) == lane then return 0.55 end
	if DropIfIdle(bot) then return 0 end
	local a = X.Assignment(bot)
	if a and a.kind == 'push' and a.lane == lane and not X.LosingHere(bot) then return 0.82 end
	return 0
end

-- Split push: a farming core takes the open towers on its way (OpenDota
-- 9098641220: a human TB, 718 GPM, 18k tower damage in 30 min, 184 lane
-- creeps and only 50 neutrals: T1 mid 11:36, T1 bot 19:06, T2 mid 20:43,
-- T3 mid + barracks 21:29, T1 top 22:37, T2 top 24:42 - one tower after
-- another, each time where the enemies weren't). Pos 1-3 from 10:00 and
-- level 8 (from 5:00 and level 5 their own lane's tower, x2.0):
--   * the lane's first standing enemy tower, with our wave at it (the lane
--     front within 1000) and the fight there won by far (x1.5, enemies seen
--     elsewhere counted half: they can teleport); a T3 from 25:00 and x2.5;
--   * the farming carry only takes a tower within 3000 of it (on its farm
--     route); in the early game a core only takes its own lane's;
--   * not while the team plan has the hero in its hunt or siege group, nor
--     in a finish, regroup or defend;
--   * the closest such tower; 0.92 within 2500 of it (it's there: hit it,
--     the farm mode yields), 0.75 to walk to it.
local function EnemyLaneTower(lane)
	for tier = 1, 3 do
		for _, info in ipairs(TOWERS) do
			if info.lane == lane and info.tier == tier then
				local tw = GetTower(GetOpposingTeam(), info.id)
				if tw then return tw, tier end
			end
		end
	end
	return nil, 4
end

local function SplitTarget(bot)
	local pos = J.GetPosition(bot)
	if pos < 1 or pos > 3 then return nil end
	local t = DotaTime()
	-- From 5:00 a core takes its own lane's tower when the wave is at it and
	-- nobody can defend it (DK pushed the mid wave to the T1 again and again
	-- and walked back under his own tower each time); from 10:00 and level 8
	-- any lane.
	local early = t < 10 * 60
	if t < 5 * 60 or bot:GetLevel() < (early and 5 or 8) or J.GetHP(bot) < 0.55 or X.IsIdle(bot) then return nil end
	local plan = TeamPlanState and TeamPlanState[GetTeam()]
	if plan then
		local p = plan.phase
		if p == 'finish' or p == 'regroup' or p == 'defend' then return nil end
		-- In the hunting group only while a hunt is on (the hunt phase runs
		-- from 14:00 and kept the offlaner from ever taking a tower).
		if ((p == 'hunt' and plan.hunt) or p == 'siege') and plan.group then
			for _, m in ipairs(plan.group) do if m == bot then return nil end end
		end
	end
	local best, bestD
	for _, lane in ipairs({ LANE_TOP, LANE_MID, LANE_BOT }) do
		local tw, tier = EnemyLaneTower(lane)
		if tw and not ((early or X.CoreLaneLocked(bot)) and lane ~= bot:GetAssignedLane()) then
			local loc = tw:GetLocation()
			local d = GetUnitToLocationDistance(bot, loc)
			local front = GetLaneFrontLocation(GetTeam(), lane, 0)
			local ok = Dist(front, loc) < 1000 and d < 7000
			if ok and X.CarryFarming(bot) and d > 3000 then ok = false end
			if ok and tier == 3 and t < 25 * 60 then ok = false end
			if ok and (not bestD or d < bestD) then
				-- Safe: nobody that can be there soon (seen within 2500 or
				-- vanished within reach), or one we beat there by far. The
				-- fog-weighted fight (every unseen enemy half at the tower)
				-- never let anyone split: 0 split pushes in a 20-minute game
				-- with all ten T1s standing.
				local n = X.EnemiesInReach(loc, 2500)
				local need = tier == 3 and 2.5 or (early and 2.0 or 1.5)
				if n == 0 or (n == 1 and tier < 3 and X.FightAt(loc, bot) >= need) then
					best, bestD = { lane = lane, tower = tw, d = d }, d
				end
			end
		end
	end
	return best
end

function X.SplitPushDesire(bot, lane)
	local t = DotaTime()
	local c = bot._split
	if not c or t - c.t >= 0.5 then
		local prev = c and c.target and c.target.tower
		c = { t = t, target = SplitTarget(bot) }
		bot._split = c
		if c.target and c.target.tower ~= prev then
			print(string.format('[Obj] %s split push: %s (%d away)', bot:GetUnitName(), c.target.tower:GetUnitName(), math.floor(c.target.d)))
		end
	end
	local s = c.target
	if not s or s.lane ~= lane or s.tower:IsNull() or not s.tower:IsAlive() then return 0 end
	if s.d < 2500 then return 0.92 end
	return 0.75
end

-- The farm mode yields to a split push the hero is at.
function X.SplitPushing(bot)
	local c = bot._split
	return c and c.target and DotaTime() - c.t < 1 and c.target.d < 2500 or false
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
	return X.HeroHitsTower(tw)
end

-- An enemy hero hitting the tower (not just farming next to it: Slark
-- farmed the waves at Radiant's top T1 and Slardar and OD "defended" it for
-- most of 25-30 min instead of pushing).
function X.HeroHitsTower(tw)
	for _, e in ipairs(HeroesNear(GetOpposingTeam(), tw:GetLocation(), 900)) do
		local tgt = e:GetAttackTarget()
		if tgt and tgt == tw then return true end
	end
	return false
end

function X.FilterDefendDesire(bot, lane, desire)
	if desire <= 0 then return desire end
	local tw, tier = X.OwnLaneTower(lane)
	if tier <= 3 and X.IsIdle(bot) then return math.min(desire, 0.2) end
	-- As many defenders as enemies at the tower + 1 (one with only creeps),
	-- the closest ones, carry and mid last: Radiant's four bots stood at
	-- their top tower 33-50% of the time against one farming enemy instead
	-- of farming. Claims last 3 s and are renewed by the bots that hold them.
	if tw and tier <= 3 then
		local S = State()
		S.defClaims = S.defClaims or {}
		local key = lane..':'..tier
		local t = DotaTime()
		local allowed = #HeroesNear(GetOpposingTeam(), tw:GetLocation(), 2000) + 1
		local function cost(m) return GetUnitToUnitDistance(m, tw) + (J.GetPosition(m) <= 2 and 2000 or 0) end
		local claims = {}
		for _, c in ipairs(S.defClaims[key] or {}) do
			if c.bot ~= bot and t - c.t <= 3 and c.bot:IsAlive() then table.insert(claims, c) end
		end
		table.sort(claims, function(a, b) return cost(a.bot) < cost(b.bot) end)
		local mine = cost(bot)
		local ok = #claims < allowed or mine + 300 < cost(claims[#claims].bot)
		if ok then
			table.insert(claims, { bot = bot, t = t })
			table.sort(claims, function(a, b) return cost(a.bot) < cost(b.bot) end)
			while #claims > allowed do table.remove(claims) end
		end
		S.defClaims[key] = claims
		if not ok then return math.min(desire, 0.15) end
	end
	-- Nothing comes at a T3 or the base: no standing guard there either (Dire
	-- stood at its mid T3 with nobody attacking it instead of farming and
	-- pushing out the waves).
	if tw and tier == 3 and not X.TowerThreatened(tw) and #HeroesNear(GetOpposingTeam(), tw:GetLocation(), 2500) == 0 then
		return math.min(desire, 0.1)
	end
	if not tw then
		local anc = GetAncient(GetTeam())
		local h = State().hp and State().hp['ancient']
		if anc and #HeroesNear(GetOpposingTeam(), anc:GetLocation(), 3500) == 0 and not (h and h.rate > 5) then
			return math.min(desire, 0.1)
		end
	end
	-- Losing the exchange here: retreat wins over a T1-T3 defense.
	if tier <= 3 and X.LosingHere(bot) then return math.min(desire, 0.3) end
	-- Nobody hits the tower: no standing guard at T1/T2.
	if tw and tier <= 2 and not X.TowerThreatened(tw) then return math.min(desire, 0.2) end
	local far = not tw or GetUnitToUnitDistance(bot, tw) > 2500
	if far and X.CoreLaneLocked(bot) and lane ~= bot:GetAssignedLane() and tier <= 2 then return math.min(desire, 0.1) end
	if far and J.GetPosition(bot) >= 4 and DotaTime() < 10 * 60 and lane ~= bot:GetAssignedLane() and tier <= 2 then return math.min(desire, 0.1) end
	if far and J.GetPosition(bot) == 1 and DotaTime() < 30 * 60 and tier <= 2 then return math.min(desire, 0.2) end
	return desire
end

-- For the defend wrappers.
-- An idle bot (no income for 20 s, not moving) loses its assignment and the
-- default push/defend desires are capped: Juggernaut stood hitting a watcher
-- by a quiet tower, "idle for 20 s" three times in a row.
local function DropIfIdle(bot)
	if not X.IsIdle(bot) then return false end
	-- Holding the base, or enemies around: waiting there is the point.
	if GetUnitToLocationDistance(bot, GetAncient(GetTeam()):GetLocation()) < 4000 then return false end
	if #HeroesNear(GetOpposingTeam(), bot:GetLocation(), 1600) > 0 then return false end
	local S = State()
	if S.assign[bot:GetPlayerID()] then S.assign[bot:GetPlayerID()] = nil end
	return true
end

function X.DefendDesire(bot, lane)
	if DropIfIdle(bot) then return 0 end
	local a = X.Assignment(bot)
	if a and a.kind == 'defend' and a.lane == lane then
		if a.tier ~= 5 and X.LosingHere(bot) then return 0 end
		-- Nothing to defend there any more: no standing guard.
		if a.tier ~= 5 and a.tower and not a.tower:IsNull() and not X.TowerThreatened(a.tower)
		and #HeroesNear(GetOpposingTeam(), a.tower:GetLocation(), 1600) == 0 then return 0 end
		return 0.88
	end
	return 0
end

-- The exchange here (X.Combat) says get out: no objective keeps the bot in.
function X.LosingHere(bot)
	local c = bot._combat
	return c ~= nil and c.retreat == true and DotaTime() - (bot._fightHintT or -math.huge) < 1.5
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

-- Illusions hit too: they're left out of the hero lists, so their damage is
-- added to the hero they copy, at the share that hero's illusions deal
-- (7.42 game files, by the ability's level):
--   Terrorblade: Conjure Image 25-40%, +60% near him (Dark Unity) -> 40-64%;
--   Phantom Lancer 17% (15% + Divergence); Naga Mirror Image 25-40%;
--   Chaos Knight Phantasm 60-100%; Spectre Haunt 35-65%; Morphling 50%;
--   Anti-Mage 75%; anyone else: Manta (33% melee, 28% ranged).
local ILLUSIONS = {
	npc_dota_hero_terrorblade = { ability = 'terrorblade_conjure_image', share = { 0.40, 0.48, 0.56, 0.64 } },
	npc_dota_hero_phantom_lancer = { share = { 0.17 } },
	npc_dota_hero_naga_siren = { ability = 'naga_siren_mirror_image', share = { 0.25, 0.30, 0.35, 0.40 } },
	npc_dota_hero_chaos_knight = { ability = 'chaos_knight_phantasm', share = { 0.60, 0.80, 1.00 } },
	npc_dota_hero_spectre = { ability = 'spectre_haunt', share = { 0.35, 0.50, 0.65 } },
	npc_dota_hero_morphling = { share = { 0.50 } },
	npc_dota_hero_antimage = { share = { 0.75 } },
}
local function IllusionShare(u)
	local e = ILLUSIONS[u:GetUnitName()]
	if not e then
		local ranged = false
		pcall(function() ranged = u:GetAttackRange() > 300 end)
		return ranged and 0.28 or 0.33
	end
	local lvl = #e.share
	if e.ability then
		pcall(function()
			local ab = u:GetAbilityByName(e.ability)
			if ab and ab:GetLevel() > 0 then lvl = math.min(#e.share, ab:GetLevel()) end
		end)
	end
	return e.share[lvl]
end
X._IllusionShare = IllusionShare

local function IllusionDamage(u, victim, secs)
	local total = 0
	local lt = (u.GetTeam and u:GetTeam() == GetTeam()) and UNIT_LIST_ALLIED_HEROES or UNIT_LIST_ENEMY_HEROES
	local share = IllusionShare(u)
	pcall(function()
		local name, loc = u:GetUnitName(), u:GetLocation()
		for _, h in pairs(GetUnitList(lt)) do
			if h ~= u and J.IsValidHero(h) and h:GetUnitName() == name and Dist(h:GetLocation(), loc) < 1200
			and (h:IsIllusion() or J.IsSuspiciousIllusion(h)) then
				local v = h:GetEstimatedDamageToTarget(true, victim, secs, DAMAGE_TYPE_PHYSICAL or DAMAGE_TYPE_ALL)
				if v then total = total + v * share end
			end
		end
	end)
	return total
end

-- Ready steroids the estimate doesn't count: Terrorblade's Metamorphosis
-- (bonus damage, and his illusions get it too).
local function SteroidDamage(u, secs)
	local extra = 0
	pcall(function()
		if u:GetUnitName() ~= 'npc_dota_hero_terrorblade' then return end
		if u:HasModifier('modifier_terrorblade_metamorphosis') then return end -- already in the estimate
		local ab = u:GetAbilityByName('terrorblade_metamorphosis')
		if ab and ab:GetLevel() > 0 and ab:GetCooldownTimeRemaining() <= 0 then
			extra = ({ 20, 40, 60, 80 })[math.min(4, ab:GetLevel())] * 1.4 * math.max(0, secs - 1)
		end
	end)
	return extra
end

-- Enemy cooldowns are hidden from us: the "ready spells only" estimate of an
-- enemy came out as little more than its attacks ("they kill us in 99 s"
-- next to a Lion with Finger of Death up, and Troll walked in and died).
-- Enemies are counted with all their spells (as a player assumes what he
-- hasn't seen used is ready), at 85%.
-- Counting all of them at 85% made bots run from even lane fights (Sven
-- spent 37% of the first 10 minutes retreating at "team x0.04-0.20"): an
-- enemy is now the mean of "ready only" and "all spells", at most 2.5 times
-- the ready-only figure.
-- Spells we saw an enemy cast are on cooldown for their cooldown time: their
-- damage comes off the "all spells" figure. Troll ran far from Winter
-- Wyvern and Dawnbreaker under his tower while all their spells were down
-- ("they kill us in 1 s") and the wave died there without him.
local enemyCasts = {} -- [unit][ability name] = { t, cd, dmg }
function X.NoteEnemyCasts()
	local t = DotaTime()
	for _, e in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(e) and not e:IsIllusion() then
			local ok, ab = pcall(function() return e:GetCurrentActiveAbility() end)
			if ok and ab and not ab:IsNull() and not ab:IsItem() then
				local name = ab:GetName()
				local rec = enemyCasts[e] or {}
				enemyCasts[e] = rec
				local r = rec[name]
				if not r or t - r.t > 1 then
					local cd, dmg = 0, 0
					pcall(function() cd = ab:GetCooldown() or 0 end)
					pcall(function() dmg = ab:GetAbilityDamage() or 0 end)
					if dmg <= 0 then
						for _, k in ipairs({ 'damage', 'total_damage', 'base_damage', 'hero_damage', 'damage_per_second' }) do
							local ok2, v = pcall(function() return ab:GetSpecialValueFloat(k) end)
							if ok2 and v and v > 0 then dmg = v break end
						end
					end
					rec[name] = { t = t, cd = cd, dmg = dmg }
				end
			end
		end
	end
end

-- Damage of the enemy's spells known to be on cooldown now.
local function DownDamage(u)
	local rec = enemyCasts[u]
	if not rec then return 0 end
	local t, sum = DotaTime(), 0
	for _, r in pairs(rec) do
		if r.cd > 0 and t - r.t < r.cd then sum = sum + r.dmg end
	end
	return sum
end

local function Estimate(u, victim, secs, dtype)
	local enemy = u.GetTeam and u:GetTeam() ~= GetTeam()
	local ready = u:GetEstimatedDamageToTarget(true, victim, secs, dtype)
	if not enemy or not ready then return ready end
	local all = u:GetEstimatedDamageToTarget(false, victim, secs, dtype) or ready
	all = math.max(ready, all - DownDamage(u))
	-- In the laning stage few spells are trained and the "all spells" figure
	-- runs far over what a level 3 hero deals: Monkey King at full HP backed
	-- off from Phoenix ("they kill us in 3 s, team x0.06") for a minute and
	-- took no last hit. Weight it 25% there, capped at 1.6x the ready figure.
	local v
	if J.IsInLaningPhase() then
		v = math.min(ready * 0.75 + all * 0.25, math.max(ready, 1) * 1.6)
	else
		v = math.min((ready + all) / 2, math.max(ready, 1) * 2.5)
	end
	-- What one enemy can really deal in `secs`: its attacks plus a spell
	-- budget of 110 per level. Razor backed off from Phoenix 19 times in 20
	-- minutes at "they kill us in 1.0 s" (level 10, 6.5k networth, one death).
	local atk, spa = 0, 1.7
	pcall(function() atk = u:GetAttackDamage() or 0 end)
	pcall(function() spa = math.max(0.3, u:GetSecondsPerAttack() or 1.7) end)
	local cap = atk * (math.floor(secs / spa) + 1) + 110 * u:GetLevel()
	return math.min(v, cap), ready, all, cap
end

local function Burst(dealers, victim, secs, magicCut)
	local d = 0
	for _, u in ipairs(dealers) do
		local ok, v = pcall(function() return Estimate(u, victim, secs, DAMAGE_TYPE_ALL) end)
		if ok and v then v = v + SummonDamage(u, secs) + IllusionDamage(u, victim, secs) + SteroidDamage(u, secs) end
		if ok and v then
			if magicCut then
				local ok2, mag = pcall(function() return Estimate(u, victim, secs, DAMAGE_TYPE_MAGICAL) end)
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
local wkWatch = {}
local function ExtraLife(victim)
	if victim:HasModifier('modifier_aegis_regen') or (victim.FindItemSlot and victim:FindItemSlot('item_aegis') >= 0) then
		return victim:GetMaxHealth()
	end
	if victim:GetUnitName() == 'npc_dota_hero_skeleton_king' then
		-- An enemy WK's cooldown is hidden from us (it always read ready, so
		-- Troll and Pugna didn't finish him after he came back): his rebirth
		-- is seen instead (under 10% HP, then nearly full within 6 s), and
		-- the second life is gone for 200 s after it.
		if victim:GetTeam() ~= GetTeam() then
			local pid = victim:GetPlayerID()
			wkWatch[pid] = wkWatch[pid] or {}
			local w, now, hp = wkWatch[pid], DotaTime(), J.GetHP(victim)
			if hp < 0.1 then w.lowT = now end
			if w.lowT and hp > 0.85 and now - w.lowT < 6 then w.usedT, w.lowT = now, nil end
			if w.usedT and now - w.usedT < 200 then return 0 end
			return victim:GetLevel() >= 6 and victim:GetMaxHealth() or 0
		end
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
	-- Terrorblade's Sunder ready: hurt, he swaps HP with the healthiest of us.
	if victim:GetUnitName() == 'npc_dota_hero_terrorblade' then
		pcall(function()
			local ab = victim:GetAbilityByName('terrorblade_sunder')
			if ab and ab:GetLevel() > 0 and ab:GetCooldownTimeRemaining() <= 0 then
				extra = extra + victim:GetMaxHealth() * 0.5
			end
		end)
	end
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

-- What each enemy hero brought to a fight when last seen (4 s of ready
-- damage on our heroes, max HP with shields): used for the ones in the fog.
local enemySnap = {}
function X.RememberEnemies()
	local ours = {}
	for _, m in ipairs(Members()) do if m:IsAlive() then table.insert(ours, m) end end
	if #ours == 0 then return end
	for _, e in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(e) and not e:IsIllusion() and not J.IsSuspiciousIllusion(e) then
			enemySnap[e:GetPlayerID()] = { power = TeamPower({ e }, ours), hp = e:GetMaxHealth() + ShieldHP(e) }
		end
	end
end

-- Enemies in the fog who may be at `loc`: seen near it in the last 10 s
-- (0.9), not seen for longer (0.5: they may be there or teleport in), seen
-- elsewhere just now (0.2). Returns their power and HP, weighted.
local function FogEnemies(loc, visible, all, half)
	local power, hp, n = 0, 0, 0
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		local snap = enemySnap[pid]
		if snap and IsHeroAlive(pid) and not visible[pid] then
			local info = GetHeroLastSeenInfo(pid)
			local d = info and info[1]
			local w = 0.5
			if d and d.time_since_seen <= 10 then w = Dist(d.location, loc) < 3000 and 0.9 or 0.2 end
			if all then w = 1 end -- at their base they all come
			if half then w = math.max(w, 0.5) end -- their tower: they may teleport in
			power, hp, n = power + snap.power * w, hp + snap.hp * w, n + w
		end
	end
	return power, hp, n
end

-- Who wins a fight at `loc` if `extra` joins: our burn rate over theirs (>1
-- we win). Enemies in the fog who may be there count too (Enigma and Rubick
-- teleported one by one to push a T2 "at x99" with our heroes behind it in
-- the fog). 99 with no enemy there and none unaccounted for.
function X.FightAt(loc, extra, allEnemies, halfEnemies)
	local allies = HeroesNear(GetTeam(), loc, 1500)
	-- extra: one hero or a list of heroes joining.
	local extras = (type(extra) == 'table' and extra[1] ~= nil) and extra or (extra and { extra } or {})
	for _, x in ipairs(extras) do
		local has = false
		for _, a in ipairs(allies) do if a == x then has = true end end
		if not has then table.insert(allies, x) end
	end
	local enemies = HeroesNear(GetOpposingTeam(), loc, 1500)
	local visible = {}
	for _, e in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(e) and not e:IsIllusion() then visible[e:GetPlayerID()] = true end
	end
	local fogPower, fogHP, fogN = FogEnemies(loc, visible, allEnemies, halfEnemies)
	if halfEnemies and not allEnemies then
		-- Visible enemies elsewhere can teleport to their tower: half each.
		for _, e in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
			if J.IsValidHero(e) and not e:IsIllusion() and not J.IsSuspiciousIllusion(e) and Dist(e:GetLocation(), loc) > 1500 then
				local snap = enemySnap[e:GetPlayerID()]
				if snap then fogPower, fogHP, fogN = fogPower + snap.power * 0.5, fogHP + snap.hp * 0.5, fogN + 0.5 end
			end
		end
	end
	if allEnemies then
		-- Every enemy alive defends there: the visible ones anywhere count too.
		for _, e in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
			if J.IsValidHero(e) and not e:IsIllusion() and not J.IsSuspiciousIllusion(e) and Dist(e:GetLocation(), loc) > 1500 then
				table.insert(enemies, e)
			end
		end
	end
	if #enemies == 0 and fogN < 0.3 then return 99 end
	if #allies == 0 then return 0 end
	-- Our damage on them: on the visible ones, else on heroes like ours.
	local ours = TeamPower(allies, #enemies > 0 and enemies or allies) / (TeamHP(enemies) * (#enemies > 0 and 1 or 0) + fogHP + 1)
	local theirs = ((#enemies > 0 and TeamPower(enemies, allies) or 0) + fogPower) / TeamHP(allies)
	return ours / math.max(0.0001, theirs)
end
X._enemySnap = enemySnap

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

-- The fight around an enemy hero for all of our heroes there: everyone of
-- ours within GROUP_RADIUS of it against every enemy there, and the target
-- they all take (the first one picked keeps it). Cached a second per team.
local GROUP_RADIUS = 1800
local groupCache = {}
function X.GroupFight(target)
	if not J.IsValidHero(target) then return nil end
	local t = DotaTime()
	local cached = groupCache[target:GetPlayerID()]
	if cached and cached.target == target and t - cached.t >= 0 and t - cached.t < 1.0 then return cached end
	local loc = target:GetLocation()
	local allies = HeroesNear(GetTeam(), loc, GROUP_RADIUS)
	local enemies = HeroesNear(GetOpposingTeam(), loc, GROUP_RADIUS)
	if #allies == 0 or #enemies == 0 then return nil end
	-- Their heroes on the way (1800-3000) count half, and those in the fog
	-- by what they had when seen (LC dived Lion at "x1.57" with three of
	-- Lion's allies running in).
	local coming = {}
	for _, e in ipairs(HeroesNear(GetOpposingTeam(), loc, 3000)) do
		if Dist(e:GetLocation(), loc) > GROUP_RADIUS then table.insert(coming, e) end
	end
	local visible = {}
	for _, e in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
		if J.IsValidHero(e) and not e:IsIllusion() then visible[e:GetPlayerID()] = true end
	end
	local fogPower, fogHP = FogEnemies(loc, visible)
	local theirPower = TeamPower(enemies, allies) + 0.5 * TeamPower(coming, allies) + fogPower
	local theirHP = TeamHP(enemies) + 0.5 * (#coming > 0 and TeamHP(coming) or 0) + fogHP
	local ratio = (TeamPower(allies, enemies) / theirHP) / math.max(0.0001, theirPower / TeamHP(allies))
	local g = { t = t, target = target, ratio = ratio, n = #allies }
	groupCache[target:GetPlayerID()] = g
	return g
end

function X.Combat(bot)
	X.NoteEnemyCasts()
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
			-- The chase counts: walking to it, and a target that reaches its
			-- tower first is safe (Gyrocopter went for Legion Commander next to
			-- her T1 instead of the Witch Doctor he was standing by).
			if tt < 99 then
				local gap = math.max(0, Dist(e:GetLocation(), myLoc) - (reach - 400))
				tt = tt + gap / 350
				if BuildingNear(GetOpposingTeam(), e:GetLocation(), 1100) and e:GetHealth() > 250 then tt = tt + 2 end
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
	-- One decision for the whole group: every hero of ours near the target
	-- uses the same fight (each bot used to count only allies within 1400 of
	-- itself: Underlord, Grimstroke and DK went on Terrorblade at x1.40 while
	-- Disruptor (x0.25) and Lifestealer stayed out, and the three lost it).
	if not c.lastStand and not noTarget then
		local g = X.GroupFight(best)
		if g and Dist(myLoc, best:GetLocation()) < GROUP_RADIUS then
			c.groupRatio = g.ratio
			if g.ratio >= 1.2 and hp > 0.3 and ttkThem > 1.5 then
				c.go, c.retreat, c.target = true, false, g.target
			elseif g.ratio < 0.8 and not (bestT <= 2 and bestT < ttkThem) then
				c.go = false
			end
		end
	end
	-- No target outside their fountain: nothing to chase.
	if noTarget then c.go = false end
	if nearFountain and #enemies > 0 then c.go, c.retreat = false, true end
	-- An enemy right next to us: decide (fight or leave), never keep farming
	-- creeps in between (MK hit creeps with enemies around in their base).
	-- (Not in the laning stage: the enemy laners are always that close, and
	-- the cores kept walking out of their lane every ten seconds.)
	if not c.go and not c.retreat and not J.IsInLaningPhase() then
		local close = false
		for _, e in ipairs(enemies) do if Dist(e:GetLocation(), myLoc) < 900 then close = true end end
		if close then
			-- Leave only when they can actually kill us soon; enemies that
			-- can't (99 s both ways) don't stop the farm (DK kept dropping the
			-- creeps to step back from Furion at x3.5).
			local theirSide = Dist(myLoc, enemyFountain) < Dist(myLoc, J.GetTeamFountain())
			if teamRatio >= 1.0 and not noTarget and hp > 0.35 then c.go = true
			-- On their side only when we'd lose the fight there: DK backed off
			-- from Invoker three times in 20 s at x1.19-x3.59 with nobody able
			-- to kill anyone ("99 s both ways") and spun in place.
			elseif ttkThem <= 6 or (theirSide and teamRatio < 1.0) then c.retreat = true end
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
-- Pickoff risk: a hero alone out of our towers' cover where the enemies out
-- of sight may be (OpenDota 9098678691: no smokes, yet the enemy took 10
-- kills outside the fights - Lifestealer caught the farming Terrorblade
-- three times and Lion and Abaddon 10 s apart, Necrophos and DP the
-- supports and Zeus walking alone). From 5:00, for `loc`:
--   * no ally hero within 1600 of it, and 2500+ from our nearest tower and
--     out of our base;
--   * enemies that may be there: those seen within 1800 in the last 3 s,
--     plus those that vanished in the last 20 s whose last spot is within
--     reach since (1200 + 320 per second unseen);
--   * risky: on the enemy half two of them (one for a support), on ours
--     three.
local function OurNearestTowerDist(loc)
	local best = math.huge
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(GetTeam(), info.id)
		if tw then best = math.min(best, Dist(tw:GetLocation(), loc)) end
	end
	return best
end

-- Enemy heroes that may be at `loc` soon: seen within `near` in the last
-- 3 s, or vanished in the last 20 s with `loc` within their reach since
-- (1200 + 320 per second). Long-missing ones aren't counted (radius 6000:
-- they'd be "everywhere" and kept Spectre out of every camp).
function X.EnemiesInReach(loc, near)
	local n = 0
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(pid) then
			local info = GetHeroLastSeenInfo(pid)
			local d = info and info[1]
			if d and d.time_since_seen < 3 then
				if Dist(d.location, loc) < near then n = n + 1 end
			elseif d and d.time_since_seen <= 20 and Dist(d.location, loc) <= 1200 + 320 * d.time_since_seen then
				n = n + 1
			end
		end
	end
	return n
end

-- ownSide: the caller knows it's our half (our own camp): the fountain
-- distance put Radiant's bottom camps by the river on Dire's half.
function X.PickoffRisk(bot, loc, ownSide)
	if DotaTime() < 5 * 60 then return false end
	if J.IsRealInvisible and J.IsRealInvisible(bot) then return false end
	for _, a in ipairs(HeroesNear(GetTeam(), loc, 1600)) do
		if a ~= bot then return false end
	end
	if Dist(loc, J.GetTeamFountain()) < 4500 or OurNearestTowerDist(loc) < 2500 then return false end
	local n = X.EnemiesInReach(loc, 1800)
	local enemyFountain = J.GetEnemyFountain and J.GetEnemyFountain() or GetAncient(GetOpposingTeam()):GetLocation()
	local enemySide = not ownSide and Dist(loc, enemyFountain) < Dist(loc, J.GetTeamFountain())
	-- Our half: three of them (the farm there is what the carry lives on);
	-- their half: two, one for a support.
	local need = enemySide and (J.GetPosition(bot) >= 4 and 1 or 2) or 3
	local risky = n >= need
	if risky and DotaTime() - (bot._pickoffLogT or -math.huge) > 30 then
		bot._pickoffLogT = DotaTime()
		print(string.format('[Obj] %s pickoff risk at (%d, %d): %d enemies may be there', bot:GetUnitName(), loc.x, loc.y, n))
	end
	return risky
end

function X.SafeSpot(bot, loc)
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(pid) then
			local info = GetHeroLastSeenInfo(pid)
			local d = info and info[1]
			if d and d.time_since_seen < 5 and Dist(d.location, loc) < 1400 then return false end
		end
	end
	local enemyFountain = J.GetEnemyFountain and J.GetEnemyFountain() or GetAncient(GetOpposingTeam()):GetLocation()
	local enemySide = not ownSide and Dist(loc, enemyFountain) < Dist(loc, J.GetTeamFountain()) - 1500
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
			print(string.format('[Fight] %s %s %s (we kill in %.1f s, they kill us in %.1f s, team x%.2f, group x%.2f, unseen enemies %d, allies coming %d, value %.0f)',
				bot:GetUnitName(), what, target:GetUnitName(), ttkUs, ttkThem, c.teamRatio or 0, c.groupRatio or 0, c.ghosts or 0, c.arriving or 0, ev))
			-- A very fast "they kill us": what each enemy's 2 s figure is made of
			-- (once a minute), to tell a real threat from a bad estimate.
			if ttkThem <= 1.5 and t - (bot._estLogT or -math.huge) > 60 then
				bot._estLogT = t
				local parts = {}
				for _, e in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
					if J.IsValidHero(e) and not e:IsIllusion() and GetUnitToUnitDistance(bot, e) < 1600 then
						local ok, v, rdy, all, cap = pcall(Estimate, e, bot, 2, DAMAGE_TYPE_ALL)
						local sm = SummonDamage(e, 2)
						local il = IllusionDamage(e, bot, 2)
						table.insert(parts, string.format('%s L%d: est %d (ready %d, all %d, cap %d) summons %d illusions %d',
							string.gsub(e:GetUnitName(), 'npc_dota_hero_', ''), e:GetLevel(), ok and v or -1, ok and rdy or -1, ok and all or -1, ok and cap or -1, sm, il))
					end
				end
				print(string.format('[Diag] %s HP %d (+%d shield): %s', bot:GetUnitName(), bot:GetHealth(), ShieldHP(bot), table.concat(parts, ' | ')))
			end
		end
	end
	-- Commitment: a decision holds for a while (retreat 3 s, fight 2 s) so the
	-- bot doesn't turn around every half second as the numbers wobble (Sniper
	-- kept turning back and taking hits). A fight is dropped early only when
	-- the bot is about to die.
	local d = bot._decision
	-- Still being hit and hurt: the retreat goes on (when it ran out, the
	-- hunt took Largo back toward Bristleback, who kept hitting him).
	-- Only while they can actually kill us: WK kept "backing off" from Drow's
	-- harass at "99 s both ways, team x2.3-x3.1" and lost half a wave.
	if d and d.kind == 'retreat' and d.untilT <= t and J.GetHP(bot) < 0.5 and bot:WasRecentlyDamagedByAnyHero(1.5) and ttkThem <= 6 then
		d.untilT = t + 2
	end
	if d and d.untilT > t then
		if d.kind == 'retreat' then c.retreat, c.go = true, false
		elseif d.kind == 'go' and not (ttkThem <= 1.5) then c.go, c.retreat = true, false end
	end
	-- Laning stage: a fight only for a near-sure kill (3 s; 2 s next to their
	-- tower), not a chase that costs the wave.
	if c.go and J.IsInLaningPhase() and J.IsValidHero(target) then
		local underTower = BuildingNear(GetOpposingTeam(), target:GetLocation(), 800) ~= nil
		if ttkUs > (underTower and 2 or 3) then c.go = false end
		-- And one we win: Spectre went for Lion at level 1-2 at x0.66 with
		-- Necrophos next to him ("they kill us in 5 s") and died at 1:58;
		-- 14 last hits at 10:00.
		if ttkUs >= ttkThem or ((c.teamRatio or 0) < 1.0 and (c.groupRatio or 0) < 1.0) then c.go = false end
		-- Cores farm the lane: a fight only for a kill within 2 s on a target
		-- already in reach (no chase). In the first 5 minutes Drow 'went for'
		-- someone 11 times and had 2 last hits; Gyrocopter 6 with 6.
		if J.GetPosition(bot) <= 3 and c.go then
			local reach = 600
			pcall(function() reach = bot:GetAttackRange() + 250 end)
			if ttkUs > 2 or GetUnitToUnitDistance(bot, target) > reach then c.go = false end
		end
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
	-- No teleport for creeps only (WK teleported from his camp to a T2 and
	-- walked back to the same camp): walk, or leave it to whoever is close.
	local a = X.Assignment(bot)
	if a and (a.enemies or 0) < 0.5 and not (a.tier == 5) then return false end
	if J.GetPosition(bot) >= 4 and DotaTime() < 15 * 60 then return false end -- walk: the lane partner stays
	if #J.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE) > 0 then return false end
	if DotaTime() < (bot._lastFieldTpT or -math.huge) + 60 then return false end -- one field teleport a minute
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
		bot._lastFieldTpT = DotaTime()
		bot:Action_UseAbilityOnLocation(item, best:GetLocation())
		ObjLog(bot:GetUnitName()..' teleports to help')
		return true
	end
	return false
end

-- Finish phase: a hero far from the finish lane teleports to our tower
-- nearest its front (the allies stood at their top T3 while the human
-- pushed alone at 5 vs 2).
function X.FinishTravel(bot, lane)
	local S = TeamPlanState and TeamPlanState[GetTeam()]
	if not S then return false end
	local finish = S.phase == 'finish' and S.finishLane == lane and (S.finishUntil or 0) - DotaTime() >= 15
	local teamSiege = S.phase == 'siege' and S.siegeAll and S.siegeLane == lane
	if not finish and not teamSiege then return false end
	local front = GetLaneFrontLocation(GetTeam(), lane, 0)
	if GetUnitToLocationDistance(bot, front) < 5000 or J.CanNotUseAction(bot) then return false end
	if bot:IsChanneling() or bot:IsUsingAbility() then return true end -- the teleport is on
	if #J.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE) > 0 then return false end
	local item
	for _, n in ipairs({ 'item_tpscroll', 'item_travel_boots', 'item_travel_boots_2' }) do
		local slot = bot:FindItemSlot(n)
		local it = slot >= 0 and bot:GetItemInSlot(slot) or nil
		if it and it:IsFullyCastable() then item = it break end
	end
	if not item then return false end
	local best, bd = nil, math.huge
	for _, info in ipairs(TOWERS) do
		local tw = GetTower(GetTeam(), info.id)
		if tw then
			local d = Dist(tw:GetLocation(), front)
			if d < bd then best, bd = tw, d end
		end
	end
	if not best or bd > GetUnitToLocationDistance(bot, front) - 3000 then return false end
	bot:Action_UseAbilityOnLocation(item, best:GetLocation())
	ObjLog(bot:GetUnitName()..' teleports to the '..(teamSiege and 'team siege' or 'finish')..' (lane '..lane..')')
	return true
end

-- Push helpers: get there (TP if far); the push mode does the rest.
-- On their high ground: buildings in order, barracks first (Radiant walked
-- back and forth on Dire's high ground while Dire wouldn't come out, and the
-- barracks stood). Melee barracks before ranged, then the T4s, then the
-- ancient; the closest one of the best kind, attackable, within 1800. Not
-- while a fight is on (the combat evaluation says go / retreat) or with an
-- enemy hero within 700.
local RAX_ORDER = {}
if BARRACKS_TOP_MELEE ~= nil then
	RAX_ORDER = { BARRACKS_TOP_MELEE, BARRACKS_MID_MELEE, BARRACKS_BOT_MELEE, BARRACKS_TOP_RANGED, BARRACKS_MID_RANGED, BARRACKS_BOT_RANGED }
end
local function Attackable(u)
	return u ~= nil and not u:IsNull() and u:IsAlive() and not u:IsInvulnerable()
end
function X.BaseTarget(bot)
	local anc = GetAncient(GetOpposingTeam())
	if not anc or GetUnitToUnitDistance(bot, anc) > 3500 then return nil end
	local myLoc = bot:GetLocation()
	local function closest(list)
		local best, bd = nil, 1800
		for _, u in ipairs(list) do
			local fountain = J.GetEnemyFountain and J.GetEnemyFountain()
			if Attackable(u) and not (fountain and Dist(u:GetLocation(), fountain) < 1700) then
				local d = GetUnitToUnitDistance(bot, u)
				if d < bd then best, bd = u, d end
			end
		end
		return best
	end
	local melee, ranged = {}, {}
	for i, id in ipairs(RAX_ORDER) do
		local b = GetBarracks(GetOpposingTeam(), id)
		if b then table.insert(i <= 3 and melee or ranged, b) end
	end
	local t4 = {}
	for _, id in ipairs({ TOWER_BASE_1, TOWER_BASE_2 }) do
		local tw = GetTower(GetOpposingTeam(), id)
		if tw then table.insert(t4, tw) end
	end
	return closest(melee) or closest(ranged) or closest(t4) or (Attackable(anc) and GetUnitToUnitDistance(bot, anc) < 1800 and anc or nil)
end

function X.BaseSiegeThink(bot)
	if J.CanNotUseAction(bot) or bot:IsChanneling() then return false end
	local c = bot._combat
	if c and (c.go or c.retreat) and DotaTime() - (bot._fightHintT or -math.huge) < 1.5 then return false end
	if #HeroesNear(GetOpposingTeam(), bot:GetLocation(), 700) > 0 then return false end
	local target = X.BaseTarget(bot)
	if not target then return false end
	if bot._baseTarget ~= target then
		bot._baseTarget = target
		ObjLog(bot:GetUnitName()..' hits '..target:GetUnitName()..' on their high ground')
	end
	bot:Action_AttackUnit(target, true)
	return true
end

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
		local inTower = Dist(e:GetLocation(), tloc) < 750 and not X.LosingHere(bot)
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
	-- Holding behind the tower: still take the last hits and denies in reach
	-- (DK stood by a wave PL's illusions were killing and took none).
	local reach = bot:GetAttackRange() + 150
	local dmg = bot:GetAttackDamage()
	for _, enemy in ipairs({ true, false }) do
		for _, c in pairs(bot:GetNearbyLaneCreeps(reach, enemy)) do
			if J.IsValid(c) and J.CanBeAttacked(c) and (enemy or J.GetHP(c) < 0.5)
			and J.WillKillTarget(c, dmg, DAMAGE_TYPE_PHYSICAL, J.GetAttackProDelayTime(bot, c)) then
				bot:Action_AttackUnit(c, true)
				return true
			end
		end
	end
	if GetUnitToLocationDistance(bot, back) > 150 then bot:Action_MoveToLocation(back) end
	return true
end

return X
