-- luajit scripts/sim/pull.lua bots : the support waits by the camp, aggroes it
-- when our next wave walks by, and drags it into the wave.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('pull.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 150
function GetTower(t, id) if id == TOWER_BOT_1 then return { GetLocation = function() return t == 2 and Vector(4900, -6100) or Vector(6200, -1600) end } end end
local FRONT = Vector(6100, -2300)
function GetLaneFrontLocation() return FRONT end
function GetLaneFrontAmount() return 0.5 end
function GetNeutralSpawners() return { { location = Vector(3500, -4500), team = 2, type = 'medium' } } end
local neutral = { loc = Vector(3550, -4500), name = 'kobold' }
function neutral:GetLocation() return self.loc end function neutral:WasRecentlyDamagedByHero() return false end
local wave = { loc = Vector(2000, -7000), name = 'creep' }
function wave:GetLocation() return self.loc end
local bot = { loc = Vector(5200, -5800) }
function bot:GetUnitName() return 'cm' end function bot:GetLocation() return self.loc end
function bot:GetAssignedLane() return LANE_BOT end function bot:GetActiveMode() return BOT_MODE_LANING end
function bot:GetAttackRange() return 600 end function bot:GetAttackDamage() return 50 end function bot:GetHealth() return 600 end
function bot:GetNearbyLaneCreeps(r, enemy) if not enemy and (self.loc - wave.loc):Length2D() < r then return { wave } end return {} end
function bot:GetNearbyNeutralCreeps(r) if (self.loc - neutral.loc):Length2D() < r then return { neutral } end return {} end
local log = {}
function bot:Action_MoveToLocation(l) local d = l - self.loc local n = d:Length2D() if n > 200 then self.loc = self.loc + d / n * 200 else self.loc = l end end
function bot:Action_AttackUnit(u) table.insert(log, 'attack '..u.name) end
function bot:SetTarget() end function bot:IsIllusion() return false end function bot:GetPlayerID() return 4 end
function GetUnitList() return {} end
local J = { GetPosition = function() return 5 end, IsValidHero = function(h) return h ~= nil end, IsValid = function(h) return h ~= nil end,
	GetHP = function() return 0.9 end, CanBeAttacked = function() return true end, CanNotUseAction = function() return false end,
	GetTeamFountain = function() return Vector(-7000, -7000) end, WillKillTarget = function() return false end,
	GetAttackProDelayTime = function() return 0.3 end, IsSuspiciousIllusion = function() return false end }
function require(p) if p:find('jmz_func') then return J end if p:find('objectives') then return { FightValue = function() return 5, 1, 0 end } end end
local L = dofile(BOTS..'/FunLib/lane_play.lua')
local aggroAt
for i = 1, 80 do
	SIM_T = SIM_T + 0.5
	-- The next wave walks from our base past the camp.
	wave.loc = wave.loc + Vector(60, 90)
	L.SupportThink(bot)
	if bot._pull and bot._pull.state == 'drag' then neutral.loc = neutral.loc + (bot.loc - neutral.loc) * 0.5 end
	if not aggroAt and log[#log] == 'attack kobold' then aggroAt = SIM_T end
	if aggroAt and not bot._pull then break end
end
local d = (wave.loc - Vector(3500, -4500)):Length2D()
print(string.format('aggro at %.1f, wave %.0f from camp at the end', aggroAt or -1, d))
assert(aggroAt, 'never pulled')
print('pull ok')
