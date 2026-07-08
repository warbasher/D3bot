
return function(globalK, otherLibFilesRelPathEach)
	local lib = {}
	
	local consoleErrorColor = Color(255, 75, 0)
	function lib.LogError(msg) MsgC(consoleErrorColor, "Error: " .. msg .. "\n") end
	
	function lib.TryInvoke(func, ...) if isfunction(func) then func(...) end end
	function lib.TryCatch(func, error)
		local didNotError, errorMsg = xpcall(func, debug.traceback)
		if not didNotError then error(errorMsg) end
	end
	function lib.TwoWay(a, b, func)
		func(a, b)
		func(b, a)
	end
	
	function lib.WriteOrAdd(tbl, k, v) if k == nil then table.insert(tbl, v) else tbl[k] = v end end
	
	-- PERFORMANCE NOTE: this used to be a plain sorted array. Enqueue() did a linear scan to
	-- find the insertion point, then table.insert() at that index, which shifts every
	-- element after it -- O(n) per insert, and this is the priority queue that
	-- D3bot.GetBestMeshPathOrNil() (A* pathfinding) uses for every single node it evaluates.
	-- The file's own benchmark comments show multi-millisecond costs per full path search
	-- even before accounting for this; on navmeshes with a lot of nodes this queue was very
	-- likely the single biggest contributor. Replaced with a standard binary min-heap:
	-- O(log n) for both Enqueue and Dequeue. External API (Enqueue/Dequeue, dedup via .Set,
	-- and the `func(a, b)` comparator signature) is unchanged, so callers (sv_path.lua)
	-- don't need to change at all.
	--
	-- Comparator semantics are preserved exactly from the old implementation: func(a, b)
	-- returning true means "a is lower priority than b" (a should be dequeued *after* b).
	-- Dequeue() always returns the highest-priority (lowest-cost, in the pathfinding case)
	-- remaining item.
	lib.SortedQueueMeta = { __index = {} }
	local sortedQueueFallback = lib.SortedQueueMeta.__index

	function lib.NewSortedQueue(func)
		return setmetatable({
			Set = {},   -- item -> true, for O(1) dedup checks on Enqueue.
			Func = func,
			Heap = {},  -- 1-indexed binary heap array.
			Size = 0 }, lib.SortedQueueMeta)
	end

	-- Returns true if the item at heap index a has strictly higher priority (should be
	-- dequeued before) the item at heap index b. This is func(b, a) rather than func(a, b):
	-- func(worse, better) == true in the original semantics, so "a has higher priority than
	-- b" is exactly "b is lower priority than a" == func(b, a).
	local function heapHigherPriority(self, indexA, indexB)
		return self.Func(self.Heap[indexB], self.Heap[indexA])
	end

	local function heapSwap(self, i, j)
		self.Heap[i], self.Heap[j] = self.Heap[j], self.Heap[i]
	end

	-- Restores the heap property by moving the item at index i up towards the root, as long
	-- as it has higher priority than its parent. Called after inserting a new item at the end.
	local function siftUp(self, i)
		while i > 1 do
			local parent = math.floor(i / 2)
			if heapHigherPriority(self, i, parent) then
				heapSwap(self, i, parent)
				i = parent
			else
				break
			end
		end
	end

	-- Restores the heap property by moving the item at index i down towards the leaves, as
	-- long as one of its children has higher priority. Called after moving the last item to
	-- the root position (which happens on every Dequeue).
	local function siftDown(self, i)
		local size = self.Size
		while true do
			local left, right, highest = i * 2, i * 2 + 1, i
			if left <= size and heapHigherPriority(self, left, highest) then highest = left end
			if right <= size and heapHigherPriority(self, right, highest) then highest = right end
			if highest == i then break end
			heapSwap(self, i, highest)
			i = highest
		end
	end

	---Adds item to the queue, unless it's already present (same dedup behavior as before).
	---O(log n).
	function sortedQueueFallback:Enqueue(item)
		if self.Set[item] then return end
		self.Set[item] = true
		self.Size = self.Size + 1
		self.Heap[self.Size] = item
		siftUp(self, self.Size)
	end

	---Removes and returns the highest priority item in the queue, or nil if empty. O(log n).
	function sortedQueueFallback:Dequeue()
		local size = self.Size
		if size == 0 then return nil end

		local top = self.Heap[1]
		self.Heap[1] = self.Heap[size]
		self.Heap[size] = nil
		self.Size = size - 1
		if self.Size > 0 then siftDown(self, 1) end

		self.Set[top] = nil
		return top
	end
	
	function lib.GetSplitStr(str, separator) return str == "" and {} or str:Split(separator) end
	function lib.GetWrappedStr(str, wrap) return wrap .. str .. wrap end
	function lib.GetQuotedStr(str) return lib.GetWrappedStr(str, "\"") end
	
	function lib.Send(...) (SERVER and net.Send or net.SendToServer)(...) end
	
	function lib.PairsByKeys(t, f)
      local a = {}
      for n in pairs(t) do table.insert(a, n) end
      table.sort(a, f)
      local i = 0				-- iterator variable
      local iter = function ()	-- iterator function
        i = i + 1
        if a[i] == nil then return nil
        else return a[i], t[a[i]]
        end
      end
      return iter
    end
	
	lib.QueryMeta = { __index = {} }
	local queryFallback = lib.QueryMeta.__index
	function lib.From(v) return setmetatable({ R = v }, lib.QueryMeta) end
	local from = lib.From
	function queryFallback:Any(func)
		for k, v in pairs(self.R) do
			if func(k, v) then
				self.R = true
				return self
			end
		end
		self.R = false
		return self
	end
	function queryFallback:ShallowCopy()
		local r = {}
		for k, v in pairs(self.R) do r[k] = v end
		self.R = r
		return self
	end
	function queryFallback:Len()
		local len = 0
		for k, v in ipairs(self.R) do len = len + 1 end
		self.R = len
		return self
	end
	function queryFallback:Ks()
		local r = {}
		for k, v in pairs(self.R) do table.insert(r, k) end
		self.R = r
		return self
	end
	function queryFallback:Sel(func)
		local r = {}
		for k, v in pairs(self.R) do lib.WriteOrAdd(r, func(k, v)) end
		self.R = r
		return self
	end
	function queryFallback:SelSort(func, sortFunc)
		local r = {}
		for k, v in lib.PairsByKeys(self.R, sortFunc) do lib.WriteOrAdd(r, func(k, v)) end
		self.R = r
		return self
	end
	function queryFallback:SelV(func)
		local r = {}
		for k, v in pairs(self.R) do r[k] = func(v) end
		self.R = r
		return self
	end
	function queryFallback:Where(func)
		local r = {}
		for k, v in pairs(self.R) do if func(k, v) then r[k] = v end end
		self.R = r
		return self
	end
	function queryFallback:W(arr)
		for k, v in ipairs(arr) do table.insert(self.R, v) end
		return self
	end
	function queryFallback:Wo(v)
		self:ShallowCopy()
		table.RemoveByValue(self.R, v)
		return self
	end
	function queryFallback:Sort(funcOrNil)
		self:ShallowCopy()
		table.sort(self.R, funcOrNil or function(a, b) return a < b end)
		return self
	end
	function queryFallback:Reverse(func)
		local r = {}
		for k, v in ipairs(self.R) do table.insert(r, 1, v) end
		self.R = r
		return self
	end
	function queryFallback:VsSet()
		local r = {}
		for k, v in ipairs(self.R) do r[v] = true end
		self.R = r
		return self
	end
	function queryFallback:Concat()
		local r = {}
		for idx, arr in ipairs(self.R) do for idx2, v in ipairs(arr) do table.insert(r, v) end end
		self.R = r
		return self
	end
	function queryFallback:Join(separator)
		self.R = string.Implode(separator, self.R)
		return self
	end
	
	function lib.GetFileInfo(path)
		local pathWoExt = path:StripExtension()
		local includePath = lib.GetIncludePath(path)
		local isSvside = pathWoExt:EndsWith("_sv")
		local isClside = pathWoExt:EndsWith("_cl")
		if not isSvside and not isClside then
			isSvside = true
			isClside = true
		end
		return {
			Name = path:GetFileFromFilename(),
			NameWoExt = pathWoExt:GetFileFromFilename(),
			Dir = path:GetPathFromFilename(),
			Path = path,
			PathWoExt = pathWoExt,
			IncludeDir = includePath:GetPathFromFilename(),
			IncludePath = includePath,
			IsSvside = isSvside,
			IsClside = isClside }
	end
	function lib.GetIncludePath(luaFilePath)
		local luaFolder = "lua/"
		local luaDirIdx = luaFilePath:find(luaFolder, 1, true)
		if not luaDirIdx then return luaFilePath end
		return luaFilePath:sub(luaDirIdx + #luaFolder)
	end
	function lib.MakeLibFileAvailable(relInfo) if SERVER and relInfo.IsClside then AddCSLuaFile(relInfo.IncludePath) end end
	function lib.ExecuteLibFile(relInfo) if (SERVER and relInfo.IsSvside) or (CLIENT and relInfo.IsClside) then lib.TryInvoke(include(relInfo.IncludePath), lib) end end
	
	lib.Color = {}
	lib.Color.Black = Color(0, 0, 0)
	lib.Color.White = Color(255, 255, 255)
	lib.Color.Red = Color(255, 0, 0)
	lib.Color.Orange = Color(255, 128, 0)
	lib.Color.Yellow = Color(255, 255, 0)
	lib.Color.Green = Color(0, 150, 0)
	lib.Color.Blocked = Color(160, 0, 255)
	for name, color in pairs(lib.Color) do
		color.HalfAlpha = ColorAlpha(color, 128)
		color.EightAlpha = ColorAlpha(color, 32)
		color.SixteenthAlpha = ColorAlpha(color, 32)
	end
	
	function lib.GetEntsOfClss(clss) return from(clss):SelV(ents.FindByClass):Concat().R end
	
	if SERVER then
		local relFileInfo = lib.GetFileInfo(debug.getinfo(1, "S").short_src)
		
		lib.MakeLibFileAvailable(relFileInfo)
		
		local assumedLibFilesRelPathEach = from(file.Find(relFileInfo.Dir .. "*.lua", "GAME")):SelV(function(name) return relFileInfo.IncludeDir .. name end).R
		function lib.SuggestSecondLibArgument() return "{\n\t" .. from(assumedLibFilesRelPathEach):Wo(relFileInfo.IncludePath):Sort():SelV(lib.GetQuotedStr):Join(",\n\t").R .. " }" end
	end
	for idx, relPath in ipairs(otherLibFilesRelPathEach) do
		local relInfo = lib.GetFileInfo(relPath)
		lib.MakeLibFileAvailable(relInfo)
		lib.ExecuteLibFile(relInfo)
	end
	
	if _G[globalK] then error("The specified global variable has already been assigned to.", 2) end
	_G[globalK] = lib
	lib.GlobalK = globalK
	lib.IsInitialized = true
end
