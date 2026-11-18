-- What every test shares. Run a test from mod/ after check.sh builds .tlpath/: lua test/X_test.lua
local tl = require("tl")
dofile("tlconfig.lua") -- Windows module-name mapping; a no-op elsewhere
tl.loader()
package.path = ".tlpath/?.tl;" .. package.path
local H = { failures = 0 }
function H.mod(name) return require("track_geometry_tool::/track_geometry/" .. name .. ".script.tl") end
function H.check(ok, what)
	print((ok and "ok   " or "FAIL ") .. what)
	if not ok then H.failures = H.failures + 1 end
end
function H.done()
	print(H.failures == 0 and "all passed" or (H.failures .. " failed"))
	os.exit(H.failures == 0 and 0 or 1)
end
return H
