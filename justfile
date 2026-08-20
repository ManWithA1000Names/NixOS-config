# Build a new generation of the system and immediately switch to it.
[script]
switch SYSTEM:
    if [ -n "$(git status --porcelain)" ]; then
    	echo -e "\033[31mThe reposity has uncommited changes!\033[0m"
    	echo -e "\033[33mPlease commit all the change first and then run this command again.\033[0m"
    	exit
    fi
    if ! rg "nixosConfigurations.{{ SYSTEM }}\s*=" > /dev/null; then
    	echo -e "\033[31m'{{ SYSTEM }}' is not a recognized system.\033[0m";
    	echo -e "Please choose one of:\033[32m"
    	rg -N "nixosConfigurations\.([a-zA-Z0-9_-]+)\s*=" -r '$1' -o flake.nix --color never
    	echo -ne "\033[0m"
    	exit
    fi
    git pull
    sudo nixos-rebuild --flake {{ ".#" + SYSTEM }} switch

# Build a new generation of the system and switch to it on the next boot up.
[script]
boot SYSTEM:
    if [ -n "$(git status --porcelain)" ]; then
    	echo -e "\033[31mThe reposity has uncommited changes!\033[0m"
    	echo -e "\033[33mPlease commit all the change first and then run this command again.\033[0m"
    	exit
    fi
    if ! rg "nixosConfigurations.{{ SYSTEM }}\s*=" > /dev/null; then
    	echo -e "\033[31m'{{ SYSTEM }}' is not a recognized system.\033[0m";
    	echo -e "Please choose one of:\033[32m"
    	rg -N "nixosConfigurations\.([a-zA-Z0-9_-]+)\s*=" -r '$1' -o flake.nix --color never
    	echo -ne "\033[0m"
    	exit
    fi
    git pull
    sudo nixos-rebuild --flake {{ ".#" + SYSTEM }} boot

# Update the channel and all other inputs. This DOES NOT trigger a rebuild!
update CHANNEL="":
    if [ -n "{{ CHANNEL }}" ]; then sed 's@github:NixOS/nixpkgs/nixos-[0-9][0-9]\.[0-9][0-9]@github:NixOS/nixpkgs/nixos-{{ CHANNEL }}@' -i flake.nix; fi
    nix flake update
    @echo "Inputs update! Use: 'just switch', or 'just boot' to build a new generation with the updates."

# Delete all old generation leaving only the newest one.
delete-generations:
    sudo nix-collect-garbage -d
    sudo /run/current-system/bin/switch-to-configuration boot

# Deploy configuration files for all services used by the 'desktop'.
[script]
deploy PROGRAM="all":
    if [ "{{ PROGRAM }}" = "hypr" ] || [ "{{ PROGRAM }}" = "all" ]; then
    	mkdir -p ~/.config/hypr/
    	cp -R ./config/hypr/* ~/.config/hypr/
    	echo "Deployed: hypr."
    fi
    if [ "{{ PROGRAM }}" = "waybar" ] || [ "{{ PROGRAM }}" = "all" ]; then
    	mkdir -p ~/.config/waybar/
    	cp -R ./config/waybar/* ~/.config/waybar/
    	echo "Deployed: waybar."
    fi
    if [ "{{ PROGRAM }}" = "alacritty" ] ||  [ "{{ PROGRAM }}" = "all" ]; then
    	mkdir -p ~/.config/alacritty/
    	cp ./config/alacritty.toml ~/.config/alacritty/
    	echo "Deployed: alacritty."
    fi
    if [ "{{ PROGRAM }}" = "kitty" ] || [ "{{ PROGRAM }}" = "all" ]; then
    	mkdir -p ~/.config/kitty/
    	cp ./config/kitty.conf ~/.config/kitty/
    	echo "Deployed: kitty."
    fi
    if [ "{{ PROGRAM }}" = "mako" ] || [ "{{ PROGRAM }}" = "all" ]; then
    	mkdir -p ~/.config/mako/
    	cp ./config/mako.conf ~/.config/mako/config
    	echo "Deployed: mako."
    fi
    echo 'Done.'
