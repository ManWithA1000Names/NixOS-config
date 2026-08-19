{
  description = "NixOS configuration with flakes.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    agenix.url = "github:ryantm/agenix";
  };

  outputs = { nixpkgs, agenix, ... }:
    let
      system = "x86_64-linux";
      USERNAME = "user";
      MEDIA_GROUP = "media";

      # All IPs are guaranteed by the router.
      router-IP = "192.168.1.1";
      o700-IP = "192.168.1.108";
      big-boss-IP = "192.168.1.107";
    in {
      nixosConfigurations.big-boss = nixpkgs.lib.nixosSystem {
        inherit system;

        specialArgs = { inherit o700-IP USERNAME MEDIA_GROUP; };

        modules = [
          ./systems/common/nix.nix
          ./systems/common/user.nix
          ./systems/common/programs.nix

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

      nixosConfigurations.o700 = nixpkgs.lib.nixosSystem {
        inherit system;

        specialArgs = {
          inherit o700-IP big-boss-IP router-IP USERNAME MEDIA_GROUP;
          DOMAIN = "o700.net";
        };

        modules = [
          agenix.nixosModules.default

          ./systems/common/nix.nix
          ./systems/common/user.nix
          ./systems/common/programs.nix
          ./systems/common/virtualisation.nix

          ./systems/o700/user.nix
          ./systems/o700/services.nix
          ./systems/o700/arr-media-stack-reqs.nix
          ./systems/o700/hardware-configuration.nix

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
              hostName = "o700";
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
