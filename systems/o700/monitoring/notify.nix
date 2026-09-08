{
  config,
  pkgs,
  lib,
  BACKUP,
  ...
}:
let
  notify-script = pkgs.writeShellApplication {
    name = "telegram-notify";
    runtimeInputs = with pkgs; [
      curl
      systemd
      coreutils
      gnused
    ];
    text = ''
      unit="''${1:?unit name required}"

      if [ "$unit" = "boot" ]; then
        verdict=""
        body="Host started"
      else
        # `-u` matches two different things: lines written by the service
        # process, and PID 1's commentary *about* the unit -- "Starting...",
        # "Main process exited", "Consumed 1.8s CPU time over 19.6s wall clock",
        # "Triggering OnFailure=". The second kind crowds out the first, so a
        # one-line finding arrives buried in five lines of lifecycle noise.
        # Matching _SYSTEMD_UNIT= selects only the process's own output, which
        # is the part that says what actually happened.
        body=$(journalctl _SYSTEMD_UNIT="$unit" -n 30 --no-pager -o cat 2>/dev/null \
               | tail -c 2500 \
               | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g') || body=""
        # A unit that is killed usually logs nothing, and an empty <pre> reads
        # as a broken notifier rather than as silence from the service.
        [ -n "$body" ] || body="no output on this invocation"

        # systemd's own verdict, as structured data rather than prose scraped
        # from the lines dropped above. Result is what separates a unit that
        # exited non-zero deliberately -- host-audit reports its findings that
        # way -- from one that was killed: signal, oom-kill, timeout,
        # core-dump. Without it every failure reads identically.
        result=$(systemctl show "$unit" --property=Result --value 2>/dev/null) || result=""
        status=$(systemctl show "$unit" --property=ExecMainStatus --value 2>/dev/null) || status=""
        verdict="''${result:-unknown} · status ''${status:-?}"
      fi

      # Telegram caps a message at 4096 characters and rejects the entire
      # request past that, so an over-long report produces *no* report. The
      # 2500-char trim above leaves room for the header, verdict and tags.
      #
      # printf builds this rather than a multi-line Nix literal: the newlines
      # are load-bearing, and a Nix indented string only strips indentation
      # down to the common prefix, so the rest would be sent to Telegram as
      # part of the message.
      if [ -n "$verdict" ]; then
        message=$(printf '<b>o700</b> | <code>%s</code>\n%s\n<pre>%s</pre>' \
                  "$unit" "$verdict" "$body")
      else
        message=$(printf '<b>o700</b> | <code>%s</code>\n<pre>%s</pre>' \
                  "$unit" "$body")
      fi

      # --retry alone never covered the failure this was added for: curl treats
      # ECONNREFUSED as fatal rather than transient (curl.1, --retry-connrefused),
      # so a closed port fell straight through the existing --retry 3.
      # --max-time bounds each attempt; --retry-max-time bounds the total, and
      # stays under systemd's 90s DefaultTimeoutStartSec.
      curl -sS --max-time 20 --retry 5 --retry-delay 5 \
        --retry-connrefused --retry-max-time 60 \
        "https://api.telegram.org/bot''${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=''${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$message"
    '';
  };

  # Critical units whose failure must reach Telegram even -- especially --
  # when the monitoring stack itself is what failed. The OnFailure= wiring
  # below means a dead Netdata triggers the notifier directly via systemd,
  # bypassing Netdata's own alarm delivery entirely.
  #
  # This path is now load-bearing in a way it was not before. Netdata's health
  # engine covers thresholds -- disk, memory, pressure -- but it cannot report
  # its own death, and there is no longer a second alerting system to notice.
  #
  # Split in two deliberately. seta is keyed by *service*, and most of what
  # belongs here is infrastructure with no seta entry at all -- so seta could
  # not replace this list, only extend it. Deriving the whole thing from seta
  # would have silently dropped sshd, nftables and fail2ban from the alerting
  # path, which is a failure that announces itself only by never arriving.
  infraCriticalUnits = [
    "netdata"
    "caddy"
    "sshd"
    "fail2ban"
    # NOT "firewall": with networking.nftables.enable the ruleset is loaded by
    # nftables.service and firewall.service does not exist. Naming a
    # non-existent unit here does not fail loudly -- it synthesises an empty
    # unit that can never fire, so the notification silently never arrives.
    "nftables"
    "dnsmasq"
    "dnscrypt-proxy"
    # Every service that has been migrated onto the centralized database now
    # fails when this one does, so its death is worth its own message rather
    # than being inferred from the pile of unrelated-looking failures that
    # follow it.
    "postgresql"
    # Not a service that can crash so much as one that reports by failing: the
    # audit exits non-zero when it finds something, so OnFailure here is the
    # delivery path for its findings, not just for its own breakage.
    "host-audit"

    # The backup orchestrator reports the same way: it counts failed sets
    # rather than aborting on the first, and exits with that count, so this is
    # the delivery path for "three services did not get backed up tonight".
    #
    # Only the units with a schedule are listed. The per-set restic-backups-*
    # units are started by the orchestrator and their failure is already
    # counted and reported by it -- wiring them here as well would send two
    # messages for one incident, and the orchestrator's is the one that says
    # which set.
    "o700-backup"
    "o700-backup-prune"
  ]
  # systems/o700/backup.nix only generates the offsite unit when a bucket is
  # configured, so naming it unconditionally would have systemd synthesise an
  # empty one -- a unit with an OnFailure and no ExecStart, which is the exact
  # failure the assertion below now catches.
  ++ lib.optional (BACKUP.b2Bucket != "") "o700-backup-offsite";

  # vaultwarden, backup-vaultwarden and gitea reach this list via
  # seta.<svc>.critical + seta.<svc>.units, so they are no longer named here.
  setaCriticalUnits = lib.concatMap (meta: meta.units) (
    builtins.filter (meta: meta.critical) (builtins.attrValues config.seta)
  );

  criticalUnits = lib.unique (infraCriticalUnits ++ setaCriticalUnits);

  # Units whose ExecStart lives in a unit file shipped inside a package
  # (systemd.packages) rather than in a Nix-level definition. The assertion
  # below reads config.systemd.services and therefore cannot see those, so
  # naming them here is the difference between an exemption and a hole.
  packageProvidedUnits = [
    # services.fail2ban sets `systemd.packages = [ cfg.package ]` and then only
    # augments the shipped unit with capabilities, paths and restartTriggers
    # (nixos/modules/services/security/fail2ban.nix:374-392). Its ExecStart is
    # in the package's own fail2ban.service. The unit is entirely real; it is
    # only invisible to the check.
    "fail2ban"
  ];

  # The alerting path egresses directly rather than through tinyproxy.
  # systemd.globalEnvironment (networking.nix) points every unit at the proxy,
  # which makes Telegram delivery depend on the one service whose failure this
  # exists to report -- and on it *listening*, which is not what systemd calling
  # it active means: the upstream unit is Type=simple, so it goes active at exec,
  # before it binds 127.0.0.1:TINYPROXY. That is the race that left
  # telegram-boot-notice failed with curl exit 7 after the 26.05 bump.
  #
  # Same reasoning the proxy block already applies to dnscrypt-proxy: something
  # the recovery path needs must not be routed through something that can be the
  # thing that broke. The filter is a blocklist and api.telegram.org was never on
  # it, so the proxy gave this traffic visibility, not policy.
  notifyEnvironment = {
    no_proxy = "*";
    NO_PROXY = "*";
  };
in
{
  # The same guard seta.nix applies to seta.<svc>.units, for the same reason
  # and against the same failure: naming a unit that nothing defines does not
  # error, it makes systemd synthesise an empty one carrying only the OnFailure
  # hung off it here. The result is a broken unit in the generation and a
  # notification path wired to something that can never run.
  #
  # seta.nix's assertion covers the units reached through the manifest. This
  # one covers infraCriticalUnits, which is hand-written and was where the gap
  # actually opened: o700-backup-offsite is conditional on a bucket being
  # configured, and listing it unconditionally produced exactly that empty unit.
  #
  # packageProvidedUnits is the exception seta.nix's own comment predicted --
  # "a unit that legitimately has no ExecStart would be a false positive. None
  # exist here" -- and one does, on this list rather than that one.
  assertions = map (unit: {
    assertion = (config.systemd.services.${unit} or null) ? serviceConfig.ExecStart;
    message = ''
      infraCriticalUnits in monitoring/notify.nix names "${unit}", which is not a systemd
      service defined by this configuration. systemd will synthesise an empty unit for it
      rather than failing, so the OnFailure wired here would hang off something that can
      never run. Either name a real unit or make the entry conditional on whatever
      generates it.
    '';
  }) (lib.subtractLists packageProvidedUnits infraCriticalUnits);

  systemd.services =
    # Wire every critical unit to call the template on failure.
    # %n expands to the full unit name including .service suffix.
    (lib.genAttrs criticalUnits (_: {
      onFailure = [ "telegram-notify@%n.service" ];
    }))
    // {
      # The template unit. %i expands to the failed unit's name (from OnFailure=).
      # This unit must not trigger itself (would loop); OnFailure is cleared on it.
      "telegram-notify@" = {
        description = "Telegram failure notification for %i";
        environment = notifyEnvironment;
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.age.secrets.alerting.path;
          ExecStart = "${lib.getExe notify-script} %i";
          Restart = "no";
        };
        unitConfig.OnFailure = lib.mkForce "";
      };

      # Boot notification. An unannounced reboot on a WAN-exposed host is itself
      # a signal. It also proves, at low frequency, that the token, network path
      # and Telegram bot all still work -- a silent Telegram bot is the same as
      # no monitoring from the user's perspective.
      telegram-boot-notice = {
        description = "Send Telegram notification on boot";
        wantedBy = [ "multi-user.target" ];
        environment = notifyEnvironment;
        after = [
          # network-online.target only means an interface has an address. It
          # says nothing about a resolver answering, which is what curl needs.
          "network-online.target"
          # dnsmasq is this host's only resolver (networking.nix), and unlike
          # dnscrypt-proxy it does NOT declare Before=nss-lookup.target -- so
          # ordering on that target would look correct and skip the very unit
          # that matters. Naming it directly is the only ordering that holds,
          # and it covers dnscrypt-proxy transitively since dnsmasq is After= it.
          "dnsmasq.service"
        ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          # A oneshot without this returns to "inactive (dead)" the instant it
          # succeeds, so every `nixos-rebuild switch` finds a wanted unit that
          # is not running and starts it again. That produced "Host started"
          # messages for a host that never started, and raced dnsmasq being
          # restarted in the same transaction -- the resolve failures that left
          # this unit failed. Staying "active (exited)" makes it fire once per
          # boot, which is what the name claims.
          RemainAfterExit = true;
          EnvironmentFile = config.age.secrets.alerting.path;
          ExecStart = "${lib.getExe notify-script} boot";
        };
      };
    };
}
