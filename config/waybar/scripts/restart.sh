#!/bin/sh

if pid=$(pgrep "waybar"); then
	kill "$pid"
fi

hyprctl dispatch 'hl.dsp.exec_cmd("waybar")'
