rec {
  NAME = "Radarr";
  SUB-DOMAIN = "radarr";
  PORT = 7878;
  GROUP = "Downloads";
  DESCRIPTION = "Movies";
  ICON = "radarr.png";

  SERVICE = "radarr";

  config = { MEDIA_GROUP, ... }: {
    enable = true;
    group = MEDIA_GROUP;
    settings.server.port = PORT;
  };
}
