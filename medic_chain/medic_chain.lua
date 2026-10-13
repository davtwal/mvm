-- medic_chain.lua
-- author: achoo
-- last updated 2026 oct 12
-- thanks to Landogg, Zilloy, fellen, and Sntr
-- special thanks to royal, without whom this would not have been possible.
-- much of the code is originally theirs.

-- TODO: actually keep track of robot templates. I don't know how to do this unfortunately

-- medic chain bots have the following quirks:
-- -they are assumed to have a primary weapon
-- -they are assumed to be restricted to their secondary weapon on spawn
-- -medics in the chain will ignore enemies while they are healing
-- -if the distance between a medic and their heal target becomes too large, they
--   will stop ignoring enemies and switch to their primary. they will still attempt
--   to move towards their heal target so long as their heal target is still alive
-- -if a medic's heal target dies, they will attempt to heal the next target in the chain.
--   if they are now the end of the chain, they switch to primary and start attacking
-- -if they have a bomb, the bomb will be teleported to the front of the chain

--------------------------------
-- constants
--------------------------------

-- defined here if not defined elsewhere
if BOT_ATTRIBUTES == nil then
    BOT_ATTRIBUTES = {
        ["IGNORE_ENEMIES"] = 1024
    }
end

if BOT_WEAPON_RESTRICTION == nil then
    BOT_WEAPON_RESTRICTION = {
        ["SECONDARY_ONLY"] = 4
    }
end

-- medics attempt to stay this far away from their heal target
MEDIC_CHAIN_TARGET_DISTANCE = 150

-- the chain is considered broken at this distance
MEDIC_CHAIN_BROKEN_DISTANCE = 500

-- the chain will restore at this distance
MEDIC_CHAIN_RECONNECT_DISTANCE = 300

-- note: default medigun broken distance is 540, and default reconnect is 450

--------------------------------
-- chain creation waiting room
--------------------------------

-- create table to collect bots in a medic chain as they spawn
AddGlobalCallback("OnWaveInit", function(wave)
    medicChainsWaiting = {}
end)

-- collect bots to fill out said table
-- bots in a medic chain must have tags. there is a tag format for the leader
--   and for each chain member.
-- leader tag: Tag medchain_X_leader_N
-- member tag: Tag medchain_X_member_I
-- where:
--  - X is the chain number. start at 1.
--  - N is the number of medics in the chain.
--  - I is the location of the medic in the chain. start at 1.
-- note that I is optional if you don't care about the order of the medics, but
--   don't mix and match please. either use it for all medics or don't use it.
AddGlobalCallback("OnWaveSpawnBot", function(bot, wave, tags)
    -- go through bot tags
    for _, tag in pairs(tags) do
        local split = {}
        for k, _ in string.gmatch(tag, "([^_]+)") do
            table.insert(split, k)
        end

        -- check for medchain
        if split[1]:lower() == "medchain" then
            local chainNum = math.tointeger(split[2])
            local leader = (split[3]:lower() == "leader")
            local num = split[4] ~= nil and math.tointeger(split[4]) or -1

            -- if this is first bot in chain, initialize the table
            if medicChainsWaiting[chainNum] == nil then
                medicChainsWaiting[chainNum] = {
                    Leader = nil,
                    WaitForCount = nil,
                    Members = {}
                }
            end

            if leader then
                medicChainsWaiting[chainNum].Leader = bot
                medicChainsWaiting[chainNum].WaitForCount = num
            else
                -- no number? then just append
                if num == -1 then
                    table.insert(medicChainsWaiting[chainNum].Members, bot)
                else
                    medicChainsWaiting[chainNum].Members[num] = bot
                end
            end

            if medicChainsWaiting[chainNum].Leader ~= nil and #medicChainsWaiting[chainNum].Members == medicChainsWaiting[chainNum].WaitForCount then
                -- util.PrintToConsoleAll("all medchain bots spawned")
                table.insert(medicChainsWaiting[chainNum].Members, 1, medicChainsWaiting[chainNum].Leader)
                BuildMedicChain(medicChainsWaiting[chainNum].Members)
                -- remove medic chain from waiting list
                -- buildmedicchain & the timers should still be fine
                medicChainsWaiting[chainNum] = nil
            end
        end
    end
end)

