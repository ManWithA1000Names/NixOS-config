{
  config,
  PORTS,
  ...
}@args:
{
  imports = [
    ./monitoring/exporters.nix
    ./monitoring/facts.nix
    ./monitoring/notify.nix
    ./monitoring/shipping.nix
  ];

  # ---------------------------------------------------------------------------
  # VictoriaMetrics (metrics storage)
  # ---------------------------------------------------------------------------

  services.victoriametrics = {
    enable = true;

    # Loopback: scraped by itself, vmalert, and Grafana. Never needs to be
    # reachable from outside, and is not opened in the firewall.
    listenAddress = "127.0.0.1:${toString PORTS.VICTORIA_METRICS}";

    # 16 MB/day at the configured scrape set and 30s interval, so 120 days is
    # ~2 GB plus index. Metrics are two orders of magnitude cheaper per day
    # than logs, so the retention window is set by what is useful rather than
    # by what is affordable: a full seasonal cycle of "was this normal?".
    retentionPeriod = "120d";

    extraOptions = [
      # Evict oldest-first to stay under the cap. This is the mechanism that
      # keeps a runaway from ever reaching the read-only threshold below:
      # ingestion continues uninterrupted and old partitions are dropped
      # instead. Sized ~10x expected usage, so in normal operation
      # retentionPeriod is what binds and this never engages -- it is runaway
      # protection, not a storage budget.
      #
      # Dropping happens per-partition, so actual usage sawtooths below the cap
      # rather than sitting against it. VM enforces a minimum here; if it
      # refuses to start with an argument error, raise to its stated minimum
      # rather than lowering.
      "-storage.maxDiskSpaceUsageBytes=20GiB"

      # Hard stop before the root filesystem is endangered, for the case the
      # cap above cannot help with: something *other* than VictoriaMetrics
      # eating the disk. At this threshold VM goes read-only rather than
      # continuing until ext4 has no room for its journal. Losing new metrics
      # is recoverable; a full root disk takes sshd, Caddy and the whole box
      # with it. VictoriaMetricsReadOnly in rules-metrics.nix makes this state
      # loud, and VictoriaMetricsDiskLow warns well before it.
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
    listenAddress = "127.0.0.1:${toString PORTS.VICTORIA_LOGS}";

    extraOptions = [
      # 120 days, matching the metrics window above so a post-mortem never has
      # metrics for a period it has no logs for -- the mismatch is only ever
      # discovered at the moment it hurts. Full capture runs 20-40 MB/day
      # compressed, so this is 3-5 GB.
      "-retentionPeriod=120d"

      # Evict oldest-first to stay under the cap. Time-based retention only
      # holds if the ingest rate stays what was assumed; a log loop or a
      # scanner storm can burn through 120 days' worth of budget in hours.
      # Sized ~6x expected usage: runaway protection, not a storage budget.
      # VictoriaLogs enforces a minimum; if startup fails with an argument
      # error, raise to its stated minimum rather than lowering.
      "-retention.maxDiskSpaceUsageBytes=30GiB"

      # Same reasoning as VictoriaMetrics: refuse writes before root fills.
      "-storage.minFreeDiskSpaceBytes=5GB"

      # Leave more memory for Jellyfin's page cache.
      "-memory.allowedBytes=512MB"

      # NOTE: -journald.streamFields and -journald.ignoreFields used to be set
      # here. They apply only to the /insert/journald endpoint, which
      # systemd-journal-upload used and Vector does not -- shipping now goes
      # through /insert/elasticsearch (see monitoring/shipping.nix). Left as a
      # comment rather than dead flags because their equivalents are load-
      # bearing: stream-field selection moved to the sink's _stream_fields
      # query parameter, and dropping them there is what prevents a new stream
      # per PID.
    ];
  };

  # ---------------------------------------------------------------------------
  # Journald
  #
  # Shipping is Vector's job now -- see monitoring/shipping.nix.
  # services.journald.upload is deliberately NOT enabled: Vector's journald
  # source reads the same journal, so running both would ingest every entry
  # into VictoriaLogs twice.
  # ---------------------------------------------------------------------------

  services.journald.extraConfig = ''
    # Vector's 1 GiB disk buffer, not this, is the write-ahead buffer for
    # shipping. What this number bounds is how long Vector can be *dead* before
    # entries age out unshipped. 500M would be many hours; 2G is days, and the
    # disk has room to spare. It also matters more than it used to now that
    # every vhost's access log lands here: fail2ban reads this journal, so
    # entries aging out early would cost bans, not just history.
    SystemMaxUse=2G

    # Unchanged: guarantees the root disk keeps headroom regardless of the cap
    # above, since journald is not the only thing writing to it.
    SystemKeepFree=4G
  '';

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
        "datasource.url" = "http://127.0.0.1:${toString PORTS.VICTORIA_METRICS}";
        "notifier.url" = [ "http://127.0.0.1:${toString PORTS.ALERT_MANAGER}" ];
        "httpListenAddr" = "127.0.0.1:${toString PORTS.VMALERT_METRICS}";
        # Persists for: timers across restarts and writes ALERTS series into
        # VictoriaMetrics so Grafana can show alert history.
        "remoteWrite.url" = "http://127.0.0.1:${toString PORTS.VICTORIA_METRICS}";
        "external.url" = "https://grafana.o700.net";
        "external.label" = [ "host=o700" ];
      };
      # The `rules` attrset is serialised verbatim to YAML -- no schema
      # validation, no error on wrong keys. Use `groups:` at the top level,
      # NOT `group:` (the nixpkgs example uses the wrong key).
      # After deploy, verify rule count in the vmalert UI: if it shows 0 rules
      # loaded, the top-level key is wrong.
      rules = import ./monitoring/rules-metrics.nix args;
    };

    logs = {
      enable = true;
      settings = {
        # datasource.url is the bare VictoriaLogs base URL, NOT a path under
        # /select. With type: vlogs in the rule group, vmalert routes to
        # /select/logsql/stats_query by itself.
        "datasource.url" = "http://127.0.0.1:${toString PORTS.VICTORIA_LOGS}";
        "notifier.url" = [ "http://127.0.0.1:${toString PORTS.ALERT_MANAGER}" ];
        "httpListenAddr" = "127.0.0.1:${toString PORTS.VMALERT_LOGS}";
        "remoteWrite.url" = "http://127.0.0.1:${toString PORTS.VICTORIA_METRICS}";
        "external.url" = "https://grafana.o700.net";
        "external.label" = [ "host=o700" ];
      };
      rules = import ./monitoring/rules-logs.nix args;
    };
  };

  # ---------------------------------------------------------------------------
  # Alertmanager (grouping, inhibition, routing to Telegram)
  # ---------------------------------------------------------------------------

  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = PORTS.ALERT_MANAGER;

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
}
