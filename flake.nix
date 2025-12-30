{
  description = "NixOS configuration with flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    homelab-dashboard.url = "github:manwitha1000names/dashboard";
  };

  outputs = { nixpkgs, homelab-dashboard, ... }:
    let system = "x86_64-linux";
    in {
      nixosConfigurations.local-cloud = nixpkgs.lib.nixosSystem {
        inherit system;

        specialArgs = rec {
          static_ip = "192.168.1.12";
          base_domain_name = "local.cloud";
          plane_app_port = 7000;
          plane_app_domain = "plane.${base_domain_name}";
        };

        modules = [
          homelab-dashboard.nixosModules.default

          ./boot.nix
          ./user.nix
          ./audio.nix
          ./services.nix
          ./programs.nix
          ./environment.nix
          ./virtualisation.nix
          ./hardware-configuration.nix

          # System configuration module
          ({ static_ip, ... }: {
            # Time zone
            time.timeZone = "Europe/Athens";
            i18n.defaultLocale = "en_US.UTF-8";

            # nix specifics
            nixpkgs.config.allowUnfree = true;
            nixpkgs.config.nvidia.acceptLicense = true;
            nix.settings = {
              experimental-features = "nix-command flakes";
              auto-optimise-store = true;
            };

            # networking
            networking = {
              hostName = "atalanta";
              firewall.enable = false;
              # networkmanager.enable = true;
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
