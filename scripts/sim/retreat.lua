-- luajit scripts/sim/retreat.lua bots : the retreat step bends away from the
-- enemies; a home teleport isn't safe with an enemy close by.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('retreat.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 900
function IsLocationPassable() return true end
function GetTower(team, id) if team == 2 and id == TOWER_MID_1 then return { GetLocation = function() return Vector(-1500, -1500) end } end end
local bot = { loc = Vector(0, 0), hit = true }
function bot:GetLocation() return self.loc end function bot:WasRecentlyDamagedByAnyHero() return self.hit end
local function enemy(loc, name) local e = { loc = loc, name = name or 'npc_dota_hero_lion' } function e:GetLocation() return self.loc end function e:IsIllusion() return false end function e:GetPlayerID() return 5 end
	function e:GetUnitName() return self.name end function e:GetCurrentMovementSpeed() return 300 end function e:GetEstimatedDamageToTarget() return 50 end return e end
local enemies = { enemy(Vector(-500, -300)) }
function GetUnitList(t) if t == UNIT_LIST_ENEMY_HEROES then return enemies end return {} end
function GetTeamPlayers(t) return t == 3 and { 5 } or { 0 } end function IsHeroAlive() return true end
local seen = Vector(-500, -300)
function GetHeroLastSeenInfo() return { { time_since_seen = 1, location = seen } } end
local disablers = { npc_dota_hero_lion = true }
function GetSelectedHeroName() return enemies[1].name end
function bot:HasModifier() return false end function bot:GetHealth() return 600 end
local J = { GetTeamFountain = function() return Vector(-7000, -7000) end, IsValidHero = function(h) return h ~= nil end,
	IsSuspiciousIllusion = function() return false end }
function require(p) if p:find('jmz_func') then return J end if p:find('roles_map') then return { IsDisabler = function(n) return disablers[n] == true end } end end
local O = dofile(BOTS..'/FunLib/objectives.lua')
local step = O.RetreatStep(bot)
print(string.format('enemy at (-500,-300) on the way to the fountain: step to (%d, %d)', step.x, step.y))
-- Straight line would be (-354,-354); bending away keeps it further from the enemy.
assert((step - enemies[1].loc):Length2D() > (Vector(-354, -354) - enemies[1].loc):Length2D())
print('Lion (stun) 580 away:', O.SafeToTeleport(bot)) assert(O.SafeToTeleport(bot) == false)
seen = Vector(-1400, -1400) enemies[1].loc = seen
print('Lion 1980 away (needs ~3.9 s to reach stun range):', O.SafeToTeleport(bot)) assert(O.SafeToTeleport(bot) == true)
seen = Vector(-500, -300) enemies[1].loc = seen enemies[1].name = 'npc_dota_hero_sniper'
print('Sniper (no disable) 580 away:', O.SafeToTeleport(bot)) assert(O.SafeToTeleport(bot) == true)
-- Largo fleeing to the mid T1 with Bristleback at his side, now a bit
-- ahead, now a bit behind: the goal stays the tower, every step heads to it.
bot.loc = Vector(0, 0) bot._retreatGoal = nil
local flips = 0
local lastSide
for i = 1, 8 do
	SIM_T = SIM_T + 0.5
	local off = (i % 2 == 0) and Vector(-150, -50) or Vector(100, 150) -- ahead / behind, at his side
	enemies = { enemy(bot.loc + off, 'npc_dota_hero_bristleback') }
	local st = O.RetreatStep(bot)
	local towardTower = ((st - bot.loc).x * -1 + (st - bot.loc).y * -1) > 0
	if lastSide ~= nil and towardTower ~= lastSide then flips = flips + 1 end
	lastSide = towardTower
	bot.loc = bot.loc + (st - bot.loc) * 0.3
end
print('Bristleback at the side, 8 steps: direction flips', flips, 'goal', tostring(bot._retreatGoal and bot._retreatGoal.loc))
assert(flips == 0 and lastSide == true)
-- At our own tower with a disabler (Lion) 500 away: still not safe.
bot.loc = Vector(-1500, -1300)
enemies = { enemy(Vector(-1100, -1000), 'npc_dota_hero_lion') }
seen = Vector(-1100, -1000)
GetSelectedHeroName = function() return 'npc_dota_hero_lion' end
local atTower = O.SafeToTeleport(bot)
print('at our tower, Lion 500 away: safe', atTower)
assert(atTower == false)
print('retreat ok')
