-- luajit scripts/sim/dodge.lua bots : a skillshot flying at us is dodged
-- sideways, one passing wide or an ally's is ignored; standing in an enemy
-- area spell steps out past its edge.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('dodge.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
local J = { GetTeamFountain = function() return Vector(-7000, -7000) end }
function require(p) if p:find('jmz_func') then return J end end
SIM_T = 300
local enemy = { GetTeam = function() return 3 end, IsNull = function() return false end }
local ally = { GetTeam = function() return 2 end, IsNull = function() return false end }
local hook = { GetName = function() return 'pudge_meat_hook' end }
local projs, zones = {}, {}
function GetLinearProjectiles() return projs end
function GetAvoidanceZones() return zones end
function IsLocationPassable() return true end
local bot = { loc = Vector(0, 0) }
function bot:GetLocation() return self.loc end function bot:IsAlive() return true end function bot:IsChanneling() return false end
function bot:GetUnitName() return 'npc_dota_hero_lina' end
local moved
function bot:Action_MoveToLocation(l) moved = l end
local D = dofile(BOTS..'/FunLib/dodge.lua')
local function fresh() SIM_T = SIM_T + 0.1 moved = nil end

-- A hook 800 away flying straight at us, 20 off its line.
fresh()
projs = { { location = Vector(-800, 20), velocity = Vector(1450, 0), radius = 100, caster = enemy, ability = hook } }
assert(D.Desire(bot) > 0.9) D.Think(bot)
print('hook at us: moves to', moved.x, moved.y)
assert(moved and moved.y < -150 or moved.y > 150)
-- The same hook 400 wide: nothing.
fresh()
projs = { { location = Vector(-800, 400), velocity = Vector(1450, 0), radius = 100, caster = enemy, ability = hook } }
assert(D.Desire(bot) == 0)
print('hook 400 wide: no dodge')
-- Already past us: nothing.
fresh()
projs = { { location = Vector(300, 0), velocity = Vector(1450, 0), radius = 100, caster = enemy, ability = hook } }
assert(D.Desire(bot) == 0)
print('hook past us: no dodge')
-- An ally's: nothing.
fresh()
projs = { { location = Vector(-800, 0), velocity = Vector(1450, 0), radius = 100, caster = ally, ability = hook } }
assert(D.Desire(bot) == 0)
print("ally's projectile: no dodge")
-- Standing in an enemy Light Strike Array.
fresh()
projs = {}
zones = { { location = Vector(50, 0), radius = 250, caster = enemy, ability = { GetName = function() return 'lina_light_strike_array' end } } }
assert(D.Desire(bot) > 0.9) D.Think(bot)
print('in a light strike array: moves to', moved.x, moved.y, 'distance from its center', math.floor((moved - Vector(50, 0)):Length2D()))
assert((moved - Vector(50, 0)):Length2D() > 250 + 32)
-- An ally's zone: nothing.
fresh()
zones = { { location = Vector(50, 0), radius = 250, caster = ally } }
assert(D.Desire(bot) == 0)
print("ally's zone: no dodge")
-- The same enemy zone 3 s later (a lasting one, like Shrapnel): no dodge.
fresh()
zones = { { location = Vector(50, 0), radius = 250, caster = enemy, ability = { GetName = function() return 'lina_light_strike_array' end } } }
SIM_T = SIM_T + 3
assert(D.Desire(bot) == 0)
print('lasting zone (3 s): no dodge')
print('dodge ok')
