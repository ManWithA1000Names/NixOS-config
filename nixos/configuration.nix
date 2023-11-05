_: {
  imports = [
    ./audio/default.nix

    ./boot/default.nix

    ./environment/default.nix
    ./environment/user.nix
    ./environment/programs.nix

    ./services/default.nix

    ./virtualisation/default.nix

    ./wayland/customization.nix
    ./wayland/login-manager.nix
    ./wayland/window-manager.nix

    ./hardware-configuration.nix
  ];

  # Time zone
  time.timeZone = "Europe/Athens";
  i18n.defaultLocale = "en_US.UTF-8";

  # nix specifics
  nixpkgs.config.allowUnfree = true;
  nix.settings = {
    experimental-features = "nix-command flakes";
    auto-optimise-store = true;
  };

  # networking
  networking.hostName = "big-boss";
  networking.networkmanager.enable = true;

  system.copySystemConfiguration = true;
  system.stateVersion = "23.05";
}
