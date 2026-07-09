local roundStartTime = CurTime()
hook.Add("PreRestartRound", D3bot.BotHooksId.."PreRestartRoundSupervisor", function() roundStartTime, D3bot.NodeZombiesCountAddition = CurTime(), nil end)

function D3bot.GetDesiredBotCount()
	--return desiredZombies, 0, allowedTotal
	return GAMEMODE.DesiredBotCount, 0, game.MaxPlayers()
end

-- NOTE ON THE RACE CONDITION FIX BELOW:
-- Team assignment for newly created bots used to rely entirely on this hook firing
-- synchronously *inside* the player.CreateNextBot() call below, in the same tick, so that
-- the `spawnAsTeam` upvalue would still hold the intended team when the hook ran. Under
-- server load (e.g. several bots pathing/spawning in the same frame), the engine can defer
-- PlayerInitialSpawn to a later tick. By then `spawnAsTeam` has already been reset to nil,
-- the `if`/`elseif` below fall through silently, and the bot never gets a team. An un-teamed
-- bot is invisible to D3bot.MaintainBotRoles' team counting (see botsByTeam below), so it
-- kept spawning replacement bots to "fill" a slot that a real (but un-teamed) bot already
-- occupied -- eventually filling every open server slot.
--
-- Fix: we no longer depend on this hook for the actual team assignment. bot:SetTeam() is
-- now called directly and unconditionally right after player.CreateNextBot() returns (see
-- the bot-adding block further down), which is not subject to any tick-timing assumptions.
-- This hook is kept only to still fire GAMEMODE:PlayerInitialSpawn() for whatever gameplay
-- setup (loadout, HP, etc.) it's responsible for, for both bots and real players.
local spawnAsTeam
hook.Add("PlayerInitialSpawn", D3bot.BotHooksId, function(pl)
	-- Initialize mem when console bots are used
	if D3bot.UseConsoleBots and D3bot.IsEnabledCached and pl:IsBot() then
		pl:D3bot_InitializeOrReset()
	end

	if spawnAsTeam == TEAM_UNDEAD then
		--GAMEMODE.PreviouslyDied[pl:UniqueID()] = CurTime()
		GAMEMODE:PlayerInitialSpawn(pl)
	elseif spawnAsTeam == TEAM_HUMAN then
		--GAMEMODE.PreviouslyDied[pl:UniqueID()] = nil
		GAMEMODE:PlayerInitialSpawn(pl)
	end
end)

