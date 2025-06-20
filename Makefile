all: waybar hypr mako kitty wofi ghostty alacritty

.PHONY: help nixos switch hypr mako waybar kitty wofi ghostty alacritty

help:
	@echo "Welcome to 'my' nix-os configuration files"
	@echo ""
	@echo "These are the available sub-commands:"
	@echo "'deploy' meaning placing them in the correct position in the system and reloading the apps"
	@echo ""
	@echo "hypr      Deploy the hyprland configuration files."
	@echo "mako      Deploy the mako configuration files."
	@echo "waybar    Deploy the waybar configuration files."
	@echo "kitty     Deploy the kitty configuration files."
	@echo "wofi      Deploy the wofi configuration files."
	@echo "ghostty   Deploy the ghostty configuration files."
	@echo "alacritty Deploy the alacritty configuration files."
	@echo ""
	@echo "Some special sub-commands"
	@echo "nixos     Deploy the nixos configuration files. REQUIRES SUDO!"
	@echo "switch    Deploy the nixos configuration files and then run 'nixos-rebuild switch'. REQUIRES SUDO!"
	@echo ""
	@echo "By default make will run all the non-special subcommands."

nixos:
	cp /etc/nixos/hardware-configuration.nix .
	rm -rf /etc/nixos/*
	cp -r ./nixos/* /etc/nixos/
	mv hardware-configuration.nix /etc/nixos/

switch: nixos
	nixos-rebuild switch
	@echo "DONE: switch"

hypr:
	cp -r ./hypr ~/.config/
	@echo "DONE: hypr"

mako:
	cp -r ./mako ~/.config/
	if command -v makoctl > /dev/null; then makoctl reload; fi
	@echo "DONE: mako"

waybar:
	cp -r ./waybar/ ~/.config/
	if command -v waybar > /dev/null; then ~/.config/waybar/scripts/restart.sh; fi
	@echo "DONE: waybar"

kitty:
	cp -r ./kitty/ ~/.config/
	@echo "DONE: kitty"

wofi:
	cp -r ./wofi/ ~/.config/wofi/
	@echo "DONE: wofi"

ghostty:
	cp -r ./ghostty/ ~/.config/
	@echo "DONE: ghostty"

alacritty:
	cp -r ./alacritty/ ~/.config/
	@echo "DONE: alacritty"
