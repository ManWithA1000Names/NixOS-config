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
  nixpkgs.config = {
    allowUnfree = true;
    cudaSupport = true;
  };
  nix.settings = {
    experimental-features = "nix-command flakes";
    auto-optimise-store = true;
  };

  # networking
  networking = {
    hostName = "big-boss"; # Host name for the mDNS to work.
    firewall.enable = false; # Turn off the firewall.
    networkmanager.enable =
      true; # Enable the networkmanager which also automatically handles IPv4LL (Link-Local)
  };

  # nvidia
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware = {
    graphics = {
      enable = true;

      package = pkgs.mesa;

      # VA-API
      extraPackages = with pkgs; [ nvidia-vaapi-driver ];
    };

    nvidia = {
      modesetting.enable = true;

      open =
        false; # nvidia open source kernel module, for 20 series and up only.

      powerManagement.enable = false;
      powerManagement.finegrained = false;

      nvidiaSettings = true;

      package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
    };

    bluetooth.enable = true;
  };

  system.copySystemConfiguration = true;
  system.stateVersion = "23.05";
}
