{
  config,
  pkgs,
  lib,
  PATHS,
  BACKUP,
  USERNAME,
  ...
}:
let
  stateDir = "/var/lib/host-audit";

  # Two days. The backup runs nightly, so this tolerates exactly one missed run
  # before complaining -- long enough that a single transient failure is
  # absorbed by the next night's success, short enough that a permanently
  # broken backup is caught before the window matters.
  backupMaxAgeSeconds = 172800;

  # Three days for the offsite copy. One night more than the local tier gets,
  # because the copy depends on the whole nightly run having finished and on a
  # third party being reachable -- so a single slow night is a worse reason to
  # send a message here than it is locally. It is still short enough that a
  # permanently broken upload is caught inside a week.
  offsiteMaxAgeSeconds = 259200;

  # The tags this expects to find, taken from the manifest that generates the
  # backup jobs rather than restated. A set added to systems/o700/backup.nix is
  # therefore watched from its first night, and -- the direction that actually
  # matters -- a set that stops producing snapshots is reported as missing
  # rather than quietly dropping out of the check along with its job.
  expectedSets = lib.sort (a: b: a < b) (builtins.attrNames config.services.restic.backups);

  offsiteRepo = "s3:${BACKUP.b2Endpoint}/${BACKUP.b2Bucket}";
  offsiteEnabled = BACKUP.b2Bucket != "";

  # One `restic snapshots` per repository, not one per tag. Against B2 each
  # call loads the repository index, so ten of them would be ten index loads a
  # day for information a single listing already contains.
  newestPerTag = ''
    restic snapshots --json 2>/dev/null \
      | jq -r '[.[] | . as $s | ($s.tags // [])[] | select(. != "o700") | {tag: ., t: $s.time}]
               | group_by(.tag)
               | map({tag: .[0].tag, newest: (map(.t) | max)})
               | .[] | "\(.tag) \(.newest)"'
  '';

  audit-script = pkgs.writeShellApplication {
    name = "host-audit";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      util-linux
      gnugrep
      jq
      restic
    ];
    text = ''
      problems=0

      # Checks one repository's snapshot ages against the expected set list.
      # Writes findings to stdout and returns the number of them, so the two
      # calls below accumulate into the same `problems` counter the rest of
      # this script uses.
      check_repo() {
        local label=$1 maxage=$2 found bad=0 newest age
        bad=0

        # writeShellApplication sets pipefail, and this pipeline is allowed to
        # produce nothing (an uninitialised repository, an unreachable bucket),
        # so the whole thing is guarded rather than aborting the audit.
        found=$(${newestPerTag}) || found=""

        if [ -z "$found" ]; then
          echo "$label: no snapshots at all -- the repository is empty or unreachable"
          return 1
        fi

        local set
        for set in ${lib.concatStringsSep " " expectedSets}; do
          newest=$(printf '%s\n' "$found" | { grep "^$set " || true; } | cut -d' ' -f2)
          if [ -z "$newest" ]; then
            echo "$label: no snapshot has ever been tagged '$set'"
            bad=$(( bad + 1 ))
            continue
          fi
          age=$(( $(date +%s) - $(date -d "$newest" +%s) ))
          if [ "$age" -gt "$maxage" ]; then
            echo "$label: '$set' snapshot is $(( age / 3600 ))h old"
            bad=$(( bad + 1 ))
          fi
        done

        return "$bad"
      }

      if mountpoint -q ${PATHS.EX-SSD}; then
        export RESTIC_PASSWORD_FILE=${config.age.secrets.restic-password.path}
        export RESTIC_CACHE_DIR=/var/cache/o700-restic

        export RESTIC_REPOSITORY=${PATHS.RESTIC_REPO}
        check_repo local ${toString backupMaxAgeSeconds} || problems=1

        ${lib.optionalString offsiteEnabled ''
          # Sourced rather than exported per-call: these are the B2 credentials
          # and they are only meaningful for the offsite listing.
          set -a
          # shellcheck disable=SC1091
          source ${config.age.secrets.restic-b2.path}
          set +a

          export RESTIC_REPOSITORY=${offsiteRepo}
          check_repo offsite ${toString offsiteMaxAgeSeconds} || problems=1
        ''}
      else
        # Reported rather than fatal: the drive being absent is the very state
        # this is here to notice. Snapshot ages are skipped because they are not
        # meaningful when the filesystem holding the repository is not there.
        echo "external SSD is not mounted at ${PATHS.EX-SSD}"
        problems=1
      fi

      # SUID binaries outside /nix/store (immutable) and /run/wrappers (NixOS's
      # sanctioned privilege escalation: sudo, ping, etc.). Anything else is
      # unexpected. -xdev keeps this on the root filesystem, so the media SSD is
      # never walked.
      suid=$(find / -xdev \
               \( -path '/nix/store/*' -o -path '/run/wrappers/*' \) \
               -prune -o -perm -4000 -print 2>/dev/null) || suid=""
      if [ -n "$suid" ]; then
        echo "unexpected SUID binaries outside the store:"
        echo "$suid"
        problems=1
      fi

      # A change here during a planned nixos-rebuild is expected -- the file is
      # regenerated from config. An unexplained one is not. Comparing against a
      # stored baseline rather than exporting a digest means the alert names the
      # event instead of requiring somebody to notice a number moved.
      # The `.d` is load-bearing: users.users.<n>.openssh.authorizedKeys.keys
      # materialises at /etc/ssh/authorized_keys.d/<user>, and sshd is pointed
      # there via AuthorizedKeysFile. This read /etc/ssh/authorized_keys/<user>
      # until 2026-08-23, which has never existed -- so the else branch below
      # ran every day, the baseline was never written, and this check had never
      # once compared anything. A wrong path here fails as a daily nuisance
      # message rather than as an obvious break, which is why it survived.
      keys="/etc/ssh/authorized_keys.d/${USERNAME}"
      if [ -f "$keys" ]; then
        digest=$(sha256sum "$keys" | cut -d' ' -f1)
        baseline="${stateDir}/authorized_keys.digest"
        if [ -f "$baseline" ] && [ "$digest" != "$(cat "$baseline")" ]; then
          echo "authorized_keys for ${USERNAME} changed since the last audit"
          problems=1
        fi
        # Written unconditionally, including on the run that reported the
        # change: a persistent difference would otherwise report every day
        # forever, and a daily repeat of a known change is noise that trains
        # you to ignore the channel.
        printf '%s\n' "$digest" > "$baseline"
      else
        echo "authorized_keys for ${USERNAME} is missing"
        problems=1
      fi

      # Non-zero is the delivery mechanism: systemd's OnFailure= on this unit
      # (see notify.nix) sends the last 20 journal lines to Telegram, which is
      # exactly the text echoed above. No separate curl, no second copy of the
      # bot token.
      exit "$problems"
    '';
  };
