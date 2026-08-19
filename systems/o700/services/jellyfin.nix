{
  NAME = "Jellyfin";
  SUB-DOMAIN = "fin";
  PORT = 8096;
  GROUP = "Media";
  DESCRIPTION = "Media server";
  ICON = "jellyfin.png";

  SERVICE = "jellyfin";

  config = { toDomain, ... }: { enable = true; };
}
