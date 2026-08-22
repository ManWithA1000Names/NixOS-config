{
  config,
  pkgs,
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
      config = ''
        import ${config.age.secrets.netdata-basicauth.path}
        reverse_proxy localhost:${toString PORTS.NETDATA}
      '';

      exposure = "LAN";
    };
  };
}