function D3bot.MaintainBotRoles()
	if #player.GetHumans() == 0 then return end
	local desiredCountByTeam = {}
	local allowedTotal
	desiredCountByTeam[TEAM_UNDEAD], desiredCountByTeam[TEAM_HUMAN], allowedTotal = D3bot.GetDesiredBotCount()

	local bots = player.GetBots()
	local botsByTeam = {}
	for k, v in ipairs(bots) do
		local team = v:Team()
		botsByTeam[team] = botsByTeam[team] or {}
		table.insert(botsByTeam[team], v)
	end

	local players = D3bot.GetCachedPlayerList()
	local playersByTeam = {}
	for k, v in ipairs(players) do
		local team = v:Team()
		playersByTeam[team] = playersByTeam[team] or {}
		table.insert(playersByTeam[team], v)
	end

	-- Check if any zombie bot is in barricade ghosting mode.
	-- This can happen in some gamemodes, we fix that here.
	-- See https://github.com/Dadido3/D3bot/issues/99 for details.
	for _, bot in ipairs(bots) do
		if bot:GetBarricadeGhosting() and (bot:Team() == TEAM_UNDEAD) and bot:Alive() then
			--bot:Say(string.format("I was a nasty bot that noclips through barricades! (%s)", bot))
			bot:SetBarricadeGhosting(false)
		end
	end

	-- TODO: Fix invisible bots when CLASS.OverrideModel is used (most common with Frigid Revenant and other OverrideModel zombies in 2018 ZS if they have a low opacity OverrideModel)
	
	-- Sort by frags and being boss zombie
	--[[if botsByTeam[TEAM_UNDEAD] then
		table.sort(botsByTeam[TEAM_UNDEAD], function(a, b) return (a:GetZombieClassTable().Boss and 1 or 0) > (b:GetZombieClassTable().Boss and 1 or 0) end)
	end
	for team, botByTeam in pairs(botsByTeam) do
		table.sort(botByTeam, function(a, b) return a:Frags() < b:Frags() end)
	end]]
	
	-- Stop managing survivor bots, after round started. Except on ZE or obj maps, where survivors are managed to be 0
	if GAMEMODE:GetWave() > 0 then
		desiredCountByTeam[TEAM_HUMAN] = nil
	end
	
	-- Manage survivor bot count to 0, if they are disabled
	if not D3bot.SurvivorsEnabled then
		desiredCountByTeam[TEAM_HUMAN] = 0
	end
	
	-- Move (kill) survivors to undead if possible
	if desiredCountByTeam[TEAM_HUMAN] and desiredCountByTeam[TEAM_UNDEAD] then
		if #(playersByTeam[TEAM_HUMAN] or {}) > desiredCountByTeam[TEAM_HUMAN] and #(playersByTeam[TEAM_UNDEAD] or {}) < desiredCountByTeam[TEAM_UNDEAD] and botsByTeam[TEAM_HUMAN] then
			local randomBot = table.remove(botsByTeam[TEAM_HUMAN], 1)
			randomBot:StripWeapons()
			--randomBot:KillSilent()
			randomBot:Kill()
			return
		end
	end

	-- Orphaned bot watchdog.
	-- Catches any bot that ended up with no valid managed team, for any reason -- not just
	-- the specific PlayerInitialSpawn race fixed above. This is a deliberately generic
	-- backstop: if some future change (an engine update, another addon, the UseConsoleBots
	-- path, etc.) produces a bot D3bot doesn't recognize as belonging to a managed team, we
	-- don't want it to silently sit there uncounted and cause the same overflow symptom
	-- again. TEAM_UNDEAD and TEAM_HUMAN are the only two teams D3bot ever assigns bots to
	-- (see spawnAsTeam usage above) -- a bot on any other team is one D3bot doesn't know
	-- what to do with. Kicking rather than fixing is deliberate: a bot in this state already
	-- had something go wrong once, so let MaintainBotRoles cleanly replace it next pass
	-- rather than patch up an entity that might be broken in other ways too.
	for _, bot in ipairs(bots) do
		local botTeam = bot:Team()
		if botTeam ~= TEAM_UNDEAD and botTeam ~= TEAM_HUMAN then
			SendToDiscordDebugLog(string.format("[D3bot] Watchdog: bot '%s' has no valid managed team (Team()=%s), kicking.", bot:Nick(), tostring(botTeam)))
			bot:Kick(D3bot.BotKickReason)
			return
		end
	end

	-- Add bots out of managed teams to maintain desired counts
	if player.GetCount() < allowedTotal then
		for team, desiredCount in pairs(desiredCountByTeam) do
			--if #(playersByTeam[team] or {}) < desiredCount then
			if #(botsByTeam[team] or {}) < desiredCount then
				if D3bot.UseConsoleBots then
					-- NOTE: The "bot" console command path doesn't hand us a reference to the
					-- created bot, so we can't verify/fix its team directly here the way we do
					-- below. This path is still subject to the original hook-timing race in
					-- principle. If you use D3bot.UseConsoleBots, the watchdog further down in
					-- this function (search "orphaned bot watchdog") is what catches and
					-- corrects any bot that slips through here without a team.
					spawnAsTeam = team
					RunConsoleCommand("bot")
					spawnAsTeam = nil
				else
					spawnAsTeam = team
					---@type GPlayer|table
					local bot = player.CreateNextBot(D3bot.GetUsername())
					spawnAsTeam = nil
					if IsValid(bot) then
						-- Normally the PlayerInitialSpawn hook above already fired
						-- synchronously inside player.CreateNextBot(), read `team` from
						-- spawnAsTeam while it was still set, and called both SetTeam()
						-- (indirectly, via GAMEMODE:PlayerInitialSpawn) and
						-- GAMEMODE:PlayerInitialSpawn() itself. bot:Team() == team is true
						-- in that case, and there's nothing left to do here.
						--
						-- If instead the hook got deferred to a later tick (server load --
						-- see the long comment near the top of this file), spawnAsTeam was
						-- already nil by the time it ran, so it did nothing: the bot has no
						-- team and never got GAMEMODE:PlayerInitialSpawn() called on it. We
						-- detect that here and finish the job ourselves. This is what
						-- actually fixes the bot overflow bug -- an un-teamed bot was
						-- invisible to MaintainBotRoles' team counting below, so it kept
						-- spawning replacements forever.
						if bot:Team() ~= team then
							bot:SetTeam(team)
							GAMEMODE:PlayerInitialSpawn(bot)
						end
						bot:D3bot_InitializeOrReset()
					end
				end
				return
			end
		end
	end

	-- Updated to NOT count player zombies towards the bot total
	-- Remove bots out of managed teams to maintain desired counts
	for team, desiredCount in pairs(desiredCountByTeam) do
		if #(botsByTeam[team] or {}) > desiredCount and botsByTeam[team] then
			local index
			if (team == TEAM_ZOMBIE) then
				for i=1, #botsByTeam[team] do
					if (not botsByTeam[team][i]:IsBossOrDemiboss()) then
						index = i
						break
					end
				end
			else
				index = 1
			end

			local randomBot = table.remove(botsByTeam[team], index)
			randomBot:StripWeapons()
			return randomBot and randomBot:Kick(D3bot.BotKickReason)
		end
	end

	-- Remove bots out of non managed teams if the server is getting too full
	--[[if player.GetCount() > allowedTotal then
		for team, desiredCount in pairs(desiredCountByTeam) do
			if not desiredCountByTeam[team] and botsByTeam[team] then
				local randomBot = table.remove(botsByTeam[team], 1)
				randomBot:StripWeapons()
				return randomBot and randomBot:Kick(D3bot.BotKickReason)
			end
		end
	end]]
