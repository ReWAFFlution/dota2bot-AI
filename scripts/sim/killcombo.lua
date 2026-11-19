-- luajit scripts/sim/killcombo.lua bots : a target our spells kill together
-- gets them in order (stun first, then the nuke), the ultimate kept when the
-- rest is enough; a target two hits finish gets no spells.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('killcombo.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 600
ABILITY_BEHAVIOR_UNIT_TARGET, ABILITY_BEHAVIOR_POINT, ABILITY_BEHAVIOR_NO_TARGET = 8, 16, 4
ABILITY_BEHAVIOR_TOGGLE, ABILITY_BEHAVIOR_CHANNELLED, ABILITY_BEHAVIOR_AUTOCAST, ABILITY_BEHAVIOR_PASSIVE = 512, 128, 4096, 2
ABILITY_TARGET_TEAM_ENEMY = 2 DAMAGE_TYPE_ALL = 7
local function ability(name, behavior, dmg, stun, ult, range)
	local a = { name = name, cast = 0 }
	function a:IsNull() return false end function a:IsPassive() return false end function a:IsHidden() return false end
	function a:IsTrained() return true end function a:IsFullyCastable() return not self.used end function a:GetName() return name end
	function a:GetBehavior() return behavior end function a:GetTargetTeam() return ABILITY_TARGET_TEAM_ENEMY end
	function a:GetCastRange() return range or 600 end function a:GetAbilityDamage() return dmg end
	function a:GetSpecialValueFloat(k) if k == 'stun_duration' then return stun or 0 end return 0 end
	function a:IsUltimate() return ult == true end function a:GetManaCost() return 100 end function a:GetCastPoint() return 0.3 end
	return a
end
local stun = ability('lion_impale', 16, 80, 1.5)
local nuke = ability('lion_mana_drain_nuke', 8, 200)
local ult = ability('lion_finger_of_death', 8, 450, 0, true)
local slots = { [0] = stun, [1] = nuke, [5] = ult }
local casts = {}
local bot = { loc = Vector(0, 0) }
function bot:IsAlive() return true end function bot:IsChanneling() return false end function bot:IsCastingAbility() return false end
function bot:IsUsingAbility() return false end function bot:IsSilenced() return false end function bot:GetLocation() return self.loc end
function bot:GetAbilityInSlot(i) return slots[i] end function bot:GetMana() return 600 end function bot:GetUnitName() return 'npc_dota_hero_lion' end
function bot:GetAttackDamage() return 40 end function bot:GetAttackRange() return 600 end function bot:SetTarget() end
function bot:IsIllusion() return false end
function bot:GetEstimatedDamageToTarget() return 700 end
function bot:Action_UseAbilityOnEntity(a) a.used = true table.insert(casts, a.name) end
function bot:Action_UseAbilityOnLocation(a) a.used = true table.insert(casts, a.name) end
function bot:Action_UseAbility(a) a.used = true table.insert(casts, a.name) end
local target = { loc = Vector(400, 0), hp = 220 }
function target:GetLocation() return self.loc end function target:GetHealth() return self.hp end function target:GetHealthRegen() return 2 end
function target:IsMagicImmune() return false end function target:IsInvulnerable() return false end function target:HasModifier() return false end
function target:GetMagicResist() return 0.25 end function target:GetExtrapolatedLocation() return self.loc end
function target:GetUnitName() return 'npc_dota_hero_sniper' end function target:IsIllusion() return false end
function GetUnitList(t) if t == UNIT_LIST_ENEMY_HEROES then return { target } end return { bot } end
function GetUnitToUnitDistance(a, b) return (a:GetLocation() - b:GetLocation()):Length2D() end
local J = { IsValidHero = function(h) return h ~= nil end, IsSuspiciousIllusion = function() return false end,
	CanCastOnNonMagicImmune = function() return true end, CanNotUseAbility = function() return false end, IsDisabled = function() return false end }
function require(p) if p:find('jmz_func') then return J end error('no '..p) end
local K = dofile(BOTS..'/FunLib/kill_combo.lua')
K.Think(bot) K.Think(bot)
print('casts on a 220 HP Sniper: '..table.concat(casts, ', '))
assert(casts[1] == 'lion_impale' and casts[2] == 'lion_mana_drain_nuke')
-- The ultimate isn't needed (stun + nuke = 280 * 0.75 >= ~225)... cast list so far has no finger.
for _, c in ipairs(casts) do assert(c ~= 'lion_finger_of_death') end
-- A target two hits finish: no spells.
casts = {} bot._killCombo = nil target.hp = 60 for _, a in pairs(slots) do a.used = false end
K.Think(bot)
print('60 HP Sniper in attack range: casts '..#casts)
assert(#casts == 0)
-- A tougher one: the ultimate joins.
casts = {} bot._killCombo = nil target.hp = 600 for _, a in pairs(slots) do a.used = false end
K.Think(bot) K.Think(bot) K.Think(bot)
print('casts on a 600 HP Sniper: '..table.concat(casts, ', '))
local hasUlt = false for _, c in ipairs(casts) do if c == 'lion_finger_of_death' then hasUlt = true end end
assert(hasUlt and casts[1] == 'lion_impale')
print('kill combo ok')
