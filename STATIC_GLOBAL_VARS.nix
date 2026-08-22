let
  VARS = {
    USERNAME = "user";

    MEDIA_GROUP = "media";

    DOMAIN = "o700.net";

    IP = {
      cloudflare-dns = "1.1.1.1";

      # IPv4 only. This is used as a firewall source-CIDR and as a fail2ban
      # ignore list, both of which must fail closed: the LAN interface also
      # carries globally routable IPv6, so an IPv6 form of this would match
      # the entire internet.
      lan = "192.168.1.0/24";

      # These IPs are guaranteed by the router it self.
      router = "192.168.1.1";
      big-boss = "192.168.1.107";
      o700 = "192.168.1.108";
    };

    PORTS = {
      SSHD = 22;
      DNSMASQ = 53;
      CADDY_HTTP = 80;
      RPC_BIND = 111;
      CADDY_HTTPS = 443;
      CADDY_ADMIN = 2019;
      NFS = 2049;
      KAVITA = 5000;
      DNSCRYPT = 5335;
      MDNS = 5353;
      RESOLVED = 5355;
      SEERR = 5055;
      BAZARR = 6767;
      RADARR = 7878;
      DASHBOARD = 8000;
      GITEA = 8001;
      MEALIE = 8002;
      QBITTORRENT = 8080;
      JELLYFIN = 8096;
      SONARR = 8989;
      PROWLARR = 9696;
      VAULTWARDEN = 9999;
      NETDATA = 19999;
      PAPERLESS = 28981;
      QBITTORRENT_TORRENT = 44995;
    };

    PATHS = rec {
      EX-SSD = "/mnt/ex-ssd";

      # Shared media storage for the Arr stack, qBittorrent and Jellyfin.
      # Downloads and the final library live under a single root on the same
      # filesystem so Sonarr/Radarr can import via instant hardlinks + atomic
      # moves (no copy, no extra disk usage, seeding keeps working).
      MEDIA_ROOT = "${EX-SSD}/media";

      BACKUP_ROOT = "${EX-SSD}/backup";
    };
  };
in
assert
  (builtins.foldl' (
    ports: port:
    assert !builtins.hasAttr (toString port) ports;
    {
      ${toString port} = true;
    }
    // ports
  ) { ok = true; } (builtins.attrValues VARS.PORTS)).ok;
# Returns the static variables.
VARS
