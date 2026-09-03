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

    # No owner, same reason as `alerting`: both opencloud units take this as a
    # systemd EnvironmentFile, which PID 1 reads before dropping to the
    # opencloud user. Contents are `KEY=value` lines, at minimum
    # IDM_ADMIN_PASSWORD -- see services-WAN.nix for why that one matters.
    opencloud-env.file = ../../secrets/opencloud-env.age;

    # No owner, and here that is forced rather than merely unnecessary: the n8n
    # unit runs DynamicUser=true, so there is no stable uid to chown to. The
    # nixpkgs module routes every *_FILE variable through LoadCredential
    # (services/misc/n8n.nix), which PID 1 opens as root and re-exposes under
    # $CREDENTIALS_DIRECTORY before dropping to the dynamic user -- the same
    # PID-1-reads-it-first arrangement as `alerting` above.
    #
    # Contents are the bare key and nothing else: no trailing newline, no JSON
    # wrapper. n8n's *_FILE reader returns the file untrimmed (@n8n/config,
    # decorators.js) and only warns about surrounding whitespace, but the
    # comparison against .n8n/config is exact and throws, so a stray newline is
    # a refusal to boot rather than a warning.
    n8n-encryption-key.file = ../../secrets/n8n-encryption-key.age;
  };
}
