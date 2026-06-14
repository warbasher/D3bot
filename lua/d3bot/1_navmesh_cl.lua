
return function(lib)
	local buffer = ""

	net.Receive(lib.MapNavMeshNetworkStr, function()
		local finished = net.ReadBool()
		local data = net.ReadData(net.ReadUInt(16))

		buffer = buffer .. data

		if finished then
			lib.MapNavMesh = lib.DeserializeNavMesh(util.Decompress(buffer)) or {}
			buffer = ""
			if lib.InvalidateMapNavMeshViewBlockedCache then lib.InvalidateMapNavMeshViewBlockedCache() end
		end
	end)
end
