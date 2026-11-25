local Utils = require( GetScriptDirectory()..'/FunLib/utils')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')
local LanePlay = require(GetScriptDirectory()..'/FunLib/lane_play')
local SafeCall = require(GetScriptDirectory()..'/FunLib/safe_call')
local Objectives = require(GetScriptDirectory()..'/FunLib/objectives')

local Version      = require(GetScriptDirectory()..'/FunLib/version')
local Localization = require(GetScriptDirectory()..'/FunLib/localization')


local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

local local_mode_laning_generic = nil
local nAllyCreeps = nil
local nEnemyCreeps = nil
local nFurthestEnemyAttackRange = 0
local nInRangeEnemy = nil
local botAssignedLane = nil
local botAttackRange = bot:GetAttackRange()
local attackDamage = bot:GetAttackDamage()
local nH, enemyBots = J.Utils.NumHumanBotPlayersInTeam(GetOpposingTeam())
local teamHumans, teamBots = J.Utils.NumHumanBotPlayersInTeam(GetTeam())

-- Announcer state
local hasPickedOneAnnouncer      = false
local lastAnnouncePrintedTime    = 0
local numberAnnouncePrinted      = 1
local announcementGapSeconds     = 6
local isChangePosMessageDone     = false

if Utils.BuggyHeroesDueToValveTooLazy[botName] then local_mode_laning_generic = dofile( GetScriptDirectory().."/FunLib/override_generic/mode_laning_generic" ) end

