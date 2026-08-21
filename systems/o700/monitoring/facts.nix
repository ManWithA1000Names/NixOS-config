{
  pkgs,
  lib,
  PATHS,
  USERNAME,
  ...
}:
let
  textfile-dir = "/var/lib/node-exporter-textfile";

  facts-script = pkgs.writeShellApplication {
    name = "node-exporter-facts";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      util-linux
    ];
    text = ''
      TEXTFILE_DIR="${textfile-dir}"
      OUT="$TEXTFILE_DIR/facts.prom"
      TMP="''${OUT}.tmp"

      {
        # SSD mount presence. Used by the ExternalSSDUnmounted alert. This
        # check must NOT fail when the drive is absent -- that is the very
        # state it is reporting.
        if mountpoint -q ${PATHS.EX-SSD} 2>/dev/null; then
          printf 'o700_mount_present{mount="${PATHS.EX-SSD}"} 1\n'
        else
          printf 'o700_mount_present{mount="${PATHS.EX-SSD}"} 0\n'
        fi

        # Vaultwarden backup age in seconds since the newest file under the
        # backup directory was last modified. Only meaningful when the SSD is
        # mounted; absent when it is not (a separate alert fires then).
        if mountpoint -q ${PATHS.EX-SSD} 2>/dev/null; then
          newest=$(find ${PATHS.BACKUP_ROOT}/warden/ -type f -printf '%T@\n' \
                   2>/dev/null | sort -rn | head -1)
          if [ -n "$newest" ]; then
            # find -printf %T@ gives seconds.microseconds; strip the decimal.
            age=$(( $(date +%s) - ''${newest%.*} ))
            printf 'o700_backup_age_seconds{name="vaultwarden"} %s\n' "$age"
          fi
        fi

        # SUID binaries outside /nix/store (immutable) and /run/wrappers
        # (NixOS's sanctioned privilege escalation: sudo, ping, etc.).
        # Anything else is unexpected and warrants investigation.
        count=$(find / -xdev \
                  \( -path '/nix/store/*' -o -path '/run/wrappers/*' \) \
                  -prune -o -perm -4000 -print 2>/dev/null | wc -l)
        printf 'o700_suid_outside_store_count %s\n' "$count"

        # Authorized-keys digest. 12 hex digits of sha256 = 48 bits, safely
        # within float64's exact integer range so changes() works correctly.
        # Changes during a planned nixos-rebuild (which regenerates the file
        # from config) are expected; an out-of-hours change is suspicious.
        auth_keys="/etc/ssh/authorized_keys/${USERNAME}"
        if [ -f "$auth_keys" ]; then
          digest=$(sha256sum "$auth_keys" | cut -c1-12)
          digest_int=$(printf '%d' "0x$digest")
          printf 'o700_authorized_keys_digest %s\n' "$digest_int"
        fi

      } > "$TMP"

      # Atomic replace: node_exporter textfile collector requires this to
      # avoid reading a partially-written file.
      mv "$TMP" "$OUT"
    '';
  };
in
{
  # The textfile collector reads from this directory. World-readable so
  # node_exporter (DynamicUser) can read without group membership.
  systemd.tmpfiles.rules = [
    "d ${textfile-dir} 0755 root root - -"
  ];

  systemd.services.node-exporter-facts = {
    description = "Write node_exporter textfile collector facts";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe facts-script;
      # Runs as root: needs to read authorized_keys (root:root) and search
      # the full filesystem for SUID files. The output dir is root-owned.
    };
  };

  systemd.timers.node-exporter-facts = {
    description = "Refresh node_exporter textfile facts every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
      # Spread the load slightly to avoid all timers firing at the same second.
      AccuracySec = "30s";
    };
  };
}
