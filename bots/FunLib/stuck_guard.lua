-- Stuck guard: a bot that stays in a mode without moving or doing anything
-- (standing at a rune spot, a watcher, an outpost, a ward spot) gets that mode
-- switched off for a while, so it goes back to farming or its lane.
--
--   if StuckGuard.Blocked(bot, 'rune', BOT_MODE_RUNE) then return BOT_MODE_DESIRE_NONE end
--
-- "Doing something" = moving more than MOVE_RADIUS, attacking, channeling or
-- casting. Before the horn standing still is on purpose, so it's ignored.

local X = {}

-- Pacing back and forth inside this radius counts as stuck too.
local MOVE_RADIUS = 350
local STUCK_TIME = 7
local BAN_TIME = 40

local function Busy(bot)
	return bot:IsChanneling() or bot:IsUsingAbility() or bot:IsCastingAbility() or bot:GetAttackTarget() ~= nil
end

-- Returns true while the mode is banned for this bot.
function X.Blocked(bot, key, mode, banTime, waitOk)
	local t = DotaTime()
	bot._stuck = bot._stuck or {}
	local s = bot._stuck[key]
	if not s then s = { ban = -1 } bot._stuck[key] = s end
	if t < s.ban then return true end
	if t < 30 or bot:GetActiveMode() ~= mode or Busy(bot) or (waitOk and waitOk(t)) then
		s.loc, s.t = nil, nil
		return false
	end
	local loc = bot:GetLocation()
	if not s.loc or (s.loc - loc):Length2D() > MOVE_RADIUS then
		s.loc, s.t = loc, t
		return false
	end
	if t - s.t > STUCK_TIME then
		s.ban = t + (banTime or BAN_TIME)
		s.loc, s.t = nil, nil
		print('[Stuck] '..bot:GetUnitName()..' stood still in '..key..' mode, switching it off for '..(banTime or BAN_TIME)..' s')
		return true
	end
	return false
end

return X
