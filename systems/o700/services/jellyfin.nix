{
  NAME = "Jellyfin";
  SUB-DOMAIN = "fin";
  PORT = 8096;

  SERVICE = "jellyfin";

  config = { toDomain, ... }: {
    enable = true;
    dataDir = "/mnt/ex-ssd/jellyfin";
  };
}
