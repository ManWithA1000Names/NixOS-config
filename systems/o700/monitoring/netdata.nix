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
  # Replaces VictoriaMetrics + VictoriaLogs + Vector + two vmalert instances +
  # Alertmanager + four exporters + Grafana. The decisive difference is not the
  # process count: it is that nothing here *ships* anything. Netdata reads
  # /proc and the journal on demand, so the steady-state write load is its own
  # dbengine and nothing else. The old stack wrote every journal entry to disk
  # a second time (Vector's 1 GiB buffer) and a third (VictoriaLogs), on the
  # 7200 RPM spindle that also holds /nix/store and the swapfile.
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

    # The three things this host actually needs -- the journal browser, PSI and
    # cgroup metrics, and per-app resource usage -- are all C plugins. python.d
    # is a separate interpreter running a scheduler for collectors this host has
    # nothing for (postgres, nvidia-smi, ceph...). Every other plugin is left at
    # its default: the point of this rewrite was to stop guessing at what is
    # heavy, so anything else gets disabled only after it is measured doing
    # damage.
    python.enable = false;

    config = {
      web = {
        # Netdata binds `*` by default -- every interface including the globally
        # routable IPv6 address. The agent dashboard has no authentication of
        # its own and the journal browser is part of it, so an unbound listener
        # publishes this host's logs. Caddy is the only path in; the firewall
        # dropping the port is the second layer rather than the only one.
        "bind to" = "127.0.0.1:${toString PORTS.NETDATA}";
      };

      db = {
        mode = "dbengine";

        # One tier, not the default three. Tiers exist to keep years of
        # downsampled history; the question this host needs answered is "what
        # was happening in the last few days", and each extra tier is another
        # set of files being flushed to the same spindle.
        "storage tiers" = 1;

        # Hard cap. Unlike VictoriaMetrics -- which had no byte-budget flag at
        # all, so a cardinality explosion could grow unbounded -- dbengine
        # evicts oldest-first to stay under this. At the default 1s collection
        # rate this is on the order of a week for this host's chart count.
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
      description = "Metrics, logs & alerts";
      group = "Monitoring";
      icon = "netdata.png";
    };

    proxy = {
      enable = true;
      port = PORTS.NETDATA;

      # LAN, and additionally behind a password. The remote_ip guard alone would
      # be the only thing between the internet and an unauthenticated shell-
      # adjacent view of this host -- the journal browser reads every unit's
      # logs, and Netdata has no login to fall back on if that guard is ever
      # loosened by mistake. Two independent controls, matching how the rest of
      # this config treats loopback binds plus firewall rules.
      #
      # `import` is a Caddyfile preprocessing directive and works inside a
      # route. The credentials live in an agenix file rather than inline because
      # everything written here lands in the nix store, which is world-readable
      # on this host.
      #
      # The CSP is a backstop for the bundled dashboard's third-party calls.
      # Most of them -- Google Tag Manager, PostHog, Sentry -- are already dead
      # because the agent build hardcodes `tracking: false`, and the registry
      # iframe is handled at its source above. This catches the rest (a Prismic
      # news feed, a marketing counter on cloudfunctions.net, cdnjs for PDF
      # export) and, more to the point, anything a future bundle adds. Only
      # connect-src and frame-src are constrained: script-src is left alone
      # because the dashboard's own bundle is what would break.
      config = ''
        import ${config.age.secrets.netdata-basicauth.path}
        header Content-Security-Policy "connect-src 'self'; frame-src 'self'"
        reverse_proxy localhost:${toString PORTS.NETDATA}
      '';

      exposure = "LAN";
    };
  };
}
