{ lib, ... }: {

  time.timeZone = "Europe/Athens";
  i18n = {
    defaultLocale = "en_US.UTF-8";
    supportedLocales = [
      "en_US.UTF-8/UTF-8"
      "el_GR.UTF-8/UTF-8"
    ];
  };

  # By default nix has some aliases that need to go.
  environment.shellAliases = lib.mkForce { };

  system.stateVersion = "26.05";
}
