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
-- 20 min, Desolator next, Skadi (much dearer) planned after: no swap.
SIM_T = 20 * 60
local st2 = { 'item_monkey_king_bar', 'item_skadi', 'item_desolator' }
mk.GetItemInSlot = function() return nil end
S.ReviewNext(mk, 1, st2)
print('20 min next item: '..st2[#st2])
assert(st2[#st2] == 'item_desolator', 'jumped to a much dearer item')
-- Juggernaut (pos 1) at 16:00 against a Wraith King seen with Radiance:
-- MKB gets planned (true strike against the blind).
SIM_T = 16 * 60
names = { [5] = 'npc_dota_hero_skeleton_king', [6] = 'npc_dota_hero_lina' }
GetSelectedHeroName = function(pid) return pid == 0 and 'npc_dota_hero_juggernaut' or names[pid] end
local wk = { }
function wk:IsNull() return false end function wk:IsAlive() return true end function wk:IsIllusion() return false end
function wk:GetUnitName() return 'npc_dota_hero_skeleton_king' end function wk:FindItemSlot(n) return n == 'item_radiance' and 0 or -1 end
GetUnitList = function() return { wk } end
local S2 = dofile(BOTS..'/FunLib/item_strategy.lua')
local jug = { inv = {} }
function jug:GetUnitName() return 'npc_dota_hero_juggernaut' end function jug:FindItemSlot(n) return self.inv[n] and 0 or -1 end
function jug:GetNetWorth() return 9000 end function jug:GetItemInSlot() return nil end function jug:HasModifier() return false end
function jug:GetPlayerID() return 0 end
local st3 = { 'item_butterfly', 'item_abyssal_blade', 'item_skadi' }
for i = 1, 12 do SIM_T = SIM_T + 4 S2.Think(jug, 1, st3) end
local has = false for _, it in ipairs(st3) do if it == 'item_monkey_king_bar' or it == 'item_bloodthorn' then has = true end end
print('Juggernaut vs Radiance WK: '..table.concat(st3, ', '))
assert(has, 'no true strike vs Radiance')
-- Bristleback (pos 3) at 15:00 with no big item vs gankers and disablers:
-- BKB comes after his usual Vanguard and Blade Mail, not first.
SIM_T = 15 * 60
names = { [5] = 'npc_dota_hero_lion', [6] = 'npc_dota_hero_nyx_assassin', [7] = 'npc_dota_hero_rubick', [8] = 'npc_dota_hero_viper', [9] = 'npc_dota_hero_skeleton_king' }
GetTeamPlayers = function(t) return t == 2 and { 0 } or { 5, 6, 7, 8, 9 } end
GetSelectedHeroName = function(pid) return pid == 0 and 'npc_dota_hero_bristleback' or names[pid] end
GetUnitList = function() return {} end
local S3 = dofile(BOTS..'/FunLib/item_strategy.lua')
local bb = {}
function bb:GetUnitName() return 'npc_dota_hero_bristleback' end function bb:FindItemSlot() return -1 end
function bb:GetNetWorth() return 4000 end function bb:GetItemInSlot() return nil end function bb:HasModifier() return false end
function bb:GetPlayerID() return 0 end
local st4 = { 'item_consecrated_wraps', 'item_lotus_orb', 'item_sange', 'item_blade_mail', 'item_vanguard' }
for i = 1, 12 do SIM_T = SIM_T + 4 S3.Think(bb, 3, st4) end
local function at(st, n) for i = #st, 1, -1 do if st[i] == n then return #st - i + 1 end end return 99 end
print(string.format('BB: vanguard %d, blade mail %d, BKB %d (1 = next)', at(st4, 'item_vanguard'), at(st4, 'item_blade_mail'), at(st4, 'item_black_king_bar')))
assert(at(st4, 'item_black_king_bar') > at(st4, 'item_vanguard') and at(st4, 'item_black_king_bar') > at(st4, 'item_blade_mail'))
print('mk build ok')
