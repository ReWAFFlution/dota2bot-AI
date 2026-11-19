-- luajit scripts/sim/captain.lua bots : Captain Mode bans/picks go through the
-- draft hooks; a hook that fails falls back to the random role-fitting hero.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('captain.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
local picked, banned, state, captain = { [2] = {}, [3] = {} }, {}, 0, 0
function IsPlayerBot() return true end function IsPlayerInHeroSelectionControl() return true end
function GetCMCaptain() return captain end function SetCMCaptain(c) captain = c end
function IsCMPickedHero(team, h) return picked[team][h] == true end function IsCMBannedHero(h) return banned[h] == true end
function CMBanHero(h) banned[h] = true end function CMPickHero(h) picked[2][h] = true end
function GetGameState() return 2 end function GetCMPhaseTimeRemaining() return 0 end
function GetHeroPickState() return state end function GetTeamPlayers() return { 0, 1, 2, 3, 4 } end
math.randomseed(1) function RandomInt(a, b) return math.random(a, b) end
local roles = { CanBeOfflaner = function() return true end, CanBeMidlaner = function() return true end,
	CanBeSupport = function() return true end, CanBeSafeLaneCarry = function() return true end }
function require(p)
	if p:find('aba_role') then return roles end
	if p:find('ts_libs/dota/index') then return { GameState = { HeroSelection = 2 }, HeroPickState = { CmCaptainPick = 1, CmBan1 = 2, CmSelect1 = 30, CmSelect10 = 39, CmPick = 40 }, Lane = { Top = 1, Mid = 2, Bot = 3 }, Team = { Radiant = 2 } } end
end
local CM = dofile(BOTS..'/FunLib/captain_mode.lua')
local all = { 'npc_dota_hero_axe', 'npc_dota_hero_lion', 'npc_dota_hero_lina', 'npc_dota_hero_cm', 'npc_dota_hero_sven', 'npc_dota_hero_pudge' }
local asked = {}
CM.SetDraftHooks({
	ban = function() return 'npc_dota_hero_pudge' end,
	pick = function(pos) table.insert(asked, pos) if pos == 2 then error('no mid in data') end
		return ({ [3] = 'npc_dota_hero_axe', [5] = 'npc_dota_hero_lion', [4] = 'npc_dota_hero_cm', [1] = 'npc_dota_hero_sven' })[pos] end,
})
state = 2 CM.CaptainModeLogic(all)
assert(banned['npc_dota_hero_pudge'], 'ban hook not used')
for i = 1, 5 do state = 30 + i - 1 CM.CaptainModeLogic(all) end
local got = {}
for h in pairs(picked[2]) do table.insert(got, h) end
table.sort(got)
print('asked positions: '..table.concat(asked, ','))
print('picked: '..table.concat(got, ' '))
assert(#got == 5 and picked[2]['npc_dota_hero_sven'] and picked[2]['npc_dota_hero_axe'], 'draft picks missing')
print('captain ok')
