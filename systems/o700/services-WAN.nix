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

    leantime = {
      enable = true;
      appUrl = "https://${config.seta.leantime.proxy.domain}";
      environmentFile = config.age.secrets.leantime-session.path;
      settings = {
        LEAN_ALLOW_TELEMETRY = false;
        LEAN_DEFAULT_TIMEZONE = "Europe/Athens";
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

    leantime = {
      critical = true;
      postgres = true;

      # phpfpm-leantime is the actual unit; "leantime" does not exist as a
      # systemd unit, so the default units = [ name ] would silently wire
      # OnFailure to a ghost unit.
      units = [ "phpfpm-leantime" ];

      dashboard = {
        enable = true;
        name = "Leantime";
        description = "Project management";
        group = "Apps";
        icon = "leantime.png";
      };

      proxy = {
        enable = true;
        domain = "leantime.${DOMAIN}";
        # Placeholder: leantime speaks FastCGI over a unix socket, not HTTP.
        # This value satisfies the required seta.proxy.port type but is never
        # bound to. The actual handler is in proxy.config below.
        port = PORTS.LEANTIME;
        exposure = "WAN";
        config = ''
          root * ${config.services.leantime.package}/share/leantime/public
          php_fastcgi unix//run/phpfpm/leantime.sock
          file_server
        '';
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
