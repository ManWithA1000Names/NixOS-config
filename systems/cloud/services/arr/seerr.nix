rec {
  NAME = "Seerr";
  SUB-DOMAIN = "serr";
  PORT = 5055;

  SERVICE = "serr";

  config = _: {
    enable = true;
    settings.server.port = PORT;
  };
}
