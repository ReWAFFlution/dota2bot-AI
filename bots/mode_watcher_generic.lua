-- Watchers (lanterns): the engine's own DOTA_BOT_MODE_WATCHER (no BOT_MODE_
-- constant in Lua; "mode 28" in the mode report). Bots stood in it 40-50% of
-- the time (Lion, Pugna), and cores walked to watchers between camps. This
-- file takes over its desire; the engine's Think still does the capture.
--   * cores: never;
--   * supports: a watcher within 1200, no enemy hero within 1200, not taken
--     by this bot in the last 5 minutes, not idle;
--   * standing within 400 of it for 6 s counts as taken (the mode lets go).

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Objectives = require(GetScriptDirectory()..'/FunLib/objectives')
local okM, MapObjects = pcall(require, GetScriptDirectory()..'/FunLib/map_objects')
if not okM then MapObjects = nil end

local bot = GetBot()

local REACH = 1200
local AGAIN = 300
local STAND = 6

local function Key(l) return math.floor(l.x)..':'..math.floor(l.y) end

local function Closest()
	if not MapObjects or not MapObjects.LANTERNS then return nil end
	local best, bd
	for _, l in ipairs(MapObjects.LANTERNS) do
		local d = GetUnitToLocationDistance(bot, l)
		if not bd or d < bd then best, bd = l, d end
	end
	return best, bd
end

function GetDesire()
	if not bot:IsAlive() or bot:IsIllusion() then return BOT_MODE_DESIRE_NONE end
	if J.GetPosition(bot) < 4 then return BOT_MODE_DESIRE_NONE end
	if DotaTime() < 0 or Objectives.IsIdle(bot) or J.GetHP(bot) < 0.5 then return BOT_MODE_DESIRE_NONE end
	local l, d = Closest()
	if not l or d > REACH then return BOT_MODE_DESIRE_NONE end
	bot._watcherTaken = bot._watcherTaken or {}
	local key = Key(l)
	local t = DotaTime()
	if t < (bot._watcherTaken[key] or -math.huge) + AGAIN then return BOT_MODE_DESIRE_NONE end
	if #J.GetEnemiesNearLoc(bot:GetLocation(), 1200) > 0 then return BOT_MODE_DESIRE_NONE end
	-- Standing at it long enough: taken.
	if d < 400 then
		bot._watcherAtT = bot._watcherAtT or t
		if t - bot._watcherAtT > STAND then
			bot._watcherTaken[key] = t
			bot._watcherAtT = nil
			return BOT_MODE_DESIRE_NONE
		end
	else
		bot._watcherAtT = nil
	end
	return 0.3
end
