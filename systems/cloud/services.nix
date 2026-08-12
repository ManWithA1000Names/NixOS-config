{ pkgs, ... }:
let

  GIT_DOMAIN = "cloud-git.local";
  MEALIE_DOMAIN = "cloud-mealie.local";
  JELLYFIN_DOMAIN = "cloud-fin.local";

  PAPERLESS_DOMAIN = "cloud-paper.local";
  KAVITA_DOMAIN = "cloud-kavita.local";

  # The "Arr" media-automation stack.
  PROWLARR_DOMAIN = "cloud-prowlarr.local";
  SONARR_DOMAIN = "cloud-sonarr.local";
  RADARR_DOMAIN = "cloud-radarr.local";
  BAZARR_DOMAIN = "cloud-bazarr.local";
  SEERR_DOMAIN = "cloud-seerr.local";
  QBIT_DOMAIN = "cloud-qbit.local";

  services = {
    ${GIT_DOMAIN} = "8001";
    ${MEALIE_DOMAIN} = "8002";
    ${JELLYFIN_DOMAIN} = "8096";
    ${PAPERLESS_DOMAIN} = "28981";
    ${KAVITA_DOMAIN} = "5000";

    ${PROWLARR_DOMAIN} = "9696";
    ${SONARR_DOMAIN} = "8989";
    ${RADARR_DOMAIN} = "7878";
    ${BAZARR_DOMAIN} = "6767";
    ${SEERR_DOMAIN} = "5055";
    ${QBIT_DOMAIN} = "8080";
  };

  service_names = {
    ${GIT_DOMAIN} = "Gitea";
    ${MEALIE_DOMAIN} = "Mealie";
    ${JELLYFIN_DOMAIN} = "Jellyfin";
    ${PAPERLESS_DOMAIN} = "Paperless";
    ${KAVITA_DOMAIN} = "Kavita";

    ${PROWLARR_DOMAIN} = "Prowlarr";
    ${SONARR_DOMAIN} = "Sonarr";
    ${RADARR_DOMAIN} = "Radarr";
    ${BAZARR_DOMAIN} = "Bazarr";
    ${SEERR_DOMAIN} = "Seerr";
    ${QBIT_DOMAIN} = "qBittorrent";
  };

  # Shared media storage for the Arr stack, qBittorrent and Jellyfin.
  # Downloads and the final library live under a single root on the same
  # filesystem so Sonarr/Radarr can import via instant hardlinks + atomic
  # moves (no copy, no extra disk usage, seeding keeps working).
  MEDIA_ROOT = "/mnt/ex-ssd/media";
  MEDIA_GROUP = "media";

  # --- DNS ---------------------------------------------------------------
  #
  # This host's LAN address. Hardcoded rather than discovered because dnsmasq
  # must both bind it and hand it out as an answer, and a moving address would
  # silently serve stale records. Pin it with a static DHCP reservation on the
  # router for this machine's MAC.
  CLOUD_IP = "192.168.1.108";
  ROUTER_IP = "192.168.1.1";

  # RFC 8375 reserves home.arpa for exactly this: a real, unicast-resolvable
  # zone for home networks that can never collide with a public name. Used
  # here to prove out LAN-wide name resolution without registering a domain.
  # It can never carry a public TLS certificate (nobody can prove ownership),
  # so it is a testing vehicle only.
  LAN_ZONE = "home.arpa";

  GITEA_DB_PORT = "9001";
  HOMELAB_DASHBOARD_PORT = "8000";

  # Helper to generate the avahi-publish commands
  publishCommands = builtins.concatStringsSep "\n"
    (builtins.map (name: "${pkgs.avahi}/bin/avahi-publish -a ${name} -R $IP &")
      (builtins.attrNames services));
