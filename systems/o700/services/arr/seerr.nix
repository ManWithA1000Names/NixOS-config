rec {
  NAME = "Seerr";
  SUB-DOMAIN = "seerr";
  PORT = 5055;
  GROUP = "Media";
  DESCRIPTION = "Media requests";
  ICON = "jellyseerr.png";

  SERVICE = "seerr";

  config = _: {
    enable = true;
    port = PORT;
  };
}
