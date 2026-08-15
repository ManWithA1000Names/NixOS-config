# NixOS Flake configuration for my machines.

The files configures 2 systems

1. `big-boss` the user's workstation. Optimized for human use.
2. `o700` the LAN server, used for self-hosting applications. Optimized for server use.

Project structure breadown:

- `flake.nix`: Defines the two system configurations.
- `flake.lock`: Pins dependencies to specific git commits.
- `public-keys`: Contains all public keys used for SSH and secrets management.
- `secrets`: Contains all the encrypted secrets.
- `config`: Contains configuration files for various programs.
- `justfile`: Contains helpful commands for deploying configuration files, building new/deleting generations.
- `systems/big-boss`: Contains nixos modules used in the `big-boss` system.
- `systems/o700`: Contains nixos modules used in the `o700` system.
- `systems/common`: Modules used in both systems.

More specific details about how everything runs/is setup can be found in the (docs)[./docs] directory.
