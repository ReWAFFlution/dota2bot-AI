-- luajit scripts/sim/defend.lua bots : a hero farming near our tower (out of its
-- range, tower not losing HP) isn't a threat: no standing guard. One that hits
-- the tower is.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('defend.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end

function GetAncient() return { GetLocation = function() return Vector(-7000, -6500) end, IsAlive = function() return true end, GetHealth = function() return 4000 end } end
SIM_T = 600
local towerHP = 1800
local tower = { loc = Vector(-6000, 1800) }
function tower:GetLocation() return self.loc end function tower:GetHealth() return towerHP end
function tower:IsAlive() return true end function tower:IsNull() return false end function tower:GetUnitName() return 'tower1_top' end
function GetTower(team, id) if team == 2 and id == TOWER_TOP_1 then return tower end end
function GetBarracks() return true end RUNE_STATUS_AVAILABLE = 1 function GetRuneStatus() return 0 end
local function hero(name, loc, team)
	local u = { name = name, loc = loc }
	function u:GetUnitName() return name end function u:GetLocation() return self.loc end function u:IsAlive() return true end
	function u:IsIllusion() return false end function u:GetPlayerID() return 0 end function u:IsBot() return true end function u:IsHero() return true end
	function u:IsChanneling() return false end function u:GetNetWorth() return 1000 end function u:DistanceFromFountain() return 5000 end
	function u:Action_MoveToLocation(l) self.last = 'move' end function u:Action_AttackUnit(t) self.last = 'attack '..t.name end
	function u:SetTarget() end function u:GetNearbyCreeps() return {} end function u:GetHealth() return 1000 end
	function u:GetEstimatedDamageToTarget() return 100 end function u:FindItemSlot() return -1 end function u:GetLevel() return 8 end
	function u:CanBeSeen() return true end function u:GetCurrentMovementSpeed() return 300 end function u:GetAssignedLane() return LANE_TOP end
	function u:WasRecentlyDamagedByHero() return false end function u:IsStunned() return false end function u:IsRooted() return false end
	function u:HasModifier() return false end function u:GetMaxHealth() return 2000 end function u:GetMana() return 300 end function u:GetAbilityByName() return nil end
	function u:IsHexed() return false end function u:GetAttackTarget() return self.atk end function u:IsSilenced() return false end function u:IsNightmared() return false end
	return u
end
local medusa = hero('medusa', Vector(-6100, 1500))
local human = hero('human', Vector(-6000, 2800), 3)
local enemies = { human }
function GetUnitList(t) if t == UNIT_LIST_ENEMY_HEROES then return enemies end if t == UNIT_LIST_ALLIED_HEROES then return { medusa } end return {} end
function GetTeamMember(i) if i == 1 then return medusa end end
function GetTeamPlayers(t) return { 0 } end function IsHeroAlive() return true end
function GetHeroLastSeenInfo() return { { time_since_seen = 1, location = Vector(0, 0) } } end
function GetLaneFrontLocation() return Vector(-6000, 2500) end
local J = { GetPosition = function() return 3 end, IsValidHero = function(h) return h ~= nil end, IsValid = function(h) return h ~= nil end,
	GetHP = function() return 0.9 end, GetMP = function() return 0.5 end, CanBeAttacked = function() return true end,
	CanNotUseAction = function() return false end, GetTeamFountain = function() return Vector(-7000, -7000) end,
	GetNearbyHeroes = function() return {} end, GetEnemiesAroundAncient = function() return 0 end, IsSuspiciousIllusion = function() return false end }
function require(p) if p:find('jmz_func') then return J end end
local O = dofile(BOTS..'/FunLib/objectives.lua')
for i = 1, 3 do SIM_T = SIM_T + 1 O.Update() end
local d1 = O.FilterDefendDesire(medusa, LANE_TOP, 0.7)
local t1 = O.DefendThink(medusa, LANE_TOP)
print('human farming 1000 away, tower fine: desire', d1, 'defend think acted', t1)
assert(d1 <= 0.2 and t1 == false)
-- Now the human hits the tower.
human.loc = Vector(-6000, 2300) human.atk = tower
for i = 1, 3 do SIM_T = SIM_T + 1 towerHP = towerHP - 60 O.Update() end
local d2 = O.FilterDefendDesire(medusa, LANE_TOP, 0.7)
print('tower losing HP: desire', d2)
assert(d2 == 0.7)
-- The exchange there says get out (a strong carry came): retreat wins.
medusa._combat = { retreat = true } medusa._fightHintT = SIM_T
local d3 = O.FilterDefendDesire(medusa, LANE_TOP, 0.7)
print('losing the fight there: desire', d3, 'assigned', O.DefendDesire(medusa, LANE_TOP))
assert(d3 <= 0.3 and O.DefendDesire(medusa, LANE_TOP) == 0)
-- An enemy farming the wave right at the tower (500 away) but not hitting
-- it, tower HP steady: no standing guard.
human.atk = nil human.loc = Vector(-6000, 2300) medusa._combat = nil
for i = 1, 10 do SIM_T = SIM_T + 1 O.Update() end
local d4 = O.FilterDefendDesire(medusa, LANE_TOP, 0.7)
print('enemy farming at the tower, not hitting it: desire', d4)
assert(d4 <= 0.2)
print('defend ok')
