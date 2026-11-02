function data()
	return {
		-- reads the mouse and places the curve badges for the tool (draws nothing)
		type = "react-plugin ::GameBarInfoDisplayExtension",
		data = {
			filePath = "westrom_track_geometry::/track_geometry/tg_gui.script@TgProbe",
			order = 31,
			priority = 31,
		}
	}
end
