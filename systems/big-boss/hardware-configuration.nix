{
  config,
  lib,
  pkgs,
  modulesPath,
  IP,
  PATHS,
  ...
}:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot = {
    initrd.availableKernelModules = [
      "xhci_pci"
      "ahci"
      "nvme"
      "usbhid"
      "usb_storage"
      "sd_mod"
    ];

    initrd.kernelModules = [ ];

    kernelModules = [
      "kvm-intel"
      "nvidia"
      "nvidia_modeset"
      "nvidia_uvm"
      "nvidia_drm"
    ];

    kernelParams = [
      "nvidia_drm.modeset=1"
      "nvidia_drm.fbdev=1"
      "reboot=force"
    ];

    extraModulePackages = [ ];

    supportedFilesystems = [
      "nfs"
      "ntfs"
    ];

    loader = {
      systemd-boot = {
        enable = true;
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

    mounts =
      let
        commonMountOptions = {
          type = "nfs";
          mountConfig = {
            # The share is optional: o700 may be down, or its external SSD
            # unplugged. Both cases must fail fast rather than block.
            #
            #   retry=0  mount.nfs otherwise keeps retrying in the background
            #            for two minutes before giving up, which is what stalls
            #            the first access to an unreachable server.
            #   soft     bounds runtime I/O too: if the server disappears after
            #            mounting, callers get EIO instead of parking in
            #            uninterruptible sleep forever. Safe here because this
            #            is a read-mostly media share, not a database.
            #   timeo    deciseconds, so 5s per RPC attempt, 2 retries.
            Options = "noatime,soft,retry=0,timeo=50,retrans=2";
            # Caps the whole mount attempt, including a server that accepts the
            # connection but then never answers.
            TimeoutSec = "10s";
          };
        };
      in
      [
        (
          commonMountOptions
          // {
            what = "${IP.o700}:${PATHS.EX-SSD}";
            where = PATHS.EX-SSD;
          }
        )
      ];

    automounts =
      let
        commonAutoMountOptions = {
          wantedBy = [ "multi-user.target" ];
          automountConfig = {
            TimeoutIdleSec = "600";
          };
        };
      in
      [ (commonAutoMountOptions // { where = PATHS.EX-SSD; }) ];
  };

  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 32 * 1024; # 32 GiB
    }
  ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp0s31f6.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp4s0.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware = {
    cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

    graphics = {
      enable = true;

      package = pkgs.mesa;

      # VA-API
      extraPackages = with pkgs; [ nvidia-vaapi-driver ];
    };

    nvidia = {
      modesetting.enable = true;

      open = false; # nvidia open source kernel module, for 20 series and up only.

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

  security.rtkit.enable = true;
}
