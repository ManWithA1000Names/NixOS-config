{
  config,
  lib,
  PORTS,
  DOMAIN,
  PATHS,
  ...
}:
{
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
