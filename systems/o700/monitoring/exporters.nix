{
  config,
  pkgs,
  PORTS,
  IP,
  ...
}:
{
  services.prometheus.exporters = {
    node = {
      enable = true;
      # Loopback-only. The firewall blocks this port from outside, but
      # stating loopback intent here ensures it stays that way even if
      # a well-meaning future change opens the port range.
      listenAddress = "127.0.0.1";
      port = PORTS.NODE;
      enabledCollectors = [
        # node_systemd_unit_state{name,state} is the single highest-leverage
        # series in the stack: one alert rule covers every service in this repo
        # automatically, including services added later, without naming any.
        "systemd"
        # Publishing surface for per-host facts that no standard exporter
        # covers: SSD presence, backup age, SUID count, authorized-keys digest.
        # Written by the node-exporter-facts timer (see facts.nix).
        "textfile"
        "processes"
      ];
      extraFlags = [
        "--collector.textfile.directory=/var/lib/node-exporter-textfile"
      ];
    };

    smartctl = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = PORTS.SMARTCTL;
      # Empty list means autodiscovery. Do not hardcode /dev/sdb: the external
      # SSD's node shifts between /dev/sdb and /dev/sdc on replug, and
      # hardcoding one causes silent gaps when it lands on the other.
      devices = [ ];
      # SMART reads can wake or spin up the device; 5 min is enough resolution
      # for health trending while not doing gratuitous reads every 60 seconds.
      maxInterval = "300s";
    };

    blackbox = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = PORTS.BLACKBOX;
      configFile = pkgs.writeText "blackbox.yml" (
        builtins.toJSON {
          modules = {
            # Login-walled apps return 401/403/302, not 200. The probe assertion
            # here is "the reverse proxy answered at all", not "the app is
            # accessible without credentials" -- which is the right health
            # definition for Vaultwarden, Gitea, Grafana, etc.
            https_any = {
              prober = "http";
              timeout = "10s";
              http = {
                valid_status_codes = [
                  200
                  204
                  301
                  302
                  303
                  307
                  308
                  401
                  403
                ];
                fail_if_not_ssl = true;
                preferred_ip_protocol = "ip4";
              };
            };
            icmp = {
              prober = "icmp";
              timeout = "5s";
            };
          };
        }
      );
    };

    fail2ban = {
      enable = true;
      # note: this exporter uses `host`, not `listenAddress`
      host = "127.0.0.1";
      port = PORTS.FAIL2BAN;
      # The exporter depends on prometheus-fail2ban-exporter-setup.service
      # which setfacl's the fail2ban socket. It will restart-loop on first
      # boot until fail2ban itself is running -- expected, not a bug.
    };
  };

  # Caddy admin API is the metrics source and the reload mechanism. The NixOS
  # Caddy module calls `caddy reload` on every nixos-rebuild switch, which
  # requires the admin API to be up. The tradeoff is that any local process
  # can POST /load and replace the entire Caddy config. Acceptable while the
  # host has no untrusted local workloads; revisit if that changes.
  services.victoriametrics.prometheusConfig = {
    global = {
      # 30s halves the footprint vs 15s and nothing here needs sub-minute
      # resolution -- the shortest for: clause in the ruleset is 5m.
      scrape_interval = "30s";
      scrape_timeout = "10s";
      external_labels.host = "o700";
    };

    scrape_configs = [
      {
        job_name = "node";
        static_configs = [ { targets = [ "127.0.0.1:${toString PORTS.NODE}" ]; } ];
      }
      {
        job_name = "smartctl";
        # SMART reads are rate-limited at the exporter; no need to scrape more
        # often than the exporter's own maxInterval.
        scrape_interval = "5m";
        static_configs = [ { targets = [ "127.0.0.1:${toString PORTS.SMARTCTL}" ]; } ];
      }
      {
        job_name = "fail2ban";
        static_configs = [ { targets = [ "127.0.0.1:${toString PORTS.FAIL2BAN}" ]; } ];
      }
      {
        job_name = "caddy";
        static_configs = [ { targets = [ "127.0.0.1:${toString PORTS.CADDY_ADMIN}" ]; } ];
        metrics_path = "/metrics";
      }
      {
        # Vector's internal_metrics, exposed by its own prometheus_exporter
        # sink. This is the only way to see that shipping is healthy: with the
        # journal no longer retained for long, an unnoticed Vector failure is
        # silent data loss rather than a delay.
        job_name = "vector";
        static_configs = [ { targets = [ "127.0.0.1:${toString PORTS.VECTOR}" ]; } ];
      }
      {
        job_name = "self";
        static_configs = [
          {
            targets = [
              "127.0.0.1:${toString PORTS.VICTORIA_METRICS}"
              "127.0.0.1:${toString PORTS.VICTORIA_LOGS}"
              "127.0.0.1:${toString PORTS.VMALERT_METRICS}"
              "127.0.0.1:${toString PORTS.VMALERT_LOGS}"
              "127.0.0.1:${toString PORTS.ALERT_MANAGER}"
              "127.0.0.1:${toString PORTS.GRAFANA}"
            ];
          }
        ];
      }
      # Standard blackbox indirection: the probed URL travels as the
      # __param_target label, the exporter is the real scrape address, and
      # `instance` is relabelled back to the URL so alerts name the site.
      {
        job_name = "blackbox-https";
        metrics_path = "/probe";
        params.module = [ "https_any" ];
        scrape_interval = "60s";
        static_configs = [
          {
            targets = map ({ proxy, ... }: "https://${proxy.domain}/") (
              builtins.filter (meta: meta.proxy.enable) (builtins.attrValues config.seta)
            );
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:${toString PORTS.BLACKBOX}";
          }
        ];
      }
      # ICMP probes distinguish "our services are broken" from "the internet
      # is gone" when every https probe fails at once.
      {
        job_name = "blackbox-icmp";
        metrics_path = "/probe";
        params.module = [ "icmp" ];
        scrape_interval = "60s";
        static_configs = [
          {
            targets = [
              IP.router
              IP.cloudflare-dns
            ];
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:${toString PORTS.BLACKBOX}";
          }
        ];
      }
    ];
  };
}
