-- SafeCall(where, fn, ...): run fn under xpcall. An error is printed once per
-- place as "[Diag] error in <where>: <message + traceback>" (console.log with
-- -condebug) and nil is returned, so the caller falls back to the default
-- logic instead of losing the whole frame. The game's own error report for
-- bot scripts often shows only "error in error handling".
--
-- Its own module (required by every file that uses it): a global defined in
-- aba_global_overrides isn't there yet when the mode files load.

local seen = {}

-- A nil rune (no such spot, or a caller passed nothing) aborts the frame in
-- the engine: return the map centre and report where it came from. Set here
-- because this module loads with the mode files.
if GetRuneSpawnLocation and not SafeRuneSpawnLocationSet then
	SafeRuneSpawnLocationSet = true
	local original = GetRuneSpawnLocation
	local reported = 0
	GetRuneSpawnLocation = function(nRune)
		if type(nRune) ~= 'number' then
			if reported < 5 then
				reported = reported + 1
				print('[Diag] GetRuneSpawnLocation('..tostring(nRune)..') '..((debug and debug.traceback) and debug.traceback() or ''))
			end
			return Vector(0, 0, 0)
		end
		return original(nRune)
	end
end

local function Handler(err)
	local tb = (debug and debug.traceback) and debug.traceback(tostring(err), 2) or tostring(err)
	return tb
end

return function(where, fn, ...)
	local args, n = { ... }, select('#', ...)
	local res = { xpcall(function() return fn(unpack(args, 1, n)) end, Handler) }
	if not res[1] then
		if not seen[where] then
			seen[where] = true
			print('[Diag] error in '..where..': '..tostring(res[2]))
		end
		return nil
	end
	return unpack(res, 2, table.maxn(res))
end
