{
  description = "NixOS configuration with flakes.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    agenix.url = "github:ryantm/agenix";
  };

  outputs =
    { nixpkgs, agenix, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      STATIC_GLOBAL_VARS = import ./STATIC_GLOBAL_VARS.nix;
    in
    {
      nixosConfigurations.big-boss = nixpkgs.lib.nixosSystem {
        inherit system;

        specialArgs = STATIC_GLOBAL_VARS;

        modules = [
          ./systems/common/nix.nix
          ./systems/common/user.nix
          ./systems/common/programs.nix
          ./systems/common/localization.nix

          ./systems/big-boss/user.nix
          ./systems/big-boss/desktop.nix
          ./systems/big-boss/programs.nix
          ./systems/big-boss/services.nix
          ./systems/big-boss/networking.nix
          ./systems/big-boss/hardware-configuration.nix
        ];
      };

      nixosConfigurations.o700 = nixpkgs.lib.nixosSystem {
        inherit system;

        specialArgs = STATIC_GLOBAL_VARS;

        modules = [
          agenix.nixosModules.default
          ./modules/seta.nix

          ./systems/common/nix.nix
          ./systems/common/user.nix
          ./systems/common/programs.nix
          ./systems/common/localization.nix

          ./systems/o700/user.nix
          ./systems/o700/networking.nix
          ./systems/o700/monitoring.nix
          ./systems/o700/used-secrets.nix
          ./systems/o700/services-LAN.nix
          ./systems/o700/services-WAN.nix
          ./systems/o700/services-internal.nix
          ./systems/o700/hardware-configuration.nix
        ];
      };

      formatter.${system} = pkgs.nixfmt-tree;

      devShells.${system}.default =
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.mkShell {
          buildInputs = [
            pkgs.nixfmt
            pkgs.nil
            pkgs.nixd
            agenix.packages.${system}.agenix
          ];
        };
    };
}
