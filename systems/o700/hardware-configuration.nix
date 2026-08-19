{ config, lib, o700-IP, big-boss-IP, modulesPath, pkgs, ... }: {
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

    # The external SSD is removable, so the mount must be optional. Without
    # "nofail" a missing drive fails local-fs.target and drops the machine
    # into rescue mode, where sshd never starts -- unrecoverable remotely.
    # The device timeout caps systemd's default 90s wait for a device that
    # isn't coming back.
    "/mnt/ex-ssd" = {
      device = "/dev/disk/by-uuid/b7df9669-1d68-44c6-988d-a410ba030953";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.device-timeout=10s" ];
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

    # "nofail" keeps the machine booting, but every consumer of the SSD must
    # then refuse to start when the drive is absent -- otherwise they run
    # against the bare mount-point on the root filesystem. Jellyfin would
    # re-import an empty library and orphan all watch history, the Arr stack
    # would see its entire library as deleted, and the Vaultwarden backups
    # would silently fill the root disk. Not starting is the graceful outcome.
    #
    # RequiresMountsFor pulls in the .mount unit and orders after it, so these
    # fail within the device timeout rather than hanging.
    services = lib.genAttrs [
      "jellyfin"
      "sonarr"
      "radarr"
      "bazarr"
      "qbittorrent"
      "backup-vaultwarden"
      # There is exactly one export and it lives on the SSD. Refusing to start
      # beats exporting the empty mount-point: clients get a connection
      # refused immediately instead of mounting a plausible-looking empty tree.
      "nfs-server"
    ] (_: { unitConfig.RequiresMountsFor = "/mnt/ex-ssd"; });

    network.networks."10-ethernet" = {
      matchConfig.Type = "ether";

      networkConfig = {
        DHCP = "ipv4";
        MulticastDNS = true;

        # Resolve via the local dnsmasq over loopback. Previously nothing here
        # said so: the router happened to advertise 192.168.1.108 over DHCP, so
        # the host reached its own resolver by hairpinning off its LAN address.
        # That made o700's resolution depend on the router's DHCP settings, and
        # broke it before the lease arrived. Loopback has neither problem.
        DNS = [ "127.0.0.1" ];

        # "~." is a routing-only domain (no effect on the search list) that makes
        # this link the resolver for every query, so docker0 or wlp5s0 cannot
        # claim one by acquiring a DNS server of their own later.
        Domains = [ "~." ];
      };

      dhcpV4Config.RequestAddress = o700-IP;

      # The router advertises itself as a resolver twice over -- DHCP option 6
      # and IPv6 RA (fe80::1). resolved ranked both as peers of dnsmasq and
      # would fail over to them, at which point the o700.net zone silently
      # stops resolving on the host itself. Refuse both.
      dhcpV4Config.UseDNS = false;
      dhcpV6Config.UseDNS = false;
      ipv6AcceptRAConfig.UseDNS = false;
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

      # resolved only consults FallbackDNS when *no* DNS server is configured,
      # so it can never rescue a dnsmasq outage -- all it can do is mask a
      # misconfiguration by quietly shipping queries to Cloudflare and Google
      # instead. Empty turns that silent bypass into a visible failure.
      settings.Resolve.FallbackDNS = [ ];
    };

    logind.settings.Login = {
      HandleLidSwitch = "ignore";
      HandleLidSwitchDocked = "ignore";
    };

    nfs.server = {
      enable = true;
      # Exported to big-boss alone rather than the whole LAN: sec=sys lets any
      # host that can reach port 2049 claim any UID, so the client list *is*
      # the access control. big-boss holds this address by way of a router
      # reservation, and NetworkManager additionally re-requests its previous
      # lease, so the two must be kept in step -- if it ever lands on a
      # different address the mount fails with an access error.
      #
      # "mountpoint" makes exportfs skip the entry unless /mnt/ex-ssd is an
      # actual mount. It is the second half of the removable-drive handling:
      # if the SSD is ever unmounted while nfs-server is already up, clients
      # get an access error instead of silently reading an empty directory
      # and concluding the library was deleted.
      exports = ''
        /mnt/ex-ssd ${big-boss-IP}(rw,sync,no_subtree_check,mountpoint)
      '';
    };
  };

}
