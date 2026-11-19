-- luajit scripts/sim/early.lua bots : bounty runes by lane (7.42 map: one by
-- each side lane); safe pair -> the one by its safe lane, off pair -> the other.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('early.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
RUNE_BOUNTY_1, RUNE_BOUNTY_2, RUNE_BOUNTY_3, RUNE_BOUNTY_4, RUNE_POWERUP_1, RUNE_POWERUP_2 = 2, 3, 4, 5, 0, 1
local runes = { [2] = Vector(-996, 4431), [3] = Vector(595, -4659), [4] = Vector(0, 0), [5] = Vector(0, 0), [0] = Vector(-1640, 1112), [1] = Vector(1180, -1216) }
function GetRuneSpawnLocation(r) return runes[r] end
local team = 2
function GetTeam() return team end function GetOpposingTeam() return team == 2 and 3 or 2 end
local towers = { [2] = { [TOWER_TOP_1] = Vector(-6200, 1800), [TOWER_MID_1] = Vector(-1500, -1400), [TOWER_BOT_1] = Vector(4900, -6100) },
                 [3] = { [TOWER_TOP_1] = Vector(-4700, 6000), [TOWER_MID_1] = Vector(500, 0), [TOWER_BOT_1] = Vector(6200, -1600) } }
function GetTower(t, id) local l = towers[t][id] return l and { GetLocation = function() return l end } end
function GetTeamPlayers() return { 0, 1, 2, 3, 4 } end function IsPlayerBot() return true end
function GetTeamMember() return nil end function RandomInt(a, b) return b end function GetGameMode() return 1 end
function GetAncient() return { GetLocation = function() return Vector(0, 0) end } end
SIM_T = -60
local J = { GetTeamFountain = function() return team == 2 and Vector(-7000, -7000) or Vector(7000, 7000) end,
	GetEnemyFountain = function() return team == 2 and Vector(7000, 7000) or Vector(-7000, -7000) end }
function require(p) if p:find('jmz_func') then return J end if p:find('objectives') then return {} end end
local E = dofile(BOTS..'/FunLib/early_game.lua')
local r = E.TeamPlan()
print('Radiant: safe pair -> '..tostring(r.safeRune)..' (bottom), off pair -> '..tostring(r.offRune)..' (top), mid -> '..tostring(r.midRune))
assert(r.safeRune == 3 and r.offRune == 2 and r.midRune == nil)
team = 3
local d = E.TeamPlan()
print('Dire: safe pair -> '..tostring(d.safeRune)..' (top), off pair -> '..tostring(d.offRune)..' (bottom)')
assert(d.safeRune == 2 and d.offRune == 3)
print('early ok')
