rec {
  NAME = "Radarr";
  SUB-DOMAIN = "radarr";
  PORT = 7878;

  SERVICE = "radarr";

  config = { MEDIA_GROUP, ... }: {
    enable = true;
    group = MEDIA_GROUP;
    settings.server.port = PORT;
  };
}
