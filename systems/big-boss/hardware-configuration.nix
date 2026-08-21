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

    # The other half of the NFSv3 machinery turned off alongside rpcbind below.
    # statd is the NSM peer that lets a rebooting client and server recover v3
    # file locks; v4 carries lock state in the protocol itself and never calls
    # it. Both are disabled together because rpc-statd declares
    # `Requires=rpcbind.socket` -- leaving it enabled with rpcbind gone turns
    # it into a unit that fails whenever something pulls it in, and a
    # permanently-red unit is worse than no unit, since it is what trains you
    # to stop reading `systemctl --failed`.
    services.rpc-statd.enable = false;
    services.rpc-statd-notify.enable = false;

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
            #   nfsvers  pinned rather than negotiated, to state the assumption
            #            the other end already enforces: o700 sets
            #            services.nfs.settings.nfsd.vers3 = false, so v3 is not
            #            on offer. Pinning means a server that stops offering
            #            4.2 fails at mount time with a clear error instead of
            #            quietly negotiating down to something that needs
            #            rpcbind -- which is disabled below.
            Options = "noatime,soft,retry=0,timeo=50,retrans=2,nfsvers=4.2";
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
    # mkForce because this is an override, not a setting: the NFS module sets
    # services.rpcbind.enable = true unconditionally whenever NFS support is
    # on (nixos/modules/tasks/filesystems/nfs.nix), so a plain `false` loses
    # the merge and a plain deletion changes nothing at all.
    #
    # rpcbind is the NFSv3 portmapper. v3 needed it to discover the ports for
    # mountd, statd and lockd; NFSv4 folded all of that into a single well-known
    # port 2049 and does not consult it. o700 now refuses v3 outright
    # (services.nfs.settings.nfsd.vers3 = false) and the mount below pins 4.2,
    # so nothing on either end can still want it.
    #
    # Worth removing rather than ignoring because it listened on [::]:111 --
    # on a host with a globally routable IPv6 and, until this commit, no
    # firewall.
    #
    # If the media mount breaks after this, rpcbind is the first thing to
    # suspect: re-enable it and check whether the mount is silently falling
    # back to v3 despite the pin.
    rpcbind.enable = lib.mkForce false;
    xserver.videoDrivers = [ "nvidia" ];
  };

  security.rtkit.enable = true;
}
