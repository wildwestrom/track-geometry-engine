local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = { }
	local a = ssu.makeAdder(result)
	-- The curve badges (tg_gui TgBadges): stretch the full-screen recipe and its layout over the whole screen, so each badge's h, v (a share of the screen) lands at its curve.
	-- Without this the layout shrinks to its badges and they pile up at the left middle of the screen. Gravity can only be set here, not in a component's own styleSheet.
	a("R::TgBadges", {
		gravity = { -1, -1 },
	})
	a("R::TgBadges > FloatingLayout", {
		gravity = { -1, -1 },
	})
	-- The mode window (tg_gui TgModeWindow): wide enough for its title, centred 2/3 of the way across the screen and halfway down.
	-- A window's place can only be set here (the window API has no position), so it is not placed at the click.
	-- Gravity runs 0 (left, top) to 1 (right, bottom) (seen in game: { 1/3, 0 } put it a third across, at the top); the anchor is the window's own centre.
	a("Window#tgmode", {
		minSize = { 260, -1 },
		anchorPoint = { 0.5, 0.5 },
		gravity = { 2 / 3, 1 / 2 },
		margin = { 10, 10, 10, 10 },
	})
	return result
end
