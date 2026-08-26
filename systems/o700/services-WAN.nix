{
  config,
  lib,
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

    vikunja = {
      enable = true;
      frontendScheme = "https";
      frontendHostname = config.seta.vikunja.proxy.domain;
      port = PORTS.VIKUNJA;
      database = {
        type = "postgres";
        # Leading slash → libpq treats this as a unix socket directory, which
        # selects peer authentication: the OS user "vikunja" (from DynamicUser)
        # is the credential, so no password is needed or stored anywhere.
        host = "/run/postgresql";
        user = "vikunja";
        database = "vikunja";
      };
      # The module defaults to ":port" (all interfaces). Loopback so caddy is
      # the only path in; the firewall not listing this port is the second layer.
      settings.service.interface = lib.mkForce "127.0.0.1:${toString PORTS.VIKUNJA}";
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
        };

        service.DISABLE_REGISTRATION = true;
      };

      database.type = "postgres";
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

  systemd.services.vikunja = {
    after = [ "postgresql.target" ];
    requires = [ "postgresql.target" ];
  };

  seta = {
    vaultwarden = {
      # The backup directory lives on external ssd.
      requiresExSSD = true;

      critical = true;

      dashboard = {
        enable = true;
        name = "Vaultwarden";
        description = "Password & Secrets manager";
        group = "Apps";
        icon = "vaultwarden.png";
      };

      proxy = {
        enable = true;
        port = PORTS.VAULTWARDEN;
        domain = "vault.${DOMAIN}";
        exposure = "WAN";
      };
    };

    vikunja = {
      critical = true;
      postgres = true;

      dashboard = {
        enable = true;
        name = "Vikunja";
        description = "Task management";
        group = "Apps";
        icon = "vikunja.png";
      };

      proxy = {
        enable = true;
        port = PORTS.VIKUNJA;
        domain = "vikunja.${DOMAIN}";
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
