{
  IP,
  PORTS,
  PATHS,
  DOMAIN,
  MEDIA_GROUP,
  ...
}:
{
  services = {
    # Bazarr (subtitle fetching for the Arr stack) is deliberately absent: it
    # was never used, and it is not free to leave running -- ~111 threads and
    # the memory that implies, held whether or not anything ever asks it for a
    # subtitle. An unused daemon with a standing cost is the cheapest thing on
    # this host to remove.
    #
    # Four places changed, so re-adding it means restoring all four: this
    # block, a seta.bazarr proxy, PORTS.BAZARR in STATIC_GLOBAL_VARS.nix, and
    # its RequiresMountsFor entry in hardware-configuration.nix.

    prowlarr = {
      enable = true;
      settings.server.port = PORTS.PROWLARR;
      # The servarr default is bindaddress "*". Loopback so caddy is the only
      # path in, leaving the firewall as a second independent layer rather than
      # the only thing between these and the network. Note `settings` is a
      # freeform attrset: a misspelling here is accepted silently and does
      # nothing, so confirm with `ss -ltnp` after the first rebuild.
      settings.server.bindaddress = "127.0.0.1";
    };

    qbittorrent = {
      enable = true;
      group = MEDIA_GROUP;
      webuiPort = PORTS.QBITTORRENT;
      # Pinned rather than left to qBittorrent's random choice so that the
      # single port opened in the firewall is the one it actually listens on.
      torrentingPort = PORTS.QBITTORRENT_TORRENT;
    };

    radarr = {
      enable = true;
      group = MEDIA_GROUP;
      settings.server.port = PORTS.RADARR;
      settings.server.bindaddress = "127.0.0.1";
    };

    sonarr = {
      enable = true;
      group = MEDIA_GROUP;
      settings.server.port = PORTS.SONARR;
      settings.server.bindaddress = "127.0.0.1";
    };

    dnsmasq = {
      enable = true;

      # Leave /etc/resolv.conf alone: systemd-resolved keeps it pointed at
      # its loopback stub. Setting this true would have resolvconf fight
      # resolved over the same file. This host is instead pointed at dnsmasq
      # explicitly, via systemd.network in networking.nix.
      resolveLocalQueries = false;

      settings = {
        # Bind explicit addresses rather than the interface. enp4s0 also
        # carries globally routable IPv6 addresses, so binding the interface
        # would put an open resolver on a public address -- reliably
        # discovered and abused for DNS amplification. The firewall scopes
        # port 53 to the LAN CIDR on top of this; neither layer is trusted
        # alone. bind-dynamic (rather than bind-interfaces) tolerates the
        # address not existing yet at boot, since it arrives via DHCP.
        #
        # Loopback is listed so this host can reach its own resolver without
        # depending on the DHCP lease: systemd-resolved is pointed at
        # 127.0.0.1 (see systemd.network in networking.nix). resolved's own
        # stub occupies 127.0.0.53/127.0.0.54, not .1, so there is no
        # conflict.
        listen-address = [
          IP.o700
          "127.0.0.1"
        ];
        bind-dynamic = true;

        # Wildcard: every name under the zone resolves to this host, matching
        # how a wildcard TLS certificate will later cover the same names.
        # Adding a service then needs no DNS change at all.
        address = [
          "/${DOMAIN}/${IP.o700}"
          # Returning NXDOMAIN for this name is the signal Firefox uses to
          # disable DNS-over-HTTPS on "canary" networks. Without it, Firefox
          # bypasses dnsmasq entirely regardless of DHCP settings.
          "/use-application-dns.net/"
        ];

        # address= above only ever creates an A record. Since dnsmasq 2.86 a
        # query for any *other* RR type against a matched domain is forwarded
        # upstream instead of answered NODATA, so every AAAA lookup for an
        # internal name was being sent to the router -- disclosing the whole
        # service inventory and costing a round trip to learn nothing. local=
        # marks the zone as ours and answers it from local data only. The
        # man page names this exact pairing as the fix.
        #
        # Not needed for use-application-dns.net: an address= with no address
        # returns NXDOMAIN for every RR type already.
        local = "/${DOMAIN}/";

        # Split upstream. The router stays authoritative for "home": it hands
        # that domain out as DHCP option 15 and answers from its lease table,
        # so big-boss.home resolves there and nowhere else -- a public
        # resolver returns NXDOMAIN for it. Every LAN client resolves through
        # this host, so forwarding "home" anywhere else breaks name lookups
        # network-wide, not just here.
        #
        # Everything else goes to the local DoH proxy. This supersedes the
        # old "keep the query on the LAN so it survives a block on outbound
        # 53" reasoning: DoH rides 443, which survives that at least as well.
        no-resolv = true;
        server = [
          "/home/${IP.router}"
          "127.0.0.1#${toString PORTS.DNSCRYPT}"
        ];

        cache-size = 1000;
        domain-needed = true;
        bogus-priv = true;

        # Query log routed to a file rather than the journal. At LAN scale this
        # is thousands of entries per hour, and the journal is now the log store
        # itself rather than a staging area -- entries aging out of the 10G cap
        # in monitoring.nix are gone outright, and fail2ban reads that same
        # journal, so crowding it out costs bans rather than just history.
        #
        # log-facility alone would only move the destination; log-queries is
        # what enables the logging at all, and dnsmasq defaults it off. Both are
        # needed. The file is there for debugging strange client behaviour, and
        # for answering "did this host resolve X" after the fact:
        #   journalctl -f --file /var/log/dnsmasq/queries.log  (or just tail)
        log-queries = true;
        log-facility = "/var/log/dnsmasq/queries.log";
      };
    };

    dnscrypt-proxy = {
      enable = true;

      settings = {
        listen_addresses = [ "127.0.0.1:${toString PORTS.DNSCRYPT}" ];
        server_names = [ "cloudflare" ];

        # DoH specifically, not DNSCrypt. DNSCrypt runs over its own UDP
        # protocol, which defeats the point of looking like ordinary HTTPS.
        doh_servers = true;
        dnscrypt_servers = false;

        # Selects the transport used to reach the resolver, and has no
        # bearing on whether AAAA records come back. IPv4 only keeps the
        # path predictable.
        ipv6_servers = false;

        # dnsmasq already caches 1000 entries in front of this, so a second
        # cache underneath it only adds somewhere for stale answers to hide.
        cache = false;

        # Resolves a real startup deadlock. This proxy has to look up
        # cloudflare-dns.com (and fetch the resolver list) before it can
        # serve anything, but the system resolver path is
        # resolved -> dnsmasq -> this proxy, which is not listening yet.
        # ignore_system_dns forces the router below to be used instead.
        ignore_system_dns = true;
        bootstrap_resolvers = [ "${IP.router}:53" ];
      };
    };
  };

  seta = {
    prowlarr = {
      proxy = {
        enable = true;
        port = PORTS.PROWLARR;
        domain = "prowlarr-internal.${DOMAIN}";
        exposure = "NONE";
      };
    };

    qbittorrent = {
      proxy = {
        enable = true;
        port = PORTS.QBITTORRENT;
        domain = "qbit-internal.${DOMAIN}";
        exposure = "NONE";
        config = ''
          reverse_proxy localhost:${toString PORTS.QBITTORRENT} {
            header_up Host localhost:${toString PORTS.QBITTORRENT}
            header_up -Origin
            header_up -Referer
          }
        '';
      };
    };

    radarr = {
      proxy = {
        enable = true;
        port = PORTS.RADARR;
        domain = "radarr-internal.${DOMAIN}";
        exposure = "NONE";
      };
    };

    sonarr = {
      proxy = {
        enable = true;
        port = PORTS.SONARR;
        domain = "sonarr-internal.${DOMAIN}";
        exposure = "NONE";
      };
    };
  };

  # +-----------------------------------------------------------------+
  # | Additional configurations that are required for these services. |
  # +-----------------------------------------------------------------+

  systemd = {
    tmpfiles.rules = [
      # dnsmasq log directory. dnsmasq drops privileges to the dnsmasq user
      # (--user=dnsmasq in its ExecStart) after binding ports; the log file
      # must therefore be writable by that user.
      "d /var/log/dnsmasq 0750 dnsmasq dnsmasq - -"

      # Folders required for the RR media stack.
      "d ${PATHS.MEDIA_ROOT}                     2775 root        ${MEDIA_GROUP} - -"
      "d ${PATHS.MEDIA_ROOT}/torrents            2775 qbittorrent ${MEDIA_GROUP} - -"
      "d ${PATHS.MEDIA_ROOT}/torrents/incomplete 2775 qbittorrent ${MEDIA_GROUP} - -"
      "d ${PATHS.MEDIA_ROOT}/torrents/tv         2775 qbittorrent ${MEDIA_GROUP} - -"
      "d ${PATHS.MEDIA_ROOT}/torrents/movies     2775 qbittorrent ${MEDIA_GROUP} - -"
      "d ${PATHS.MEDIA_ROOT}/library             2775 root        ${MEDIA_GROUP} - -"
      "d ${PATHS.MEDIA_ROOT}/library/tv          2775 root        ${MEDIA_GROUP} - -"
      "d ${PATHS.MEDIA_ROOT}/library/movies      2775 root        ${MEDIA_GROUP} - -"
    ];

    services = {
      # Ordering only, and best-effort at that: dnscrypt-proxy is Type=simple, so
      # "started" means the process exists, not that it is answering yet.
      # Deliberately not a Requires -- if the proxy is dead, dnsmasq must still
      # come up to serve the o700.net zone and the "home" forwards.
      dnsmasq.after = [ "dnscrypt-proxy.service" ];
    };
  };
}
