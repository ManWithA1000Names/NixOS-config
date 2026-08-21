{
  pkgs,
  lib,
  config,
  IP,
  PORTS,
  PATHS,
  DOMAIN,
  USERNAME,
  ...
}:
let
  # Source ranges permitted to reach a vhost, keyed by seta exposure level.
  # This is where seta.<svc>.proxy.exposure stops being documentation and
  # starts being enforcement.
  #
  # Caddy is the only place this *can* be enforced: every vhost shares port
  # 443, so nftables cannot tell them apart, and the router's DNAT rewrites the
  # destination to this host's LAN address, so `bind` cannot either. remote_ip
  # is the sole discriminator. The firewall remains the second layer -- service
  # ports are absent from allowedTCPPorts, so a direct hit on e.g. :8096 is
  # dropped regardless of what happens here.
  #
  # IP.o700 is present even in NONE. The blackbox prober resolves service names
  # through dnsmasq, which answers with this host's LAN address, so its probes
  # leave and re-enter via that address rather than 127.0.0.1. Omit it and
  # probe_success goes to 0 for every internal service at once, firing
  # ProbeFailed across the whole arr stack -- a monitoring break that presents
  # as a service break. Allowing it widens nothing: that address is this host.
  #
  # IPv4-only for the LAN range, for the same reason IP.lan itself is: this
  # interface also carries globally routable IPv6, so an IPv6 form would match
  # the entire internet. LAN clients resolve internal names through dnsmasq,
  # which answers A records only (local=/o700.net/ makes AAAA return NODATA),
  # so they arrive over IPv4 and match. A LAN device that bypasses dnsmasq --
  # a phone with its own DoH, say -- and connects over IPv6 is treated as WAN.
  vhostSources = {
    NONE = [
      "127.0.0.1/32"
      "::1/128"
      "${IP.o700}/32"
    ];
    LAN = [
      "127.0.0.1/32"
      "::1/128"
      "${IP.o700}/32"
      IP.lan
    ];
    WAN = [ ];
  };

  # Applied to every vhost regardless of exposure. Deliberately excludes a
  # Content-Security-Policy: a useful one has to be written per-application,
  # and a generic one breaks every app behind this proxy.
  securityHeaders = ''
    header {
      # No `preload`. Preloading is baked into browser binaries and takes
      # months to reverse; plain max-age is revocable by lowering it.
      Strict-Transport-Security "max-age=31536000; includeSubDomains"
      X-Content-Type-Options nosniff
      # SAMEORIGIN rather than DENY: Grafana panel embedding and Jellyfin's
      # web client both frame same-origin content, which DENY would break.
      X-Frame-Options SAMEORIGIN
      Referrer-Policy strict-origin-when-cross-origin
      # Caddy sends no version, but no reason to name the software either.
      -Server
    }
  '';

  vhostConfig =
    proxy:
    let
      handler =
        if proxy.config != "" then proxy.config else "reverse_proxy localhost:${toString proxy.port}";

      sources = vhostSources.${proxy.exposure};

      # 404, not 403 -- matching what the wildcard vhost answers for names no
      # service claims. An outside scanner therefore cannot distinguish a
      # LAN-only service from a name that does not exist, where 403 would
      # confirm it is there and worth coming back to. The request is logged
      # either way, so blocked attempts remain visible in VictoriaLogs, and
      # the caddy-scan jail below counts them.
      guard = lib.optionalString (sources != [ ]) ''
        @blocked not remote_ip ${lib.concatStringsSep " " sources}
        respond @blocked 404
      '';
    in
    # `route` wraps the handler so evaluation follows written order. Outside a
    # route block Caddy imposes its own directive order, in which `respond` and
    # `reverse_proxy` have a fixed relative position that is not the one
    # written here -- the guard would be silently bypassed, which is the worst
    # possible failure mode for an access control.
    ''
      ${securityHeaders}
      route {
        ${guard}
        ${handler}
      }
    '';
