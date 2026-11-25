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
local function d(hp, mp, bottle, dist) return M.PowerRuneDesire(sf, 0, RUNE_STATUS_AVAILABLE, RUNE_WATER, dist or 1500, hp, mp, bottle) end
-- With the wave still there it's only worth it when needed (or right here).
local full = d(1, 1, true) charges = 0 local empty = d(1, 1, true) local nob = d(1, 1, false) local low = d(0.4, 0.3, false)
local far = d(0.4, 0.3, false, 3000) local here = d(1, 1, false, 600)
print('full bottle', full, 'empty bottle', empty, 'no bottle full HP', nob, 'low HP', low, 'low HP far', far, 'right here', here)
assert(full == nil and nob == nil and empty > 0 and low > 0 and far == nil and here > 0)
print('water ok')
-- Out of mana, the rune out of sight 20 s after the 4:00 spawn: still worth a
-- look (Arc Warden at 0 mana never went for one, 9105652499).
SIM_T = 4 * 60 + 20
local dry = M.PowerRuneDesire(sf, 0, RUNE_STATUS_UNKNOWN, RUNE_WATER, 1800, 0.8, 0.05, false)
local fullMana = M.PowerRuneDesire(sf, 0, RUNE_STATUS_UNKNOWN, RUNE_WATER, 1800, 0.9, 0.9, false)
print('unseen, 20 s in: no mana', dry, 'full mana', fullMana)
assert(dry and dry > 0 and fullMana == nil)
print('dry mid ok')
