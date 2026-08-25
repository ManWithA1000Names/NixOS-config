{
  config,
  PORTS,
  DOMAIN,
  PATHS,
  # Referenced only from the commented vaultwarden block below for now.
  # POSTGRESQL_DBHOST,
  ...
}:
{
  services = {
    vaultwarden = {
      enable = true;
      domain = "${config.seta.vaultwarden.proxy.domain}";
      backupDir = "${PATHS.BACKUP_ROOT}/warden";
      config = {
        ROCKET_PORT = PORTS.VAULTWARDEN;

        # Vaultwarden ships with signups OPEN. On a WAN-exposed vhost that
        # means anyone who finds the domain can create an account inside the
        # vault host -- they cannot read existing vaults, but they get a
        # foothold, storage, and a login form that no longer looks anomalous
        # in the logs. Existing accounts are unaffected by this; to add a new
        # one, invite from an existing account or flip this temporarily.
        SIGNUPS_ALLOWED = false;
      };

      # MIGRATION STEP 5 -- LAST, and gated on the backup being rewritten first.
      #
      #   dbBackend = "postgresql";
      #
      # The module asserts `backupDir != null -> dbBackend == "sqlite"`
      # ("Backups for database backends other than sqlite will need
      # customization"), so flipping this REQUIRES deleting backupDir above --
      # which deletes the backup-vaultwarden unit, and that unit is load-bearing
      # in three other places:
      #
      #   - seta.vaultwarden.units below (RequiresMountsFor + OnFailure)
      #   - the freshness check in monitoring/checks.nix, which looks for files
      #     under BACKUP_ROOT/warden and reports daily when it finds none
      #   - the nightly timer that is currently the only copy of this vault
      #
      # So the order is: write the pg_dump job, point checks.nix at it, let it
      # run clean for several nights, and only then come back here. Do not flip
      # this and "fix the backup after" -- the window in between has no backup
      # of the one service on this host whose loss is unrecoverable.
      #
      # Note `configurePostgres` is NOT the option to use: it would declare its
      # own database and user, duplicating what seta already creates. dbBackend
      # alone plus DATABASE_URL below is enough.
      #
      # config.DATABASE_URL = "postgresql:///vaultwarden?host=${POSTGRESQL_DBHOST}";
    };

    gitea = {
      enable = true;
      lfs.enable = true;
      settings = {
        server = {
          DOMAIN = "${config.seta.gitea.proxy.domain}";
          HTTP_PORT = PORTS.GITEA;

          # Loopback so caddy is the only path in. The firewall already drops
          # this port from outside -- it is not in allowedTCPPorts -- so this
          # is the backup for the case where the firewall is the thing that
          # failed. Defence in depth is only depth if the layers fail
          # independently, and a bad nftables ruleset does not move a listener.
          HTTP_ADDR = "127.0.0.1";
        };

        # Same reasoning as SIGNUPS_ALLOWED above. Note this only closes
        # self-registration: anonymous *reading* of public repositories still
        # works. Set REQUIRE_SIGNIN_VIEW if that should close too -- it also
        # breaks unauthenticated `git clone`, so it is left alone here.
        service.DISABLE_REGISTRATION = true;
      };

      # MIGRATION STEP 3 -- uncomment together with seta.gitea.postgres.
      #
      # The biggest single payoff here: gitea's sqlite file is the largest and
      # busiest state on this host. `createDatabase` already defaults true and
      # `socket` then defaults to /run/postgresql, so type alone is enough --
      # and unlike mealie/vaultwarden, gitea reads the configured port back
      # (database.port defaults to pg.settings.port), so it is the one service
      # that would survive POSTGRESQL moving off 5432.
      #
      # No built-in converter. Stock pkgs.pgloader should serve -- gitea's xorm
      # identifiers are lowercase snake_case, so it avoids the quoting bug --
      # but rehearse against a *copy* of /var/lib/gitea/data/gitea.db and
      # compare row counts before pointing the live instance at the result.
      #
      # database.type = "postgres";
    };
  };

  seta = {
    vaultwarden = {
      # Just the service. Backups are becoming their own subsystem rather than
      # an adjunct of the thing they back up, so backup-vaultwarden is not
      # listed here even though it exists today -- see the note in
      # hardware-configuration.nix and monitoring/notify.nix.

      # vaultwarden's own state is /var/lib/vaultwarden on the root disk; it is
      # backupDir that lives on the SSD. Once step 5 moves that state into
      # postgres and drops backupDir, nothing of vaultwarden's touches the SSD
      # and this should go back to false -- otherwise unplugging the drive takes
      # the password manager down for no reason at all.
      requiresExSSD = true;

      critical = true;

      # MIGRATION STEP 5 -- uncomment with services.vaultwarden above, and only
      # after the pg_dump backup has replaced backup-vaultwarden.
      # postgres = true;

      dashboard = {
        enable = true;
        name = "Vaultwarden";
        description = "Password & Secrets manager";
        group = "Apps";
        icon = "vaultwarden.png";
      };

      proxy = {
        enable = true;
        port = PORTS.VAULTWARDEN;
        domain = "vault.${DOMAIN}";
        exposure = "WAN";
      };
    };

    gitea = {
      critical = true;

      # MIGRATION STEP 3 -- uncomment with services.gitea.database above.
      # postgres = true;

      dashboard = {
        enable = true;
        name = "Gitea";
        description = "Git hosting";
        group = "Apps";
        icon = "gitea.png";
      };

      proxy = {
        enable = true;
        port = PORTS.GITEA;
        domain = "git.${DOMAIN}";
        exposure = "WAN";
      };
    };
  };
}
