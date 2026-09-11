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

  # The OnFailure value every opted-in unit carries. One definition, because
  # it is now written in four different files and a silent typo in any of them
  # is a notification that never arrives -- see the assertions below, which
  # check the units against this exact string.
  notifyMarker = "telegram-notify@%n.service";

  # The same guard seta.nix applies to seta.<svc>.units, for the same reason
  # and against the same failure: naming a unit that nothing defines does not
  # error, it makes systemd synthesise an empty one carrying only the OnFailure
  # hung off it. The result is a broken unit in the generation and a
  # notification path wired to something that can never run.
  #
  # This used to check a hand-written list of unit names kept in this file.
  # There is no list any more -- each unit opts in on its own definition, next
  # to its own ExecStart -- so the check is derived from the configuration
  # instead, and now covers every present and future opt-in without being
  # updated. That also closes the gap that actually opened last time: the
  # offsite backup unit is conditional on a bucket being configured, and the
  # central list named it unconditionally. Wired on the unit itself it lives
  # inside the same lib.mkIf, so the condition cannot be stated twice and drift.
  #
  # Two distinct mistakes are caught here, both of which fail silently:
  #
  #   A unit with no ExecStart. Most opt-ins sit beside their own ExecStart and
  #   cannot get this wrong, but netdata's comes from nixpkgs -- so a module
  #   that renamed its unit would leave the wiring attached to nothing.
  #
  #   The wrong specifier. `%n` expands to the failing unit's full name, which
  #   is what the template's ExecStart passes to the notifier. `%i` is the
  #   obvious typo and expands to nothing useful outside a template unit, so
  #   the message would arrive naming no service at all.
  notifiedUnits = builtins.filter (
    name: builtins.any (u: lib.hasPrefix "telegram-notify@" u) config.systemd.services.${name}.onFailure
  ) (builtins.attrNames config.systemd.services);

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
  assertions =
    (map (unit: {
      assertion = config.systemd.services.${unit} ? serviceConfig.ExecStart;
      message = ''
        systemd.services."${unit}".onFailure wires the telegram notifier, but that unit has no
        ExecStart in this configuration. systemd will synthesise an empty unit for it rather
        than failing, so the OnFailure would hang off something that can never run. Either
        attach the wiring to a real unit or make it conditional on whatever generates one.
      '';
    }) notifiedUnits)
    ++ (map (unit: {
      assertion = config.systemd.services.${unit}.onFailure == [ notifyMarker ];
      message = ''
        systemd.services."${unit}".onFailure must be exactly [ "${notifyMarker}" ]. The %n
        specifier is what expands to the failing unit's own name; %i expands to nothing
        meaningful on a non-template unit, and the notification would arrive without saying
        which service produced it.
      '';
    }) notifiedUnits);

  systemd.services = {
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
