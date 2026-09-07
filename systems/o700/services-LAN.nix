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

      # The list of proxies whose X-Forwarded-For paperless will believe.
      # Upstream names it as the setting needed "to prevent IP address spoofing
      # if you are using e.g. fail2ban". Caddy is the only hop.
      #
      # PAPERLESS_URL is not needed alongside it: the module already derives it
      # from `domain` above, and that one variable covers ALLOWED_HOSTS,
      # CORS_ALLOWED_HOSTS and CSRF_TRUSTED_ORIGINS.
      settings.PAPERLESS_TRUSTED_PROXIES = "127.0.0.1";

      database.createLocally = true;
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

    opencloud = {
      enable = true;

      port = PORTS.OPENCLOUD;
      url = "https://${config.seta.opencloud.proxy.domain}";

      # Without this, the init oneshot below invents an admin password on first
      # boot and writes it into /etc/opencloud/opencloud.yaml, where reading it
      # off the host is the only way to learn it. An env var beats the yaml, so
      # supplying IDM_ADMIN_PASSWORD here keeps the credential in agenix and
      # makes the first login reproducible rather than archaeological.
      environmentFile = config.age.secrets.opencloud-env.path;

      environment = {
        # The module's default for this whole attrset is
        # `{ OC_INSECURE = "true"; }`. Assigning replaces that default rather
        # than merging into it, so dropping this line switches TLS verification
        # back on for the internal service-to-service and NATS calls -- which
        # have no certificates to satisfy it, because nothing issued any.
        OC_INSECURE = "true";

        # The proxy service defaults to serving *HTTPS* on its bind address,
        # with a self-signed certificate it generates under the state
        # directory. `opencloud init --insecure true` does not turn that off:
        # it only relaxes backend and OIDC verification (see CreateConfig in
        # opencloud/pkg/init/init.go), leaving PROXY_TLS at its default of
        # true. Caddy's generated `reverse_proxy localhost:9200` speaks plain
        # HTTP, so at the default this is a 502 on every single request.
        # Terminating TLS once, at Caddy, is the intent anyway.
        PROXY_TLS = "false";
      };
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

      # Confined like everything else, which is only safe because the default
      # allow list is the LAN /24 rather than this host's own address. Jellyfin
      # binds 0.0.0.0 and is the one service here that house clients reach
      # directly, and IPAddressAllow matches the *peer*: narrowed to a /32 the
      # inbound half of this filter would refuse every TV and phone on the
      # network while looking, from the config, like an egress rule.
      #
      # Outbound it needs metadata providers, and .NET's
      # HttpClient.DefaultProxy reads HTTP_PROXY on Unix, so those already go
      # through tinyproxy.

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

      postgres = true;

      dashboard = {
        enable = true;
        name = "Paperless";
        description = "Document manager";
        group = "Files & Sharing";
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
      postgres = true;

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

    opencloud = {
      critical = true;

      # The module ships a second unit. opencloud-init-config is a oneshot,
      # ordered before opencloud.service, that runs `opencloud init` to
      # generate /etc/opencloud/opencloud.yaml when it is absent -- that file
      # holds every inter-service credential, so if it fails the main unit
      # crash-loops against a config that was never written. The `units`
      # default of [ name ] would leave it unwatched.
      units = [
        "opencloud"
        "opencloud-init-config"
      ];

      dashboard = {
        enable = true;
        name = "OpenCloud";
        description = "File sync & sharing";
        group = "Files & Sharing";
        # selfh.st icon set (the `sh-` prefix). The dashboard-icons set that
        # every other entry here draws from has no opencloud icon, only an
        # owncloud one, and this is not that.
        icon = "sh-opencloud.png";
      };

      proxy = {
        enable = true;
        port = PORTS.OPENCLOUD;
        domain = "cloud.${DOMAIN}";
        exposure = "LAN";
      };
    };

    homepage-dashboard = {
      critical = true;

      proxy = {
        enable = true;
        port = PORTS.DASHBOARD;
        domain = "home.${DOMAIN}";
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
