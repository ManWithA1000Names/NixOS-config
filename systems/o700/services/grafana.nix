rec {
  NAME = "Grafana";
  SUB-DOMAIN = "grafana";
  PORT = 3000;
  GROUP = "Monitoring";
  DESCRIPTION = "Metrics and logs dashboard";
  ICON = "grafana.png";

  SERVICE = "grafana";

  # Includes an access log so fail2ban can watch login failures for the
  # caddy-badauth jail defined in hardening.nix. The log block must come
  # before reverse_proxy; later directives take precedence in Caddy.
  CADDY_EXTRA_CONFIG = ''
    log {
      output file /var/log/caddy/access-grafana.log {
        roll_size 20MiB
        roll_keep 5
      }
      format json
    }
    reverse_proxy localhost:${builtins.toString PORT}
  '';

  config = { toDomain, pkgs, ... }: {
    enable = true;

    # victoriametrics-logs-datasource is a community plugin. If Grafana
    # refuses to load it unsigned, add:
    #   settings.plugins.allow_loading_unsigned_plugins = "victoriametrics-logs-datasource";
    declarativePlugins = [ pkgs.grafanaPlugins.victoriametrics-logs-datasource ];

    settings = {
      server = {
        # Caddy is the only thing that speaks to Grafana; binding to loopback
        # is redundant with the default-deny firewall but states intent clearly
        # and survives someone later adding an allowedTCPPorts entry for 3000.
        http_addr = "127.0.0.1";
        http_port = PORT;
        domain = toDomain SUB-DOMAIN;
        root_url = "https://${toDomain SUB-DOMAIN}/";
        enforce_domain = true;
      };
      security = {
        # admin_password is intentionally left unset here. Grafana will prompt
        # for a new password on first login (admin / admin default). You MUST
        # change it before creating the public DNS A record for grafana.o700.net.
        cookie_secure = true;
        cookie_samesite = "strict";
        disable_gravatar = true;
        content_security_policy = true;
        strict_transport_security = true;
      };
      users.allow_sign_up = false;
      "auth.anonymous".enabled = false;
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
      };
    };

    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = [
          {
            name = "VictoriaMetrics";
            type = "prometheus";
            uid = "vm";
            url = "http://127.0.0.1:8428";
            isDefault = true;
          }
          {
            name = "VictoriaLogs";
            type = "victoriametrics-logs-datasource";
            uid = "vl";
            url = "http://127.0.0.1:9428";
          }
        ];
      };
    };
  };
}