in
{
  systemd.services.host-audit = {
    description = "Daily host integrity and backup audit";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe audit-script;
      StateDirectory = "host-audit";

      # Shared with the backup units. restic re-downloads the repository index
      # on every invocation without it, which for the offsite check means
      # pulling it from B2 daily.
      CacheDirectory = "o700-restic";

      # Runs as root: reads authorized_keys (root:root) and walks the whole
      # root filesystem looking for SUID bits.
      #
      # The predecessor of this unit ran the same filesystem walk every five
      # minutes, which on a 7200 RPM root disk holding /nix/store and 16 GB of
      # Jellyfin metadata was a meaningful share of the contention that took
      # this host down. Daily is 288x less of it. (That disk also held a
      # swapfile at the time, since removed -- it turned out to be the larger
      # share by far.)
      #
      # Nice only affects CPU, and IOSchedulingClass is honoured by BFQ but
      # ignored by mq-deadline, which is the likely scheduler here -- so treat
      # these as best-effort politeness, not as a guarantee. The cadence is what
      # actually fixes the problem.
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.host-audit = {
    description = "Run the host audit daily";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      # Catch up after downtime rather than skipping the window silently.
      Persistent = true;
      # A laptop that is not always on at 00:00 plus a filesystem walk that
      # should not collide with the nightly Jellyfin and backup work.
      RandomizedDelaySec = "30m";
      AccuracySec = "1m";
    };
  };
}
