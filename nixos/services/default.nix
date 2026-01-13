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
        "jellyfin.me".locations."/" = {
          proxyPass = "http://127.0.0.1:8096";
          proxyWebsockets = true;
        };
        "plane.me".locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          proxyWebsockets = true;
        };
        "penpot.me".locations."/" = {
          proxyPass = "http://127.0.0.1:9001";
          proxyWebsockets = true;
        };
      };
    };
  };
}
