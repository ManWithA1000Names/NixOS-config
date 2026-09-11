{
  config,
  pkgs,
  DOMAIN,
  PORTS,
  ...
}:
{
  # ---------------------------------------------------------------------------
  # Netdata
  #
  # Nothing here *ships* anything: Netdata reads /proc on demand, so the
  # steady-state write load is its own dbengine and nothing else. That property
  # is the whole point on this host -- / and /nix/store share a 7200 RPM spindle,
  # and contention on it has taken the machine down twice: once from this stack's
  # predecessor writing every journal entry twice, and once from a swapfile that
  # used to sit on the same disk (see swapDevices in hardware-configuration.nix).
  # Anything that writes a second copy of data which already exists is
  # disqualified on this hardware.
  #
  # This is a metrics-only deployment. Netdata's log side -- the systemd-journal
  # browser -- is a "Function", and every Function is gated: /api/v3/functions
  # reports `access: [signed-in, same-space, sensitive-data]` on all of them and
  # an anonymous request gets HTTP 412, over loopback as well as through Caddy.
  # The gate is agent-side and has no configuration key, because the agent ships
  # no local identity provider at all -- bearer tokens are stamped with a cloud
  # account id and can only be minted by Netdata Cloud over the ACLK, so there
  # is nothing here that could ever grant `signed-in`. Charts, alarms, ML
  # anomaly detection, PSI and cgroups are all ANONYMOUS_DATA and unaffected.
  # Logs are read with journalctl over SSH; see the [plugins] block below.
  # ---------------------------------------------------------------------------

  services.netdata = {
    enable = true;
    enableAnalyticsReporting = false;

    # nixpkgs builds the default `netdata` with `withCloudUi = false`, which
    # passes -DENABLE_DASHBOARD=OFF and ships an empty share/netdata/web -- the
    # agent answers every dashboard URL with "File does not exist". This variant
    # is the same daemon with the web bundle included; the only nixpkgs
    # difference is that the bundle is vendored instead of downloaded at build
    # time. It is unfree (NCUL1) on top of GPL3, covered by the global
    # allowUnfree in systems/common/nix.nix.
    #
    # withNdsudo defaults to false in nixpkgs, and while it is off the module
    # never creates the security.wrappers entry for ndsudo -- the shipped binary
    # stays non-setuid, so any collector that needs privileges fails quietly
    # rather than loudly. It is what makes the fail2ban collector below work at
    # all: /run/fail2ban is 0750 root-owned, so the netdata user cannot even
    # reach the socket to be refused by it. The cost is a from-source build --
    # no upstream binary is built with this flag, so nothing in cache.nixos.org
    # matches and big-boss compiles the daemon and the go.d plugin itself.
    package = pkgs.netdataCloud.override { withNdsudo = true; };

    # This list is the entire root-capable surface, because ndsudo execs as
    # root. nixpkgs patches it to *replace* PATH with this directory instead of
    # searching /bin:/sbin:/usr/bin (upstream advisory GHSA-pmhq-4cxq-wj93), so
    # a command in ndsudo's hardcoded allowlist is only reachable if its binary
    # was put here deliberately. With fail2ban alone, everything ndsudo can do
    # on this host is `fail2ban-client status [jail]`. The wrapper itself is
    # root:netdata with o-rwx, so nothing outside that group can invoke it.
    extraNdsudoPackages = [ pkgs.fail2ban ];

    # The two things this host actually needs -- PSI and cgroup metrics, and
    # per-app resource usage -- are both C plugins. python.d is a separate
    # interpreter running a scheduler for collectors this host has nothing for
    # (nvidia-smi, ceph...). Note that this does not disable the postgres or
    # fail2ban collectors configured below: both were ported to Go years ago and
    # live in go.d, which is a different plugin. Apart from systemd-journal below,
    # every other plugin is left at its default: the point of this rewrite was
    # to stop guessing at what is heavy, so anything else gets disabled only
    # after it is measured doing damage.
    python.enable = false;

    config = {
      plugins = {
        # No BMC on this board -- there is no /dev/ipmi0, so libipmimonitoring
        # cannot find an in-band device and the plugin logs
        # `ipmi_monitoring_*(): internal error` every 30s for ten minutes after
        # each start before netdata disables it with "0 successful data
        # collections". That replays on every boot and every netdata restart.
        # Unlike systemd-journal below this is not a gating problem: IPMI
        # telemetry comes from a service processor this hardware does not have,
        # so no configuration could ever make it produce data.
        "freeipmi" = "no";

        # Disabled because what it exists to serve cannot be reached. The
        # journal browser is a Function, and Functions need a Netdata Cloud
        # bearer this host will never hold (see the header). Left enabled it is
        # a process opening journal files to answer requests that always return
        # 412, and a dashboard entry advertising a feature that is not there.
        #
        # The key is the plugin filename with `.plugin` stripped: plugins_d.c
        # looks up [plugins] by exactly that name when it scans the plugin
        # directory, so `systemd-journal` disables systemd-journal.plugin.
        "systemd-journal" = "no";
      };

      web = {
        # Netdata binds `*` by default -- every interface including the globally
        # routable IPv6 address. The agent dashboard has no authentication of
        # its own -- none whatsoever; the Sign in button delegates entirely to
        # Netdata Cloud -- so an unbound listener hands this host's full metric
        # history to anyone who finds the port. Caddy is the only path in; the
        # firewall dropping the port is the second layer rather than the only
        # one.
        "bind to" = "127.0.0.1:${toString PORTS.NETDATA}";
      };

      db = {
        mode = "dbengine";

        # 1s is the default and it is oversampling for this host. Most of what
        # matters here is already an average over a longer window -- the kernel
        # exposes PSI as 10s/60s/300s figures, so reading it every second
        # returns the same number five times -- and the rest moves slowly
        # enough that 5s resolution costs nothing diagnostically. Collection
        # scales directly with this number: /proc parsing, compression and
        # dbengine flushes all drop roughly fivefold, which is the point on a
        # spindle that has taken this host down once already.
        "update every" = 5;

        # One tier, not the default three. Tiers exist to keep years of
        # downsampled history; the question this host needs answered is "what
        # was happening in the last few days", and each extra tier is another
        # set of files being flushed to the same spindle.
        "storage tiers" = 1;

        # Hard cap: dbengine evicts oldest-first to stay under it, so a
        # cardinality explosion costs retention rather than growing unbounded
        # and taking the root filesystem with it. Being a *byte* budget, it
        # interacts with the rate above -- a fifth as many points per metric
        # stretches the same budget about five times further.
        #
        # Raised from 512MiB when the postgres collector was added: that one
        # charts per-database, so the chart count now grows with every service
        # migrated onto the centralized instance, and at a fixed budget each
        # migration would have silently shortened the retention window for
        # everything else.
        "dbengine tier 0 retention size" = "2GiB";
      };

      registry = {
        # Not about running a registry -- this host does not. `action=hello`
        # returns this string whether or not the registry is enabled, and the
        # dashboard unconditionally injects a hidden iframe pointing at
        # `<that string>/registry-access.html?x=<base64>`, where the payload
        # carries machine_guid, hostname and agent version. Left at its default
        # of https://registry.my-netdata.io that is a beacon to Netdata on every
        # page load. The agent serves registry-access.html out of its own web
        # root, so naming ourselves keeps the iframe same-origin; it answers
        # "disabled", the dashboard logs a console error, and nothing else
        # changes.
        "registry to announce" = "https://${config.seta.netdata.proxy.domain}";
      };
    };

    configDir = {
      # Netdata Cloud, off at the source. `package` above is netdataCloud, so
      # the ACLK is compiled in and one claim token is all that stands between
      # this agent and a persistent outbound connection to app.netdata.cloud.
      #
      # This is the layer that actually holds, and it is the innermost of three.
      # Behind it is seta.netdata.networkConfinement, which leaves this unit no
      # peer but loopback and the LAN -- app.netdata.cloud is a public address,
      # so a direct socket to it has nowhere to go. Outermost is the
      # netdata.cloud entry in the tinyproxy filter (networking.nix), and that
      # one is the weakest: the ACLK is MQTT over WebSocket with its own proxy
      # setting in this same file, not an HTTP request that inherits HTTP_PROXY,
      # so it might never issue a CONNECT for the filter to match. It would then
      # fail at confinement rather than escape -- but it would fail silently, so
      # the proxy log is not where to look for evidence either way.
      #
      # enableAnalyticsReporting = false above is a third, separate thing: it
      # covers the anonymous telemetry POST, not the cloud link.
      #
      # Netdata writes claim state into this file, so with it a store symlink
      # claiming becomes impossible rather than merely disabled -- an attempt
      # fails on a read-only path instead of silently succeeding.
      "cloud.conf" = pkgs.writeText "cloud.conf" ''
        [global]
            enabled = no
      '';

      # The centralized postgres, declared rather than discovered. go.d's
      # net_listeners service discovery already finds anything on 5432 and
      # tries three template DSNs against it; naming the job here means the
      # connection details are in this config instead of in netdata's shipped
      # discovery rules, which are free to change under us on any bump.
      #
      # Socket, not TCP: postgres no longer opens a port at all (see
      # listen_addresses in services-internal.nix), and peer auth over the
      # socket means the OS user netdata runs as is the whole credential --
      # there is no password here to keep out of the store.
      #
      # Left at the collector's default update rate rather than the 5s used
      # for /proc above. These are SQL queries against pg_stat_*, not file
      # reads, and the right interval for them is a different question from
      # the one answered in the db block -- one to settle by measuring, if the
      # collector ever shows up as a cost.
      #
      # autodetection_retry because nothing orders this after postgres: a job
      # that fails to connect at startup is dropped for good, so without it a
      # boot where netdata wins the race against postgresql-setup leaves the
      # collector silently absent until netdata is next restarted. Retrying is
      # the collector-native fix; a systemd ordering edge would only cover the
      # boot case and not, say, a postgres restart.
      "go.d/postgres.conf" = pkgs.writeText "postgres.conf" ''
        jobs:
          - name: local
            dsn: 'host=/run/postgresql dbname=postgres user=netdata'
            autodetection_retry: 60
      '';

      # Per-jail ban counts for fail2ban (see networking.nix). Charts only:
      # fail2ban.jail_banned_ips and fail2ban.jail_active_failures, labelled by
      # jail. These are ordinary ANONYMOUS_DATA metrics, not a Function, so
      # unlike the journal browser named in the header they are readable
      # anonymously and none of the 412 gating applies.
      #
      # Declared rather than left to discovery for the same reason as postgres
      # above -- go.d.conf enables this collector by default and conf.d ships a
      # bare `- name: fail2ban` job -- except that here the point is to pin the
      # interval rather than the connection details.
      #
      # 60s, not the 5s used for /proc: the collector shells out to
      # fail2ban-client once to enumerate jails and once more per jail, and
      # fail2ban-client is Python, so the global rate would mean roughly 48
      # interpreter startups a minute on the spindle. The rate is set against
      # what the data does rather than what the collector defaults to -- these
      # are cumulative ban counters and every jail here has findtime of 5-10
      # minutes, so nothing can move meaningfully inside one minute.
      #
      # No socket_path is given. The collector's default is
      # /var/run/fail2ban/fail2ban.sock and the NixOS module puts the socket at
      # /run/fail2ban/fail2ban.sock, which is the same file reached through the
      # /var/run compatibility symlink.
      #
      # Nothing here alerts -- netdata ships no stock health template for this
      # collector. The value is answering a question the counters in nftables
      # cannot: whether caddy-badauth is banning a scanner or banning us. Under
      # the bantime-increment in networking.nix that distinction is the
      # difference between the jail working as designed and a LAN device outside
      # ignoreIP being locked out for a week over a mistyped password.
      "go.d/fail2ban.conf" = pkgs.writeText "fail2ban.conf" ''
        jobs:
          - name: fail2ban
            update_every: 60
      '';

      # Certificate expiry. Caddy renews silently and fails silently: a broken
      # renewal leaves the unit active and the old certificate still being
      # served, so the OnFailure= wiring in notify.nix never fires and the
      # first signal is a browser error. Nothing else here would catch it --
      # host-audit checks backups, SUID and authorized_keys, and netdata ships
      # no x509check job by default (conf.d has the module enabled but every
      # job commented out, and there is no service discovery for it), so the
      # stock health template has no chart to attach to and silently never
      # instantiates.
      #
      # Two jobs because caddy manages two certificates here, not one. Verified
      # over the wire 2026-08-28: the apex serves CN=o700.net with SAN
      # `DNS:o700.net` alone, the vhosts serve CN=*.o700.net with SAN
      # `DNS:*.o700.net` alone -- different serials, disjoint SAN sets, and a
      # wildcard does not match the bare parent label. Watching one would leave
      # the other unmonitored.
      #
      # Checked over the wire rather than by reading the .crt files: caddy's
      # StateDirectory is 0700 caddy so the netdata user cannot read them, and
      # what matters anyway is the certificate being *served* rather than the
      # newest one on disk -- those differ if a renewal succeeds but the reload
      # does not.
      #
      # Names must be ones a vhost actually claims. Requests for unclaimed
      # names fall through to the `*.${DOMAIN}` catch-all, which answers 404,
      # and the caddy-scan jail in networking.nix bans on accumulated 404s.
      #
      # update_every is a display constraint here, not a data one. The stock
      # default is go.d's 1s floored to the 5s in [db] above -- a TLS handshake
      # against caddy every five seconds for a value that moves one second per
      # second. Hourly was the first attempt: it collected correctly for 26
      # hours while charting nothing, because the dashboard's default view is
      # the last 15 minutes and 39 of every 40 such windows contain no stored
      # point. Verified 2026-08-29 -- an absolute query for that window returns
      # zero points, while a relative one clamps back to the last on-the-hour
      # sample and looks healthy, which is how the API hid this. 60s puts 15
      # points in the default window.
      #
      # Stock health.d/x509check.conf warns under 14 days and goes critical
      # under 7 -- against Let's Encrypt renewing at 30 days remaining, so a
      # warning means renewal has been failing for a fortnight. It is
      # `to: webmaster`, and the stock config leaves every role falling back to
      # DEFAULT_RECIPIENT_TELEGRAM, which is set below.
      "go.d/x509check.conf" = pkgs.writeText "x509check.conf" ''
        jobs:
          - name: apex
            source: https://${DOMAIN}:443
            update_every: 60
          - name: wildcard
            source: https://home.${DOMAIN}:443
            update_every: 60
      '';

      # The stock systemd-unit alarm, enabled. Upstream ships it *disabled* in
      # a way that is easy to miss: health.d/systemdunits.conf sets
      # `chart labels: unit_name=!*`, a negative matcher that matches no unit,
      # so the template never instantiates against any chart. The collector
      # behind it needs nothing -- go.d.conf has `systemdunits: yes` as its
      # default and go.d/systemdunits.conf ships an active `service-units` job
      # including '*.service'.
      #
      # This is what replaces the hand-maintained OnFailure= list that used to
      # live in monitoring/notify.nix. That list named 28 units; this covers
      # every service unit in the configuration -- 109 declared here plus the
      # package-provided ones -- so failures of agenix, postgresql-setup,
      # acme-*, logrotate and systemd-tmpfiles-* now report where previously
      # they fired nothing at all. Four units stay on the OnFailure path for
      # reasons this template cannot serve; see notify.nix.
      #
      # Replacing the file is the only mechanism available: a same-named file
      # in the user config dir shadows the stock one wholesale rather than
      # merging with it. Nothing is lost by that -- the other nine templates in
      # the stock file (socket, timer, target, mount, swap, scope, slice, path,
      # device) are disabled by the same matcher, and none is wanted here.
      #
      # `to: sysadmin` routes to Telegram with no extra wiring:
      # role_recipients_telegram[sysadmin] is commented out in the stock
      # health_alarm_notify.conf, which means it falls back to
      # DEFAULT_RECIPIENT_TELEGRAM -- set in the override just below.
      #
      # Cost, stated because it is not free: the collector charts every service
      # unit, so this adds roughly a hundred charts against the 2GiB tier 0
      # budget in [db] above. That is paid in retention, not in disk growth --
      # dbengine still evicts oldest-first to stay under the cap. Measure
      # before narrowing, and if it does bite, narrow the collector's
      # `include:` rather than this matcher, so the alarm keeps covering
      # whatever is still collected.
      #
      # restic-backups-* is excluded because o700-backup already counts failed
      # sets and reports them with the set name attached. Without the
      # exclusion one bad night sends two messages, and the orchestrator's is
      # the one that says which set failed.
      "health.d/systemdunits.conf" = pkgs.writeText "systemdunits.conf" ''
            template: systemd_service_unit_failed_state
                  on: systemd.service_unit_state
               class: Errors
                type: Linux
           component: Systemd units
        chart labels: unit_name=!restic-backups-* *
                calc: $failed
               units: state
               every: 10s
                warn: $this != nan AND $this == 1
               delay: down 5m multiplier 1.5 max 1h
             summary: systemd unit ''${label:unit_name} state
                info: systemd service unit in the failed state
                  to: sysadmin
      '';

      # alarm-notify.sh sources the stock health_alarm_notify.conf first and
      # this one second, so only the overridden keys need to appear here; every
      # other notification method keeps its stock (disabled) default.
      #
      # Sourcing is also what makes the secret work: this file is a bash script,
      # not a data file, so the token can be read from the agenix path at run
      # time instead of being interpolated into the world-readable nix store.
      # The secret is already in EnvironmentFile format (KEY=value), which is
      # valid bash, so the same file serves both consumers.
      "health_alarm_notify.conf" = pkgs.writeText "health_alarm_notify.conf" ''
        source ${config.age.secrets.alerting-netdata.path}

        SEND_TELEGRAM="YES"
        TELEGRAM_BOT_TOKEN="''${TELEGRAM_BOT_TOKEN}"
        DEFAULT_RECIPIENT_TELEGRAM="''${TELEGRAM_CHAT_ID}"
      '';
    };
  };

  # +-----------------------------------------------------------------+
  # | Additional configurations that are required for these services. |
  # +-----------------------------------------------------------------+

  # The one failure netdata cannot report: its own. Every other service on this
  # host now reaches Telegram through the systemd_service_unit_failed_state
  # template configured above, and a dead agent evaluates no templates -- so
  # without this, a crashed netdata and a quiet night are the same observation.
  #
  # This path deliberately does not share netdata's delivery route. The
  # notifier runs with no_proxy set (monitoring/notify.nix), while netdata's
  # own alerts are curl inheriting systemd.globalEnvironment and are confined
  # to localhost and the LAN by the seta block below -- meaning api.telegram.org
  # is reachable from netdata *only* through tinyproxy. Anything whose failure
  # could also be the proxy's failure has to report some other way, and this is
  # the other way.
  #
  # Wired here rather than in a central list because there is no central list
  # any more: each unit that needs the notifier says so on its own definition.
  # The assertions in monitoring/notify.nix check the ones, like this, whose
  # ExecStart comes from nixpkgs rather than from this repo.
  systemd.services.netdata.onFailure = [ "telegram-notify@%n.service" ];

  # See seta.netdata.sandbox below for why this one setting is stated outside
  # it: ndsudo is a setuid wrapper, and NoNewPrivileges makes a setuid bit
  # inert. The sandbox baseline sets it true at mkOptionDefault, so this
  # ordinary definition wins.
  systemd.services.netdata.serviceConfig.NoNewPrivileges = false;

  seta.netdata = {
    # The one service that has to opt out of half the sandboxing baseline, and
    # the reasons are its entire job rather than incidental.
    #
    # NOT disabled wholesale: the fifteen-odd settings it does not conflict with
    # -- ProtectClock, ProtectKernelModules, LockPersonality, RestrictRealtime,
    # RestrictNamespaces and the rest -- still apply and are still worth having
    # on a process that reads everything on the host.
    sandbox = {
      # apps.plugin and cgroups.plugin read other processes' /proc entries, and
      # the /proc/stat, /proc/meminfo, /proc/pressure files the C collectors are
      # built on are exactly what ProcSubset=pid hides. Under the hardened
      # values netdata keeps running and reports an almost empty machine, which
      # is the worst failure available to a monitoring agent: no alarm fires,
      # because the alarms have no data to fire on.
      allProcesses = true;

      # The module sets these thirteen itself (they beat mkOptionDefault), so
      # this is restated rather than load-bearing -- but an empty list here
      # would read as "netdata needs no capabilities", which is the opposite of
      # true, and the next person to touch the module's own definition would
      # have no hint that the question was considered.
      capabilities = [
        "CAP_DAC_OVERRIDE"
        "CAP_DAC_READ_SEARCH"
        "CAP_NET_RAW"
        "CAP_PERFMON"
        "CAP_SETPCAP"
        "CAP_SETUID"
        "CAP_SYSLOG"
        "CAP_SYS_ADMIN"
        "CAP_SYS_CHROOT"
        "CAP_SYS_PTRACE"
        "CAP_SYS_RESOURCE"
        "CAP_FOWNER"
        "CAP_SYS_RAWIO"
      ];

      # ndsudo is a setuid wrapper (withNdsudo above, and the security.wrappers
      # entry the module creates for it). NoNewPrivileges=true makes the setuid
      # bit a no-op, so the fail2ban collector would lose its only route to the
      # socket -- silently, since it already fails quietly when it cannot reach
      # it. The baseline sets NoNewPrivileges at mkOptionDefault, so this
      # explicit false wins.
      #
      # AF_NETLINK because netdata's network collectors read interface and
      # socket state over netlink.
      addressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
    };

    # Confined by default like every other seta service, and the two things
    # that could have broken both survive:
    #
    #   x509check reaches https://${DOMAIN} and https://home.${DOMAIN}, which
    #   resolve to this host's LAN address rather than loopback. Inside the
    #   default allow list because that list is the /24.
    #
    #   Telegram alerts go out through alarm-notify.sh, which is curl, which
    #   inherits this unit's environment and so uses tinyproxy.
    #
    # The second of those is worth re-checking by hand after any change here.
    # Netdata is the alarm system, so a confinement mistake that silences
    # notifications also silences the thing that would have reported it --
    # unlike every other service, this one fails quietly. Fire a test alarm
    # rather than waiting to be told.
    proxy = {
      enable = true;
      port = PORTS.NETDATA;

      headers = {
        Content-Security-Policy = ''"connect-src 'self'; frame-src 'self'"'';
      };

      domain = "netdata-internal.${DOMAIN}";
      exposure = "NONE";
    };
  };
}
