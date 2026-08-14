rec {
  NAME = "Sonarr";
  SUB-DOMAIN = "sonarr";
  PORT = 8989;

  SERVICE = "sonarr";

  config = { MEDIA_GROUP, ... }: {
    enable = true;
    group = MEDIA_GROUP;
    settings.server.port = PORT;
  };
}
