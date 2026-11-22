-- Kill combo: when an enemy hero near us dies to the damage we have ready,
-- use the spells on it in a sensible order, whatever the hero file's own
-- conditions say (they mostly check "does this one spell kill alone", so a
-- target that two spells kill together walked away).
--
--   * killable: our heroes within 1200 of the target have the ready damage
--     for 2.5 s (engine estimate, spells included) to beat its HP, shields,
--     second life and regen; a target two right-clicks finish is left to the
--     attack (no spells wasted);
--   * order: disables first (stun, root, hex, silence, sleep), then damage,
--     the ultimate last and only when the rest isn't enough;
--   * spells: enemy unit-target ones in cast range, point ones on the
--     target's predicted spot, no-target ones when it's inside their radius.
--     Not toggles, channels, passives, or spells with neither damage nor a
--     disable (blinks and such);
--   * not on a target that's magic immune, in Shallow Grave, False Promise,
--     Borrowed Time, Aegis-less reincarnation is counted as more HP.
-- Called first in AbilityUsageThink; returns true when it cast something.

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local okO, Objectives = pcall(require, GetScriptDirectory()..'/FunLib/objectives')
if not okO then Objectives = nil end

local X = {}

local RANGE = 1200
local WINDOW = 2.5

local DISABLE_KEYS = { 'stun_duration', 'hero_stun_duration', 'stun_time', 'root_duration', 'hex_duration',
	'silence_duration', 'sleep_duration', 'fear_duration', 'duration_stun', 'stun', 'bash_duration' }
local DAMAGE_KEYS = { 'damage', 'total_damage', 'base_damage', 'hero_damage', 'damage_per_second', 'target_damage' }
local SAVES = { 'modifier_dazzle_shallow_grave', 'modifier_oracle_false_promise_timer', 'modifier_abaddon_borrowed_time',
	'modifier_templar_assassin_refraction_absorb', 'modifier_item_aeon_disk_buff', 'modifier_winter_wyvern_winters_curse_aura' }

-- Moves that take the hero into them or cost it its life: not here.
local SKIP = { storm_spirit_ball_lightning = true, phoenix_icarus_dive = true, techies_suicide = true,
	life_stealer_infest = true, ember_spirit_activate_fire_remnant = true, monkey_king_tree_dance = true,
	morphling_waveform = true, magnataur_skewer = true, mirana_leap = true, pangolier_gyroshot = true,
	snapfire_gobble_up = true, tiny_toss = true, rattletrap_hookshot = true }

local function Has(b, flag)
	if not b or not flag or flag == 0 then return false end
	return math.floor(b / flag) % 2 == 1
end

local function Special(ab, keys)
	for _, k in ipairs(keys) do
		local ok, v = pcall(function() return ab:GetSpecialValueFloat(k) end)
		if ok and v and v > 0 then return v end
	end
	return 0
end

local function Damage(ab)
	local d = 0
	pcall(function() d = ab:GetAbilityDamage() or 0 end)
	if d <= 0 then d = Special(ab, DAMAGE_KEYS) end
	return d
end

local function Radius(ab)
	return Special(ab, { 'radius', 'aoe', 'area_of_effect', 'damage_radius', 'impact_radius' })
end

