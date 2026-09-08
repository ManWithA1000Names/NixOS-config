{
  description = "NixOS configuration with flakes.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    agenix.url = "github:ryantm/agenix";
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      STATIC_GLOBAL_VARS = import ./STATIC_GLOBAL_VARS.nix;

      # Stamps the git commit that built a generation into the system itself,
      # where `nixos-version` and anything reading config.system.configurationRevision
      # can find it. Nothing set this before, so `nixos-version` reported
      # nothing useful about which commit a running host came from.
      #
      # The backup system is what makes this load-bearing rather than a nicety:
      # every snapshot records this value, and it is what lets a restore name
      # the exact configuration the data was written under -- surviving
      # `just delete-generations`, which garbage-collects the generation and
      # would take a store path with it.
      #
      # `self.rev` exists only for a clean tree; the justfile refuses to deploy
      # a dirty one, so the fallback should never be what lands on o700.
      configRevision = {
        system.configurationRevision = self.rev or self.dirtyRev or "dirty";
      };
    in
    {
      nixosConfigurations.big-boss = nixpkgs.lib.nixosSystem {
        inherit system;

        specialArgs = STATIC_GLOBAL_VARS;

        modules = [
          configRevision

          ./systems/common/nix.nix
          ./systems/common/user.nix
          ./systems/common/programs.nix
          ./systems/common/localization.nix

          ./systems/big-boss/user.nix
          ./systems/big-boss/deploy.nix
          ./systems/big-boss/desktop.nix
          ./systems/big-boss/programs.nix
          ./systems/big-boss/services.nix
          ./systems/big-boss/networking.nix
          ./systems/big-boss/virtualisation.nix
          ./systems/big-boss/hardware-configuration.nix
        ];
      };

      nixosConfigurations.o700 = nixpkgs.lib.nixosSystem {
        inherit system;

        specialArgs = STATIC_GLOBAL_VARS;

        modules = [
          configRevision

          agenix.nixosModules.default
          ./modules/seta.nix

          ./systems/common/nix.nix
          ./systems/common/user.nix
          ./systems/common/programs.nix
          ./systems/common/localization.nix

          ./systems/o700/user.nix
          ./systems/o700/backup.nix
          ./systems/o700/deploy.nix
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
