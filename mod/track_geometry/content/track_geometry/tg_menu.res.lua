function data()
	return {
		-- adds the "Geometry" row to the track entries of the game's own builder (draws nothing)
		type = "react-plugin ::ModEntryPointExtension",
		data = {
			filePath = "track_geometry_tool::/track_geometry/tg_gui.script@TgMenuPlugin",
			order = 210,
		}
	}
end
