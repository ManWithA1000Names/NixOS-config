{ static_ip, plane_app_port, plane_app_domain, base_domain_name, ... }:
let

  subdomain = subdomain: subdomain + "." + base_domain_name;
  localurl = port: "http://127.0.0.1:${builtins.toString port}";

  services = {
    adguard = rec {
      port = 8001;
      domain = subdomain "adguard";
      url = "http://${domain}";
    };
    gitea = rec {
      port = 8002;
      domain = subdomain "git";
      url = "http://${domain}";
    };
    mealie = rec {
      port = 8004;
      domain = subdomain "mealie";
      url = "http://${domain}";
    };
    jellyfin = rec {
      port = 8096;
      domain = subdomain "fin";
      url = "http://${domain}";
    };
    plane = rec {
      port = plane_app_port;
      domain = plane_app_domain;
      url = "http://${domain}";
    };
  };

  toVirtualHosts = s:
    builtins.foldl' (acc: name:
      acc // {
        ${s.${name}.domain} = {
          locations."/".proxyPass = localurl s.${name}.port;
        };
      }) { } (builtins.attrNames s);

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

    # avahi = {
    #   enable = true;
    #   nssmdns4 = true;
    #   publish = {
    #     enable = true;
    #     addresses = true;
    #     workstation = true;
    #     userServices = true;
    #   };
    # };

    nginx = {
      enable = true;

      virtualHosts = {
        ${base_domain_name} = {
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
      inherit (services.adguard) port;
      mutableSettings = false;
      settings = {
        dns.bootstrap_dns = [ "1.1.1.1" "1.0.0.1" ];
        filtering.rewrites = [
          {
            answer = static_ip;
            domain = base_domain_name;
          }
          {
            answer = static_ip;
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

    jellyfin = {
      enable = true;
      dataDir = "/mnt/hdd/jellyfin/";
    };

    mealie = {
      enable = true;
      inherit (services.mealie) port;
      settings = { BASE_URL = "http://${""}"; };
    };

  };

}
