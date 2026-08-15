rec {
  NAME = "Gitea";
  SUB-DOMAIN = "git";
  PORT = 8001;
  DB-PORT = 9001;
  GROUP = "Apps";
  DESCRIPTION = "Git hosting";
  ICON = "gitea.png";

  SERVICE = "gitea";

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
