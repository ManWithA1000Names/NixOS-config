#!/bin/sh

mkdir -p /tmp/hypr/

PAPER="$(find ~/.config/hypr/Wallpapers -type f | shuf | head -1)"
sed "s@\$paper@$PAPER@g" ~/.config/hypr/hyprpaper.conf >/tmp/hypr/hyprpaper.conf
sed "s@\$paper@$PAPER@g" ~/.config/hypr/hyprlock.conf >/tmp/hypr/hyprlock.conf
PAPER_SPECIAL="$(find ~/Pictures/DC_Characters/fixed/ -type f | shuf | head -1)"
sed -i "s@\$special@$PAPER_SPECIAL@g" /tmp/hypr/hyprpaper.conf
sed -i "s@\$special@$PAPER_SPECIAL@g" /tmp/hypr/hyprlock.conf
hyprpaper -c /tmp/hypr/hyprpaper.conf
