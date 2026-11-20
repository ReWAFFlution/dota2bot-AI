if GetBot():IsInvulnerable() or not GetBot():IsHero() or not string.find(GetBot():GetUnitName(), "hero") or  GetBot():IsIllusion() then
	return
end

local X = {}

local bot = GetBot()
local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local W = require(GetScriptDirectory() ..'/FunLib/aba_ward_utility')
local okMapObjects, MapObjects = pcall(require, GetScriptDirectory()..'/FunLib/map_objects')
if not okMapObjects then MapObjects = nil end
local Objectives = require(GetScriptDirectory()..'/FunLib/objectives')
local StuckGuard = require(GetScriptDirectory()..'/FunLib/stuck_guard')
local Customize = require(GetScriptDirectory()..'/Customize/general')
Customize.ThinkLess = Customize.Enable and Customize.ThinkLess or 1

local nObserverWardCastRange = 500
local nSentryWardCastRange = 500

local ObserverWard = nil
local SentryWard = nil

local hTargetSpot = nil
local sTargetKind = nil -- 'obs' or 'sentry': the ward meant for hTargetSpot
local hDeward = nil -- an enemy ward we see and go to kill
local fLastWardPlantTime = -math.huge

function GetDesire()
	if J.GetPosition(bot) <= 3 then return BOT_MODE_DESIRE_NONE end
	if StuckGuard.Blocked(bot, 'ward', BOT_MODE_WARD, 20) then return BOT_MODE_DESIRE_NONE end
	-- local cacheKey = 'GetWardDesire'..tostring(bot:GetPlayerID())
	-- local cachedVar = J.Utils.GetCachedVars(cacheKey, 0.6 * (1 + Customize.ThinkLess))
	-- if DotaTime() > 30 and cachedVar ~= nil then return cachedVar end
	local res = GetDesireHelper()
	-- J.Utils.SetCachedVars(cacheKey, res)
	return RemapValClamped(J.GetHP(bot) * res, 0, 1, BOT_MODE_DESIRE_NONE, res)
end
function GetDesireHelper()
    if not X.IsSuitableToWard() then
        return BOT_MODE_DESIRE_NONE
    end
    -- Deward: an enemy ward we see (our sentry, true sight) within 1600 and
    -- nobody of theirs at it. The bots never attacked a ward; the human
    -- supports in 9098678691 killed 6 observers and 12 sentries between them.
    hDeward = X.EnemyWardToKill()
    if hDeward then return BOT_MODE_DESIRE_VERYHIGH end

	-- 如果在打高地 就别撤退去干别的
	if J.Utils.IsTeamPushingSecondTierOrHighGround(bot) then
		return BOT_MODE_DESIRE_NONE
	end
	local enemiesAtAncient = J.Utils.CountEnemyHeroesNear(GetAncient(GetTeam()):GetLocation(), 3200)
    if enemiesAtAncient >= 1 then
        return BOT_MODE_DESIRE_NONE
    end

    -- Wards wait in the backpack between plants (item_purchase_generic moves
    -- them there), so look at slots 0-8; Think brings them to the main bar.
    ObserverWard, SentryWard = nil, nil
    for i = 0, 8 do
        local hItem = bot:GetItemInSlot(i)
        if hItem then
            local sItemName = hItem:GetName()
            if sItemName == 'item_ward_observer' or sItemName == 'item_ward_dispenser' then
                ObserverWard = hItem
				break
            end
        end
    end
    -- Wards held for a while: walk further to use them.
    local bHasWard = false
    for i = 0, 8 do
        local it = bot:GetItemInSlot(i)
        if it and (it:GetName() == 'item_ward_observer' or it:GetName() == 'item_ward_sentry' or it:GetName() == 'item_ward_dispenser') then bHasWard = true end
    end
    if bHasWard then bot._wardHeldSince = bot._wardHeldSince or DotaTime() else bot._wardHeldSince = nil end
    local nWardRange = DotaTime() > 10 * 60 and 5000 or 3200
    if bot._wardHeldSince and DotaTime() - bot._wardHeldSince > 45 then nWardRange = 9000 end

    -- Observer
    if X.WardReady(ObserverWard) then
        local hAvailabeObserverWardSpots = W.GetAvailabeObserverWardSpots(bot)
        hTargetSpot = W.GetClosestObserverWardSpot(bot, X.Unblocked(hAvailabeObserverWardSpots))
        sTargetKind = 'obs'
		if hTargetSpot and (not X.IsEnemyCloserToWardLocation(hTargetSpot.location) or J.IsRealInvisible(bot)) then
			if DotaTime() < 0 and DotaTime() > (J.IsModeTurbo() and -45 or -60) then
				return BOT_MODE_DESIRE_ABSOLUTE
			end

			if DotaTime() > fLastWardPlantTime + 1.0 then
				if GetUnitToLocationDistance(bot, hTargetSpot.location) <= nWardRange then
					return BOT_MODE_DESIRE_VERYHIGH
				end
			end
		end
    end

	for i = 0, 8 do
        local hItem = bot:GetItemInSlot(i)
        if hItem then
            local sItemName = hItem:GetName()
            if sItemName == 'item_ward_sentry' or sItemName == 'item_ward_dispenser' then
                SentryWard = hItem
				break
            end
        end
    end

    -- Sentry
    if X.WardReady(SentryWard) then
        local hPossibleSentryWardSpots = W.GetPossibleSentryWardSpots(bot)
        hTargetSpot = W.GetClosestSentryWardSpot(bot, X.Unblocked(hPossibleSentryWardSpots))
        sTargetKind = 'sentry'
		if hTargetSpot and (not X.IsEnemyCloserToWardLocation(hTargetSpot.location) or J.IsRealInvisible(bot)) then
			if DotaTime() > fLastWardPlantTime + 1.0 then
				if GetUnitToLocationDistance(bot, hTargetSpot.location) <= 3200 then
					return BOT_MODE_DESIRE_VERYHIGH
				end
			end
		end
    end

	return BOT_MODE_DESIRE_NONE
