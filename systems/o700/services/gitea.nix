rec {
  NAME = "Gitea";
  SUB-DOMAIN = "git";
  PORT = 8001;
  DB-PORT = 9001;
  GROUP = "Apps";
  DESCRIPTION = "Git hosting";
  ICON = "gitea.png";

  SERVICE = "gitea";

  # JSON access log for the caddy-badauth fail2ban jail (login failures).
  CADDY_EXTRA_CONFIG = ''
    log {
      output file /var/log/caddy/access-git.log {
        roll_size 20MiB
        roll_keep 5
      }
      format json
    }
    reverse_proxy localhost:${builtins.toString PORT}
  '';

  config = { toDomain, ... }: {
    enable = true;
    lfs.enable = true;
    settings.server = {
      domain = toDomain SUB-DOMAIN;
      HTTP_PORT = PORT;
    };

    database.port = DB-PORT;
  };
}
