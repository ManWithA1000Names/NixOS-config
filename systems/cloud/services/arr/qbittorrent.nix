rec {
  NAME = "qBittorrent";
  SUB-DOMAIN = "qbit";
  PORT = 8080;

  SERVICE = "qbittorrent";

  config = { MEDIA_GROUP, ... }: {
    enable = true;
    group = MEDIA_GROUP;
    webuiPort = PORT;
  };

  CADDY_EXTRA_CONFIG = ''
    reverse_proxy localhost:${builtins.toString PORT} {
      header_up Host localhost:${builtins.toString PORT}
      header_up -Origin
      header_up -Referer
    }
  '';
}
