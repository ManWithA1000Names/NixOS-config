{
  pkgs,
  config,
  PORTS,
  DOMAIN,
  PATHS,
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
    };

    grafana = {
      enable = true;

      # services.grafana.settings.plugins.allow_loading_unsigned_plugins =
      #   "victoriametrics-logs-datasource";
      declarativePlugins = with pkgs.grafanaPlugins; [
        victoriametrics-logs-datasource
      ];

      settings = {
        server = rec {
          http_addr = "127.0.0.1";
          http_port = PORTS.GRAFANA;
          domain = "${config.seta.grafana.proxy.domain}";
          root_url = "https://${domain}";
          enforce_domain = true;
        };
        security = {
          cookie_secure = true;
          cookie_samesite = "strict";
          disable_gravatar = true;
          content_security_policy = true;
          strict_transport_security = true;
        };
        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
        };
        users.allow_sign_up = false;
        auth.anonymous.enabled = false;
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
              url = "http://127.0.0.1:${toString PORTS.VICTORIA_METRICS}";
            }
            {
              name = "VictoriaLogs";
              type = "victoriametrics-logs-datasource";
              uid = "vl";
              url = "http://127.0.0.1:${toString PORTS.VICTORIA_LOGS}";
            }
          ];
        };
      };
    };
  };

  seta = {
    vaultwarden = {
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

    grafana = {
      dashboard = {
        enable = true;
        name = "Grafana";
        description = "Metrics & logs dashboard";
        group = "Monitoring";
        icon = "grafana.png";
      };

      proxy = {
        enable = true;
        port = PORTS.GRAFANA;
        domain = "grafana.${DOMAIN}";
        exposure = "WAN";
      };
    };
  };
}
