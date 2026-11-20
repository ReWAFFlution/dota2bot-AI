-- luajit scripts/sim/ward.lua bots : a fresh observer of ours counts for the
-- sentry pairing (the name check never matched before), an old one doesn't.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('ward.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
local obs = { loc = Vector(100, 0), life = 300 }
function obs:GetUnitName() return 'npc_dota_observer_wards' end
function obs:GetRemainingLifespan() return self.life end
function GetUnitList() return { obs } end
function GetUnitToLocationDistance(u, l) return (u.loc - l):Length2D() end
local J = setmetatable({ IsValid = function(u) return u ~= nil end, Site = {} }, { __index = function() return function() end end })
function require(p) if p:find('jmz_func') then return J end return setmetatable({}, { __index = function() return function() end end }) end
local W = dofile(BOTS..'/FunLib/aba_ward_utility.lua')
assert(W.IsOtherWardClose(Vector(0, 0), 'npc_dota_observer_wards', 400, true, true), 'fresh observer pairs')
obs.life = 60 assert(not W.IsOtherWardClose(Vector(0, 0), 'npc_dota_observer_wards', 400, true, true), 'old observer')
assert(W.IsOtherWardClose(Vector(0, 0), 'npc_dota_observer_wards', 400, true, false), 'any observer')
print('ward ok')
