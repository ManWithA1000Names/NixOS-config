{ config, pkgs, lib, ... }:
let
  ports = import ./monitoring/ports.nix;
in {
  imports = [
    ./monitoring/exporters.nix
    ./monitoring/facts.nix
    ./monitoring/notify.nix
  ];

  # ---------------------------------------------------------------------------
  # VictoriaMetrics (metrics storage)
  # ---------------------------------------------------------------------------

  services.victoriametrics = {
    enable = true;

    # Loopback: scraped by itself, vmalert, and Grafana. Never needs to be
    # reachable from outside, and is not opened in the firewall.
    listenAddress = "127.0.0.1:${toString ports.victoriametrics}";

    # 16 MB/day at the configured scrape set and 30s interval, so 90 days is
    # ~1.5 GB plus index. 90 days is the shortest window that still answers
    # "was this normal three months ago?" after an incident.
    retentionPeriod = "90d";

    extraOptions = [
      # Hard stop before the root filesystem is endangered. At this threshold
      # VM goes read-only rather than continuing until ext4 has no room for its
      # journal. Losing new metrics is recoverable; a full root disk takes sshd,
      # Caddy and the whole box with it. VictoriaMetricsReadOnly in
      # rules-metrics.nix makes this state loud.
      "-storage.minFreeDiskSpaceBytes=5GB"

      # The default -memory.allowedPercent=60 would reserve ~9.6 GB of this
      # 16 GB box's RAM. That is appropriate for a dedicated TSDB host, not
      # for one that also transcodes video via Jellyfin. 1 GB is far more than
      # ~8k active series requires and leaves the page cache to the media stack.
      "-memory.allowedBytes=1GB"
    ];
  };

  # ---------------------------------------------------------------------------
  # VictoriaLogs (log storage)
  # ---------------------------------------------------------------------------

  services.victorialogs = {
    enable = true;
    listenAddress = "127.0.0.1:${toString ports.victorialogs}";

    extraOptions = [
      # 30-day retention. Logs answer "what happened during this incident";
      # incidents are found within days, not months. Longer questions are
      # better answered by the metrics above, which are two orders of magnitude
      # cheaper per day.
      "-retentionPeriod=30d"

      # Disk cap independent of the time-based retention: time retention only
      # holds if the ingest rate stays what was assumed. A log loop or a
      # scanner storm can blow through 30 days' worth of budget in hours.
      # VictoriaLogs may enforce a minimum; if startup fails with an argument
      # error, raise to its stated minimum rather than lowering.
      "-retention.maxDiskSpaceUsageBytes=10GiB"

      # Same reasoning as VictoriaMetrics: refuse writes before root fills.
      "-storage.minFreeDiskSpaceBytes=5GB"

      # Leave more memory for Jellyfin's page cache.
      "-memory.allowedBytes=512MB"

      # Every distinct combination of stream fields is a separate log stream;
      # VictoriaLogs pays per-stream overhead. _PID is in the default set,
      # which means every process restart mints a new stream -- unbounded churn.
      # Unit + hostname is the granularity we actually query by.
      "-journald.streamFields=_HOSTNAME,_SYSTEMD_UNIT"

      # These fields are constant-per-boot or non-queryable; dropping them at
      # ingest is cheaper than storing them and never selecting on them.
      "-journald.ignoreFields=_MACHINE_ID,_SOURCE_MONOTONIC_TIMESTAMP,__MONOTONIC_TIMESTAMP,_SYSTEMD_INVOCATION_ID,_CAP_EFFECTIVE"
    ];
  };

  # ---------------------------------------------------------------------------
  # Log shipping: systemd-journal-upload → VictoriaLogs
  # ---------------------------------------------------------------------------

  services.journald.upload = {
    enable = true;
    settings.Upload = {
      # journal-upload unconditionally appends "/upload" to whatever is
      # configured here (it builds proto + host + "/upload" in its URL
      # parser). VictoriaLogs handles journald ingestion under
      # /insert/journald and matches "/upload" beneath it, so the request
      # that lands is /insert/journald/upload -- which is what VictoriaLogs
      # documents. Do NOT add a trailing slash and do NOT append /upload here;
      # either produces a 404 that looks like a connectivity problem at runtime.
      #
      # The scheme is mandatory. Without it journal-upload defaults to https://
      # and fails the TLS handshake against a plaintext listener.
      URL = "http://127.0.0.1:${toString ports.victorialogs}/insert/journald";

      # Bound how long the uploader waits for a dead VictoriaLogs before
      # exiting. The unit restarts (Restart=always) and resumes from its
      # saved cursor, so an exit is cheap. The default ("wait forever") turns
      # a VictoriaLogs restart into a permanently wedged uploader.
      NetworkTimeoutSec = "30s";
    };
  };

  # Limit journald's own on-disk footprint. It is the write-ahead buffer for
  # journal-upload; it does not need to retain weeks of history independently.
  services.journald.extraConfig = ''
    # 2G is ~2 weeks of this host's traffic with log-queries routing to a file,
    # far more slack than the uploader ever needs. SystemKeepFree ensures the
    # root disk always has headroom even if VictoriaLogs falls behind.
    SystemMaxUse=2G
    SystemKeepFree=4G
  '';

  systemd.services.systemd-journal-upload = {
    # Ordering only -- not a hard dependency. If VictoriaLogs is down, the
    # uploader must still start, fail, and retry; the journal is the buffer.
    after = [ "victorialogs.service" ];
    wants = [ "victorialogs.service" ];
  };

  # ---------------------------------------------------------------------------
  # vmalert (rule evaluation and alert dispatch)
  #
  # Two instances are required because vmalert accepts exactly one
  # -datasource.url: metric rules query VictoriaMetrics, log rules query
  # VictoriaLogs. Left at the default -httpListenAddr=:8880, the second
  # instance dies with "address already in use" -- silently, since metric
  # alerts keep arriving and everything looks fine.
  # ---------------------------------------------------------------------------

  services.vmalert.instances = {
    metrics = {
      enable = true;
      settings = {
        "datasource.url" = "http://127.0.0.1:${toString ports.victoriametrics}";
        "notifier.url" = [ "http://127.0.0.1:${toString ports.alertmanager}" ];
        "httpListenAddr" = "127.0.0.1:${toString ports.vmalert-metrics}";
        # Persists for: timers across restarts and writes ALERTS series into
        # VictoriaMetrics so Grafana can show alert history.
        "remoteWrite.url" = "http://127.0.0.1:${toString ports.victoriametrics}";
        "external.url" = "https://grafana.o700.net";
        "external.label" = [ "host=o700" ];
      };
      # The `rules` attrset is serialised verbatim to YAML -- no schema
      # validation, no error on wrong keys. Use `groups:` at the top level,
      # NOT `group:` (the nixpkgs example uses the wrong key).
      # After deploy, verify rule count in the vmalert UI: if it shows 0 rules
      # loaded, the top-level key is wrong.
      rules = import ./monitoring/rules-metrics.nix;
    };

    logs = {
      enable = true;
      settings = {
        # datasource.url is the bare VictoriaLogs base URL, NOT a path under
        # /select. With type: vlogs in the rule group, vmalert routes to
        # /select/logsql/stats_query by itself.
        "datasource.url" = "http://127.0.0.1:${toString ports.victorialogs}";
        "notifier.url" = [ "http://127.0.0.1:${toString ports.alertmanager}" ];
        "httpListenAddr" = "127.0.0.1:${toString ports.vmalert-logs}";
        "remoteWrite.url" = "http://127.0.0.1:${toString ports.victoriametrics}";
        "external.url" = "https://grafana.o700.net";
        "external.label" = [ "host=o700" ];
      };
      rules = import ./monitoring/rules-logs.nix;
    };
  };

  # ---------------------------------------------------------------------------
  # Alertmanager (grouping, inhibition, routing to Telegram)
  # ---------------------------------------------------------------------------

  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = ports.alertmanager;

    # configText rather than the structured `configuration` option for one
    # specific reason: Alertmanager types chat_id as int64. The structured
    # path renders the envsubst placeholder as a quoted JSON string, which
    # Alertmanager rejects. As raw text, the substituted value lands unquoted
    # and parses correctly.
    #
    # Same fact forces checkConfig = false: amtool validates the pre-substitution
    # file, where chat_id is literally "$TELEGRAM_CHAT_ID" -- a string, not int.
    checkConfig = false;
    environmentFile = config.age.secrets.alerting.path;

    configText = ''
      global:
        resolve_timeout: 5m

      route:
        receiver: telegram
        group_by: ['alertname', 'severity']
        # Telegram rate-limits a chat to ~20 messages/minute. group_wait and
        # group_interval keep an incident that fires thirty alerts at once
        # under that limit without delaying the first notification past usefulness.
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 12h
        routes:
          - receiver: telegram
            matchers:
              - severity = "critical"
            repeat_interval: 4h

      inhibit_rules:
        # A dead host produces one root-cause alert and many derived ones.
        # Suppress the derived ones so the message says what is wrong, not
        # everything that is downstream of it.
        - source_matchers:
            - alertname = "ScrapeTargetDown"
          target_matchers:
            - severity =~ "warning|info"
          equal: [instance]
        - source_matchers:
            - alertname = "ExternalSSDUnmounted"
          target_matchers:
            - alertname = "ExternalSSDLow"

      receivers:
        - name: telegram
          telegram_configs:
            - bot_token: $TELEGRAM_BOT_TOKEN
              chat_id: $TELEGRAM_CHAT_ID
              parse_mode: HTML
              send_resolved: true
              message: |-
                {{ if eq .Status "firing" }}FIRING{{ else }}RESOLVED{{ end }} - <b>o700</b>
                {{ range .Alerts -}}
                <b>{{ .Labels.alertname }}</b>{{ if .Labels.severity }} [{{ .Labels.severity }}]{{ end }}
                {{ if .Annotations.summary }}{{ .Annotations.summary }}{{ end }}
                {{ if .Labels.instance }}<code>{{ .Labels.instance }}</code>{{ end }}
                {{ end -}}
    '';
  };

  # ---------------------------------------------------------------------------
  # Grafana (dashboards + provisioned datasources)
  # Loaded declaratively by the victoriametrics-logs-datasource plugin.
  # ---------------------------------------------------------------------------

  # If Grafana refuses to load the plugin (signature rejected), uncomment:
  # services.grafana.settings.plugins.allow_loading_unsigned_plugins =
  #   "victoriametrics-logs-datasource";

  # The /var/log/caddy directory is created by hardening.nix (where the
  # fail2ban jail that reads it is also defined).
}
