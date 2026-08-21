_: {
  age.secrets = {
    cloudflare-dns-api = {
      file = ../../secrets/cloudflare-dns-api.age;
      owner = "caddy";
      group = "caddy";
    };

    # No owner: consumed only as a systemd EnvironmentFile, which PID 1 reads
    # as root before dropping privileges.
    alerting.file = ../../secrets/alerting.age;

    # Owned by grafana, unlike alerting above: this one is read via grafana's
    # own $__file{} provider, so the grafana process opens it after dropping
    # privileges rather than PID 1 reading it as root.
    grafana-secret-key = {
      file = ../../secrets/grafana-secret-key.age;
      owner = "grafana";
      group = "grafana";
    };
  };
}
