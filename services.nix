{ pkgs, plane_app_port, plane_app_domain, ... }:
let

  services = {
    "git.local" = "8001";
    "mealie.local" = "8002";
    "jellyfin.local" = "8096";
    ${plane_app_domain} = toString plane_app_port;
  };

  GITEA_DB_PORT = "9001";
  HOMELAB_DASHBOARD_PORT = "8000";

  # Helper to generate the avahi-publish commands
  publishCommands = builtins.concatStringsSep "\n"
    (builtins.map (name: "${pkgs.avahi}/bin/avahi-publish -a ${name} -R $IP &")
      (builtins.attrNames services));
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

    caddy = {
      enable = true;
      globalConfig = ''
        local_certs
      '';
      virtualHosts = (builtins.mapAttrs
        (name: port: { extraConfig = "reverse_proxy localhost:${port}"; })
        services) // {
          ":80" = {
            extraConfig = "reverse_proxy localhost:${HOMELAB_DASHBOARD_PORT}";
          };
          ":443" = {
            extraConfig = "reverse_proxy localhost:${HOMELAB_DASHBOARD_PORT}";
          };
        };
    };

    homelab-dashboard = {
      enable = true;
      port = pkgs.lib.toInt HOMELAB_DASHBOARD_PORT;
      title = "Local Cloud Control Center";
      services = builtins.mapAttrs (name: value: {
        port = pkgs.lib.toInt value;
        url = "http://${name}";
      }) services;
    };

    gitea = {
      enable = true;
      lfs.enable = true;
      settings.server = {
        DOMAIN = "git.local";
        HTTP_PORT = pkgs.lib.toInt services."git.local";
      };

      database.port = pkgs.lib.toInt GITEA_DB_PORT;
    };

    jellyfin = {
      enable = true;
      dataDir = "/mnt/hdd/jellyfin/";
    };

    mealie = {
      enable = true;
      port = pkgs.lib.toInt services."mealie.local";
      settings = { BASE_URL = "http://mealie.local"; };
    };

  };

  systemd.services.avahi-aliases = {
    description = "Broadcast mDNS aliases for Caddy";
    after = [ "avahi-daemon.service" "network.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.avahi pkgs.coreutils pkgs.gawk pkgs.iproute2 pkgs.gnugrep ];
    serviceConfig = {
      Type = "simple";
      # This script finds the current IP and starts the background broadcasters
      ExecStart = pkgs.writeShellScript "publish-aliases" ''
        # Wait for an IP to be assigned (crucial for offline/Link-Local)
        while ! hostname -I | grep -q '.'; do sleep 1; done

        IP=$(ip -4 addr show up | grep -v "127.0.0.1" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
        echo "Registering aliases for IP: $IP"

        ${publishCommands}

        # Keep the service alive
        wait
      '';
      Restart = "always";
    };
  };

}
