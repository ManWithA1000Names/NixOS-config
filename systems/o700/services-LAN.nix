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

    n8n = {
      enable = true;

      # No `settings` and no `webhookUrl`: both are mkRemovedOptionModule in
      # this module, and everything goes through `environment` instead. That
      # attrset is freeform, so a misspelled variable is accepted silently and
      # does nothing -- the same trap the servarr `settings` note in
      # services-internal.nix describes. Only the handful of names below are
      # declared options with types; the rest are checked by n8n, not by Nix.
      environment = {
        N8N_PORT = PORTS.N8N;

        # Defaults to "::" -- every interface, including the globally routable
        # IPv6 address enp4s0 also carries. Loopback so caddy is the only path
        # in; the firewall dropping this port is then the second layer rather
        # than the only one. Same reasoning as kavita and mealie above, except
        # that here the default is worse than 0.0.0.0: it is v6-inclusive.
        N8N_LISTEN_ADDRESS = "127.0.0.1";

        # n8n otherwise derives its own public URL from
        # N8N_HOST/N8N_PORT/N8N_PROTOCOL, which behind a reverse proxy yields
        # http://localhost:5678/ -- the URL it then puts in password-reset
        # mail, OAuth redirect URIs and the webhook addresses it shows you in
        # the editor. Setting N8N_HOST and N8N_PROTOCOL instead would not fix
        # it: that derivation appends ":<port>" whenever the port is not the
        # protocol's default, so it would produce
        # https://n8n.${DOMAIN}:5678/. These two override it outright.
        #
        # N8N_WEBHOOK_URL, not the bare WEBHOOK_URL that this module's own
        # removed-option message still names -- upstream has since demoted that
        # spelling to a deprecated fallback.
        N8N_EDITOR_BASE_URL = "https://${config.seta.n8n.proxy.domain}";
        N8N_WEBHOOK_URL = "https://${config.seta.n8n.proxy.domain}";

        # Caddy is the one hop. Left at its default of 0, express takes the
        # socket peer as the client, so every request looks like it came from
        # 127.0.0.1 -- login rate limiting collapses into a single global
        # bucket and the IP recorded against an audit event is the proxy's.
        # Same job PAPERLESS_TRUSTED_PROXIES does above.
        N8N_PROXY_HOPS = 1;

        # Otherwise n8n generates this on first start and saves it to
        # $N8N_USER_FOLDER/.n8n/config, where no rebuild asserts it and no
        # postgres-only backup captures it. Every stored credential is
        # encrypted with it, so restoring the n8n database alone -- the one
        # thing the centralized-postgres note below buys us -- would yield
        # workflows whose credentials cannot be decrypted.
        #
        # This is not a change of key. It is the key n8n already generated,
        # moved into the repo so it survives /var/lib being lost. n8n compares
        # this value against the settings file on every start and refuses to
        # boot on a mismatch (core, instance-settings.js), so a wrong value
        # fails visibly rather than quietly orphaning the credential store.
        N8N_ENCRYPTION_KEY_FILE = config.age.secrets.n8n-encryption-key.path;

        # State in the centralized postgres rather than n8n's default SQLite
        # under N8N_USER_FOLDER, for the reason given on the postgresql block
        # in services-internal.nix: one thing to back up rather than one per
        # service.
        #
        # A DB_POSTGRESDB_HOST beginning with "/" is how node-postgres is told
        # to use a unix socket -- it connects to <host>/.s.PGSQL.<port> instead
        # of opening TCP. Both halves of that matter here: our server has
        # listen_addresses = "" and no TCP socket at all to connect to, and the
        # socket is what makes peer auth work, so DB_POSTGRESDB_PASSWORD stays
        # unset and there is no credential to store.
        #
        # The role is "n8n" because the unit runs DynamicUser=true and a
        # dynamic user takes the unit's name, which is what peer auth compares
        # against. seta.n8n.postgres below creates the role and database.
        #
        # The port is named rather than left to n8n's own 5432 default because
        # it is part of the socket's filename, not just a TCP port.
        DB_TYPE = "postgresdb";
        DB_POSTGRESDB_HOST = "/run/postgresql";
        DB_POSTGRESDB_PORT = PORTS.POSTGRESQL;
        DB_POSTGRESDB_DATABASE = "n8n";
        DB_POSTGRESDB_USER = "n8n";

        # +-------------------------------------------------------------+
        # | Phone-home. Every one of these is `true` in n8n's own code.  |
        # +-------------------------------------------------------------+
        #
        # n8n ships pointed at four hosts: license.n8n.io, telemetry.n8n.io,
        # ph.n8n.io and api.n8n.io. The tinyproxy filter in networking.nix
        # denies that whole zone, but it can only stop the first of them --
        # the other three are fetched by the *browser*, from a LAN client whose
        # egress never passes through this host. These settings are what stops
        # those, because the editor only calls an endpoint that the backend
        # handed it in /rest/settings. Proxy filter and config are not two
        # layers over one hole here; they cover different holes.
        #
        # The first two are already false in the nixpkgs module and are
        # restated anyway: n8n's own default for both is true, so "off" lives
        # in a module option default rather than in the application, and a
        # package or module bump could move it back without anything in this
        # repo changing.

        # PostHog + RudderStack, front end and back end. This is the only one
        # of the group with a server-side half, so it is the only one the
        # proxy log would ever have shown.
        N8N_DIAGNOSTICS_ENABLED = false;

        # api.n8n.io/api/versions/, sent from the browser with this instance's
        # id in an `n8n-instance-id` header -- so the fetch is also the
        # identifier. The "what's new" articles ride the same switch upstream,
        # but they have their own endpoint and their own flag, so name both
        # rather than relying on the gate between them staying put.
        N8N_VERSION_NOTIFICATIONS_ENABLED = false;
        N8N_VERSION_NOTIFICATIONS_WHATS_NEW_ENABLED = false;

        # api.n8n.io/api/banners -- in-app announcements, fetched on every
        # editor load.
        N8N_DYNAMIC_BANNERS_ENABLED = false;

        # The template gallery, also api.n8n.io and also browser-side. This is
        # the one entry here that costs a feature rather than just silencing a
        # beacon: the Templates tab disappears. It is off rather than left to
        # fail against the blocked zone so it fails as a hidden feature instead
        # of as an error toast.
        N8N_TEMPLATES_ENABLED = false;

        # The only phone-home that is server-side and unconditional. n8n's
        # license SDK is constructed with renewOnInit set from this flag
        # (cli/src/license.ts), so a community instance with no activation key
        # still contacts license.n8n.io on every single start, carrying its
        # instance id as a device fingerprint plus collected usage metrics.
        # Nothing in the UI turns it off.
        #
        # This does NOT silence it quietly: n8n logs "Automatic license
        # renewal is disabled..." at startup whenever this is false. That
        # warning is the intended state, not a fault to chase -- the same
        # arrangement as odoo's publisher_warranty_url in services-WAN.nix,
        # where the inner layer stops the payload and leaves a log line behind.
        N8N_LICENSE_AUTO_RENEW_ENABLED = false;
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

    n8n = {
      critical = true;

      # Puts n8n in the central pg_dump manifest. Worth stating what that will
      # and will not recover: n8n encrypts every stored credential with a key
      # it generates on first start into /var/lib/n8n/.n8n/config, which is not
      # in postgres. A database-only restore therefore comes back with every
      # credential present and none of them decryptable.
      #
      # The fix is to lift that generated key into agenix and hand it back via
      # N8N_ENCRYPTION_KEY_FILE (the nixpkgs module turns any *_FILE variable
      # into a systemd credential, and n8n resolves any *_FILE suffix itself,
      # so the two meet without a wrapper). Deliberately not done here, because
      # doing it means committing a secret that does not exist yet. Note the
      # order this has to happen in: once n8n has written that file, supplying
      # a *different* key is a hard startup error ("Mismatching encryption
      # keys"), so the value that goes into agenix must be the one already on
      # disk, not a freshly generated one.
      postgres = true;

      # No networkConfinement override, which is worth being explicit about
      # for this service in particular. n8n's entire job is making outbound
      # HTTP calls, and the default confinement means every one of them has to
      # traverse tinyproxy: nodes built on axios pick up the proxy variables
      # and work, anything reaching for undici/fetch or a vendor SDK that
      # ignores them does not -- it fails outright rather than escaping
      # unobserved, which is the intended failure direction. ConnectPort in
      # networking.nix also caps HTTPS at 443, so an API on a non-standard
      # port is a deliberate change there rather than something that quietly
      # works.
      dashboard = {
        enable = true;
        name = "n8n";
        description = "Workflow automation";
        group = "Apps";
        icon = "n8n.png";
      };

      proxy = {
        enable = true;
        port = PORTS.N8N;
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

  # The nixpkgs n8n module orders the unit after network.target and nothing
  # else, so on a cold boot it can reach TypeORM's connect before the database
  # is up. postgresql.target rather than postgresql.service is the ordering
  # that actually helps: the target also pulls in postgresql-setup, the oneshot
  # that runs ensureDatabases/ensureUsers, and it is the "n8n" role created
  # there -- not merely a listening socket -- that n8n needs to exist.
  #
  # `after` only, never `requires`. The module already sets Restart=on-failure,
  # so a database that is down is a reason for n8n to retry; making it a
  # dependency would instead take n8n out of the unit graph and, because
  # seta.n8n.critical wires OnFailure to the notifier, turn every postgres
  # blip into a page.
  #
  # This is a list option, so it concatenates with the module's own `after`
  # rather than conflicting with it.
  systemd.services.n8n.after = [ "postgresql.target" ];

  # Jellyfin only needs to *read* the library, so it joins "media" as a
  # supplementary group rather than changing its primary group.
  users.users.jellyfin.extraGroups = [ MEDIA_GROUP ];
}
