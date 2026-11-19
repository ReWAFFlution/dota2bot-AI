-- luajit scripts/sim/siege.lua bots : a ranged hero hits a tower from its full
-- range instead of walking up to it.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('siege.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 900
local tower = { loc = Vector(0, 0), target = nil }
function tower:GetLocation() return self.loc end function tower:IsNull() return false end function tower:IsAlive() return true end
function tower:HasModifier() return false end function tower:GetAttackTarget() return self.target end
function GetTower(team, id) if team == 3 and id == TOWER_MID_1 then return tower end end
local creep = { loc = Vector(-300, 0) } function creep:GetLocation() return self.loc end
local sniper = { loc = Vector(-1500, 0) }
function sniper:GetLocation() return self.loc end function sniper:GetAttackRange() return 1000 end
function sniper:GetNearbyLaneCreeps(r, enemy) if not enemy then return { creep } end return {} end
function sniper:Action_MoveToLocation(l) self.last = string.format('move to %d', l.x) self.loc = l end
function sniper:Action_AttackUnit(t) self.last = 'attack tower from '..math.floor((self.loc - t.loc):Length2D()) end
local J = { CanNotUseAction = function() return false end, CanBeAttacked = function() return true end, IsValid = function(u) return u ~= nil end }
function require(p) if p:find('jmz_func') then return J end end
local O = dofile(BOTS..'/FunLib/objectives.lua')
O.RangedSiegeThink(sniper) print(sniper.last)
O.RangedSiegeThink(sniper) print(sniper.last)
assert(sniper.last:find('attack tower from 9'))
print('siege ok')
