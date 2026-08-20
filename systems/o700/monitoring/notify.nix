{ config, pkgs, lib, USERNAME, ... }:
let
  notify-script = pkgs.writeShellApplication {
    name = "telegram-notify";
    runtimeInputs = with pkgs; [ curl systemd coreutils gnused ];
    text = ''
      unit="''${1:?unit name required}"

      # Telegram caps a message at 4096 characters and rejects the whole request
      # if you exceed it -- so an over-long failure report produces *no* report.
      # Tail 20 lines then hard-trim to 3000 chars, HTML-escape angle brackets
      # and ampersands (parse_mode=HTML rejects unescaped ones).
      if [ "$unit" = "boot" ]; then
        body="Host started"
      else
        body=$(journalctl -u "$unit" -n 20 --no-pager -o cat 2>/dev/null \
               | tail -c 3000 \
               | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
      fi

      curl -sS --max-time 20 --retry 3 --retry-delay 5 \
        "https://api.telegram.org/bot''${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=''${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=<b>o700</b> | <code>$unit</code>
<pre>$body</pre>"
    '';
  };

  # Critical units whose failure must reach Telegram even -- especially --
  # when the monitoring stack itself is what failed. The OnFailure= wiring
  # below means a dead VictoriaMetrics triggers the notifier directly via
  # systemd, bypassing vmalert and Alertmanager entirely.
  criticalUnits = [
    "victoriametrics"
    "victorialogs"
    "vmalert-metrics"
    "vmalert-logs"
    "alertmanager"
    "grafana"
    "systemd-journal-upload"
    "prometheus-node-exporter"
    "prometheus-blackbox-exporter"
    "prometheus-smartctl-exporter"
    "prometheus-fail2ban-exporter"
    "caddy"
    "sshd"
    "fail2ban"
    "firewall"
    "dnsmasq"
    "dnscrypt-proxy"
    "vaultwarden"
    "backup-vaultwarden"
    "gitea"
    "nfs-server"
    "node-exporter-facts"
  ];
in {
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
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.age.secrets.alerting.path;
          ExecStart = "${lib.getExe notify-script} boot";
        };
      };
    };
}
