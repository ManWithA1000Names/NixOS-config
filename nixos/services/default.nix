_: {
  services = {
    printing.enable = true;

    hypridle.enable = true;

    gnome.gnome-keyring.enable = true;

    blueman.enable = true;

    resolved.enable = true;

    openssh = {
      enable = true;
      settings.PermitRootLogin = "no";
    };

    avahi = {
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
        workstation = true;
        userServices = true;
      };
    };

    jellyfin = {
      enable = true;
      dataDir = "/mnt/ex-ssd/jellyfin/";
    };

    nginx = {
      enable = true;

      virtualHosts = {
        "br41niac.net" = {
          # Use a global redirect to the subdomain
          # The browser will be told to go to plane.br41niac.net instead
          extraConfig = "return 301 http://plane.br41niac.net$request_uri;";
          listen = [{
            addr = "127.0.0.2";
            port = 80;
          }];
        };

        "fin.br41niac.net" = {
          locations."/" = {
            proxyPass = "http://127.0.0.1:8096";
            proxyWebsockets = true;
          };
          listen = [{
            addr = "127.0.0.2";
            port = 80;
          }];
        };

        "plane.br41niac.net" = {
          locations."/" = {
            proxyPass = "http://127.0.0.1:8079";
            proxyWebsockets = true;
          };
          listen = [{
            addr = "127.0.0.2";
            port = 80;
          }];
        };

        "penpot.br41niac.net" = {
          locations."/" = {
            proxyPass = "http://127.0.0.1:9001";
            proxyWebsockets = true;
          };
          listen = [{
            addr = "127.0.0.2";
            port = 80;
          }];
        };

        "erp.br41niac.net" = {
          locations."/" = {
            proxyPass = "http://127.0.0.1:8080";
            proxyWebsockets = true;
          };
          listen = [{
            addr = "127.0.0.2";
            port = 80;
          }];
        };
      };
    };
  };
}
