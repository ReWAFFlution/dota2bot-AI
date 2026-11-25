local bot = GetBot()
local botName = bot:GetUnitName();
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

local J = require( GetScriptDirectory()..'/FunLib/jmz_func' )
local Customize = require( GetScriptDirectory()..'/Customize/general' )

local killTime = 0.0
local shouldKillRoshan = false
local DoingRoshanMessage = DotaTime()

-- local rTwinGate = nil
-- local dTwinGate = nil
-- local rTwinGateLoc = Vector(5888, -7168, 256)
-- local dTwinGateLoc = Vector(6144, 7552, 256)

local sinceRoshAliveTime = 0
local roshTimeFlag = false
local initDPSFlag = false

local Roshan

-- Roshan is a team call: the desire (the engine's team Roshan desire per
-- bot) went to whoever had nothing better, and Dragon Knight walked in and
-- hit Roshan alone while the others farmed (bot vs bot 9105606782). Each
-- bot that wants Roshan notes it here; the mode is on only while at least
-- three alive heroes (all of them if fewer are alive) want it, or Roshan is
-- under half HP with us at it. Think waits at the pit until they're there.
RoshanCall = RoshanCall or {}
local function RoshanGroup()
	local calls = RoshanCall[GetTeam()] or {}
	local n, alive = 0, 0
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if m and m:IsAlive() then
			alive = alive + 1
			local tc = calls[m:GetPlayerID()]
			if (tc and DotaTime() - tc < 3) or m:GetActiveMode() == BOT_MODE_ROSHAN then n = n + 1 end
		end
	end
	return n, math.max(1, math.min(3, alive))
end
local function RoshanHere()
	local loc = J.GetCurrentRoshanLocation()
	for _, c in pairs(bot:GetNearbyNeutralCreeps(1600)) do
		if c and not c:IsNull() and c:IsAlive() and c:GetUnitName() == 'npc_dota_roshan' then return c, loc end
	end
	return nil, loc
end

function GetDesire()
	local res = GetDesireHelper()
	RoshanCall[GetTeam()] = RoshanCall[GetTeam()] or {}
	if res > 0.4 then RoshanCall[GetTeam()][bot:GetPlayerID()] = DotaTime() end
	if res > 0 then
		local rosh = RoshanHere()
		local finishing = rosh and rosh:GetHealth() / math.max(1, rosh:GetMaxHealth()) < 0.5
		local n, need = RoshanGroup()
		if not finishing and n < need then
			if DotaTime() - (bot._roshWaitLogT or -math.huge) > 60 and res > 0.4 then
				bot._roshWaitLogT = DotaTime()
				print(string.format('[Rosh] %s wants Roshan, %d of %d needed want it: not yet', botName, n, need))
			end
			return math.min(res, 0.3)
		end
	end
	if res > 0.6 then J.ModeAnnounce(bot, 'say_roshan', 30) end
	return res
end

