-- Game-bar plugin. Two buttons fire the milestone 1 smoke test (tg_engine.script.tl) from the
-- camera centre, heading the way the camera faces: "TG dry run" only checks the proposal,
-- "TG build" also builds it. The results go to the log.
-- Bump VERSION, sync, reload, and check the log for the new value.

local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin

local VERSION = "v5"
local TAG = "[westrom_track_geometry] "
print(TAG .. "gui file loaded " .. VERSION)

local function sendSmoke(build : boolean)
	local cam = api.gui.camera.getCameraData() -- {center.x, center.y, distance, angle, pitch}
	local param = { x = cam.x, y = cam.y, heading = cam.w, build = build }
	print(string.format("%ssmoke %s requested at (%.1f, %.1f) heading %.1f deg", TAG,
		build and "build" or "dry run", cam.x, cam.y, math.deg(cam.w)))
	api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", "TrackGeometry", "tg_smoke", param))
end

local function button(label : string, onClick : function()) : TreeNodeId
	return builtin.Button{
		content = builtin.TextView{ text = label },
		onClick = onClick,
	}
end

local TgProbe = react.RegisterRecipe("TgProbe", function() : TreeNodeId
	react.useRefLazy(function() : boolean
		print(TAG .. "TgProbe mounted " .. VERSION)
		return true
	end)
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			button("TG dry run", function() sendSmoke(false) end),
			button("TG build", function() sendSmoke(true) end),
		},
	}
end)

return {
	TgProbe = TgProbe,
}
