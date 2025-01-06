{ pkgs, ... }:
let
  URL = "atalanta.me";
  subdomain = subdomain: subdomain + "." + URL;
  localurl = port: "http://127.0.0.1:${builtins.toString port}";

  SERVER_IP = "192.168.1.12";

  ADGUARD_PORT = 8000;

  GIT_PORT = 8001;
  GIT_DB_PORT = 8002;

  GRAFANA_PORT = 8003;
  JELLYFIN_PORT = 8096;

  MEALIE_PORT = 8004;

in {
  services = {
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };

    logind = {
      lidSwitch = "ignore";
      lidSwitchDocked = "ignore";
    };

    nginx = {
      enable = true;

      virtualHosts = {
        ${URL} = { };

        ${subdomain "fin"}.locations."/".proxyPass = localurl JELLYFIN_PORT;
        ${subdomain "mealie"}.locations."/".proxyPass = localurl MEALIE_PORT;
        ${subdomain "adguard"}.locations."/".proxyPass = localurl ADGUARD_PORT;
        ${subdomain "git"}.locations."/".proxyPass = localurl GIT_PORT;

        ${subdomain "grafana"}.locations."/" = {
          proxyPass = localurl GRAFANA_PORT;
          extraConfig = ''
            proxy_set_header Host $host;
          '';
        };
      };

    };

    adguardhome = {
      enable = true;
      port = ADGUARD_PORT;
      mutableSettings = false;
      settings = {
        dns.bootstrap_dns = [ "1.1.1.1" "1.0.0.1" ];
        dns.filtering.rewrites = [
          {
            answer = SERVER_IP;
            domain = URL;
          }
          {
            answer = SERVER_IP;
            domain = subdomain "*";
          }
        ];
      };
    };

    gitea = {
      enable = true;
      lfs.enable = true;
      settings.server = {
        DOMAIN = subdomain "git";
        HTTP_PORT = GIT_PORT;
      };

      database.port = GIT_DB_PORT;
    };

    grafana = {
      enable = true;
      settings = {
        server = {
          http_port = GRAFANA_PORT;
          domain = subdomain "grafana";
        };
        security = {
          admin_user = "admin";
          admin_password = "admin"; # Change this in production
        };
      };
    };

    jellyfin = {
      enable = true;
      dataDir = "/mnt/hdd/jellyfin/";
    };

    mealie = {
      enable = true;
      port = MEALIE_PORT;
      settings = {
        BASE_URL = "http://${subdomain "mealie"}";
      };
    };

  };

}
