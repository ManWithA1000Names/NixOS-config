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

    # No owner, same reason as `alerting`: every consumer is a systemd unit
    # running as root, which is not a convenience but a requirement -- the
    # backup jobs read /var/lib/private, which is 0700 root:root, so the three
    # DynamicUser services' state is unreadable to anything else.
    #
    # One password for both repositories. Two would only mean two things to
    # lose, and the offsite repository is a byte-exact copy of the local one
    # rather than an independently secured store.
    restic-password.file = ../../secrets/restic-password.age;

    # AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY for B2's S3-compatible
    # endpoint.
    #
    # Not a systemd EnvironmentFile despite the shape: every consumer is a
    # writeShellApplication doing `set -a; source <file>; set +a` (backup.nix,
    # monitoring/checks.nix). The file therefore has to be valid *shell*, which
    # EnvironmentFile syntax is not automatically -- plain `KEY=value` with no
    # spaces around the `=` satisfies both readings, which is why it is written
    # that way.
    #
    # Must be a B2 *application* key, not the account master key: the master
    # key is rejected by the S3-compatible API. Scope it to the one bucket.
    #
    # restic needs exactly five capabilities:
    #   listBuckets, listFiles, readFiles, writeFiles, deleteFiles
    #
    # The B2 console's "Read and Write" preset grants eighteen, and the extras
    # are not harmless -- writeBucketLifecycleRules alone would let a holder
    # schedule the deletion of everything, which is the same backstop the
    # bucket's version-retention rule is supposed to provide. Narrower keys can
    # only be created from the CLI (`b2 key create --bucket ...`), and from
    # big-boss rather than o700, since it needs the master key.
    #
    # deleteFiles cannot be dropped: restic removes its own locks, and
    # o700-backup-prune runs `forget --prune` offsite. See section 9 of
    # docs/backup-and-restore.md for what that leaves unprotected.
    restic-b2.file = ../../secrets/restic-b2.age;

    user-password.file = ../../secrets/user-password.age;
  };
}
