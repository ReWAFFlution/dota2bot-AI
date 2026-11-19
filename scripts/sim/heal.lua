-- luajit scripts/sim/heal.lua bots : heal/mana skills go to whoever needs them;
-- emergency ultimates only to save someone under attack.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('heal.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 600
local function ability(name, opts)
	opts = opts or {}
	local a = { name = name }
	function a:IsTrained() return true end function a:IsPassive() return false end function a:IsFullyCastable() return true end
	function a:GetManaCost() return opts.cost or 100 end function a:GetCastRange() return opts.range or 700 end
	function a:GetSpecialValueInt() return opts.restore or 0 end function a:GetToggleState() return false end
	return a
end
local function hero(name, hp, loc)
	local u = { name = name, hp = hp, loc = loc, mana = 400, maxMana = 500, hit = false }
	function u:GetUnitName() return name end function u:GetLocation() return self.loc end function u:IsAlive() return true end
	function u:IsIllusion() return false end function u:HasModifier() return false end
	function u:WasRecentlyDamagedByAnyHero() return self.hit end function u:WasRecentlyDamagedByTower() return false end
	function u:GetMana() return self.mana end function u:GetMaxMana() return self.maxMana end
	return u
end
local omni = hero('omniknight', 0.9, Vector(0, 0))
omni.abilities = { omniknight_purification = ability('omniknight_purification') }
function omni:GetAbilityByName(n) return self.abilities[n] end
function omni:IsChanneling() return false end function omni:IsCastingAbility() return false end function omni:IsUsingAbility() return false end
function omni:IsSilenced() return false end
local cast
function omni:Action_UseAbilityOnEntity(a, t) cast = a.name..' -> '..t.name end
function omni:Action_UseAbility(a) cast = a.name end
local carry = hero('carry', 0.45, Vector(300, 0))
local mates = { omni, carry }
function GetTeamMember(i) return mates[i] end
local J = { GetHP = function(u) return u.hp end, CanNotUseAction = function() return false end }
function require(p) if p:find('jmz') then return J end end
local S = dofile(BOTS..'/FunLib/support_skills.lua')
S.Think(omni) print('hurt carry:', cast) assert(cast == 'omniknight_purification -> carry')
-- Chen's ultimate: not for a hurt ally who isn't being hit; yes when he is.
cast = nil carry.hp = 0.2 omni.abilities = { chen_hand_of_god = ability('chen_hand_of_god') }
S.Think(omni) print('low, safe:', cast) assert(cast == nil)
carry.hit = true S.Think(omni) print('low, hit:', cast) assert(cast == 'chen_hand_of_god')
-- KotL mana to the ally missing the most.
cast = nil omni.abilities = { keeper_of_the_light_chakra_magic = ability('keeper_of_the_light_chakra_magic', { restore = 150 }) }
carry.mana = 100 S.Think(omni) print('mana:', cast) assert(cast == 'keeper_of_the_light_chakra_magic -> carry')
print('heal ok')
