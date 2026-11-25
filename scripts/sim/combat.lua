-- luajit scripts/sim/combat.lua bots : time to kill both ways decides go/retreat.
local BOTS = arg[1]
dofile(debug.getinfo(1).source:sub(2):gsub('combat.lua$', 'stub.lua'))
function GetScriptDirectory() return BOTS end

local ancientLoc = Vector(-7000, -6500)
function GetAncient() return { GetLocation = function() return ancientLoc end, IsAlive = function() return true end, GetHealth = function() return 4000 end } end
SIM_T = 900
DAMAGE_TYPE_MAGICAL = 2
local function hero(name, team, loc, hp, dps)
	local u = { name = name, team = team, loc = loc, hp = hp, dps = dps, items = {} }
	function u:GetUnitName() return 'npc_dota_hero_'..name end function u:GetLocation() return self.loc end
	u.pid = (team == 3) and 5 or 0
	function u:IsAlive() return true end function u:IsIllusion() return false end function u:GetPlayerID() return self.pid end
	function u:GetHealth() return self.hp end function u:GetMaxHealth() return 2000 end function u:GetHealthRegen() return 5 end
	function u:GetEstimatedDamageToTarget(_, _, secs, dtype) return dtype == DAMAGE_TYPE_MAGICAL and self.dps * 0.3 * secs or self.dps * secs end
	function u:FindItemSlot(n) return self.items[n] and 0 or -1 end
	function u:GetItemInSlot() return { IsFullyCastable = function() return true end } end
	function u:CanBeSeen() return true end function u:HasModifier() return false end function u:IsHero() return true end
	function u:GetNetWorth() return 5000 end function u:GetLevel() return 12 end function u:IsBot() return true end
	function u:GetAttackRange() return 550 end function u:GetAttackDamage() return 60 end
	function u:GetAbilityByName(n) return self.abilities and self.abilities[n] end
	function u:GetMana() return self.mana or 0 end
	function u:GetTeam() return self.team end
	return u
end
local me = hero('sven', 2, Vector(0, 0), 1800, 250)
local allies, enemies = { me }, {}
function GetUnitList(t) if t == UNIT_LIST_ENEMY_HEROES then return enemies end if t == UNIT_LIST_ALLIED_HEROES then return allies end return {} end
function GetTower() return nil end function GetTeamMember(i) return allies[i] end
local seenNear = {}
function GetTeamPlayers(t) return t == 3 and { 5, 6, 7, 8 } or { 0 } end function IsHeroAlive() return true end
function GetHeroLastSeenInfo(pid) if seenNear[pid] then return { { time_since_seen = 2, location = Vector(800, 0) } } end return { { time_since_seen = 1, location = Vector(9000, 9000) } } end
local J = { IsInLaningPhase = function() return false end, IsValidHero = function(h) return h ~= nil end, CanBeAttacked = function() return true end, GetHP = function(u) return u.hp / 2000 end,
	GetMP = function() return 0.8 end, IsSuspiciousIllusion = function() return false end, GetPosition = function() return 1 end,
	GetEnemyFountain = function() return Vector(7000, 7000) end, GetTeamFountain = function() return Vector(-7000, -7000) end }
function require(p) if p:find('jmz_func') then return J end if p:find('roles_map') then return { IsDisabler = function(n) return DISABLERS and DISABLERS[n] == true end, HasEscape = function() return false end } end end
local O = dofile(BOTS..'/FunLib/objectives.lua')
local function show(label) local c = O.Combat(me) print(string.format('%-28s us %4.0f s  them %4.0f s  go=%s retreat=%s', label, c.ttkUs, c.ttkThem, tostring(c.go), tostring(c.retreat))) return c end
enemies = { hero('lina', 3, Vector(400, 0), 600, 150) }
local c = show('1v1 vs hurt Lina') assert(c.go and not c.retreat)
enemies = { hero('lina', 3, Vector(400, 0), 1400, 300), hero('lion', 3, Vector(300, 200), 1300, 300), hero('pudge', 3, Vector(200, -200), 2500, 250) }
c = show('1v3 full HP') assert(c.retreat and not c.go)
me.items.item_blink = true me.hp = 1800
c = show('1v3 with Blink ready') print('(escape adds 40% HP to survive the burst)')
-- Medusa: her mana is HP. Full mana she outlasts us; drained she's a kill.
me.items = {} me.hp = 1800
local medusa = hero('medusa', 3, Vector(400, 0), 600, 150) medusa.mana = 1000
enemies = { medusa }
c = show('1v1 hurt Medusa, full mana') assert(not c.go)
medusa.mana = 50
c = show('1v1 hurt Medusa, drained') assert(c.go)
-- 4v4 with a clear edge: their combos together would kill one bot in a
-- second, but they don't all hit the same hero; our group burns theirs faster.
me.hp = 1500
allies = { me, hero('mk', 2, Vector(100, 100), 1800, 420), hero('sf', 2, Vector(-100, 50), 1500, 450), hero('nyx', 2, Vector(50, -120), 1300, 300) }
enemies = { hero('medusa', 3, Vector(600, 0), 1500, 260), hero('pango', 3, Vector(650, 150), 1200, 260),
	hero('ven', 3, Vector(550, -150), 900, 220), hero('wk', 3, Vector(700, 50), 1700, 260) }
