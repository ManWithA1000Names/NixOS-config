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
    package = pkgs.netdataCloud;

    # The two things this host actually needs -- PSI and cgroup metrics, and
    # per-app resource usage -- are both C plugins. python.d is a separate
    # interpreter running a scheduler for collectors this host has nothing for
    # (postgres, nvidia-smi, ceph...). Apart from systemd-journal below, every
    # other plugin is left at its default: the point of this rewrite was to stop
    # guessing at what is heavy, so anything else gets disabled only after it is
    # measured doing damage.
    python.enable = false;

    config = {
      plugins = {
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
        # stretches the same 512MiB about five times further, so at 5s this is
        # on the order of a month for this host's chart count rather than the
        # week it held at 1s.
        "dbengine tier 0 retention size" = "512MiB";
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
        "registry to announce" = "https://netdata.${DOMAIN}";
      };
    };

    configDir = {
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

  seta.netdata = {
    dashboard = {
      enable = true;
      name = "Netdata";
      description = "Metrics & alerts";
      group = "Monitoring";
      icon = "netdata.png";
    };

    proxy = {
      enable = true;
      port = PORTS.NETDATA;

      # The CSP is a backstop for the bundled dashboard's third-party calls.
      # Most of them -- Google Tag Manager, PostHog, Sentry -- are already dead
      # because the agent build hardcodes `tracking: false`, and the registry
      # iframe is handled at its source above. This catches the rest (a Prismic
      # news feed, a marketing counter on cloudfunctions.net, cdnjs for PDF
      # export) and, more to the point, anything a future bundle adds. Only
      # connect-src and frame-src are constrained: script-src is left alone
      # because the dashboard's own bundle is what would break.
      config = ''
        header Content-Security-Policy "connect-src 'self'; frame-src 'self'"
        reverse_proxy localhost:${toString PORTS.NETDATA}
      '';

      domain = "netdata-internal.${DOMAIN}";
      exposure = "NONE";
    };
  };
}
