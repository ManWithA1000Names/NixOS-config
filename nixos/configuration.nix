{ config, pkgs, ... }: {
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
  i18n = {
    defaultLocale = "en_US.UTF-8";
    supportedLocales = [ "en_US.UTF-8/UTF-8" "el_GR.UTF-8/UTF-8" ];
  };

  # nix specifics
  nixpkgs.config.allowUnfree = true;
  nix.settings = {
    experimental-features = "nix-command flakes";
    auto-optimise-store = true;
  };

  # networking
  networking = {
    hostName = "big-boss";
    networkmanager.enable = true;
    firewall.enable = false;
  };

  # nvidia
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.opengl = {
    enable = true;
    # Vulkan stuff
    driSupport = true;
    # VA-API
    extraPackages = with pkgs; [ nvidia-vaapi-driver ];
  };
  hardware.nvidia = {
    open = false; # nvidia open source kernel module, for 20 series and up only.
    nvidiaSettings = true;
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  system.copySystemConfiguration = true;
  system.stateVersion = "23.05";
}