function GetDesire()
	PickOneAnnouncer()
	AnnounceMessages()

	-- Deaths in the laning stage, for "this lane is lost" below.
	if not bot:IsAlive() then
		if not bot._laneDeadNow then
			bot._laneDeadNow = true
			bot._laneDeaths = bot._laneDeaths or {}
			table.insert(bot._laneDeaths, DotaTime())
		end
	else
		bot._laneDeadNow = nil
	end
	if bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return BOT_MODE_DESIRE_NONE end
	-- A support that died twice in 4 minutes in a lane we lose: not back into
	-- it for now (warding, pulls, roaming take over). Lion respawned and died
	-- to Viper and Techies in the bottom lane three times in 3 minutes.
	if J.GetPosition(bot) >= 4 and bot._laneDeaths then
		local recent = 0
		for _, dt in ipairs(bot._laneDeaths) do if DotaTime() - dt < 240 then recent = recent + 1 end end
		-- Not while our core in that lane is being hit by their heroes: Crystal
		-- Maiden went for a lotus and a ward while Pudge and Abaddon killed
		-- her Gyrocopter (9105594922, 4:30).
		local coreHit = false
		for i = 1, 5 do
			local m = GetTeamMember(i)
			if m and m ~= bot and m:IsAlive() and J.GetPosition(m) <= 3 and m:GetAssignedLane() == bot:GetAssignedLane()
			and GetUnitToUnitDistance(m, bot) < 2500 and m:WasRecentlyDamagedByAnyHero(2.0) then coreHit = true end
		end
		if recent >= 2 and not coreHit then
			local front = GetLaneFrontLocation(GetTeam(), bot:GetAssignedLane(), 0)
			local ok, ratio = pcall(Objectives.FightAt, front, bot)
			if ok and ratio and ratio < 0.8 then
				if DotaTime() - (bot._laneLostLogT or -math.huge) > 60 then
					bot._laneLostLogT = DotaTime()
					print(string.format('[Lane] %s: died %d times in 4 min, lane lost (x%.2f): stays out of it', botName, recent, ratio))
				end
				return 0.1
			end
		end
	end
	-- A core that died twice in 4 minutes in a lane we lose there: the other
	-- side lane when it's quiet and we hold it, else the jungle for 2 minutes
	-- (Gyrocopter died 6 times in the bottom lane by 8:37 to Omniknight and
	-- Skywrath and walked back each time, bot vs bot 9105560137).
	if J.GetPosition(bot) <= 3 and J.GetPosition(bot) ~= 2 and bot._laneDeaths and DotaTime() < 10 * 60 then
		local t = DotaTime()
		local recent = 0
		for _, dt in ipairs(bot._laneDeaths) do if t - dt < 240 then recent = recent + 1 end end
		local swapOn = bot._laneSwap and t < bot._laneSwap.untilT
		local jungleOn = (bot._lostLaneUntil or -math.huge) > t
		if recent >= 2 and not swapOn and not jungleOn and t - (bot._laneLostDecideT or -math.huge) > 60 then
			local own = bot:GetAssignedLane()
			local front = GetLaneFrontLocation(GetTeam(), own, 0)
			local ok, ratio = pcall(Objectives.FightAt, front, bot)
			if ok and ratio and ratio < 0.8 then
				bot._laneLostDecideT = t
				local other = (own == LANE_TOP) and LANE_BOT or (own == LANE_BOT) and LANE_TOP or nil
				local choice
				if other then
					local of = GetLaneFrontLocation(GetTeam(), other, 0)
					local seen = 0
					for _, pid in pairs(GetTeamPlayers(GetOpposingTeam())) do
						if IsHeroAlive(pid) then
							local info = GetHeroLastSeenInfo(pid)
							local d = info and info[1]
							if d and d.time_since_seen < 30 and (d.location - of):Length2D() < 2000 then seen = seen + 1 end
						end
					end
					local ok2, r2 = pcall(Objectives.FightAt, of, bot)
					if seen <= 1 and ok2 and r2 and r2 >= 1.0 then choice = other end
				end
				if choice then
					bot._laneSwap = { lane = choice, untilT = t + 180 }
					print(string.format('[Lane] %s: died %d times in 4 min, lane %d lost (x%.2f): moves to lane %d', botName, recent, own, ratio, choice))
				else
					bot._lostLaneUntil = t + 120
					print(string.format('[Lane] %s: died %d times in 4 min, lane %d lost (x%.2f): farms the jungle', botName, recent, own, ratio))
				end
			end
		end
		if (bot._lostLaneUntil or -math.huge) > t then return 0.1 end
	end
	local botLV = bot:GetLevel()
	local currentTime = DotaTime()

	botAttackRange = bot:GetAttackRange()
	nAllyCreeps = bot:GetNearbyLaneCreeps(1200, false)
	nEnemyCreeps = bot:GetNearbyLaneCreeps(800, true)
	nInRangeEnemy = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
	nFurthestEnemyAttackRange = GetFurthestEnemyAttackRange(nInRangeEnemy)
	if local_mode_laning_generic then
		botAssignedLane = local_mode_laning_generic.GetBotTargetLane()
	else
		botAssignedLane = bot:GetAssignedLane()
	end
	attackDamage = bot:GetAttackDamage()
	if bot:GetItemSlotType(bot:FindItemSlot("item_quelling_blade")) == ITEM_SLOT_TYPE_MAIN then
		if bot:GetAttackRange() > 310 or bot:GetUnitName() == "npc_dota_hero_templar_assassin" then
			attackDamage = attackDamage + 4
		else
			attackDamage = attackDamage + 8
		end
	end

	if GetGameMode() == 23 then currentTime = currentTime * 1.65 end
	if currentTime < 0 then return BOT_ACTION_DESIRE_NONE end

	-- Harass windows: spells on the lane enemies (supports trade freely,
	-- cores between last hits).
	SafeCall('LanePlay.Harass', LanePlay.Harass, bot)

	-- if DotaTime() > 20 and DotaTime() - skipLaningState.lastCheckTime < skipLaningState.checkGap then
	-- 	if skipLaningState.count > 6 then
	-- 		print('[WARN] Bot ' ..botName.. ' switching modes too often, now stop it for laning to avoid conflicts.')
	-- 		return 0
	-- 	end
	-- else
	-- 	skipLaningState.lastCheckTime = DotaTime()
	-- 	skipLaningState.count = 0
	-- end

	if J.GetEnemiesAroundAncient(bot, 3200) > 0 then
		return BOT_MODE_DESIRE_NONE
	end

	-- if J.GetDistanceFromAncient( bot, true ) < 6900 then
	-- 	return BOT_MODE_DESIRE_NONE
	-- end

	if bot:WasRecentlyDamagedByAnyHero(5)
	and #J.Utils.GetLastSeenEnemyIdsNearLocation(bot:GetLocation(), 800) > 0 then
		local nLaneFrontLocation = GetLaneFrontLocation(GetTeam(), bot:GetAssignedLane(), 0)
		local nDistFromLane = GetUnitToLocationDistance(bot, nLaneFrontLocation)
		if not J.WeAreStronger(bot, 1200) or (nDistFromLane > 700 and J.GetHP(bot) < 0.7) then
			return BOT_MODE_DESIRE_NONE
		end
	end

	-- 如果在打高地 就别撤退去干别的
	if J.Utils.IsTeamPushingSecondTierOrHighGround(bot) then
		return BOT_MODE_DESIRE_NONE
	end
	-- if J.ShouldGoFarmDuringLaning(bot) then
	-- 	return 0.2
	-- end

	-- A core by an empty lane after 8:00 (no enemy creeps within 1500, no
	-- enemy hero within 1600): the laning mode has nothing to do there, let
	-- farming, pushing and the rest take over instead of standing by it.
	if J.GetPosition(bot) <= 3 and currentTime > 8 * 60 and #bot:GetNearbyLaneCreeps(1500, true) == 0 and #nInRangeEnemy == 0 then
		return 0.1
	end

	if local_mode_laning_generic or (J.GetPosition(bot) == 1 and J.IsPosxHuman(5)) then
		-- last hit
		if J.IsInLaningPhase() then
			local hitCreep, _ = GetBestLastHitCreep(nEnemyCreeps)
			if J.IsValid(hitCreep) then
				if J.GetPosition(bot) <= 2 or not J.IsThereNonSelfCoreNearby(700) -- this is for e.g lone druid bear as pos1-2 with core LD nearby to do last hit.
				then
					return 0.9
				end
			end
		end
	end
	if local_mode_laning_generic and local_mode_laning_generic.GetDesire ~= nil then return local_mode_laning_generic.GetDesire() end

	if GetGameMode() == GAMEMODE_1V1MID or GetGameMode() == GAMEMODE_MO then
		return 1
	end

	if currentTime <= 10 then return 0.268 end
	if currentTime <= 9 * 60 and botLV <= 7 then return 0.446 end
	if currentTime <= 12 * 60 and botLV <= 11 then return 0.369 end
	if botLV <= 14 and J.GetCoresAverageNetworth() < 7000 then return 0.2 end

	J.Utils.GameStates.passiveLaningTime = true
	return 0.01
