rec {
  NAME = "Seerr";
  SUB-DOMAIN = "seerr";
  PORT = 5055;

  SERVICE = "seerr";

  config = _: {
    enable = true;
    port = PORT;
  };
}
