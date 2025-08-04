{ lib, ... }:
{
  # By default nix has some aliases that need to go.
  environment.shellAliases = lib.mkForce { };
}
