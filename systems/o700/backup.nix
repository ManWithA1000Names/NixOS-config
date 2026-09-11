{
  config,
  lib,
  pkgs,
  PATHS,
  BACKUP,
  ...
}:
let
  # +-----------------------------------------------------------------+
  # | The manifest                                                    |
  # +-----------------------------------------------------------------+

  # Backup sets that are not seta services.
  #
  # The third of three sibling escape hatches, all in this directory and all
  # existing for the same reason: seta is keyed by *service*, and some things
  # that need its behaviour are not one. The other two are infraRequiresExSSD
  # (hardware-configuration.nix) and infraCriticalUnits (monitoring/notify.nix).
  #
  # Here, `postgres` is the database cluster itself and `kavita-library` is a
  # pile of files no daemon owns.
  #
  # This file is a seta *consumer*, like networking.nix and notify.nix, which is
  # why it lives beside them rather than in modules/. Nothing in it declares an
  # option -- seta.<svc>.backup is declared in modules/seta.nix, and everything
  # below merely reads that manifest and generates config from it. It is also
  # not host-agnostic and could not be: it reads config.seta, which exists only
  # on this host.
  infraBackupSets = {
    # The whole-cluster safety net, and the only set that captures roles,
    # grants and any database whose service has no seta entry. Every
    # per-service set already carries its own database, so this duplicates
    # them -- deliberately. Both are produced by the same pg_dump invocation
    # with the same flags, so the bytes are identical and restic stores the
    # overlap exactly once. What it buys is that a bare-metal rebuild is one
    # restore rather than six.
    postgres = {
      # Restoring this drops and recreates every database, which cannot happen
      # while anything holds a connection. The unit list is therefore every
      # backed-up service on the host, assembled below rather than written out,
      # so a service added to the backup cannot be left connected during a
      # cluster restore.
      units = lib.concatMap (meta: meta.units) (
        builtins.attrValues (lib.filterAttrs (_: meta: meta.backup.enable) config.seta)
      );

      # Never stopped for the *backup* -- pg_dump is an online, transactionally
      # consistent read. The units above matter only at restore time.
      stopUnits = false;

      paths = [ ];
      exclude = [ ];
      sqlite = [ ];

      databases = postgresDatabases;
      globals = true;

      package = config.services.postgresql.package;

      keepYearly = 10;
    };

    # Kavita's library. A separate set from `kavita` on purpose: the app's own
    # state is a few hundred MB and restoring it should take seconds, while
    # this is the bulk of the offsite bill. Splitting them means
    # `o700-restore restore kavita` never drags the library along, and the two
    # can carry different retention if the B2 invoice ever argues for it.
    kavita-library = {
      units = [ "kavita" ];
      stopUnits = false;
      paths = lib.optional (PATHS.BOOKS != "") PATHS.BOOKS;
      exclude = [ ];
      sqlite = [ ];
      databases = [ ];
      globals = false;
      package = null;
      keepYearly = 3;
    };
  };

  # Every database in the cluster, from the same manifest that creates them
  # (services-internal.nix does the same filter for ensureDatabases). Sorted so
  # the generated script is stable across rebuilds.
  postgresDatabases = lib.sort (a: b: a < b) (
    builtins.attrNames (lib.filterAttrs (_: meta: meta.postgres) config.seta)
  );

  # seta services that asked to be backed up, normalised into the same shape as
  # infraBackupSets so everything below has one kind of thing to iterate over.
  setaBackupSets = lib.mapAttrs (name: meta: {
    inherit (meta) units;
    inherit (meta.backup)
      stopUnits
      paths
      exclude
      sqlite
      keepYearly
      ;

    # `postgres` is already the database manifest -- see its description in
    # modules/seta.nix. This is the consumer three comments in this repo
    # promised and none delivered.
    databases = lib.optional meta.postgres name;
    globals = false;

    # The package whose version defines whether this snapshot's data can be
    # loaded. Looked up by service name rather than declared per service
    # because every one of these modules spells it `services.<name>.package`;
    # the assertion below is what stops that assumption from failing silently.
    package = config.services.${name}.package or null;
  }) (lib.filterAttrs (_: meta: meta.backup.enable) config.seta);

  sets = setaBackupSets // infraBackupSets;

  setNames = lib.sort (a: b: a < b) (builtins.attrNames sets);

  # The order the nightly run walks. Cheap and diagnostic first (a broken
  # postgres should fail in the first thirty seconds, not the last hour),
  # bulk last, and opencloud second-to-last because it is the one set that
  # stops a service -- putting its downtime at the end of the window rather
  # than in the middle of it.
  backupOrder =
    let
      tail = [
        "opencloud"
        "kavita-library"
      ];
      head = [ "postgres" ];
      middle = lib.subtractLists (head ++ tail) setNames;
    in
    builtins.filter (n: builtins.elem n setNames) (head ++ middle ++ tail);

  # +-----------------------------------------------------------------+
  # | Repositories                                                    |
  # +-----------------------------------------------------------------+

  localRepo = PATHS.RESTIC_REPO;
  offsiteRepo = "s3:${BACKUP.b2Endpoint}/${BACKUP.b2Bucket}";
  offsiteEnabled = BACKUP.b2Bucket != "";

  passwordFile = config.age.secrets.restic-password.path;
  b2EnvFile = config.age.secrets.restic-b2.path;

  staging = set: "${PATHS.BACKUP_STAGING}/${set}";

  # Refuse to start a backup that could fill the disk the repository lives on.
  # 10 GiB is not a computed figure -- it is comfortably more than the sum of
  # the database dumps and small enough not to trip on a healthy drive. If it
  # starts firing, that is the signal to prune, not to lower it.
  minFreeKiB = 10 * 1024 * 1024;

  # +-----------------------------------------------------------------+
  # | Version manifest                                                |
  # +-----------------------------------------------------------------+

  # Written next to the dumps so a snapshot knows what produced it. The point is
  # not bookkeeping: restoring a database under a *newer* binary than the one
  # that wrote it is the one way this whole system still loses data, and a
  # comparison is only possible if the old side recorded its version.
  #
  # configurationRevision is the load-bearing field. It is the git commit of
  # this repo that built the running system, so it survives
  # `just delete-generations` garbage-collecting the generation itself -- a
  # store path would not.
  manifestFor =
    set: meta:
    let
      rev =
        if config.system.configurationRevision == null then
          "unknown"
        else
          config.system.configurationRevision;
      version = if meta.package == null then "" else (meta.package.version or "unknown");
      pname = if meta.package == null then "" else (meta.package.pname or meta.package.name or "unknown");
    in
    ''
      set=${set}
      configurationRevision=${rev}
      nixosLabel=${config.system.nixos.label}
      package=${pname}
      version=${version}
      postgresVersion=${config.services.postgresql.package.version}
    '';

  # +-----------------------------------------------------------------+
  # | Prepare / cleanup                                                |
  # +-----------------------------------------------------------------+

  # This runs as the restic unit's ExecStartPre, which puts the database dump
  # *before* the file scan in ExecStart. That ordering is load-bearing and is
  # the reverse of what looks safe, so do not "fix" it.
  #
  # Every application here writes the blob before committing the row that
  # references it -- it must, or the row would be visible while its data was
  # not. A backup therefore has to capture them the other way round: dump the
  # database, then scan the files. A blob written mid-run is then an orphan
  # nothing points at, which is harmless. Scanning files first and dumping
  # afterwards produces the opposite and much worse artefact -- a row committed
  # after the scan passed, referencing a file that was never captured.
  #
  # Stated so it can be checked: if B references A and the application writes A
  # then B, capturing B at t_B and A at t_A is safe only when t_B <= t_A. B is
  # the database.
  #
  # The case this does NOT cover is deletion, which is the mirror image: a row
  # deleted after the dump leaves the dump referencing a file the scan no longer
  # finds. The two orders are symmetric and this is a bet that creations
  # outnumber deletions, which they do by a wide margin at 02:00. The way to
  # remove the window rather than trade it is stopUnits, which is what
  # opencloud does.
  #
  # Everything runs as root (the restic units' default user), which is required
  # rather than convenient: /var/lib/private is 0700 root:root, so the three
  # DynamicUser services' state is unreadable to anyone else.
  #
  # Databases are dumped by `runuser -u postgres`, never by the owning role.
  # Three of the five roles belong to DynamicUser units and do not exist as
  # system users while the unit is stopped, so peer auth as the owner is simply
  # not available at backup or restore time. runuser rather than sudo because
  # this is a system unit with no tty and no PAM session to negotiate.
  #
  # -Fc -Z0: custom format so pg_restore can take -j and select individual
  # objects, and *uncompressed* so restic's content-defined chunking can see
  # through it. A gzipped dump changes wholesale on every run and deduplicates
  # to nothing, which is the difference between a nightly delta of megabytes
  # and one of gigabytes.
  prepareScript =
    set: meta:
    pkgs.writeShellApplication {
      name = "backup-prepare-${set}";
      runtimeInputs = with pkgs; [
        coreutils
        util-linux
        sqlite
        systemd
        config.services.postgresql.package
      ];
      text = ''
        staging=${lib.escapeShellArg (staging set)}

        # df's own header is the reason for tail -1; --output=avail keeps this
        # from depending on column positions that differ between filesystems.
        avail=$(df --output=avail -k ${lib.escapeShellArg PATHS.BACKUP_ROOT} | tail -1)
        if [ "$avail" -lt ${toString minFreeKiB} ]; then
          echo "refusing to start: only $(( avail / 1024 )) MiB free on ${PATHS.BACKUP_ROOT}," \
               "want at least ${toString (minFreeKiB / 1024)} MiB"
          exit 1
        fi

        rm -rf "$staging"
        mkdir -p "$staging"
        chmod 0700 "$staging"

        cat > "$staging/manifest" <<'MANIFEST'
        ${manifestFor set meta}
        MANIFEST

        ${lib.optionalString meta.stopUnits ''
          # Stopped because this service's on-disk state cannot be copied
          # consistently while it runs and it offers no pg_dump equivalent.
          # The matching start lives in the cleanup script, which systemd runs
          # in postStop -- so it happens even when the backup fails.
          echo "stopping ${toString (builtins.length meta.units)} unit(s) for a consistent copy"
          systemctl stop ${lib.escapeShellArgs meta.units}
        ''}

        ${lib.optionalString meta.globals ''
          # Roles, grants and tablespaces. Not carried by any per-database dump,
          # and without them pg_restore recreates objects owned by roles that
          # do not exist.
          #
          # Deliberately without --clean. The DROP ROLE statements it adds fail
          # against any role that still owns an object, which on a restore into
          # a live cluster is every one of them -- so --clean would turn the
          # useful case into a wall of errors. Without it the file is additive:
          # it creates what is missing on a fresh cluster and no-ops on an
          # existing one.
          runuser -u postgres -- pg_dumpall --globals-only > "$staging/globals.sql"
        ''}

        ${lib.optionalString (meta.databases != [ ]) ''
          mkdir -p "$staging/db"
        ''}
        ${lib.concatMapStringsSep "\n" (db: ''
          echo "dumping database ${db}"
          runuser -u postgres -- pg_dump -Fc -Z0 ${lib.escapeShellArg db} > "$staging/db/${db}.dump"
        '') meta.databases}

        ${lib.optionalString (meta.sqlite != [ ]) ''
          mkdir -p "$staging/sqlite"
        ''}
        ${lib.concatMapStringsSep "\n" (db: ''
          # .backup rather than cp: with WAL enabled the committed state is
          # split between the .db and its -wal sibling, so copying the file
          # alone is a torn read of a live database.
          echo "snapshotting sqlite ${db}"
          sqlite3 ${lib.escapeShellArg db} ".backup '$staging/sqlite/${baseNameOf db}'"
        '') meta.sqlite}
      '';
    };

  cleanupScript =
    set: meta:
    pkgs.writeShellApplication {
      name = "backup-cleanup-${set}";
      runtimeInputs = with pkgs; [
        coreutils
        systemd
      ];
      text = ''
        ${lib.optionalString meta.stopUnits ''
          # systemd runs this in postStop, so it fires on failure and on
          # success alike. That is the whole reason stopUnits is safe: there is
          # no path through this unit that leaves the service down.
          systemctl start ${lib.escapeShellArgs meta.units}
        ''}

        # The dumps have been archived; keeping them costs SSD space for no
        # benefit, since restic deduplicates by content and re-reading a fresh
        # dump tomorrow is free.
        rm -rf ${lib.escapeShellArg (staging set)}
      '';
    };

  # The restic module runs these through pkgs.writeScript and execs the result,
  # which does not add a shebang of its own -- so the string has to carry one or
  # the unit fails with ENOEXEC. The real logic stays in a writeShellApplication
  # so it gets set -euo pipefail and a proper runtimeInputs closure.
  hookFor = script: "#!${pkgs.runtimeShell}\nexec ${lib.getExe script}\n";

  # +-----------------------------------------------------------------+
  # | Retention                                                       |
  # +-----------------------------------------------------------------+

  forgetArgs = meta: [
    "--keep-last 3"
    "--keep-daily 14"
    "--keep-weekly 8"
    "--keep-monthly 12"
    "--keep-yearly ${toString meta.keepYearly}"
    # Without this, forget groups by host+paths, so changing a set's `paths`
    # silently orphans every snapshot taken under the old list -- they stop
    # matching any group and are kept forever. Grouping by tags follows the set
    # rather than its current contents.
    "--group-by tags"
  ];

  # +-----------------------------------------------------------------+
  # | Operator entry points                                           |
  # +-----------------------------------------------------------------+

  resticWrapper =
    name: repo: extraEnv:
    pkgs.writeShellApplication {
      name = "o700-restic-${name}";
      runtimeInputs = [ pkgs.restic ];
      text = ''
        export RESTIC_REPOSITORY=${lib.escapeShellArg repo}
        export RESTIC_PASSWORD_FILE=${lib.escapeShellArg passwordFile}
        export RESTIC_CACHE_DIR=/var/cache/o700-restic
        ${extraEnv}
        exec restic "$@"
      '';
    };

  # +-----------------------------------------------------------------+
  # | The three orchestration scripts                                 |
  # +-----------------------------------------------------------------+

  orchestratorScript = pkgs.writeShellApplication {
    name = "o700-backup";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = ''
      # Failures are counted, not fatal. Aborting on the first one would let a
      # single broken service skip the other ${toString (builtins.length backupOrder - 1)},
      # which is the opposite of what a backup should do under partial failure.
      # Same idiom as host-audit (monitoring/checks.nix): non-zero exit is the
      # delivery mechanism, and OnFailure routes the journal tail to Telegram.
      problems=0

      run() {
        echo "== $1"
        if systemctl start --wait "$1"; then
          return 0
        fi
        echo "FAILED: $1"
        problems=$(( problems + 1 ))
        return 0
      }

      ${lib.concatMapStringsSep "\n" (set: ''run "restic-backups-${set}.service"'') backupOrder}

      ${lib.optionalString offsiteEnabled ''run "o700-backup-offsite.service"''}

      if [ "$problems" -gt 0 ]; then
        echo "$problems backup job(s) failed"
      fi
      exit "$problems"
    '';
  };

  offsiteScript = pkgs.writeShellApplication {
    name = "o700-backup-offsite";
    runtimeInputs = with pkgs; [
      coreutils
      restic
    ];
    text = ''
      set -a
      # shellcheck disable=SC1091
      source ${lib.escapeShellArg b2EnvFile}
      set +a

      export RESTIC_REPOSITORY=${lib.escapeShellArg offsiteRepo}
      export RESTIC_PASSWORD_FILE=${lib.escapeShellArg passwordFile}
      export RESTIC_FROM_REPOSITORY=${lib.escapeShellArg localRepo}
      export RESTIC_FROM_PASSWORD_FILE=${lib.escapeShellArg passwordFile}
      export RESTIC_CACHE_DIR=/var/cache/o700-restic

      # --copy-chunker-params is not optional and cannot be added later. Without
      # it the two repositories chunk differently, so every `copy` re-uploads
      # data the destination already holds -- forever, and invisibly, because it
      # still succeeds. The only fix after the fact is to discard the offsite
      # repository and start it again.
      if ! restic cat config > /dev/null 2>&1; then
        echo "offsite repository does not exist yet; initialising from the local one"
        restic init --from-repo "$RESTIC_FROM_REPOSITORY" --copy-chunker-params
      fi

      restic copy
    '';
  };

  pruneScript = pkgs.writeShellApplication {
    name = "o700-backup-prune";
    runtimeInputs = with pkgs; [
      coreutils
      restic
    ];
    text = ''
      problems=0

      # Failures are counted rather than left to set -e. Bash suppresses set -e
      # for the entire body of a function invoked in a `f || x` context, which
      # is how this one is called -- so a failing `restic forget` here would
      # otherwise be stepped over in silence and the function would still
      # report whatever `restic check` returned.
      prune_repo() {
        local label=$1 bad=0
        echo "== $label"

      ${lib.concatMapStringsSep "\n" (
        set:
        "  restic forget --tag ${set} ${
            lib.concatStringsSep " " (forgetArgs sets.${set})
          } || bad=$(( bad + 1 ))"
      ) setNames}

        # unlock first: a run killed mid-flight leaves a stale lock that would
        # otherwise block every subsequent prune until somebody notices.
        restic unlock       || bad=$(( bad + 1 ))
        restic prune        || bad=$(( bad + 1 ))

        # A subset rather than the whole repository. Reading every pack every
        # week is hours of spindle I/O for a guarantee that a rotating 5% gives
        # in twenty weeks at a twentieth of the cost.
        restic check --read-data-subset=5% || bad=$(( bad + 1 ))

        if [ "$bad" -gt 0 ]; then
          echo "$label: $bad retention step(s) failed"
        fi
        return "$bad"
      }

      export RESTIC_PASSWORD_FILE=${lib.escapeShellArg passwordFile}
      export RESTIC_CACHE_DIR=/var/cache/o700-restic

      export RESTIC_REPOSITORY=${lib.escapeShellArg localRepo}
      prune_repo local || problems=$(( problems + 1 ))

      ${lib.optionalString offsiteEnabled ''
        set -a
        # shellcheck disable=SC1091
        source ${lib.escapeShellArg b2EnvFile}
        set +a
        export RESTIC_REPOSITORY=${lib.escapeShellArg offsiteRepo}
        prune_repo offsite || problems=$(( problems + 1 ))
      ''}

      exit "$problems"
    '';
  };

  localWrapper = resticWrapper "local" localRepo "";

  offsiteWrapper = resticWrapper "offsite" offsiteRepo ''
    set -a
    # shellcheck disable=SC1091
    source ${lib.escapeShellArg b2EnvFile}
    set +a
  '';

  # +-----------------------------------------------------------------+
  # | o700-restore                                                    |
  # +-----------------------------------------------------------------+

  # Generated from the same manifest as the backup jobs, so the two cannot
  # drift: a set added above is restorable without touching this.
  setMetaCase = lib.concatMapStringsSep "\n" (
    set:
    let
      meta = sets.${set};
    in
    ''
      ${set})
        units=(${lib.concatStringsSep " " (map lib.escapeShellArg meta.units)})
        paths=(${lib.concatStringsSep " " (map lib.escapeShellArg meta.paths)})
        sqlites=(${lib.concatStringsSep " " (map lib.escapeShellArg meta.sqlite)})
        databases=(${lib.concatStringsSep " " (map lib.escapeShellArg meta.databases)})
        globals=${if meta.globals then "1" else "0"}
        curver=${lib.escapeShellArg (if meta.package == null then "" else (meta.package.version or ""))}
        stagingdir=${lib.escapeShellArg (staging set)}
        ;;
    ''
  ) setNames;

  restoreScript = pkgs.writeShellApplication {
    name = "o700-restore";
    runtimeInputs =
      with pkgs;
      [
        coreutils
        util-linux
        jq
        sqlite
        systemd
        config.services.postgresql.package
        localWrapper
      ]
      ++ lib.optional offsiteEnabled offsiteWrapper;

    text = ''
      SETS=(${lib.concatStringsSep " " setNames})
      CURRENT_REV=${
        lib.escapeShellArg (
          if config.system.configurationRevision == null then
            "unknown"
          else
            config.system.configurationRevision
        )
      }
      CURRENT_PG=${lib.escapeShellArg config.services.postgresql.package.version}
      OFFSITE=${if offsiteEnabled then "1" else "0"}

      repo=local
      dryrun=0
      assumeyes=0
      allowskew=0

      usage() {
        cat <<'USAGE'
      o700-restore -- put one service's state back from a restic snapshot.

        o700-restore list
            Every backup set, its newest snapshot and how old that is.

        o700-restore snapshots <set>
            Snapshot ids, times and the app version each was taken under.

        o700-restore restore <set> <snapshot|latest> [options]
            Stop the set's units, put its data back, start them again.

            --repo local|offsite   Which repository to read (default: local).
            --dry-run              Show what would change; touch nothing.
            --yes                  Skip the confirmation prompt.
            --allow-version-skew   Proceed despite a version mismatch that
                                   would otherwise be refused. Read what it
                                   printed before reaching for this.

        o700-restore verify
            restic check on every configured repository.

      USAGE
        printf 'Sets: %s\n' "''${SETS[*]}"
      }

      restic_cmd() {
        if [ "$repo" = offsite ]; then
          o700-restic-offsite "$@"
        else
          o700-restic-local "$@"
        fi
      }

      # Populates the globals every routine below reads. Kept as one function so
      # that adding a set is a change in exactly one generated block.
      set_meta() {
        units=(); paths=(); sqlites=(); databases=(); globals=0; curver=""; stagingdir=""
        case "$1" in
      ${setMetaCase}
          *)
            echo "unknown backup set: $1" >&2
            printf 'known sets: %s\n' "''${SETS[*]}" >&2
            return 1
            ;;
        esac
      }

      # Refuses the two directions that corrupt, and explains the way out.
      #
      # An older snapshot under the same major is fine and common: Gitea,
      # Paperless, Mealie, n8n, Vaultwarden and Kavita all run their migration
      # framework on start, so loading older data under the current binary is
      # the ordinary upgrade path. The reverse is not -- Gitea refuses to boot
      # against a newer schema, and the Django/alembic apps partially apply.
      check_version() {
        local snapver=$1 snaprev=$2 snappg=$3 set=$4
        local reason=""

        if [ -n "$curver" ] && [ -n "$snapver" ] && [ "$snapver" != "$curver" ]; then
          local snapmaj=''${snapver%%.*} curmaj=''${curver%%.*} newest
          newest=$(printf '%s\n%s\n' "$snapver" "$curver" | sort -V | tail -1)

          if [ "$snapmaj" != "$curmaj" ]; then
            reason="major version differs: snapshot $snapver, installed $curver"
          elif [ "$newest" = "$snapver" ]; then
            reason="the snapshot is NEWER than what is installed: $snapver > $curver"
          else
            echo "note: snapshot was taken under $set $snapver; this system runs $curver."
            echo "      the application will migrate forward on start."
          fi
        fi

        if [ -n "$snappg" ] && [ "''${snappg%%.*}" != "''${CURRENT_PG%%.*}" ]; then
          reason="PostgreSQL major differs: snapshot ''${snappg%%.*}, server ''${CURRENT_PG%%.*}."
          reason="$reason A dump cannot cross a major downgrade; the fix is pg_upgrade, not a restore"
        fi

        [ -n "$reason" ] || return 0

        echo
        echo "REFUSING: $reason"
        echo
        echo "  snapshot config revision: $snaprev"
        echo "  this system:              $CURRENT_REV"
        echo
        echo "On NixOS the data and the system that wrote it are restored together."
        echo "To go back to the system this snapshot was taken under:"
        echo
        echo "  git -C ~/.config/nixos checkout $snaprev && just switch-o700"
        echo "  o700-restore restore $set <snapshot> --yes"
        echo
        echo "Odoo and OpenCloud have no automatic path across a major in either"
        echo "direction; for those this is the only correct order."
        echo
        echo "Pass --allow-version-skew to proceed anyway."

        if [ "$allowskew" = 1 ]; then
          echo "--allow-version-skew given; continuing."
          return 0
        fi
        return 1
      }

      cmd_list() {
        printf '%-16s %-12s %-22s %s\n' SET SNAPSHOT TAKEN AGE
        local set line id when age
        for set in "''${SETS[@]}"; do
          line=$(restic_cmd snapshots --tag "$set" --latest 1 --json 2>/dev/null \
                 | jq -r '.[0] | "\(.short_id) \(.time)"' 2>/dev/null) || line=""
          if [ -z "$line" ] || [ "$line" = "null null" ]; then
            printf '%-16s %-12s %-22s %s\n' "$set" "-" "-" "NO SNAPSHOT"
            continue
          fi
          id=''${line%% *}
          when=''${line#* }
          age=$(( ( $(date +%s) - $(date -d "$when" +%s) ) / 3600 ))
          printf '%-16s %-12s %-22s %sh\n' "$set" "$id" "''${when%%.*}" "$age"
        done
      }

      cmd_snapshots() {
        local set=$1
        set_meta "$set"
        restic_cmd snapshots --tag "$set"
      }

      cmd_verify() {
        echo "== local"
        o700-restic-local check
        if [ "$OFFSITE" = 1 ]; then
          echo "== offsite"
          o700-restic-offsite check
        fi
      }

      cmd_restore() {
        local set=$1 snap=$2
        set_meta "$set"

        if [ "$snap" = latest ]; then
          snap=$(restic_cmd snapshots --tag "$set" --latest 1 --json | jq -r '.[0].short_id // empty')
          if [ -z "$snap" ]; then
            echo "no snapshot tagged '$set' in the $repo repository" >&2
            exit 1
          fi
        fi

        # The staging payload comes out first, before anything is stopped or
        # overwritten, because the version guard reads its manifest. A restore
        # that is going to be refused must be refused while the service is
        # still running.
        local scratch payload
        scratch=$(mktemp -d /var/tmp/o700-restore.XXXXXXXX)
        # shellcheck disable=SC2064
        trap "rm -rf '$scratch'" EXIT

        echo "reading snapshot $snap from the $repo repository..."
        restic_cmd restore "$snap" --target "$scratch" --include "$stagingdir" > /dev/null
        payload="$scratch$stagingdir"

        # pg_restore and psql run as `postgres` via runuser, and neither can
        # reach this payload as extracted. Two separate barriers: mktemp -d
        # creates the scratch root 0700, and restic recreates the staging
        # directories inside it carrying the 0700 root mode recorded in the
        # snapshot (the tmpfiles rule below). Either one alone is enough to
        # produce "could not open input file: Permission denied" on a file that
        # is plainly there.
        #
        # chown rather than chmod because the payload holds plaintext dumps --
        # Vaultwarden's database among them -- and /var/tmp is world-traversable.
        # Handing the tree to the one account that has to read it keeps it away
        # from every other account; root is unaffected by ownership, so the
        # manifest and sqlite steps below still work unchanged.
        #
        # The dry-run path skips the database block entirely, so this is not
        # something --dry-run can ever surface. It was found by a real restore.
        chown -R postgres:postgres "$scratch"

        local snapver="" snaprev="unknown" snappg="" snaptime
        if [ -f "$payload/manifest" ]; then
          snapver=$(sed -n 's/^version=//p'                "$payload/manifest")
          snaprev=$(sed -n 's/^configurationRevision=//p'  "$payload/manifest")
          snappg=$(sed -n 's/^postgresVersion=//p'         "$payload/manifest")
        else
          echo "warning: snapshot carries no manifest; version cannot be checked."
        fi
        snaptime=$(restic_cmd snapshots "$snap" --json | jq -r '.[0].time')

        echo
        echo "set:       $set"
        echo "snapshot:  $snap  (''${snaptime%%.*})"
        echo "recorded:  ''${snapver:-unknown}  rev ''${snaprev:-unknown}"
        echo "installed: ''${curver:-n/a}  rev $CURRENT_REV"
        echo

        check_version "$snapver" "$snaprev" "$snappg" "$set" || exit 1

        if [ "$dryrun" = 0 ] && [ "$assumeyes" = 0 ]; then
          echo "This stops ''${#units[@]} unit(s), replaces ''${#paths[@]} path(s) and reloads"
          echo "''${#databases[@]} database(s). Files created since the snapshot are removed."
          printf 'Type the set name to continue: '
          local answer; read -r answer
          [ "$answer" = "$set" ] || { echo "aborted."; exit 1; }
        fi

        # Ownership is read off the live filesystem *before* anything moves,
        # and re-applied at the end.
        #
        # The reason is bare-metal recovery, not DynamicUser. System uids are
        # allocated in whatever order the modules happen to be evaluated, so a
        # rebuilt host can give `gitea` or `paperless` a different uid than the
        # one recorded in the snapshot. restic restores the *recorded* uid
        # faithfully, which on a rebuilt host means a service that cannot read
        # its own state directory. Reading the current owner first and chowning
        # back to it is what makes a restore survive that.
        #
        # It is a no-op for the three DynamicUser services, and the reason is
        # worth knowing because it is not the obvious one: with id-mapped
        # mounts -- which this kernel supports -- systemd leaves
        # /var/lib/private/<svc> owned by `nobody` (65534) in the *host*
        # namespace permanently, and maps it to the dynamic uid only inside the
        # service's own namespace (systemd.exec(5), DynamicUser=). So the uid
        # restic sees is 65534 every night regardless of what systemd allocated
        # this boot, it is stable across reboots, and the snapshot is never
        # stale. Nothing here has to compensate for a rotating uid, because
        # from the host's point of view there isn't one.
        local -a owners=()
        local pth
        for pth in "''${paths[@]}"; do
          owners+=("$(stat -c '%u:%g' "$pth" 2>/dev/null || echo "")")
        done

        if [ "$dryrun" = 0 ] && [ "''${#units[@]}" -gt 0 ]; then
          echo "stopping: ''${units[*]}"
          systemctl stop "''${units[@]}"
        fi

        local -a restoreflags=(--target / --delete)
        # --verbose=2, not --verbose. At level 1 restic prints only the summary
        # line -- "deleted 3 files/dirs" -- which is a count with no names, and
        # naming them is the entire reason to run this before a real restore.
        # restic's own help for --delete says so: "Use '--dry-run -vv' to check
        # what would be deleted".
        [ "$dryrun" = 1 ] && restoreflags+=(--dry-run --verbose=2)

        for pth in "''${paths[@]}"; do
          echo "restoring $pth"
          restic_cmd restore "$snap" "''${restoreflags[@]}" --include "$pth"
        done

        local db
        for db in "''${databases[@]}"; do
          if [ "$dryrun" = 1 ]; then
            echo "would drop and reload database $db from $payload/db/$db.dump"
            continue
          fi
          echo "reloading database $db"
          runuser -u postgres -- psql -qtAX -c \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid()" \
            > /dev/null
          runuser -u postgres -- dropdb --if-exists "$db"
          runuser -u postgres -- createdb -O "$db" "$db"
          runuser -u postgres -- pg_restore -j2 -d "$db" "$payload/db/$db.dump"
        done

        if [ "$globals" = 1 ]; then
          if [ "$dryrun" = 1 ]; then
            echo "would reapply cluster roles and grants from $payload/globals.sql"
          else
            echo "reapplying cluster roles and grants"
            # Not ON_ERROR_STOP: this file is additive and every role that
            # already exists reports an error that is the expected outcome.
            runuser -u postgres -- psql -q -f "$payload/globals.sql" > /dev/null 2>&1 || true
          fi
        fi

        local sq base
        for sq in "''${sqlites[@]}"; do
          base=$(basename "$sq")
          if [ "$dryrun" = 1 ]; then
            echo "would install $payload/sqlite/$base over $sq"
            continue
          fi
          echo "installing sqlite $sq"
          cp --no-preserve=ownership "$payload/sqlite/$base" "$sq"
          # Stale sidecars describe the database that was just replaced. Left
          # behind, SQLite replays them over the restored file.
          rm -f "$sq-wal" "$sq-shm"
        done

        if [ "$dryrun" = 0 ]; then
          local i=0
          for pth in "''${paths[@]}"; do
            if [ -n "''${owners[$i]}" ]; then
              chown -R "''${owners[$i]}" "$pth"
            fi
            i=$(( i + 1 ))
          done
        fi

        if [ "$dryrun" = 0 ] && [ "''${#units[@]}" -gt 0 ]; then
          echo "starting: ''${units[*]}"
          systemctl start "''${units[@]}"
        fi

        echo
        if [ "$dryrun" = 1 ]; then
          echo "dry run complete; nothing was changed."
        else
          echo "restored $set from snapshot $snap (''${snaptime%%.*}, $set ''${snapver:-unknown})."
        fi
      }

      cmd=''${1:-}
      # Written as an `if` rather than `[ $# -gt 0 ] && shift`. Not because the
      # AND-list would trip set -e -- it would not, and an earlier version of
      # this comment claimed otherwise. Bash exempts a failing command in a &&
      # list unless it is the one following the final &&, so the test may fail
      # freely here.
      #
      # The reason is that the exemption stops applying when such a list is the
      # LAST command in a function or script: there its non-zero status becomes
      # the return value, which under set -e aborts the caller or silently
      # turns a successful run into a non-zero exit. The `if` form has no such
      # edge, so it is the shape used throughout this script.
      if [ $# -gt 0 ]; then shift; fi
      case "$cmd" in
        list|snapshots|restore|verify) ;;
        -h|--help|"") usage; exit 0 ;;
        *) echo "unknown command: $cmd" >&2; usage >&2; exit 1 ;;
      esac

      positional=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --repo)               repo=$2; shift 2 ;;
          --repo=*)             repo=''${1#*=}; shift ;;
          --dry-run)            dryrun=1; shift ;;
          --yes|-y)             assumeyes=1; shift ;;
          --allow-version-skew) allowskew=1; shift ;;
          -h|--help)            usage; exit 0 ;;
          -*)                   echo "unknown option: $1" >&2; exit 1 ;;
          *)                    positional+=("$1"); shift ;;
        esac
      done

      case "$repo" in
        local) ;;
        offsite)
          if [ "$OFFSITE" != 1 ]; then
            echo "no offsite repository is configured (BACKUP.b2Bucket is empty)" >&2
            exit 1
          fi
          ;;
        *) echo "--repo must be 'local' or 'offsite'" >&2; exit 1 ;;
      esac

      case "$cmd" in
        list)   cmd_list ;;
        verify) cmd_verify ;;
        snapshots)
          [ "''${#positional[@]}" -ge 1 ] || { echo "usage: o700-restore snapshots <set>" >&2; exit 1; }
          cmd_snapshots "''${positional[0]}"
          ;;
        restore)
          [ "''${#positional[@]}" -ge 2 ] || {
            echo "usage: o700-restore restore <set> <snapshot|latest>" >&2; exit 1; }
          cmd_restore "''${positional[0]}" "''${positional[1]}"
          ;;
      esac
    '';
  };
