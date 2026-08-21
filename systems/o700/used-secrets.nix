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
  };
}
