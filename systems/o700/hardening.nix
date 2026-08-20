{ config, pkgs, lib, o700-IP, big-boss-IP, USERNAME, ... }:
{
  # ---------------------------------------------------------------------------
  # Firewall (nftables backend)
  # ---------------------------------------------------------------------------

  # nftables rather than iptables: extraInputRules is what makes source-CIDR
  # scoping expressible inline. The iptables backend would need extraCommands
  # and raw ip46tables lines. services.fail2ban.banaction follows
  # networking.nftables.enable automatically (defaults to nftables-multiport).
  #
  # IMPORTANT: this is only safe because Docker is disabled on o700. Docker
  # DNAT'd ports bypass the INPUT chain entirely and would silently escape a
  # default-deny INPUT policy. If Docker is ever re-enabled, revisit whether
  # the firewall backend and rule structure need to change.
  networking.nftables.enable = true;

  networking.firewall = {
    enable = true;

    # Reachable from the internet by design.
    allowedTCPPorts = [
      # MUST be in the very first switch that enables this firewall, otherwise
      # the switch locks you out of the only remote administration path.
      22
      # Caddy HTTP→HTTPS redirect. ACME uses DNS-01 so port 80 is not needed
      # for certificate issuance, but without it every http:// link to this
      # host times out instead of redirecting gracefully.
      80
      443
    ];

    # Caddy enables HTTP/3 by default and advertises it via Alt-Svc. Without
    # UDP/443, browsers accept the advertisement, fail QUIC, then fall back to
    # TCP -- a per-connection stall that shows up as elevated probe_duration_seconds
    # rather than as a visible error.
    allowedUDPPorts = [ 443 ];

    # On a WAN-exposed address, logging every refused connection would write
    # every unsolicited SYN from every background internet scanner into the
    # journal -- which is now shipped to VictoriaLogs and counted against its
    # 10 GiB cap. The information content is near zero (the packets were
    # dropped) and the volume dominates every other log source combined.
    # Attack visibility comes from fail2ban's counters, the Fail2banBanBurst
    # alert, and Caddy's access logs instead.
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
      ip saddr 192.168.1.0/24 udp dport 53 accept comment "dnsmasq UDP LAN"
      ip saddr 192.168.1.0/24 tcp dport 53 accept comment "dnsmasq TCP LAN (large answers)"

      # mDNS. systemd-resolved has MulticastDNS=yes and the link sets
      # MulticastDNS=true. Without this: o700.local stops resolving and LAN
      # service discovery from other machines breaks.
      ip saddr 192.168.1.0/24 udp dport 5353 accept comment "mDNS LAN"

      # NFS, exported to exactly one peer. The export line in
      # hardware-configuration.nix already restricts to big-boss, but sec=sys
      # means the client list *is* the access control -- the firewall repeats
      # it rather than trusting a single layer. NFSv4 only (see extraNfsdConfig
      # below), so port 2049 is the entire surface: no rpcbind (111), no mountd,
      # no statd, no lockd. Without this rule the client mount hangs rather than
      # failing -- the most confusing NFS failure mode.
      ip saddr ${big-boss-IP} tcp dport 2049 accept comment "NFS to big-boss"
    '';
  };

  # Force NFSv4-only so the firewall surface is one port (2049) instead of
  # five. NFSv3 additionally requires rpcbind (111) and mountd, statd and
  # lockd on ports that are random unless pinned. If big-boss ever mounts with
  # vers=3 it will fail loudly at mount time, which is the correct outcome.
  services.nfs.server.extraNfsdConfig = ''
    vers3=n
  '';

  # ---------------------------------------------------------------------------
  # fail2ban
  # ---------------------------------------------------------------------------

  services.fail2ban = {
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

    # Never ban yourself. The LAN is the recovery path when the WAN side is
    # misconfigured; banning it turns a single typo into a trip with a keyboard.
    # Loopback is excluded too: the host probes itself via blackbox https probes.
    ignoreIP = [
      "127.0.0.0/8"
      "::1"
      "192.168.1.0/24"
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
      # File-based rather than the systemd backend because matching a failregex
      # against JSON inside the journal is brittle, and a dedicated log file
      # keeps scanner noise out of VictoriaLogs (separate concern, separate
      # file). Only applied to vhosts that have a login form.
      caddy-badauth = {
        settings = {
          backend = "polling";
          # Glob covers all per-vhost access log files created by the log {}
          # block in services/grafana.nix, services/gitea.nix,
          # services/vaultwarden.nix.
          logpath = "/var/log/caddy/access-*.log";
          maxretry = 6;
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
    };
  };

  # fail2ban log directory used by the caddy-badauth jail
  systemd.tmpfiles.rules = [
    "d /var/log/caddy 0750 caddy caddy - -"
  ];

  # ---------------------------------------------------------------------------
  # sshd hardening
  # ---------------------------------------------------------------------------

  services.openssh.settings = {
    # Already set in services.nix: PermitRootLogin=no,
    # PasswordAuthentication=false, KbdInteractiveAuthentication=false.

    AllowUsers = [ USERNAME ];
    MaxAuthTries = 3;
    LoginGraceTime = "30s";

    # LogLevel = "VERBOSE" is set by the fail2ban module via mkDefault. It
    # also puts each accepted login's key fingerprint into the journal, which
    # is what makes "somebody logged in with an unrecognised key" answerable.

    # MUST stay yes: ssh -L is the only access path for VictoriaMetrics,
    # VictoriaLogs, Alertmanager, both vmalerts and every exporter.
    AllowTcpForwarding = "yes";
  };
}
