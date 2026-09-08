{
  pkgs,
  config,
  PORTS,
  DOMAIN,
  PATHS,
  ...
}:
let
  # OCA's web_dark_mode (AGPL-3, initOS GmbH). Replaced Cybrosys' theme, which
  # layered 70 KB of hardcoded overrides on top of the compiled stylesheets and
  # left every surface it missed light-on-light -- most visibly the whole
  # navbar systray, which went dark-on-dark and unusable.
  #
  # This one substitutes primary/secondary_variables.scss and
  # bootstrap_overridden.scss *before* Odoo's SCSS compiles, so stock styles
  # recompile dark rather than being painted over. odoo18 already declares the
  # web.assets_backend_lazy_dark and web.assets_web_dark bundles it hooks
  # (web/__manifest__.py); Community merely ships no switch, which this adds to
  # the user menu, per user.
  #
  # Pinned to a commit, not the 18.0 branch head, so the hash is stable.
  # postFetch strips the other ~50 addons of the OCA/web monorepo: they would
  # otherwise all land on addons_path and clutter the Apps list.
  odooDarkMode = pkgs.fetchzip {
    name = "odoo-addon-web-dark-mode-18.0.1.0.0";
    url = "https://github.com/OCA/web/archive/0c027cd611fb070c2e3f18e8121384e6ff2245ba.tar.gz";
    hash = "sha256-49hYo7Yz8Zzr85uhmp65EEwswMwPmrcProFtJMSJfqI=";
    postFetch = ''
      find "$out" -mindepth 1 -maxdepth 1 ! -name web_dark_mode -exec rm -rf {} +
    '';
  };
