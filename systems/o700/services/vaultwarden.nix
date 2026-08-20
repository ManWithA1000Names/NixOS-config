rec {
  NAME = "Vaultwarden";
  SUB-DOMAIN = "vault";
  PORT = 9999;
  GROUP = "Apps";
  DESCRIPTION = "Password manager";
  ICON = "vaultwarden.png";

  SERVICE = "vaultwarden";

  # JSON access log for the caddy-badauth fail2ban jail (login failures).
  CADDY_EXTRA_CONFIG = ''
    log {
      output file /var/log/caddy/access-vault.log {
        roll_size 20MiB
        roll_keep 5
      }
      format json
    }
    reverse_proxy localhost:${builtins.toString PORT}
  '';

  config = { toDomain, ... }: {
    enable = true;
    domain = toDomain SUB-DOMAIN;
    config = { ROCKET_PORT = PORT; };
    backupDir = "/mnt/ex-ssd/backup/warden/";
  };
}