end

local NextNodeDamage = CurTime()
local NextMaintainBotRoles = CurTime()
function D3bot.SupervisorThinkFunction()
	if NextMaintainBotRoles < CurTime() then
		NextMaintainBotRoles = CurTime() + (D3bot.BotUpdateDelay or 1)
		D3bot.MaintainBotRoles()
	end

	if (NextNodeDamage or 0) < CurTime() then
		NextNodeDamage = CurTime() + (D3bot.NodeDamageInterval or 2)
		D3bot.DoNodeTrigger()
	end
end

function D3bot.DoNodeTrigger()
	local players = D3bot.RemoveObsDeadTgts(D3bot.GetCachedPlayerList())
	players = D3bot.From(players):Where(function(k, v) return v:Team() ~= TEAM_UNDEAD end).R
	local ents = table.Add(players, D3bot.GetEntsOfClss(D3bot.NodeDamageEnts))
	for i, ent in pairs(ents) do
		local nodeOrNil = D3bot.MapNavMesh:GetNearestNodeOrNil(ent:GetPos()) -- TODO: Don't call GetNearestNodeOrNil that often
		if nodeOrNil then
			if not D3bot.DisableNodeDamage and type(nodeOrNil.Params.DMGPerSecond) == "number" and nodeOrNil.Params.DMGPerSecond > 0 then
				ent:TakeDamage(nodeOrNil.Params.DMGPerSecond * (D3bot.NodeDamageInterval or 2), game.GetWorld(), game.GetWorld())
			end
			if ent:IsPlayer() and not ent.D3bot_Mem and nodeOrNil.Params.BotMod then
				D3bot.NodeZombiesCountAddition = nodeOrNil.Params.BotMod
			end
		end
	end
end

-- TODO: Detect situations and coordinate bots accordingly (Attacking cades, hunt down runners, spawncamping prevention)
-- TODO: If needed force one bot to flesh creeper and let him build a nest at a good place
