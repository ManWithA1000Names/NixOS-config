{ config, lib, pkgs, modulesPath, o700-IP, ... }: {
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot = {
    initrd.availableKernelModules =
      [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" ];

    initrd.kernelModules = [ ];

    kernelModules =
      [ "kvm-intel" "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];

    kernelParams =
      [ "nvidia_drm.modeset=1" "nvidia_drm.fbdev=1" "reboot=force" ];

    extraModulePackages = [ ];

    supportedFilesystems = [ "nfs" "ntfs" ];

    loader = {
      systemd-boot = {
        enable = true;
        # With NVIDIA modules in the initrd each generation is ~225MB.
        # A 511MB /boot can only safely hold 2 generations.
        configurationLimit = 2;
      };
      efi.canTouchEfiVariables = true;
    };
  };

  console = {
    font = "ter-v32n";
    keyMap = "us";
    packages = with pkgs; [ terminus_font ];
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-uuid/567edb05-0ddf-4cfe-a862-d23ee0e570de";
      fsType = "ext4";
    };
    "/boot" = {
      device = "/dev/disk/by-uuid/0B93-50D8";
      fsType = "vfat";
    };
    "/mnt/windows" = {
      device = "/dev/disk/by-uuid/F4080EA4080E65C8";
      fsType = "ntfs";
    };
  };

  systemd = {
    settings.Manager.RebootWatchdogSec = "0";

    mounts = let
      commonMountOptions = {
        type = "nfs";
        mountConfig = { Options = "noatime"; };
      };
    in [
      (commonMountOptions // {
        what = "${o700-IP}:/export-ssd";
        where = "/mnt/ex-ssd/";
      })
    ];

    automounts = let
      commonAutoMountOptions = {
        wantedBy = [ "multi-user.target" ];
        automountConfig = { TimeoutIdleSec = "600"; };
      };
    in [ (commonAutoMountOptions // { where = "/mnt/ex-ssd"; }) ];
  };

  swapDevices = [{
    device = "/var/lib/swapfile";
    size = 32 * 1024; # 32 GiB
  }];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp0s31f6.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp4s0.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware = {
    cpu.intel.updateMicrocode =
      lib.mkDefault config.hardware.enableRedistributableFirmware;

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

      # Required for proper GPU release during shutdown, especially after
      # a prior Windows boot which leaves the GPU in an unexpected state.
      powerManagement.enable = true;
      powerManagement.finegrained = false;

      nvidiaSettings = true;

      package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
    };

    bluetooth.enable = true;
  };

  services = {
    rpcbind.enable = true;
    xserver.videoDrivers = [ "nvidia" ];
  };
}
