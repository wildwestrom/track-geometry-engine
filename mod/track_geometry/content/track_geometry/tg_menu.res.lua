function data()
	return {
		-- adds the "Track Geometry" row to the default track builder
		type = "react-plugin ::ModEntryPointExtension",
		data = {
			filePath = "track_geometry_tool::/track_geometry/tg_gui.script@TgMenuPlugin",
			order = 210,
		}
	}
end
