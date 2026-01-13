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

    ollama = {
      enable = true;
      acceleration = "cuda";
      loadModels = [ "gemma3:27b" "deepseek-r1:32b" ];
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
        };

        "fin.br41niac.net".locations."/" = {
          proxyPass = "http://127.0.0.1:8096";
          proxyWebsockets = true;
        };
        "plane.br41niac.net".locations."/" = {
          proxyPass = "http://127.0.0.1:8079";
          proxyWebsockets = true;
        };
        "penpot.br41niac.net".locations."/" = {
          proxyPass = "http://127.0.0.1:9001";
          proxyWebsockets = true;
        };
        "erp.br41niac.net".locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          proxyWebsockets = true;
        };
      };
    };
  };
}
