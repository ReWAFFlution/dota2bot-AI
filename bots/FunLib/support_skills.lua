-- Heal and mana skills used when someone needs them.
--
-- Hero files mostly cast their heals inside fights; out of a fight a hurt ally
-- (or the hero itself) was left as it was. This runs after the hero's own
-- ability logic (ability_item_usage_generic.AbilityUsageThink) and, when the
-- hero isn't casting anything, uses a heal / mana skill on whoever needs it:
--   * regular heals: an ally (or self) below 60% HP;
--   * strong or costly ones (Chen's Hand of God, Oracle's False Promise,
--     Winter Wyvern's Cold Embrace): only to save someone low and under attack;
--   * mana (KotL's Chakra Magic): an ally missing more than the restore.
-- Allies healing at the fountain are skipped, and the caster keeps some mana
-- for its fight spells unless it's an emergency.

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')

local X = {}

-- kind: 'unit' (ally target), 'none' (around the caster / global), 'loc'
-- (ground at the caster), 'toggle'. hp: trigger HP share. radius for 'none'.
local SKILLS = {
	{ name = 'omniknight_purification', kind = 'unit', hp = 0.6 },
	{ name = 'treant_living_armor', kind = 'unit', hp = 0.6, global = true },
	{ name = 'warlock_shadow_word', kind = 'unit', hp = 0.6 },
	{ name = 'dazzle_shadow_wave', kind = 'unit', hp = 0.65 },
	{ name = 'abaddon_death_coil', kind = 'unit', hp = 0.6, selfCost = true },
	{ name = 'undying_soul_rip', kind = 'unit', hp = 0.6 },
	{ name = 'legion_commander_press_the_attack', kind = 'unit', hp = 0.55 },
	{ name = 'enchantress_natures_attendants', kind = 'none', hp = 0.6, radius = 300 },
	{ name = 'necrolyte_death_pulse', kind = 'none', hp = 0.7, radius = 500 },
	{ name = 'juggernaut_healing_ward', kind = 'loc', hp = 0.5, radius = 450 },
	{ name = 'witch_doctor_voodoo_restoration', kind = 'toggle', hp = 0.75, radius = 500 },
	{ name = 'chen_hand_of_god', kind = 'none', hp = 0.3, global = true, emergency = true },
	{ name = 'oracle_false_promise', kind = 'unit', hp = 0.25, emergency = true },
	{ name = 'winter_wyvern_cold_embrace', kind = 'unit', hp = 0.3, emergency = true },
	{ name = 'keeper_of_the_light_chakra_magic', kind = 'unit', mana = true },
}

local function Log(bot, msg) print('[Heal] '..bot:GetUnitName()..': '..msg) end

local function Allies(bot, radius)
	local list = {}
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if m and m:IsAlive() and not m:IsIllusion() and (not radius or GetUnitToUnitDistance(bot, m) <= radius)
		and not m:HasModifier('modifier_fountain_aura_buff') then
			table.insert(list, m)
		end
	end
	return list
end

local function UnderAttack(m)
	return m:WasRecentlyDamagedByAnyHero(2.0) or m:WasRecentlyDamagedByTower(2.0)
end

-- Enough mana left for the hero's fight spells afterwards (unless emergency).
local function ManaOk(bot, ability, emergency)
	local cost = ability:GetManaCost() or 0
	if emergency then return bot:GetMana() >= cost end
	return bot:GetMana() - cost >= bot:GetMaxMana() * 0.2
end

local function MissingMana(m) return m:GetMaxMana() - m:GetMana() end

-- The ally this skill should go to (lowest HP share below the trigger).
local function PickTarget(bot, s, ability)
	local range = s.global and nil or (math.max(ability:GetCastRange(), 150) + 200)
	local best, bestV
	for _, m in ipairs(Allies(bot, range)) do
		if s.mana then
			local need = ability:GetSpecialValueInt('mana_restore')
			if need <= 0 then need = 100 end
			local missing = MissingMana(m)
			if m ~= bot and missing > need * 1.2 and (not bestV or missing > bestV) then best, bestV = m, missing end
			if m == bot and missing > need * 1.2 and not best then best, bestV = m, missing end
		else
			local hp = J.GetHP(m)
			local ok = hp < s.hp and (not s.emergency or UnderAttack(m))
			if s.selfCost and m == bot then ok = false end
			if ok and (not bestV or hp < bestV) then best, bestV = m, hp end
		end
	end
	return best
end

-- Someone around the caster (radius) below the trigger.
local function AnyHurtAround(bot, s)
	for _, m in ipairs(Allies(bot, s.global and nil or s.radius)) do
		if J.GetHP(m) < s.hp and (not s.emergency or UnderAttack(m)) then return m end
	end
	return nil
end

-- Returns true when it cast something.
function X.Think(bot)
	if not bot:IsAlive() or bot:IsChanneling() or bot:IsCastingAbility() or bot:IsUsingAbility() then return false end
	if J.CanNotUseAction(bot) or bot:IsSilenced() or bot:HasModifier('modifier_fountain_aura_buff') then return false end
	-- Don't replace a spell the hero's own logic just ordered.
	local ok, actionType = pcall(function() return bot:GetCurrentActionType() end)
	if ok and BOT_ACTION_TYPE_USE_ABILITY ~= nil and actionType == BOT_ACTION_TYPE_USE_ABILITY then return false end
	for _, s in ipairs(SKILLS) do
		local ability = bot:GetAbilityByName(s.name)
		if ability and ability:IsTrained() and not ability:IsPassive() then
			if s.kind == 'toggle' then
				local hurt = AnyHurtAround(bot, s)
				local on = ability:GetToggleState()
				if hurt and not on and ability:IsFullyCastable() and ManaOk(bot, ability, false) then
					bot:Action_UseAbility(ability)
					return true
				elseif on and not hurt then
					bot:Action_UseAbility(ability) -- stop draining mana
					return true
				end
			elseif ability:IsFullyCastable() and ManaOk(bot, ability, s.emergency)
			and not (s.selfCost and J.GetHP(bot) < 0.5) then
				if s.kind == 'unit' then
					local target = PickTarget(bot, s, ability)
					if target then
						Log(bot, s.name..' on '..target:GetUnitName()..string.format(' (%d%% %s)',
							math.floor((s.mana and target:GetMana() / math.max(1, target:GetMaxMana()) or J.GetHP(target)) * 100), s.mana and 'mana' or 'HP'))
						bot:Action_UseAbilityOnEntity(ability, target)
						return true
					end
				elseif s.kind == 'none' then
					local hurt = AnyHurtAround(bot, s)
					if hurt then
						Log(bot, s.name..' for '..hurt:GetUnitName())
						bot:Action_UseAbility(ability)
						return true
					end
				elseif s.kind == 'loc' then
					local hurt = AnyHurtAround(bot, s)
					if hurt then
						bot:Action_UseAbilityOnLocation(ability, bot:GetLocation())
						return true
					end
				end
			end
		end
	end
	return false
end

return X
