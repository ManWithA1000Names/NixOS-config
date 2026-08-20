# Loopback port assignments for every internal monitoring component.
#
# Imported by exporters.nix (scrape config) and facts.nix (listener
# allowlist) so the two cannot drift. These ports never appear in
# all_services and are never opened in the firewall; they are loopback-only
# and reached from outside via ssh -L.
{
  victoriametrics = 8428;
  victorialogs = 9428;
  vmalert-metrics = 8880;
  vmalert-logs = 8881;
  alertmanager = 9093;
  grafana = 3000;
  node = 9100;
  smartctl = 9633;
  blackbox = 9115;
  fail2ban = 9191;
  caddy-admin = 2019;
}
