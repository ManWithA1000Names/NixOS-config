#!/bin/sh

if [ -z "$1" ]; then
	echo "Please provide a channel version"
	exit 1
fi

sudo nix-channel --add "https://nixos.org/channels/nixos-$1" nixos
sudo nixos-rebuild --upgrade boot
