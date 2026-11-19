-- Item value from the item's own stats, for this hero, now.
--
-- Stats come from FunLib/item_stats_data.lua (generated from the game files by
-- scripts/gen_item_stats.py). Each stat is converted to gold through the basic
-- items that sell it (Blades of Attack: 45 g per damage, Chainmail: 110 g per
-- armor, ...), then weighted for the hero:
--   * primary attribute adds damage (universal heroes get 0.7 per attribute);
--   * physical cores value damage / attack speed / crit / lifesteal, and more
--     so as the game goes on (their base damage grows);
--   * casters value spell amp, mana, regen and cooldowns;
--   * the offlane values health, armor, magic resistance, status resistance;
--   * supports value movement speed, auras and actives;
--   * enemy damage type: armor/evasion against physical, magic resistance and
--     status resistance against nukers/disablers.
-- The score mixes gold efficiency (value/cost, what matters while gold is
-- scarce) with total impact (what matters late, when slots are the limit).

local okData, Data = pcall(require, GetScriptDirectory()..'/FunLib/item_stats_data')
if not okData then Data = nil end
local okRoles, HeroRoles = pcall(require, GetScriptDirectory()..'/FunLib/aba_hero_roles_map')
if not okRoles then HeroRoles = nil end

local X = {}

-- Gold per point of each stat (from the basic items that sell it).
local GOLD = {
	attr = 45, dmg = 45, as = 23, armor = 110, hp = 4, mana = 3.2, hpr = 100, mpr = 160,
	mr = 50, ms = 18, evasion = 45, lifesteal = 45, spell_amp = 110, status = 60, cdr = 90,
}

-- Strong actives, in gold (worth beyond their stats).
local ACTIVE = {
	item_black_king_bar = 2600, item_blink = 2000, item_overwhelming_blink = 2300, item_swift_blink = 2300,
	item_arcane_blink = 2300, item_sheepstick = 2600, item_refresher = 2200, item_aeon_disk = 1800,
	item_glimmer_cape = 1300, item_force_staff = 1100, item_hurricane_pike = 1500, item_lotus_orb = 1500,
	item_pipe = 1200, item_crimson_guard = 1100, item_mekansm = 900, item_guardian_greaves = 1500,
	item_satanic = 1000, item_shivas_guard = 1300, item_manta = 1300, item_silver_edge = 1500,
	item_nullifier = 1500, item_abyssal_blade = 1700, item_bloodthorn = 1500, item_orchid = 900,
	item_heavens_halberd = 1200, item_solar_crest = 900, item_spirit_vessel = 900, item_blade_mail = 900,
	item_harpoon = 1300, item_wind_waker = 1600, item_cyclone = 1000, item_ethereal_blade = 1300,
	item_gungir = 1300, item_rod_of_atos = 800, item_diffusal_blade = 700, item_disperser = 1100,
	item_boots_of_bearing = 1300, item_ancient_janggo = 700, item_vladmir = 0, item_assault = 0,
	item_sphere = 1400, item_caduceus = 1500, item_skypiercer = 1900, item_starforge = 1600,
	item_berserkers_sabatons = 1300, item_bloodslinger = 300, item_ristuls_devotion = 0, item_helm_of_the_dominator = 700, item_mjollnir = 900, item_dagon_5 = 1500, item_heart = 0, item_skadi = 600,
	item_monkey_king_bar = 600, item_butterfly = 0, item_greater_crit = 0, item_radiance = 1200,
}
local AURA_VALUE = 700
local AURA_EXTRA = { item_ristuls_devotion = 1600, item_assault = 900, item_pipe = 500, item_guardian_greaves = 600 }

-- Values in the item files that aren't permanent stats.
local NOT_PERMANENT = { item_aeon_disk = { status = true }, item_refresher = { hpr = true, mpr = true } }

local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function Short(hero) return (string.gsub(hero, '^npc_dota_hero_', '')) end

local function Roles(hero)
	if not HeroRoles or not HeroRoles.HeroRolesMap then return {} end
	return HeroRoles.HeroRolesMap[hero] or HeroRoles.HeroRolesMap[Short(hero)] or {}
end

-- What kind of hero this is, for this position.
function X.Profile(hero, pos)
	local h = Data and Data.Heroes[hero] or {}
	local r = Roles(hero)
	local p = { attr = h.attr or 'all', ranged = h.ranged == 1, bat = h.bat or 1.7 }
	local carry, nuker = r.carry or 0, r.nuker or 0
	p.physical = pos <= 2 and (carry >= 2 or h.attr == 'agi') and not (h.attr == 'int' and nuker >= 2)
	if pos == 1 then p.physical = true end
	p.caster = (h.attr == 'int' or nuker >= 2) and not (pos == 1 and carry >= 2)
	p.tank = pos == 3 or (r.durable or 0) >= 2
	p.support = pos >= 4
	return p
end

-- Enemy damage mix: share of nukers/disablers (magic) vs carries (physical).
function X.EnemyMix()
	local magic, phys, n = 0, 0, 0
	for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
		local name = GetSelectedHeroName(pid)
		if name and name ~= '' then
			local r = Roles(name)
			magic = magic + (r.nuker or 0) + (r.disabler or 0) * 0.5
			phys = phys + (r.carry or 0)
			n = n + 1
		end
	end
	local total = magic + phys
	if total <= 0 then return 0.5, 0.5 end
	return magic / total, phys / total
