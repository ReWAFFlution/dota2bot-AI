-- luajit scripts/sim/farm.lua bots : between waves in the laning stage a
-- core clears a nearby camp of its own jungle; not while its wave is there,
-- not a support, not a far or enemy camp.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('farm.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 8 * 60
local pos = 1
local J = { GetPosition = function() return pos end, GetHP = function() return 0.9 end }
function require(p) if p:find('jmz_func') then return J end end
function GetTeam() return 2 end function GetOpposingTeam() return 3 end
function GetTeamPlayers() return {} end function GetTower() return nil end
local creeps = {}
local bot = { loc = Vector(0, 0) }
function bot:GetLocation() return self.loc end function bot:GetUnitName() return 'npc_dota_hero_juggernaut' end
function bot:GetNearbyLaneCreeps() return creeps end
local neutrals = { {} }
function bot:GetNearbyNeutralCreeps() return neutrals end function bot:GetAttackDamage() return 100 end
local hp = 900
function bot:GetHealth() return hp end function bot:GetMaxHealth() return 1000 end
function bot:GetSecondsPerAttack() return 1.2 end function bot:GetLevel() return 6 end function bot:GetCurrentMovementSpeed() return 315 end
function GetUnitToLocationDistance(u, l) return (u:GetLocation() - l):Length2D() end
local F = dofile(BOTS..'/FunLib/farm_plan.lua')
local list = {
	{ idx = 1, cattr = { location = Vector(900, 300), team = 2, type = 'small' } },
	{ idx = 2, cattr = { location = Vector(1400, 0), team = 2, type = 'medium' } },
	{ idx = 3, cattr = { location = Vector(600, 0), team = 3, type = 'large' } },  -- enemy jungle
	{ idx = 4, cattr = { location = Vector(5000, 0), team = 2, type = 'large' } }, -- far
}
creeps = { {} }
local a = F.BetweenWaves(bot, list)
print('wave still there:', a and a.idx)
assert(a == nil)
creeps = {}
local b = F.BetweenWaves(bot, list)
print('wave dead: camp', b and b.idx, b and b.cattr.type)
assert(b and (b.idx == 1 or b.idx == 2))
creeps = { {} } SIM_T = SIM_T + 5
local c = F.BetweenWaves(bot, list)
print('next wave comes while clearing: keeps camp', c and c.idx)
assert(c and c.idx == b.idx)
pos = 5 bot._waveCamp = nil creeps = {}
assert(F.BetweenWaves(bot, list) == nil)
print('support: no camp')
-- The camp got cleared (standing at it, no neutrals): not picked again this
-- minute; the empty list from the farm mode falls back to the game's camps.
pos = 1 bot._waveCamp = nil creeps = {} neutrals = {}
bot.loc = Vector(900, 300)
GetNeutralSpawners = function() local r = {} for _, e in ipairs(list) do table.insert(r, e.cattr) end return r end
local d = F.BetweenWaves(bot, {})
print('standing at the cleared small camp: next camp', d and d.cattr.type)
assert(d == nil or d.cattr.type ~= 'small')
-- Clearing a camp for 30 s (slow clear): it's kept past the 25 s walk limit.
pos = 1 bot._waveCamp = nil creeps = {} neutrals = { {} } SIM_T = SIM_T + 120
bot.loc = Vector(0, 0)
local e = F.BetweenWaves(bot, list)
bot.loc = e.cattr.location + Vector(100, 0)
SIM_T = SIM_T + 30
local still = F.BetweenWaves(bot, list)
print('30 s into a slow clear: same camp', still and still.idx == e.idx)
assert(still and still.idx == e.idx)
pos = 2 bot._waveCamp = nil creeps = {} neutrals = { {} } bot.loc = Vector(0, 0)
local later = SIM_T SIM_T = 2.5 * 60
assert(F.BetweenWaves(bot, list) == nil)
print('mid before 3:00: no camp')
SIM_T = later bot._waveCamp = nil
print('mid after 8:00: camp', F.BetweenWaves(bot, list) ~= nil)
print('farm ok')
-- A clear that would leave us low (the camp's own hits and spells): no camp.
pos = 1 bot._waveCamp = nil creeps = {} neutrals = { {} } bot.loc = Vector(0, 0) SIM_T = 5 * 60
hp = 600
assert(F.BetweenWaves(bot, list) == nil)
print('at 60% HP, the clear would leave under 55%: no camp')
hp = 1000
print('cost of a small camp at 5:00:', math.floor(F.CampCost(bot, list[1].cattr)))
-- A lost lane: the jungle even with the wave there.
pos = 1 bot._waveCamp = nil creeps = { {} } neutrals = { {} } bot.loc = Vector(0, 0) SIM_T = 6 * 60 hp = 1000
assert(F.BetweenWaves(bot, list) == nil)
bot._lostLaneUntil = SIM_T + 120
local j = F.BetweenWaves(bot, list)
print('lane lost, wave there: camp', j and j.cattr.type)
assert(j ~= nil)
bot._lostLaneUntil = nil
-- The wave estimate: a wave at the front vs one still to come (its wait).
do
	SIM_T = 20 * 60 + 2 -- the next wave spawns in 28 s
	function GetLaneFrontLocation() return Vector(300, 0) end
	local seenCreeps = {}
	function GetUnitList() return seenCreeps end
	local unseenRate, _, seen0 = F.WaveRate(bot, LANE_BOT)
	local function creep(name) local c = { name = name } function c:IsNull() return false end function c:IsAlive() return true end
		function c:GetLocation() return Vector(400, 0) end function c:GetUnitName() return self.name end function c:GetHealth() return 450 end return c end
	seenCreeps = { creep('creep_badguys_melee'), creep('creep_badguys_melee'), creep('creep_badguys_melee'), creep('creep_badguys_ranged') }
	local seenRate, _, seen1 = F.WaveRate(bot, LANE_BOT)
	local camp = F.CampRate(bot, list[2].cattr)
	print(string.format('wave rate at 20:02: seen %.1f g/s, still to come %.1f g/s (camp next door %.1f)', seenRate, unseenRate, camp))
	assert(seen1 and not seen0)
	assert(seenRate > camp and unseenRate < seenRate * 0.5)
end
print('wave estimate ok')
-- Route: of two equal camps at the same distance, the one with another camp
-- next to it (Dragon Knight walked 3300-4900 to lone camps, 9105740279).
do
	SIM_T = 22 * 60 + 5
	pos = 1 bot._waveCamp = nil bot._farmCamp = nil creeps = {} neutrals = {} bot.loc = Vector(0, 0) hp = 1000
	local lone = { location = Vector(-2000, 0), team = 2, type = 'medium' }
	local pair = { location = Vector(2000, 0), team = 2, type = 'medium' }
	local next = { location = Vector(2900, 0), team = 2, type = 'medium' }
	local camps = { { idx = 11, cattr = lone }, { idx = 12, cattr = pair }, { idx = 13, cattr = next } }
	GetNeutralSpawners = function() return { lone, pair, next } end
	local oldDmg = bot.GetAttackDamage
	bot.GetAttackDamage = function() return 260 end -- a 22-minute core
	local pick = F.BestCamp(bot, { camps[1], camps[2] }, function() return nil end)
	bot.GetAttackDamage = oldDmg
	print('lone vs paired camp ->', pick and pick.idx, string.format('(bonus %.1f g/s)', F.RouteBonus(bot, pair.location, pair)))
	assert(pick and pick.idx == 12)
end
print('route ok')
-- Camp safety by strength and wards: an enemy seen by our camp closes it
-- only where we lose (107 of 140 far-camp walks were "near ones unsafe",
-- 9105791662); their camp with enemies missing is open when our ward
-- watches it.
do
	SIM_T = 20 * 60
	local fight, watched = 2.0, false
	local O = { FightAt = function() return fight end, PickoffRisk = function() return false end,
		Watched = function() return watched end }
	require = function(p) if p:find('jmz_func') then return J end if p:find('objectives') then return O end end
	local F2 = dofile(BOTS..'/FunLib/farm_plan.lua')
	GetTeamPlayers = function(team) return team == 3 and { 7, 8, 9 } or { 1, 2, 3 } end
	IsHeroAlive = function() return true end
	local seen = { [7] = { location = Vector(1000, 0), time_since_seen = 2 } }
	GetHeroLastSeenInfo = function(pid) return seen[pid] and { seen[pid] } or {} end
	local our = { location = Vector(0, 0), team = 2, type = 'large' }
	local s1 = F2.IsSafe(bot, our)
	fight = 0.8
	local s2, why2 = F2.IsSafe(bot, our)
	print('our camp, enemy seen: strong', s1, '| weak', s2, why2)
	assert(s1 == true and s2 == false and why2 == 'enemy seen')
	seen = {} -- 8 and 9 (and 7) missing
	local their = { location = Vector(0, 0), team = 3, type = 'large' }
	local s3, why3 = F2.IsSafe(bot, their)
	watched = true
	local s4 = F2.IsSafe(bot, their)
	print('their camp, 3 missing: no ward', s3, why3, '| ward', s4)
	assert(s3 == false and why3 == 'enemies missing' and s4 == true)
end
print('safety ok')
