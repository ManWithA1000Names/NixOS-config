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

    claude-code-api = {
      enable = true;

      # Loopback, like every other backend here -- caddy is the only path in,
      # and the firewall dropping this port is then the second layer rather
      # than the only one. Stated rather than inherited so the number comes
      # from PORTS, which is also what the generated vhost is built from.
      listen = "127.0.0.1:${toString PORTS.CLAUDE_CODE_API}";

      # Not optional here, whatever upstream's default says. `tools` is left at
      # "default", so a prompt reaching this endpoint is a shell in the unit's
      # StateDirectory -- and the exposure guard below only narrows who can
      # send one to the LAN, which includes every phone and TV in the house.
      # The key is the half of that which does not depend on the network.
      apiKeyFile = config.age.secrets.claude-code-api-key.path;

      # The credential the CLI presents to Anthropic. Supplied here so the unit
      # is self-sufficient on first boot: the alternative is OAuth state seeded
      # by hand into /var/lib/private/claude-code-api, which nothing in this
      # repo could reproduce and no backup here captures.
      oauthTokenFile = config.age.secrets.claude-code-oauth-token.path;

      # Everything else stays on upstream's defaults deliberately -- haiku as
      # the default model, all three models allowed, 3 concurrent invocations,
      # remote image fetching off. Narrowing any of them is a decision to make
      # from measured usage, not from first principles.
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

        # Restated rather than inherited, for the same reason the diagnostics
        # flags above are: both are correct defaults in n8n 2.x, and both are
        # defaults rather than guarantees. This service is exposure = WAN and
        # its Code nodes are in-process JavaScript, so a default that moves
        # under a version bump moves remote code execution with it.
        N8N_BLOCK_ENV_ACCESS_IN_NODE = true;
        NODES_EXCLUDE = ''["n8n-nodes-base.executeCommand","n8n-nodes-base.readWriteFile"]'';

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
      requiresExSSD = true;

      backup = {
        enable = true;

        # The application's own state only. The book and manga library is a
        # separate set (kavita-library, in systems/o700/backup.nix) so that
        # recovering a broken Kavita takes seconds instead of hours and does
        # not depend on the bulk transfer succeeding.
        paths = [ "/var/lib/kavita" ];

        # SQLite rather than the central postgres. Kavita is a .NET/EF Core
        # application and the module offers no database backend option.
        #
        # cache.db is here rather than in `exclude` deliberately, and the choice
        # is made under uncertainty: its name and its 16 KB next to kavita.db's
        # 1.2 MB both say "disposable", but that is inference from the file
        # listing, not from Kavita's source. Capturing it costs a few KB a night
        # and dropping it costs whatever it turns out to hold, so it is captured
        # -- the same "keep excludes conservative" rule the exclude list below
        # follows. It is snapshotted through the SQLite API for the same reason
        # kavita.db is: it was sitting there with a live -wal and -shm.
        sqlite = [
          "/var/lib/kavita/config/kavita.db"
          "/var/lib/kavita/config/cache.db"
        ];

        # Both databases and all their -wal/-shm/-journal siblings are excluded
        # automatically because they are named in `sqlite` above -- see the
        # exclude derivation in backup.nix.
        exclude = [
          "/var/lib/kavita/config/logs"
          "/var/lib/kavita/config/temp"
          "/var/lib/kavita/config/cache"
          # Sibling of cache/, and a cache by the same reading. Found on the
          # host rather than in the module -- neither this nor cache.db is
          # visible from the nixpkgs source the rest of these lists were
          # written from.
          "/var/lib/kavita/config/cache-long"
          # Kavita's own periodic self-backup. Backing up a backup doubles the
          # stored bytes for no additional recoverability.
          "/var/lib/kavita/config/backups"
        ];

        # Kept on purpose, having looked at the actual directory: bookmarks/
        # (saved pages, user data), covers/, images/, fonts/, themes/ and
        # templates/ (all user-supplied or expensive to regenerate), favicons/
        # (a cache, but tiny and immutable so it deduplicates to nothing), the
        # two progress_export CSVs, and appsettings.json -- which Kavita
        # rewrites from the Nix template on every start, so restoring it is a
        # no-op, but it is 155 bytes and holds a second copy of the TokenKey.

        # What survives the excludes and matters: config/covers and
        # config/bookmarks, and secrets/tokenkey -- the 512-bit signing key
        # named by services.kavita.tokenKeyFile, which nothing in this repo
        # creates. It was placed by hand, exists only on this disk, and Kavita
        # will not start without it.
      };

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

      backup = {
        enable = true;

        # One path covers media/ (originals, archive and thumbnails),
        # consume/ (anything dropped in but not yet ingested) and the loose
        # files at the top level, including nixos-paperless-secret-key.
        #
        # That file is the Django SECRET_KEY, generated on first start with
        # umask 0377 and written nowhere else -- but it is worth being accurate
        # about how much it costs, because it is easy to over-rank. It signs
        # session cookies and password-reset links and nothing else here.
        # Passwords survive it (PBKDF2, per-password salts) and so do API
        # tokens, which are random authtoken rows rather than anything derived
        # from it. Losing it means everybody logs in again; it does not make a
        # single document unreadable.
        #
        # The documents are what actually matters in this path, and they are
        # plain files under media/documents/.
        paths = [ "/var/lib/paperless" ];

        exclude = [
          # The Whoosh full-text index. Rebuilt by `document_index reindex`,
          # and it is rewritten wholesale on every document change -- the worst
          # dedup profile of anything on this host.
          "/var/lib/paperless/index"

          # Retrained from the documents themselves -- and by far the largest
          # single file in any state directory here: 434 MB, rewritten whenever
          # the classifier retrains. Excluding it is the difference between a
          # trivial nightly delta for this service and a hundreds-of-megabytes
          # one.
          #
          # The trailing glob is load-bearing and was verified rather than
          # assumed: restic's `*` matches the empty string, so this pattern
          # covers the bare `classification_model.pickle` as well as any
          # suffixed variant. A pattern that silently failed to match would
          # have cost 434 MB a night without any visible symptom.
          "/var/lib/paperless/classification_model.pickle*"

          "/var/lib/paperless/log"

          # Celery Beat's periodic-task scheduler state -- last-run timestamps
          # and nothing else. Found on the host, not in the module: it is
          # created at runtime and does not appear anywhere in nixpkgs.
          #
          # Excluded rather than captured through `sqlite`, which is the
          # opposite of the call made for kavita's cache.db, and deliberately
          # so. There the file's role was uncertain, so it was captured. Here it
          # is not: this tracks when periodic tasks last ran, and restoring a
          # stale copy is actively worse than starting without one, because
          # Celery reads it and fires everything it believes is overdue. It is
          # also the churniest file in the directory -- a 2.6 MB write-ahead log
          # against a 12 KB database, rewritten continuously.
          "/var/lib/paperless/celerybeat-schedule.db*"
        ];

        # Kept, having looked at the actual directory: media/ (the documents,
        # the entire point), consume/ (anything dropped in but not yet
        # ingested), nixos-paperless-secret-key, and src-version.

        # media/documents/thumbnails is deliberately NOT excluded. It is
        # regenerable in principle, but only by re-rendering every document,
        # and it deduplicates well because a thumbnail never changes once
        # written.

        # Personal and association records are mixed in this archive, so the
        # stricter business retention governs all of it.
        keepYearly = 10;
      };

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
      postgres = true;

      backup = {
        enable = true;

        # /var/lib/private, not /var/lib: DynamicUser=true with
        # StateDirectory=mealie. Holds recipe images and assets, and the
        # generated .secret used to sign tokens.
        paths = [ "/var/lib/private/mealie" ];

        exclude = [
          "/var/lib/private/mealie/.temp"
          # Mealie's own export bundles. A backup of a backup.
          "/var/lib/private/mealie/backups"
          "/var/lib/private/mealie/mealie.log"
        ];
      };

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

      backup = {
        enable = true;

        # The one service on this host that is stopped for its own backup.
        #
        # It has no pg_dump and no sqlite .backup equivalent: its state is a
        # set of embedded stores (bbolt for idm, jsoncs3 for shares, nats for
        # the event bus) that offer no snapshot API, and both filesystems here
        # are ext4, so there is no filesystem-level snapshot to take instead.
        # Copying them live yields a crash-consistent image of a metadata store
        # mid-write, which is precisely the file that decides who can see which
        # space. The blobs themselves would be fine -- they are content-
        # addressed -- but a correct blob store with torn metadata is not a
        # recoverable instance.
        #
        # The restart is wired through the restic module's
        # backupCleanupCommand, which systemd runs in postStop, so the service
        # comes back even when the backup fails. systems/o700/backup.nix schedules
        # this set second-to-last so the downtime lands at the end of the
        # window rather than in the middle of it.
        stopUnits = true;

        # /etc/opencloud is not optional and is the reason this has two paths.
        # opencloud.yaml is written once at runtime by opencloud-init-config
        # and holds every inter-service credential the instance was built
        # around -- machine auth API key, jwt secret, transfer secret, the
        # system user's id. It is not in /var/lib and not in the nix store, so
        # a snapshot of the state directory alone restores an instance that
        # cannot be opened.
        paths = [
          "/var/lib/opencloud"
          "/etc/opencloud"
        ];

        exclude = [
          # The bleve search index. Excluded because bleve rewrites segment
          # files on every change, which is the churn profile that inflates a
          # deduplicating repository fastest.
          #
          # The cost is real and is NOT self-healing: OpenCloud builds this
          # index from events, so a restored instance has an empty one and
          # nothing triggers a full rebuild on its own. A reindex has to be run
          # by hand afterwards -- see section 5 of docs/backup-and-restore.md.
          "/var/lib/opencloud/search"

          # Rendered previews, regenerated on demand from the blobs.
          "/var/lib/opencloud/thumbnails"
        ];
      };

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

    claude-code-api = {
      # networkConfinement left at its default of enabled, and it holds here
      # for the reason it holds for the Node services already on this host:
      # the CLI is a Node program, the module sets NODE_USE_ENV_PROXY=1
      # itself, and the only destination that matters -- api.anthropic.com --
      # is reached on 443, which is the one port tinyproxy permits CONNECT to.
      # So the confinement costs nothing and every call the CLI makes lands in
      # the egress log like everything else.

      # No backup entry, and that is a decision rather than an omission. The
      # state directory holds the CLI's OAuth cache, which is re-derived from
      # oauthTokenFile on every start, and conversation transcripts, which
      # expire after sessionTTL (2h) and are a cache of somebody else's
      # chat history rather than a record this host owns. There is nothing in
      # there a restore would want.

      # No dashboard entry either: the tile would link to https://<domain>/,
      # and this service has no UI to serve there -- it answers /v1/... and
      # /healthz and 404s everything else.

      proxy = {
        enable = true;
        port = PORTS.CLAUDE_CODE_API;
        domain = "claude.${DOMAIN}";
        exposure = "LAN";
      };
    };

    n8n = {
      # Puts n8n in the central pg_dump manifest. Worth stating what that will
      # and will not recover: n8n encrypts every stored credential with a key
      # it generates on first start into /var/lib/n8n/.n8n/config, which is not
      # in postgres. A database-only restore therefore comes back with every
      # credential present and none of them decryptable.
      #
      # That key is now in agenix and handed back via N8N_ENCRYPTION_KEY_FILE
      # (see the `environment` block above and used-secrets.nix), so the
      # database and the key that decrypts it are both recoverable -- but from
      # two different places. The database comes out of the backup below; the
      # key comes out of the config repo, which is backed up separately. A
      # restore needs both.
      postgres = true;

      backup = {
        enable = true;

        # /var/lib/private, not /var/lib -- DynamicUser=true with
        # StateDirectory=n8n, so the latter is a symlink restic would archive
        # as a symlink and nothing else.
        #
        # Most of n8n's state is in postgres, but not all of it. What is
        # actually in this tree, checked against the host:
        #
        #   .n8n/config     56 bytes, mode 0600. The encryption-key check value
        #                   n8n compares against N8N_ENCRYPTION_KEY_FILE on
        #                   every start. See the restore hazard below.
        #   .n8n/nodes/     community node manifest, and node_modules/ once any
        #                   are installed. Kept rather than treated as a
        #                   reinstallable artifact, because reinstalling means
        #                   npm reaching the internet and this service is held
        #                   to the egress proxy -- the backup is the reliable
        #                   path here, not the fallback.
        #   .n8n/storage/   empty today; n8n's on-disk payload area.
        #
        # RESTORE HAZARD, and the reason .n8n/config is worth understanding
        # rather than just archiving: n8n refuses to start when that file and
        # N8N_ENCRYPTION_KEY_FILE disagree ("Mismatching encryption keys"). The
        # two agree today because the agenix secret was lifted from this file
        # rather than generated fresh. They are therefore a pair: restoring one
        # without the other, or rotating the agenix key without replacing this
        # file, is a service that will not boot.
        paths = [ "/var/lib/private/n8n" ];

        exclude = [
          "/var/lib/private/n8n/.cache"

          # n8n's own append-only execution log, and it does grow -- the
          # rotated -3 file is 95 KB against 1 KB for the live one. The
          # authoritative record of executions is in postgres; this is a
          # debugging aid.
          #
          # The trailing glob covers the live n8nEventLog.log and every rotated
          # n8nEventLog-N.log alongside it.
          "/var/lib/private/n8n/.n8n/n8nEventLog*"
        ];
      };

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

        # LAN, not WAN. The editor, its REST API, the MCP endpoints and the
        # "listen for test event" webhooks were all published to the internet
        # purely so that production webhooks could be delivered -- one endpoint
        # requiring third-party access dragged the entire application out with
        # it. The exposure guard now answers 404 to anything off-LAN except the
        # paths named below.
        #
        # This narrows a service that matters more than most: n8n's Code nodes
        # are in-process JavaScript, which is why N8N_BLOCK_ENV_ACCESS_IN_NODE
        # is restated rather than inherited above. Reaching the editor was
        # reaching that.
        exposure = "LAN";

        # n8n 2.34.6 serves production webhooks under this prefix
        # (N8N_ENDPOINT_WEBHOOK, default "webhook"). Deliberately just this one:
        #
        #   /webhook-test/*    the editor's test runs. Only live while somebody
        #                      has "listen for test event" open, and letting a
        #                      stranger fire the workflow being edited is worse
        #                      than the production case, not better.
        #   /webhook-waiting/* Wait-node resume URLs. Add it here if a workflow
        #                      ever needs a third party to resume it; nothing
        #                      does today, and it cannot be added blind because
        #                      the resume URL carries an execution id.
        #   /form/*            n8n Forms, which are public-facing by design.
        #                      Add when the first Form trigger exists.
        #   /mcp/*, /rest/*    stay LAN, unconditionally.
        #
        # The trailing "/" is load-bearing: "/webhook*" would also match
        # /webhook-test/* and /webhook-waiting/*, which is precisely the set
        # deliberately excluded above.
        #
        # There is no source check on these, so n8n is the whole access
        # control. A production webhook is only as private as its path, which
        # n8n generates as a UUID by default but lets a workflow override with
        # anything -- and every existing webhook becomes internet-reachable the
        # moment this lands, not just ones created afterwards. Worth an audit
        # of the workflow list for guessable paths, and Header Auth on anything
        # whose trigger has a side effect.
        #
        # Guessing is not free, at least: an unregistered path returns 404 from
        # n8n, and caddy-scan (networking.nix) bans on 40 of those in 5 minutes
        # with banaction_allports and bantime-increment behind it.
        wanPaths = [ "/webhook/*" ];
      };
    };

    homepage-dashboard = {
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
  systemd.services = {
    mealie.serviceConfig = {
      TimeoutStartSec = "10min";
      Restart = "on-failure";
      RestartSec = "15s";
    };

    homepage-dashboard.environment.HOSTNAME = "127.0.0.1";

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
    # netdata's systemd_service_unit_failed_state template now alerts on every
    # service unit that enters the failed state, turn every postgres blip into a
    # page. That alarm is wider than the OnFailure list it replaced, so this
    # reasoning binds harder than it did, not less.
    #
    # This is a list option, so it concatenates with the module's own `after`
    # rather than conflicting with it.
    n8n.after = [ "postgresql.target" ];
  };

  # Jellyfin only needs to *read* the library, so it joins "media" as a
  # supplementary group rather than changing its primary group.
  users.users.jellyfin.extraGroups = [ MEDIA_GROUP ];
}
