local meta = FindMetaTable("Player")
function meta:IsBeingControlled()
	return SERVER and self.D3bot_Mem or self.m_IsBeingControlled
end

function D3bot.GetTrajectories2DParams(g, initVel, distZ, distRad)
	local trajectories = {}
	local radix = initVel^4 - g*(g*distRad^2 + 2*distZ*initVel^2)
	
	if radix < 0 then return trajectories end
	local pitch = math.atan((initVel^2 - math.sqrt(radix)) / (g*distRad))
	local t1 = distRad / (initVel * math.cos(pitch))
	table.insert(trajectories, {g = g, initVel = initVel, pitch = pitch, t1 = t1})
	if radix > 0 then
		local pitch = math.atan((initVel^2 + math.sqrt(radix)) / (g*distRad))
		local t1 = distRad / (initVel * math.cos(pitch))
		table.insert(trajectories, {g = g, initVel = initVel, pitch = pitch, t1 = t1})
	end
	
	return trajectories
end

---This will calculate player jump heights based on the "Source SDK 2013" gamemovement.cpp logic.
---While this could be done analytically, any such solution results in smaller final jump heights due to truncation errors of the numerical integration that the engine does.
---Therefore we will replicate what the engine is doing.
---
---You may have to add the height difference between the `HullDuck` and `Hull` hull to the final result.
---@param jumpPower number The initial jump velocity.
---@param gravAcceleration number The gravitational acceleration.
---@param isCrouching boolean When true, we will jump while crouching. This minimally changes the math, and makes the player jump higher.
---@return number height The resulting jump height in source units.
function D3bot.CalculateJumpHeight(jumpPower, gravAcceleration, isCrouching)
	-- Some information:
	-- - The initial vertical velocity is not 0 when the player is standing, but `-g/tickrate/2`. (https://github.com/ValveSoftware/source-sdk-2013/blob/0d8dceea4310fde5706b3ce1c70609d72a38efdf/mp/src/game/shared/gamemovement.cpp#L1259)
	-- - Crouching and instantly jumping is better than jumping and crouching. This is because if the player jumps while crouching, the entity's speed is overwritten instead of added to, resulting in an initial velocity advantage of `g/tickrate/2`. (https://github.com/ValveSoftware/source-sdk-2013/blob/0d8dceea4310fde5706b3ce1c70609d72a38efdf/mp/src/game/shared/gamemovement.cpp#L2452-L2465)
	-- - After we have started to jump, we will subtract `-g/tickrate/2` again. (https://github.com/ValveSoftware/source-sdk-2013/blob/0d8dceea4310fde5706b3ce1c70609d72a38efdf/mp/src/game/shared/gamemovement.cpp#L2122)

	local tickRate = 1 / engine.TickInterval() -- Ticks/s
	local integratedAcceleration = math.abs(gravAcceleration/tickRate)

	local vel, height = -integratedAcceleration/2, 0
	if isCrouching then
		vel = jumpPower
	else
		vel = vel + jumpPower
	end
	vel = vel - integratedAcceleration/2

	-- Checks to ensure termination.
	if vel > 10000 then return 0 end
	if integratedAcceleration <= 0 then return 0 end

	while vel > 0 do
		height = height + vel / tickRate
		vel = vel - integratedAcceleration
	end

	return height
end

function D3bot.GetTrajectory2DPoints(trajectory, segments)
	trajectory.points = {}
	for i = 0, segments, 1 do
		local t = Lerp(i/segments, 0, trajectory.t1)
		local r = Vector(math.cos(trajectory.pitch)*trajectory.initVel*t, 0, math.sin(trajectory.pitch)*trajectory.initVel*t - trajectory.g/2*t^2)
		table.insert(trajectory.points, r)
	end
	
	return trajectory
end

function D3bot.GetTrajectories(initVel, r0, r1, segments)
	local g = 600 -- Hard coded acceleration, should be read from gmod later
	
	local distZ = r1.z - r0.z
	local distRad = math.sqrt((r1.x - r0.x)^2 + (r1.y - r0.y)^2)
	local yaw = math.atan2(r1.y - r0.y, r1.x - r0.x)
	
	local trajectories = D3bot.GetTrajectories2DParams(g, initVel, distZ, distRad)
	for i, trajectory in ipairs(trajectories) do
		trajectories[i].yaw = yaw
		-- Calculate 2D trajectory from parameters
		trajectories[i] = D3bot.GetTrajectory2DPoints(trajectory, segments)
		-- Rotate and move trajectory into 3D space
		for k, _ in ipairs(trajectory.points) do
			trajectory.points[k]:Rotate(Angle(0, math.deg(yaw), 0))
			trajectory.points[k]:Add(r0)
		end
	end
	
	return trajectories
end

-- PERFORMANCE: player.GetAll() allocates and returns a brand new table on every single call --
-- it's not a cached reference to anything. Several bots each independently calling it once or
-- twice per tick (trace filters, target scans, enemy lists) adds up to N-bots x M-call-sites
-- fresh full-roster allocations per tick, most of which don't need to differ from one another
-- within the same tick. D3bot.GetCachedPlayerList() below refreshes once per unique CurTime()
-- (i.e. once per server tick, since CurTime() is stable within a tick) and every caller within
-- that tick shares the same table.
--
-- IMPORTANT: the returned table is shared across every caller in the current tick. Treat it as
-- read-only -- do not sort it, insert into it, or remove from it in place. If you need a
-- modified/filtered copy (e.g. via D3bot.RemoveObsDeadTgts or D3bot.From(...):Where(...)),
-- that's fine and safe, since those return a new table rather than mutating their input.
local cachedPlayerList, cachedPlayerListTime = {}, -1
function D3bot.GetCachedPlayerList()
	local now = CurTime()
	if cachedPlayerListTime ~= now then
		cachedPlayerListTime = now
		cachedPlayerList = player.GetAll()
	end
	return cachedPlayerList
end

-- Remove spectating, meshing and dead players
function D3bot.RemoveObsDeadTgts(tgts)
	return D3bot.From(tgts):Where(function(k, v) return IsValid(v) and v:GetObserverMode() == OBS_MODE_NONE and not v:IsFlagSet(FL_NOTARGET) and v:Alive() end).R
end

-- List of entities that will be used to check whether nodes are blocked or unblocked.
-- Used by the condition=blocked and condition=unblocked parameters.
D3bot.NodeBlocking = {
	mins = Vector(-1, -1, -1),
	maxs = Vector(1, 1, 1),
	classes = {func_breakable = true, prop_physics = true, prop_dynamic = true, prop_door_rotating = true, func_door = true, func_physbox = true, func_physbox_multiplayer = true, func_movelinear = true}
}

-- List of entities that will be used to check whether nodes are blocked or unblocked.
-- Used by the condition=MapUnblocked parameter.
-- This specific variant excludes anything that can be used to cade.
D3bot.NodeBlockingMap = {
	mins = Vector(-1, -1, -1),
	maxs = Vector(1, 1, 1),
	classes = {func_breakable = true, prop_dynamic = true, prop_door_rotating = true, func_door = true, func_movelinear = true}
}

-- PERFORMANCE NOTE: D3bot.IsNavMeshNodeBlocked() (below) is called once per link evaluated
-- during A* pathfinding (see sv_path.lua), which is itself already one of the more expensive
-- things this addon does per the benchmark comments in that file. The underlying
-- ents.FindInBox()/ents.FindInSphere() world queries it does are comparatively expensive to
-- repeat on every single call. In practice, node-blocking state (barricades built/destroyed,
-- wave changing) changes far less often than it gets checked -- many bots pathing through the
-- same area re-check the exact same nodes many times per second. We cache the result per node
-- for a short duration instead of re-querying the world every time.
local nodeBlockedCache = {}
local nodeBlockedCacheDuration = 0.25 -- Seconds. Short enough to pick up gameplay-relevant changes quickly (new barricade, wave change), long enough to absorb bursts of path searches happening in the same tick/frame.

---Clears the entire blocked-node cache. Called whenever something that could affect node
---blocking changes: a relevant entity is created/removed (see hooks below), or the navmesh
---itself is edited (see fallback:InvalidateCache in 1_navmesh.lua).
---We don't try to figure out which specific nodes are affected by a given entity -- clearing
---the whole cache is cheap (a table wipe) and this only runs on relatively rare events, not
---on every tick.
function D3bot.InvalidateNodeBlockedCache()
	table.Empty(nodeBlockedCache)
end

local function entityCouldAffectNodeBlocking(ent)
	if not IsValid(ent) then return false end
	local class = ent:GetClass()
	local nodeBlocking, nodeBlockingMap = D3bot.NodeBlocking, D3bot.NodeBlockingMap
	return (nodeBlocking and nodeBlocking.classes[class]) or (nodeBlockingMap and nodeBlockingMap.classes[class])
	-- NOTE: this deliberately doesn't check individual nodes' BlockEntity values (arbitrary
	-- entity classes set per-node in the navmesh editor). Checking against every node's
	-- BlockEntity here would defeat the point of a cheap invalidation check, and creating/
	-- removing an entity that happens to match some node's BlockEntity is rare enough that we
	-- accept up to nodeBlockedCacheDuration seconds of staleness for that specific case.
end

hook.Add("OnEntityCreated", "D3bot_InvalidateNodeBlockedCache", function(ent)
	-- Deferred: ent:GetClass() and other properties aren't guaranteed to be valid the instant
	-- OnEntityCreated fires.
	timer.Simple(0, function()
		if entityCouldAffectNodeBlocking(ent) then
			D3bot.InvalidateNodeBlockedCache()
		end
	end)
end)
hook.Add("EntityRemoved", "D3bot_InvalidateNodeBlockedCache", function(ent)
	if entityCouldAffectNodeBlocking(ent) then
		D3bot.InvalidateNodeBlockedCache()
	end
end)

---Cache for D3bot.GetCachedNumberParam, keyed by the params table itself (weak keys, so an
---entry disappears on its own once the corresponding node/link's Params table is garbage
---collected -- no separate cleanup needed when nodes get deleted in the navmesh editor).
---
---IMPORTANT: this is a *separate* table from item.Params on purpose. An earlier version of
---this cache stored its entries directly inside item.Params (e.g. params["_NumCache_"..key]).
---That silently broke the navmesh editor's on-screen param display, which iterates over
---every key in item.Params and concatenates it into a string -- the cache's internal false
---sentinel (see below) is a boolean, and Lua's `..` can't concatenate a boolean, which is
---what caused the "attempt to concatenate local 'v' (a boolean value)" error in
---2_mapnavmeshui_cl.lua. item.Params must only ever contain real, user-set param values.
local numberParamCache = setmetatable({}, { __mode = "k" })

---Returns tonumber(params[key]), caching the parsed result so repeated calls (read on every
---path search, for every node with the given param set) don't re-parse the same string over
---and over. The cache entry is invalidated automatically whenever SetParam() writes a new raw
---value for that key -- see itemFallback:SetParam in 1_navmesh.lua.
---@param params table
---@param key string
---@return number|nil
function D3bot.GetCachedNumberParam(params, key)
	local cacheForParams = numberParamCache[params]
	if not cacheForParams then
		cacheForParams = {}
		numberParamCache[params] = cacheForParams
	end

	local cached = cacheForParams[key]
	if cached ~= nil then
		if cached == false then return nil end -- "not a number" is cached as false, since nil is indistinguishable from "not cached yet".
		return cached
	end

	local num = tonumber(params[key])
	cacheForParams[key] = num or false
	return num
end

---Clears any cached number for a specific param, e.g. because it was just changed in the
---navmesh editor. Called from itemFallback:SetParam in 1_navmesh.lua.
---@param params table
---@param key string
function D3bot.InvalidateNumberParamCache(params, key)
	local cacheForParams = numberParamCache[params]
	if cacheForParams then cacheForParams[key] = nil end
end

---Returns whether the given node is currently blocked, for the given wave. Results are
---cached briefly -- see nodeBlockedCacheDuration above.
---@param nodeParams table
---@param nodePos GVector
---@param wave number
---@return boolean
function D3bot.IsNavMeshNodeBlocked(nodeParams, nodePos, wave)
	-- The node's Params table identity is used as the cache key: each node has its own
	-- unique Params table, so this uniquely (and cheaply) identifies the node without an
	-- explicit node ID needing to be passed in.
	local cacheEntry = nodeBlockedCache[nodeParams]
	local now = CurTime()
	if cacheEntry and cacheEntry.Wave == wave and (now - cacheEntry.Time) < nodeBlockedCacheDuration then
		return cacheEntry.Blocked
	end

	local blocked = D3bot.CalculateIsNavMeshNodeBlocked(nodeParams, nodePos, wave)
	nodeBlockedCache[nodeParams] = { Blocked = blocked, Wave = wave, Time = now }
	return blocked
end

---The actual (uncached) blocked-node calculation. Kept separate from the cache handling in
---D3bot.IsNavMeshNodeBlocked() above so each stays simple on its own.
---@param nodeParams table
---@param nodePos GVector
---@param wave number
---@return boolean
function D3bot.CalculateIsNavMeshNodeBlocked(nodeParams, nodePos, wave)
	local nodeBlocking = D3bot.NodeBlocking
	local nodeBlockingMap = D3bot.NodeBlockingMap
	if not nodeBlocking or not nodeBlockingMap then return false end

	if nodeParams.Condition == "Unblocked" then
		local ents = ents.FindInBox(nodePos + nodeBlocking.mins, nodePos + nodeBlocking.maxs)
		for _, ent in ipairs(ents) do
			if nodeBlocking.classes[ent:GetClass()] then return true end
		end
	elseif nodeParams.Condition == "Blocked" then
		local ents = ents.FindInBox(nodePos + nodeBlocking.mins, nodePos + nodeBlocking.maxs)
		local found = false
		for _, ent in ipairs(ents) do
			if nodeBlocking.classes[ent:GetClass()] then found = true; break end
		end
		if not found then return true end
	elseif nodeParams.Condition == "MapUnblocked" then
		local ents = ents.FindInBox(nodePos + nodeBlockingMap.mins, nodePos + nodeBlockingMap.maxs)
		for _, ent in ipairs(ents) do
			if nodeBlockingMap.classes[ent:GetClass()] then return true end
		end
	end

	-- BlockRadius/BlockBeforeWave/BlockAfterWave come from navmesh param strings. The
	-- original code called tonumber() on these directly, every call (BlockBeforeWave's was
	-- even called twice per check). These rarely change at runtime -- only via the navmesh
	-- editor -- so we cache the parsed number on the params table itself. See
	-- D3bot.GetCachedNumberParam above.
	if nodeParams.BlockEntity then
		local blockRadius = D3bot.GetCachedNumberParam(nodeParams, "BlockRadius")
		if blockRadius then
			for _, ent in ipairs(ents.FindInSphere(nodePos, blockRadius)) do
				if ent:GetClass() == nodeParams.BlockEntity then
					return true
				end
			end
		end
	end

	local blockBeforeWave = D3bot.GetCachedNumberParam(nodeParams, "BlockBeforeWave")
	if blockBeforeWave and wave < blockBeforeWave then return true end

	local blockAfterWave = D3bot.GetCachedNumberParam(nodeParams, "BlockAfterWave")
	if blockAfterWave and wave > blockAfterWave then return true end

	return false
end

---Calculates a falloff on the given nodes.
---@param startNode D3NavmeshNode|nil -- The node to start on.
---@param iterations integer -- The maximum number of iterations.
---@param startValue number -- The starting value.
---@param falloff number -- The falloff factor for every followed link.
---@param nodes table<D3NavmeshNode, number> -- The starting node-number pairs.
---@return table<D3NavmeshNode, number> -- Result is a map of nodes with number values.
function D3bot.NeighbourNodeFalloff(startNode, iterations, startValue, falloff, nodes)
	if not startNode then return {} end
	local nodes = nodes or {}
	local queue = {startNode}
	nodes[startNode] = (nodes[startNode] or 0) + startValue
	while #queue > 0 and iterations > 0 do
		local node = table.remove(queue)
		iterations = iterations - 1
		for linkedNode, link in pairs(node.LinkByLinkedNode) do
			nodes[linkedNode] = nodes[node] * falloff
			table.insert(queue, linkedNode)
		end
	end
	return nodes
end
