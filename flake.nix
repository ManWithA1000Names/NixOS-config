{
  description = "NixOS configuration with flakes";

  inputs = { nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05"; };

  outputs = { nixpkgs, ... }:
    let system = "x86_64-linux";
    in {
      nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
        inherit system;

        modules = [
          ./user.nix
          ./audio.nix
          ./programs.nix
          ./environment.nix

          # System configuration module
          (_: {
            # Time zone
            time.timeZone = "Europe/Athens";
            i18n.defaultLocale = "en_US.UTF-8";

            # nix specifics
            nixpkgs.config.allowUnfree = true;
            nix.settings = {
              experimental-features = "nix-command flakes";
              auto-optimise-store = true;
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
