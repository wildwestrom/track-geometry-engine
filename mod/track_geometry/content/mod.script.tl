
local mod = {}

mod.preRunFn = function(captureParams, configDict : {{string, string}}, allModParams : {string : {string : integer}}, baseConfig : BaseConfig)
	print("[westrom_track_geometry] preRunFn: mod loaded")
end

return mod
