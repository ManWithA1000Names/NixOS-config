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
    leantime-session.file = ../../secrets/leantime-session.age;

    # The same ciphertext as `alerting` above, decrypted a second time under a
    # different owner. Netdata's alarm-notify.sh runs as the netdata user and
    # sources this file as bash, so it has to open the file itself -- there is
    # no PID 1 step reading it privileged first. agenix keys secrets by
    # attribute name rather than by file, so two entries pointing at one .age is
    # how the same value reaches two identities without a second plaintext.
    alerting-netdata = {
      file = ../../secrets/alerting.age;
      owner = "netdata";
      group = "netdata";
    };
  };
}
