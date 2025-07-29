_:
let
  shared = import ../shared.nix;

  subdomain = subdomain: subdomain + "." + shared.base_domain_name;
  localurl = port: "http://127.0.0.1:${builtins.toString port}";
  localurlV6 = port: "http://[::1]:${builtins.toString port}";

  services = {
    adguard = rec {
      port = 8001;
      domain = subdomain "adguard";
      url = "http://${domain}";
      local_url = localurl port;
    };
    gitea = rec {
      port = 8002;
      domain = subdomain "git";
      url = "http://${domain}";
      local_url = localurl port;
    };
    grafana = rec {
      port = 8003;
      domain = subdomain "grafana";
      url = "http://${domain}";
      local_url = localurl port;
    };
    mealie = rec {
      port = 8004;
      domain = subdomain "mealie";
      url = "http://${domain}";
      local_url = localurl port;
    };
    jellyfin = rec {
      port = 8096;
      domain = subdomain "fin";
      url = "http://${domain}";
      local_url = localurl port;
    };
    warden = rec {
      port = 8222;
      domain = subdomain "warden";
      url = "http://${domain}";
      local_url = localurlV6 port;
    };
    plane = rec {
      port = shared.plane_app_port;
      domain = shared.plane_app_domain;
      url = "http://${domain}";
      local_url = localurl port;
    };
    netdata = rec {
      port = 19999;
      domain = subdomain "netdata";
      url = "http://${domain}";
      local_url = localurl port;
    };
  };

  toVirtualHosts = s:
    builtins.foldl' (acc: name:
      acc // {
        ${s.${name}.domain} = {
          locations."/".proxyPass = s.${name}.local_url;
        };
      }) { } (builtins.attrsNames s);

  GITEA_DB_PORT = 9001;
  HOMELAB_DASHBOARD_PORT = 8000;
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

    nginx = {
      enable = true;

      virtualHosts = {
        ${shared.base_domain_name} = {
          default = true;
          locations."/".proxyPass = localurl HOMELAB_DASHBOARD_PORT;
        };
      } // (toVirtualHosts services);

    };

    homelab-dashboard = {
      enable = true;
      port = HOMELAB_DASHBOARD_PORT;
      title = "Local Cloud Control Center";
      services =
        builtins.mapAttrs (name: value: { inherit (value) port url; }) services;
    };

    adguardhome = {
      enable = true;
      port = services.adguard.port;
      mutableSettings = false;
      settings = {
        dns.bootstrap_dns = [ "1.1.1.1" "1.0.0.1" ];
        filtering.rewrites = [
          {
            answer = shared.static_ip;
            domain = shared.base_domain_name;
          }
          {
            answer = shared.static_ip;
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
        HTTP_PORT = services.gitea.port;
      };

      database.port = GITEA_DB_PORT;
    };

    grafana = {
      enable = true;
      settings = {
        server = {
          http_port = services.grafana.port;
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
      port = services.mealie.port;
      settings = { BASE_URL = "http://${""}"; };
    };

    netdata = { enable = true; };

    vaultwarden = { enable = true; };
  };

}
