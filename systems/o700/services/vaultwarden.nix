rec {
  NAME = "Vaultwarden";
  SUB-DOMAIN = "vault";
  PORT = 9999;
  GROUP = "Apps";
  DESCRIPTION = "Password manager";
  ICON = "vaultwarden.png";

  SERVICE = "vaultwarden";

  config = { toDomain, ... }: {
    enable = true;
    domain = toDomain SUB-DOMAIN;
    config = { ROCKET_PORT = PORT; };
    backupDir = "/mnt/ex-ssd/backup/warden/";
  };
}
