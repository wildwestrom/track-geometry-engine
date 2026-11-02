function data()
	return {
		-- "TG dry run" / "TG build" buttons for the smoke test; also logs when the GUI script loads
		type = "react-plugin ::GameBarInfoDisplayExtension",
		data = {
			filePath = "westrom_track_geometry::/track_geometry/tg_gui.script@TgProbe",
			order = 31,
			priority = 31,
		}
	}
end
