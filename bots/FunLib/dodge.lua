-- Dodging enemy skillshots and delayed area spells.
--
-- Bots stood in a Light Strike Array, walked into hooks and arrows: nothing
-- looked at what was flying at them. Two threats, from the game's own lists:
--   * linear projectiles (GetLinearProjectiles: hooks, arrows, waves): one
--     that passes within its radius + our hull in the next 1.5 s -> step
--     sideways out of its line (the side we're already on);
--   * avoidance zones (GetAvoidanceZones: Light Strike Array, Torrent,
--     Split Earth, Sun Strike...): standing in one -> out past its edge.
-- Enemy ones only. The step must be passable; a dodge we can't make in time
-- is still tried (half the hits land late anyway).
-- Used by mode_evasive_maneuvers_generic (desire 0.99 while a dodge is on).

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')

local X = {}

local HORIZON = 1.5
local HULL = 32

local function Dist(a, b) return (a - b):Length2D() end

local function Enemy(caster, pid)
	if caster and not caster:IsNull() then
		local ok, team = pcall(function() return caster:GetTeam() end)
		if ok and team then return team ~= GetTeam() end
	end
	if pid and pid >= 0 and GetTeamForPlayer then
		local ok, team = pcall(GetTeamForPlayer, pid)
		if ok and team then return team ~= GetTeam() end
	end
	return false
end

local function Passable(loc)
	if not IsLocationPassable then return true end
	local ok, r = pcall(IsLocationPassable, loc)
	return not ok or r
end

local function AbilityName(a)
	if not a then return '?' end
	local ok, n = pcall(function() return a:GetName() end)
	return ok and n or '?'
end

-- The dodge for this frame (cached): { loc, why, t } or nil.
function X.Threat(bot)
	local now = DotaTime()
	local c = bot._dodgeCache
	if c and c.at == now then return c.res end
	local res = nil
	-- Not while it can't move (stunned, rooted, hexed): Dragon Knight stood
	-- 5 s in the dodge mode at 0.99 (9105740279).
	local stuck = false
	pcall(function() stuck = bot:IsStunned() or bot:IsRooted() or bot:IsHexed() or bot:IsNightmared() end)
	if bot:IsAlive() and not bot:IsChanneling() and not stuck then
		local myLoc = bot:GetLocation()
		local best
		-- Linear projectiles.
		local okL, list = pcall(GetLinearProjectiles)
		for _, p in pairs(okL and list or {}) do
			if p and p.location and p.velocity and Enemy(p.caster, p.playerid) then
				local v = p.velocity
				local speed = v:Length2D()
				if speed > 1 then
					local dir = v / speed
					local rel = myLoc - p.location
					local along = rel.x * dir.x + rel.y * dir.y
					if along > -(p.radius or 100) then
						local tHit = math.max(0, along) / speed
						if tHit < HORIZON then
							local perp = rel - dir * along
							local lat = perp:Length2D()
							local need = (p.radius or 100) + HULL + 60
							if lat < need then
								local side = lat > 5 and perp / lat or Vector(-dir.y, dir.x, 0)
								local loc = myLoc + side * (need - lat + 60)
								if not Passable(loc) then loc = myLoc - side * (need + lat + 60) end
								if Passable(loc) and (not best or tHit < best.t) then
									best = { loc = loc, t = tHit, why = AbilityName(p.ability)..string.format(' (%.1f s, %d off its line)', tHit, lat) }
								end
							end
						end
					end
				end
			end
		end
		-- Avoidance zones: new ones only (a delayed hit is about to land). A
		-- lasting one (Shrapnel, Static Storm...) had the bot step out, the
		-- other modes step back in, and Dragon Knight stood 20 s in the dodge
		-- mode in the first 10 minutes (9105761054).
		X._zoneSeen = X._zoneSeen or {}
		if now - (X._zonePurgeT or -math.huge) > 30 then
			X._zonePurgeT = now
			for k, t0 in pairs(X._zoneSeen) do if now - t0 > 60 then X._zoneSeen[k] = nil end end
		end
		local okZ, zones = pcall(GetAvoidanceZones)
		for _, z in pairs(okZ and zones or {}) do
			local zkey = z and z.location and (math.floor(z.location.x / 50)..':'..math.floor(z.location.y / 50)..':'..AbilityName(z.ability)) or nil
			if zkey then
				X._zoneSeen[zkey] = X._zoneSeen[zkey] or now
			end
			local fresh = zkey and now - X._zoneSeen[zkey] < 2.5
			if z and z.location and z.radius and fresh and Enemy(z.caster) then
				local d = Dist(myLoc, z.location)
				local edge = z.radius + HULL + 40
				if d < edge then
					local away = myLoc - z.location
					if away:Length2D() < 10 then away = J.GetTeamFountain() - z.location end
					away = away / math.max(1, away:Length2D())
					local loc = z.location + away * (edge + 60)
					if not Passable(loc) then loc = z.location - away * (edge + 60) end
					if Passable(loc) and not best then
						best = { loc = loc, t = 0.5, why = AbilityName(z.ability)..string.format(' (zone %d, %d from its center)', z.radius, d) }
					end
				end
			end
		end
		res = best
	end
	bot._dodgeCache = { at = now, res = res }
	return res
end

function X.Desire(bot)
	local th = X.Threat(bot)
	if not th then return 0 end
	return 0.99
end

function X.Think(bot)
	local th = X.Threat(bot)
	if not th then return false end
	if DotaTime() - (bot._dodgeLogT or -math.huge) > 5 then
		bot._dodgeLogT = DotaTime()
		print('[Dodge] '..bot:GetUnitName()..' dodges '..th.why)
	end
	bot:Action_MoveToLocation(th.loc)
	return true
end

return X