in {

  services = {
    # avahi-aliases (below) publishes Caddy's hostname aliases via the
    # avahi-daemon D-Bus API. That API is rejected with "Not permitted"
    # unless user-triggered publishing is allowed.
    avahi.publish.userServices = pkgs.lib.mkForce true;

    # LAN resolver. Answers authoritatively for LAN_ZONE and forwards
    # everything else to the router.
    dnsmasq = {
      enable = true;

      # Leave this host's own resolution alone: systemd-resolved keeps
      # /etc/resolv.conf pointed at its loopback stub. Setting this true would
      # have resolvconf fight resolved over the same file.
      resolveLocalQueries = false;

      settings = {
        # Bind one explicit address rather than the interface. enp4s0 also
        # carries globally routable IPv6 addresses and this host runs with
        # networking.firewall.enable = false, so binding the interface would
        # expose an open resolver to the internet -- reliably discovered and
        # abused for DNS amplification. bind-dynamic (rather than
        # bind-interfaces) tolerates the address not existing yet at boot,
        # since it arrives via DHCP.
        listen-address = CLOUD_IP;
        bind-dynamic = true;

        # Wildcard: every name under the zone resolves to this host, matching
        # how a wildcard TLS certificate will later cover the same names.
        # Adding a service then needs no DNS change at all.
        address = [
          "/${LAN_ZONE}/${CLOUD_IP}"
          # Returning NXDOMAIN for this name is the signal Firefox uses to
          # disable DNS-over-HTTPS on "canary" networks. Without it, Firefox
          # bypasses dnsmasq entirely regardless of DHCP settings.
          "/use-application-dns.net/"
        ];

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

    caddy = {
      enable = true;
      globalConfig = ''
        local_certs
      '';
      virtualHosts = (builtins.mapAttrs
        (name: port: { extraConfig = "reverse_proxy localhost:${port}"; })
        services) // {
          # qBittorrent's WebUI enforces Host-header validation and CSRF
          # checks that reject reverse-proxied requests. Rewriting Host to
          # the upstream and dropping Origin/Referer makes the request look
          # local to qBittorrent, so its defaults can stay enabled.
          ${QBIT_DOMAIN} = {
            extraConfig = ''
              reverse_proxy localhost:${services.${QBIT_DOMAIN}} {
                header_up Host localhost:${services.${QBIT_DOMAIN}}
                header_up -Origin
                header_up -Referer
              }
            '';
          };
          ":80" = {
            extraConfig = "reverse_proxy localhost:${HOMELAB_DASHBOARD_PORT}";
          };
          ":443" = {
            extraConfig = "reverse_proxy localhost:${HOMELAB_DASHBOARD_PORT}";
          };
        };
    };

    homelab-dashboard = {
      enable = true;
      port = pkgs.lib.toInt HOMELAB_DASHBOARD_PORT;
      title = "Local Cloud Control Center";
      services = builtins.mapAttrs (name: value: {
        url = "http://${name}";
        name = service_names.${name};
      }) services;
    };

    gitea = {
      enable = true;
      lfs.enable = true;
      settings.server = {
        DOMAIN = GIT_DOMAIN;
        HTTP_PORT = pkgs.lib.toInt services.${GIT_DOMAIN};
      };

      database.port = pkgs.lib.toInt GITEA_DB_PORT;
    };

    jellyfin = {
      enable = true;
      dataDir = "/mnt/ex-ssd/jellyfin/";
    };

    mealie = {
      enable = true;
      port = pkgs.lib.toInt services.${MEALIE_DOMAIN};
      settings = { BASE_URL = "http://${MEALIE_DOMAIN}"; };
    };

    paperless = {
      enable = true;
      domain = PAPERLESS_DOMAIN;
      port = pkgs.lib.toInt services.${PAPERLESS_DOMAIN};
    };

    kavita = {
      enable = true;
      settings = { Port = pkgs.lib.toInt services.${KAVITA_DOMAIN}; };
      tokenKeyFile = "/var/lib/kavita/secrets/tokenkey";
    };

    # --- Arr media-automation stack ---------------------------------------

    # Indexer manager. Syncs its indexers into Sonarr/Radarr automatically.
    prowlarr = {
      enable = true;
      settings.server.port = pkgs.lib.toInt services.${PROWLARR_DOMAIN};
    };

    # TV automation. Writes to the shared library, so it runs in "media".
    sonarr = {
      enable = true;
      group = MEDIA_GROUP;
      settings.server.port = pkgs.lib.toInt services.${SONARR_DOMAIN};
    };

    # Movie automation. Writes to the shared library, so it runs in "media".
    radarr = {
      enable = true;
      group = MEDIA_GROUP;
      settings.server.port = pkgs.lib.toInt services.${RADARR_DOMAIN};
    };

    # Subtitles. Writes subtitle files next to media, so it runs in "media".
    bazarr = {
      enable = true;
      group = MEDIA_GROUP;
      listenPort = pkgs.lib.toInt services.${BAZARR_DOMAIN};
    };

    # Requests portal (formerly Jellyseerr). Talks to APIs only, no media.
    seerr = {
      enable = true;
      port = pkgs.lib.toInt services.${SEERR_DOMAIN};
    };

    # Download client. Writes downloads to the shared root, so it runs in
    # "media" to keep hardlinks/imports possible across to the library.
    qbittorrent = {
      enable = true;
      group = MEDIA_GROUP;
      webuiPort = pkgs.lib.toInt services.${QBIT_DOMAIN};
    };

  };

  # Shared group that owns everything under MEDIA_ROOT. Every service that
  # touches media files runs with this as its primary group (set above),
  # and the human user is a member too (see cloud/user.nix).
  #
  # The GID is pinned to a fixed, known value because the NFS export squashes
  # every client onto this group (see hardware-configuration.nix). A stable
  # GID keeps that mapping valid across rebuilds and machines.
  users.groups.${MEDIA_GROUP} = { gid = 985; };

  # Jellyfin only needs to *read* the library, so it joins "media" as a
  # supplementary group rather than changing its primary group.
  users.users.jellyfin.extraGroups = [ MEDIA_GROUP ];

  systemd = {
    services = {
      # Create new files group-writable (0664/0775) so any "media" member can
      # manage the content. Radarr/qBittorrent ship a stricter default UMask,
      # hence mkForce.
      sonarr.serviceConfig.UMask = pkgs.lib.mkForce "0002";
      radarr.serviceConfig.UMask = pkgs.lib.mkForce "0002";
      bazarr.serviceConfig.UMask = pkgs.lib.mkForce "0002";
      qbittorrent.serviceConfig.UMask = pkgs.lib.mkForce "0002";

      avahi-aliases = {
        description = "Broadcast mDNS aliases for Caddy";
        after = [ "avahi-daemon.service" "network.target" ];
        wantedBy = [ "multi-user.target" ];
        path =
          [ pkgs.avahi pkgs.coreutils pkgs.gawk pkgs.iproute2 pkgs.gnugrep ];
        serviceConfig = {
          Type = "simple";
          # This script finds the current IP and starts the background broadcasters
          ExecStart = pkgs.writeShellScript "publish-aliases" ''
            # Wait for an IP to be assigned (crucial for offline/Link-Local)
            while ! ip -4 addr show up | grep -q 'inet '; do sleep 1; done

            IP=$(ip -4 addr show up | grep -v "127.0.0.1" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
            echo "Registering aliases for IP: $IP"

            ${publishCommands}

            # Keep the service alive
            wait
          '';
          Restart = "always";
        };
      };
    };

    # Media directory tree. The setgid bit (leading 2 in 2775) makes new
    # subdirectories inherit the "media" group automatically.
    #
    # Note: the parent mount-point /mnt/ex-ssd must be root-owned for these
    # rules to apply -- systemd-tmpfiles refuses an "unsafe path transition"
    # from an unprivileged-user-owned directory into a root-owned one. That
    # ownership is asserted next to the mount in hardware-configuration.nix.
    tmpfiles.rules = [
      "d ${MEDIA_ROOT}                     2775 root        ${MEDIA_GROUP} - -"
      "d ${MEDIA_ROOT}/torrents            2775 qbittorrent ${MEDIA_GROUP} - -"
      "d ${MEDIA_ROOT}/torrents/incomplete 2775 qbittorrent ${MEDIA_GROUP} - -"
      "d ${MEDIA_ROOT}/torrents/tv         2775 qbittorrent ${MEDIA_GROUP} - -"
      "d ${MEDIA_ROOT}/torrents/movies     2775 qbittorrent ${MEDIA_GROUP} - -"
      "d ${MEDIA_ROOT}/library             2775 root        ${MEDIA_GROUP} - -"
      "d ${MEDIA_ROOT}/library/tv          2775 root        ${MEDIA_GROUP} - -"
      "d ${MEDIA_ROOT}/library/movies      2775 root        ${MEDIA_GROUP} - -"
    ];
  };

}
