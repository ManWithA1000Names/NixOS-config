{
  pkgs,
  lib,
  config,
  IP,
  PORTS,
  DOMAIN,
  USERNAME,
  ...
}:
let
  # Source ranges permitted to reach a vhost, keyed by seta exposure level.
  # This is where seta.<svc>.proxy.exposure stops being documentation and
  # starts being enforcement.
  #
  # Caddy is the only place this *can* be enforced: every vhost shares port
  # 443, so nftables cannot tell them apart, and the router's DNAT rewrites the
  # destination to this host's LAN address, so `bind` cannot either. remote_ip
  # is the sole discriminator. The firewall remains the second layer -- service
  # ports are absent from allowedTCPPorts, so a direct hit on e.g. :8096 is
  # dropped regardless of what happens here.
  #
  # IP.o700 is present even in NONE, so that anything on this host reaching an
  # internal service by name still matches: dnsmasq answers with this host's
  # LAN address, so such a request leaves and re-enters via that address rather
  # than 127.0.0.1. Nothing currently depends on this -- the monitoring that
  # did was removed -- but allowing it widens nothing, since that address is
  # this host.
  #
  # IPv4-only for the LAN range, for the same reason IP.lan itself is: this
  # interface also carries globally routable IPv6, so an IPv6 form would match
  # the entire internet. LAN clients resolve internal names through dnsmasq,
  # which answers A records only (local=/o700.net/ makes AAAA return NODATA),
  # so they arrive over IPv4 and match. A LAN device that bypasses dnsmasq --
  # a phone with its own DoH, say -- and connects over IPv6 is treated as WAN.
  vhostSources = rec {
    NONE = [
      "127.0.0.1/32"
      "::1/128"
      "${IP.o700}/32"
    ];
    LAN = NONE ++ [
      IP.big-boss
      IP.lan
    ];
    WAN = [ ];
  };

  # Applied to every vhost regardless of exposure. Deliberately excludes a
  # Content-Security-Policy: a useful one has to be written per-application,
  # and a generic one breaks every app behind this proxy.
  securityHeaders = ''
    header {
      # No `preload`. Preloading is baked into browser binaries and takes
      # months to reverse; plain max-age is revocable by lowering it.
      Strict-Transport-Security "max-age=31536000; includeSubDomains"
      X-Content-Type-Options nosniff
      # SAMEORIGIN rather than DENY: Netdata's dashboard and Jellyfin's web
      # client both frame same-origin content, which DENY would break.
      X-Frame-Options SAMEORIGIN
      Referrer-Policy strict-origin-when-cross-origin
      # Caddy sends no version, but no reason to name the software either.
      -Server
    }
  '';

  # Applied to every vhost, ahead of the per-service headers.
  #
  # Caddy *appends* to a client-supplied X-Forwarded-For rather than replacing
  # it, and forwards a client-supplied X-Real-IP untouched. So without these, a
  # request carrying its own X-Real-IP decides what vaultwarden logs and
  # rate-limits on (IP_HEADER defaults to X-Real-IP), and one carrying its own
  # X-Forwarded-For decides it for any backend that reads the leftmost entry.
  # Overwriting both makes the address this host actually observed the only one
  # a backend can see, whatever its parsing does.
  #
  # Safe to set unconditionally only because caddy is the edge here: there is no
  # upstream proxy whose forwarded value would be discarded. That stops being
  # true the moment anything fronts this host -- same trigger as the Cloudflare
  # warning on the caddy-badauth jail below.
  forwardedHeaders = {
    "X-Forwarded-For" = "{http.request.remote.host}";
    "X-Real-IP" = "{http.request.remote.host}";
  };

  vhostConfig =
    proxy:
    let
      # Per-service headers last, so a service can still override: qbittorrent
      # replaces Host, and anything here could need the same treatment.
      headerLines =
        lib.mapAttrsToList (k: v: "header_up ${k} ${v}") (forwardedHeaders // proxy.headers)
        ++ map (k: "header_up -${k}") proxy.removeHeaders;

      # No bare `reverse_proxy` form any more: forwardedHeaders makes headerLines
      # non-empty for every service that goes through this template.
      handler =
        if proxy.config != "" then
          proxy.config
        else
          ''
            reverse_proxy localhost:${toString proxy.port} {
              ${lib.concatStringsSep "\n      " headerLines}
            }
          '';

      sources = vhostSources.${proxy.exposure};

      # 404, not 403 -- matching what the wildcard vhost answers for names no
      # service claims. An outside scanner therefore cannot distinguish a
      # LAN-only service from a name that does not exist, where 403 would
      # confirm it is there and worth coming back to. The request is logged
      # either way, so blocked attempts remain visible in the journal, and
      # the caddy-scan jail below counts them.
      #
      # log_append marks the line so the caddy-exposure jail can act on "turned
      # away by the guard" rather than on the bare 404, which is ambiguous --
      # every application here emits 404s of its own, which is why caddy-scan
      # has to sit at 40 hits. Marking it at the point the decision is made,
      # rather than regexing the hostname downstream, keeps it generic: it
      # covers LAN vhosts as well as NONE ones and does not depend on the
      # *-internal naming convention holding.
      #
      # `handle` rather than a bare `respond`, because log_append has a fixed
      # position in Caddy's directive order and the two must fire as one unit.
      # Sibling to the handler below inside the same `route`: a request that
      # does not match @blocked falls through to it unchanged.
      guard = lib.optionalString (sources != [ ]) ''
        @blocked not remote_ip ${lib.concatStringsSep " " sources}
        handle @blocked {
          log_append ban_reason "exposure-guard"
          respond 404
        }
      '';
    in
    # `route` wraps the handler so evaluation follows written order. Outside a
    # route block Caddy imposes its own directive order, in which `respond` and
    # `reverse_proxy` have a fixed relative position that is not the one
    # written here -- the guard would be silently bypassed, which is the worst
    # possible failure mode for an access control.
    ''
      ${securityHeaders}
      route {
        ${guard}
        ${handler}
      }
    '';

  # Blocklist for the egress proxy below. One rule per line, POSIX ERE
  # (FilterType is set to "ere"); "#" starts a comment.
  #
  # This is one global list. tinyproxy has no per-client filter and every client
  # here is 127.0.0.1, so every entry applies to every service on the host --
  # "block this name for one app only" is not expressible. It was odooFilter
  # while Odoo was the only client; the proxy went host-wide in 5fc36fc and the
  # name stopped describing it.
  egressFilter = pkgs.writeText "tinyproxy-egress-filter" ''
    # Matches odoo.com and every subdomain of it, and nothing else. The
    # alternation anchors to a label boundary, so this catches iap.odoo.com and
    # iap-services.odoo.com while leaving lookalikes such as xodoo.com and
    # odoo.com.example.net alone -- which an unanchored "odoo\.com" would not.
    (^|\.)odoo\.com$

    # Kavita's anonymous usage telemetry. Kavita does have an in-app toggle for
    # this, but it lives in Kavita's SQLite database, where no rebuild can
    # assert it and a restored backup can quietly revert it.
    ^stats\.kavitareader\.com$

    # Gravatar. Gitea (federated avatars default on) and Jellyseerr both resolve
    # user avatars by sending an MD5 of the user's email address to Automattic
    # on every render. Both degrade to locally generated avatars.
    ^www\.gravatar\.com$

    # Netdata Cloud, pre-emptively -- nothing has requested it, this is here so
    # a future claim cannot happen quietly. Outermost of three layers, and still
    # the least reliable of them: the ACLK is MQTT over WebSocket and takes its
    # proxy from netdata's own config key rather than from HTTP_PROXY, so if it
    # ever ran it might never issue a CONNECT for this list to match.
    #
    # It would not escape, though -- it would fail earlier. netdata is confined
    # (seta.netdata.networkConfinement), so a direct socket to app.netdata.cloud
    # has no route: the allow list is loopback and the LAN, and reaching a public
    # address means a public peer regardless of which box forwards the packet.
    # That is the second layer. The one that holds is `cloud.conf` in
    # monitoring/netdata.nix, which stops the link from starting at all.
    (^|\.)netdata\.cloud$

    # n8n. It ships pointed at four hosts in this zone: license.n8n.io (the
    # license SDK), telemetry.n8n.io and ph.n8n.io (RudderStack and PostHog),
    # and api.n8n.io (version checks, "what's new", in-app banners, the
    # template gallery). One zone rule rather than four names, on the odoo.com
    # precedent above and anchored the same way; nothing else on this host has
    # any reason to reach n8n.io, so the host-wide scope costs nothing.
    #
    # Only the first of those is actually stopped here, and the distinction is
    # the point rather than a caveat. The license call is server-side and
    # leaves through this proxy on every n8n start. The other three are issued
    # by the *browser*: the backend hands the editor those endpoints in
    # /rest/settings and the editor's own REST client calls them, from a LAN
    # client whose egress never passes through this host at all. Those are
    # stopped by the N8N_* settings in services-LAN.nix, which keep the
    # endpoints out of /rest/settings to begin with. This rule cannot reach
    # them and must not be read as though it had.
    (^|\.)n8n\.io$

    # Firebase Cloud Messaging, Google's push relay. Blocked without having
    # established which service uses it -- the candidates are Odoo's web push
    # (VAPID; Chrome's endpoint is FCM) and Vaultwarden. If push notifications
    # stop arriving somewhere, this is the first thing to suspect.
    ^fcm\.googleapis\.com$
  '';

  # Ban scope for the two marker-driven caddy jails below, which are tight
  # enough (1 and 5 hits) that a false positive is a realistic outcome rather
  # than a theoretical one.
  #
  # Every other jail here bans 0:65535 -- fail2ban's jail.conf DEFAULT, which
  # neither caddy-badauth nor caddy-scan overrides, so "not naming a port" is
  # already an all-ports ban. On this host that is worse than it sounds: dnsmasq
  # below is one of the LAN's resolvers, so an all-ports ban on a household device
  # costs it, not just this host. Leaving 53 reachable makes
  # a wrong ban survivable -- the device loses o700 and nothing else.
  #
  # Nothing else here is load-bearing for a LAN client: the router serves DHCP
  # (this host is a DHCP *client*, see systemd.network below), and there is no
  # NTP or mDNS responder. ICMP is untouched either way, since multiport only
  # matches tcp/udp destination ports -- a banned device still answers ping.
  #
  # Starts at 1 rather than 0 because port 0 is not a real destination.
  banAllExceptDNS = {
    # fail2ban renders this through `sed s/:/-/g` into an nftables anonymous
    # set (action.d/nftables.conf, rule_match-multiport), so this becomes
    # `dport { 1-52,54-65535 }`. The same code path already renders the 0:65535
    # default every other jail here uses, so the range form is not new ground.
    port = "1:52,54:65535";

    # tcp,udp rather than fail2ban's `tcp` default. Caddy advertises HTTP/3 via
    # Alt-Svc and UDP/443 is open (allowedUDPPorts below), so a TCP-only ban
    # leaves a browser that already learned the advertisement talking to caddy
    # over QUIC -- the ban would appear applied and change nothing. The action
    # loops over this list, producing one nft rule per protocol against the
    # same address set.
    protocol = "tcp,udp";
  };
in
{
  networking = {
    hostName = "o700";
    useNetworkd = true;

    # nftables rather than iptables: extraInputRules is what makes source-CIDR
    # scoping expressible inline. The iptables backend would need extraCommands
    # and raw ip46tables lines. services.fail2ban.banaction follows
    # networking.nftables.enable automatically (defaults to nftables-multiport).
    #
    # IMPORTANT: this is only safe because Docker is disabled on o700. Docker
    # DNAT'd ports bypass the INPUT chain entirely and would silently escape a
    # default-deny INPUT policy. If Docker is ever re-enabled, revisit whether
    # the firewall backend and rule structure need to change.
    nftables.enable = true;
    firewall = {
      enable = true;

      # Reachable from the internet by design.
      allowedTCPPorts = [
        # MUST be in the very first switch that enables this firewall, otherwise
        # the switch locks you out of the only remote administration path.
        PORTS.SSHD
        # Caddy HTTP→HTTPS redirect. ACME uses DNS-01 so port 80 is not needed
        # for certificate issuance, but without it every http:// link to this
        # host times out instead of redirecting gracefully.
        PORTS.CADDY_HTTP
        PORTS.CADDY_HTTPS
        # BitTorrent. Inbound connections are how this peer is reachable by
        # anyone not already connected to it; without the port open qBittorrent
        # still works but only via outbound connections, which caps peer counts
        # and makes it undesirable to trackers. Unlike the WebUI (internal-only,
        # reached through caddy) this one genuinely has to face the internet, so
        # it is listed here rather than via services.qbittorrent.openFirewall --
        # that option would open the WebUI port too.
        PORTS.QBITTORRENT_TORRENT

        PORTS.JELLYFIN
      ];

      # Caddy enables HTTP/3 by default and advertises it via Alt-Svc. Without
      # UDP/443, browsers accept the advertisement, fail QUIC, then fall back to
      # TCP -- a per-connection stall that shows up as elevated probe_duration_seconds
      # rather than as a visible error.
      allowedUDPPorts = [
        PORTS.CADDY_HTTPS
        # uTP: qBittorrent's default transport is UDP, not TCP. Opening only
        # the TCP port halves reachability in a way that looks like "slow
        # torrents" rather than a firewall problem.
        PORTS.QBITTORRENT_TORRENT
      ];

      # On a WAN-exposed address, logging every refused connection would write
      # every unsolicited SYN from every background internet scanner into the
      # journal -- which is the log store itself, capped at 10G, and read by
      # fail2ban, so crowding it out costs bans rather than just history. The
      # information content is near zero (the packets were dropped) and the
      # volume dominates every other log source combined. Attack visibility
      # comes from fail2ban's counters and Caddy's access logs instead.
      logRefusedConnections = false;

      extraInputRules = ''
        # --- LAN-only services -------------------------------------------------
        # Source-CIDR scoped, IPv4 only, deliberately. This host has a single NIC:
        # LAN and WAN packets arrive on the same interface (enp4s0), so
        # networking.firewall.interfaces.<name> rules cannot distinguish them.
        # enp4s0 also carries globally routable IPv6 addresses that the router
        # does NOT NAT; any rule that is not explicitly `ip saddr` would expose
        # these services to the internet over IPv6. An open DNS resolver on a
        # public IPv6 address is found within hours and used for amplification.

        # dnsmasq -- authoritative for o700.net and the LAN's only resolver.
        # Without these: every LAN client loses name resolution.
        ip saddr ${IP.lan} udp dport ${toString PORTS.DNSMASQ} accept comment "dnsmasq UDP LAN"
        ip saddr ${IP.lan} tcp dport ${toString PORTS.DNSMASQ} accept comment "dnsmasq TCP LAN (large answers)"

        # mDNS. systemd-resolved has MulticastDNS=yes and the link sets
        # MulticastDNS=true. Without this: o700.local stops resolving and LAN
        # service discovery from other machines breaks.
        ip saddr ${IP.lan} udp dport ${toString PORTS.MDNS} accept comment "mDNS LAN"

      '';
    };
  };

  systemd.network.networks."10-ethernet" = {
    matchConfig.Type = "ether";

    networkConfig = {
      DHCP = "ipv4";
      MulticastDNS = true;

      # Resolve via the local dnsmasq over loopback. Previously nothing here
      # said so: the router happened to advertise 192.168.1.108 over DHCP, so
      # the host reached its own resolver by hairpinning off its LAN address.
      # That made o700's resolution depend on the router's DHCP settings, and
      # broke it before the lease arrived. Loopback has neither problem.
      DNS = [ "127.0.0.1" ];

      # "~." is a routing-only domain (no effect on the search list) that makes
      # this link the resolver for every query, so docker0 or wlp5s0 cannot
      # claim one by acquiring a DNS server of their own later.
      Domains = [ "~." ];
    };

    dhcpV4Config.RequestAddress = IP.o700;

    # The router advertises itself as a resolver twice over -- DHCP option 6
    # and IPv6 RA (fe80::1). resolved ranked both as peers of dnsmasq and
    # would fail over to them, at which point the o700.net zone silently
    # stops resolving on the host itself. Refuse both.
    dhcpV4Config.UseDNS = false;
    dhcpV6Config.UseDNS = false;
    ipv6AcceptRAConfig.UseDNS = false;
  };

  services = {
    resolved = {
      enable = true;
      settings.Resolve.MulticastDNS = "yes";

      # resolved only consults FallbackDNS when *no* DNS server is configured,
      # so it can never rescue a dnsmasq outage -- all it can do is mask a
      # misconfiguration by quietly shipping queries to Cloudflare and Google
      # instead. Empty turns that silent bypass into a visible failure.
      settings.Resolve.FallbackDNS = [ ];
    };

    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;

        AllowUsers = [ USERNAME ];
        MaxAuthTries = 3;
        LoginGraceTime = "30s";

        # LogLevel = "VERBOSE" is set by the fail2ban module via mkDefault. It
        # also puts each accepted login's key fingerprint into the journal, which
        # is what makes "somebody logged in with an unrecognised key" answerable.

        # ssh -L is the only access path to anything bound to loopback. Netdata
        # is reachable through Caddy on the LAN, so this is no longer the sole
        # route to the monitoring UI -- but it is still how a loopback listener
        # gets looked at from off-host, which is the whole point of binding them
        # there.
        AllowTcpForwarding = "yes";
      };
    };

    fail2ban = {
      enable = true;

      bantime = "1h";
      maxretry = 4;

      # Exponential growth: a one-hour first ban means nothing to a botnet that
      # simply tries again. 4x growth capped at 7 days turns sustained attackers
      # into week-long bans while a fat-fingered own password on a first offence
      # still costs only one hour.
      bantime-increment = {
        enable = true;
        maxtime = "7d";
        factor = "4";
        overalljails = true;
      };

      # IP.lan is deliberately NOT here. A compromised or misbehaving LAN
      # device can hammer these services from inside the network exactly as
      # effectively as one outside it, and "the LAN is trusted" is precisely
      # the assumption that makes a foothold there valuable. Jails apply to the
      # LAN like anywhere else.
      #
      # Two exemptions remain. big-boss is the recovery path when the WAN side
      # is misconfigured, and banning it turns a typo into a trip with a
      # keyboard. IP.o700 is this host, whose own requests to an internal
      # service by name arrive from its own LAN address rather than loopback --
      # so without it this host could ban itself, which under bantime-increment
      # escalates rather than self-corrects. Nothing on the host currently
      # generates such traffic in volume; the entry is cheap insurance.
      ignoreIP = [
        "127.0.0.0/8"
        "::1"
        IP.o700
        IP.big-boss
      ];

      jails = {
        # backend=systemd is the module's DEFAULT -- the sshd jail reads the
        # journal directly. The fail2ban module also sets
        # services.openssh.settings.LogLevel = "VERBOSE" via mkDefault, which
        # is what makes failed attempts visible in the journal at all.
        sshd.settings = {
          maxretry = 3;
          findtime = "10m";
          # Ban all ports, not just 22. An attacker probing ssh is probing
          # everything; leaving them 443 to hammer serves no purpose.
          action = "%(banaction_allports)s[name=sshd]";
        };

        # Watches Caddy's JSON access logs for repeated 401/403 responses.
        #
        # Reads the journal, because that is now the only place Caddy's access
        # logs exist -- every vhost writes to stderr and nothing writes files.
        # The failregex below is byte-identical to the file-based version; the
        # JSON line is the journal MESSAGE field verbatim.
        #
        # Consequence of the single stream: this jail also sees Caddy's own
        # runtime output and every vhost at once, where the file glob gave one
        # file per vhost. Both regex keys must appear on the same line for a
        # match, and runtime error logs carry neither, so false positives are
        # unlikely -- but a per-vhost ban policy is no longer expressible here.
        caddy-badauth = {
          settings = {
            # backend = "systemd" is the module default, same as the sshd jail.
            journalmatch = "_SYSTEMD_UNIT=caddy.service";
            # A 401 is not always a rejected login. Under OAuth/OIDC it is the
            # protocol's "token expired, go refresh" signal, so a client with
            # several requests in flight emits a burst of them in well under a
            # second and then recovers on its own. OpenCloud's Android client
            # tripped the old maxretry = 4 with exactly such a burst. The
            # headroom here covers that shape of false positive generically,
            # since any bearer-token app on this host can produce it.
            maxretry = 10;
            findtime = "10m";
          };
          filter.Definition = {
            # Caddy JSON access log. Anchored on specific JSON keys so the regex
            # fails closed (no match = no ban) if the log format shifts.
            #
            # WARNING: this regex keys on `remote_ip`. The Cloudflare integration
            # here is DNS-only (the token has Zone.DNS:Edit for ACME DNS-01;
            # nothing proxies traffic). If the Cloudflare orange cloud is ever
            # switched on for any record, every request will appear to come from
            # a Cloudflare IP and this jail will ban Cloudflare within minutes,
            # taking the entire site offline. Before enabling proxying: add
            # `trusted_proxies static <cloudflare-ranges>` and
            # `client_ip_headers CF-Connecting-IP` to Caddy's globalConfig and
            # switch the failregex to key on `client_ip`.
            failregex = ''^.*"remote_ip":"<HOST>".*"status":(401|403).*$'';
            ignoreregex = "";
          };
        };

        # Content scanning: sweeping for /wp-login.php, /.env, /admin and the
        # rest. Lenient by design, because a 404 is ambiguous where a 401 is
        # not -- a browser chasing a missing favicon or web manifest produces a
        # handful legitimately, and a single-page app with a stale asset
        # reference can produce more. 40 inside 5 minutes is not a browser.
        #
        # This jail also backs the exposure guard: a request from outside the
        # permitted range for a NONE or LAN vhost is answered 404, so anyone
        # working through internal hostnames from the WAN accumulates hits here
        # and is banned without a separate rule for it.
        caddy-scan = {
          settings = {
            journalmatch = "_SYSTEMD_UNIT=caddy.service";
            maxretry = 40;
            findtime = "5m";
          };
          filter.Definition = {
            # Same remote_ip caveat as caddy-badauth above regarding the
            # Cloudflare orange cloud.
            failregex = ''^.*"remote_ip":"<HOST>".*"status":404.*$'';
            ignoreregex = "";
          };
        };

        # --- Marker-driven caddy jails ---------------------------------------
        #
        # Both key on the `ban_reason` field that log_append writes into the
        # access line (vhostConfig and the wildcard vhost, above). That marker
        # is the entire reason these can be strict where caddy-scan cannot: it
        # says *why* caddy answered 404, which the status code alone does not,
        # so neither jail can be tripped by an application's own 404.
        #
        # Both fail closed in the same sense as caddy-badauth: if log_append
        # ever stops emitting, the regex stops matching and the jail bans
        # nobody. Verified with fail2ban-regex against real caddy output before
        # being trusted -- a genuine `jellyfin.${DOMAIN}` -> /favicon.ico 404 is
        # missed by both.
        #
        # Both are additive rather than exclusive: a marked line still counts
        # toward caddy-scan, and bantime-increment.overalljails shares the
        # escalation ladder. A client persistent enough to reach caddy-scan's 40
        # therefore also collects its all-ports ban, DNS included -- which is
        # the intended split. banAllExceptDNS is mercy for the accident, not for
        # someone working through a name list.

        # Requests the exposure guard turned away: an address that is not
        # permitted to reach a NONE or LAN vhost asking for one by name.
        #
        # maxretry = 1 is deliberate, and is only safe because nothing here
        # produces such a request legitimately. Checked, and each of these has
        # to stay true: no *-internal service sets dashboard.enable, so the
        # homepage links to none of them; those UIs are reached over the ssh
        # forward, which arrives as 127.0.0.1 and is permitted; and the two
        # hosts that might plausibly ask for one by name -- this one, via
        # dnsmasq's wildcard, and big-boss -- are both in ignoreIP above.
        # findtime is irrelevant at maxretry = 1 and is stated only so the
        # window is not inherited silently.
        caddy-exposure = {
          settings = {
            journalmatch = "_SYSTEMD_UNIT=caddy.service";
            maxretry = 1;
            findtime = "10m";
          }
          // banAllExceptDNS;
          filter.Definition = {
            # Same remote_ip caveat as caddy-badauth above regarding the
            # Cloudflare orange cloud.
            failregex = ''^.*"remote_ip":"<HOST>".*"ban_reason":"exposure-guard".*$'';
            ignoreregex = "";
          };
        };

        # Names no service claims, answered by the wildcard vhost.
        #
        # NOT maxretry = 1, even though the marker is exactly as unambiguous as
        # the one above, because the population that lands here is not the same.
        # dnsmasq wildcards the whole zone (address=/${DOMAIN}/ below), so every
        # typo of every name from every device on the network resolves to this
        # host and arrives here. A browser navigation is at least two hits --
        # the document plus /favicon.ico, which browsers request for error
        # responses too -- so at 1 or 2 a single mistyped URL is a ban, and a
        # renamed service turns every stale bookmark into one (mailpit-internal
        # -> mail-internal, b8866ef, is recent enough for that to be live).
        #
        # Five costs nothing against the case this is actually for: anything
        # walking a subdomain list produces hundreds, and this host is not
        # reachable from the internet, so the realistic population here is
        # household devices rather than background scanners.
        caddy-unknown-host = {
          settings = {
            journalmatch = "_SYSTEMD_UNIT=caddy.service";
            maxretry = 5;
            findtime = "10m";
          }
          // banAllExceptDNS;
          filter.Definition = {
            failregex = ''^.*"remote_ip":"<HOST>".*"ban_reason":"unknown-host".*$'';
            ignoreregex = "";
          };
        };

        # --- Per-application jails ------------------------------------------
        #
        # The two caddy jails above see status codes and nothing else, so they
        # are blind to the failure mode that matters most: these applications
        # answer a rejected login with HTTP 200 and put the refusal in the body.
        # A password-guessing run against vaultwarden is, to caddy, a series of
        # successful requests.
        #
        # All three read the journal rather than a file. That is not just house
        # style -- each of these services logs to stdout under its nixos module,
        # so the journal is where the lines already are, and adding a file would
        # mean a second copy plus rotation for it.
        #
        # Every failregex here is upstream's own, and each keys on the address
        # the *application* believes it is talking to. That address is only the
        # real client because of the forwardedHeaders block at the top of this
        # file; without it all three would match 127.0.0.1 and ban the proxy.
        # ignoreIP saves the host from itself, so the visible symptom would be a
        # jail that never bans anything rather than an outage -- which is why
        # the fail2ban-regex check matters before trusting these.

        # https://github.com/dani-garcia/vaultwarden/wiki/Fail2Ban-Setup
        vaultwarden = {
          settings = {
            journalmatch = "_SYSTEMD_UNIT=vaultwarden.service";
            # Upstream's number. A wrong password on a password manager is
            # plausible twice, not four times.
            maxretry = 3;
            findtime = "10m";
            # Same reasoning as the sshd jail: someone brute-forcing the vault
            # has no business holding any other port either.
            action = "%(banaction_allports)s[name=vaultwarden]";
          };
          filter.Definition = {
            failregex = ''^.*Username or password is incorrect\. Try again\. IP: <ADDR>\. Username:.*$'';
            ignoreregex = "";
          };
        };

        # https://docs.gitea.com/administration/fail2ban-setup
        gitea = {
          settings = {
            journalmatch = "_SYSTEMD_UNIT=gitea.service";
            # Upstream's 10 rather than the global 4: git clients retry with
            # credentials on their own, so a wrong stored password produces a
            # burst without anyone typing anything.
            maxretry = 10;
            findtime = "1h";
            action = "%(banaction_allports)s[name=gitea]";
          };
          filter.Definition = {
            failregex = ''.*(Failed authentication attempt|invalid credentials|Attempted access of unknown user).* from <HOST>'';
            ignoreregex = "";
          };
        };

        # https://jellyfin.org/docs/general/post-install/networking/advanced/fail2ban/
        #
        # Depends on two things outside this file: jellyfin's log level being
        # Info (its default -- denied auth is not logged at Error), and "Known
        # Proxies" naming 127.0.0.1 in Dashboard -> Networking. Jellyfin
        # discards forwarded headers from anything not listed there by design,
        # so until that is set this jail sees the proxy on every line. That
        # setting lives in network.xml and the nixos module exposes no option
        # for it, so it stays a manual step.
        jellyfin = {
          settings = {
            journalmatch = "_SYSTEMD_UNIT=jellyfin.service";
            maxretry = 3;
            findtime = "10m";
            action = "%(banaction_allports)s[name=jellyfin]";
          };
          filter.Definition = {
            failregex = ''^.*Authentication request for .* has been denied \(IP: "<ADDR>"\)\.'';
            ignoreregex = "";
          };
        };
      };
    };

    caddy = {
      enable = true;

      # Stock caddy has no DNS provider modules compiled in; the ACME DNS-01
      # challenge below is unusable without this plugin.
      package = pkgs.caddy.withPlugins {
        plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
        hash = "sha256-7GoH8YLCoPmPExQxoga2FHB58zQDoZVf1BBwkVi0SsQ=";
      };

      # Read by systemd before the caddy process starts. Must define
      # CF_API_TOKEN (single Cloudflare token: Zone.Zone:Read + Zone.DNS:Edit).
      environmentFile = config.age.secrets.cloudflare-dns-api.path;

      # DNS-01 rather than HTTP-01 because the wildcard below cannot be
      # validated any other way.
      globalConfig = ''
        acme_dns cloudflare {env.CF_API_TOKEN}
        tls_resolvers ${IP.cloudflare-dns}
      '';

      virtualHosts =
        let
          generated = builtins.foldl' (
            hosts:
            { proxy, ... }:
            assert !builtins.hasAttr proxy.domain hosts;
            {
              ${proxy.domain} = {
                extraConfig = vhostConfig proxy;

                # Every vhost, unconditionally: stderr -> journal, which is now
                # where these stay rather than being a waypoint to a log store.
                # There is no per-service switch because a request that was not
                # recorded is indistinguishable from one that never happened,
                # which is precisely the gap an attacker benefits from.
                #
                # This is also the single largest write source on the root disk --
                # roughly 65 lines a minute, every one of them fsynced by journald
                # and re-read by two fail2ban jails. If disk contention becomes a
                # problem again, narrowing this (rather than dropping it) is the
                # first thing to reach for.
                #
                # This string is spliced into a `log { }` block by the caddy
                # module, and it replaces the module's default wholesale. The
                # default is `output file <logDir>/access-<host>.log`, so naming
                # only a format here would silently drop the output directive --
                # hence stating `output stderr` explicitly even though it happens
                # to be caddy's fallback.
                logFormat = ''
                  output stderr
                  format json
                '';
              };
            }
            // hosts
          ) { } (builtins.filter ({ proxy, ... }: proxy.enable) (builtins.attrValues config.seta));

          # Exists purely so caddy manages a wildcard cert. Caddy skips
          # per-name certs for any subject a managed wildcard covers, so every
          # single-label service host above shares this one cert -- which is
          # why seta.<svc>.proxy.domain should stay single-label.
          #
          # Odoo is the deliberate exception: it claims the bare ${DOMAIN}
          # (services-WAN.nix explains why). A wildcard covers one label and
          # does not match the bare parent, so caddy manages two certificates
          # here: CN=${DOMAIN} with SAN `DNS:${DOMAIN}`, and CN=*.${DOMAIN}
          # with SAN `DNS:*.${DOMAIN}` -- separate serials, disjoint SAN sets,
          # renewed independently. Confirmed over the wire 2026-08-28; this
          # comment previously claimed a single cert carrying both names, which
          # is why the x509check jobs in monitoring/netdata.nix watch both.
          #
          # Exact hosts still win at routing time, so this only catches
          # subdomains with no service.
          handWritten = {
            "*.${DOMAIN}" = {
              # Same log_append marker as the exposure guard, different reason:
              # this is a name no service claims, which the caddy-unknown-host
              # jail acts on. Nothing else in the JSON line distinguishes it from
              # an application's own 404.
              extraConfig = ''
                ${securityHeaders}
                handle {
                  log_append ban_reason "unknown-host"
                  respond 404
                }
              '';

              # Must be stated, not inherited. Left at the module default this
              # vhost writes access-*.o700.net.log -- a literal asterisk in the
              # filename. Requests landing here are by definition for names no
              # service claims, which makes them more interesting than average,
              # not less.
              logFormat = ''
                output stderr
                format json
              '';
            };
          };

          # `//` gives the right-hand side priority, and the fold's own assert
          # only guards collisions *within* the fold. So a name defined on both
          # sides would silently take the hand-written definition and drop the
          # seta one, with no eval error and nothing in the diff to show for it.
          #
          # Not hypothetical: this block used to define "${DOMAIN}" as a redirect
          # to home.${DOMAIN}, and Odoo now claims that exact name through seta.
          # Landing those two in the same tree would have served the redirect and
          # silently discarded Odoo's vhost.
          collisions = builtins.attrNames (builtins.intersectAttrs generated handWritten);
        in
        assert lib.assertMsg (collisions == [ ]) ''
          caddy: hand-written vhost(s) ${lib.concatStringsSep ", " collisions} would
          silently override the seta-generated definition of the same name.
        '';
        generated // handWritten;
    };

    dnsmasq = {
      enable = true;

      # Leave /etc/resolv.conf alone: systemd-resolved keeps it pointed at
      # its loopback stub. Setting this true would have resolvconf fight
      # resolved over the same file. This host is instead pointed at dnsmasq
      # explicitly, via systemd.network in networking.nix.
      resolveLocalQueries = false;

      settings = {
        # Bind explicit addresses rather than the interface. enp4s0 also
        # carries globally routable IPv6 addresses, so binding the interface
        # would put an open resolver on a public address -- reliably
        # discovered and abused for DNS amplification. The firewall scopes
        # port 53 to the LAN CIDR on top of this; neither layer is trusted
        # alone. bind-dynamic (rather than bind-interfaces) tolerates the
        # address not existing yet at boot, since it arrives via DHCP.
        #
        # Loopback is listed so this host can reach its own resolver without
        # depending on the DHCP lease: systemd-resolved is pointed at
        # 127.0.0.1 (see systemd.network in networking.nix). resolved's own
        # stub occupies 127.0.0.53/127.0.0.54, not .1, so there is no
        # conflict.
        listen-address = [
          IP.o700
          "127.0.0.1"
        ];
        bind-dynamic = true;

        # Wildcard: every name under the zone resolves to this host, matching
        # how a wildcard TLS certificate will later cover the same names.
        # Adding a service then needs no DNS change at all.
        address = [
          "/${DOMAIN}/${IP.o700}"
          # Returning NXDOMAIN for this name is the signal Firefox uses to
          # disable DNS-over-HTTPS on "canary" networks. Without it, Firefox
          # bypasses dnsmasq entirely regardless of DHCP settings.
          "/use-application-dns.net/"
        ];

        # address= above only ever creates an A record. Since dnsmasq 2.86 a
        # query for any *other* RR type against a matched domain is forwarded
        # upstream instead of answered NODATA, so every AAAA lookup for an
        # internal name was being sent to the router -- disclosing the whole
        # service inventory and costing a round trip to learn nothing. local=
        # marks the zone as ours and answers it from local data only. The
        # man page names this exact pairing as the fix.
        #
        # Not needed for use-application-dns.net: an address= with no address
        # returns NXDOMAIN for every RR type already.
        local = "/${DOMAIN}/";

        # Split upstream. The router stays authoritative for "home": it hands
        # that domain out as DHCP option 15 and answers from its lease table,
        # so big-boss.home resolves there and nowhere else -- a public
        # resolver returns NXDOMAIN for it. Every LAN client resolves through
        # this host, so forwarding "home" anywhere else breaks name lookups
        # network-wide, not just here.
        #
        # Everything else goes to the local DoH proxy. This supersedes the
        # old "keep the query on the LAN so it survives a block on outbound
        # 53" reasoning: DoH rides 443, which survives that at least as well.
        no-resolv = true;
        server = [
          "/home/${IP.router}"
          "127.0.0.1#${toString PORTS.DNSCRYPT}"
        ];

        cache-size = 1000;
        domain-needed = true;
        bogus-priv = true;

        # Query log routed to a file rather than the journal. At LAN scale this
        # is thousands of entries per hour, and the journal is now the log store
        # itself rather than a staging area -- entries aging out of the 10G cap
        # in monitoring.nix are gone outright, and fail2ban reads that same
        # journal, so crowding it out costs bans rather than just history.
        #
        # log-facility alone would only move the destination; log-queries is
        # what enables the logging at all, and dnsmasq defaults it off. Both are
        # needed. The file is there for debugging strange client behaviour, and
        # for answering "did this host resolve X" after the fact:
        #   journalctl -f --file /var/log/dnsmasq/queries.log  (or just tail)
        log-queries = true;
        log-facility = "/var/log/dnsmasq/queries.log";
      };
    };

    dnscrypt-proxy = {
      enable = true;

      settings = {
        listen_addresses = [ "127.0.0.1:${toString PORTS.DNSCRYPT}" ];
        server_names = [ "cloudflare" ];

        # DoH specifically, not DNSCrypt. DNSCrypt runs over its own UDP
        # protocol, which defeats the point of looking like ordinary HTTPS.
        doh_servers = true;
        dnscrypt_servers = false;

        # Selects the transport used to reach the resolver, and has no
        # bearing on whether AAAA records come back. IPv4 only keeps the
        # path predictable.
        ipv6_servers = false;

        # dnsmasq already caches 1000 entries in front of this, so a second
        # cache underneath it only adds somewhere for stale answers to hide.
        cache = false;

        # Resolves a real startup deadlock. This proxy has to look up
        # cloudflare-dns.com (and fetch the resolver list) before it can
        # serve anything, but the system resolver path is
        # resolved -> dnsmasq -> this proxy, which is not listening yet.
        # ignore_system_dns forces the router below to be used instead.
        ignore_system_dns = true;
        bootstrap_resolvers = [ "${IP.router}:53" ];
      };
    };

    # The host's outbound HTTP choke point. Every service that honours the
    # standard proxy variables egresses through here (systemd.globalEnvironment
    # below), which buys two things: one place to block a destination by name,
    # and -- the reason it is host-wide rather than scoped to Odoo -- a single
    # log of what this machine actually talks to. Filter rules can then be
    # added from evidence instead of guesswork.
    #
    # This replaces an address=/odoo.com/ entry in dnsmasq above. That worked,
    # but dnsmasq is the LAN's only resolver and cannot tell a query from this
    # host apart from one from a phone, so it took odoo.com away from every
    # client on the network. Filtering per-host is not something this LAN's DNS
    # can express; it is something a proxy can.
    #
    # Odoo was once the only service additionally denied a direct route off the
    # host. That is now the default for everything in the seta manifest --
    # seta.<svc>.networkConfinement, applied below -- so the proxy is compulsory
    # rather than merely configured for all but the two services that opt out.
    tinyproxy = {
      enable = true;

      settings = {
        # Loopback only. Nothing outside this host has any business here, and
        # an open forward proxy on a LAN address -- let alone the globally
        # routable IPv6 that enp4s0 also carries -- is an abuse relay. Allow
        # restates that at the application layer so the two must both fail.
        Listen = "127.0.0.1";
        Port = PORTS.TINYPROXY;
        Allow = "127.0.0.1";

        # Filtering is on the request host, and tinyproxy applies it after the
        # CONNECT branch (reqs.c:476-482), so HTTPS is matched on the CONNECT
        # target. Nothing is decrypted and no CA has to be trusted; the filter
        # follows the *name*, so it is unaffected by odoo.com sharing CDN
        # addresses with unrelated sites.
        Filter = egressFilter;
        FilterType = "ere";

        # With no ConnectPort line at all, tinyproxy permits CONNECT to *any*
        # port (connect-ports.c:56-58), which would make this a general
        # outbound tunnel for the one service otherwise confined to loopback --
        # SMTP included. Now that every service is routed here this also caps
        # the host: HTTPS on a non-443 port fails with a 403 from tinyproxy
        # rather than silently working, so widening it is a deliberate act.
        ConnectPort = [ 443 ];

        # One line per request (reqs.c:120). This is the visibility the
        # host-wide routing exists to produce; Info adds per-header noise
        # without adding destinations.
        LogLevel = "Connect";

        # A file, not the journal -- deliberately, and for the same reason
        # dnsmasq's query log was moved out above. The journal is this host's
        # log store (capped at 10G in monitoring.nix) and fail2ban reads it, so
        # a per-request stream crowds out bans rather than just history.
        #
        # Nothing rotates this yet. Watch its growth before trusting it
        # unattended; it is one line per outbound request, host-wide.
        LogFile = "/var/log/tinyproxy/tinyproxy.log";
      };
    };
  };

  systemd.services = lib.mkMerge (
    [
      # The upstream module runs tinyproxy as its own user but declares no
      # writable directory, so LogFile above has nowhere to land. LogsDirectory
      # creates /var/log/tinyproxy owned by that user on start.
      { tinyproxy.serviceConfig.LogsDirectory = "tinyproxy"; }
    ]

    # The enforcement half of the proxy story below: globalEnvironment asks
    # every service to use tinyproxy, and this leaves the ones that opted in
    # with no other route to ignore it with. Driven off
    # seta.<svc>.networkConfinement (modules/seta.nix), which defaults to on, so
    # this list is every seta service except the two that say otherwise.
    #
    # Deliberately hung off `units` rather than the seta key: a service whose
    # real unit is named differently would otherwise have systemd synthesise an
    # empty unit and silently confine nothing, which is the same failure the
    # paperless note in services-LAN.nix describes.
    #
    # Nothing here touches the networking services -- caddy, dnsmasq,
    # dnscrypt-proxy, fail2ban and sshd have no seta entry, and confining the
    # resolver in particular would deadlock the boot for the reason given below.
    ++ map (
      meta:
      lib.genAttrs meta.units (_: {
        serviceConfig = {
          IPAddressDeny = "any";
          IPAddressAllow = meta.networkConfinement.allow;
        };
      })
    ) (builtins.filter (meta: meta.networkConfinement.enable) (builtins.attrValues config.seta))
  );

  # Route every service that honours the standard proxy variables through
  # tinyproxy. This is DefaultEnvironment=, so it reaches system units only --
  # login shells are left alone on purpose, since interactive curl/git is the
  # operator's traffic rather than an application's and would only pollute the
  # log this exists to produce.
  #
  # On its own this is honoured, not enforced: a service that ignores these
  # variables egresses directly and the proxy log never sees it. That gap is
  # closed above rather than here -- seta.<svc>.networkConfinement denies every
  # route off the host except loopback and the LAN, which turns the proxy from a
  # setting a service reads into the only path that exists. The variables still
  # matter: confinement says *no other route*, this says *which route*, and a
  # confined service with no proxy configured simply fails.
  #
  # The exemptions are the services whose traffic is not HTTP and so could never
  # traverse an HTTP proxy: qbittorrent (BitTorrent peers and DHT) and mailpit
  # (SMTP to a real relay). Notably dnscrypt-proxy is immune --
  # it sets its transport proxy solely from its own TOML http_proxy key
  # (config_loader.go:109) and never from the environment, which is what keeps
  # this from deadlocking: routing the resolver through a proxy that itself
  # needs the resolver would not survive a boot.
  systemd.globalEnvironment =
    let
      proxy = "http://127.0.0.1:${toString PORTS.TINYPROXY}";

      # Traffic that never leaves the LAN must not detour through a loopback
      # proxy: service-to-service calls, the router, and the ${DOMAIN} names
      # that resolve straight back to this host.
      #
      # The individual addresses are listed *as well as* the CIDR because
      # NO_PROXY CIDR support is not universal -- Go and python-requests parse
      # it, curl does not.
      noProxy = lib.concatStringsSep "," [
        "127.0.0.1"
        "localhost"
        "::1"
        IP.lan
        IP.router
        IP.o700
        ".${DOMAIN}"
        ".home"
      ];
    in
    {
      # Both cases deliberately. curl reads only the lowercase http_proxy --
      # it ignores uppercase HTTP_PROXY because that name collides with a
      # CGI-controlled request header -- while Go and Python prefer uppercase.
      HTTP_PROXY = proxy;
      HTTPS_PROXY = proxy;
      NO_PROXY = noProxy;

      http_proxy = proxy;
      https_proxy = proxy;
      no_proxy = noProxy;

      # Node reads none of the above. Verified on nodejs 22.23.2 -- the runtime
      # seerr is built against -- by pointing HTTP_PROXY at one closed port and
      # the request at another: both http.request and global fetch connect
      # straight to the origin, and only reach the proxy with this set.
      #
      # Libraries that bring their own env handling are unaffected either way;
      # axios inlines proxy-from-env and is why Node services here work at all
      # today. This covers the ones built on bare fetch/undici, which is where
      # new Node code is heading. Unknown to every other runtime on this host,
      # so setting it globally costs nothing.
      NODE_USE_ENV_PROXY = "1";
    };
}
