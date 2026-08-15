rec {
  NAME = "Prowlarr";
  SUB-DOMAIN = "prowlarr";
  PORT = 9696;
  GROUP = "Downloads";
  DESCRIPTION = "Indexers";
  ICON = "prowlarr.png";

  SERVICE = "prowlarr";

  config = _: {
    enable = true;
    settings.server.port = PORT;
  };
}
