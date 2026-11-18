
local mod = {}

mod.preRunFn = function(captureParams, configDict : {{string, string}}, allModParams : {string : {string : integer}}, baseConfig : BaseConfig)
	print("[track_geometry_tool] preRunFn: mod loaded")
end

return mod
