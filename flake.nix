{
  description = "NixOS configuration with flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fish-config-source = {
      flake = false;
      url = "github:manwitha1000names/fish";
    };
  };

  outputs = { nixpkgs, nixos-wsl, fish-config-source, home-manager, ... }:
    let system = "x86_64-linux";
    in {
      nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
        inherit system;

        specialArgs = { username = "user"; };

        modules = [
          nixos-wsl.nixosModules.default
          home-manager.nixosModules.default

          ./user.nix
          ./audio.nix
          ./programs.nix
          ./environment.nix

          # System configuration module
          ({ username, ... }: {
            wsl.enable = true;
            wsl.defaultUser = username;

            # Time zone
            time.timeZone = "Europe/Athens";
            i18n.defaultLocale = "en_US.UTF-8";

            # nix specifics
            nixpkgs.config.allowUnfree = true;
            nix.settings = {
              experimental-features = "nix-command flakes";
              auto-optimise-store = true;
            };

            home-manager = {
              extraSpecialArgs = {
                inherit username;
                fishConfigSource = fish-config-source;
              };
              users.${username} = import ./home.nix;
            };

            system.stateVersion = "23.11";
          })

        ];
      };

      devShells.${system}.default =
        nixpkgs.legacyPackages.x86_64-linux.mkShell {
          buildInputs = with nixpkgs.legacyPackages.x86_64-linux; [
            nixpkgs-fmt
            nil
            nixd
          ];
        };
    };
}
