rec {
  NAME = "Bazarr";
  SUB-DOMAIN = "bazarr";
  PORT = 6767;
  GROUP = "Downloads";
  DESCRIPTION = "Subtitles";
  ICON = "bazarr.png";

  SERVICE = "bazarr";

  config = { MEDIA_GROUP, ... }: {
    enable = true;
    group = MEDIA_GROUP;
    listenPort = PORT;
  };
}