for _, e in ipairs(enemies) do e.mana = 0 end
c = show('4v4, our group stronger') print(string.format('team ratio x%.2f', c.teamRatio))
assert(c.teamRatio > 1.2 and not c.retreat and c.go)
-- The same won fight right at their fountain: no chase, step back.
local ef = Vector(7000, 7000)
for _, e in ipairs(enemies) do e.loc = ef + (e.loc - Vector(600, 0)) end
me.loc = ef + Vector(-900, -900) for i = 2, #allies do allies[i].loc = me.loc end
c = show('same fight at their fountain') assert(c.retreat and not c.go)
-- An enemy next to us on their half, even odds: decide, don't idle.
me.loc, me.hp = Vector(2000, 2000), 1500
allies = { me } enemies = { hero('wk', 3, Vector(2500, 2000), 1800, 250) }
c = show('1v1 even, enemy close') assert(c.go or c.retreat)
-- On our half, low, an enemy close that can't kill us soon (99 s): no
-- stepping back from the creeps (DK kept doing it next to Furion).
me.loc, me.hp = Vector(-3000, -3000), 600
enemies = { hero('furion', 3, Vector(-2600, -3000), 1800, 20) }
c = show('own half, enemy harmless') assert(not c.retreat)
-- 3 of ours vs 2 visible, 2 more seen right here 2 s ago: not a free fight.
me.loc, me.hp = Vector(0, 0), 1500
allies = { me, hero('mk', 2, Vector(100, 100), 1800, 300), hero('nyx', 2, Vector(50, -120), 1300, 250) }
local e1, e2 = hero('pango', 3, Vector(500, 0), 1200, 300), hero('ven', 3, Vector(550, -100), 900, 250)
e1.pid, e2.pid = 5, 6
enemies = { e1, e2 }
local cVisible = O.Combat(me)
seenNear[7], seenNear[8] = true, true
me._x = nil
local cGhosts = O.Combat(me)
print(string.format('3v2 visible: team x%.2f go=%s | +2 seen nearby: team x%.2f go=%s', cVisible.teamRatio, tostring(cVisible.go), cGhosts.teamRatio, tostring(cGhosts.go)))
assert(cGhosts.teamRatio < cVisible.teamRatio * 0.6)
-- Wraith King: with Reincarnation ready he has a second life; once used the
-- same fight is better for us, not worse.
seenNear = {}
allies = { me, hero('mk', 2, Vector(100, 100), 1800, 400), hero('sf', 2, Vector(-100, 50), 1500, 400) }
local wk = hero('skeleton_king', 3, Vector(500, 0), 2000, 300) wk.pid = 5
local ultReady = true
function wk:GetLevel() return 15 end
function wk:GetAbilityByName() return { GetLevel = function() return 1 end, GetCooldownTimeRemaining = function() return ultReady and 0 or 80 end } end
enemies = { wk }
local cBefore = O.Combat(me)
ultReady = false
local cAfter = O.Combat(me)
print(string.format('vs WK: team x%.2f with Reincarnation ready, x%.2f after it', cBefore.teamRatio, cAfter.teamRatio))
assert(cAfter.teamRatio > cBefore.teamRatio * 1.5)
-- Last stand: enemies at our ancient; 1v2 we'd normally leave, here we hold.
me.loc, me.hp = Vector(-6600, -6100), 1500
allies = { me }
local a1, a2 = hero('mk', 3, Vector(-6700, -6300), 1800, 300), hero('sf', 3, Vector(-6500, -6400), 1500, 300)
a1.pid, a2.pid = 5, 6
enemies = { a1, a2 }
c = show('1v2 at our ancient') assert(not c.retreat and c.lastStand)
-- Wobbling numbers: once it decides to leave it keeps leaving for 3 s.
J.IsInLaningPhase = function() return false end
J.GetProperTarget = function() return nil end
me.WasRecentlyDamagedByAnyHero = function() return true end
me.SetTarget = function() end
me.DistanceFromFountain = function() return 5000 end me.GetLevel = function() return 12 end
function GetLaneFrontLocation() return Vector(0, 0) end me.GetAssignedLane = function() return 2 end
wd_stub_done = true
me.loc, me.hp = Vector(0, 0), 900
allies = { me }
local wd = hero('witch_doctor', 3, Vector(500, 0), 1500, 260) wd.pid = 5
enemies = { wd }
local flips, last = 0, nil
for i = 1, 12 do
	SIM_T = SIM_T + 0.5
	wd.dps = (i % 2 == 0) and 260 or 120 -- the estimate wobbles
	local h = O.FightHint(me)
	local now = h >= 0.9 and 'retreat' or 'other'
	if last and now ~= last then flips = flips + 1 end
	last = now
