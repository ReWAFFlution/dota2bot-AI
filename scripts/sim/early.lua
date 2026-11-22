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
function require(p) if p:find('jmz_func') then return J end if p:find('objectives') then return OBJ end end
OBJ = { FightAt = function() return FIGHT_AT or 99 end }
local E = dofile(BOTS..'/FunLib/early_game.lua')
local r = E.TeamPlan()
print('Radiant: safe pair -> '..tostring(r.safeRune)..' (bottom), off pair -> '..tostring(r.offRune)..' (top), mid -> '..tostring(r.midRune))
assert(r.safeRune == 3 and r.offRune == 2 and r.midRune == nil)
team = 3
local d = E.TeamPlan()
print('Dire: safe pair -> '..tostring(d.safeRune)..' (top), off pair -> '..tostring(d.offRune)..' (bottom)')
assert(d.safeRune == 2 and d.offRune == 3)
-- Dire Techies (pos 4, off pair -> bottom bounty) with Lifestealer standing
-- on the rune: we lose there, so it goes to lane instead of walking in.
J.GetPosition = function() return 4 end
J.IsValidHero = function(h) return h ~= nil end J.IsSuspiciousIllusion = function() return false end
local techies = { IsIllusion = function() return false end, GetUnitName = function() return 'npc_dota_hero_techies' end, GetLocation = function() return Vector(1500, -3500) end }
local ls = { GetLocation = function() return Vector(600, -4600) end, IsIllusion = function() return false end }
function GetUnitList(t) if t == UNIT_LIST_ENEMY_HEROES then return { ls } end return { techies } end
function GetUnitToLocationDistance(u, l) return (u:GetLocation() - l):Length2D() end
FIGHT_AT = 0.3 -- below 0.6
local dz = E.GetDesire(techies)
print('Techies, Lifestealer on the bounty (x0.3): rune desire', dz)
-- Before the horn the module keeps it (walks it to its tower); after, nil.
assert(techies._earlyDone and techies._earlyGaveUp and (dz == nil or (DotaTime() < 0 and dz == 0.9)))
print('early ok')