end

-- Gold-equivalent value of `item` for the hero right now.
function X.Value(hero, pos, item, minutes, magicShare)
	local s = Data and Data.Items[item]
	if not s then return 0, 0 end
	local p = X.Profile(hero, pos)
	minutes = minutes or 20
	magicShare = magicShare or 0.5
	local physShare = 1 - magicShare
	local grow = 1 + Clamp(minutes, 0, 50) / 40 -- % stats scale with the hero's damage

	local w = { dmg = 1, as = 1, crit = 1, lifesteal = 1, spell_amp = 1, mana = 1, mpr = 1, int = 1, str = 1, agi = 1,
	            hp = 1, armor = 1, mr = 1, status = 1, ms = 1, evasion = 1, hpr = 1, cdr = 1 }
	-- Right-click stats matter less for heroes that don't fight with attacks.
	if not p.physical then w.dmg, w.as, w.crit, w.lifesteal = 0.7, 0.7, 0.4, 0.6 end
	if p.physical then
		w.dmg, w.as, w.crit, w.lifesteal = 1.3 * grow, 1.3 * grow * (p.ranged and 1.1 or 1), 1.3 * grow, 1.2
		w.spell_amp, w.mana, w.mpr, w.cdr = 0.3, 0.6, 0.5, 0.4
	end
	if not p.caster then w.cdr = 0.6 end
	if p.caster then
		w.spell_amp, w.mana, w.mpr, w.cdr, w.int = 1.5 * grow, 1.2, 1.3, 1.5, 1.1
		w.dmg, w.as, w.crit, w.lifesteal = 0.5, 0.4, 0.2, 0.3
	end
	if p.tank then
		w.hp, w.armor, w.mr, w.status, w.str = 1.3, 1.3, 1.3, 1.3, 1.2
		if not p.physical then w.crit = 0.3 end
	end
	if p.support then
		w.ms, w.mpr, w.hp = 1.4, 1.2, 1.1
		w.dmg, w.as, w.crit, w.lifesteal = 0.3, 0.3, 0, 0.2
	end
	-- Against the enemy damage.
	w.armor = w.armor * (0.7 + 0.6 * physShare)
	w.evasion = w.evasion * (0.6 + 0.8 * physShare)
	w.mr = w.mr * (0.6 + 0.8 * magicShare)
	w.status = w.status * (0.6 + 0.8 * magicShare)

	local v = 0
	-- Attributes: their own effect plus damage for the primary one.
	local function Attr(name, amount)
		if not amount or amount == 0 then return end
		local primary = (p.attr == name) and 1 or (p.attr == 'all' and 0.7 or 0)
		-- What one point gives (7.42): str 20 HP + 0.1 regen, agi 1/6 armor +
		-- 1 attack speed, int 12 mana + 0.05 mana regen + 0.125% magic resistance.
		local own
		if name == 'str' then own = 20 * GOLD.hp * w.hp + 0.1 * GOLD.hpr * w.hpr
		elseif name == 'agi' then own = GOLD.armor / 6 * w.armor + GOLD.as * w.as
		else own = 12 * GOLD.mana * w.mana + 0.05 * GOLD.mpr * w.mpr + 0.125 * GOLD.mr * w.mr end
		v = v + amount * (own + primary * GOLD.dmg * w.dmg)
	end
	local all = s.all or 0
	Attr('str', (s.str or 0) + all)
	Attr('agi', (s.agi or 0) + all)
	Attr('int', (s.int or 0) + all)

	for _, k in ipairs({ 'dmg', 'as', 'armor', 'hp', 'mana', 'hpr', 'mpr', 'mr', 'ms', 'evasion', 'lifesteal', 'spell_amp', 'status', 'cdr' }) do
		if s[k] and not (NOT_PERMANENT[item] and NOT_PERMANENT[item][k]) then v = v + s[k] * GOLD[k] * (w[k] or 1) end
	end
	-- Crit as average extra damage on ~120 (early) to ~250 (late) hero damage.
	if s.crit and s.crit_chance then
		local base = 120 + 3 * Clamp(minutes, 0, 45)
		v = v + (s.crit_chance / 100) * ((s.crit - 100) / 100) * base * GOLD.dmg * w.crit
	end
	if s.active == 1 or ACTIVE[item] then
		v = v + (ACTIVE[item] or 300) * (p.support and 1.3 or 1)
	end
	if s.aura == 1 then v = v + (AURA_VALUE + (AURA_EXTRA[item] or 0)) * (p.support and 1.4 or 1) end
	return v, s.cost or 0
end

-- Score to rank items: efficiency early, total impact late.
function X.Score(hero, pos, item, minutes, magicShare)
	local v, cost = X.Value(hero, pos, item, minutes, magicShare)
	if cost <= 0 then return 0 end
	local late = Clamp((minutes - 15) / 25, 0, 1)
	return (1 - late) * (v / cost) + late * (v / 4000)
end

return X
