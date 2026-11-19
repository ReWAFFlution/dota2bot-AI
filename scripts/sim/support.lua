-- luajit scripts/sim/support.lua bots : after the laning stage a support joins
-- a fight next to it, otherwise pushes the closest safe lane.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('support.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 900
local function hero(name, pos, loc, team)
	local u = { name = name, pos = pos, loc = loc, team = team or 2, dmg = false }
	function u:GetUnitName() return 'npc_dota_hero_'..name end function u:GetLocation() return self.loc end
	function u:IsAlive() return true end function u:IsBot() return true end function u:IsHero() return true end
	function u:IsIllusion() return false end function u:GetPlayerID() return pos end
	function u:WasRecentlyDamagedByAnyHero() return self.dmg end
	function u:Action_MoveToLocation(l) self.last = string.format('move %d,%d', l.x, l.y) end
	function u:Action_AttackUnit(t) self.last = 'attack '..t.name end function u:SetTarget() end
	return u
end
local lion = hero('lion', 4, Vector(0, 0))
local axe = hero('axe', 3, Vector(2500, 0))
local mates = { hero('am', 1, Vector(-6000, -6000)), hero('sf', 2, Vector(-6000, -5000)), axe, lion, hero('cm', 5, Vector(-6500, -6500)) }
local sven = hero('sven', 1, Vector(2900, 100), 3)
local enemies = {}
function GetTeamMember(i) return mates[i] end
function GetTeamPlayers(t) return t == 2 and { 0, 1, 2, 3, 4 } or { 5, 6, 7, 8, 9 } end
function IsHeroAlive() return true end
function GetHeroLastSeenInfo() return { { time_since_seen = 1, location = Vector(9000, 9000) } } end
function GetUnitList(t) if t == UNIT_LIST_ENEMY_HEROES then return enemies end if t == UNIT_LIST_ALLIED_HEROES then return mates end return {} end
function GetTower(team, id) return { GetLocation = function() return Vector(5000, 5000) end, GetHealth = function() return 1000 end } end
function GetAncient() return { GetLocation = function() return Vector(-7000, -7000) end } end
function GetLaneFrontLocation(team, lane) return lane == LANE_TOP and Vector(-5000, 3000) or (lane == LANE_MID and Vector(500, 500) or Vector(5000, -5000)) end
function GetItemStockCount() return 1 end function GetItemCost() return 50 end
function GetNetWorth() return 0 end
local J = { GetPosition = function(u) return u.pos end, IsValidHero = function(h) return h ~= nil end, IsValid = function(h) return h ~= nil end,
	GetHP = function() return 0.9 end, CanBeAttacked = function() return true end, IsInLaningPhase = function() return false end,
	IsGoingOnSomeone = function() return false end, IsSuspiciousIllusion = function() return false end,
	GetAlliesNearLoc = function() return {} end, GetTeamFountain = function() return Vector(-7000, -7000) end,
	GetEnemyFountain = function() return Vector(7000, 7000) end, GetInventoryNetworth = function() return 0, 0 end,
	GetAverageLevel = function() return 10 end }
function require(p)
	if p:find('jmz_func') then return J end
	if p:find('objectives') then return { FightValue = function() return 5, 1, 0 end } end
	if p:find('roles_map') then return { HeroRolesMap = {}, IsDisabler = function() return false end, HasEscape = function() return false end } end
end
local P = dofile(BOTS..'/FunLib/team_plan.lua')
-- No fight: the support picks the closest safe lane to push.
print('push lane', P.SupportPushLane(lion))
assert(P.SupportPushLane(lion) == LANE_MID)
-- Axe trades with Sven next to us: the support joins.
enemies = { sven } axe.dmg = true
print('fight ally', P.SupportFightToJoin(lion) and P.SupportFightToJoin(lion).name)
assert(P.SupportFightToJoin(lion) == axe)
print('support ok')