end

function GetFurthestEnemyAttackRange(enemyList)
	local attackRange = 0
	for _, enemy in pairs(enemyList) do
		if J.IsValidHero(enemy) and not J.IsSuspiciousIllusion(enemy) then
			local enemyAttackRange = enemy:GetAttackRange()
			if enemyAttackRange > attackRange then
				attackRange = enemyAttackRange
			end
		end
	end

	return attackRange
end

function GetBestLastHitCreep(hCreepList)
	local dmgDelta = attackDamage * 0.7

	local moveToCreep = nil
	for _, creep in pairs(hCreepList) do
		if J.IsValid(creep) and J.CanBeAttacked(creep) then
			local nDelay = J.GetAttackProDelayTime(bot, creep)
			if J.WillKillTarget(creep, attackDamage, DAMAGE_TYPE_PHYSICAL, nDelay) then
				return creep, false
			end
			if J.WillKillTarget(creep, attackDamage + dmgDelta, DAMAGE_TYPE_PHYSICAL, nDelay) then
				moveToCreep = creep
			end
		end
	end
	if moveToCreep then
		return moveToCreep, true
	end

	return nil
end

function GetBestDenyCreep(hCreepList)
	for _, creep in pairs(hCreepList)
	do
		if J.IsValid(creep)
		and J.GetHP(creep) < 0.49
		and J.CanBeAttacked(creep)
		and creep:GetHealth() <= attackDamage
		then
			return creep
		end
	end

	return nil
end

-- Heroes on the replacement laning logic (Hoodwink, Elder Titan, Dark
-- Willow, IO...) get our support logic too (harass, deny, pull): it doesn't
-- use the engine's buggy part; the lane comes from the replacement.
if local_mode_laning_generic and local_mode_laning_generic.GetBotTargetLane then
	bot._laneOverrideFn = local_mode_laning_generic.GetBotTargetLane
end
if LanePlay.UseSupportThink(bot) then
	-- Supports: harass, deny, leave last hits to the core, pull.
	function Think()
		SafeCall('LanePlay.SupportThink', LanePlay.SupportThink, bot)
	end
