{ lib, ... }:
{
  # Lets big-boss push a system closure it built, without granting it
  # trusted-user rights here. See systems/big-boss/deploy.nix for the other half.
  #
  # fileContents, not readFile: trusted-public-keys is written as a single
  # space-separated line in nix.conf, so an embedded trailing newline breaks it.
  nix.settings.trusted-public-keys = [
    (lib.fileContents ../../public-keys/big-boss-cache.pub)
  ];
}
