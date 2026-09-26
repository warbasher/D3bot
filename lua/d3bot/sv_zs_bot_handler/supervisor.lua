local roundStartTime = CurTime()
hook.Add("PreRestartRound", D3bot.BotHooksId.."PreRestartRoundSupervisor", function() roundStartTime, D3bot.NodeZombiesCountAddition = CurTime(), nil end)

function D3bot.GetDesiredBotCount()
	--return desiredZombies, 0, allowedTotal
	return GAMEMODE.DesiredBotCount, 0, game.MaxPlayers()
end

local spawnAsTeam
hook.Add("PlayerInitialSpawn", D3bot.BotHooksId, function(pl)
	-- Initialize mem when console bots are used
	if D3bot.UseConsoleBots and D3bot.IsEnabledCached and pl:IsBot() then
		pl:D3bot_InitializeOrReset()
	end

	if spawnAsTeam == TEAM_UNDEAD then
		GAMEMODE:PlayerInitialSpawn(pl)
	elseif spawnAsTeam == TEAM_HUMAN then
		GAMEMODE:PlayerInitialSpawn(pl)
	end
end)

function D3bot.MaintainBotRoles()
	if GAMEMODE.DebugMode then return end
	if (#player.GetHumans() == 0) then return end

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
			bot:SetBarricadeGhosting(false)
		end
	end

	-- TODO: Fix invisible bots when CLASS.OverrideModel is used (most common with Frigid Revenant and other OverrideModel zombies in 2018 ZS if they have a low opacity OverrideModel)

	-- Stop managing survivor bots, after round started. Except on ZE or obj maps, where survivors are managed to be 0
	if (GAMEMODE:GetWave() > 0) then
		desiredCountByTeam[TEAM_HUMAN] = nil
	end

	-- Manage survivor bot count to 0, if they are disabled
	if (not D3bot.SurvivorsEnabled) then
		desiredCountByTeam[TEAM_HUMAN] = 0
	end

	-- Move (kill) survivors to undead if possible
	if desiredCountByTeam[TEAM_HUMAN] and desiredCountByTeam[TEAM_UNDEAD] then
		if ((#(playersByTeam[TEAM_HUMAN] or {}) > desiredCountByTeam[TEAM_HUMAN])) and (#(playersByTeam[TEAM_UNDEAD] or {}) < desiredCountByTeam[TEAM_UNDEAD]) and botsByTeam[TEAM_HUMAN] then
			local randomBot = table.remove(botsByTeam[TEAM_HUMAN], 1)
			randomBot:StripWeapons()
			--randomBot:KillSilent()
			randomBot:Kill()
			return
		end
	end

	-- Add bots out of managed teams to maintain desired counts
	if (player.GetCount() < allowedTotal) then
		for team, desiredCount in pairs(desiredCountByTeam) do
			if (#(playersByTeam[team] or {}) < desiredCount) then
				if D3bot.UseConsoleBots then
					spawnAsTeam = team
					RunConsoleCommand("bot")
					spawnAsTeam = nil
				else
					spawnAsTeam = team
					---@type GPlayer|table
					local bot = player.CreateNextBot(D3bot.GetUsername())
					spawnAsTeam = nil
					if IsValid(bot) then
						if (bot:Team() ~= team) then
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
		if (#(botsByTeam[team] or {}) > desiredCount) and botsByTeam[team] then
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
