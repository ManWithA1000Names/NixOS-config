{
  config,
  PORTS,
  DOMAIN,
  PATHS,
  MEDIA_GROUP,
  ...
}:
{
  services = {
    jellyfin.enable = true;

    kavita = {
      enable = true;
      settings.Port = PORTS.KAVITA;
      # Defaults to "0.0.0.0,::" -- every interface including the globally
      # routable IPv6 address. Loopback so caddy is the only path in; the
      # firewall dropping this port is then the second layer rather than the
      # only one.
      settings.IpAddresses = "127.0.0.1";
      tokenKeyFile = "/var/lib/kavita/secrets/tokenkey";
    };

    paperless = {
      enable = true;
      port = PORTS.PAPERLESS;
      domain = "${config.seta.paperless.proxy.domain}";

      database.createLocally = true;
      exporter.enable = true;
    };

    mealie = {
      enable = true;
      port = PORTS.MEALIE;
      # Defaults to 0.0.0.0. Same reasoning as kavita above.
      listenAddress = "127.0.0.1";
      settings.BASE_URL = "https://${config.seta.mealie.proxy.domain}";

      database.createLocally = true;
    };

    seerr = {
      enable = true;
      port = PORTS.SEERR;
    };

    homepage-dashboard = {
      enable = true;
      listenPort = PORTS.DASHBOARD;

      # Homepage rejects any request whose Host header is not listed here, so
      # this has to name the proxied domain and not just the loopback pair it
      # defaults to. Reached through caddy, the Host header is the domain.
      allowedHosts = builtins.concatStringsSep "," [
        config.seta.homepage-dashboard.proxy.domain
        "localhost:${toString PORTS.DASHBOARD}"
        "127.0.0.1:${toString PORTS.DASHBOARD}"
      ];

      settings.title = DOMAIN;

      widgets = [
        {
          resources = {
            cpu = true;
            memory = true;
            disk = [
              PATHS.EX-SSD
              "/"
            ];
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
          grouped = builtins.groupBy (s: s.dashboard.group) (
            builtins.filter (meta: meta.dashboard.enable) (builtins.attrValues config.seta)
          );
        in
        builtins.attrValues (
          builtins.mapAttrs (group: svcs: {
            ${group} = map ({ dashboard, proxy, ... }: {
              ${dashboard.name} = {
                inherit (dashboard) icon description;
                href = "https://${proxy.domain}";
              };
            }) svcs;
          }) grouped
        );
    };
  };

  seta = {
    jellyfin = {
      critical = true;
      requiresExSSD = true;

      dashboard = {
        enable = true;
        name = "Jellyfin";
        description = "Media server";
        group = "Media";
        icon = "jellyfin.png";
      };

      proxy = {
        enable = true;
        port = PORTS.JELLYFIN;
        exposure = "LAN";
      };
    };

    kavita = {
      critical = true;
      requiresExSSD = true;

      dashboard = {
        enable = true;
        name = "Kavita";
        description = "Manga & comics & books.";
        group = "Media";
        icon = "kavita.png";
      };

      proxy = {
        enable = true;
        port = PORTS.KAVITA;
        exposure = "LAN";
      };
    };

    paperless = {
      critical = true;

      # Paperless has no unit called "paperless" -- the module ships
      # paperless-scheduler, paperless-task-queue, paperless-consumer and
      # paperless-web. The `units` default of [ name ] would therefore name a
      # unit that does not exist, which fails the same silent way the nftables
      # note in monitoring/notify.nix describes: systemd synthesises an empty
      # unit and every flag hung off it quietly does nothing.
      units = [
        "paperless-scheduler"
        "paperless-task-queue"
        "paperless-consumer"
        "paperless-web"
      ];

      # MIGRATION STEP 1 -- uncomment with services.paperless.database above.
      # postgres = true;

      dashboard = {
        enable = true;
        name = "Paperless";
        description = "Document manager";
        group = "Apps";
        icon = "paperless-ngx.png";
      };

      proxy = {
        enable = true;
        port = PORTS.PAPERLESS;
        exposure = "LAN";
      };
    };

    mealie = {
      critical = true;
      # MIGRATION STEP 4 -- uncomment with services.mealie.database above.
      # postgres = true;

      dashboard = {
        enable = true;
        name = "Mealie";
        description = "Recipes & Food planner";
        group = "Apps";
        icon = "mealie.png";
      };

      proxy = {
        enable = true;
        port = PORTS.MEALIE;
        exposure = "LAN";
      };
    };

    seerr = {
      critical = true;

      dashboard = {
        enable = true;
        name = "Seerr";
        description = "Media requests";
        group = "Media";
        icon = "jellyseerr.png";
      };

      proxy = {
        enable = true;
        port = PORTS.SEERR;
        exposure = "LAN";
      };
    };

    homepage-dashboard = {
      critical = true;

      proxy = {
        enable = true;
        port = PORTS.DASHBOARD;
        domain = DOMAIN;
        exposure = "LAN";
      };
    };
  };

  # +-----------------------------------------------------------------+
  # | Additional configurations that are required for these services. |
  # +-----------------------------------------------------------------+

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

  # Jellyfin only needs to *read* the library, so it joins "media" as a
  # supplementary group rather than changing its primary group.
  users.users.jellyfin.extraGroups = [ MEDIA_GROUP ];
}
