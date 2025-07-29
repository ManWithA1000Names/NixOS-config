.PHONY: switch fast rollback

switch:
	nixos-rebuild switch --flake .#local-cloud
	@echo "DONE: switch"

fast:
	nixos-rebuild switch --fast --flake .#local-cloud

rollback:
	nixos-rebuild switch --rollback
