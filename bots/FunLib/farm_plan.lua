-- Which neutral camp to farm next.
--
-- The default picked the closest camp. This picks the camp with the best gold
-- per second (walk + clear time from the hero's own damage) among the safe
-- ones:
--   * no enemy hero seen near it in the last few seconds;
--   * not next to an enemy tower;
--   * enemy jungle only when most enemies are visible and we aren't outnumbered;
--   * ancients only for heroes that clear them fast enough.
-- With no safe camp, it falls back to the default choice.

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')

local X = {}

local GOLD = { small = 55, medium = 85, large = 120, ancient = 170 }
local HP = { small = 900, medium = 1500, large = 2300, ancient = 4200 }
local TOWERS = { TOWER_TOP_1, TOWER_MID_1, TOWER_BOT_1, TOWER_TOP_2, TOWER_MID_2, TOWER_BOT_2, TOWER_TOP_3, TOWER_MID_3, TOWER_BOT_3 }

local function Dist(a, b) return (a - b):Length2D() end

local function MissingAndRecent(loc, radius)
	local missing, recent = 0, false
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(pid) then
			local info = GetHeroLastSeenInfo(pid)
			local d = info and info[1]
			if not d or d.time_since_seen > 6 then missing = missing + 1 end
			if d and d.time_since_seen < 8 and Dist(d.location, loc) < radius then recent = true end
		end
	end
	return missing, recent
end

local function NearEnemyTower(loc, r)
	for _, id in ipairs(TOWERS) do
		local t = GetTower(GetOpposingTeam(), id)
		if t and Dist(t:GetLocation(), loc) < r then return true end
	end
	return false
end

local function AliveCount(team)
	local n = 0
	for _, pid in pairs(GetTeamPlayers(team)) do if IsHeroAlive(pid) then n = n + 1 end end
	return n
end

local function Dps(bot)
	local spa = 1.7
	pcall(function() spa = bot:GetSecondsPerAttack() end)
	return bot:GetAttackDamage() / math.max(0.3, spa)
end

function X.IsSafe(bot, camp)
	local loc = camp.location
	local missing, recent = MissingAndRecent(loc, 1500)
	if recent then return false end
	if NearEnemyTower(loc, 1500) then return false end
	if camp.team ~= GetTeam() then
		if missing >= 2 then return false end
		if AliveCount(GetOpposingTeam()) > AliveCount(GetTeam()) then return false end
	end
	return true
end

-- Gold per second of a camp for this hero.
function X.CampRate(bot, camp)
	local kind = camp.type or 'medium'
	local dps = Dps(bot) * (1 + 0.15 * math.max(0, bot:GetLevel() - 6) / 6) -- spells help as levels go up
	local clear = (HP[kind] or 1500) / math.max(30, dps)
	if kind == 'ancient' and (bot:GetLevel() < 12 or clear > 35) then return 0 end
	local walk = GetUnitToLocationDistance(bot, camp.location) / math.max(250, bot:GetCurrentMovementSpeed())
	local gold = (GOLD[kind] or 80) * (1 + DotaTime() / 60 / 60) -- bounty grows ~1 g/min
	return gold / (walk + clear + 2)
end

-- Drop-in for J.Site.GetClosestNeutralSpwan(bot, list): list entries are
-- { idx = ..., cattr = camp }.
function X.BestCamp(bot, list, fallback)
	-- Supports don't farm the jungle: they push lanes, ward and fight.
	if J.GetPosition(bot) >= 4 then return nil end
	if not list or #list == 0 then return fallback(bot, list) end
	local best, bestRate = nil, 0
	for _, entry in ipairs(list) do
		local camp = entry.cattr
		if camp and camp.location and X.IsSafe(bot, camp)
		and (not J.Site or not J.Site.IsTheClosestOne or J.Site.IsTheClosestOne(bot, camp.location)) then -- one farmer per camp
			local r = X.CampRate(bot, camp)
			if r > bestRate then best, bestRate = entry, r end
		end
	end
	if best then
		if bot._farmCamp ~= best.idx then
			bot._farmCamp = best.idx
			print(string.format('[Farm] %s -> %s camp (%.1f gold/s)', bot:GetUnitName(), tostring(best.cattr.type), bestRate))
		end
		return best
	end
	-- Nothing safe: the default choice, but only in our own jungle.
	local own = {}
	for _, entry in ipairs(list) do
		if entry.cattr and entry.cattr.team == GetTeam() then table.insert(own, entry) end
	end
	if #own == 0 then return nil end
	return fallback(bot, own)
end

return X
