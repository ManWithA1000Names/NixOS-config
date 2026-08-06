local terminal = "alacritty"
-- local browser = "helium --new-window --profile-directory=Default"
-- local browser = "vivaldi --new-window http://cloud.local"
local browser = "firefox"

local lock = [[hyprlock -c /tmp/hypr/hyprlock.conf]]

--------------------
---- AUTO START ----
--------------------

hl.on("hyprland.start", function()
	hl.exec_cmd(lock)
	hl.exec_cmd("pidof mako || mako")
	hl.exec_cmd("pidof waybar || waybar")
	hl.exec_cmd("pidof hyprpaper || /home/user/.config/hypr/scripts/startbg.sh")
	hl.exec_cmd("pidof vicinae-server || vicinae server")
	hl.timer(function()
		-- We need to set a timeout here, otherwise
		-- the focusing of the monitor happens too quickly
		-- and does not result in the correct monitor being focused.
		hl.dispatch(hl.dsp.focus({ monitor = "DP-3" }))
	end, { timeout = 1, type = "oneshot" })
end)

------------------
---- ENV VARS ----
------------------

hl.env("NIXOS_OZONE_WL", "1")
hl.env("XDG_SCREENSHOTS_DIR", "/home/user/Pictures/Screenshots/")
hl.env("NVD_BACKEND", "direct")
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")

------------------
---- MONITORS ----
------------------

-- 49" Samsung Monitor (1440p)
hl.monitor({
	output = "DP-3",
	mode = "5120x1440@120",
	position = "0x1440",
	scale = 1,
})

-- 34" Iiyama Monitor (1440p)
hl.monitor({
	output = "DP-2",
	mode = "3440x1440@144",
	position = "1350x0",
	scale = 1,
})

-- 24" LG Monitor (1080p)
hl.monitor({
	output = "DP-1",
	mode = "1920x1080@60",
	position = "5120x1055",
	scale = 1,
	transform = 1,
})

----------------
---- CONFIG ----
----------------

hl.config({
	general = {
		resize_on_border = true,
		locale = "en_US",
		col = {
			active_border = { colors = { "rgba(33ccffee)", "rgba(00ff99ee)" }, angle = 45 },
			inactive_border = "rgba(595959aa)",
		},
	},

	decoration = {
		rounding = 5,
	},

	input = {
		kb_layout = "us,gr",
		kb_options = "grp:alt_shift_toggle",

		accel_profile = "flat",

		follow_mouse_shrink = 5,

		sensitivity = 0,

		touchpad = {
			natural_scroll = true,
		},
	},

	animations = {
		enabled = true,
	},
})

-- Disable the slide animation when switching workspaces
hl.animation({ leaf = "workspaces", enabled = false })

hl.config({

	misc = {
		disable_hyprland_logo = true,
		disable_splash_rendering = true,

		mouse_move_enables_dpms = true,

		enable_swallow = true,
		swallow_regex = [[^(Alacritty)$]],

		focus_on_activate = true,

		allow_session_lock_restore = true,

		-- After a windows is opened in a workspace
		-- all children windows will always be
		-- opened in the same workspace.
		initial_workspace_tracking = 2,

		middle_click_paste = false,
	},

	binds = {
		-- On workspace focus, center the mouse on the last focused window.
		workspace_center_on = 1,
	},

	ecosystem = {
		no_update_news = true,
		no_donation_nag = true,
		enforce_permissions = true,
	},

	dwindle = {
		preserve_split = true,
		force_split = 2,
	},
})

hl.gesture({
	fingers = 3,
	direction = "horizontal",
	action = "workspace",
})

---------------------
---- PERMISSIONS ----
---------------------

hl.permission({ binary = "/nix/store/[a-z0-9]{32}-grim-[0-9.]*/bin/grim", type = "screencopy", mode = "allow" })
hl.permission({ binary = "/nix/store/[a-z0-9]{32}-hyprlock-[0-9.]*/bin/hyprlock", type = "screencopy", mode = "allow" })
hl.permission({
	binary = "/nix/store/[a-z0-9]{32}-hyprpicker-[0-9.]*/bin/hyprpicker",
	type = "screencopy",
	mode = "allow",
})
hl.permission({
	binary = "/nix/store/[a-z0-9]{32}-xdg-desktop-portal-hyprland-[0-9.]*/libexec/.xdg-desktop-portal-hyprland-wrapped",
	type = "screencopy",
	mode = "allow",
})

----------------------
---- WINDOW RULES ----
----------------------

hl.window_rule({
	name = "no-border-on-floating",
	match = { float = true },
	border_size = 0,
})

hl.window_rule({
	name = "suppress-maximize-events",
	match = { class = ".*" },

	suppress_event = "maximize",
})

hl.window_rule({
	-- Fix some dragging issues with XWayland
	name = "fix-xwayland-drags",
	match = {
		class = "^$",
		title = "^$",
		xwayland = true,
		float = true,
		fullscreen = false,
		pin = false,
	},

	no_focus = true,
})

hl.layer_rule({
	match = { namespace = "vicinae" },
	name = "vicinae-blur",
	blur = true,
	ignore_alpha = 0,
})

hl.layer_rule({
	match = { namespace = "vicinae" },
	name = "vicinae-no-animation",
	no_anim = true,
})

-------------------------
---- WORKSPACE RULES ----
-------------------------
hl.workspace_rule({
	workspace = "1",
	monitor = "DP-3",
	default = true,
	persistent = true,
})