-- The castable spells of the bot that can hit `target` now.
local function Spells(bot, target)
	local list = {}
	local dist = GetUnitToUnitDistance(bot, target)
	for i = 0, 23 do
		local ab = bot:GetAbilityInSlot(i)
		if ab and not ab:IsNull() and not ab:IsPassive() and not ab:IsHidden() and ab:IsTrained() and ab:IsFullyCastable()
		and not SKIP[ab:GetName()] then
			local b = ab:GetBehavior()
			-- Autocast attack modifiers (Viper's Poison Attack, Frost Arrows)
			-- are cast by hand on the target: Viper had Medusa low after his
			-- ultimate and never used Poison Attack to finish her.
			local orb = Has(b, ABILITY_BEHAVIOR_AUTOCAST) and Has(b, ABILITY_BEHAVIOR_UNIT_TARGET)
			local skip = Has(b, ABILITY_BEHAVIOR_TOGGLE) or Has(b, ABILITY_BEHAVIOR_CHANNELLED)
				or (Has(b, ABILITY_BEHAVIOR_AUTOCAST) and not orb) or Has(b, ABILITY_BEHAVIOR_PASSIVE)
			local disable = Special(ab, DISABLE_KEYS)
			local dmg = Damage(ab)
			if not skip and (disable > 0 or dmg > 0) then
				local kind
				local range = math.max(ab:GetCastRange(), 0) + 150
				if Has(b, ABILITY_BEHAVIOR_UNIT_TARGET) then
					local team = ab:GetTargetTeam()
					if (team == ABILITY_TARGET_TEAM_ENEMY or Has(team, ABILITY_TARGET_TEAM_ENEMY)) and dist <= range then kind = 'unit' end
				elseif Has(b, ABILITY_BEHAVIOR_POINT) then
					if dist <= range + Radius(ab) * 0.5 then kind = 'point' end
				elseif Has(b, ABILITY_BEHAVIOR_NO_TARGET) then
					local r = Radius(ab)
					if r > 0 and dist <= r - 50 then kind = 'none' end
				end
				if kind then
					table.insert(list, { ab = ab, kind = kind, disable = disable, dmg = dmg, ult = ab:IsUltimate(),
						cost = ab:GetManaCost(), point = ab:GetCastPoint() })
				end
			end
		end
	end
	return list
end

-- An enemy tower next to the target (Chaos Knight walked from his bounty
-- rune under Radiant's mid T1 at 0:30 to stun Sand King, then on to his
-- lane): in the laning stage never; later only when it's dying anyway.
local function UnderTheirTower(t)
	for _, id in ipairs({ TOWER_TOP_1, TOWER_MID_1, TOWER_BOT_1, TOWER_TOP_2, TOWER_MID_2, TOWER_BOT_2,
		TOWER_TOP_3, TOWER_MID_3, TOWER_BOT_3, TOWER_BASE_1, TOWER_BASE_2 }) do
		local tw = id and GetTower(GetOpposingTeam(), id)
		if tw and GetUnitToUnitDistance(tw, t) < 850 then return true end
	end
	return false
end

local function TargetOk(t)
	if not J.IsValidHero(t) or J.IsSuspiciousIllusion(t) or t:IsMagicImmune() or t:IsInvulnerable() then return false end
	if UnderTheirTower(t) and (J.IsInLaningPhase() or J.GetHP(t) > 0.25) then return false end
	for _, m in ipairs(SAVES) do if t:HasModifier(m) then return false end end
	return J.CanCastOnNonMagicImmune(t)
end

-- HP to beat: health, shields and a second life, regen over the window.
local function NeedHP(t)
	local hp = t:GetHealth()
	pcall(function() hp = hp + t:GetHealthRegen() * WINDOW end)
	if Objectives and Objectives.ShieldHP then hp = hp + Objectives.ShieldHP(t) end
	return hp
end

local function TeamDamage(t)
	local sum = 0
	for _, a in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES)) do
		if J.IsValidHero(a) and not a:IsIllusion() and GetUnitToUnitDistance(a, t) <= RANGE then
			local ok, v = pcall(function() return a:GetEstimatedDamageToTarget(true, t, WINDOW, DAMAGE_TYPE_ALL) end)
			if ok and v then sum = sum + v end
		end
	end
	return sum
end

local function Log(bot, msg) print('[Fight] '..bot:GetUnitName()..': '..msg) end

function X.Think(bot)
	if not bot:IsAlive() or bot:IsChanneling() or bot:IsCastingAbility() or bot:IsUsingAbility() then return false end
	if J.CanNotUseAbility(bot) or bot:IsSilenced() then return false end
	local t = DotaTime()
	-- A combo in progress keeps its target.
	local c = bot._killCombo
	local target
	if c and t < c.untilT and TargetOk(c.target) then
		target = c.target
	else
		bot._killCombo = nil
		local best, bestHP
		for _, e in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES)) do
			if TargetOk(e) and GetUnitToUnitDistance(bot, e) <= RANGE then
				local need = NeedHP(e)
				-- Two right-clicks finish it: no spells.
				local hits = bot:GetAttackDamage() * 2
				local inReach = GetUnitToUnitDistance(bot, e) <= bot:GetAttackRange() + 100
				if not (inReach and e:GetHealth() <= hits) and TeamDamage(e) >= need then
					if not bestHP or need < bestHP then best, bestHP = e, need end
				end
			end
		end
		if not best then return false end
		target = best
	end

	local spells = Spells(bot, target)
	if #spells == 0 then return false end
	-- The ultimate only when the rest of our damage isn't enough.
	local rest = 0
	for _, s in ipairs(spells) do if not s.ult then rest = rest + s.dmg end end
	local need = NeedHP(target)
	local function ok(s) return not s.ult or rest * (1 - target:GetMagicResist()) < need end
	-- Disables first (unless it's already disabled), then the biggest damage.
	table.sort(spells, function(a, b)
		local da = a.disable > 0 and not J.IsDisabled(target)
		local db = b.disable > 0 and not J.IsDisabled(target)
		if da ~= db then return da end
		if a.ult ~= b.ult then return not a.ult end
		return a.dmg > b.dmg
	end)
	for _, s in ipairs(spells) do
		if ok(s) and bot:GetMana() >= s.cost then
			if not bot._killCombo then
				bot._killCombo = { target = target, untilT = t + 4 }
				Log(bot, string.format('kill combo on %s (needs %d)', target:GetUnitName(), math.floor(need)))
			end
			bot:SetTarget(target)
			bot.forceFightUntil = t + 2
			if s.kind == 'unit' then
				bot:Action_UseAbilityOnEntity(s.ab, target)
			elseif s.kind == 'point' then
				bot:Action_UseAbilityOnLocation(s.ab, target:GetExtrapolatedLocation(s.point + 0.3))
			else
				bot:Action_UseAbility(s.ab)
			end
			return true
		end
	end
	return false
end

return X
