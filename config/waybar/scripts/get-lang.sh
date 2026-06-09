#!/bin/sh

res="$(hyprctl devices -j | jq -r '.keyboards[] | .active_keymap' | sort | uniq | tail -1)"

if [ "$res" = "Greek" ]; then
	echo "gr"
else
	echo "us"
fi
