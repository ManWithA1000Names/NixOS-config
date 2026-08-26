{
  config,
  pkgs,
  lib,
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

      curl -sS --max-time 20 --retry 3 --retry-delay 5 \
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
  ];

  # vaultwarden, backup-vaultwarden and gitea reach this list via
  # seta.<svc>.critical + seta.<svc>.units, so they are no longer named here.
  setaCriticalUnits = lib.concatMap (meta: meta.units) (
    builtins.filter (meta: meta.critical) (builtins.attrValues config.seta)
  );

  criticalUnits = lib.unique (infraCriticalUnits ++ setaCriticalUnits);
in
{
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