end

function Think()
	if J.CanNotUseAction(bot) then return end
	if hDeward and J.IsValid(hDeward) and hDeward:CanBeSeen() then
		bot:Action_AttackUnit(hDeward, true)
		return
	end
	if J.Utils.IsBotThinkingMeaningfulAction(bot, Customize.ThinkLess, "ward") then return end
	if hTargetSpot then
		if X.BringWardToMainSlot(ObserverWard) or X.BringWardToMainSlot(SentryWard) then return end
		if X.SpotIsBlocked(hTargetSpot) then return end
		if sTargetKind ~= 'sentry' and ObserverWard and J.CanCastAbility(ObserverWard) then
			if GetUnitToLocationDistance(bot, hTargetSpot.location) <= nObserverWardCastRange then
				-- Plant on the highest ground within reach of the spot.
				if not hTargetSpot.refined then
					hTargetSpot.refined = true
					hTargetSpot.location = W.HighGroundNear(hTargetSpot.location, 250)
				end
				if ObserverWard:GetName() == 'item_ward_observer' then
					bot:Action_UseAbilityOnLocation(ObserverWard, hTargetSpot.location)
				else
					if ObserverWard:GetToggleState() == false then
						bot:Action_UseAbilityOnEntity(ObserverWard, bot)
						return
					else
						bot:Action_UseAbilityOnLocation(ObserverWard, hTargetSpot.location)
					end
				end

				hTargetSpot.plant_time_obs = DotaTime()
				return
			else
				bot:Action_MoveToLocation(hTargetSpot.location)
				return
			end
		end

		if sTargetKind ~= 'obs' and SentryWard and J.CanCastAbility(SentryWard) then
			if GetUnitToLocationDistance(bot, hTargetSpot.location) <= nSentryWardCastRange then
				local fLength = 0
				if W.IsOtherWardClose(hTargetSpot.location, 'npc_dota_observer_wards', 300, true, false) then
					fLength = 30
				end

				if SentryWard:GetName() == 'item_ward_sentry' then
					bot:Action_UseAbilityOnLocation(SentryWard, hTargetSpot.location + RandomVector(fLength))
				else
					if SentryWard:GetToggleState() == true then
						bot:Action_UseAbilityOnEntity(SentryWard, bot)
						return
					else
						bot:Action_UseAbilityOnLocation(SentryWard, hTargetSpot.location + RandomVector(fLength))
					end
				end

				hTargetSpot.plant_time_sentry = DotaTime()
				return
			else
				bot:Action_MoveToLocation(hTargetSpot.location)
				return
			end
		end
	end
end

-- A ward that can be planted now, or once it's moved out of the backpack.
function X.WardReady(hItem)
	if hItem == nil or hItem:IsNull() then return false end
	local slot = bot:FindItemSlot(hItem:GetName())
	if slot >= 6 and slot <= 8 then return hItem:GetCurrentCharges() > 0 or hItem:GetName() == 'item_ward_dispenser' end
	return J.CanCastAbility(hItem)
end

-- Swap a backpack ward into the main bar (with the cheapest item if it's full).
-- Returns true when it swapped this frame.
function X.BringWardToMainSlot(hItem)
	if hItem == nil or hItem:IsNull() then return false end
	local slot = bot:FindItemSlot(hItem:GetName())
	if slot < 6 or slot > 8 then return false end
	local target, cheapest = nil, math.huge
	for i = 0, 5 do
		local it = bot:GetItemInSlot(i)
		if it == nil then target = i break end
		local cost = GetItemCost(it:GetName())
		if cost < cheapest then target, cheapest = i, cost end
	end
	if target then
		bot:ActionImmediate_SwapItems(slot, target)
		bot._wardWantedUntil = DotaTime() + 10 -- item_purchase: don't move it back
		return true
	end
	return false
end

-- A ward that doesn't land within a few seconds at the spot (the spot is
-- taken by a watcher, a building or a tree): skip the spot for 6 minutes.
local tWardTry = nil
local function WardCharges()
	local n = 0
	for i = 0, 8 do
		local it = bot:GetItemInSlot(i)
		if it and (it:GetName() == 'item_ward_observer' or it:GetName() == 'item_ward_sentry' or it:GetName() == 'item_ward_dispenser') then
			n = n + it:GetCurrentCharges()
		end
	end
	return n