end
print('decision changes over 6 s of wobbling numbers:', flips)
assert(flips <= 2)
-- WD vs an almost dead Terrorblade in Metamorphosis: the engine estimate
-- misses Death Ward; WD still has the kill.
allies = { me } me.loc, me.hp = Vector(0, 0), 900
me.dps = 30 me.mana = 400
me.abilities = { witch_doctor_death_ward = { GetLevel = function() return 1 end, GetCooldownTimeRemaining = function() return 0 end, GetManaCost = function() return 200 end } }
local tb = hero('terrorblade', 3, Vector(500, 0), 600, 500) tb.pid = 5
enemies = { tb }
local cw = O.Combat(me)
print(string.format('WD vs TB at 600 HP with Death Ward ready: we kill in %d s, go=%s', cw.ttkUs, tostring(cw.go)))
assert(cw.ttkUs <= 3)
tb.hp = 150 me.abilities = {}
local cf = O.Combat(me)
print(string.format('WD vs TB at 150 HP, no ult: we kill in %d s, they kill us in %d s, go=%s', cf.ttkUs, cf.ttkThem, tostring(cf.go)))
assert(cf.ttkUs <= 2 and cf.go)
-- WD with Cask ready vs Terrorblade at 450 HP hitting for 500/s: while TB is
-- stunned he doesn't hit, so WD wins the exchange.
DISABLERS = { npc_dota_hero_sven = true } -- 'me' plays the WD here
me.abilities = {} me.dps = 160 me.hp = 900
local tb2 = hero('terrorblade', 3, Vector(450, 0), 450, 500) tb2.pid = 5
enemies = { tb2 }
local cs = O.Combat(me)
print(string.format('WD (Cask ready) vs TB 450 HP: we kill in %d s, they kill us in %d s, go=%s', cs.ttkUs, cs.ttkThem, tostring(cs.go)))
assert(cs.go)
DISABLERS = nil
-- Clockwerk vs a Terrorblade twice as strong at a tower: not worth joining.
local clock = hero('rattletrap', 2, Vector(-3000, 0), 1300, 150)
local tb3 = hero('terrorblade', 3, Vector(-2700, 0), 2600, 450) tb3.pid = 5
allies, enemies = {}, { tb3 }
local f = O.FightAt(Vector(-2800, 0), clock)
print(string.format('Clockwerk joining vs a twice-stronger Terrorblade: fight x%.2f', f))
assert(f < 0.8)
-- The same Terrorblade against a group of three that comes together.
local g1 = hero('rattletrap', 2, Vector(-5000, 0), 1300, 150)
local g2 = hero('witch_doctor', 2, Vector(-5000, 300), 1100, 220)
local g3 = hero('dragon_knight', 2, Vector(-5000, -300), 1900, 200)
local fGroup = O.FightAt(Vector(-2800, 0), { g1, g2, g3 })
print(string.format('vs the same Terrorblade: Clockwerk alone x%.2f, with WD and DK x%.2f', O.FightAt(Vector(-2800, 0), g1), fGroup))
assert(fGroup >= 1.0)
-- Clockwerk and DK on a Terrorblade with 3 illusions, Metamorphosis and
-- Sunder ready: the illusions and the ult count, so they don't go in.
SIM_T = SIM_T + 10
clock.hp = 1900 clock.loc = Vector(0, 0)
local dk = hero('dragon_knight', 2, Vector(100, 0), 2000, 180)
allies = { clock, dk }
local tb2 = hero('terrorblade', 3, Vector(500, 0), 1500, 200)
local ready = function(lvl) return { GetLevel = function() return lvl end, GetCooldownTimeRemaining = function() return 0 end } end
tb2.abilities = { terrorblade_metamorphosis = ready(2), terrorblade_sunder = ready(1) }
local function illusion(i)
	local u = hero('terrorblade', 3, Vector(500 + i * 50, 100), 1500, 200)
	function u:IsIllusion() return true end
	return u
