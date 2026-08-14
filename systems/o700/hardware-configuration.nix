{ config, lib, o700-IP, modulesPath, pkgs, ... }: {
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot = {
    initrd.availableKernelModules =
      [ "xhci_pci" "ehci_pci" "ahci" "usbhid" "sd_mod" ];
    kernelModules = [ "kvm-intel" ];

    kernelParams = [ "consoleblank=30" ];

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

    "/mnt/ex-ssd" = {
      device = "/dev/disk/by-uuid/b7df9669-1d68-44c6-988d-a410ba030953";
      fsType = "ext4";
    };
  };

  swapDevices = [ ];

  systemd = {
    # The external SSD is shared by Jellyfin, the media stack and the NFS
    # export. Its mount-point must be root-owned, otherwise
    # systemd-tmpfiles refuses to create anything beneath it ("unsafe path
    # transition") whenever a regular user owns the mount-point. It stays
    # group-writable by "media" so the human user can still manage the drive.
    tmpfiles.rules = [ "d /mnt/ex-ssd 2775 root media - -" ];

    settings.Manager.RebootWatchdogSec = "0";

    network.networks."10-ethernet" = {
      matchConfig.Type = "ether";
      networkConfig.DHCP = "ipv4";
      networkConfig.MulticastDNS = true;
      dhcpV4Config.RequestAddress = o700-IP;
    };
  };

  nixpkgs = {
    hostPlatform = lib.mkDefault "x86_64-linux";

    config.problems.handlers.nvidia-x11.broken = "ignore";
    config.problems.handlers.nvidia-kernel-modules.broken = "ignore";
  };

  # Load the NVIDIA modules early so that udev rules (which create
  # /dev/nvidia*, /dev/nvidia-uvm, etc.) fire before any service starts.
  # nvidia_uvm is intentionally omitted here: the nvidia module sets a
  # softdep so it loads automatically after nvidia via modprobe, which is
  # the correct ordering on non-NVLink hardware.
  boot.initrd.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_drm" ];

  hardware = {
    cpu.intel.updateMicrocode =
      lib.mkDefault config.hardware.enableRedistributableFirmware;

    # Required for EGL/render-node access (e.g. ffmpeg -hwaccel cuda,
    # headless OpenGL). Does not start a display server.
    graphics.enable = true;

    nvidia = {
      open = false;
      # Exposes /dev/dri/renderD* so compute clients (ffmpeg, etc.) can
      # reach the GPU without a display. No GLX patch needed headlessly.
      modesetting.enable = true;
      package = config.boot.kernelPackages.nvidiaPackages.legacy_390;
    };
  };

  services = {
    # Activates hardware.nvidia (udev rules, kernel modules, driver libraries)
    # without starting X. services.xserver.enable remains false (default).
    xserver.videoDrivers = [ "nvidia" ];

    resolved = {
      enable = true;
      settings.Resolve.MulticastDNS = "yes";
    };

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
        /mnt/ex-ssd 192.168.1.0/24(rw,sync,no_subtree_check,all_squash,anonuid=${
          toString config.users.users.user.uid
        },anongid=${toString config.users.groups.media.gid})
      '';
    };
  };

}
