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
      CADDY_HTTPS = 443;
      CADDY_ADMIN = 2019;
      KAVITA = 5000;
      DNSCRYPT = 5335;
      MDNS = 5353;
      RESOLVED = 5355;
      # Postgres does not bind to this port as of yet.
      # All connection with it is done through local sockets.
      POSTGRESQL = 5432;
      SEERR = 5055;
      # The editor/webhook front door only. n8n also runs a task broker on
      # 5679, which the in-process Code-node runner connects back to; it binds
      # 127.0.0.1 by its own default (N8N_RUNNERS_BROKER_LISTEN_ADDRESS) and
      # nothing here refers to it by number.
      N8N = 5678;
      RADARR = 7878;
      DASHBOARD = 8000;
      GITEA = 8001;
      MEALIE = 8002;
      QBITTORRENT = 8080;
      JELLYFIN = 8096;
      # claude-code-api. Upstream's own default for `listen`, restated here
      # because caddy has to name the same number: the vhost is generated from
      # seta.<svc>.proxy.port, so leaving the service on its default and the
      # proxy on a guess is how the two drift apart.
      CLAUDE_CODE_API = 8817;
      TINYPROXY = 8888;
      SONARR = 8989;
      # Only the proxy front door. Fullstack mode starts ~34 more listeners
      # (9100-9290 plus a few high ones, and NATS on 9233); they are internal,
      # bind loopback themselves, and nothing here refers to them by number.
      ODOO = 8069;
      # Odoo's second listener. In multi-process mode the websocket endpoint
      # is served by a separate gevent worker on its own port, and the regular
      # http workers answer /websocket with a 500 -- so caddy has to know this
      # number too (seta.odoo.proxy.extraUpstreams, services-WAN.nix). It is
      # Odoo's own default for gevent_port; named here so the config and the
      # proxy cannot drift apart. Loopback-bound like ODOO above, because
      # GeventServer takes its interface from http_interface.
      ODOO_GEVENT = 8072;
      OPENCLOUD = 9200;
      PROWLARR = 9696;
      VAULTWARDEN = 9999;
      NETDATA = 19999;
      PAPERLESS = 28981;
      MAILPIT_SMTP = 1025;
      MAILPIT_HTTP = 8025;
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

      # The restic repository holding every backup set. On the SSD rather than
      # the root spindle: the root disk is the thing most likely to be lost, and
      # a backup that dies with its source is not one. It also keeps the nightly
      # write load off the disk whose I/O contention took this host down once
      # already (see the swapDevices note in o700/hardware-configuration.nix).
      RESTIC_REPO = "${BACKUP_ROOT}/restic";

      # Where each set's database dumps and version manifest are written before
      # restic archives them. Deliberately NOT inside RESTIC_REPO -- restic
      # refuses to back up a path inside its own repository, and the two have
      # opposite lifetimes: the repo is permanent, this is wiped after every run.
      BACKUP_STAGING = "${BACKUP_ROOT}/staging";

      # Kavita's book and manga library.
      #
      # MUST BE SET before the kavita-library backup set does anything useful.
      # Unlike the arr stack, whose directories are created by tmpfiles rules in
      # services-internal.nix, Kavita's library paths are configured in-app and
      # live only inside its SQLite database -- so nothing in this repo knows
      # where they are. Naming the path here rather than leaving it implicit is
      # what lets the backup set reference it at all.
      #
      # Empty string means "not configured yet", and systems/o700/backup.nix asserts
      # on it rather than silently backing up nothing.
      BOOKS = "${EX-SSD}/books";
    };

    # Offsite backup target. Not secret -- a bucket name is not a credential,
    # and the actual keys live in secrets/restic-b2.age. Kept here so the repo
    # string is built in one place and the restore script and the backup units
    # cannot disagree about which bucket they are talking to.
    #
    # The S3-compatible endpoint rather than restic's native `b2:` backend:
    # upstream recommends it, and it is the form that works through this host's
    # egress proxy, which permits CONNECT on 443 only (networking.nix,
    # tinyproxy ConnectPort). An SFTP-based provider would need that hole
    # widened; this needs nothing.
    #
    # MUST BE SET before the offsite tier does anything. Empty means "local
    # only", which systems/o700/backup.nix handles by not generating the offsite
    # unit at all rather than by generating one that fails every night.
    BACKUP = {
      # The bucket NAME, not the bucket ID. restic addresses S3 buckets by
      # name; the 24-character hex id B2 also shows you belongs to B2's native
      # API and is not used anywhere here.
      #
      # Must match the bucket exactly: B2 bucket names are case-sensitive
      # identifiers, and the S3-compatible endpoint additionally addresses them
      # as a DNS label in virtual-hosted style, where mixed case is a known
      # source of signature failures. Lowercase is both required and correct.
      # Names are globally unique and cannot be renamed.
      b2Bucket = "backup-o700";

      # Verified against the bucket's own "Endpoint" field in the B2 console.
      # It is region-specific, so it must be re-checked if the bucket is ever
      # recreated elsewhere.
      b2Endpoint = "s3.eu-central-003.backblazeb2.com";
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
