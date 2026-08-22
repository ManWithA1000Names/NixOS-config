{
  pkgs,
  lib,
  PATHS,
  USERNAME,
  ...
}:
let
  stateDir = "/var/lib/host-audit";

  # Two days. The vaultwarden backup runs nightly, so this tolerates exactly one
  # missed run before complaining -- long enough that a single transient failure
  # is absorbed by the next night's success, short enough that a permanently
  # broken backup is caught before the window matters.
  backupMaxAgeSeconds = 172800;

  audit-script = pkgs.writeShellApplication {
    name = "host-audit";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      util-linux
    ];
    text = ''
      problems=0

      if mountpoint -q ${PATHS.EX-SSD}; then
        # find -printf %T@ gives seconds.microseconds; the decimal is stripped
        # below. The whole pipeline is guarded because writeShellApplication
        # sets `pipefail`, and head closing the pipe early makes find exit
        # non-zero -- which would abort the audit rather than report on it.
        newest=$(find ${PATHS.BACKUP_ROOT}/warden/ -type f -printf '%T@\n' 2>/dev/null \
                 | sort -rn | head -1) || newest=""

        if [ -z "$newest" ]; then
          echo "no vaultwarden backup found under ${PATHS.BACKUP_ROOT}/warden"
          problems=1
        else
          age=$(( $(date +%s) - ''${newest%.*} ))
          if [ "$age" -gt ${toString backupMaxAgeSeconds} ]; then
            echo "vaultwarden backup is $(( age / 3600 ))h old"
            problems=1
          fi
        fi
      else
        # Reported rather than fatal: the drive being absent is the very state
        # this is here to notice. Backup age is skipped because it is not
        # meaningful when the filesystem holding the backups is not there.
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
      keys="/etc/ssh/authorized_keys/${USERNAME}"
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

      # Runs as root: reads authorized_keys (root:root) and walks the whole
      # root filesystem looking for SUID bits.
      #
      # The predecessor of this unit ran the same filesystem walk every five
      # minutes, which on a 7200 RPM root disk holding /nix/store, the swapfile
      # and 16 GB of Jellyfin metadata was a meaningful share of the contention
      # that took this host down. Daily is 288x less of it.
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
