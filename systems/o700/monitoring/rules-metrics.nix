# Alert rules evaluated against VictoriaMetrics (PromQL).
# Imported directly as the `rules` value for the vmalert-metrics instance.
#
# VERIFY before relying on these:
#   - Caddy metric names: curl -s 127.0.0.1:2019/metrics | grep ^caddy_http
#   - fail2ban metric names: curl -s 127.0.0.1:9191/metrics | head -40
#   - smartctl attribute labels: curl -s 127.0.0.1:9633/metrics | grep Reallocated
#   - vm_storage_is_read_only: curl -s 127.0.0.1:8428/metrics | grep read_only
{ PATHS, ... }: {
  groups = [
    {
      name = "host-health";
      rules = [
        {
          alert = "RootDiskLow";
          expr = ''node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} < 0.15'';
          "for" = "30m";
          labels.severity = "warning";
          annotations.summary = "Root filesystem < 15% free";
        }
        {
          alert = "RootDiskCritical";
          expr = ''node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} < 0.07'';
          "for" = "10m";
          labels.severity = "critical";
          annotations.summary = "Root filesystem < 7% free";
        }
        {
          alert = "RootDiskFillingFast";
          # predict_linear: if it fills within the next 24h at the current rate
          expr = ''predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 86400) < 0'';
          "for" = "1h";
          labels.severity = "warning";
          annotations.summary = "Root filesystem will fill within 24h at current rate";
        }
        {
          alert = "RootFilesystemReadOnly";
          expr = ''node_filesystem_readonly{mountpoint="/"} == 1'';
          "for" = "1m";
          labels.severity = "critical";
          annotations.summary = "Root filesystem is read-only (disk full or VictoriaMetrics cap hit?)";
        }
        {
          alert = "MemoryExhausted";
          expr = "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.08";
          "for" = "15m";
          labels.severity = "warning";
          # swapDevices = [] so there is nothing to absorb pressure; an OOM kill
          # can follow quickly after this threshold. 8% of 16 GB = ~1.3 GB.
          annotations.summary = "< 8% RAM available; OOM kill risk";
        }
        {
          alert = "OOMKill";
          expr = "increase(node_vmstat_oom_kill[15m]) > 0";
          "for" = "0m";
          labels.severity = "critical";
          annotations.summary = "A process was OOM-killed";
        }
        {
          alert = "LoadSustained";
          expr = "node_load15 / count(count by(cpu)(node_cpu_seconds_total)) > 2";
          "for" = "30m";
          labels.severity = "warning";
          annotations.summary = "15-min load average > 2x CPU count for 30 min";
        }
        {
          alert = "Overheating";
          # Lid is closed and the switch is ignored. The laptop runs in an
          # enclosed space with no active cooling; 85 C is the threshold before
          # thermal throttling becomes aggressive.
          expr = "node_hwmon_temp_celsius > 85";
          "for" = "10m";
          labels.severity = "warning";
          annotations.summary = "CPU/GPU temperature > 85 C";
        }
        {
          alert = "UnexpectedReboot";
          expr = "changes(node_boot_time_seconds[1h]) > 0";
          "for" = "0m";
          labels.severity = "warning";
          annotations.summary = "Host rebooted";
        }
        {
          alert = "ClockDrift";
          # TLS validity windows and log-to-metric correlation both silently
          # break before anything reports an error when the clock drifts.
          expr = "abs(node_timex_offset_seconds) > 0.5";
          "for" = "15m";
          labels.severity = "warning";
          annotations.summary = "NTP offset > 500 ms";
        }
        {
          alert = "SmartFailing";
          expr = "smartctl_device_smart_status == 0";
          "for" = "5m";
          labels.severity = "critical";
          annotations.summary = "SMART overall health check FAILED on {{ $labels.device }}";
        }
        {
          # Reallocated sectors are permanent bad-block remaps; any increase
          # means the drive is actively failing. labelname must be verified:
          # `curl -s 127.0.0.1:9633/metrics | grep Reallocated`
          alert = "SmartReallocations";
          expr = ''increase(smartctl_device_attribute{attribute_name="Reallocated_Sector_Ct",attribute_value_type="raw"}[24h]) > 0'';
          "for" = "0m";
          labels.severity = "warning";
          annotations.summary = "Reallocated sectors increased on {{ $labels.device }}";
        }
      ];
    }

    {
      name = "service-liveness";
      rules = [
        {
          alert = "SystemdUnitFailed";
          # Generic: covers every service in this repo automatically, including
          # ones added later, without naming any of them here.
          expr = ''node_systemd_unit_state{state="failed"} == 1'';
          "for" = "5m";
          labels.severity = "warning";
          annotations.summary = "Systemd unit {{ $labels.name }} is in failed state";
        }
        {
          alert = "ScrapeTargetDown";
          expr = "up == 0";
          "for" = "5m";
          labels.severity = "warning";
          annotations.summary = "Scrape target {{ $labels.instance }} is unreachable";
        }
        {
          # ProbeFailed is critical while SystemdUnitFailed is only warning
          # because a unit can be "active" and still serve 502s; the probe is
          # what a user experiences.
          alert = "ProbeFailed";
          expr = "probe_success == 0";
          "for" = "10m";
          labels.severity = "critical";
          annotations.summary = "Probe failed for {{ $labels.instance }}";
        }
        {
          alert = "ProbeSlow";
          expr = "probe_duration_seconds > 5";
          "for" = "15m";
          labels.severity = "warning";
          annotations.summary = "Probe took > 5s for {{ $labels.instance }}";
        }
        {
          # Caddy 5xx rate. Metric and label names must be confirmed:
          # `curl -s 127.0.0.1:2019/metrics | grep ^caddy_http`
          alert = "Caddy5xxRate";
          expr = ''sum by(host)(rate(caddy_http_requests_total{code=~"5.."}[5m])) > 0.2'';
          "for" = "10m";
          labels.severity = "warning";
          annotations.summary = "Caddy 5xx rate > 0.2/s on {{ $labels.host }}";
        }
        {
          alert = "UpstreamUnreachable";
          expr = ''probe_success{job="blackbox-icmp"} == 0'';
          "for" = "5m";
          labels.severity = "critical";
          annotations.summary = "ICMP probe failed for {{ $labels.instance }} (internet/LAN issue?)";
        }
      ];
    }

    {
      name = "security";
      rules = [
        {
          # Ban burst: > 10 new bans in 15 minutes means an active brute-force
          # campaign. fail2ban metric names must be verified:
          # `curl -s 127.0.0.1:9191/metrics | head -40`
          alert = "Fail2banBanBurst";
          expr = "increase(f2b_jail_banned_total[15m]) > 10";
          "for" = "0m";
          labels.severity = "warning";
          annotations.summary = "> 10 fail2ban bans in 15 min on jail {{ $labels.jail }}";
        }
        {
          alert = "Fail2banSustainedPressure";
          expr = "f2b_jail_banned_current > 25";
          "for" = "30m";
          labels.severity = "warning";
          annotations.summary = "> 25 currently banned IPs in jail {{ $labels.jail }}";
        }
        {
          alert = "Fail2banDown";
          expr = "f2b_up == 0";
          "for" = "5m";
          labels.severity = "critical";
          annotations.summary = "fail2ban exporter reports fail2ban is down";
        }
        {
          alert = "SuidBinaryFound";
          # SUID binaries outside /nix/store (immutable) and /run/wrappers
          # (NixOS's own sudo/ping/etc wrappers). Anything else is suspicious.
          expr = "o700_suid_outside_store_count > 0";
          "for" = "0m";
          labels.severity = "critical";
          annotations.summary = "Unexpected SUID binary found outside /nix/store and /run/wrappers";
        }
        {
          # Fires if the sha256 of /etc/ssh/authorized_keys/user changes.
          # In normal operation this only changes when the NixOS config is
          # rebuilt. An unexpected change means someone added or removed a key.
          alert = "AuthorizedKeysChanged";
          expr = "changes(o700_authorized_keys_digest[6h]) > 0";
          "for" = "0m";
          labels.severity = "critical";
          annotations.summary = "SSH authorized_keys file changed unexpectedly";
        }
      ];
    }

    {
      name = "data-integrity";
      rules = [
        {
          alert = "ExternalSSDUnmounted";
          expr = ''o700_mount_present{mount="${PATHS.EX-SSD}"} == 0'';
          "for" = "5m";
          labels.severity = "critical";
          annotations.summary = "External SSD is not mounted at ${PATHS.EX-SSD}";
        }
        {
          alert = "ExternalSSDLow";
          expr = ''node_filesystem_avail_bytes{mountpoint="${PATHS.EX-SSD}"} / node_filesystem_size_bytes{mountpoint="${PATHS.EX-SSD}"} < 0.10'';
          "for" = "30m";
          labels.severity = "warning";
          annotations.summary = "External SSD < 10% free";
        }
        {
          # 36 hours: the vaultwarden backup timer runs at 23:00 daily, so
          # this allows exactly one missed run plus a morning's worth of slack.
          # A stale password-manager backup is only discovered to matter at the
          # worst possible moment, hence critical rather than warning.
          alert = "VaultwardenBackupStale";
          expr = "o700_backup_age_seconds{name=\"vaultwarden\"} > 129600";
          "for" = "0m";
          labels.severity = "critical";
          annotations.summary = "Vaultwarden backup is > 36h old";
        }
        {
          # Caddy renews at ~30 days out (2/3 of a 90-day cert's life), so
          # < 14 days remaining means renewal has been failing for a fortnight.
          # This catches Cloudflare token expiry, plugin regression, ACME
          # loop failures -- none of which produce a reliable log line.
          alert = "CertExpiringSoon";
          expr = "probe_ssl_earliest_cert_expiry - time() < 1209600";
          "for" = "1h";
          labels.severity = "warning";
          annotations.summary = "TLS cert for {{ $labels.instance }} expires in < 14 days";
        }
        {
          alert = "CertExpiringCritical";
          expr = "probe_ssl_earliest_cert_expiry - time() < 432000";
          "for" = "10m";
          labels.severity = "critical";
          annotations.summary = "TLS cert for {{ $labels.instance }} expires in < 5 days";
        }
        {
          # vm_storage_is_read_only metric name must be verified:
          # `curl -s 127.0.0.1:8428/metrics | grep read_only`
          alert = "VictoriaMetricsReadOnly";
          expr = "vm_storage_is_read_only == 1";
          "for" = "5m";
          labels.severity = "critical";
          annotations.summary = "VictoriaMetrics is in read-only mode (disk full or minFreeDiskSpaceBytes hit)";
        }
        {
          # vl_rows_ingested_total metric name must be verified:
          # `curl -s 127.0.0.1:9428/metrics | grep rows_ingested`
          alert = "LogIngestionStopped";
          expr = "rate(vl_rows_ingested_total[15m]) == 0";
          "for" = "30m";
          labels.severity = "critical";
          annotations.summary = "VictoriaLogs has not ingested any rows in 30 min";
        }
      ];
    }

    {
      # The shipping path is journald -> Vector -> VictoriaLogs. With journald
      # retention cut to 500M, a break anywhere along it is silent data loss
      # within hours rather than a recoverable backlog, so each hop gets its
      # own signal. Vector's process death is covered separately and more
      # directly by OnFailure= in notify.nix; these cover the ways it stays
      # alive while not doing its job.
      name = "log-pipeline";
      rules = [
        {
          # Early warning ahead of VictoriaMetricsReadOnly. By the time that
          # one fires, ingestion has already stopped. -storage.minFreeDiskSpaceBytes
          # is 5GB, so 15GB leaves roughly a week of slack at the observed
          # write rate -- enough to act deliberately rather than at 3am.
          #
          # Metric name must be verified:
          #   curl -s 127.0.0.1:8428/metrics | grep free_disk
          alert = "VictoriaMetricsDiskLow";
          expr = "vm_free_disk_space_bytes < 15e9";
          "for" = "15m";
          labels.severity = "warning";
          annotations.summary = "VictoriaMetrics free disk below 15 GB (goes read-only at 5 GB)";
        }
        {
          # Verify: curl -s 127.0.0.1:9428/metrics | grep free_disk
          alert = "VictoriaLogsDiskLow";
          expr = "vl_free_disk_space_bytes < 15e9";
          "for" = "15m";
          labels.severity = "warning";
          annotations.summary = "VictoriaLogs free disk below 15 GB (refuses writes at 5 GB)";
        }
        {
          # The only alert in this group with no automatic remedy behind it.
          # VictoriaMetrics has no size-cap flag at all (see monitoring.nix), so
          # nothing evicts oldest-first when it grows past budget -- it simply
          # keeps growing until -storage.minFreeDiskSpaceBytes trips and
          # ingestion stops dead. 20GB is ~10x the expected footprint at 120d,
          # so crossing it means something changed shape, almost certainly
          # series cardinality rather than sample volume.
          #
          # Clearing it is manual: find the offending series and drop them, or
          # shorten retentionPeriod. Start with
          #   curl -s 127.0.0.1:8428/api/v1/status/tsdb
          #
          # Verify metric name: curl -s 127.0.0.1:8428/metrics | grep data_size
          alert = "VictoriaMetricsGrowthUnbounded";
          expr = "sum(vm_data_size_bytes) > 20e9";
          "for" = "1h";
          labels.severity = "warning";
          annotations.summary = "VictoriaMetrics past 20GB and nothing evicts automatically -- check cardinality before it hits the read-only brake";
        }
        {
          # Unlike the VictoriaMetrics alert above, this one is informational:
          # -retention.maxDiskSpaceUsageBytes=30GiB means VictoriaLogs is
          # already dropping oldest per-day partitions to stay under it. Nothing
          # is failing -- what changed is that the cap, not retentionPeriod, is
          # now what bounds history, so logs are aging out earlier than 120d.
          #
          # Verify: curl -s 127.0.0.1:9428/metrics | grep data_size
          alert = "VictoriaLogsRetentionTruncated";
          expr = "sum(vl_storage_data_size_bytes) > 29e9";
          "for" = "1h";
          labels.severity = "warning";
          annotations.summary = "VictoriaLogs near its 30GiB cap -- retention is now shorter than 120d";
        }
        {
          # Vector reporting errors on a component: a source that cannot read,
          # a transform whose VRL is failing per-event, or a sink being
          # rejected. Any of these drop events while the process stays up and
          # the unit stays "active", which is the failure mode OnFailure=
          # cannot catch.
          alert = "VectorComponentErrors";
          expr = "sum by(component_id)(rate(vector_component_errors_total[15m])) > 0";
          "for" = "15m";
          labels.severity = "warning";
          annotations.summary = "Vector component {{ $labels.component_id }} is erroring";
        }
        {
          # The disk buffer filling means Vector is reading faster than
          # VictoriaLogs accepts. Transient during a VictoriaLogs restart --
          # that is what the buffer is for -- so this only fires if it stays
          # high. At 1 GiB the buffer blocks, and blocking stalls the journald
          # reader, at which point the 500M journal is the only thing standing
          # between a slow sink and lost entries.
          alert = "VectorBufferBacklog";
          expr = "sum(vector_buffer_byte_size) > 5e8";
          "for" = "30m";
          labels.severity = "warning";
          annotations.summary = "Vector disk buffer above 500 MB -- VictoriaLogs is not keeping up";
        }
      ];
    }
  ];
}
