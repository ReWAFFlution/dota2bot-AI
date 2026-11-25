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
