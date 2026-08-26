{
  config,
  lib,
  PATHS,
  MEDIA_GROUP,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot = {
    initrd.availableKernelModules = [
      "xhci_pci"
      "ehci_pci"
      "ahci"
      "usbhid"
      "sd_mod"
    ];

    kernelModules = [ "kvm-intel" ];

    # Load the NVIDIA modules early so that udev rules (which create
    # /dev/nvidia*, /dev/nvidia-uvm, etc.) fire before any service starts.
    # nvidia_uvm is intentionally omitted here: the nvidia module sets a
    # softdep so it loads automatically after nvidia via modprobe, which is
    # the correct ordering on non-NVLink hardware.
    initrd.kernelModules = [
      "nvidia"
      "nvidia_modeset"
      "nvidia_drm"
    ];

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

    # The external SSD is removable, so the mount must be optional. Without
    # "nofail" a missing drive fails local-fs.target and drops the machine
    # into rescue mode, where sshd never starts -- unrecoverable remotely.
    # The device timeout caps systemd's default 90s wait for a device that
    # isn't coming back.
    ${PATHS.EX-SSD} = {
      device = "/dev/disk/by-uuid/b7df9669-1d68-44c6-988d-a410ba030953";
      fsType = "ext4";
      options = [
        "nofail"
        "x-systemd.device-timeout=10s"
      ];
    };
  };

  # Deliberately empty, and it must stay that way unless the storage layout
  # changes. A 16 GiB swapfile lived at /var/lib/swapfile between 3576421 and
  # 2026-08-23. /var is on /, so that put the paging path on the 7200 RPM
  # spindle that also carries /nix/store.
  #
  # The failure mode: qBittorrent writing to the external SSD at 80+ MiB/s
  # fills the page cache, and at the default vm.swappiness of 60 the kernel
  # answers that pressure by evicting cold anonymous pages -- on an otherwise
  # idle server, that is sshd's listener, PAM and the login path. Faulting
  # them back in is 4K random reads from a spindle, which measured 6.2s of
  # disk backlog and 40% iowait while the disk moved only 1.6 MB/s. It
  # presented as "the host is unreachable during downloads", and it took the
  # NIC down with it: no free pages to allocate skbs into means the RX ring
  # stops being refilled, so ~10k FIFO errors and 110 TCP resets/s were
  # downstream of this, not separate faults.
  #
  # With no swap the kernel's only reclaim target is clean page cache, which
  # is free to drop and keeps sshd resident by construction. Confirmed by
  # differential test: swap off, same download, 80 MiB/s sustained with every
  # service responsive.
  #
  # It was added as part of the VictoriaMetrics/VictoriaLogs/Vector rewrite,
  # presumably for that stack's headroom. The stack was removed in d4290cc;
  # the swapfile outlived its reason by two days. If an overflow reserve is
  # ever genuinely needed, zram is the option that does not touch this disk --
  # anything backed by the spindle reintroduces exactly the above.
  swapDevices = [ ];

  systemd = {
    # The external SSD is shared by Jellyfin and the media stack. Its
    # mount-point must be root-owned, otherwise
    # systemd-tmpfiles refuses to create anything beneath it ("unsafe path
    # transition") whenever a regular user owns the mount-point. It stays
    # group-writable by "media" so the human user can still manage the drive.
    tmpfiles.rules = [ "d ${PATHS.EX-SSD} 2775 root ${MEDIA_GROUP} - -" ];

    settings.Manager.RebootWatchdogSec = "0";

    # "nofail" keeps the machine booting, but every consumer of the SSD must
    # then refuse to start when the drive is absent -- otherwise they run
    # against the bare mount-point on the root filesystem. Jellyfin would
    # re-import an empty library and orphan all watch history, the Arr stack
    # would see its entire library as deleted, and the Vaultwarden backups
    # would silently fill the root disk. Not starting is the graceful outcome.
    #
    # RequiresMountsFor pulls in the .mount unit and orders after it, so these
    # fail within the device timeout rather than hanging.
    #
    # The service half of this list is now derived from seta.<svc>.requiresExSSD
    # rather than restated here, so adding a service to the media stack cannot
    # leave it half-wired. infraRequiresExSSD is the escape hatch for units that
    # have no seta entry at all -- seta is keyed by *service*, and this one is
    # infrastructure.
    services =
      let
        infraRequiresExSSD = [];

        setaRequiresExSSD = lib.concatMap (meta: meta.units) (
          builtins.filter (meta: meta.requiresExSSD) (builtins.attrValues config.seta)
        );
      in
      lib.genAttrs (lib.unique (infraRequiresExSSD ++ setaRequiresExSSD)) (_: {
        unitConfig.RequiresMountsFor = PATHS.EX-SSD;
      });
  };

  nixpkgs = {
    hostPlatform = lib.mkDefault "x86_64-linux";

    config.problems.handlers.nvidia-x11.broken = "ignore";
    config.problems.handlers.nvidia-kernel-modules.broken = "ignore";
  };

  hardware = {
    cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

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

    logind.settings.Login = {
      HandleLidSwitch = "ignore";
      HandleLidSwitchDocked = "ignore";
    };

  };

  security.rtkit.enable = true;
}
