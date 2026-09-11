{ config, lib, ... }:
let
  # The systemd sandboxing baseline, in one place, applied to two populations:
  # the units reached through seta.<svc>.sandbox, and the infrastructure units
  # below that have no seta entry at all. seta is keyed by *service*, and caddy,
  # dnsmasq, tinyproxy and fail2ban are not services in that sense -- the same
  # split monitoring/notify.nix draws, for the same reason.
  #
  # Every value is mkOptionDefault (priority 1500, the same priority an option's
  # own `default` carries), so any module that states a value wins outright.
  # This can therefore only fill gaps, never contradict a module that already
  # thought about the question -- which is what makes it safe to apply to
  # paperless at 0.9 as well as to tinyproxy at 9.2.
  #
  # Deliberately absent from the baseline, each for a concrete reason:
  #
  #   ProtectSystem   Several modules here already set "strict" and the rest
  #                   differ in where they write. A blanket value would either
  #                   be too weak to matter or turn a write outside
  #                   StateDirectory into a startup failure, and which services
  #                   do that cannot be established from the module source
  #                   alone.
  #
  #   UMask=0077      The media stack shares files through MEDIA_GROUP --
  #                   qBittorrent writes what Sonarr hardlinks and Jellyfin
  #                   reads. Making every new file group-unreadable breaks that
  #                   chain, for 0.1 of score.
  #
  #   MemoryDenyWriteExecute
  #                   Breaks every JIT on the host: n8n, seerr and
  #                   homepage-dashboard are Node, kavita and jellyfin are .NET.
  #                   It is worth having for the non-JIT services and should be
  #                   added per-service, after checking, rather than centrally.
  sandboxBaseline =
    cfg:
    lib.mapAttrs (_: lib.mkOptionDefault) {
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";

      RestrictAddressFamilies = cfg.addressFamilies;
      CapabilityBoundingSet = cfg.capabilities;
      SystemCallFilter = cfg.systemCalls;

      # EPERM rather than the default SIGSYS: a filter that turns out to be one
      # syscall too tight then surfaces as a handled error inside the service
      # instead of as an unexplained kill, which is the difference between a
      # log line naming the call and a crash loop naming nothing.
      SystemCallErrorNumber = "EPERM";

      ProtectProc = if cfg.allProcesses then "default" else "invisible";
      ProcSubset = if cfg.allProcesses then "all" else "pid";
    };

  # Infrastructure, which has no seta entry -- caddy, dnsmasq, tinyproxy,
  # dnscrypt-proxy and fail2ban are not "services" in seta's sense. An attrset
  # rather than a list so the warning above can enumerate the same names that
  # are configured here, instead of the two drifting apart.
  #
  # Each deviation from the baseline is a capability the service demonstrably
  # needs, not a guess -- a bounding set that is one capability short fails at
  # start, and four of these five are on the path used to fix it.
  infraSandbox = {
    # Binds :80 and :443 as User=caddy. Its two ambient capabilities come from
    # the unit file shipped inside the package, where
    # config.systemd.services.caddy.serviceConfig cannot see them -- and
    # AmbientCapabilities must be a subset of the bounding set, so naming
    # them here is what keeps them. An empty set takes the site down.
    #
    # CAP_NET_ADMIN is kept because upstream ships it, not because anything
    # in this configuration is known to need it. Dropping it is a plausible
    # further step and a testable one; it is not a change to make blind on
    # the service that terminates TLS for everything.
    caddy = infraDefaults // {
      capabilities = [
        "CAP_NET_BIND_SERVICE"
        "CAP_NET_ADMIN"
      ];
    };

    # The one unit here whose capability set is dictated by the daemon rather
    # than inferred. dnsmasq calls capget() at startup, compares the permitted
    # set against what its configuration needs, and calls die() on a shortfall
    # -- so a bounding set that is one capability short is not a subtle
    # degradation, it is "FAILED to start up" on the LAN's only resolver.
    #
    # Taken from dnsmasq 2.93 src/dnsmasq.c rather than from reasoning about
    # what a DNS server "should" need, after two rounds of getting that wrong:
    #
    #   NET_RAW             Required unconditionally because this unit runs
    #                       with --enable-dbus: the HAVE_DBUS branch at :526
    #                       sets need_cap_net_raw = 1 whenever OPT_DBUS is on.
    #                       Nothing to do with DHCP, which is what the upstream
    #                       comment at :505 talks about and what misled the
    #                       first attempt here. Also needed by any `server=`
    #                       line bound to an interface, which uses
    #                       SO_BINDTODEVICE.
    #   NET_BIND_SERVICE    Port 53, and set by the same dbus branch.
    #   NET_ADMIN           ARP injection on the DHCP paths (:221, :327, :337).
    #                       Not used by this DNS-only configuration; kept
    #                       because the daemon's own checks are configuration
    #                       dependent and this is not the unit to be clever on.
    #   SETUID, SETGID      It drops to --user=dnsmasq itself. systemd is not
    #                       doing the transition, so these are not implied by a
    #                       User= line the way they are everywhere else here.
    #   CHOWN               Read at :559 into have_cap_chown, and used for the
    #                       lease file after privileges are dropped. Also what
    #                       the pre-start's `chown -R dnsmasq` needs.
    #   DAC_OVERRIDE        Not for the daemon: for the ExecStartPre, which runs
    #                       as root and touches /var/lib/dnsmasq, a directory
    #                       owned by dnsmasq from the previous run. Root is
    #                       "other" against 0755, so this is the only thing that
    #                       permits the write. Its absence produced
    #                       "touch: cannot touch ...: Permission denied" and was
    #                       reproduced exactly as a namespace root with the
    #                       capability dropped.
    #   SETPCAP             Kept rather than justified. Reducing one's own
    #                       capabilities through capset() does not require it on
    #                       a current kernel, so this is probably removable --
    #                       but "probably" has now cost two outages here, and
    #                       verifying it is worth more than the 0.0 of score it
    #                       would return.
    #
    # AF_NETLINK is separate from all of that: dnsmasq enumerates interfaces and
    # watches for address changes over a netlink socket. Without it the daemon
    # starts and then cannot see the interface it is meant to answer on.
    dnsmasq = infraDefaults // {
      capabilities = [
        "CAP_NET_BIND_SERVICE"
        "CAP_NET_RAW"
        "CAP_NET_ADMIN"
        "CAP_SETUID"
        "CAP_SETGID"
        "CAP_SETPCAP"
        "CAP_CHOWN"
        "CAP_DAC_OVERRIDE"
      ];
      addressFamilies = infraDefaults.addressFamilies ++ [ "AF_NETLINK" ];
    };

    # The cleanest case on the host: a small C daemon that binds an
    # unprivileged loopback port as User=tinyproxy and needs no capability
    # at all. It was also the worst-scoring service we actually control.
    tinyproxy = infraDefaults;

    # The module sets AmbientCapabilities=CAP_NET_BIND_SERVICE, and ambient
    # must be a subset of the bounding set -- so even though this resolver
    # listens on an unprivileged port here, naming the capability is what
    # keeps the module's own setting from being silently voided.
    dnscrypt-proxy = infraDefaults // {
      capabilities = [ "CAP_NET_BIND_SERVICE" ];
      addressFamilies = infraDefaults.addressFamilies ++ [ "AF_NETLINK" ];
    };

    # The module already sets a bounding set (CAP_AUDIT_READ,
    # CAP_DAC_READ_SEARCH, CAP_NET_ADMIN, CAP_NET_RAW) and ProtectSystem=strict,
    # and those definitions beat mkOptionDefault, so the capability line
    # here is inert by design -- restated only so this reads as a complete
    # list rather than as an omission.
    #
    # AF_NETLINK is the one thing the module does not cover and fail2ban
    # genuinely needs: banning is nftables, and nftables is netlink.
    fail2ban = infraDefaults // {
      capabilities = [
        "CAP_AUDIT_READ"
        "CAP_DAC_READ_SEARCH"
        "CAP_NET_ADMIN"
        "CAP_NET_RAW"
      ];
      addressFamilies = infraDefaults.addressFamilies ++ [ "AF_NETLINK" ];
    };
  };

  # Defaults for a unit with no seta entry, so the infra list below reads as a
  # set of deviations from the baseline rather than restating it.
  infraDefaults = {
    capabilities = [ ];
    addressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
    systemCalls = [ "@system-service" ];
    allProcesses = false;
  };
