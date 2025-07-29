{
  description = "NixOS configuration with flakes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    homelab-dashboard.url = "github:manwitha1000names/dashboard";
  };

  outputs = { nixpkgs, homelab-dashboard, ... }:
    let
      system = "x86_64-linux";
      shared = import ./shared.nix;
    in {
      nixosConfigurations.local-cloud = nixpkgs.lib.nixosSystem {
        inherit system;

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
          (_: {
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

              useDHCP = false;
              firewall.enable = false;
              interfaces.enp4s0 = {
                ipv4.addresses = [{
                  address = shared.static_ip;
                  prefixLength = 24;
                }];
              };

              defaultGateway = {
                address = "192.168.1.1";
                interface = "enp4s0";
              };
              nameservers = [ "1.1.1.1" "1.0.0.1" ];
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
