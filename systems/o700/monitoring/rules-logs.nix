# Alert rules evaluated against VictoriaLogs (LogsQL).
# Imported directly as the `rules` value for the vmalert-logs instance.
#
# ALL expressions here must be verified empirically before trusting:
#
#   1. Check that logs are arriving:
#      curl -s 'http://127.0.0.1:9428/select/logsql/query?query=*&limit=3'
#
#   2. Check the actual field names as ingested from journald:
#      curl -s 'http://127.0.0.1:9428/select/logsql/query?query=_time:1m&limit=1'
#      Look for _SYSTEMD_UNIT, SYSLOG_IDENTIFIER, MESSAGE vs _MESSAGE, etc.
#
#   3. Verify threshold semantics: does vmalert fire when the stats query
#      returns a row, or only when the value > 0? Test with one rule first.
#      If vmalert fires on any returned row, drop the `| filter c > N` clause.
#
# Until verified, these rules fire safe-fail: a wrong field name yields no
# matches, which means no rows, which means no alert -- so a misconfigured
# log rule causes silence rather than spam.
_: {
  groups = [
    {
      name = "security-logs";
      # type = "vlogs" tells vmalert to query VictoriaLogs' LogsQL endpoint
      # rather than VictoriaMetrics' PromQL endpoint. Without this the instance
      # sends /api/v1/query to VictoriaLogs and gets a 404 -- and because that
      # looks like a connectivity error, no alert fires and no error is obvious.
      type = "vlogs";
      interval = "2m";
      rules = [
        {
          alert = "SSHBruteForce";
          # SSH failed authentication: high volume in a short window.
          # Field name _SYSTEMD_UNIT must match what VictoriaLogs actually
          # stores -- verify with the query above before tuning the threshold.
          expr = ''_time:10m _SYSTEMD_UNIT:"sshd.service" "Failed password" | stats count() as c | filter c > 20'';
          labels.severity = "warning";
          annotations.summary = "> 20 SSH authentication failures in the last 10 min";
        }
        {
          alert = "SudoAuthFailure";
          expr = ''_time:10m SYSLOG_IDENTIFIER:"sudo" "authentication failure" | stats count() as c | filter c > 3'';
          labels.severity = "warning";
          annotations.summary = "> 3 sudo authentication failures in the last 10 min";
        }
        {
          alert = "PAMAuthFailureBurst";
          # Catches authentication failures from any PAM-using service (su, login,
          # screensaver unlock) that does not have its own jail.
          expr = ''_time:10m SYSLOG_IDENTIFIER:"(sshd|login|su)" "authentication failure" | stats count() as c | filter c > 10'';
          labels.severity = "warning";
          annotations.summary = "> 10 PAM authentication failures in the last 10 min";
        }
      ];
    }
  ];
}