--------------------------------
-- bomb failsafes
--------------------------------

-- function below directly from royal
-- (royal): as all bots in a squad spawn in at the exact same tick, sometimes a squad member may be assigned the bomb instead of the squad leader
-- this fixes that by forcefully sending the bomb back to the squad leader
function MedicChainBombFailsafe(squadBots, squadLeader, attempts)
	if attempts >= #squadBots * 4 then
		return
	end

	for _, bomb in pairs(ents.FindAllByClass("item_teamflag")) do
		local bombOwner = bomb.m_hPrevOwner

		if bombOwner and bomb.m_nFlagStatus == 1 then
			for _, squadMember in pairs(squadBots) do
				if squadMember == bombOwner and squadMember ~= squadLeader then
					util.PrintToChatAll("[MEDIC-CHAIN]: detected bomb on a chain member, moving to chain leader")

					-- (royal): it's not guaranteed that the leader will successfully pick up the bomb when it's teleported to them, sometimes medics pick it up
					bomb:ForceDrop()
					bomb:SetAbsOrigin(squadLeader:GetAbsOrigin() + Vector(0, 0, 10))

					local timerId
					timerId = timer.Simple(0.05, function()

						attempts = attempts + 1
						MedicChainBombFailsafe(squadBots, squadLeader, attempts)
					end)
					break
				end
			end
		end
	end
end

-- function below directly from royal
local function hasBomb(squadMember)
	for _, bomb in pairs(ents.FindAllByClass("item_teamflag")) do
		local bombOwner = bomb.m_hPrevOwner

		if bombOwner and squadMember == bombOwner then
			return true
		end
	end
	return false
end

--------------------------------
-- main functionality
--------------------------------

-- medics in chain ignore enemies and are restricted to their medigun
local function addMedicChainRestrictions(chainMember)
    chainMember:RunScriptCode(
		("activator.AddBotAttribute(%s)"):format(BOT_ATTRIBUTES.IGNORE_ENEMIES),
		chainMember,
		chainMember
	)

    chainMember:RunScriptCode(
		("activator.AddWeaponRestriction(%s)"):format(BOT_WEAPON_RESTRICTION.SECONDARY_ONLY),
		chainMember,
		chainMember
	)
end

-- removes the restrictions and stops the interrupt actions, but does not stop the timer.
-- called when the chain breaks
local function removeMedicChainRestrictions(chainMember)
    chainMember:RunScriptCode(
		("activator.RemoveBotAttribute(%s)"):format(BOT_ATTRIBUTES.IGNORE_ENEMIES),
		chainMember,
		chainMember
	)

    chainMember:RunScriptCode("activator.ClearAllWeaponRestrictions()", chainMember, chainMember)
	chainMember:BotCommand("stop interrupt action")
	chainMember:BotCommand("clear_interrupt_action_queue")
end

-- fully stops medic chain behavior for a medic.
-- only called when a medic is becoming the leader.
local function cancelChainMedicBehavior(chainMember, timerId)
    timer.Stop(timerId)
    removeMedicChainRestrictions(chainMember)
end