hl.workspace_rule({
	workspace = "3",
	monitor = "DP-3",
})
hl.workspace_rule({
	workspace = "4",
	monitor = "DP-3",
})
hl.workspace_rule({
	workspace = "5",
	monitor = "DP-3",
})
hl.workspace_rule({
	workspace = "6",
	monitor = "DP-3",
})
hl.workspace_rule({
	workspace = "7",
	monitor = "DP-3",
})
hl.workspace_rule({
	workspace = "8",
	monitor = "DP-3",
})
hl.workspace_rule({
	workspace = "9",
	monitor = "DP-3",
})

hl.workspace_rule({
	workspace = "2",
	monitor = "DP-2",
	default = true,
	persistent = true,
})

hl.workspace_rule({
	workspace = "10",
	monitor = "DP-1",
	default = true,
	persistent = true,
})

----------------------
---- KEY BINDINGS ----
----------------------
local shutdown =
	[[command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown -t 'Shutting down...' --post-cmd 'shutdown now' || shutdown now]]
local reboot =
	[[command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown -t 'Rebooting...' --post-cmd 'reboot' || reboot]]
local launcher = "vicinae toggle"

-- The most essential key bind!
hl.bind("SUPER + RETURN", hl.dsp.exec_cmd(terminal))

-- Hyprland related
hl.bind("SUPER + SHIFT + Q", hl.dsp.exit())
hl.bind("SUPER + F", hl.dsp.window.fullscreen())
hl.bind("SUPER + SHIFT + C", hl.dsp.window.close())
hl.bind("SUPER + SHIFT + K", hl.dsp.window.kill())
hl.bind("SUPER + SPACE", hl.dsp.window.float({ action = "toggle" }))

hl.bind("SUPER + S", function()
	hl.dispatch(hl.dsp.dpms())
	hl.exec_cmd(lock)
end)
hl.bind("SUPER + ESCAPE", hl.dsp.exec_cmd(lock))
hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd(shutdown))
hl.bind("SUPER + SHIFT + ESCAPE", hl.dsp.exec_cmd(reboot))

hl.bind("SUPER + L", hl.dsp.focus({ direction = "right" }))
hl.bind("SUPER + H", hl.dsp.focus({ direction = "left" }))
hl.bind("SUPER + K", hl.dsp.focus({ direction = "up" }))
hl.bind("SUPER + J", hl.dsp.focus({ direction = "down" }))

hl.bind("SUPER + SHIFT + L", hl.dsp.window.move({ direction = "right" }))
hl.bind("SUPER + SHIFT + H", hl.dsp.window.move({ direction = "left" }))
hl.unbind("SUPER + SHIFT + K") -- This is important to remove defautl keybinds.
hl.bind("SUPER + SHIFT + K", hl.dsp.window.move({ direction = "up" }))
hl.bind("SUPER + SHIFT + J", hl.dsp.window.move({ direction = "down" }))

for i = 1, 10 do
	local key = i % 10 -- 10 maps to key 0
	hl.bind("SUPER + " .. key, hl.dsp.focus({ workspace = i }))
	hl.bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

hl.bind("SUPER + W", hl.dsp.workspace.toggle_special("magic"))
hl.bind("SUPER + SHIFT + W", hl.dsp.window.move({ workspace = "special:magic" }))

hl.bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind("SUPER + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Applications
hl.bind("SUPER + B", hl.dsp.exec_cmd(browser))
hl.bind("SUPER + R", hl.dsp.exec_cmd(launcher))
hl.bind("SUPER + SHIFT + X", hl.dsp.exec_cmd("hyprpicker --autocopy"))
hl.bind("Print", hl.dsp.exec_cmd("grimblast --freeze --notify copysave area"))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("grimblast --freeze --notify copysave screen"))

-- Audio
hl.bind(
	"XF86AudioRaiseVolume",
	hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"),
	{ locked = true, repeating = true }
)
hl.bind(
	"XF86AudioLowerVolume",
	hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),
	{ locked = true, repeating = true }
)
hl.bind("ALT + F1", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"))
hl.bind(
	"XF86AudioMute",
	hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),
	{ locked = true, repeating = true }
)
hl.bind(
	"XF86AudioMicMute",
	hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),
	{ locked = true, repeating = true }
)

hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, repeating = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, repeating = true })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"))
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"))

-- Audio devices

local function get_audio_sink_id(card_name)
	local safe_card_name = card_name:gsub('"', '\\"')
	local cmd = string.format(
		[[pw-dump | jq '.[] | select(.type == "PipeWire:Interface:Node") | select(.info.props["alsa.card_name"] == "%s") | select(.info.props["media.class"] == "Audio/Sink") | .id']],
		safe_card_name
	)

	local handle = io.popen(cmd)
	if nil == handle then
		hl.notification.create({
			text = "Failed to find the PipeWire ID for " .. card_name,
			icon = 3,
			color = "#FF0000",
			timeout = 5000,
		})
		return "??"
	end

	local result = handle:read("*a")
	handle:close()
	result = result:match("^%s*(.-)%s*$")

	return result
end

hl.bind("ALT + F2", function()
	-- Headphones
	local card_name = "Razer Nari" --

	hl.notification.create({
		text = "Changing audio sink to: " .. card_name,
		timeout = 5000,
		color = "#32a852",
		icon = 1,
		font_size = 8,
	})

	hl.exec_cmd("wpctl set-default '" .. get_audio_sink_id(card_name) .. "'")
end)

hl.bind("ALT + F3", function()
	-- Speakers
	local card_name = "Razer Nommo Chroma"

	hl.notification.create({
		text = "Changing audio sink to: " .. card_name,
		timeout = 5000,
		color = "#32a852",
		icon = 1,
		font_size = 8,
	})

	hl.exec_cmd("wpctl set-default '" .. get_audio_sink_id(card_name) .. "'")
end)
