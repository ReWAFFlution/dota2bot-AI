-- luajit scripts/sim/pickoff.lua bots : a hero alone out of tower cover where
-- unseen enemies may be is at risk; with an ally, near our tower or with the
-- enemies seen far away, it isn't.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('pickoff.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 1200
function DotaTime() return SIM_T end
function GetTeam() return 2 end function GetOpposingTeam() return 3 end
local ourTower = { loc = Vector(-6000, -6000) } function ourTower:GetLocation() return self.loc end
function GetTower(team, id) if team == 2 and id == TOWER_MID_2 then return ourTower end end
function GetTeamPlayers(team) return team == 3 and { 5, 6, 7, 8, 9 } or { 0, 1, 2, 3, 4 } end
function IsHeroAlive() return true end
local seen = {}
function GetHeroLastSeenInfo(pid) return { seen[pid] } end
local allies = {}
function GetUnitList() return allies end
local pos = 5
local bot = { loc = Vector(2000, 2000) } function bot:GetLocation() return self.loc end function bot:GetUnitName() return 'npc_dota_hero_lion' end
local J = { GetPosition = function() return pos end, GetTeamFountain = function() return Vector(-7000, -7000) end,
	GetEnemyFountain = function() return Vector(7000, 7000) end, IsValidHero = function(u) return u ~= nil end, GetHP = function() return 1 end }
function require(p) if p:find('jmz_func') then return J end end
local O = dofile(BOTS..'/FunLib/objectives.lua')
local fight = 0.8 O.FightAt = function() return fight end
local function Seen(pid, x, y, tss) seen[pid] = { location = Vector(x, y), time_since_seen = tss } end
for pid = 5, 9 do Seen(pid, 7000, 7000, 1) end -- all at their fountain, just seen
local loc = Vector(2000, 2000)
assert(not O.PickoffRisk(bot, loc), 'all seen far away')
Seen(5, 4000, 4000, 6) -- unseen 6 s, 2800 away: may be here
assert(O.PickoffRisk(bot, loc), 'support, enemy half, one may be there')
pos = 1 assert(not O.PickoffRisk(bot, loc), 'core needs two')
Seen(6, 3000, 1000, 10) Seen(7, -3000, 6000, 60) -- long gone: doesn't count
 assert(O.PickoffRisk(bot, loc), 'core, two may be there')
fight = 1.5 assert(not O.PickoffRisk(bot, loc), 'two may be there, but we win there by strength') fight = 0.8
local near = Vector(-5000, -5000) assert(not O.PickoffRisk(bot, near), 'near our tower')
SIM_T = 200 assert(not O.PickoffRisk(bot, loc), 'too early') SIM_T = 1200
print('pickoff ok')