in
{
  # A path that is never named is a backup set that silently archives nothing.
  # Both of these are eval-time because the failure is otherwise invisible: the
  # unit succeeds, the snapshot exists, and it is empty.
  assertions = [
    {
      assertion = config.seta ? kavita -> (config.seta.kavita.backup.enable -> PATHS.BOOKS != "");
      message = ''
        PATHS.BOOKS is empty in STATIC_GLOBAL_VARS.nix, so the kavita-library backup set has
        no paths and would archive nothing at all. Kavita's library directories are configured
        in-app and live only inside its SQLite database, so nothing in this repo can discover
        them -- set PATHS.BOOKS to the real directory.
      '';
    }
  ]
  ++ lib.mapAttrsToList (set: meta: {
    assertion = meta.package != null;
    message = ''
      seta.${set}.backup.enable is set, but config.services.${set}.package does not resolve.
      systems/o700/backup.nix looks the package up by service name to stamp a version into every
      snapshot, and that version is what stops a restore from loading old data under a newer
      binary. Without it the version guard in o700-restore silently has nothing to compare.
    '';
  }) setaBackupSets;

  # +-----------------------------------------------------------------+
  # | One restic job per backup set                                    |
  # +-----------------------------------------------------------------+
  services.restic.backups = lib.mapAttrs (set: meta: {
    repository = localRepo;
    inherit passwordFile;
    initialize = true;

    paths = [ (staging set) ] ++ meta.paths;
    # Excludes are the operator's list plus the live SQLite files, derived
    # rather than restated. Anything captured by `sqlite` has already been
    # snapshotted into staging through the SQLite API; archiving the live file
    # as well stores a second, torn copy of the same database and re-uploads
    # most of it every night, since a WAL-mode database rewrites pages
    # scattered throughout the file.
    #
    # This used to be a sentence in the `sqlite` option telling whoever added a
    # service to also write the exclude by hand. Forgetting it cost repository
    # churn silently -- the backup still succeeded and the restore was still
    # correct, because o700-restore installs the staged copy after the file
    # restore, so nothing ever pointed at the mistake.
    #
    # The three sidecars are named explicitly rather than globbed with
    # "${db}*": -wal and -shm exist in WAL mode, -journal in rollback mode, and
    # a glob would also swallow anything else that happens to share the prefix.
    exclude =
      meta.exclude
      ++ lib.concatMap (db: [
        db
        "${db}-wal"
        "${db}-shm"
        "${db}-journal"
      ]) meta.sqlite;

    # No timer. Every entry is started by o700-backup.service instead, in a
    # fixed order, one at a time -- see the orchestrator below for why serial
    # is not an optimisation to revisit.
    timerConfig = null;

    extraBackupArgs = [
      "--tag"
      set
      "--tag"
      "o700"
      "--exclude-caches"
    ];

    # forget and prune are centralised in o700-backup-prune.service. Running
    # them per entry would repack the repository nine times a night, and prune
    # is the one restic operation that rewrites pack files.
    pruneOpts = [ ];
    runCheck = false;

    # Ten `restic-<set>` binaries on $PATH is noise. o700-restic-local and
    # o700-restic-offsite cover the same ground with two names.
    createWrapper = false;

    backupPrepareCommand = hookFor (prepareScript set meta);
    backupCleanupCommand = hookFor (cleanupScript set meta);
  }) sets;

  # +-----------------------------------------------------------------+
  # | The nightly run                                                 |
  # +-----------------------------------------------------------------+

  # One timer for the whole estate, not one per set.
  #
  # Serial execution is the requirement, not an implementation detail. Every
  # source path except the media library sits on the 7200 RPM root spindle, and
  # this host has already been taken down once by I/O contention on that disk
  # (see the swapDevices note in hardware-configuration.nix). Nine restic jobs
  # firing on overlapping timers is exactly the shape of that incident. It also
  # buys one failure notification, one journal story to read, and one command
  # to run the whole thing by hand.
  systemd.services.o700-backup = {
    description = "Nightly backup of every service on this host";

    # Reports by failing. The orchestrator counts failed sets rather than
    # aborting on the first, then exits with that count -- so the notifier's
    # journal excerpt is the message "three services did not get backed up
    # tonight, here is which", and netdata's unit-state alarm could only say
    # that o700-backup failed.
    #
    # The per-set restic-backups-* units deliberately do NOT carry this. They
    # are started by this orchestrator and their failures are already counted
    # and named here; wiring them too would send two messages for one incident,
    # and this is the one that says which set. They are excluded from netdata's
    # template for the same reason -- see the chart labels matcher in
    # monitoring/netdata.nix.
    onFailure = [ "telegram-notify@%n.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe orchestratorScript;

      # Politeness, not a guarantee: Nice only affects CPU, and
      # IOSchedulingClass is honoured by BFQ but ignored by mq-deadline. The
      # 02:00 schedule is what actually keeps this away from the working day.
      Nice = 19;
      IOSchedulingClass = "idle";

      # Individual restic jobs can take a long time on their first run; the
      # default 90s would kill the orchestrator mid-estate.
      TimeoutStartSec = "12h";
    };
  };

  systemd.timers.o700-backup = {
    description = "Run the nightly backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "02:00";
      # Catch up after downtime rather than skipping a night in silence.
      Persistent = true;
      RandomizedDelaySec = "20m";
      AccuracySec = "1m";
    };
  };

  # Mirrors new snapshots to B2. Separate from the orchestrator so a failed
  # upload is attributable on its own -- "the backup failed" and "the offsite
  # copy failed" are different incidents with different urgencies, and only the
  # second one is survivable overnight.
  systemd.services.o700-backup-offsite = lib.mkIf offsiteEnabled {
    description = "Copy new snapshots to the offsite repository";

    # Inside the same mkIf that creates the unit, which is the point of wiring
    # this here instead of in a list elsewhere. monitoring/notify.nix used to
    # name this unit unconditionally while backup.nix generated it only when a
    # bucket was configured -- so with no bucket, systemd synthesised an empty
    # unit carrying nothing but an OnFailure. The condition is now stated once.
    onFailure = [ "telegram-notify@%n.service" ];

    # The upload keeps the standard proxy variables, so it egresses through
    # tinyproxy like everything else on this host. CONNECT to 443 is permitted
    # and the filter is a blocklist, so nothing has to be opened for it; the
    # gain is that a multi-gigabyte transfer to a third party is visible in the
    # same log as every other outbound request. Do not add a no_proxy exemption
    # here without a measured reason.
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe offsiteScript;
      Nice = 19;
      IOSchedulingClass = "idle";
      TimeoutStartSec = "12h";
      CacheDirectory = "o700-restic";
    };
  };

  # forget, prune and check, once a week for the whole repository rather than
  # after every set. prune is the one restic operation that rewrites pack
  # files, so running it nine times a night would repack the repository nine
  # times for no benefit.
  systemd.services.o700-backup-prune = {
    description = "Apply retention and verify the backup repositories";

    # `restic check` is the half that matters here: it reports repository
    # corruption, and the finding is the list of damaged packs on stdout rather
    # than the bare fact that the unit exited non-zero.
    onFailure = [ "telegram-notify@%n.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe pruneScript;
      Nice = 19;
      IOSchedulingClass = "idle";
      TimeoutStartSec = "12h";
      CacheDirectory = "o700-restic";
    };
  };

  systemd.timers.o700-backup-prune = {
    description = "Weekly backup retention and verification";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Sunday, well after the nightly run has finished.
      OnCalendar = "Sun 06:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
      AccuracySec = "1m";
    };
  };

  systemd.tmpfiles.rules = [
    # 0755 and NOT 0700, which is the tempting value and is wrong.
    #
    # This directory is a parent, not a container of secrets. The vaultwarden
    # module puts its own nightly dump at ${PATHS.BACKUP_ROOT}/warden owned by
    # vaultwarden:vaultwarden, and backup-vaultwarden.service runs as that user
    # -- so it needs the traverse bit here to reach its own directory at all.
    # At 0700 root:root that unit fails with EACCES, which would break the only
    # backup this host had before any of this existed.
    #
    # Nothing is exposed by that. What is sensitive lives one level down and is
    # 0700 in its own right, and the names of three subdirectories are not a
    # secret worth breaking a service for.
    "d ${PATHS.BACKUP_ROOT}     0755 root root - -"

    # These two are the ones that matter. The repository holds every secret on
    # this host in restic's encrypted form, and the staging directory holds
    # plaintext database dumps for the minutes between the dump and the
    # archive. Neither has any reason to be readable by the media group that
    # owns the rest of the drive.
    "d ${PATHS.RESTIC_REPO}     0700 root root - -"
    "d ${PATHS.BACKUP_STAGING}  0700 root root - -"
  ];

  environment.systemPackages = [
    localWrapper
    restoreScript
  ]
  ++ lib.optional offsiteEnabled offsiteWrapper;
}
