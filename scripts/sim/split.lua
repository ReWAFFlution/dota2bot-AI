-- luajit scripts/sim/split.lua bots : a core takes an open enemy tower with
-- our wave at it when nobody defends; not into a lost fight; the farming
-- carry not across the map.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('split.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 900
function DotaTime() return SIM_T end
local tower = { loc = Vector(0, 0) }
function tower:GetLocation() return self.loc end function tower:IsNull() return false end function tower:IsAlive() return true end
function tower:GetUnitName() return 'npc_dota_badguys_tower1_mid' end
function GetTower(team, id) if team == 3 and id == TOWER_MID_1 then return tower end end
function GetTeam() return 2 end function GetOpposingTeam() return 3 end
function GetLaneFrontLocation(team, lane) return lane == LANE_MID and Vector(-500, 0) or Vector(-9000, -9000) end
function GetUnitToLocationDistance(u, l) return (u.loc - l):Length2D() end
local pos = 3
local bot = { loc = Vector(-1500, 0) }
function bot:GetLocation() return self.loc end function bot:GetLevel() return 10 end
function bot:GetAssignedLane() return LANE_MID end function bot:GetUnitName() return 'npc_dota_hero_terrorblade' end
function bot:GetItemInSlot() return nil end
local J = { GetPosition = function() return pos end, GetHP = function() return 0.9 end }
function require(p) if p:find('jmz_func') then return J end end
local O = dofile(BOTS..'/FunLib/objectives.lua')
O.IsIdle = function() return false end
local fight = 99
O.FightAt = function() return fight end
local function D(lane) bot._split = nil return O.SplitPushDesire(bot, lane) end
assert(D(LANE_MID) == 0.92 and D(LANE_TOP) == 0, 'open tower')
fight = 1.2 assert(D(LANE_MID) == 0, 'lost fight') fight = 99
bot.loc = Vector(-5000, 0) assert(D(LANE_MID) == 0.75, 'walk to it')
pos = 1 assert(D(LANE_MID) == 0, 'farming carry far away')
bot.loc = Vector(-1500, 0) assert(D(LANE_MID) == 0.92, 'farming carry on its route')
SIM_T = 250 assert(D(LANE_MID) == 0, 'too early')
SIM_T = 500 pos = 2 assert(D(LANE_MID) == 0.92, 'mid core, own lane, 8:20')
fight = 1.7 assert(D(LANE_MID) == 0, 'early needs x2.0') fight = 99
print('split ok')