in
{
  # ---------------------------------------------------------------------------
  # Kernel-level hardening
  #
  # Everything here is the part of the old `profiles/hardened.nix` that was
  # worth keeping, applied one option at a time instead of as a bundle. That
  # profile no longer exists: in this channel it is a mkRemovedOptionModule stub
  # and the 26.05 release notes give the reason -- "more of a grab bag of
  # settings than a cohesive security policy", with breakage and performance
  # costs that are not obvious from the import line. So is `linux_hardened`,
  # removed in the same release for lack of maintenance.
  #
  # The selection rule used here: take the settings whose cost is zero on a
  # headless single-tenant server, and leave the ones that trade real capability
  # for defence against attackers who already have local code execution. What
  # was deliberately NOT taken, and why:
  #
  #   security.lockKernelModules -- blocks module loading after boot. The
  #     external SSD is removable (see fileSystems below), so a drive plugged in
  #     after boot needs its storage path loaded then, and nftables lazy-loads
  #     netfilter modules on ruleset changes. Both fail weeks later, at hotplug
  #     or at the next rebuild, rather than at switch time.
  #
  #   security.allowSimultaneousMultithreading = false -- halves the CPU of a
  #     single-socket home server to defend against cross-thread side channels,
  #     which require local code execution to exploit. At that point there are
  #     larger problems.
  #
  #   kernel.unprivileged_userns_clone = 0 -- a Debian patch rather than a
  #     mainline sysctl; NixOS exposes security.unprivilegedUsernsClone for it.
  #     Turning it off breaks things subtly and buys nothing here.
  #
  #   security.forcePageTableIsolation -- already the kernel default on CPUs
  #     that need it.
  # ---------------------------------------------------------------------------

  # Blocks kexec, so the running kernel image cannot be replaced without a
  # reboot, and adds `nohibernate` -- hibernation is the other way to swap the
  # running kernel. Neither is a capability this host uses: swapDevices is
  # empty (see hardware-configuration.nix) so it could not hibernate anyway.
  security.protectKernelImage = true;

  # A core dump of vaultwarden, postgres or odoo contains every secret those
  # processes hold in memory, and lands on the root spindle -- the disk whose
  # I/O contention has taken this host down twice. Both halves of that are
  # reasons not to write them.
  systemd.coredump.enable = false;

  boot.kernel.sysctl = {
    # --- Network -------------------------------------------------------------
    #
    # Reverse-path filtering is deliberately NOT set here.
    # networking.firewall.checkReversePath installs an nftables rpfilter chain
    # instead, and setting the sysctl as well applies two independent filters
    # with different semantics to the same packets.
    #
    # This host has a globally routable IPv6 address on the same NIC as the LAN
    # (see the extraInputRules comment in networking.nix), so the v6 halves of
    # these are not theoretical.

    # ICMP redirects let an off-path peer rewrite this host's routing table.
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.secure_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;

    # Source routing lets the sender pick the return path, which defeats every
    # source-address check in the firewall -- including the `ip saddr` scoping
    # that is the only thing keeping sshd and dnsmasq off the v6 internet.
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;

    # Not a router. Sending redirects is only meaningful for one.
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;

    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.tcp_syncookies" = 1;

    # net.ipv6.conf.*.accept_ra is untouched on purpose: this host takes its
    # global IPv6 address from router advertisements (see ipv6AcceptRAConfig in
    # networking.nix). Setting it to 0 removes the address.

    # --- Kernel --------------------------------------------------------------

    # Raised from the NixOS default of 1. At 2, /proc and dmesg hide kernel
    # pointers from every user including root -- which is what an exploit needs
    # in order to defeat KASLR once it has a foothold.
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;

    # 1 = a process may only ptrace its own descendants. This is the one that
    # matters most on this host: without it, any process running as a given
    # service's user can read that service's memory, and every secret agenix
    # delivers ends up there. 2 and 3 are stricter but break debugging.
    "kernel.yama.ptrace_scope" = 1;

    # Neither affects root-loaded programs, so netdata's ebpf plugin and
    # systemd's IPAddressDeny filters (which every seta service uses) keep
    # working. bpf_jit_harden blinds constants in JITed programs, which is a
    # throughput cost on that fast path -- worth watching on this hardware, and
    # the first thing to drop if BPF shows up as a cost.
    "kernel.unprivileged_bpf_disabled" = 1;
    "net.core.bpf_jit_harden" = 2;

    # --- Filesystem ----------------------------------------------------------
    #
    # All four close the classic symlink/hardlink/FIFO races in world-writable
    # directories -- which on this host means /tmp, now that it is cleaned on
    # boot rather than accumulating forever.
    "fs.protected_hardlinks" = 1;
    "fs.protected_symlinks" = 1;
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;

    "vm.unprivileged_userfaultfd" = 0;
  };

  # Four protocol stacks with a long CVE history that nothing on this host
  # speaks, plus filesystems nothing here mounts. Each one is an autoloadable
  # module, which means a single unprivileged socket() call is enough to pull
  # its parser into the kernel.
  #
  # NOT blacklisted, deliberately:
  #
  #   usb_storage -- /mnt/ex-ssd is removable, and it carries the restic
  #     repository, every backup and the whole media library. Blacklisting this
  #     is lynis USB-1000's suggestion and it would silently take all of that
  #     away at the next boot: `nofail` means the machine comes up looking
  #     healthy while requiresExSSD refuses to start half the stack.
  #
  #   squashfs -- how any AppImage or mounted ISO works. Fails at mount time,
  #     long after the decision, rather than at eval time.
  boot.blacklistedKernelModules = [
    "dccp"
    "sctp"
    "rds"
    "tipc"
    "cramfs"
    "freevxfs"
    "jffs2"
    "hfs"
    "hfsplus"
    "udf"
  ];

  # /tmp is on the root filesystem and nothing has ever cleared it. Not tmpfs:
  # that trades disk for RAM on a host with neither to spare and no swap to
  # fall back on (swapDevices is empty and must stay that way).
  boot.tmp.cleanOnBoot = true;

  # lynis NAME-4028. The host has a hostName but no domain, so `hostname -d`
  # answers nothing and the FQDN is just "o700" -- on the machine that is
  # authoritative for this zone.
  networking.domain = "o700.net";

  # lynis HRDN-7222. The NixOS default set drops perl, rsync, strace and nano
  # into the system PATH of a WAN-facing host for no function this
  # configuration uses. gcc/gnumake/python3 are handled separately, by keeping
  # them out of systems/common/programs.nix -- closures are built on big-boss
  # and pushed (see the justfile), and Nix builds use the store's toolchain
  # rather than environment.systemPackages, so nothing here needs to compile.
  environment.defaultPackages = lib.mkForce [ ];

  # ---------------------------------------------------------------------------
  # Applying the baseline
  # ---------------------------------------------------------------------------

  # A unit that runs as root and has an empty CapabilityBoundingSet has lost
  # root's DAC override, so every file operation it performs against something
  # it does not own fails -- and fails as a plain "Permission denied" that looks
  # like a broken path rather than like a capability problem. dnsmasq cost a DNS
  # outage to learn this, because its pre-start runs as root, chowns its state
  # directory to the dnsmasq user, and then has to write into it again next
  # start.
  #
  # A warning rather than an assertion: a root unit that only touches root-owned
  # files is genuinely fine with no capabilities, and refusing to build would be
  # wrong for it. What is not fine is finding out at 11:09 on a Friday.
  #
  # Reads serviceConfig, so it sees User=/DynamicUser= however the module spells
  # them -- including the modules that set DynamicUser as the string "true",
  # which a plain `== true` would miss.
  warnings =
    let
      runsAsRoot =
        unit:
        let
          sc = config.systemd.services.${unit}.serviceConfig or { };
          dynamic = sc.DynamicUser or false;
        in
        !(sc ? User) && dynamic != true && dynamic != "true" && dynamic != "yes";

      unprivileged =
        unit: (config.systemd.services.${unit}.serviceConfig.CapabilityBoundingSet or null) == [ ];

      candidates = lib.unique (
        (builtins.concatMap (m: m.units) (
          builtins.filter (m: m.sandbox.enable) (builtins.attrValues config.seta)
        ))
        ++ builtins.attrNames infraSandbox
      );

      exposed = builtins.filter (
        u: (config.systemd.services ? ${u}) && runsAsRoot u && unprivileged u
      ) candidates;
    in
    lib.optional (exposed != [ ]) ''
      These units run as root under the sandboxing baseline with an empty CapabilityBoundingSet:

        ${lib.concatStringsSep "\n  " exposed}

      Root without CAP_DAC_OVERRIDE cannot write to a file or directory it does not own, and
      root without CAP_CHOWN cannot hand one to a service user. Both surface as "Permission
      denied" from the unit's own ExecStartPre, which reads like a wrong path.

      Check what each unit does before it drops privileges -- a pre-start that creates or
      chowns a state directory is the usual case -- and name the capabilities it needs in
      seta.<svc>.sandbox.capabilities, or in the infra list in this file.
    '';

  systemd.services = lib.mkMerge (
    # Every seta service that has not opted out.
    (map (
      meta:
      lib.genAttrs meta.units (_: {
        serviceConfig = sandboxBaseline meta.sandbox;
      })
    ) (builtins.filter (meta: meta.sandbox.enable) (builtins.attrValues config.seta)))

    # And the infrastructure units, which have no seta entry to carry it.
    ++ (lib.mapAttrsToList (unit: cfg: { ${unit}.serviceConfig = sandboxBaseline cfg; }) infraSandbox)
  );
}
