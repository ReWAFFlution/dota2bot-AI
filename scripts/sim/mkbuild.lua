-- luajit scripts/sim/mkbuild.lua bots : MK (pos 1) vs Medusa gets Diffusal, and a
-- damage item before an early BKB.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('mkbuild.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
local D = dofile(BOTS..'/FunLib/item_stats_data.lua')
function GetItemCost(n) local it = D.Items[n] return it and it.cost or 0 end
SIM_T = 8 * 60
local names = { [5] = 'npc_dota_hero_medusa', [6] = 'npc_dota_hero_lina' }
function GetTeamPlayers(t) return t == 2 and { 0 } or { 5, 6 } end
function GetSelectedHeroName(pid) return pid == 0 and 'npc_dota_hero_monkey_king' or names[pid] end
function GetHeroKills() return 0 end function GetHeroDeaths() return 0 end
function GetTeamMember() return nil end function GetUnitList() return {} end
function require(p) if p:find('aba_item') then error('x') end local ok, r = pcall(dofile, p..'.lua') return ok and r or nil end
local S = dofile(BOTS..'/FunLib/item_strategy.lua')
local mk = { inv = {} }
function mk:GetUnitName() return 'npc_dota_hero_monkey_king' end function mk:FindItemSlot(n) return self.inv[n] and 0 or -1 end
function mk:GetNetWorth() return 4000 end function mk:GetItemInSlot() return nil end function mk:HasModifier() return false end
function mk:GetPlayerID() return 0 end
local stack = { 'item_monkey_king_bar', 'item_skadi', 'item_echo_sabre', 'item_desolator', 'item_black_king_bar' }
for i = 1, 12 do SIM_T = SIM_T + 4 S.Think(mk, 1, stack) end
-- Diffusal bought; choosing the next item: a damage item before the BKB.
assert(table.remove(stack) == 'item_diffusal_blade', 'diffusal not first')
mk.inv.item_diffusal_blade = true
mk.GetItemInSlot = function(_, i) if i == 0 then return { GetName = function() return 'item_diffusal_blade' end } end end
S.ReviewNext(mk, 1, stack)
local order = {}
for i = #stack, 1, -1 do table.insert(order, (stack[i]:gsub('item_', ''))) end
print('next items: '..table.concat(order, ', '))
local function idx(n) for i = #stack, 1, -1 do if stack[i] == n then return #stack - i + 1 end end end
assert(idx('item_desolator') < idx('item_black_king_bar'))
print('mk build ok')
