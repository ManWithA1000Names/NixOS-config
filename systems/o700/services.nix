{ config, pkgs, lib, o700-IP, router-IP, MEDIA_GROUP, DOMAIN, ... }:
let
  HOMELAB_DASHBOARD_PORT = 8000;

  # Not 5353: systemd-resolved already holds 0.0.0.0:5353 for mDNS, and a
  # 127.0.0.1:5353 bind underneath that wildcard bind fails.
  DOH_PROXY_PORT = 5335;
  toDomain = sub: "${sub}.${DOMAIN}";
  config_args = { inherit toDomain MEDIA_GROUP pkgs; };

  all_services = [
    (import ./services/gitea.nix)
    (import ./services/jellyfin.nix)
    (import ./services/kavita.nix)
    (import ./services/mealie.nix)
    (import ./services/paperless.nix)
    (import ./services/vaultwarden.nix)

    (import ./services/grafana.nix)

    # -- RR stack services
    (import ./services/arr/bazarr.nix)
    (import ./services/arr/prowlarr.nix)
    (import ./services/arr/qbittorrent.nix)
    (import ./services/arr/radarr.nix)
    (import ./services/arr/seerr.nix)
    (import ./services/arr/sonarr.nix)
  ];

in assert (builtins.foldl' (ports: service:
  assert !builtins.hasAttr (builtins.toString service.PORT) ports;
  {
    ${builtins.toString service.PORT} = true;
  } // ports) { ok = true; } all_services).ok;
#
# Define the actual services.<name> options.
#
{

  services = {
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
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
        tls_resolvers 1.1.1.1

        # Per-vhost request rate and status code breakdown. Without per_host,
        # every vhost's requests collapse into one counter and "which service
        # is being hammered" becomes unanswerable -- the only question these
        # metrics are here to answer. per_host adds a `host` label, roughly
        # 15x the HTTP series; at ~15 vhosts that is well under 1k series.
        # Metrics served at localhost:2019/metrics, scraped by VictoriaMetrics
        # (see monitoring/exporters.nix).
        metrics {
          per_host
        }
      '';

      virtualHosts = (builtins.foldl' (hosts: service:
        {
          ${toDomain service.SUB-DOMAIN}.extraConfig =
            if service ? "CADDY_EXTRA_CONFIG" then
              service.CADDY_EXTRA_CONFIG
            else
              "reverse_proxy localhost:${builtins.toString service.PORT}";
        } // hosts) { } all_services) // {
          ${DOMAIN}.extraConfig = "reverse_proxy localhost:${
              builtins.toString HOMELAB_DASHBOARD_PORT
            }";

          # Exists purely so caddy manages a wildcard cert. Caddy skips
          # per-name certs for any subject a managed wildcard covers, so all
          # service hosts above share this one cert. Exact hosts still win
          # at routing time; this only catches subdomains with no service.
          "*.${DOMAIN}".extraConfig = "respond 404";
        };
    };

    homepage-dashboard = {
      enable = true;
      listenPort = HOMELAB_DASHBOARD_PORT;

      settings.title = "o700";

      widgets = [
        {
          resources = {
            cpu = true;
            memory = true;
            disk = "/mnt/ex-ssd";
          };
        }
        {
          search = {
            provider = "duckduckgo";
            target = "_blank";
          };
        }
      ];

      services = let grouped = builtins.groupBy (s: s.GROUP) all_services;
      in builtins.attrValues (builtins.mapAttrs (group: svcs: {
        ${group} = map (s: {
          ${s.NAME} = {
            href = "https://${toDomain s.SUB-DOMAIN}";
            icon = s.ICON;
            description = s.DESCRIPTION;
          };
        }) svcs;
      }) grouped);
    };

    dnsmasq = {
      enable = true;

      # Leave /etc/resolv.conf alone: systemd-resolved keeps it pointed at
      # its loopback stub. Setting this true would have resolvconf fight
      # resolved over the same file. This host is instead pointed at dnsmasq
      # explicitly, via systemd.network in hardware-configuration.nix.
      resolveLocalQueries = false;

      settings = {
        # Bind explicit addresses rather than the interface. enp4s0 also
        # carries globally routable IPv6 addresses and this host runs with
        # networking.firewall.enable = false, so binding the interface would
        # expose an open resolver to the internet -- reliably discovered and
        # abused for DNS amplification. bind-dynamic (rather than
        # bind-interfaces) tolerates the address not existing yet at boot,
        # since it arrives via DHCP.
        #
        # Loopback is listed so this host can reach its own resolver without
        # depending on the DHCP lease: systemd-resolved is pointed at
        # 127.0.0.1 (see systemd.network in hardware-configuration.nix).
        # resolved's own stub occupies 127.0.0.53/127.0.0.54, not .1, so
        # there is no conflict.
        listen-address = [ o700-IP "127.0.0.1" ];
        bind-dynamic = true;

        # Wildcard: every name under the zone resolves to this host, matching
        # how a wildcard TLS certificate will later cover the same names.
        # Adding a service then needs no DNS change at all.
        address = [
          "/${DOMAIN}/${o700-IP}"
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
          "/home/${router-IP}"
          "127.0.0.1#${builtins.toString DOH_PROXY_PORT}"
        ];

        cache-size = 1000;
        domain-needed = true;
        bogus-priv = true;

        # Query log routed to a file rather than the journal. At LAN scale
        # this is thousands of entries per hour; shipping them through the
        # journal to VictoriaLogs would dominate its retention budget. The
        # file is still there for debugging strange client behaviour:
        #   journalctl -f --file /var/log/dnsmasq/queries.log  (or just tail)
        log-queries = true;
        log-facility = "/var/log/dnsmasq/queries.log";
      };
    };

    # The DoH half of the resolver. dnsmasq forwards everything that is not
    # local to this, and it re-issues the query inside HTTPS so the ISP sees
    # only a TLS session to Cloudflare. Note this encrypts exactly one hop:
    # LAN clients still reach dnsmasq over plaintext UDP 53.
    dnscrypt-proxy = {
      enable = true;

      settings = {
        listen_addresses = [ "127.0.0.1:${builtins.toString DOH_PROXY_PORT}" ];
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
        bootstrap_resolvers = [ "${router-IP}:53" ];
      };
    };

  } // (builtins.foldl' (configs: service:
    {
      ${service.SERVICE} = service.config config_args;
    } // configs) { } all_services);

  systemd.tmpfiles.rules = [
    # dnsmasq log directory. dnsmasq drops privileges to the dnsmasq user
    # (--user=dnsmasq in its ExecStart) after binding ports; the log file
    # must therefore be writable by that user.
    "d /var/log/dnsmasq 0750 dnsmasq dnsmasq - -"
  ];

  systemd.services = {
    # Ordering only, and best-effort at that: dnscrypt-proxy is Type=simple, so
    # "started" means the process exists, not that it is answering yet.
    # Deliberately not a Requires -- if the proxy is dead, dnsmasq must still
    # come up to serve the o700.net zone and the "home" forwards.
    dnsmasq.after = [ "dnscrypt-proxy.service" ];

    homepage-dashboard.environment.HOMEPAGE_ALLOWED_HOSTS = lib.mkForce
      "${DOMAIN},localhost:${
        builtins.toString HOMELAB_DASHBOARD_PORT
      },127.0.0.1:${builtins.toString HOMELAB_DASHBOARD_PORT}";

    # Mealie's ExecStartPre (init_db) imports the whole application -- fastapi,
    # sqlalchemy, alembic, the scraper stack -- before it opens the SQLite file.
    # That is thousands of small reads with nothing external to block on, so its
    # runtime is bound entirely by page-cache state. Started by hand it takes
    # ~15s off a warm cache; during boot it contends with every other unit here
    # for a cold one and overruns systemd's 90s DefaultTimeoutStartSec, which
    # kills start-pre and fails the unit. Give it headroom, and retry instead of
    # staying dead until somebody notices.
    mealie.serviceConfig = {
      TimeoutStartSec = "10min";
      Restart = "on-failure";
      RestartSec = "15s";
    };
  };

}