-- At the pit: hit Roshan once enough of us are there (or he's under half
-- HP, or he's already on one of us); otherwise wait at the entrance. The
-- Aegis for the richest core at the pit, other drops for whoever is closest.
function Think()
	if J.CanNotUseAction(bot) then return end
	local rosh, loc = RoshanHere()
	for _, d in pairs(GetDroppedItemList() or {}) do
		if d and d.item and d.location and GetUnitToLocationDistance(bot, d.location) < 1200 then
			local name = d.item:GetName()
			if name == 'item_aegis' then
				local richest, nw = nil, -1
				for i = 1, 5 do
					local m = GetTeamMember(i)
					if m and m:IsAlive() and J.IsCore(m) and GetUnitToLocationDistance(m, d.location) < 1500 and m:GetNetWorth() > nw then richest, nw = m, m:GetNetWorth() end
				end
				if richest == nil or richest == bot then bot:Action_PickUpItem(d.item) return end
			elseif name == 'item_cheese' or name == 'item_refresher_shard' or name == 'item_roshans_banner' then
				bot:Action_PickUpItem(d.item)
				return
			end
		end
	end
	local present, alive = 0, 0
	for i = 1, 5 do
		local m = GetTeamMember(i)
		if m and m:IsAlive() then
			alive = alive + 1
			if GetUnitToLocationDistance(m, loc) < 1600 then present = present + 1 end
		end
	end
	local need = math.max(1, math.min(3, alive))
	if rosh then
		local tgt = rosh:GetAttackTarget()
		local onUs = tgt and not tgt:IsNull() and tgt:GetTeam() == GetTeam()
		if present >= need or onUs or rosh:GetHealth() / math.max(1, rosh:GetMaxHealth()) < 0.5 then
			bot:Action_AttackUnit(rosh, false)
			return
		end
	end
	-- Wait at the entrance, on our side.
	local toUs = J.GetTeamFountain() - loc
	local wait = loc + toUs / math.max(1, toUs:Length2D()) * 900
	if rosh == nil and present >= need then wait = loc end
	if GetUnitToLocationDistance(bot, wait) > 150 then bot:Action_MoveToLocation(wait) end
end
function GetDesireHelper()
	if bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return BOT_MODE_DESIRE_NONE end
    if Roshan == nil then
        local nCreeps = bot:GetNearbyNeutralCreeps(700)
        for _, creepOrRoshan in pairs(nCreeps)
        do
            if creepOrRoshan:GetUnitName() == "npc_dota_roshan"
            then
                Roshan = creepOrRoshan
            end
        end
    end

	-- 如果在打高地 就别撤退去干别的
	if J.Utils.IsTeamPushingSecondTierOrHighGround(bot) then
		return BOT_MODE_DESIRE_NONE
	end

	if J.GetEnemiesAroundAncient(bot, 3200) > 0 or J.GetHP(GetAncient(bot:GetTeam())) < 0.8 then
		return BOT_MODE_DESIRE_NONE
	end

    local timeOfDay = J.CheckTimeOfDay()

    local nTeamFightLocation = J.GetTeamFightLocation(bot)
    if nTeamFightLocation ~= nil
    then
        if timeOfDay == 'day'
        and GetUnitToLocationDistance(bot, J.Utils.RadiantRoshanLoc) < 1600
        and GetUnitToLocationDistance(bot, nTeamFightLocation) < 2000
        then
            return BOT_ACTION_DESIRE_NONE
        else
            if timeOfDay == 'night'
            and GetUnitToLocationDistance(bot, J.Utils.DireRoshanLoc) < 1600
            and GetUnitToLocationDistance(bot, nTeamFightLocation) < 2000
            then
                return BOT_ACTION_DESIRE_NONE
            end
        end
    end

    local lEnemyHeroesAroundLoc = J.GetLastSeenEnemiesNearLoc(bot:GetLocation(), 1200)
    if #lEnemyHeroesAroundLoc >= 2 then
        return BOT_ACTION_DESIRE_NONE
    end

    -- if Roshan is about to get killed, kill it unless there are other absolute actions.
    if J.Utils.IsValidUnit(Roshan) then
        local roshHP = Roshan:GetHealth() / Roshan:GetMaxHealth()
        if roshHP < 0.5 and #lEnemyHeroesAroundLoc == 0 then
            return RemapValClamped(roshHP, 100, 0, BOT_MODE_DESIRE_MODERATE, BOT_MODE_DESIRE_ABSOLUTE )
        end
    end

    local aliveAlly = J.GetNumOfAliveHeroes(false)
    local aliveEnemy = J.GetNumOfAliveHeroes(true)
    local hasSameOrMoreHero = aliveAlly >= aliveEnemy

    if not hasSameOrMoreHero then
        return BOT_ACTION_DESIRE_NONE
    end

    local nCoreWithNoEmptySlot = 0
    local aliveHeroesList = {}
    for _, h in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES)) do
        if h:IsAlive()
        then
            if J.Utils.CountBackpackEmptySpace(h) <= 0 and J.IsCore(h) then
                nCoreWithNoEmptySlot = nCoreWithNoEmptySlot + 1
            end

            -- do not take rosh if the cores do not have any empty slot, it may get dropped on ground.
            if nCoreWithNoEmptySlot >= 2 then
                return BOT_ACTION_DESIRE_NONE
            end
            table.insert(aliveHeroesList, h)
        end
    end

    shouldKillRoshan = J.IsRoshanAlive()

    if shouldKillRoshan
    and not roshTimeFlag
    then
        sinceRoshAliveTime = DotaTime()
        roshTimeFlag = true
    else
        if not shouldKillRoshan
        then
            sinceRoshAliveTime = 0
            roshTimeFlag = false
        end
    end

    if J.HasEnoughDPSForRoshan(aliveHeroesList)
    then
        initDPSFlag = true
    end

    if J.IsRoshanCloseToChangingSides()
    then
        local botTarget = J.GetProperTarget(bot)
        if J.IsRoshan(botTarget) then
            return RemapValClamped(J.GetHP(botTarget), 1, 0, BOT_ACTION_DESIRE_NONE, BOT_ACTION_DESIRE_VERYHIGH )
        end
        if not J.IsValid(botTarget) or not J.IsRoshan(botTarget) then
            return BOT_ACTION_DESIRE_NONE
        end
    end

    local nEnemyHeroes = J.GetEnemiesNearLoc(bot:GetLocation(), 1300)
    if nEnemyHeroes ~= nil and #nEnemyHeroes > 0
    then
        return BOT_ACTION_DESIRE_NONE
    end

    if shouldKillRoshan
    and initDPSFlag
    then
        local human, humanPing = J.GetHumanPing()
        if human ~= nil and DotaTime() > 5.0 then
            if humanPing ~= nil
            and humanPing.normal_ping
            and GetUnitToLocationDistance(human, J.GetCurrentRoshanLocation()) < 4500
            and J.GetDistance(humanPing.location, J.GetCurrentRoshanLocation()) < 600
            and DotaTime() < humanPing.time + 5.0
            then
                return 0.95
            end
        end

        local mul = RemapValClamped(DotaTime(), sinceRoshAliveTime, sinceRoshAliveTime + (2.5 * 60), 1, 2)
        local nRoshanDesire = (GetRoshanDesire() * mul)

        if hasSameOrMoreHero or (not hasSameOrMoreHero and J.HasEnoughDPSForRoshan(aliveHeroesList)) then
            return Clamp(nRoshanDesire, 0, 0.95)
        end
    end

    return BOT_ACTION_DESIRE_NONE
end