-- defines the behavior for one medic in the chain
function MedicChainMedicBehavior(chainBots, infoTargets, memberIndex)
    -- member index should be > 1
    local chainMember = chainBots[memberIndex]
    local chainMemberInfoTarget = infoTargets[memberIndex]
    local chainMemberSpawnBotId = chainMember.SpawnBotId

    local healTarget = chainBots[memberIndex - 1]
    local healTargetInfoTarget = infoTargets[memberIndex - 1]
    local healTargetSpawnBotId = healTarget.SpawnBotId

    local lastHealTargetHP = healTarget.m_iHealth
    local lastMemberHP = chainMember.m_iHealth

    addMedicChainRestrictions(chainMember)

    -- set up interrupts
    -- this interrupt will be reformatted if the heal target dies
    local interruptActionStr = "interrupt_action -posent %s -lookposent %s -killlook -waituntildone -alwayslook -distance %d"
    local chainBrokenIntActStr = "interrupt_action -posent %s -waituntildone -distance %d"
    local interruptAction = nil
    local chainBrokenIntAct = nil

    local function formatInterruptActions()
        interruptAction = interruptActionStr:format(
		    healTargetInfoTarget:GetName(),
		    healTargetInfoTarget:GetName(),
            MEDIC_CHAIN_TARGET_DISTANCE
	    )

        chainBrokenIntAct = chainBrokenIntActStr:format(
            healTargetInfoTarget:GetName(),
            MEDIC_CHAIN_TARGET_DISTANCE
        )
    end

    formatInterruptActions()

	local interruptActive = false
    local chainBroken = false

	local function startInterrupt()
		if interruptActive then
			return
		end

		interruptActive = true
        if chainBroken then
            chainMember:BotCommand(chainBrokenIntAct)
        else
            chainMember:BotCommand(interruptAction)
        end
	end

	local function stopInterrupt()
		if not interruptActive then
			return
		end

		interruptActive = false
		chainMember:BotCommand("stop interrupt action")
		chainMember:BotCommand("clear_interrupt_action_queue")
	end

    local timerId
    timerId = timer.Create(0.15, function()
        -- check to see if member is alive
        if not chainMember:IsAlive() or chainMember.SpawnBotId ~= memberSpawnBotId then
            util.PrintToConsoleAll(string.format("--%s self dead", chainMember:GetHandleIndex()))
            
            if IsValid(memberInfoTarget) then
                memberInfoTarget:Remove()
            end
            cancelChainMedicBehavior(chainMember, timerId)
            return
        end
        
        -- check to see if heal target is alive
        if not healTarget:IsAlive() or healTargetSpawnBotId ~= healTarget.SpawnBotId then
            -- stop trying to follow a dead guy
            stopInterrupt()

            if IsValid(healTargetInfoTarget) then
                healTargetInfoTarget:Remove()
            end

            -- find self in chain member list, as the index likely changed
            local foundSelf = false
            for i, chainBot in pairs(chainBots) do
                if chainBot == chainMember then
                    memberIndex = i
                    foundSelf = true
                    break
                end
            end

            if not foundSelf then
                util.PrintToChatAll("[MEDIC-CHAIN][ERROR] Unable to find self when re-healing")
                return
            end

            -- run down list of chain members from memberIndex-1 .. 1 for valid bots to heal
            -- if memberIndex == 1, then this will do nothing anyway
            local foundNewHealTarget = false
            for i = memberIndex - 1, 1, -1 do
                local potentialHealTarget = chainBots[i]
                if potentialHealTarget:IsAlive() then
                    healTarget = potentialHealTarget
                    healTargetInfoTarget = infoTargets[i]
                    healTargetSpawnBotId = healTarget.SpawnBotId
                    
                    formatInterruptActions()
                    
                    stopInterrupt()
                    break
                end
            end

            if not foundNewHealTarget then
                -- look at me. i am the leader now
                cancelChainMedicBehavior(chainMember, timerId)
                return
            end
        end

        -- we dont want bomb!!! go away!
		if hasBomb(squadMember) then
            MedicChainBombFailsafe(chainBots, chainLeader, 0)
		end

        -- check distance to heal target and chain breakage
        local healTargetDistance = chainMember:GetAbsOrigin():Distance(healTarget:GetAbsOrigin())
        
        if not chainBroken and healTargetDistance > MEDIC_CHAIN_BROKEN_DISTANCE then
            chainMember:WeaponSwitchSlot(LOADOUT_POSITION_PRIMARY)
            -- medics will automatically switch back to their medigun unless this is added
            chainMember:RunScriptCode("activator.AddCustomAttribute(\"disable weapon switch\", 1, 0)", chainMember, chainMember)
            chainBroken = true
            removeMedicChainRestrictions(chainMember)
            stopInterrupt()
        end
        
        if chainBroken and healTargetDistance <= MEDIC_CHAIN_RECONNECT_DISTANCE then
            -- reallow weapon switching to go back to medigun
            chainMember:RunScriptCode("activator.RemoveCustomAttribute(\"disable weapon switch\")", chainMember, chainMember)
            chainMember:WeaponSwitchSlot(LOADOUT_POSITION_SECONDARY)
            chainBroken = false
            addMedicChainRestrictions(chainMember)
            stopInterrupt()
        end

        -- interrupt_action time
        startInterrupt()
        
        -- set medigun to heal heal target
        local medigun = chainMember:GetPlayerItemBySlot(LOADOUT_POSITION_SECONDARY)

        if medigun.m_hHealingTarget ~= healTarget then
            -- disconnect if healing wrong guy
			chainMember:RunScriptCode("activator.PressFireButton(0.05)", chainMember, chainMember)
		else
			chainMember:RunScriptCode("activator.PressFireButton(9999999999)", chainMember, chainMember)
		end

		local medicThreshold = chainMember:GetAttributeValue("bot medic uber health threshold") or 75

		if chainMember.m_iHealth <= medicThreshold or (healTarget.m_iHealth / healTarget.m_iMaxHealth) <= 0.5 then
			if chainMember.m_iHealth < lastHealTargetHP or chainMember.m_iHealth < lastMemberHP then
				-- uber
				chainMember:RunScriptCode("activator.PressAltFireButton(0.1)", chainMember, chainMember)
			end
		end

		lastHealTargetHP = healTarget.m_iHealth
		lastMemberHP = chainMember.m_iHealth
    end, 0)
