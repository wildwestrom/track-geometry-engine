local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = { }
	local a = ssu.makeAdder(result)
	-- The curve badges (tg_gui TgBadges): stretch the full-screen recipe and its layout over the
	-- whole screen, so each badge's h, v (a share of the screen) lands at its curve. Without this
	-- the layout shrinks to its badges and they pile up at the left middle of the screen. Gravity
	-- can only be set here, not in a component's own styleSheet.
	a("R::TgBadges", {
		gravity = { -1, -1 },
	})
	a("R::TgBadges > FloatingLayout", {
		gravity = { -1, -1 },
	})
	-- The mode window (tg_gui TgModeWindow): wide enough for its title, at the bottom right of the
	-- screen above the game bar, as the game's own calendar window (Window#calendar).
	a("Window#tgmode", {
		minSize = { 260, -1 },
		anchorPoint = { 1, 1 },
		gravity = { 1, 1 },
		margin = { 0, 30, 120, 0 },
	})
	return result
end
