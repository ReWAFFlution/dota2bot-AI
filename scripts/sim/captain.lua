-- luajit scripts/sim/captain.lua bots : Captain Mode bans/picks go through the
-- draft hooks; a hook that fails falls back to the random role-fitting hero.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('captain.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
local picked, banned, state, captain = { [2] = {}, [3] = {} }, {}, 0, 0
local ourTurn = true
function IsPlayerBot() return true end function IsPlayerInHeroSelectionControl() return ourTurn end
function GetCMCaptain() return captain end function SetCMCaptain(c) captain = c end
function IsCMPickedHero(team, h) return picked[team][h] == true end function IsCMBannedHero(h) return banned[h] == true end
function CMBanHero(h) if not pool or pool[h] then banned[h] = true end end function CMPickHero(h) if not pool or pool[h] then picked[2][h] = true end end
local gt = 0 function GameTime() return gt end
pool = nil -- Captains Draft: only these can be taken (global: used by the stubs above)
function GetGameState() return 2 end function GetCMPhaseTimeRemaining() return 0 end
function GetHeroPickState() return state end function GetTeamPlayers() return { 0, 1, 2, 3, 4 } end
math.randomseed(1) function RandomInt(a, b) return math.random(a, b) end
local roles = { CanBeOfflaner = function() return true end, CanBeMidlaner = function() return true end,
	CanBeSupport = function() return true end, CanBeSafeLaneCarry = function() return true end }
function require(p)
	if p:find('aba_role') then return roles end
	if p:find('ts_libs/dota/index') then return { GameState = { HeroSelection = 2 }, HeroPickState = { CmCaptainPick = 1, CmBan1 = 2, CmSelect1 = 21, CmSelect10 = 30, CmPick = 31, CdCaptainPick = 34, CdBan1 = 35, CdBan6 = 40, CdSelect1 = 41, CdSelect10 = 50, CdPick = 51 }, Lane = { Top = 1, Mid = 2, Bot = 3 }, Team = { Radiant = 2 } } end
end
local CM = dofile(BOTS..'/FunLib/captain_mode.lua')
local all = { 'npc_dota_hero_axe', 'npc_dota_hero_lion', 'npc_dota_hero_lina', 'npc_dota_hero_cm', 'npc_dota_hero_sven', 'npc_dota_hero_pudge', 'npc_dota_hero_tiny', 'npc_dota_hero_zuus' }
local asked = {}
CM.SetDraftHooks({
	ban = function() return 'npc_dota_hero_pudge' end,
	pick = function(pos) table.insert(asked, pos) if pos == 2 then error('no mid in data') end
		return ({ [3] = 'npc_dota_hero_axe', [5] = 'npc_dota_hero_lion', [4] = 'npc_dota_hero_cm', [1] = 'npc_dota_hero_sven' })[pos] end,
})
state = 2 CM.CaptainModeLogic(all) gt = gt + 1 ourTurn = false CM.CaptainModeLogic(all)
assert(banned['npc_dota_hero_pudge'], 'ban hook not used')
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
-- Like the game: the selection state moves on once a pick is registered.
local function runPicks(M, first)
	for i = 1, 5 do
		state = first + i - 1
		ourTurn = true
		local before = count(picked[2])
		for k = 1, 10 do
			M.CaptainModeLogic(all) gt = gt + 1
			-- Picked: the turn passes to the other captain.
			if count(picked[2]) > before then ourTurn = false M.CaptainModeLogic(all) gt = gt + 1 break end
		end
	end
end
runPicks(CM, 21)
local got = {}
for h in pairs(picked[2]) do table.insert(got, h) end
table.sort(got)
print('asked positions: '..table.concat(asked, ','))
print('picked: '..table.concat(got, ' '))
assert(#got == 5 and picked[2]['npc_dota_hero_sven'] and picked[2]['npc_dota_hero_axe'], 'draft picks missing')
print('captain ok')

-- Captains Draft: Axe isn't in the pool; the pick moves on to another hero.
package.loaded = package.loaded
picked, banned, asked = { [2] = {}, [3] = {} }, {}, {}
pool = { npc_dota_hero_lion = true, npc_dota_hero_sven = true, npc_dota_hero_lina = true, npc_dota_hero_cm = true, npc_dota_hero_pudge = true, npc_dota_hero_tiny = true }
local CD = dofile(BOTS..'/FunLib/captain_mode.lua')
local cand = { [3] = { 'npc_dota_hero_axe', 'npc_dota_hero_tiny' }, [5] = { 'npc_dota_hero_lion' }, [2] = { 'npc_dota_hero_lina' }, [4] = { 'npc_dota_hero_cm' }, [1] = { 'npc_dota_hero_sven' } }
CD.SetDraftHooks({ ban = function() return 'npc_dota_hero_pudge' end,
	pick = function(pos) for _, h in ipairs(cand[pos]) do if not CD.IsTried(h) then return h end end end })
ourTurn = true state = 35 CD.CaptainModeLogic(all) gt = gt + 1 ourTurn = false CD.CaptainModeLogic(all)
runPicks(CD, 41)
got = {}
for h in pairs(picked[2]) do table.insert(got, h) end
table.sort(got)
print('CD picked: '..table.concat(got, ' '))
assert(picked[2]['npc_dota_hero_tiny'] and not picked[2]['npc_dota_hero_axe'] and #got == 5, 'CD retry failed')
print('captains draft ok')
