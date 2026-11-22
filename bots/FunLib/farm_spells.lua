-- Farm spells: cores clear camps and waves with their area spells, not only
-- with attacks (the farm mode only right-clicked; most hero files cast
-- nothing on creeps, and at 35:00 the bot carries had a third of a human
-- carry's last hits).
--
-- When: a core (pos 1-3) in the farm or push modes, no enemy hero within
-- 1200, the hero's own logic cast nothing this frame. What: a ready area
-- spell with damage (not the ultimate, not a channel/toggle/autocast, not a
-- dive) on the densest group of 3+ creeps it reaches, when the group has
-- clearly more HP than the spell deals. Mana: the ultimate's cost plus 75
-- stays, and at least 40% of the pool.
-- Called from AbilityUsageThink after the hero's own skills; true when cast.

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')

local X = {}

local SKIP = { storm_spirit_ball_lightning = true, phoenix_icarus_dive = true, techies_suicide = true,
	life_stealer_infest = true, ember_spirit_activate_fire_remnant = true, monkey_king_tree_dance = true,
	morphling_waveform = true, magnataur_skewer = true, mirana_leap = true, pangolier_gyroshot = true,
	snapfire_gobble_up = true, tiny_toss = true, rattletrap_hookshot = true, pudge_meat_hook = true,
	earth_spirit_rolling_boulder = true, void_spirit_astral_step = true, ember_spirit_fire_remnant = true }

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
	if d <= 0 then d = Special(ab, { 'damage', 'total_damage', 'base_damage', 'damage_per_second', 'creep_damage', 'target_damage' }) end
	return d
end

local function Radius(ab)
	return Special(ab, { 'radius', 'aoe', 'area_of_effect', 'damage_radius', 'impact_radius', 'end_radius', 'width' })
end

local function FarmMode(bot)
	local m = bot:GetActiveMode()
	return m == BOT_MODE_FARM or m == BOT_MODE_PUSH_TOWER_TOP or m == BOT_MODE_PUSH_TOWER_MID or m == BOT_MODE_PUSH_TOWER_BOT
end

-- Densest group of creeps around one of them within `reach`.
local function BestGroup(bot, creeps, radius, reach)
	local best, bestN, bestHP
	for _, c in ipairs(creeps) do
		if GetUnitToUnitDistance(bot, c) <= reach then
			local n, hp = 0, 0
			for _, o in ipairs(creeps) do
				if GetUnitToUnitDistance(c, o) <= radius then n, hp = n + 1, hp + o:GetHealth() end
			end
			if not bestN or n > bestN then best, bestN, bestHP = c, n, hp end
		end
	end
	return best, bestN or 0, bestHP or 0
end

local function UltCost(bot)
	local cost = 0
	for i = 0, 23 do
		local ab = bot:GetAbilityInSlot(i)
		if ab and not ab:IsNull() and ab:IsUltimate() and ab:IsTrained() then cost = math.max(cost, ab:GetManaCost()) end
	end
	return cost
end

function X.Think(bot)
	if J.GetPosition(bot) > 3 or not bot:IsAlive() or not FarmMode(bot) then return false end
	if bot:IsChanneling() or bot:IsCastingAbility() or bot:IsUsingAbility() or J.CanNotUseAbility(bot) or bot:IsSilenced() then return false end
	if bot:HasModifier('modifier_spirit_breaker_charge_of_darkness') then return false end
	if DotaTime() < (bot._farmSpellT or -math.huge) + 1.5 then return false end
	if #J.GetEnemiesNearLoc(bot:GetLocation(), 1200) > 0 then return false end
	local creeps = {}
	for _, c in pairs(bot:GetNearbyCreeps(1100, true)) do
		if J.IsValid(c) and J.CanBeAttacked(c) and not J.IsRoshan(c) then table.insert(creeps, c) end
	end
	if #creeps < 3 then return false end
	local keep = math.max(UltCost(bot) + 75, bot:GetMaxMana() * 0.4)

	for i = 0, 23 do
		local ab = bot:GetAbilityInSlot(i)
		if ab and not ab:IsNull() and ab:IsTrained() and not ab:IsPassive() and not ab:IsHidden() and not ab:IsUltimate()
		and ab:IsFullyCastable() and not SKIP[ab:GetName()] and bot:GetMana() - ab:GetManaCost() >= keep then
			local b = ab:GetBehavior()
			local bad = Has(b, ABILITY_BEHAVIOR_TOGGLE) or Has(b, ABILITY_BEHAVIOR_CHANNELLED) or Has(b, ABILITY_BEHAVIOR_AUTOCAST)
			local dmg, radius = Damage(ab), Radius(ab)
			if not bad and dmg > 0 and radius > 0 then
				local reach = math.max(ab:GetCastRange(), 0) + 100
				if Has(b, ABILITY_BEHAVIOR_NO_TARGET) then
					local n, hp = 0, 0
					for _, c in ipairs(creeps) do
						if GetUnitToUnitDistance(bot, c) <= radius - 30 then n, hp = n + 1, hp + c:GetHealth() end
					end
					if n >= 3 and hp >= dmg * 1.5 then
						bot._farmSpellT = DotaTime()
						bot:Action_UseAbility(ab)
						return true
					end
				else
					local center, n, hp = BestGroup(bot, creeps, radius, reach)
					if center and n >= 3 and hp >= dmg * 1.5 then
						bot._farmSpellT = DotaTime()
						if Has(b, ABILITY_BEHAVIOR_POINT) then
							bot:Action_UseAbilityOnLocation(ab, center:GetLocation())
							return true
						elseif Has(b, ABILITY_BEHAVIOR_UNIT_TARGET) then
							local team = ab:GetTargetTeam()
							if team == ABILITY_TARGET_TEAM_ENEMY or Has(team, ABILITY_TARGET_TEAM_ENEMY) then
								bot:Action_UseAbilityOnEntity(ab, center)
								return true
							end
						end
					end
				end
			end
		end
	end
	return false
end

return X