end

-- actually create the chain.
function BuildMedicChain(chainBots)
    local chainLeader = chainBots[1]
    local leaderSpawnBotId = chainLeader.SpawnBotId

    -- create info targets for each member
    local function createInfoTarget(bot)
        local infoTargetName = tostring(bot:GetHandleIndex()) .. "chainLinkTarget"
        local infoTarget = ents.FindByName(infoTargetName)
        if not infoTarget or not IsValid(infoTarget) then
            infoTarget = Entity("info_target")
		    infoTarget:SetAbsOrigin(bot:GetAbsOrigin())
		    infoTarget:SetFakeParent(bot)
		    infoTarget:SetName(infoTargetName)
        end
        return infoTarget
    end

    local infoTargets = {}

    for i, chainBot in pairs(chainBots) do
        table.insert(infoTargets, i, createInfoTarget(chainBot))
    end

    -- initiate behavior for each member of the chain
    for i, chainMember in pairs(chainBots) do
        if chainMember ~= chainLeader then
            MedicChainMedicBehavior(chainBots, infoTargets, i)
        end

        -- death callbacks to remove member from chain on death
        local callbacks = {}
        local function clearCallbacks()
			for _, callbackId in pairs(callbacks) do
				chainMember:RemoveCallback(callbackId)
			end
		end

        callbacks.spawned = chainMember:AddCallback(ON_SPAWN, function()
			clearCallbacks()
		end)

		callbacks.died = chainMember:AddCallback(ON_DEATH, function()
			clearCallbacks()
            for j, squadBot in pairs(chainBots) do
				if squadBot == chainMember then
					table.remove(chainBots, j)
                    table.remove(infoTargets, j)
					--table.remove(squadBotTemplates, j)
					break
				end
			end
		end)
    end

    -- check bomb location. ensure bomb is on the chain leader.
    timer.Simple(1, function()
        if chainLeader:IsAlive() and chainLeader.SpawnBotId == leaderSpawnBotId then
			MedicChainBombFailsafe(chainBots, chainLeader, 0)
		end
    end)
end