in
{
  networking = {
    hostName = "o700";
    useNetworkd = true;

    # nftables rather than iptables: extraInputRules is what makes source-CIDR
    # scoping expressible inline. The iptables backend would need extraCommands
    # and raw ip46tables lines. services.fail2ban.banaction follows
    # networking.nftables.enable automatically (defaults to nftables-multiport).
    #
    # IMPORTANT: this is only safe because Docker is disabled on o700. Docker
    # DNAT'd ports bypass the INPUT chain entirely and would silently escape a
    # default-deny INPUT policy. If Docker is ever re-enabled, revisit whether
    # the firewall backend and rule structure need to change.
    nftables.enable = true;
    firewall = {
      enable = true;

      # Reachable from the internet by design.
      allowedTCPPorts = [
        # MUST be in the very first switch that enables this firewall, otherwise
        # the switch locks you out of the only remote administration path.
        PORTS.SSHD
        # Caddy HTTP→HTTPS redirect. ACME uses DNS-01 so port 80 is not needed
        # for certificate issuance, but without it every http:// link to this
        # host times out instead of redirecting gracefully.
        PORTS.CADDY_HTTP
        PORTS.CADDY_HTTPS
        # BitTorrent. Inbound connections are how this peer is reachable by
        # anyone not already connected to it; without the port open qBittorrent
        # still works but only via outbound connections, which caps peer counts
        # and makes it undesirable to trackers. Unlike the WebUI (internal-only,
        # reached through caddy) this one genuinely has to face the internet, so
        # it is listed here rather than via services.qbittorrent.openFirewall --
        # that option would open the WebUI port too.
        PORTS.QBITTORRENT_TORRENT
      ];

      # Caddy enables HTTP/3 by default and advertises it via Alt-Svc. Without
      # UDP/443, browsers accept the advertisement, fail QUIC, then fall back to
      # TCP -- a per-connection stall that shows up as elevated probe_duration_seconds
      # rather than as a visible error.
      allowedUDPPorts = [
        PORTS.CADDY_HTTPS
        # uTP: qBittorrent's default transport is UDP, not TCP. Opening only
        # the TCP port halves reachability in a way that looks like "slow
        # torrents" rather than a firewall problem.
        PORTS.QBITTORRENT_TORRENT
      ];

      # On a WAN-exposed address, logging every refused connection would write
      # every unsolicited SYN from every background internet scanner into the
      # journal -- which is now shipped to VictoriaLogs and counted against its
      # 10 GiB cap. The information content is near zero (the packets were
      # dropped) and the volume dominates every other log source combined.
      # Attack visibility comes from fail2ban's counters, the Fail2banBanBurst
      # alert, and Caddy's access logs instead.
      logRefusedConnections = false;

      extraInputRules = ''
        # --- LAN-only services -------------------------------------------------
        # Source-CIDR scoped, IPv4 only, deliberately. This host has a single NIC:
        # LAN and WAN packets arrive on the same interface (enp4s0), so
        # networking.firewall.interfaces.<name> rules cannot distinguish them.
        # enp4s0 also carries globally routable IPv6 addresses that the router
        # does NOT NAT; any rule that is not explicitly `ip saddr` would expose
        # these services to the internet over IPv6. An open DNS resolver on a
        # public IPv6 address is found within hours and used for amplification.

        # dnsmasq -- authoritative for o700.net and the LAN's only resolver.
        # Without these: every LAN client loses name resolution.
        ip saddr ${IP.lan} udp dport ${toString PORTS.DNSMASQ} accept comment "dnsmasq UDP LAN"
        ip saddr ${IP.lan} tcp dport ${toString PORTS.DNSMASQ} accept comment "dnsmasq TCP LAN (large answers)"

        # mDNS. systemd-resolved has MulticastDNS=yes and the link sets
        # MulticastDNS=true. Without this: o700.local stops resolving and LAN
        # service discovery from other machines breaks.
        ip saddr ${IP.lan} udp dport ${toString PORTS.MDNS} accept comment "mDNS LAN"

        # NFS, exported to exactly one peer. The export line in
        # hardware-configuration.nix already restricts to big-boss, but sec=sys
        # means the client list *is* the access control -- the firewall repeats
        # it rather than trusting a single layer. NFSv4 only (see extraNfsdConfig
        # below), so port 2049 is the entire surface: no rpcbind (111), no mountd,
        # no statd, no lockd. Without this rule the client mount hangs rather than
        # failing -- the most confusing NFS failure mode.
        ip saddr ${IP.big-boss} tcp dport ${toString PORTS.NFS} accept comment "NFS to big-boss"
      '';
    };
  };

  systemd.network.networks."10-ethernet" = {
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

    dhcpV4Config.RequestAddress = IP.o700;

    # The router advertises itself as a resolver twice over -- DHCP option 6
    # and IPv6 RA (fe80::1). resolved ranked both as peers of dnsmasq and
    # would fail over to them, at which point the o700.net zone silently
    # stops resolving on the host itself. Refuse both.
    dhcpV4Config.UseDNS = false;
    dhcpV6Config.UseDNS = false;
    ipv6AcceptRAConfig.UseDNS = false;
  };

  services = {
    resolved = {
      enable = true;
      settings.Resolve.MulticastDNS = "yes";

      # resolved only consults FallbackDNS when *no* DNS server is configured,
      # so it can never rescue a dnsmasq outage -- all it can do is mask a
      # misconfiguration by quietly shipping queries to Cloudflare and Google
      # instead. Empty turns that silent bypass into a visible failure.
      settings.Resolve.FallbackDNS = [ ];
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
        ${PATHS.EX-SSD} ${IP.big-boss}(rw,sync,no_subtree_check,mountpoint)
      '';
    };

    # Force NFSv4-only so the firewall surface is one port (2049) instead of
    # five. NFSv3 additionally requires rpcbind (111) and mountd, statd and
    # lockd on ports that are random unless pinned. If big-boss ever mounts with
    # vers=3 it will fail loudly at mount time, which is the correct outcome.
    #
    # Sits under services.nfs rather than services.nfs.server, and replaces the
    # deprecated extraNfsdConfig: `settings` covers the whole of nfs.conf, and
    # an assertion rejects the two being set together rather than merging them.
    nfs.settings.nfsd.vers3 = false;

    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;

        AllowUsers = [ USERNAME ];
        MaxAuthTries = 3;
        LoginGraceTime = "30s";

        # LogLevel = "VERBOSE" is set by the fail2ban module via mkDefault. It
        # also puts each accepted login's key fingerprint into the journal, which
        # is what makes "somebody logged in with an unrecognised key" answerable.

        # MUST stay yes: ssh -L is the only access path for VictoriaMetrics,
        # VictoriaLogs, Alertmanager, both vmalerts and every exporter.
        AllowTcpForwarding = "yes";
      };
    };

    fail2ban = {
      enable = true;

      bantime = "1h";
      maxretry = 4;

      # Exponential growth: a one-hour first ban means nothing to a botnet that
      # simply tries again. 4x growth capped at 7 days turns sustained attackers
      # into week-long bans while a fat-fingered own password on a first offence
      # still costs only one hour.
      bantime-increment = {
        enable = true;
        maxtime = "7d";
        factor = "4";
        overalljails = true;
      };

      # IP.lan is deliberately NOT here. A compromised or misbehaving LAN
      # device can hammer these services from inside the network exactly as
      # effectively as one outside it, and "the LAN is trusted" is precisely
      # the assumption that makes a foothold there valuable. Jails apply to the
      # LAN like anywhere else.
      #
      # Two exemptions remain. big-boss is the recovery path when the WAN side
      # is misconfigured, and banning it turns a typo into a trip with a
      # keyboard. IP.o700 is this host: the blackbox prober's requests arrive
      # from its own LAN address, so without it a service that answers 404 on /
      # would have the host ban itself inside the hour -- which, with
      # bantime-increment, escalates rather than self-corrects.
      ignoreIP = [
        "127.0.0.0/8"
        "::1"
        IP.o700
        IP.big-boss
      ];

      jails = {
        # backend=systemd is the module's DEFAULT -- the sshd jail reads the
        # journal directly. The fail2ban module also sets
        # services.openssh.settings.LogLevel = "VERBOSE" via mkDefault, which
        # is what makes failed attempts visible in the journal at all.
        sshd.settings = {
          maxretry = 3;
          findtime = "10m";
          # Ban all ports, not just 22. An attacker probing ssh is probing
          # everything; leaving them 443 to hammer serves no purpose.
          action = "%(banaction_allports)s[name=sshd]";
        };

        # Watches Caddy's JSON access logs for repeated 401/403 responses.
        #
        # Reads the journal, because that is now the only place Caddy's access
        # logs exist -- every vhost writes to stderr and nothing writes files.
        # The failregex below is byte-identical to the file-based version; the
        # JSON line is the journal MESSAGE field verbatim.
        #
        # Consequence of the single stream: this jail also sees Caddy's own
        # runtime output and every vhost at once, where the file glob gave one
        # file per vhost. Both regex keys must appear on the same line for a
        # match, and runtime error logs carry neither, so false positives are
        # unlikely -- but a per-vhost ban policy is no longer expressible here.
        caddy-badauth = {
          settings = {
            # backend = "systemd" is the module default, same as the sshd jail.
            journalmatch = "_SYSTEMD_UNIT=caddy.service";
            # Strict. A 401 or 403 is unambiguous -- credentials were presented
            # and rejected -- so there is no innocent explanation for a run of
            # them, unlike the 404s the caddy-scan jail counts.
            maxretry = 4;
            findtime = "10m";
          };
          filter.Definition = {
            # Caddy JSON access log. Anchored on specific JSON keys so the regex
            # fails closed (no match = no ban) if the log format shifts.
            #
            # WARNING: this regex keys on `remote_ip`. The Cloudflare integration
            # here is DNS-only (the token has Zone.DNS:Edit for ACME DNS-01;
            # nothing proxies traffic). If the Cloudflare orange cloud is ever
            # switched on for any record, every request will appear to come from
            # a Cloudflare IP and this jail will ban Cloudflare within minutes,
            # taking the entire site offline. Before enabling proxying: add
            # `trusted_proxies static <cloudflare-ranges>` and
            # `client_ip_headers CF-Connecting-IP` to Caddy's globalConfig and
            # switch the failregex to key on `client_ip`.
            failregex = ''^.*"remote_ip":"<HOST>".*"status":(401|403).*$'';
            ignoreregex = "";
          };
        };

        # Content scanning: sweeping for /wp-login.php, /.env, /admin and the
        # rest. Lenient by design, because a 404 is ambiguous where a 401 is
        # not -- a browser chasing a missing favicon or web manifest produces a
        # handful legitimately, and a single-page app with a stale asset
        # reference can produce more. 40 inside 5 minutes is not a browser.
        #
        # This jail also backs the exposure guard: a request from outside the
        # permitted range for a NONE or LAN vhost is answered 404, so anyone
        # working through internal hostnames from the WAN accumulates hits here
        # and is banned without a separate rule for it.
        caddy-scan = {
          settings = {
            journalmatch = "_SYSTEMD_UNIT=caddy.service";
            maxretry = 40;
            findtime = "5m";
          };
          filter.Definition = {
            # Same remote_ip caveat as caddy-badauth above regarding the
            # Cloudflare orange cloud.
            failregex = ''^.*"remote_ip":"<HOST>".*"status":404.*$'';
            ignoreregex = "";
          };
        };
      };
    };

    caddy = {
      enable = true;

      # Stock caddy has no DNS provider modules compiled in; the ACME DNS-01
      # challenge below is unusable without this plugin.
      package = pkgs.caddy.withPlugins {
        plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
        hash = "sha256-7GoH8YLCoPmPExQxoga2FHB58zQDoZVf1BBwkVi0SsQ=";
      };

      # Read by systemd before the caddy process starts. Must define
      # CF_API_TOKEN (single Cloudflare token: Zone.Zone:Read + Zone.DNS:Edit).
      environmentFile = config.age.secrets.cloudflare-dns-api.path;

      # DNS-01 rather than HTTP-01 because the wildcard below cannot be
      # validated any other way.
      globalConfig = ''
        acme_dns cloudflare {env.CF_API_TOKEN}
        tls_resolvers ${IP.cloudflare-dns}
        metrics { per_host }
      '';

      virtualHosts =
        (builtins.foldl' (
          hosts:
          { proxy, ... }:
          assert !builtins.hasAttr proxy.domain hosts;
          {
            ${proxy.domain} = {
              extraConfig = vhostConfig proxy;

              # Every vhost, unconditionally: stderr -> journal -> Vector ->
              # VictoriaLogs. There is no per-service switch because a request
              # that was not recorded is indistinguishable from one that never
              # happened, which is precisely the gap an attacker benefits from.
              #
              # This string is spliced into a `log { }` block by the caddy
              # module, and it replaces the module's default wholesale. The
              # default is `output file <logDir>/access-<host>.log`, so naming
              # only a format here would silently drop the output directive --
              # hence stating `output stderr` explicitly even though it happens
              # to be caddy's fallback.
              logFormat = ''
                output stderr
                format json
              '';
            };
          }
          // hosts
        ) { } (builtins.filter ({ proxy, ... }: proxy.enable) (builtins.attrValues config.seta)))
        // {
          # Exists purely so caddy manages a wildcard cert. Caddy skips
          # per-name certs for any subject a managed wildcard covers, so every
          # single-label service host above shares this one cert -- which is
          # why seta.<svc>.proxy.domain must stay single-label. The apex is
          # not covered (a wildcard matches exactly one label) and gets its
          # own cert; so would any deeper name. Exact hosts still win at
          # routing time, so this only catches subdomains with no service.
          "*.${DOMAIN}" = {
            extraConfig = ''
              ${securityHeaders}
              respond 404
            '';

            # Must be stated, not inherited. Left at the module default this
            # vhost writes access-*.o700.net.log -- a literal asterisk in the
            # filename. Requests landing here are by definition for names no
            # service claims, which makes them more interesting than average,
            # not less.
            logFormat = ''
              output stderr
              format json
            '';
          };
        };
    };
  };

}
