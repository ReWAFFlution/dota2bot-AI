-- luajit scripts/sim/humanwatch.lua bots : the human recorder logs a camp
-- entry, a new item and a 5-minute summary without errors.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('humanwatch.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
TEAM_NEUTRAL = 4
SIM_T = 600
local camp = { location = Vector(-3000, 500), team = 2, type = 'large' }
function GetNeutralSpawners() return { camp } end
function GetLaneFrontLocation() return Vector(6000, 6000) end
local neutral = { IsNull = function() return false end, IsHero = function() return false end, IsBuilding = function() return false end,
	IsTower = function() return false end, GetTeam = function() return TEAM_NEUTRAL end }
local item = nil
local h = { loc = Vector(-3100, 450) }
function h:IsBot() return false end function h:IsIllusion() return false end function h:GetPlayerID() return 0 end
function h:GetUnitName() return 'npc_dota_hero_terrorblade' end function h:IsAlive() return true end
function h:GetLocation() return self.loc end function h:DistanceFromFountain() return 6000 end
function h:GetAttackTarget() return neutral end function h:IsChanneling() return false end function h:IsCastingAbility() return false end
function h:GetItemInSlot(i) if i == 0 then return item end end function h:GetLastHits() return 42 end function h:GetNetWorth() return 4000 end
function GetTeamMember(i) if i == 1 then return h end end
function GetItemCost(n) return n == 'item_manta' and 4600 or 0 end
function require(p) if p:find('jmz_func') then return {} end error('no '..p) end
local W = dofile(BOTS..'/FunLib/human_watch.lua')
local out = {}
local realPrint = print
print = function(s) table.insert(out, s) realPrint(s) end
for i = 1, 310 do
	SIM_T = SIM_T + 1
	if i == 200 then item = { GetName = function() return 'item_manta' end } end
	W.Update()
end
print = realPrint
local all = table.concat(out, '\n')
assert(all:find('camp large %(own%)'), 'no camp line')
assert(all:find('item item_manta'), 'no item line')
assert(all:find('jungle_own'), 'no summary')
print('human watch ok')
