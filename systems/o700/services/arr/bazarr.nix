rec {
  NAME = "Bazarr";
  SUB-DOMAIN = "bazarr";
  PORT = 6767;

  SERVICE = "bazarr";

  config = { MEDIA_GROUP, ... }: {
    enable = true;
    group = MEDIA_GROUP;
    listenPort = PORT;
  };
}
