#!/bin/sh

if pid=$(pgrep "waybar"); then
	kill "$pid"
fi

hyprctl dispatch exec waybar
