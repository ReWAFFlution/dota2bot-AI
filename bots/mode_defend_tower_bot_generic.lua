local Defend = require( GetScriptDirectory()..'/FunLib/aba_defend')

local bot = GetBot()
local botName = bot:GetUnitName()

if bot:IsInvulnerable() or not bot:IsHero() or not string.find(botName, "hero") or bot:IsIllusion() then
	return
end

local Objectives = require(GetScriptDirectory()..'/FunLib/objectives')

-- Objectives: bots assigned by the score system come to defend.
function GetDesire() return math.max(Objectives.FilterDefendDesire(bot, LANE_BOT, Defend.GetDefendDesire(bot, LANE_BOT)), Objectives.DefendDesire(bot, LANE_BOT)) end
function Think()
	if Objectives.DefendThink(bot, LANE_BOT) then return end -- fight under the tower / hold behind it
	Defend.DefendThink(bot, LANE_BOT)
end
