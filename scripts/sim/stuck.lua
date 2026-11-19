-- luajit scripts/sim/stuck.lua bots : the stuck guard never blocks a mode before
-- the horn (DotaTime() < 0) and does block a bot standing still in it.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('stuck.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end
BOT_MODE_RUNE = 5
local bot = { loc = Vector(0, 0) }
function bot:GetLocation() return self.loc end function bot:GetUnitName() return 'cm' end
function bot:GetActiveMode() return BOT_MODE_RUNE end function bot:IsChanneling() return false end
function bot:IsUsingAbility() return false end function bot:IsCastingAbility() return false end function bot:GetAttackTarget() return nil end
local G = dofile(BOTS..'/FunLib/stuck_guard.lua')
SIM_T = -80
assert(G.Blocked(bot, 'rune', BOT_MODE_RUNE) == false, 'blocked before the horn')
print('before the horn: not blocked')
SIM_T = 100
local blocked = false
for i = 1, 20 do SIM_T = SIM_T + 0.5 if G.Blocked(bot, 'rune', BOT_MODE_RUNE) then blocked = true break end end
assert(blocked, 'standing still never blocked')
print('standing still at 1:40: blocked after '..(SIM_T - 100)..' s')
print('stuck ok')
