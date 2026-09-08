# Build a new generation of the system and immediately switch to it.
[script]
switch SYSTEM="host":
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "\033[31mThe reposity has uncommited changes!\033[0m"
        echo -e "\033[33mPlease commit all the change first and then run this command again.\033[0m"
        exit
    fi
    if [ "{{ SYSTEM }}" = "host" ]; then
        SYSTEM="$(hostname)"
    else
        if [ "{{ SYSTEM }}" != "$(hostname)" ]; then
            echo -e "\033[31mThis machine is '$(hostname)', not '{{ SYSTEM }}'.\033[0m"
        fi
        SYSTEM="{{ SYSTEM }}"
    fi
    if ! rg "nixosConfigurations.${SYSTEM}\s*=" > /dev/null; then
        echo -e "\033[31m'${SYSTEM}' is not a recognized system.\033[0m";
        echo -e "Please choose one of:\033[32m"
        rg -N "nixosConfigurations\.([a-zA-Z0-9_-]+)\s*=" -r '$1' -o flake.nix --color never
        echo -ne "\033[0m"
        exit
    fi
    git pull
    sudo nixos-rebuild --flake ".#$SYSTEM" switch

# Build a new generation of the system and switch to it on the next boot up.
[script]
boot SYSTEM="host":
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "\033[31mThe reposity has uncommited changes!\033[0m"
        echo -e "\033[33mPlease commit all the change first and then run this command again.\033[0m"
        exit
    fi
    if [ "{{ SYSTEM }}" = "host" ]; then
        SYSTEM="$(hostname)"
    else
        if [ "{{ SYSTEM }}" != "$(hostname)" ]; then
            echo -e "\033[31mThis machine is '$(hostname)', not '{{ SYSTEM }}'.\033[0m"
        fi
        SYSTEM="{{ SYSTEM }}"
    fi
    if ! rg "nixosConfigurations.${SYSTEM}\s*=" > /dev/null; then
        echo -e "\033[31m'${SYSTEM}' is not a recognized system.\033[0m";
        echo -e "Please choose one of:\033[32m"
        rg -N "nixosConfigurations\.([a-zA-Z0-9_-]+)\s*=" -r '$1' -o flake.nix --color never
        echo -ne "\033[0m"
        exit
    fi
    git pull
    sudo nixos-rebuild --flake ".#$SYSTEM" boot

# Build the next 'o700' generation here on 'big-boss' and switch to it there.
switch-o700: (_deploy-o700 "switch")

# Same, but 'o700' keeps running its current generation until the next boot up.
boot-o700: (_deploy-o700 "boot")

# Ship the closure to 'o700' and report what switching would do, without doing it.
dry-o700: (_deploy-o700 "dry-activate")

# Put 'o700' back on its previous generation.
[script]
rollback-o700:
    if [ "$(hostname)" = "o700" ]; then
        echo "We are already on the 'o700' host.";
        exit 1
    fi
    nixos-rebuild --flake .#o700 --target-host o700 --sudo --ask-sudo-password --rollback switch

# Builds 'o700's closure on this machine and pushes it over the LAN, so the
# production server spends CPU on the activation and nothing else.
[private]
[script]
_deploy-o700 ACTION:
    if [ "$(hostname)" = "o700" ]; then
        echo "We are already on the 'o700' host. Please use the '{{ ACTION }}' subcommand instead.";
        exit 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "\033[31mThe reposity has uncommited changes!\033[0m"
        echo -e "\033[33mPlease commit all the change first and then run this command again.\033[0m"
        exit 1
    fi
    git pull
    # Not run under sudo: this has to stay as the human user so ssh finds the
    # key and the agent. Privilege is only needed on the far end, via --sudo.
    nixos-rebuild --flake .#o700 --target-host o700 --sudo --ask-sudo-password --print-build-logs {{ ACTION }}

# Run the full nightly backup on 'o700' now, and follow it as it goes.
[script]
backup-o700:
    if [ "$(hostname)" = "o700" ]; then
        sudo systemctl start --wait o700-backup.service
        exit $?
    fi
    # --wait so this recipe's exit status is the backup's. Without it systemctl
    # returns as soon as the job is enqueued and a failed backup looks like a
    # successful command.
    ssh -t o700 sudo systemctl start --wait o700-backup.service

# What was backed up, when, and how stale it is -- both repositories.
[script]
backup-status-o700:
    if [ "$(hostname)" = "o700" ]; then
        sudo o700-restore list
        exit $?
    fi
    # sudo, because the restic repository password is a root-owned agenix
    # secret -- `o700-restore list` as a normal user cannot open the repository.
    ssh -t o700 sudo o700-restore list

# Run it without --yes first: the remote command prompts, and -t keeps the tty
# that the confirmation and the version guard need.
#
# Put one service back to a snapshot. SNAPSHOT is an id or 'latest'.
[script]
restore-o700 SET SNAPSHOT="latest" *ARGS="":
    if [ "$(hostname)" = "o700" ]; then
        sudo o700-restore restore {{ SET }} {{ SNAPSHOT }} {{ ARGS }}
        exit $?
    fi
    ssh -t o700 sudo o700-restore restore {{ SET }} {{ SNAPSHOT }} {{ ARGS }}

# The safe order for anything that bumps a package version: it guarantees a
# snapshot taken under the OLD binary exists, which is the only snapshot a
# restore can use without the version guard refusing.
#
# Deliberately a separate recipe rather than folded into switch-o700. Making
# every deploy wait for a full backup would train you to bypass it, and most
# deploys change nothing that matters here.
#
# Take a backup of 'o700', then deploy to it.
[script]
backup-then-switch-o700:
    just backup-o700
    just switch-o700

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
