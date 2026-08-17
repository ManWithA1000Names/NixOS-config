{ config, pkgs, lib, o700-IP, MEDIA_GROUP, DOMAIN, ... }@args:
let
  ROUTER_IP = "192.168.1.1";
  HOMELAB_DASHBOARD_PORT = 8000;
  toDomain = sub: "${sub}.${DOMAIN}";
  config_args = { inherit toDomain MEDIA_GROUP; };

  all_services = [
    (import ./services/gitea.nix)
    (import ./services/jellyfin.nix)
    (import ./services/kavita.nix)
    (import ./services/mealie.nix)
    (import ./services/paperless.nix)
    (import ./services/vaultwarden.nix)

    # -- RR stack services
    (import ./services/arr/bazarr.nix)
    (import ./services/arr/prowlarr.nix)
    (import ./services/arr/qbittorrent.nix)
    (import ./services/arr/radarr.nix)
    (import ./services/arr/seerr.nix)
    (import ./services/arr/sonarr.nix)
  ];
in (import ./arr-media-stack-tweaks.nix args) // (
  #
  # Assert that all service ports are unique.
  #
  assert (builtins.foldl' (ports: service:
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

        services =
          let
            grouped = builtins.groupBy (s: s.GROUP) all_services;
          in
            builtins.attrValues (builtins.mapAttrs (group: svcs: {
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

          # Upstream is the router, deliberately: the query stays on the LAN, so
          # it survives any future firewall rule that blocks outbound port 53.
          no-resolv = true;
          server = [ ROUTER_IP ];

          cache-size = 1000;
          domain-needed = true;
          bogus-priv = true;

          # Temporary, for the rollout test: records which client asked for
          # what, so bypassing devices can be identified from evidence rather
          # than guessed at. Remove once the DNS path is confirmed working.
          log-queries = true;
        };
      };

    } // (builtins.foldl' (configs: service:
      {
        ${service.SERVICE} = service.config config_args;
      } // configs) { } all_services);

    systemd.services.homepage-dashboard.environment.HOMEPAGE_ALLOWED_HOSTS = lib.mkForce
      "${DOMAIN},localhost:${builtins.toString HOMELAB_DASHBOARD_PORT},127.0.0.1:${builtins.toString HOMELAB_DASHBOARD_PORT}";

    # Mealie's ExecStartPre (init_db) imports the whole application -- fastapi,
    # sqlalchemy, alembic, the scraper stack -- before it opens the SQLite file.
    # That is thousands of small reads with nothing external to block on, so its
    # runtime is bound entirely by page-cache state. Started by hand it takes
    # ~15s off a warm cache; during boot it contends with every other unit here
    # for a cold one and overruns systemd's 90s DefaultTimeoutStartSec, which
    # kills start-pre and fails the unit. Give it headroom, and retry instead of
    # staying dead until somebody notices.
    systemd.services.mealie.serviceConfig = {
      TimeoutStartSec = "10min";
      Restart = "on-failure";
      RestartSec = "15s";
    };

  })
