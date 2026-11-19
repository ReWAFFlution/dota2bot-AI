local Defend = require( GetScriptDirectory()..'/FunLib/aba_defend')

local bot = GetBot()
local botName = bot:GetUnitName()

if bot:IsInvulnerable() or not bot:IsHero() or not string.find(botName, "hero") or bot:IsIllusion() then
	return
end

local Objectives = require(GetScriptDirectory()..'/FunLib/objectives')

-- Objectives: bots assigned by the score system come to defend.
function GetDesire() return math.max(Objectives.FilterDefendDesire(bot, LANE_TOP, Defend.GetDefendDesire(bot, LANE_TOP)), Objectives.DefendDesire(bot, LANE_TOP)) end
function Think()
	if Objectives.DefendThink(bot, LANE_TOP) then return end -- fight under the tower / hold behind it
	Defend.DefendThink(bot, LANE_TOP)
end