elseif LanePlay.UseCoreThink(bot) then
	-- Cores: last hits and denies by predicted creep HP, next to the wave.
	function Think()
		SafeCall('LanePlay.CoreThink', LanePlay.CoreThink, bot)
	end
elseif local_mode_laning_generic or (J.GetPosition(bot) == 1 and J.IsPosxHuman(5)) then
	function Think()
		local hitCreep, moveToCreep = GetBestLastHitCreep(nEnemyCreeps)
		if J.IsValid(hitCreep) then
			if J.GetPosition(bot) <= 2 or not J.IsThereNonSelfCoreNearby(700)
			then
				if GetUnitToUnitDistance(bot, hitCreep) > botAttackRange
				or (moveToCreep and GetUnitToUnitDistance(bot, hitCreep) > botAttackRange * 0.8) then
					bot:Action_MoveToUnit(hitCreep)
					return
				else
					bot:SetTarget(hitCreep)
					bot:Action_AttackUnit(hitCreep, true)
					return
				end
			end
		end

		local denyCreep = GetBestDenyCreep(nAllyCreeps)
		if J.IsValid(denyCreep) then
			bot:SetTarget(denyCreep)
			bot:Action_AttackUnit(denyCreep, true)
			return
		end

		if local_mode_laning_generic then
			local_mode_laning_generic.Think()
		end

		local fLaneFrontAmount = GetLaneFrontAmount(GetTeam(), botAssignedLane, false)
		local fLaneFrontAmount_enemy = GetLaneFrontAmount(GetOpposingTeam(), botAssignedLane, false)

		local nLongestAttackRange = math.max(botAttackRange, 250, nFurthestEnemyAttackRange)

		local target_loc = GetLaneFrontLocation(GetTeam(), botAssignedLane, -nLongestAttackRange)
		if fLaneFrontAmount_enemy < fLaneFrontAmount then
			target_loc = GetLaneFrontLocation(GetOpposingTeam(), botAssignedLane, -nLongestAttackRange)
		end

		bot:Action_MoveToLocation(target_loc + RandomVector(50))
	end
end


function PickOneAnnouncer()
	if not hasPickedOneAnnouncer then
		for i, _ in pairs(GetTeamPlayers(GetTeam())) do
			local member = GetTeamMember(i)
			if member ~= nil and member.isAnnouncer then return end
		end
		bot.isAnnouncer = true
		hasPickedOneAnnouncer = true
	end
end

function AnnounceMessages()
	-- Only pre-game chatter
	if DotaTime() > 60 then return end

	local welcomeMessages = Localization.Get('welcome_msgs')
	local inTurbo         = J.IsModeTurbo()

	-- Staggered lines during negative DotaTime pre-game
	if ((inTurbo and DotaTime() > -50 + GetTeam() * 2) or (not inTurbo and DotaTime() > -75 + GetTeam() * 2))
	   and numberAnnouncePrinted < #welcomeMessages + 1
	   and bot.isAnnouncer
	   and DotaTime() < 0
	then
		if GameTime() - lastAnnouncePrintedTime >= announcementGapSeconds then
			local message      = welcomeMessages[numberAnnouncePrinted]
			local isFirstLine  = (numberAnnouncePrinted == 1)
			if message then
				-- Match original behavior: first line (or if no enemy bots) can be global
				bot:ActionImmediate_Chat(isFirstLine and (message .. Version.number) or message, enemyBots == 0 or isFirstLine)
			end
			numberAnnouncePrinted   = numberAnnouncePrinted + 1
			lastAnnouncePrintedTime = GameTime()
		end
	end

	-- Announce role during pre-game
	if GetGameMode() ~= GAMEMODE_1V1MID
	   and GetGameState() == GAME_STATE_PRE_GAME
	   and (bot.announcedRole == nil or bot.announcedRole ~= J.GetPosition(bot))
	then
		bot.announcedRole = J.GetPosition(bot)
		bot:ActionImmediate_Chat(Localization.Get('say_play_pos') .. J.GetPosition(bot), false)
	end

	-- Close position selection after horn if humans and bots mixed
	if GetGameMode() ~= GAMEMODE_1V1MID and not isChangePosMessageDone then
		if DotaTime() >= 0 and teamHumans > 0 and teamBots > 0 then
			bot:ActionImmediate_Chat(Localization.Get('pos_select_closed'), true)
			isChangePosMessageDone = true
		end
	end
end