end
function X.Unblocked(spots)
	local list = {}
	for _, spot in pairs(spots or {}) do
		-- Not blocked, and safe to walk to alone (FunLib/objectives.lua).
		-- Not next to a watcher either: it gives vision there already.
		if (spot.blocked_until or -math.huge) < DotaTime() and Objectives.SafeSpot(bot, spot.location)
		and not (MapObjects and MapObjects.NearLantern and spot.location and MapObjects.NearLantern(spot.location, 800)) then
			table.insert(list, spot)
		end
	end
	return list
end
function X.SpotIsBlocked(spot)
	local now, charges = DotaTime(), WardCharges()
	-- Only time real attempts: in cast range with a ward ready to cast (a ward
	-- just moved out of the backpack is on cooldown for a few seconds, and that
	-- used to "block" every spot in turn until none was left).
	local ready = (ObserverWard and J.CanCastAbility(ObserverWard)) or (SentryWard and J.CanCastAbility(SentryWard))
	if GetUnitToLocationDistance(bot, spot.location) > 550 or not ready then
		tWardTry = nil
		return false
	end
	if tWardTry == nil or tWardTry.spot ~= spot or charges < tWardTry.charges then
		tWardTry = { spot = spot, t = now, charges = charges }
		return false
	end
	if now > tWardTry.t + 3 then
		print('[Ward] '..bot:GetUnitName()..string.format(' cannot ward at (%d, %d), skipping the spot', spot.location.x, spot.location.y))
		spot.blocked_until = now + 240
		tWardTry = nil
		hTargetSpot = nil
		return true
	end
	return false
end

function X.EnemyWardToKill()
	local best, bd
	for _, w in pairs(GetUnitList(UNIT_LIST_ENEMY_WARDS)) do
		if J.IsValid(w) and w:CanBeSeen() then
			local name = w:GetUnitName() or ''
			if string.find(name, 'observer_wards') or string.find(name, 'sentry_wards') then
				local d = GetUnitToUnitDistance(bot, w)
				if d < 1600 and #J.GetEnemiesNearLoc(w:GetLocation(), 1000) == 0 and (not bd or d < bd) then best, bd = w, d end
			end
		end
	end
	if best and best ~= hDeward then
		print('[Ward] '..bot:GetUnitName()..' dewards '..best:GetUnitName()..string.format(' at (%d, %d)', best:GetLocation().x, best:GetLocation().y))
	end
	return best
end

function X.IsSuitableToWard()
	local nEnemyHeroes = bot:GetNearbyHeroes(1200, true, BOT_MODE_NONE)

	local botActiveMode = bot:GetActiveMode()
    local botActiveModeDesire = bot:GetActiveModeDesire()

	if (J.IsRetreating(bot) and botActiveModeDesire > 0.75)
	or (botActiveMode == BOT_MODE_RUNE and DotaTime() > 0)
	or (botActiveMode == BOT_MODE_DEFEND_ALLY)
	or (nEnemyHeroes ~= nil and #nEnemyHeroes >= 1 and X.IsIBecameTheTarget(nEnemyHeroes))
    or J.IsDefending(bot)
	or J.IsGoingOnSomeone(bot)
	or bot:WasRecentlyDamagedByAnyHero(5.0)
	then
		return false
	end

	return true
end

function X.IsIBecameTheTarget(unitList)
	for _, unit in pairs(unitList) do
		if J.IsValid(unit)
        and not J.IsSuspiciousIllusion(unit)
		and unit:GetAttackTarget() == bot
		then
			return true
		end
	end

	return false
end

function X.IsEnemyCloserToWardLocation(vLocation)
	for _, id in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(id) then
			local info = GetHeroLastSeenInfo(id)
			if info ~= nil then
				local dInfo = info[1]
				if  dInfo ~= nil
				and dInfo.time_since_seen < 3.0
				and J.GetDistance(dInfo.location, vLocation) < GetUnitToLocationDistance(bot, vLocation)
				then
					local nAllyHeroes = J.GetAlliesNearLoc(vLocation, 1200)
					local nEnemyHeroes = J.GetEnemiesNearLoc(vLocation, 1200)
					if #nEnemyHeroes > #nAllyHeroes then
						return true
					end
				end
			end
		end
	end

	return false
end