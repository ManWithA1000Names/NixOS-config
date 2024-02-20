#!/bin/sh

PAPER="$(find /home/user/.config/hypr/Wallpapers -type f | shuf | head -1)"
sed "s@\$paper@$PAPER@g" /home/user/.config/hypr/hyprpaper.conf >/tmp/hypr/hyprpaper.conf
hyprpaper -c /tmp/hypr/hyprpaper.conf
