-- luajit scripts/sim/farmspells.lua bots : a core in the farm mode casts its
-- area nuke on a camp of 4, keeps it for one creep, and keeps mana for its
-- ultimate.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('farmspells.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 900
ABILITY_BEHAVIOR_UNIT_TARGET, ABILITY_BEHAVIOR_POINT, ABILITY_BEHAVIOR_NO_TARGET = 8, 16, 4
ABILITY_BEHAVIOR_TOGGLE, ABILITY_BEHAVIOR_CHANNELLED, ABILITY_BEHAVIOR_AUTOCAST, ABILITY_BEHAVIOR_PASSIVE = 512, 128, 4096, 2
ABILITY_TARGET_TEAM_ENEMY = 2 BOT_MODE_FARM = 17 BOT_MODE_PUSH_TOWER_TOP, BOT_MODE_PUSH_TOWER_MID, BOT_MODE_PUSH_TOWER_BOT = 8, 9, 10
local function ability(name, behavior, dmg, radius, ult, cost)
	local a = { name = name }
	function a:IsNull() return false end function a:IsPassive() return false end function a:IsHidden() return false end
	function a:IsTrained() return true end function a:IsFullyCastable() return true end function a:GetName() return name end
	function a:GetBehavior() return behavior end function a:GetTargetTeam() return ABILITY_TARGET_TEAM_ENEMY end
	function a:GetCastRange() return 700 end function a:GetAbilityDamage() return dmg end
	function a:GetSpecialValueFloat(k) if k == 'radius' then return radius end return 0 end
	function a:IsUltimate() return ult == true end function a:GetManaCost() return cost or 100 end
	return a
end
local nuke = ability('lina_light_strike_array', 16, 120, 250)
local ult = ability('lina_laguna_blade', 8, 600, 0, true, 300)
local slots = { [0] = nuke, [5] = ult }
local cast
local mana = 700
local bot = { loc = Vector(0, 0) }
function bot:IsAlive() return true end function bot:IsChanneling() return false end function bot:IsCastingAbility() return false end
function bot:IsUsingAbility() return false end function bot:IsSilenced() return false end function bot:GetLocation() return self.loc end
function bot:GetAbilityInSlot(i) return slots[i] end function bot:GetMana() return mana end function bot:GetMaxMana() return 1000 end
function bot:GetActiveMode() return BOT_MODE_FARM end
function bot:Action_UseAbilityOnLocation(a) cast = a.name end function bot:Action_UseAbility(a) cast = a.name end function bot:Action_UseAbilityOnEntity(a) cast = a.name end
local creeps = {}
local function creep(x, y, hp) local c = { loc = Vector(x, y), hp = hp } function c:GetLocation() return self.loc end function c:GetHealth() return self.hp end return c end
function bot:GetNearbyCreeps() return creeps end
function GetUnitToUnitDistance(a, b) return (a:GetLocation() - b:GetLocation()):Length2D() end
local J = { GetPosition = function() return 1 end, CanNotUseAbility = function() return false end, GetEnemiesNearLoc = function() return {} end,
	IsValid = function(u) return u ~= nil end, CanBeAttacked = function() return true end, IsRoshan = function() return false end }
function require(p) if p:find('jmz_func') then return J end error('no '..p) end
local F = dofile(BOTS..'/FunLib/farm_spells.lua')
creeps = { creep(500, 0, 400), creep(560, 60, 400), creep(520, -80, 300), creep(600, 0, 500) }
F.Think(bot)
print('camp of 4 at full HP: cast', cast)
assert(cast == 'lina_light_strike_array')
cast = nil SIM_T = SIM_T + 5 creeps = { creep(500, 0, 60), creep(560, 60, 40), creep(520, -80, 30) }
F.Think(bot)
print('3 nearly dead creeps: cast', cast)
assert(cast == nil)
cast = nil SIM_T = SIM_T + 5 mana = 450 creeps = { creep(500, 0, 400), creep(560, 60, 400), creep(520, -80, 300), creep(600, 0, 500) }
F.Think(bot)
print('mana 450 (ult 300 + 75 + nuke 100 > 450): cast', cast)
assert(cast == nil)
print('farm spells ok')
