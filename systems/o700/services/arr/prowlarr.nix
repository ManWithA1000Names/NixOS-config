rec {
  NAME = "Prowlarr";
  SUB-DOMAIN = "prowlarr";
  PORT = 9696;

  SERVICE = "prowlarr";

  config = _: {
    enable = true;
    settings.server.port = PORT;
  };
}
