-- luajit scripts/sim/lotus.lua bots   : walk into the pool, pluck by channel, count lotuses.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('lotus.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 400
local pool = { loc = Vector(1000, 0) }
function pool:GetLocation() return self.loc end function pool:IsNull() return false end
function pool:GetUnitName() return 'npc_dota_lotus_pool' end
function GetUnitList(t) if t == UNIT_LIST_ALL then return { pool } end return {} end
local lot, channelUntil, casts = 0, -1, 0
local bot = { loc = Vector(0, 0) }
function bot:GetLocation() return self.loc end function bot:GetUnitName() return 'cm' end
function bot:IsChanneling() return SIM_T < channelUntil end function bot:IsUsingAbility() return false end
function bot:IsCastingAbility() return false end function bot:GetActiveMode() return BOT_MODE_ROAM end function bot:WasRecentlyDamagedByAnyHero() return false end
function bot:GetAttackTarget() return nil end function bot:WasRecentlyDamagedByAnyHero() return false end
function bot:Action_MoveToLocation(l) local d = l - self.loc local n = d:Length2D() if n > 300 then self.loc = self.loc + d / n * 300 else self.loc = Vector(l.x - 150, l.y) end end
function bot:Action_ClearActions() end
function bot:GetAbilityByName(n) return n == 'ability_pluck_lotus' and { name = n } or nil end
function bot:Action_UseAbilityOnEntity(a, u) casts = casts + 1 channelUntil = SIM_T + 1.5 end
function bot:GetItemInSlot(i) if i == 0 and lot > 0 then return { GetName = function() return 'item_famango' end, GetCurrentCharges = function() return lot end } end end
function bot:FindItemSlot() return -1 end
function bot:GetAssignedLane() return LANE_BOT end function bot:GetNearbyLaneCreeps() return {} end
-- Our carry in the same lane.
local carry = { hit = false }
function carry:IsAlive() return true end function carry:GetAssignedLane() return LANE_BOT end
function carry:WasRecentlyDamagedByAnyHero() return self.hit end
function GetTeamMember(i) if i == 1 then return carry end if i == 5 then return bot end end
local J = { GetHP = function() return 0.9 end, GetPosition = function(u) return u == carry and 1 or 5 end, IsGoingOnSomeone = function() return false end,
	IsRetreating = function() return false end, GetNearbyHeroes = function() return {} end, IsValidHero = function() return false end }
function require(p) if p:find('jmz') then return J end if p:find('stuck') then return { Blocked = function() return false end } end end
local M = dofile(BOTS..'/FunLib/map_objects.lua')
for i = 1, 40 do
	SIM_T = SIM_T + 0.5
	if channelUntil > 0 and SIM_T >= channelUntil and lot == 0 then lot = 1 end -- the channel gives a lotus
	local d = M.RoamDesire(bot) bot._roamBy = 'map'
	if not d then break end
	M.RoamThink(bot)
end
print(string.format('casts=%d lotus=%d', casts, lot))
assert(lot == 1 and casts >= 1, 'lotus not picked')
-- The carry gets hit: the support doesn't go (and would turn back).
SIM_T = SIM_T + 200 carry.hit = true bot._lotusGiveUpUntil = nil
local d2 = M.RoamDesire(bot)
print('carry under attack -> lotus desire', d2)
assert(d2 == nil)
print('lotus ok')