in
{
  # Pulled in by `pkgs.opencloud.idp-web`, the login-page assets for the built-in
  # OIDC provider, which still builds with pnpm_9 (pkgs.opencloud.web moved to
  # pnpm_10 and is clean). Eval reaches it through IDP_ASSET_PATH in
  # opencloud-init-config's environment, so it fails before anything is built.
  #
  # The seven CVEs are all attacks by untrusted *input* to pnpm: a lockfile that
  # smuggles `--upload-pack=<cmd>` into git fetch (CVE-2026-50014), a patch file
  # with `../` in its paths (CVE-2026-50015), a codeload.github.com that serves a
  # tarball not matching the lockfile hash (CVE-2026-48995). None of those inputs
  # are attacker-reachable here: the lockfile and patches come from the pinned
  # opencloud source, the dependency fetch is a fixed-output derivation Nix
  # hash-checks itself, and the build phase has no network at all. pnpm is also
  # build-time only -- it is never in o700's runtime closure.
  #
  # This uses the old `permittedInsecurePackages` gate rather than the
  # `nixpkgs.config.problems.handlers.*` style used in hardware-configuration.nix,
  # because problems.nix defines only the maintainerless/broken/removal/deprecated
  # kinds. Insecurity is still handled by check-meta.nix on the older path.
  nixpkgs.config.permittedInsecurePackages = [ "pnpm-9.15.9" ];

  services = {
    vaultwarden = {
      enable = true;
      domain = "${config.seta.vaultwarden.proxy.domain}";
      backupDir = "${PATHS.BACKUP_ROOT}/warden";
      config = {
        ROCKET_PORT = PORTS.VAULTWARDEN;
        SIGNUPS_ALLOWED = false;
      };
    };

    gitea = {
      enable = true;
      lfs.enable = true;
      settings = {
        server = {
          DOMAIN = "${config.seta.gitea.proxy.domain}";
          HTTP_PORT = PORTS.GITEA;

          # Loopback so caddy is the only path in. The firewall already drops
          # this port from outside -- it is not in allowedTCPPorts -- so this
          # is the backup for the case where the firewall is the thing that
          # failed. Defence in depth is only depth if the layers fail
          # independently, and a bad nftables ruleset does not move a listener.
          HTTP_ADDR = "127.0.0.1";

          # The module derives this as http://<DOMAIN>:<HTTP_PORT>/, which here
          # is the loopback port over plain http -- a URL that resolves for
          # nobody. Gitea bakes ROOT_URL into the clone URLs it displays, its
          # webhook targets, OAuth redirects and outbound email links, so it has
          # to be the public name rather than the address it happens to bind.
          ROOT_URL = "https://${config.seta.gitea.proxy.domain}/";
        };

        # The session cookie is only ever presented over caddy's TLS, so mark it
        # Secure and let the browser refuse to send it in cleartext.
        session.COOKIE_SECURE = true;

        service.DISABLE_REGISTRATION = true;
      };

      database.type = "postgres";
    };

    odoo = {
      enable = true;
      # Pinned to 18 rather than the channel default (odoo19). odoo19 still
      # carries PyPDF2 3.0.1 at runtime (six CVEs: ReDoS + memory-safety in
      # the PDF parser). odoo18 drops PyPDF2 entirely (nixpkgs
      # pythonRemoveDeps) in favour of pypdf, which is maintained and clean.
      # odoo19 can be revisited once nixpkgs patches its PyPDF2 dependency.
      package = pkgs.odoo18;
      autoInit = true;
      autoInitExtraFlags = [ "--without-demo=all" ];

      # Sets settings.options.addons_path only. Odoo still appends its own
      # odoo/addons to odoo.addons.__path__ afterwards
      # (odoo/modules/module.py, initialize_sys_path), so naming a path here
      # does not cost us the built-in modules.
      addons = [ odooDarkMode ];

      settings.options = {
        # Bind loopback only — Caddy is the sole external path in.
        http_interface = "127.0.0.1";
        http_port = PORTS.ODOO;

        # Must be explicit: proxy_mode defaults to (domain != null), and we
        # intentionally leave domain null so the module skips its nginx setup.
        proxy_mode = true;

        # Unix socket path → libpq uses peer auth. Our PostgreSQL has
        # listen_addresses = "" (no TCP socket at all), so without this Odoo
        # can't connect to the database.
        db_host = "/run/postgresql";
        db_user = "odoo";

        list_db = false; # already the module default; explicit for clarity

        # Community ships a "Publisher: Update Notification" cron (mail/data/
        # ir_cron_data.xml) that POSTs weekly to the default
        # http://services.odoo.com/publisher-warranty/ -- over plain HTTP. The
        # payload (mail/models/update.py:44-61) is not a version check: it
        # carries dbuuid, dbname, user counts, web.base.url, the installed-app
        # list, and the acting user's company name, email and phone.
        #
        # It cannot be turned off from the UI -- the same data file rewrites
        # base.ir_cron_act's domain to filter this one record out of Scheduled
        # Actions.
        #
        # Pointing at a closed local port stops this specific payload at the
        # source, independently of whatever else is in the way. It is the inner
        # of two layers: the outer one is the tinyproxy egress filter
        # (networking.nix), which denies the whole odoo.com zone for
        # every request this service makes, not just this one.
        #
        # This does NOT silence the failure. The cron calls
        # update_notification(None); None is falsy, so both handlers take their
        # `raise` branch rather than the silent `return False`, and a UserError
        # traceback lands in the log weekly whether the send fails on DNS or on
        # connection-refused. Suppressing that means disabling the cron record
        # in the database, which is not expressible here.
        publisher_warranty_url = "http://127.0.0.1:1/";

        # Four, not the 2*cores+1 = 17 from Odoo's sizing note: that assumes a
        # dedicated machine and dozens of concurrent users. This one has eight
        # cores shared with jellyfin, the arr stack and opencloud, 16 GB with
        # no swap, and served 11k requests from a single client address across
        # the entire evaluation. Four drains that 111-request burst in about a
        # second. Raising it is this one line.
        workers = 4;

        # The websocket worker's port. Stated rather than left at its default
        # because caddy now has to name the same number -- see
        # seta.odoo.proxy.extraUpstreams below.
        gevent_port = PORTS.ODOO_GEVENT;

        # The connection pool is per *process*, and this change turns one
        # process into seven: 4 http + 2 cron + 1 gevent. Left at the 64
        # default that is a licence for 448 backends against a postgres whose
        # max_connections was still the stock 100, shared with gitea, n8n,
        # mealie, paperless and netdata (16 backends in use at the time of
        # writing). The service that got the `too many clients` would not
        # necessarily have been this one.
        #
        # 8 is generous for a worker that handles one request at a time; the
        # gevent worker is the one that genuinely multiplexes -- every live
        # browser tab is a connection it owns -- which is why Odoo gives it a
        # separate knob. Worst case is now 4*8 + 2*8 + 24 = 72, and
        # services-internal.nix raises max_connections to 200 so that number
        # is not the whole budget.
        db_maxconn = 8;
        db_maxconn_gevent = 24;

        # Raised from the 60s/120s defaults, which only take effect per worker
        # in multi-process mode. The workload that approaches them is module
        # installation: `ir.module.module/button_immediate_install` was
        # measured at 19-24s of wall time during the evaluation and the
        # process peaked at 1.2 GB of address space doing it. Installing a
        # localization pack on top of Accounting is a larger job than any of
        # those, and a worker SIGXCPU'd halfway through leaves a partially
        # installed module -- a materially worse outcome than a slow request.
        #
        # Nothing in 30 days came close even to the old limit_time_real: the
        # slowest request on record is 38s, and that was static files behind a
        # module install. The cost of the higher ceilings is that a genuinely
        # stuck request holds one of four workers for longer.
        limit_time_cpu = 300;
        limit_time_real = 600;
      };
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
  };

  seta = {
    odoo = {
      critical = true;

      # The Odoo NixOS module declares its own ensureDatabases/ensureUsers.
      # postgres = true here adds "odoo" to the central pg_dump backup run —
      # belt-and-suspenders; the duplicated CREATE-if-not-exists is harmless.
      postgres = true;

      backup = {
        enable = true;

        # /var/lib/private, not /var/lib. The unit is DynamicUser=true with
        # StateDirectory=odoo, so /var/lib/odoo is a symlink into the private
        # tree -- and restic archives a symlink as a symlink. Naming the
        # symlink produces a snapshot that succeeds, reports a plausible file
        # count and contains no filestore at all.
        #
        # `data` rather than the whole state directory: this is the filestore,
        # where every ir.attachment binary lives under filestore/odoo/. It is
        # content-addressed by sha1, so the files are immutable and restic sees
        # only genuinely new attachments each night.
        paths = [ "/var/lib/private/odoo/data" ];

        # Session cookies. Regenerated on demand, worthless a day later, and
        # they churn constantly -- the worst possible combination for dedup.
        exclude = [ "/var/lib/private/odoo/data/sessions" ];

        # Nothing else in that directory is excluded, and both survivors were
        # checked against the real host rather than inferred:
        #
        #   addons/               modules installed through the UI rather than
        #                         declared in `addons` above. Not reproducible
        #                         from this config, so not disposable.
        #   .odoo.initialized     zero bytes and load-bearing. autoInit's
        #                         pre-start runs `odoo --init=INIT --database=odoo`
        #                         whenever this file is absent (odoo.nix:191-196),
        #                         so a restore that dropped it would fire an
        #                         init pass at an already-populated database.

        # Accounting and myDATA-relevant records. Greek statutory retention
        # governs how long these have to survive, and it is measured in years,
        # not in the twelve months the shared monthly policy provides.
        keepYearly = 10;
      };

      dashboard = {
        enable = true;
        name = "Odoo";
        description = "ERP";
        group = "Apps";
        icon = "odoo.png";
      };

      proxy = {
        enable = true;
        port = PORTS.ODOO;

        # Multi-process mode moves the websocket off the main port. Only
        # GeventServer puts the raw connection into environ['socket'], so a
        # /websocket handshake arriving at an http worker hits a KeyError that
        # WebsocketConnectionHandler.open_connection re-raises as
        # `RuntimeError: Couldn't bind the websocket. Is the connection opened
        # on the evented port (8072)?` -- a 500 on every upgrade, with the
        # browser's worker retrying forever. Loud, not silent, but total.
        #
        # This is the same split the nixpkgs odoo module makes when it
        # generates its own nginx vhost (odoo + odoochat upstreams), which is
        # bypassed here because services.odoo.domain is left null.
        #
        # Two matchers rather than one `/websocket*`, which would also swallow
        # a hypothetical /websocketfoo. Everything under /websocket/ (health,
        # peek_notifications, update_bus_presence, on_closed) is an ordinary
        # http route either process can serve; sending it to the gevent worker
        # matches upstream's `location /websocket` and keeps the bus endpoints
        # together.
        extraUpstreams = {
          "/websocket" = PORTS.ODOO_GEVENT;
          "/websocket/*" = PORTS.ODOO_GEVENT;
        };

        # The bare apex, and the only service that does not follow the
        # `<name>.${DOMAIN}` convention. Odoo serves the public website and the
        # ERP backend from one process on one hostname *by design*, and nothing
        # in it can be configured otherwise:
        #
        #   - `request.is_frontend` is read off the route decorator
        #     (`routing.get('website', False)`, http_routing/models/ir_http.py),
        #     never off the Host header. `/odoo` is not a website route, so the
        #     website machinery -- including a website's Domain field -- is
        #     structurally blind to it.
        #   - There is no ALLOWED_HOSTS equivalent. The only host-aware gate
        #     Odoo has is `dbfilter`, which selects a *database*; with one
        #     database it selects nothing.
        #   - Access to the backend is gated on the user instead: non-internal
        #     users are bounced to /my (web/controllers/home.py), whatever
        #     hostname they arrived on.
        #
        # Upstream's own on-prem deployment guide agrees by example -- its
        # single nginx sample is one `server_name` carrying backend, website,
        # portal and websocket together. Splitting them across two names was
        # considered and rejected: it cannot be expressed in Odoo, so it would
        # have to live in caddy, where it buys obscurity rather than access
        # control and leaves generated links pointing at whichever name Odoo
        # decided to stamp on them.
        #
        # Costs one certificate. The managed wildcard is `*.${DOMAIN}` and a
        # wildcard does not match the bare parent, so caddy issues a second
        # cert for this name -- see the comment on the `*.${DOMAIN}` vhost in
        # networking.nix. That was already true before Odoo moved here (the
        # apex carried a hand-written redirect vhost), so the CT-log exposure
        # is unchanged.
        domain = DOMAIN;

        exposure = "WAN";
      };
    };

    vaultwarden = {
      # The backup directory lives on external ssd.
      requiresExSSD = true;

      critical = true;

      # backup-vaultwarden is the module's own nightly sqlite dump. It was
      # never named here, so it had been running with none of the three things
      # this list drives: no RequiresMountsFor, so it wrote to the bare
      # mount-point and filled the root disk whenever the SSD was absent; no
      # OnFailure, so a broken backup was silent; and no IPAddressDeny.
      # modules/seta.nix:161 and monitoring/notify.nix:114 both already claimed
      # it reached those consumers through this option.
      #
      # It is exactly the failure the assertion at the bottom of seta.nix
      # exists to catch, and the one case that assertion cannot see: it checks
      # that every *named* unit exists, not that every unit a service owns was
      # named.
      units = [
        "vaultwarden"
        "backup-vaultwarden"
      ];

      backup = {
        enable = true;

        # The live state directory, not ${PATHS.BACKUP_ROOT}/warden. Reading
        # the module's own backup copy would make restic's input depend on
        # another job having succeeded first, and would leave the restore path
        # writing to a directory nothing reads. Capturing the source directly
        # keeps this service shaped like every other one -- and leaves
        # backup-vaultwarden as a genuinely independent second mechanism
        # rather than a link in this chain.
        paths = [ "/var/lib/vaultwarden" ];

        sqlite = [ "/var/lib/vaultwarden/db.sqlite3" ];

        exclude = [
          # Favicons fetched from the sites users store logins for. Purely a
          # cache, and one that churns.
          "/var/lib/vaultwarden/icon_cache"
          "/var/lib/vaultwarden/tmp"
        ];

        # db.sqlite3 and its -wal/-shm/-journal siblings are excluded
        # automatically because they are named in `sqlite` above -- see the
        # exclude derivation in backup.nix.

        # attachments/ is irreplaceable and is the reason the whole directory
        # is archived rather than an enumerated list. sends/ does not exist yet
        # -- vaultwarden creates it the first time somebody uses Send -- and
        # archiving the directory rather than its current contents is exactly
        # what means nobody has to remember to add it then.
        #
        # rsa_key.pem is a different and much milder case, worth stating so it
        # is not mistaken for the first kind: it signs the JWT access tokens
        # clients hold, nothing more. The vault itself is encrypted client-side
        # under each user's master password and this key is not involved, so
        # losing it costs one re-login per device and destroys nothing. It is
        # backed up because a recovery nobody notices beats one that logs
        # everybody out, not because the data depends on it.
      };

      dashboard = {
        enable = true;
        name = "Vaultwarden";
        description = "Password & Secrets manager";
        group = "Files & Sharing";
        icon = "vaultwarden.png";
      };

      proxy = {
        enable = true;
        port = PORTS.VAULTWARDEN;
        domain = "vault.${DOMAIN}";
        exposure = "WAN";
      };
    };

    gitea = {
      # Due to network confinement, Gitea repository mirrors over ssh:// do break: they spawn git/ssh
      # subprocesses that ignore HTTP_PROXY entirely, so there is no route for them.
      # https:// mirrors are fine. Clone-over-SSH *into* gitea is unaffected -- that
      # is the host's sshd, which has no seta entry and is not confined.

      critical = true;

      postgres = true;

      backup = {
        enable = true;

        # The whole state directory in one path, because almost all of it is
        # irreplaceable and enumerating the good parts is how you miss one.
        # It holds repositories/ (the git objects), data/lfs, data/attachments,
        # data/avatars, data/packages -- and custom/conf, which is the part
        # that is easy to forget.
        #
        # custom/conf/secret_key is the one that matters, and it is not a
        # session key. Gitea uses it to encrypt columns *in the database*: TOTP
        # secrets, OAuth2 application client secrets, Actions secrets. Restore
        # the database without it and that ciphertext is undecryptable -- every
        # 2FA-enrolled user is locked out rather than merely logged out, and the
        # only way back in is an admin disabling 2FA per user from the CLI.
        # (Which columns exactly varies by Gitea version; confirm against the
        # running one before relying on the list.)
        #
        # The other three in that directory are far milder and are here for
        # completeness rather than urgency: oauth2_jwt_secret costs third-party
        # integrations a re-authorisation, lfs_jwt_secret signs tokens that live
        # for minutes, and internal_token authenticates the git hook binary
        # calling back into the server -- a mismatch breaks pushes until it is
        # fixed, which is operational rather than lossy.
        paths = [ "/var/lib/gitea" ];

        exclude = [
          "/var/lib/gitea/log"

          # The bleve code-search index and the queue spool: both rebuilt from
          # the repositories and the database, both rewritten constantly.
          "/var/lib/gitea/data/indexers"
          "/var/lib/gitea/data/queues"

          # Generated repo archives -- the tarball you get from "Download ZIP".
          # Gitea treats these as a cache and deletes them itself on a cron
          # (repo-archive DELETE_OLDER_THAN, 24h by default), so archiving them
          # stores blobs their own owner intends to throw away. Found on the
          # host; it is not visible anywhere in the nixpkgs module.
          "/var/lib/gitea/data/repo-archive"

          # A symlink into the nix store, planted by the module's own tmpfiles
          # rule (`L+ conf/locale -> ${package}/locale`, gitea.nix:773).
          #
          # Worth excluding despite being a single symlink, because restoring
          # it is the problem rather than storing it: it would come back
          # pointing at whichever gitea store path existed when the snapshot
          # was taken, which after a version bump or a garbage collection no
          # longer exists. The tmpfiles rule re-plants the correct one on
          # activation, so the right move is to let it own that path entirely.
          "/var/lib/gitea/conf/locale"

          # The two below are DEFENSIVE, not observed: neither directory exists
          # on the host today. tmp/ appears only once chunked package uploads
          # are used (gitea.nix:713), and data/sessions/ only if the session
          # PROVIDER is switched from the default `memory` to `file`. Excluding
          # them now means neither can start being archived silently later.
          "/var/lib/gitea/tmp"
          "/var/lib/gitea/data/sessions"

          # services.gitea.dump.enable is false, so this is empty -- excluded
          # on the same defensive grounds, so that turning the built-in dump on
          # does not start storing a second copy of every repository inside
          # this snapshot.
          "/var/lib/gitea/dump"
        ];

        # Kept, having walked the real directory. The two that look like
        # scratch and are not:
        #
        #   data/jwt/       the RSA private key Gitea signs OAuth2/OIDC tokens
        #                   with. A secret, generated once, living nowhere
        #                   else -- and not one of the four in custom/conf, so
        #                   it is easy to miss when reasoning from that list.
        #   .ssh/           gitea's own authorized_keys, which it rewrites as
        #                   users add and remove SSH keys. Empty today because
        #                   nobody has added one.
      };

      dashboard = {
        enable = true;
        name = "Gitea";
        description = "Git hosting";
        group = "Apps";
        icon = "gitea.png";
      };

      proxy = {
        enable = true;
        port = PORTS.GITEA;
        domain = "git.${DOMAIN}";
        exposure = "WAN";
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
        exposure = "WAN";
      };
    };
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
}
