{
  description = "NixOS configuration with flakes.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    homelab-dashboard.url = "github:ManWithA1000Names/dashboard";
    agenix.url = "github:ryantm/agenix";
  };

  outputs = { nixpkgs, homelab-dashboard, agenix, ... }:
    let system = "x86_64-linux";
    in {
      nixosConfigurations.big-boss = nixpkgs.lib.nixosSystem {
        inherit system;

        modules = [
          ./systems/common/nix.nix
          ./systems/common/programs.nix
          ./systems/common/virtualisation.nix

          ./systems/big-boss/user.nix
          ./systems/big-boss/desktop.nix
          ./systems/big-boss/programs.nix
          ./systems/big-boss/services.nix
          ./systems/big-boss/hardware-configuration.nix

          ({ lib, ... }: {

            time.timeZone = "Europe/Athens";
            i18n = {
              defaultLocale = "en_US.UTF-8";
              supportedLocales = [ "en_US.UTF-8/UTF-8" "el_GR.UTF-8/UTF-8" ];
            };

            security.rtkit.enable = true;

            networking = {
              hostName = "big-boss";
              firewall.enable = false;
              networkmanager.enable = true;
            };

            # By default nix has some aliases that need to go.
            environment.shellAliases = lib.mkForce { };

            system.stateVersion = "26.05";
          })
        ];
      };

      nixosConfigurations.cloud = nixpkgs.lib.nixosSystem {
        inherit system;

        specialArgs = {
          DOMAIN = "o700.net";
          MEDIA_GROUP = "media";
        };

        modules = [
          agenix.nixosModules.default
          homelab-dashboard.nixosModules.default

          ./systems/common/nix.nix
          ./systems/common/programs.nix
          ./systems/common/virtualisation.nix

          ./systems/cloud/user.nix
          ./systems/cloud/services.nix
          ./systems/cloud/hardware-configuration.nix

          ({ lib, ... }: {
            time.timeZone = "Europe/Athens";
            i18n = {
              defaultLocale = "en_US.UTF-8";
              supportedLocales = [ "en_US.UTF-8/UTF-8" "el_GR.UTF-8/UTF-8" ];
            };

            security.rtkit.enable = true;

            age.secrets.cloudflare-dns-api = {
              file = ./secrets/cloudflare-dns-api.age;
              owner = "caddy";
              group = "caddy";
            };

            networking = {
              hostName = "cloud";
              firewall.enable = false;
              useNetworkd = true;
            };

            # By default nix has some aliases that need to go.
            environment.shellAliases = lib.mkForce { };

            system.stateVersion = "26.05";
          })
        ];
      };

      devShells.${system}.default =
        let pkgs = import nixpkgs { inherit system; };
        in pkgs.mkShell {
          buildInputs = with pkgs; [
            nixpkgs-fmt
            nil
            nixd
            agenix.packages.${system}.agenix
          ];
        };
    };
}