end
enemies = { tb2 }
local cNo = O.Combat(clock)
enemies = { tb2, illusion(1), illusion(2), illusion(3) }
local cYes = O.Combat(clock)
print(string.format('Clock+DK vs Terrorblade: without illusions/ult counted %s s to die, with them %s s; go=%s retreat=%s',
	tostring(cNo and cNo.ttkThem), tostring(cYes.ttkThem), tostring(cYes.go), tostring(cYes.retreat)))
assert(cYes.ttkThem < cNo.ttkThem and not cYes.go)
-- Illusion damage by hero: TB (Conjure Image 4 + Dark Unity) 64%, PL 17%,
-- TB with Conjure Image 1 40%, a melee hero with Manta 33%.
local pl = hero('phantom_lancer', 3, Vector(0, 0), 1500, 200)
local sven = hero('sven', 3, Vector(0, 0), 1500, 200) function sven:GetAttackRange() return 150 end
local tbLow = hero('terrorblade', 3, Vector(0, 0), 1500, 200) tbLow.abilities = { terrorblade_conjure_image = ready(1) }
print(string.format('illusion damage: TB %.2f, TB (Conjure Image 1) %.2f, PL %.2f, Sven with Manta %.2f',
	O._IllusionShare(tb2), O._IllusionShare(tbLow), O._IllusionShare(pl), O._IllusionShare(sven)))
assert(O._IllusionShare(tb2) == 0.64 and O._IllusionShare(tbLow) == 0.40 and O._IllusionShare(pl) == 0.17 and O._IllusionShare(sven) == 0.33)
-- One decision for the group: Underlord, Grimstroke and DK next to a
-- Terrorblade, Disruptor 1200 away from him (1600+ from the others). Alone
-- Disruptor would stay out; with the group's fight he goes in too.
SIM_T = SIM_T + 10
local tbG = hero('terrorblade', 3, Vector(0, 0), 1500, 300)
local ul = hero('abyssal_underlord', 2, Vector(-600, 0), 1500, 150)
local gr = hero('grimstroke', 2, Vector(-500, 300), 1300, 150)
local dkG = hero('dragon_knight', 2, Vector(-400, -300), 1700, 150)
local dis = hero('disruptor', 2, Vector(1200, 0), 900, 100)
allies, enemies = { ul, gr, dkG, dis }, { tbG }
local cd = O.Combat(dis)
print(string.format('Disruptor 1200 from TB (1600+ from the rest): own team x%.2f, group x%.2f, go=%s', cd.teamRatio, cd.groupRatio or 0, tostring(cd.go)))
assert(cd.go and cd.groupRatio >= 1.2)
-- Pushing a tower with nobody visible there, but a strong enemy seen next to
-- it 5 s ago (now in the fog): not a free x99 any more.
SIM_T = SIM_T + 10
local tbF = hero('terrorblade', 3, Vector(5000, 5000), 2500, 400) tbF.pid = 5
local pusher = hero('enigma', 2, Vector(3000, 3000), 1400, 120)
allies, enemies = { pusher }, { tbF }
O.RememberEnemies()
enemies = {}
seenNear[5] = true
local oldInfo = GetHeroLastSeenInfo
GetHeroLastSeenInfo = function(pid) if pid == 5 then return { { time_since_seen = 5, location = Vector(5100, 5000) } } end return oldInfo(pid) end
local fFog = O.FightAt(Vector(5000, 5000), pusher)
print(string.format('Enigma pushing a tower, Terrorblade in the fog by it: x%.2f', fFog))
assert(fFog < 1.0)
GetHeroLastSeenInfo = oldInfo
-- SF alone at their T4: one enemy by the tower, three more seen earlier
-- elsewhere. For their base everyone counts: no go alone.
SIM_T = SIM_T + 10
local sfB = hero('nevermore', 2, Vector(5000, 5000), 2200, 300)
local e1 = hero('largo', 3, Vector(5300, 5000), 1800, 120) e1.pid = 5
local e2 = hero('dragon_knight', 3, Vector(-3000, 0), 2500, 200) e2.pid = 6
local e3 = hero('skeleton_king', 3, Vector(-3000, 500), 3000, 250) e3.pid = 7
local e4 = hero('ringmaster', 3, Vector(-3000, -500), 1600, 150) e4.pid = 8
allies, enemies = { sfB }, { e1, e2, e3, e4 }
O.RememberEnemies()
enemies = { e1 }
local near = O.FightAt(Vector(5000, 5000), sfB)
local all = O.FightAt(Vector(5000, 5000), sfB, true)
print(string.format('SF alone at their T4: nearby only x%.2f, everyone defending x%.2f', near, all))
assert(all < 1.2 and all < near)
-- LC on Lion: alone with him it's ours, but three of Lion's allies are
-- 2500 away and coming: the group fight isn't a go any more.
SIM_T = SIM_T + 10
local lc = hero('legion_commander', 2, Vector(0, 0), 1500, 200)
local lion = hero('lion', 3, Vector(300, 0), 700, 120) lion.pid = 5
allies, enemies = { lc }, { lion }
local alone = O.GroupFight(lion).ratio
SIM_T = SIM_T + 2
local h1 = hero('earthshaker', 3, Vector(2500, 0), 1600, 150) h1.pid = 6
local h2 = hero('hoodwink', 3, Vector(2400, 500), 1100, 150) h2.pid = 7
local h3 = hero('dragon_knight', 3, Vector(2600, -400), 1900, 150) h3.pid = 8
enemies = { lion, h1, h2, h3 }
local coming = O.GroupFight(lion).ratio
print(string.format('LC on Lion: alone x%.2f, with three of theirs coming x%.2f', alone, coming))
assert(coming < alone and coming < 1.2)
-- An enemy WK: second life counted until his rebirth is seen, then not.
SIM_T = SIM_T + 10
local wkE = hero('skeleton_king', 3, Vector(400, 0), 2000, 200) wkE.pid = 9
local before = O.ExtraLife(wkE)
wkE.hp = 100 O.ExtraLife(wkE) -- nearly dead
SIM_T = SIM_T + 3 wkE.hp = 1950 -- back, full
local after = O.ExtraLife(wkE)
print(string.format('enemy WK second life: before %d, after his rebirth %d', before, after))
assert(before > 0 and after == 0)
print('combat ok')

