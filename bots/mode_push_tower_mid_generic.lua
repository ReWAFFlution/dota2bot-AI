local Push = require( GetScriptDirectory()..'/FunLib/aba_push')
local TeamPlan = require(GetScriptDirectory()..'/FunLib/team_plan')
local Objectives = require(GetScriptDirectory()..'/FunLib/objectives')
local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end
if bot.PushLaneDesire == nil then bot.PushLaneDesire = {0, 0, 0} end

function GetDesire()
    -- Objectives: join a push an ally started when the expected points are worth it.
    bot.PushLaneDesire[LANE_MID] = Objectives.CapPushWhenLosing(bot, math.max(TeamPlan.AdjustPushDesire(bot, LANE_MID, Push.GetPushDesire(bot, LANE_MID)), Objectives.PushDesire(bot, LANE_MID), Objectives.SplitPushDesire(bot, LANE_MID)))
    return bot.PushLaneDesire[LANE_MID]
end
function Think()
    if Objectives.PushThink(bot, LANE_MID) then return end -- get to the ally's push (TP if far)
    if Objectives.BaseSiegeThink(bot) then return end -- their high ground: barracks first
    if TeamPlan.PushFormationThink(bot, LANE_MID) then return end -- tank goes first
    if Objectives.RangedSiegeThink(bot) then return end -- ranged: hit the tower from full range
    Push.PushThink(bot, LANE_MID)
end
