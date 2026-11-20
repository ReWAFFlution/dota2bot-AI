-- Human watch: records how the human players on our team play, to copy
-- their pattern into the bots (where they farm, what they hit, the camps
-- they chain, item timings). Lines are tagged [Human].
--
-- Every second, for each human hero: the area (lane top/mid/bot, own or
-- enemy jungle, river, base, other) and the activity (lane creeps,
-- neutrals, heroes, buildings, moving, standing). Printed:
--   * a camp entry when the human starts hitting the neutrals of a camp;
--   * a new item worth 1000+ when it shows up in the inventory;
--   * every 5 minutes, the shares of areas and activities, and last hits.
-- Called from Objectives.Update (once a second per team).

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')

local X = {}

local LANES = { [LANE_TOP or 1] = 'top', [LANE_MID or 2] = 'mid', [LANE_BOT or 3] = 'bot' }
local WINDOW = 300

local state = {}

local function Dist(a, b) return (a - b):Length2D() end

local function Camps()
	if state.camps then return state.camps end
	state.camps = {}
	for _, c in pairs(GetNeutralSpawners and GetNeutralSpawners() or {}) do
		if c and c.location then table.insert(state.camps, c) end
	end
	return state.camps
end

local function NearestCamp(loc)
	local best, bd
	for _, c in ipairs(Camps()) do
		local d = Dist(c.location, loc)
		if not bd or d < bd then best, bd = c, d end
	end
	return best, bd or math.huge
end

local function Area(h)
	local loc = h:GetLocation()
	if h:DistanceFromFountain() < 2500 then return 'base' end
	-- Lane: close to either team's lane front on that lane.
	local bestLane, bd = nil, 1300
	for lane, name in pairs(LANES) do
		for _, team in ipairs({ GetTeam(), GetOpposingTeam() }) do
			local f = GetLaneFrontLocation(team, lane, 0)
			if f then
				local d = Dist(f, loc)
				if d < bd then bestLane, bd = name, d end
			end
		end
	end
	if bestLane then return 'lane_'..bestLane end
	local camp, cd = NearestCamp(loc)
	if camp and cd < 1000 then return camp.team == GetTeam() and 'jungle_own' or 'jungle_enemy' end
	-- River: near the diagonal between the two bases.
	if math.abs(loc.x + loc.y) < 1400 then return 'river' end
	return 'other'
end

local function Activity(h, r)
	local tgt = h:GetAttackTarget()
	if tgt and not tgt:IsNull() then
		if tgt:IsHero() then return 'heroes' end
		if tgt:IsBuilding() or tgt:IsTower() then return 'buildings' end
		local ok, neutral = pcall(function() return tgt:GetTeam() == TEAM_NEUTRAL end)
		if ok and neutral then return 'neutrals' end
		return 'lane_creeps'
	end
	if h:IsChanneling() or h:IsCastingAbility() then return 'casting' end
	local loc = h:GetLocation()
	local moved = r.loc and Dist(r.loc, loc) > 100
	return moved and 'moving' or 'standing'
end

local function Clock(t) return string.format('%d:%02d', math.floor(t / 60), math.floor(t % 60)) end

local function Share(tbl, n)
	local list = {}
	for k, c in pairs(tbl) do table.insert(list, { k = k, c = c }) end
	table.sort(list, function(a, b) return a.c > b.c end)
	local parts = {}
	for _, e in ipairs(list) do table.insert(parts, string.format('%s %d%%', e.k, math.floor(100 * e.c / math.max(1, n)))) end
	return table.concat(parts, ' ')
end

function X.Update()
	local t = DotaTime()
	if t < 0 then return end
	for i = 1, 5 do
		local h = GetTeamMember(i)
		if h and not h:IsBot() and not h:IsIllusion() then
			local pid = h:GetPlayerID()
			local r = state[pid]
			if not r then
				r = { area = {}, act = {}, n = 0, items = {}, windowStart = 0, lh = 0 }
				state[pid] = r
			end
			local name = string.gsub(h:GetUnitName(), 'npc_dota_hero_', '')
			if h:IsAlive() then
				local area, act = Area(h), Activity(h, r)
				r.area[area] = (r.area[area] or 0) + 1
				r.act[act] = (r.act[act] or 0) + 1
				r.n = r.n + 1
				r.loc = h:GetLocation()
				-- Camp chain: the camp whose neutrals the human starts hitting.
				if act == 'neutrals' then
					local camp, cd = NearestCamp(h:GetLocation())
					local key = camp and (math.floor(camp.location.x)..':'..math.floor(camp.location.y))
					if camp and cd < 1200 and key ~= r.lastCamp then
						r.lastCamp = key
						print(string.format('[Human] %s %s camp %s (%s) at (%d, %d)', Clock(t), name, tostring(camp.type),
							camp.team == GetTeam() and 'own' or 'enemy', camp.location.x, camp.location.y))
					end
				elseif act == 'lane_creeps' then
					r.lastCamp = nil
				end
			else
				r.area.dead = (r.area.dead or 0) + 1
				r.n = r.n + 1
			end
			-- New items worth 1000+.
			for slot = 0, 8 do
				local it = h:GetItemInSlot(slot)
				if it then
					local n = it:GetName()
					if not r.items[n] and GetItemCost(n) >= 1000 then
						r.items[n] = t
						print(string.format('[Human] %s %s item %s', Clock(t), name, n))
					end
				end
			end
			-- Every 5 minutes: where the time went.
			if t - r.windowStart >= WINDOW and r.n > 0 then
				local lh = 0
				pcall(function() lh = h:GetLastHits() end)
				print(string.format('[Human] %s-%s %s areas: %s | doing: %s | last hits +%d (%d), networth %d',
					Clock(r.windowStart), Clock(t), name, Share(r.area, r.n), Share(r.act, r.n), lh - r.lh, lh, h:GetNetWorth()))
				r.area, r.act, r.n, r.windowStart, r.lh = {}, {}, 0, t, lh
			end
		end
	end
end

return X