-- Laning: one hero's harass ("they kill us in ~4 s" is their full 4 s) is no
-- retreat; two heroes hitting us at once is (Ursa and Sven spent 20-25% of
-- the first 5 minutes backing off from single harass hits, 9105606782).
do
	J.IsInLaningPhase = function() return true end
	local h1 = hero('dragon_knight', 3, Vector(300, 0), 700, 200) h1.pid = 5
	local h2 = hero('terrorblade', 3, Vector(350, 100), 650, 200) h2.pid = 6
	me.loc, me.hp = Vector(0, 0), 1200 -- 60%
	allies = { me }
	enemies = { h1, h2 }
	local hitBy = { [h1] = true }
	me.WasRecentlyDamagedByHero = function(_, e) return hitBy[e] == true end
	me._decision, me._fightHintT, me._hpHist = nil, nil, nil
	SIM_T = SIM_T + 10
	local one = O.FightHint(me)
	print(string.format('lane, harassed by one (them %.1f s): hint %.2f', me._combat.ttkThem, one))
	assert(one < 0.9, 'a single harasser should not make a lane retreat')
	hitBy[h2] = true
	me._decision, me._fightHintT, me._hpHist = nil, nil, nil
	SIM_T = SIM_T + 10
	local two = O.FightHint(me)
	print(string.format('lane, hit by both (them %.1f s): hint %.2f', me._combat.ttkThem, two))
	assert(two >= 0.9, 'two heroes on us should make a lane retreat')
	J.IsInLaningPhase = function() return false end
end
print('lane calm ok')

-- Out of lane: hit by two we can't kill, dead in ~6 s -> leave (Vengeful
-- kept hitting a tower under Keeper and Dragon Knight, 9105606782).
do
	J.IsInLaningPhase = function() return false end
	local k = hero('keeper_of_the_light', 3, Vector(500, 0), 1800, 120) k.pid = 5
	local d = hero('dragon_knight', 3, Vector(300, 200), 2400, 140) d.pid = 6
	me.loc, me.hp = Vector(0, 0), 1500
	me.GetAttackDamage = function() return 5 end me.dps = 5
	allies = { me } enemies = { k, d }
	me.WasRecentlyDamagedByAnyHero = function() return true end
	local c = O.Combat(me)
	print(string.format('hit by two, can\'t kill: us %.0f s, them %.1f s, retreat=%s', c.ttkUs, c.ttkThem, tostring(c.retreat)))
	assert(c.retreat, 'should leave')
	me.dps = 250 me.GetAttackDamage = function() return 60 end
end
print('outmatched retreat ok')
