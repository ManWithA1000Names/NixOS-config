{ lib, ... }: {
  # By default nix has some aliases that need to go.
  environment.shellAliases = lib.mkForce { };

  # Make volantes cursors default cursor theme
  environment.extraSetup = ''
    mkdir $out/share/icons/default
    cat << EOF > $out/share/icons/default/index.theme
    [Icon Theme]
    Inherits=volantes_light_cursors
    EOF
  '';
}
