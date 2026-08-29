{
  pkgs,
  config,
  PORTS,
  DOMAIN,
  PATHS,
  ...
}:
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

      settings.options = {
        # Bind loopback only — Caddy is the sole external path in.
        http_interface = "127.0.0.1";
        http_port      = PORTS.ODOO;

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
        # (services-internal.nix), which denies the whole odoo.com zone for
        # every request this service makes, not just this one.
        #
        # This does NOT silence the failure. The cron calls
        # update_notification(None); None is falsy, so both handlers take their
        # `raise` branch rather than the silent `return False`, and a UserError
        # traceback lands in the log weekly whether the send fails on DNS or on
        # connection-refused. Suppressing that means disabling the cron record
        # in the database, which is not expressible here.
        publisher_warranty_url = "http://127.0.0.1:1/";

        # Single-process mode for the evaluation period.
        # NOTE: Odoo's Discuss (chat) real-time features are BROKEN in this
        # mode. To fix them two things are needed:
        #   1. Set workers > N (Odoo docs recommend 2*(CPU cores)+1 for HTTP
        #      workers) — this switches Odoo to multi-process mode and starts
        #      a gevent longpolling worker on port 8072.
        #   2. Proxy /websocket to 127.0.0.1:8072 in Caddy. The seta system
        #      has no template for a second upstream; the simplest approach is
        #      a `handle /websocket*` block added to the Caddy vhost generation
        #      in networking.nix, either as a seta option or hardcoded for odoo.
        workers = 0;
      };
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
  };

  # The proxy variables themselves are host-wide now (systemd.globalEnvironment
  # in services-internal.nix); Odoo inherits them like everything else. What
  # stays here is the part that is specific to this service: making the proxy
  # compulsory rather than merely configured.
  #
  # Every other service *honours* HTTP_PROXY and could equally ignore it --
  # fine, since for them the proxy is there to observe traffic. Odoo is the one
  # service actively distrusted, so it is denied any route off the host except
  # loopback, and the proxy stops being a setting it reads and becomes the only
  # path that exists. requests does honour it (trust_env defaults true, and the
  # phone-home at mail/models/update.py:73 is a plain requests.post), but that
  # is not something to depend on.
  #
  # Still not a blanket egress block: tinyproxy fetches on Odoo's behalf, so
  # ordinary outbound HTTP keeps working and only the odoo.com zone is refused.
  systemd.services.odoo.serviceConfig = {
    # localhost covers 127.0.0.0/8 and ::1: tinyproxy outbound, and Caddy's
    # inbound reverse-proxy connection. The PostgreSQL socket is a unix socket
    # and is not subject to address filtering at all.
    #
    # NOTE: this also blocks direct outbound SMTP. smtplib does not speak HTTP
    # proxies, so configuring Odoo email later means allowing the relay
    # explicitly here -- it will not route itself through tinyproxy.
    IPAddressDeny = "any";
    IPAddressAllow = "localhost";
  };

  seta = {
    odoo = {
      critical = true;

      # The Odoo NixOS module declares its own ensureDatabases/ensureUsers.
      # postgres = true here adds "odoo" to the central pg_dump backup run —
      # belt-and-suspenders; the duplicated CREATE-if-not-exists is harmless.
      postgres = true;

      dashboard = {
        enable      = true;
        name        = "Odoo";
        description = "ERP";
        group       = "Apps";
        icon        = "odoo.png";
      };

      proxy = {
        enable   = true;
        port     = PORTS.ODOO;
        domain   = "erp.${DOMAIN}";
        exposure = "WAN";
      };
    };

    vaultwarden = {
      # The backup directory lives on external ssd.
      requiresExSSD = true;

      critical = true;

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
        exposure = "WAN";
      };
    };

    gitea = {
      critical = true;

      postgres = true;

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
  };
}
