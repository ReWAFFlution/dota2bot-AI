-- luajit scripts/sim/combat.lua bots : time to kill both ways decides go/retreat.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('combat.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 900
DAMAGE_TYPE_MAGICAL = 2
local function hero(name, team, loc, hp, dps)
	local u = { name = name, team = team, loc = loc, hp = hp, dps = dps, items = {} }
	function u:GetUnitName() return 'npc_dota_hero_'..name end function u:GetLocation() return self.loc end
	function u:IsAlive() return true end function u:IsIllusion() return false end function u:GetPlayerID() return 0 end
	function u:GetHealth() return self.hp end function u:GetMaxHealth() return 2000 end function u:GetHealthRegen() return 5 end
	function u:GetEstimatedDamageToTarget(_, _, secs, dtype) return dtype == DAMAGE_TYPE_MAGICAL and self.dps * 0.3 * secs or self.dps * secs end
	function u:FindItemSlot(n) return self.items[n] and 0 or -1 end
	function u:GetItemInSlot() return { IsFullyCastable = function() return true end } end
	function u:CanBeSeen() return true end function u:HasModifier() return false end
	function u:GetMana() return self.mana or 0 end
	return u
end
local me = hero('sven', 2, Vector(0, 0), 1800, 250)
local allies, enemies = { me }, {}
function GetUnitList(t) if t == UNIT_LIST_ENEMY_HEROES then return enemies end if t == UNIT_LIST_ALLIED_HEROES then return allies end return {} end
function GetTower() return nil end function GetTeamMember(i) return allies[i] end
function GetTeamPlayers() return { 0 } end function IsHeroAlive() return true end
local J = { IsValidHero = function(h) return h ~= nil end, CanBeAttacked = function() return true end, GetHP = function(u) return u.hp / 2000 end,
	GetMP = function() return 0.8 end, IsSuspiciousIllusion = function() return false end, GetPosition = function() return 1 end,
	GetEnemyFountain = function() return Vector(7000, 7000) end, GetTeamFountain = function() return Vector(-7000, -7000) end }
function require(p) if p:find('jmz_func') then return J end if p:find('roles_map') then return { IsDisabler = function() return false end, HasEscape = function() return false end } end end
local O = dofile(BOTS..'/FunLib/objectives.lua')
local function show(label) local c = O.Combat(me) print(string.format('%-28s us %4.0f s  them %4.0f s  go=%s retreat=%s', label, c.ttkUs, c.ttkThem, tostring(c.go), tostring(c.retreat))) return c end
enemies = { hero('lina', 3, Vector(400, 0), 600, 150) }
local c = show('1v1 vs hurt Lina') assert(c.go and not c.retreat)
enemies = { hero('lina', 3, Vector(400, 0), 1400, 300), hero('lion', 3, Vector(300, 200), 1300, 300), hero('pudge', 3, Vector(200, -200), 2500, 250) }
c = show('1v3 full HP') assert(c.retreat and not c.go)
me.items.item_blink = true me.hp = 1800
c = show('1v3 with Blink ready') print('(escape adds 40% HP to survive the burst)')
-- Medusa: her mana is HP. Full mana she outlasts us; drained she's a kill.
me.items = {} me.hp = 1800
local medusa = hero('medusa', 3, Vector(400, 0), 600, 150) medusa.mana = 1000
enemies = { medusa }
c = show('1v1 hurt Medusa, full mana') assert(not c.go)
medusa.mana = 50
c = show('1v1 hurt Medusa, drained') assert(c.go)
-- 4v4 with a clear edge: their combos together would kill one bot in a
-- second, but they don't all hit the same hero; our group burns theirs faster.
me.hp = 1500
allies = { me, hero('mk', 2, Vector(100, 100), 1800, 420), hero('sf', 2, Vector(-100, 50), 1500, 450), hero('nyx', 2, Vector(50, -120), 1300, 300) }
enemies = { hero('medusa', 3, Vector(600, 0), 1500, 260), hero('pango', 3, Vector(650, 150), 1200, 260),
	hero('ven', 3, Vector(550, -150), 900, 220), hero('wk', 3, Vector(700, 50), 1700, 260) }
for _, e in ipairs(enemies) do e.mana = 0 end
c = show('4v4, our group stronger') print(string.format('team ratio x%.2f', c.teamRatio))
assert(c.teamRatio > 1.2 and not c.retreat and c.go)
-- The same won fight right at their fountain: no chase, step back.
local ef = Vector(7000, 7000)
for _, e in ipairs(enemies) do e.loc = ef + (e.loc - Vector(600, 0)) end
me.loc = ef + Vector(-900, -900) for i = 2, #allies do allies[i].loc = me.loc end
c = show('same fight at their fountain') assert(c.retreat and not c.go)
-- An enemy next to us, even odds: decide, don't idle.
me.loc, me.hp = Vector(0, 0), 1500
allies = { me } enemies = { hero('wk', 3, Vector(500, 0), 1800, 250) }
c = show('1v1 even, enemy close') assert(c.go or c.retreat)
print('combat ok')
