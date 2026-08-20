# Alert rules evaluated against VictoriaMetrics (PromQL).
# Imported directly as the `rules` value for the vmalert-metrics instance.
#
# VERIFY before relying on these:
#   - Caddy metric names: curl -s 127.0.0.1:2019/metrics | grep ^caddy_http
#   - fail2ban metric names: curl -s 127.0.0.1:9191/metrics | head -40
#   - smartctl attribute labels: curl -s 127.0.0.1:9633/metrics | grep Reallocated
#   - vm_storage_is_read_only: curl -s 127.0.0.1:8428/metrics | grep read_only
{
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
          expr = ''o700_mount_present{mount="/mnt/ex-ssd"} == 0'';
          "for" = "5m";
          labels.severity = "critical";
          annotations.summary = "External SSD is not mounted at /mnt/ex-ssd";
        }
        {
          alert = "ExternalSSDLow";
          expr = ''node_filesystem_avail_bytes{mountpoint="/mnt/ex-ssd"} / node_filesystem_size_bytes{mountpoint="/mnt/ex-ssd"} < 0.10'';
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
  ];
}
