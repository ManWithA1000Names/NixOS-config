{ config, lib, modulesPath, pkgs, ... }: {
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot = {
    initrd.availableKernelModules =
      [ "xhci_pci" "ehci_pci" "ahci" "usbhid" "sd_mod" ];
    initrd.kernelModules =
      [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];

    kernelModules = [ "kvm-intel" ];

    kernelParams = [ "fsck.mode=force" "fsck.repair=yes" "consoleblank=30" ];

    extraModulePackages = [ ];

    loader = {
      systemd-boot.enable = true;
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
      device = "/dev/disk/by-label/NIXROOT";
      fsType = "ext4";
    };

    "/boot" = {
      device = "/dev/disk/by-label/NIXBOOT";
      fsType = "vfat";
    };

    "/export" = {
      device = "/home/user";
      fsType = "none";
      options = [ "bind" ];
    };

    "/export-ssd" = {
      device = "/mnt/ex-ssd";
      fsType = "none";
      options = [ "bind" ];
    };

    "/mnt/ex-ssd" = {
      device = "/dev/disk/by-uuid/b7df9669-1d68-44c6-988d-a410ba030953";
      fsType = "ext4";
    };
  };

  # The external SSD is shared by Jellyfin, the media stack and the NFS
  # export. Its mount-point must be root-owned, otherwise
  # systemd-tmpfiles refuses to create anything beneath it ("unsafe path
  # transition") whenever a regular user owns the mount-point. It stays
  # group-writable by "media" so the human user can still manage the drive.
  systemd.tmpfiles.rules = [ "d /mnt/ex-ssd 2775 root media - -" ];

  systemd.settings.Manager.RebootWatchdogSec = "0";

  swapDevices = [ ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.docker0.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp4s0.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp5s0.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # nvidia
  hardware = {
    cpu.intel.updateMicrocode =
      lib.mkDefault config.hardware.enableRedistributableFirmware;

    graphics = { enable = true; };

    nvidia = {
      # nvidia open source kernel module, for 20 series and up only.
      open = false;

      nvidiaSettings = true;
      modesetting.enable = true;
      package = config.boot.kernelPackages.nvidiaPackages.legacy_390;

      prime = {
        sync.enable = true;
        intelBusId = "PCI:0:2:0";
        nvidiaBusId = "PCI:1:0:0";
      };
    };
  };

  services = {
    xserver.videoDrivers = [ "nvidia" ];

    logind.settings.Login = {
      HandleLidSwitch = "ignore";
      HandleLidSwitchDocked = "ignore";
    };

    nfs.server = {
      enable = true;
      # The SSD export uses all_squash so that *any* client -- regardless of
      # its local users/groups -- is mapped onto the server's "user" account
      # and "media" group. That account owns the existing data and the media
      # group owns the Arr-stack tree, so every client gets full read/write
      # access without needing a matching UID/GID configured on its end.
      exports = ''
        /export 192.168.1.0/24(rw,sync,no_subtree_check)
        /export-ssd 192.168.1.0/24(rw,sync,no_subtree_check,all_squash,anonuid=${
          toString config.users.users.user.uid
        },anongid=${toString config.users.groups.media.gid})
      '';
    };
  };

}
