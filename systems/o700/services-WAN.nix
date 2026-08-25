{
  config,
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

      # MIGRATION STEP 3 -- uncomment together with seta.gitea.postgres.
      #
      # The biggest single payoff here: gitea's sqlite file is the largest and
      # busiest state on this host. `createDatabase` already defaults true and
      # `socket` then defaults to /run/postgresql, so type alone is enough --
      # and unlike mealie, gitea reads the configured port back
      # (database.port defaults to pg.settings.port), so it is the one service
      # that would survive POSTGRESQL moving off 5432.
      #
      # No built-in converter. Stock pkgs.pgloader should serve -- gitea's xorm
      # identifiers are lowercase snake_case, so it avoids the quoting bug --
      # but rehearse against a *copy* of /var/lib/gitea/data/gitea.db and
      # compare row counts before pointing the live instance at the result.
      #
      database.type = "postgres";
    };
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

    gitea = {
      critical = true;

      # MIGRATION STEP 3 -- uncomment with services.gitea.database above.
      # postgres = true;

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
