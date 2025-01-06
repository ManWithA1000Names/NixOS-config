.PHONY: help nixos switch 

help:
	@echo "Welcome to 'my' nix-os configuration files"
	@echo ""
	@echo "These are the available sub-commands:"
	@echo "'deploy' meaning placing them in the correct position in the system and reloading the apps"
	@echo ""
	@echo "nixos     Deploy the nixos configuration files. REQUIRES SUDO!"
	@echo "switch    Deploy the nixos configuration files and then run 'nixos-rebuild switch'. REQUIRES SUDO!"
	@echo ""
	@echo "By default make will run all the non-special subcommands."

nixos:
	cp /etc/nixos/hardware-configuration.nix .
	rm -rf /etc/nixos/*
	cp -r ./nixos/* /etc/nixos/
	cp hardware-configuration.nix /etc/nixos/
	rm hardware-configuration.nix

switch: nixos
	nixos-rebuild switch
	@echo "DONE: switch"
