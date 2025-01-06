{ config, ... }: {
  imports = [
    ./audio/default.nix

    ./boot/default.nix

    ./environment/default.nix
    ./environment/user.nix
    ./environment/programs.nix

    ./services/nfs.nix
    ./services/default.nix

    ./virtualisation/default.nix

    ./hardware-configuration.nix
  ];

  # Time zone
  time.timeZone = "Europe/Athens";
  i18n.defaultLocale = "en_US.UTF-8";

  # nix specifics
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.nvidia.acceptLicense = true;
  nix.settings = {
    experimental-features = "nix-command flakes";
    auto-optimise-store = true;
  };

  # networking
  networking = {
    hostName = "atalanta";

    useDHCP = false;
    firewall.enable = false;
    interfaces.enp4s0 = {
      ipv4.addresses = [{
        address = "192.168.1.12";
        prefixLength = 24;
      }];
    };

    defaultGateway = {
      address = "192.168.1.1";
      interface = "enp4s0";
    };
    nameservers = [ "1.1.1.1" "1.0.0.1" ];

  };

  # nvidia
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics = { enable = true; };
  hardware.nvidia = {
    open = false; # nvidia open source kernel module, for 20 series and up only.
    nvidiaSettings = true;
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.legacy_390;

    prime = {
      sync.enable = true;
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  system.copySystemConfiguration = true;
  system.stateVersion = "23.11";
}
