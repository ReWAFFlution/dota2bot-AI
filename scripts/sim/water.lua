-- luajit scripts/sim/water.lua bots : the mid goes for the water rune with or
-- without a Bottle, sooner when it needs it.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('water.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
SIM_T = 2 * 60 + 5
RUNE_STATUS_AVAILABLE, RUNE_STATUS_UNKNOWN, RUNE_WATER = 1, 0, 7
BOT_MODE_DESIRE_HIGH, BOT_MODE_DESIRE_VERYHIGH, BOT_MODE_DESIRE_NONE = 0.75, 0.9, 0
local charges = 3
local sf = { loc = Vector(0, 0) }
function sf:GetUnitName() return 'nevermore' end function sf:GetLocation() return self.loc end
function sf:GetNearbyLaneCreeps() return { {} } end -- the wave is still there
function sf:FindItemSlot(n) return n == 'item_bottle' and 0 or -1 end
function sf:GetItemInSlot() return { GetCurrentCharges = function() return charges end } end
local J = { GetPosition = function() return 2 end }
function require(p) if p:find('jmz_func') then return J end end
local M = dofile(BOTS..'/FunLib/mid_play.lua')
local function d(hp, mp, bottle) return M.PowerRuneDesire(sf, 0, RUNE_STATUS_AVAILABLE, RUNE_WATER, 2000, hp, mp, bottle) end
local full = d(1, 1, true) charges = 0 local empty = d(1, 1, true) local nob = d(1, 1, false) local low = d(0.4, 0.3, false)
print(string.format('full bottle %.2f, empty bottle %.2f, no bottle full HP %.2f, no bottle low HP %.2f', full, empty, nob, low))
assert(full > 0 and nob > 0 and empty > full and low > nob)
print('water ok')
